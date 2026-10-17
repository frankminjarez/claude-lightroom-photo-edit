--[[
  Claude AI Photo Edit for Lightroom Classic
  ClaudeEdit.lua — Main action

  Shows a dialog before processing:
    - Freeform style prompt          (persisted between runs)
    - Recent prompts picker          (last 100 prompts, most recent first)
    - Which develop panels to adjust (persisted between runs)

  For each selected photo:
    1. Read current develop settings
    2. Fetch JPEG thumbnail from Lightroom's preview cache
    3. POST image + current settings + style prompt to Anthropic Messages API
       — prompt schema is built dynamically from the selected panels
    4. Parse JSON response
    5. Apply returned settings for selected panels only
    6. Show per-run before→after summary with Claude's reasoning
--]]

local LrApplication      = import 'LrApplication'
local LrBinding          = import 'LrBinding'
local LrDialogs          = import 'LrDialogs'
local LrFunctionContext  = import 'LrFunctionContext'
local LrHttp             = import 'LrHttp'
local LrPrefs            = import 'LrPrefs'
local LrProgressScope    = import 'LrProgressScope'
local LrTasks            = import 'LrTasks'
local LrStringUtils      = import 'LrStringUtils'
local LrView             = import 'LrView'

local json = require 'json'

local pluginPrefs = LrPrefs.prefsForPlugin()

-- ─────────────────────────────────────────────────────────
-- Prompt history (last 100 style prompts, most recent first)
-- Stored as a JSON string in plugin prefs so it persists reliably.
-- ─────────────────────────────────────────────────────────
local MAX_PROMPT_HISTORY = 100

local function loadPromptHistory()
    local raw = pluginPrefs.promptHistory
    local list = (type(raw) == 'string' and raw ~= '') and json.decode(raw) or nil
    if type(list) ~= 'table' then list = {} end
    -- Seed with the previously saved single prompt (upgrade from older version)
    if #list == 0 and type(pluginPrefs.stylePrompt) == 'string' and pluginPrefs.stylePrompt ~= '' then
        list[1] = pluginPrefs.stylePrompt
    end
    return list
end

local function savePromptHistory(list)
    pluginPrefs.promptHistory = json.encode(list)
end

-- Move/insert prompt at the top, drop duplicates, cap at MAX_PROMPT_HISTORY
local function addToPromptHistory(prompt)
    local list    = loadPromptHistory()
    local updated = { prompt }
    for _, p in ipairs(list) do
        if p ~= prompt and #updated < MAX_PROMPT_HISTORY then
            updated[#updated + 1] = p
        end
    end
    savePromptHistory(updated)
end

-- Build popup_menu items for the history list
local function historyMenuItems(list)
    local items = {
        { title = (#list > 0)
                    and string.format('\226\128\148 Recent prompts (%d) \226\128\148', #list)
                    or  '\226\128\148 No saved prompts yet \226\128\148',
          value = 0 },
    }
    for i, p in ipairs(list) do
        local label = p:gsub('[\r\n]+', ' ')
        if #label > 90 then
            -- trim, then drop any partial UTF-8 character at the cut point
            label = label:sub(1, 87):gsub('[\192-\255][\128-\191]*$', '') .. '...'
        end
        items[#items + 1] = { title = label, value = i }
    end
    return items
end

-- ─────────────────────────────────────────────────────────
-- Base64 encoder (pure Lua)
-- ─────────────────────────────────────────────────────────
local B64_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

local function base64Encode(data)
    local result  = {}
    local dataLen = #data
    local padding = (3 - (dataLen % 3)) % 3
    for i = 1, dataLen + padding, 3 do
        local b1 = data:byte(i)     or 0
        local b2 = data:byte(i + 1) or 0
        local b3 = data:byte(i + 2) or 0
        local n  = b1 * 65536 + b2 * 256 + b3
        result[#result + 1] = B64_CHARS:sub(math.floor(n / 262144) % 64 + 1, math.floor(n / 262144) % 64 + 1)
        result[#result + 1] = B64_CHARS:sub(math.floor(n / 4096)   % 64 + 1, math.floor(n / 4096)   % 64 + 1)
        result[#result + 1] = B64_CHARS:sub(math.floor(n / 64)     % 64 + 1, math.floor(n / 64)     % 64 + 1)
        result[#result + 1] = B64_CHARS:sub(n % 64 + 1,                      n % 64 + 1)
    end
    local encoded = table.concat(result)
    if padding == 2 then encoded = encoded:sub(1, #encoded - 2) .. '=='
    elseif padding == 1 then encoded = encoded:sub(1, #encoded - 1) .. '='
    end
    return encoded
end

-- ─────────────────────────────────────────────────────────
-- JPEG dimension reader (pure Lua — parses SOF marker)
-- ─────────────────────────────────────────────────────────
local function getJpegDimensions(data)
    if not data or #data < 4 then return nil, nil end
    if data:byte(1) ~= 0xFF or data:byte(2) ~= 0xD8 then return nil, nil end
    local i = 3
    while i <= #data - 8 do
        if data:byte(i) ~= 0xFF then break end
        local marker = data:byte(i + 1)
        if marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC
           and marker >= 0xC0 and marker <= 0xCF then
            local h = data:byte(i + 5) * 256 + data:byte(i + 6)
            local w = data:byte(i + 7) * 256 + data:byte(i + 8)
            return w, h
        end
        local segLen = data:byte(i + 2) * 256 + data:byte(i + 3)
        if segLen < 2 then break end
        i = i + 2 + segLen
    end
    return nil, nil
end

local MAX_IMAGE_DIM   = 7999
local MAX_IMAGE_BYTES = 9 * 1024 * 1024

-- ─────────────────────────────────────────────────────────
-- Async thumbnail retrieval
--
-- When Lightroom marks a preview stale (e.g. after develop settings change),
-- requestJpegThumbnail returns an error on every attempt regardless of how
-- long you wait.  The only reliable reset is for the user to click away to
-- another photo and back — this resets Lightroom's internal preview state.
--
-- catalog:setSelectedPhotos() cannot be called from inside an async task
-- while a progress scope is active (Lightroom asserts).  So after exhausting
-- retries we surface a clear instruction instead.
-- ─────────────────────────────────────────────────────────
local function getPhotoThumbnail(photo, size)
    local MAX_ATTEMPTS = 3

    for attempt = 1, MAX_ATTEMPTS do
        local jpegData, thumbError, done = nil, nil, false

        photo:requestJpegThumbnail(size, size, function(data, errorMsg)
            if data and #data > 0 then jpegData = data
            else thumbError = errorMsg or 'unknown' end
            done = true
        end)

        local deadline = os.time() + 30
        while not done do
            LrTasks.yield()
            if os.time() > deadline then
                return nil, 'Timed out waiting for preview. Go to Library \226\150\184 Previews \226\150\184 Build Standard-Sized Previews and retry.'
            end
        end

        if jpegData then
            if #jpegData > MAX_IMAGE_BYTES then
                return nil, string.format(
                    'Preview is too large to send (%.1f MB \226\128\148 limit is 9 MB). ' ..
                    'Go to Library \226\150\184 Previews \226\150\184 Build Standard-Sized Previews and retry.',
                    #jpegData / (1024 * 1024))
            end
            local w, h = getJpegDimensions(jpegData)
            if w and h and (w > MAX_IMAGE_DIM or h > MAX_IMAGE_DIM) then
                return nil, string.format(
                    'Preview too large (%d\195\151%d px, limit 8000 px). ' ..
                    'Go to Library \226\150\184 Previews \226\150\184 Build Standard-Sized Previews and retry.',
                    w, h)
            end
            return jpegData, nil
        end

        -- Brief yield between attempts before giving up
        LrTasks.yield()
    end

    return nil, 'Preview appears stale. Click a different photo and then ' ..
        're-select this one to reset the preview, then run Edit again. ' ..
        'Or go to Library \226\150\184 Previews \226\150\184 Build Standard-Sized Previews.'
end

-- ─────────────────────────────────────────────────────────
-- Read all develop settings (all panels)
-- ─────────────────────────────────────────────────────────
local HSL_COLORS = { 'Red', 'Orange', 'Yellow', 'Green', 'Aqua', 'Blue', 'Purple', 'Magenta' }

local function readCurrentSettings(photo)
    local ds = photo:getDevelopSettings()
    if not ds then return {} end
    local s = {}

    -- White Balance
    s.WhiteBalance   = ds.WhiteBalance  or 'Custom'
    s.Temperature    = ds.Temperature   or 5500
    s.Tint           = ds.Tint          or 0

    -- Basic Tone
    s.Exposure2012   = ds.Exposure2012   or 0
    s.Contrast2012   = ds.Contrast2012   or 0
    s.Highlights2012 = ds.Highlights2012 or 0
    s.Shadows2012    = ds.Shadows2012    or 0
    s.Whites2012     = ds.Whites2012     or 0
    s.Blacks2012     = ds.Blacks2012     or 0

    -- Presence
    s.Clarity2012 = ds.Clarity2012 or 0
    s.Vibrance    = ds.Vibrance    or 0
    s.Saturation  = ds.Saturation  or 0

    -- Parametric Tone Curve
    s.ParametricShadows    = ds.ParametricShadows    or 0
    s.ParametricDarks      = ds.ParametricDarks      or 0
    s.ParametricLights     = ds.ParametricLights     or 0
    s.ParametricHighlights = ds.ParametricHighlights or 0

    -- HSL Color Mixer
    for _, color in ipairs(HSL_COLORS) do
        s['HueAdjustment'        .. color] = ds['HueAdjustment'        .. color] or 0
        s['SaturationAdjustment' .. color] = ds['SaturationAdjustment' .. color] or 0
        s['LuminanceAdjustment'  .. color] = ds['LuminanceAdjustment'  .. color] or 0
    end

    -- Color Grading (LR 10+ keys; fall back to Split Toning keys for older versions)
    s.CGShadowHue    = ds.ColorGradeShadowHue    or ds.ShadowHue           or 0
    s.CGShadowSat    = ds.ColorGradeShadowSat    or ds.ShadowSaturation    or 0
    s.CGMidtoneHue   = ds.ColorGradeMidtoneHue   or 0
    s.CGMidtoneSat   = ds.ColorGradeMidtoneSat   or 0
    s.CGHighlightHue = ds.ColorGradeHighlightHue or ds.HighlightHue        or 0
    s.CGHighlightSat = ds.ColorGradeHighlightSat or ds.HighlightSaturation or 0
    s.CGBalance      = ds.ColorGradeBalance      or ds.SplitToningBalance  or 0

    -- Detail — Sharpening
    s.Sharpness          = ds.Sharpness          or 25
    s.SharpenRadius      = ds.SharpenRadius      or 1.0
    s.SharpenDetail      = ds.SharpenDetail      or 25
    s.SharpenEdgeMasking = ds.SharpenEdgeMasking or 0

    -- Detail — Noise Reduction
    s.LuminanceSmoothing            = ds.LuminanceSmoothing            or 0
    s.LuminanceDetail               = ds.LuminanceDetail               or 50
    s.LuminanceContrast             = ds.LuminanceContrast             or 0
    s.ColorNoiseReduction           = ds.ColorNoiseReduction           or 25
    s.ColorNoiseReductionDetail     = ds.ColorNoiseReductionDetail     or 50
    s.ColorNoiseReductionSmoothness = ds.ColorNoiseReductionSmoothness or 50

    return s
end

-- ─────────────────────────────────────────────────────────
-- Build a human-readable settings summary sent to Claude
-- (always includes all panels so Claude understands the full current state)
-- ─────────────────────────────────────────────────────────
local function settingsSummary(s)
    local lines = {
        string.format('White Balance: %s  Temperature: %dK  Tint: %+d',
            s.WhiteBalance, s.Temperature, s.Tint),
        string.format('Tone: Exposure %+.2f  Contrast %+d  Highlights %+d  Shadows %+d  Whites %+d  Blacks %+d',
            s.Exposure2012, s.Contrast2012, s.Highlights2012, s.Shadows2012, s.Whites2012, s.Blacks2012),
        string.format('Presence: Clarity %+d  Vibrance %+d  Saturation %+d',
            s.Clarity2012, s.Vibrance, s.Saturation),
        string.format('Tone Curve: Shadows %+d  Darks %+d  Lights %+d  Highlights %+d',
            s.ParametricShadows, s.ParametricDarks, s.ParametricLights, s.ParametricHighlights),
        '',
        'HSL Color Mixer:',
        '  Color    | Hue | Sat | Lum',
        '  ---------|-----|-----|----',
    }
    for _, color in ipairs(HSL_COLORS) do
        lines[#lines + 1] = string.format('  %-8s | %+4d | %+4d | %+4d',
            color,
            s['HueAdjustment'        .. color] or 0,
            s['SaturationAdjustment' .. color] or 0,
            s['LuminanceAdjustment'  .. color] or 0)
    end
    lines[#lines + 1] = string.format(
        'Color Grading: Shadows H:%d S:%d  Midtones H:%d S:%d  Highlights H:%d S:%d  Balance %+d',
        s.CGShadowHue, s.CGShadowSat, s.CGMidtoneHue, s.CGMidtoneSat,
        s.CGHighlightHue, s.CGHighlightSat, s.CGBalance)
    lines[#lines + 1] = string.format(
        'Detail: Sharpness %d  Radius %.1f  Detail %d  Masking %d  Lum NR %d (detail %d contrast %d)  Color NR %d (detail %d smooth %d)',
        s.Sharpness, s.SharpenRadius, s.SharpenDetail, s.SharpenEdgeMasking,
        s.LuminanceSmoothing, s.LuminanceDetail, s.LuminanceContrast,
        s.ColorNoiseReduction, s.ColorNoiseReductionDetail, s.ColorNoiseReductionSmoothness)
    return table.concat(lines, '\n')
end

-- ─────────────────────────────────────────────────────────
-- Clamp helpers
-- ─────────────────────────────────────────────────────────
local function clampInt(v, lo, hi)
    v = math.floor((tonumber(v) or 0) + 0.5)
    return math.max(lo, math.min(hi, v))
end

local function clampFloat(v, lo, hi, decimals)
    v = tonumber(v) or 0
    v = math.max(lo, math.min(hi, v))
    local factor = 10 ^ (decimals or 2)
    return math.floor(v * factor + 0.5) / factor
end

-- ─────────────────────────────────────────────────────────
-- Build the API prompt dynamically from selected panels
-- ─────────────────────────────────────────────────────────
local function buildPrompt(settingsText, modules, stylePrompt)
    local schema = {}
    local ranges = {}

    schema[#schema + 1] = '{'
    schema[#schema + 1] = '  "style_applied": "brief label for the edit applied",'
    schema[#schema + 1] = '  "reasoning": "2-3 sentences on what you saw and the choices you made"'

    if modules.useWhiteBalance then
        schema[#schema + 1] = ' ,"white_balance": { "temperature": 5500, "tint": 0 }'
        ranges[#ranges + 1] = '- white_balance.temperature: 2000-50000 (integer)'
        ranges[#ranges + 1] = '- white_balance.tint: -150 to +150 (integer)'
    end

    if modules.useTone then
        schema[#schema + 1] = ' ,"tone": { "exposure": 0.00, "contrast": 0, "highlights": 0, "shadows": 0, "whites": 0, "blacks": 0 }'
        ranges[#ranges + 1] = '- tone.exposure: -5.00 to +5.00 (float, 2 decimal places)'
        ranges[#ranges + 1] = '- tone.contrast / highlights / shadows / whites / blacks: -100 to +100 (integer)'
    end

    if modules.usePresence then
        schema[#schema + 1] = ' ,"presence": { "clarity": 0, "vibrance": 0, "saturation": 0 }'
        ranges[#ranges + 1] = '- presence.clarity / vibrance / saturation: -100 to +100 (integer)'
    end

    if modules.useToneCurve then
        schema[#schema + 1] = ' ,"tone_curve": { "shadows": 0, "darks": 0, "lights": 0, "highlights": 0 }'
        ranges[#ranges + 1] = '- tone_curve.shadows / darks / lights / highlights: -100 to +100 (integer)'
    end

    if modules.useHSL then
        schema[#schema + 1] = ' ,"hsl": {'
        schema[#schema + 1] = '    "hue":        { "Red":0,"Orange":0,"Yellow":0,"Green":0,"Aqua":0,"Blue":0,"Purple":0,"Magenta":0 },'
        schema[#schema + 1] = '    "saturation": { "Red":0,"Orange":0,"Yellow":0,"Green":0,"Aqua":0,"Blue":0,"Purple":0,"Magenta":0 },'
        schema[#schema + 1] = '    "luminance":  { "Red":0,"Orange":0,"Yellow":0,"Green":0,"Aqua":0,"Blue":0,"Purple":0,"Magenta":0 }'
        schema[#schema + 1] = '  }'
        ranges[#ranges + 1] = '- hsl hue / saturation / luminance values: -100 to +100 (integer)'
    end

    if modules.useColorGrading then
        schema[#schema + 1] = ' ,"color_grading": { "shadows_hue":0,"shadows_sat":0,"midtones_hue":0,"midtones_sat":0,"highlights_hue":0,"highlights_sat":0,"balance":0 }'
        ranges[#ranges + 1] = '- color_grading shadows/midtones/highlights _hue: 0-360 (integer, degrees)'
        ranges[#ranges + 1] = '- color_grading shadows/midtones/highlights _sat: 0-100 (integer)'
        ranges[#ranges + 1] = '- color_grading.balance: -100 to +100 (integer)'
    end

    if modules.useDetail then
        schema[#schema + 1] = ' ,"detail": { "sharpness":25,"radius":1.0,"detail_amount":25,"masking":0,"luminance_nr":0,"luminance_nr_detail":50,"luminance_nr_contrast":0,"color_nr":25,"color_nr_detail":50,"color_nr_smoothness":50 }'
        ranges[#ranges + 1] = '- detail.sharpness: 0-150 (integer)'
        ranges[#ranges + 1] = '- detail.radius: 0.5-3.0 (float, 1 decimal place)'
        ranges[#ranges + 1] = '- detail.detail_amount / masking: 0-100 (integer)'
        ranges[#ranges + 1] = '- detail.luminance_nr / luminance_nr_detail / luminance_nr_contrast: 0-100 (integer)'
        ranges[#ranges + 1] = '- detail.color_nr / color_nr_detail / color_nr_smoothness: 0-100 (integer)'
    end

    schema[#schema + 1] = '}'

    return string.format([[Analyse this photo and apply an edit that matches the style target below.

STYLE TARGET: %s

CURRENT LIGHTROOM SETTINGS (for context — the full state of the photo):
%s

Respond with ONLY valid JSON — no markdown, no code fences, no extra text.
Include ONLY the keys shown in the schema — do not add any other keys.

JSON schema:
%s

Value ranges:
%s]], stylePrompt, settingsText, table.concat(schema, '\n'), table.concat(ranges, '\n'))
end

-- ─────────────────────────────────────────────────────────
-- Anthropic API call
-- ─────────────────────────────────────────────────────────
local SYSTEM_PROMPT = [[You are an expert photographer and photo editor with deep knowledge of Lightroom Classic develop settings and photographic aesthetics.

Your task is to analyse a photo and apply an edit that matches the requested style target. You have full access to both the image and the photo's current develop settings.

Guidelines:
- Study the image carefully: its lighting quality, colour palette, mood, subject matter, and existing adjustments
- Your edit should be intentional and cohesive — every adjustment should serve the overall look
- Enhance the image's inherent character rather than fighting it
- All values must be strictly within their documented Lightroom ranges
- Be conservative with exposure changes (±1.5 EV max) unless drama is explicitly requested
- Hue values in Color Grading are in degrees 0-360; saturation values are 0-100
- For Detail: only increase sharpening/noise reduction meaningfully if the style or image genuinely calls for it]]

local function callClaudeAPI(jpegData, currentSettings, apiKey, model, modules, stylePrompt)
    local b64          = base64Encode(jpegData)
    local settingsText = settingsSummary(currentSettings)
    local userPrompt   = buildPrompt(settingsText, modules, stylePrompt)

    local requestBody = json.encode({
        model      = model,
        max_tokens = 2048,
        system     = SYSTEM_PROMPT,
        messages   = {
            {
                role    = 'user',
                content = {
                    { type = 'image', source = { type = 'base64', media_type = 'image/jpeg', data = b64 } },
                    { type = 'text',  text   = userPrompt },
                },
            },
        },
    })

    local headers = {
        { field = 'Content-Type',      value = 'application/json' },
        { field = 'x-api-key',         value = apiKey             },
        { field = 'anthropic-version', value = '2023-06-01'       },
    }

    local responseBody, responseHeaders = LrHttp.post(
        'https://api.anthropic.com/v1/messages', requestBody, headers)

    if not responseBody then
        return nil, 'Network error: no response received from Anthropic'
    end

    if responseHeaders and responseHeaders.status ~= 200 then
        local detail  = ''
        local errData = json.decode(responseBody)
        if errData and errData.error then
            detail = '\n' .. (errData.error.message or errData.error.type or '')
        elseif responseBody and #responseBody > 0 then
            detail = '\nRaw: ' .. responseBody:sub(1, 400)
        end
        return nil, 'API error ' .. tostring(responseHeaders.status) .. detail
    end

    local apiResp = json.decode(responseBody)
    if not apiResp then return nil, 'Could not parse API response as JSON' end
    if not (apiResp.content and apiResp.content[1] and apiResp.content[1].text) then
        return nil, 'Unexpected API response structure'
    end

    local claudeText = apiResp.content[1].text

    -- Strip code fences if Claude wrapped its response
    claudeText = claudeText:match('```json%s*(.-)%s*```')
              or claudeText:match('```%s*(.-)%s*```')
              or claudeText
    claudeText = claudeText:match('^%s*(.-)%s*$')

    -- Strip leading '+' from positive numbers (not valid JSON)
    claudeText = claudeText:gsub('([:%[,]%s*)%+(%d)', '%1%2')

    local result = json.decode(claudeText)
    if not result then
        -- Try extracting the outermost { … } in case Claude prepended prose
        local s = claudeText:find('{', 1, true)
        local e = claudeText:match('.*()%}')
        if s and e and e >= s then result = json.decode(claudeText:sub(s, e)) end
    end
    if not result then
        return nil, 'Could not parse JSON from Claude response.\nRaw: ' .. claudeText:sub(1, 400)
    end

    return result, nil
end

-- ─────────────────────────────────────────────────────────
-- Apply settings to photo
-- No pcall — Lua 5.1 forbids yield inside pcall and catalog
-- ops yield internally. Use a boolean flag instead.
-- ─────────────────────────────────────────────────────────
local function applySettings(catalog, photo, result, modules)
    local ns = {}  -- new settings table

    if modules.useWhiteBalance and result.white_balance then
        ns.WhiteBalance = 'Custom'
        ns.Temperature  = clampInt(result.white_balance.temperature, 2000, 50000)
        ns.Tint         = clampInt(result.white_balance.tint,        -150, 150)
    end

    if modules.useTone and result.tone then
        ns.Exposure2012   = clampFloat(result.tone.exposure,   -5,   5, 2)
        ns.Contrast2012   = clampInt(result.tone.contrast,    -100, 100)
        ns.Highlights2012 = clampInt(result.tone.highlights,  -100, 100)
        ns.Shadows2012    = clampInt(result.tone.shadows,     -100, 100)
        ns.Whites2012     = clampInt(result.tone.whites,      -100, 100)
        ns.Blacks2012     = clampInt(result.tone.blacks,      -100, 100)
    end

    if modules.usePresence and result.presence then
        ns.Clarity2012 = clampInt(result.presence.clarity,    -100, 100)
        ns.Vibrance    = clampInt(result.presence.vibrance,   -100, 100)
        ns.Saturation  = clampInt(result.presence.saturation, -100, 100)
    end

    if modules.useToneCurve and result.tone_curve then
        ns.ParametricShadows    = clampInt(result.tone_curve.shadows,    -100, 100)
        ns.ParametricDarks      = clampInt(result.tone_curve.darks,      -100, 100)
        ns.ParametricLights     = clampInt(result.tone_curve.lights,     -100, 100)
        ns.ParametricHighlights = clampInt(result.tone_curve.highlights, -100, 100)
    end

    if modules.useHSL and result.hsl then
        for _, color in ipairs(HSL_COLORS) do
            ns['HueAdjustment'        .. color] = clampInt(result.hsl.hue        and result.hsl.hue[color],        -100, 100)
            ns['SaturationAdjustment' .. color] = clampInt(result.hsl.saturation and result.hsl.saturation[color], -100, 100)
            ns['LuminanceAdjustment'  .. color] = clampInt(result.hsl.luminance  and result.hsl.luminance[color],  -100, 100)
        end
    end

    if modules.useColorGrading and result.color_grading then
        local cg = result.color_grading
        ns.ColorGradeShadowHue    = clampInt(cg.shadows_hue,    0, 360)
        ns.ColorGradeShadowSat    = clampInt(cg.shadows_sat,    0, 100)
        ns.ColorGradeMidtoneHue   = clampInt(cg.midtones_hue,   0, 360)
        ns.ColorGradeMidtoneSat   = clampInt(cg.midtones_sat,   0, 100)
        ns.ColorGradeHighlightHue = clampInt(cg.highlights_hue, 0, 360)
        ns.ColorGradeHighlightSat = clampInt(cg.highlights_sat, 0, 100)
        ns.ColorGradeBalance      = clampInt(cg.balance,       -100, 100)
        -- Legacy Split Toning keys (LR < 10)
        ns.ShadowHue              = ns.ColorGradeShadowHue
        ns.ShadowSaturation       = ns.ColorGradeShadowSat
        ns.HighlightHue           = ns.ColorGradeHighlightHue
        ns.HighlightSaturation    = ns.ColorGradeHighlightSat
        ns.SplitToningBalance     = ns.ColorGradeBalance
    end

    if modules.useDetail and result.detail then
        local d = result.detail
        ns.Sharpness                   = clampInt(d.sharpness,               0, 150)
        ns.SharpenRadius               = clampFloat(d.radius,               0.5, 3.0, 1)
        ns.SharpenDetail               = clampInt(d.detail_amount,           0, 100)
        ns.SharpenEdgeMasking          = clampInt(d.masking,                 0, 100)
        ns.LuminanceSmoothing          = clampInt(d.luminance_nr,            0, 100)
        ns.LuminanceDetail             = clampInt(d.luminance_nr_detail,     0, 100)
        ns.LuminanceContrast           = clampInt(d.luminance_nr_contrast,   0, 100)
        ns.ColorNoiseReduction         = clampInt(d.color_nr,                0, 100)
        ns.ColorNoiseReductionDetail   = clampInt(d.color_nr_detail,         0, 100)
        ns.ColorNoiseReductionSmoothness = clampInt(d.color_nr_smoothness,   0, 100)
    end

    local writeOk = false
    catalog:withWriteAccessDo('Claude AI: Photo Edit', function()
        photo:applyDevelopSettings(ns)
        writeOk = true
    end)

    return writeOk, ns
end

-- ─────────────────────────────────────────────────────────
-- Build a before→after summary for the result dialog
-- ─────────────────────────────────────────────────────────
local function buildSummary(old, new, result, modules)
    local lines = {}

    local function diff(label, oldVal, newVal, fmt)
        fmt = fmt or '%g'
        if oldVal ~= newVal then
            lines[#lines + 1] = string.format(
                '  %-30s ' .. fmt .. ' -> ' .. fmt .. '  (%+g)',
                label, oldVal, newVal, newVal - oldVal)
        end
    end

    lines[#lines + 1] = 'STYLE: ' .. (result.style_applied or 'Custom')
    lines[#lines + 1] = ''

    if modules.useWhiteBalance and new.Temperature ~= nil then
        lines[#lines + 1] = 'WHITE BALANCE'
        diff('Temperature (K)', old.Temperature, new.Temperature, '%d')
        diff('Tint',            old.Tint,        new.Tint,        '%+d')
        lines[#lines + 1] = ''
    end

    if modules.useTone and new.Exposure2012 ~= nil then
        lines[#lines + 1] = 'BASIC TONE'
        diff('Exposure',   old.Exposure2012,   new.Exposure2012,   '%.2f')
        diff('Contrast',   old.Contrast2012,   new.Contrast2012,   '%+d')
        diff('Highlights', old.Highlights2012, new.Highlights2012, '%+d')
        diff('Shadows',    old.Shadows2012,    new.Shadows2012,    '%+d')
        diff('Whites',     old.Whites2012,     new.Whites2012,     '%+d')
        diff('Blacks',     old.Blacks2012,     new.Blacks2012,     '%+d')
        lines[#lines + 1] = ''
    end

    if modules.usePresence and new.Clarity2012 ~= nil then
        lines[#lines + 1] = 'PRESENCE'
        diff('Clarity',    old.Clarity2012, new.Clarity2012, '%+d')
        diff('Vibrance',   old.Vibrance,    new.Vibrance,    '%+d')
        diff('Saturation', old.Saturation,  new.Saturation,  '%+d')
        lines[#lines + 1] = ''
    end

    if modules.useToneCurve and new.ParametricShadows ~= nil then
        lines[#lines + 1] = 'TONE CURVE'
        diff('Shadows',    old.ParametricShadows,    new.ParametricShadows,    '%+d')
        diff('Darks',      old.ParametricDarks,      new.ParametricDarks,      '%+d')
        diff('Lights',     old.ParametricLights,     new.ParametricLights,     '%+d')
        diff('Highlights', old.ParametricHighlights, new.ParametricHighlights, '%+d')
        lines[#lines + 1] = ''
    end

    if modules.useHSL then
        local hslChanged = {}
        for _, color in ipairs(HSL_COLORS) do
            local hO = old['HueAdjustment'        .. color] or 0
            local sO = old['SaturationAdjustment' .. color] or 0
            local lO = old['LuminanceAdjustment'  .. color] or 0
            local hN = new['HueAdjustment'        .. color] or hO
            local sN = new['SaturationAdjustment' .. color] or sO
            local lN = new['LuminanceAdjustment'  .. color] or lO
            if hO ~= hN or sO ~= sN or lO ~= lN then
                hslChanged[#hslChanged + 1] = string.format(
                    '  %-8s  H:%+d->%+d  S:%+d->%+d  L:%+d->%+d',
                    color, hO, hN, sO, sN, lO, lN)
            end
        end
        if #hslChanged > 0 then
            lines[#lines + 1] = 'HSL (changed channels)'
            for _, l in ipairs(hslChanged) do lines[#lines + 1] = l end
            lines[#lines + 1] = ''
        end
    end

    if modules.useColorGrading and new.ColorGradeShadowHue ~= nil then
        local cgChanged = (old.CGShadowHue    ~= new.ColorGradeShadowHue)    or
                          (old.CGShadowSat    ~= new.ColorGradeShadowSat)    or
                          (old.CGMidtoneHue   ~= new.ColorGradeMidtoneHue)   or
                          (old.CGMidtoneSat   ~= new.ColorGradeMidtoneSat)   or
                          (old.CGHighlightHue ~= new.ColorGradeHighlightHue) or
                          (old.CGHighlightSat ~= new.ColorGradeHighlightSat) or
                          (old.CGBalance      ~= new.ColorGradeBalance)
        if cgChanged then
            lines[#lines + 1] = 'COLOR GRADING'
            lines[#lines + 1] = string.format('  Shadows    H:%d->%d  S:%d->%d',
                old.CGShadowHue,    new.ColorGradeShadowHue,
                old.CGShadowSat,    new.ColorGradeShadowSat)
            lines[#lines + 1] = string.format('  Midtones   H:%d->%d  S:%d->%d',
                old.CGMidtoneHue,   new.ColorGradeMidtoneHue,
                old.CGMidtoneSat,   new.ColorGradeMidtoneSat)
            lines[#lines + 1] = string.format('  Highlights H:%d->%d  S:%d->%d',
                old.CGHighlightHue, new.ColorGradeHighlightHue,
                old.CGHighlightSat, new.ColorGradeHighlightSat)
            lines[#lines + 1] = string.format('  Balance    %+d->%+d',
                old.CGBalance, new.ColorGradeBalance)
            lines[#lines + 1] = ''
        end
    end

    if modules.useDetail and new.Sharpness ~= nil then
        local detailChanged = (old.Sharpness     ~= new.Sharpness)          or
                              (old.SharpenRadius ~= new.SharpenRadius)       or
                              (old.SharpenDetail ~= new.SharpenDetail)       or
                              (old.SharpenEdgeMasking ~= new.SharpenEdgeMasking) or
                              (old.LuminanceSmoothing ~= new.LuminanceSmoothing) or
                              (old.ColorNoiseReduction ~= new.ColorNoiseReduction)
        if detailChanged then
            lines[#lines + 1] = 'DETAIL'
            diff('Sharpness',        old.Sharpness,          new.Sharpness,          '%d')
            diff('Radius',           old.SharpenRadius,      new.SharpenRadius,      '%.1f')
            diff('Detail',           old.SharpenDetail,      new.SharpenDetail,      '%d')
            diff('Masking',          old.SharpenEdgeMasking, new.SharpenEdgeMasking, '%d')
            diff('Lum Noise Reduce', old.LuminanceSmoothing, new.LuminanceSmoothing, '%d')
            diff('Color Noise Reduce', old.ColorNoiseReduction, new.ColorNoiseReduction, '%d')
            lines[#lines + 1] = ''
        end
    end

    if type(result.reasoning) == 'string' and #result.reasoning > 0 then
        lines[#lines + 1] = "CLAUDE'S REASONING"
        lines[#lines + 1] = result.reasoning
    end

    return table.concat(lines, '\n')
end

-- ─────────────────────────────────────────────────────────
-- Entry point
-- All UI (pre-flight dialog + progress scope) share ONE
-- callWithContext so Lightroom's binding cleanup never
-- fires between the dialog exit and the first catalog write.
-- ─────────────────────────────────────────────────────────
LrTasks.startAsyncTask(function()

    local apiKey = pluginPrefs.claudeApiKey
    if not apiKey or LrStringUtils.trimWhitespace(apiKey) == '' then
        LrDialogs.message(
            'Claude AI Photo Edit',
            'No API key found.\n\nGo to  File \226\150\184 Plug-in Extras \226\150\184 Claude Edit Settings  to enter your Anthropic API key.',
            'critical')
        return
    end

    local catalog    = LrApplication.activeCatalog()
    local photos     = catalog:getTargetPhotos()

    if not photos or #photos == 0 then
        LrDialogs.message('Claude AI Photo Edit',
            'No photos selected. Select one or more photos and try again.', 'info')
        return
    end

    local model      = pluginPrefs.claudeModel    or 'claude-opus-4-5'
    local thumbSize  = tonumber(pluginPrefs.thumbnailSize) or 1024
    local photoCount = #photos

    -- Single context covers the pre-flight dialog AND the batch loop.
    -- Keeping both inside one callWithContext prevents LR's binding
    -- teardown from running between dialog close and the first write.
    LrFunctionContext.callWithContext('claudePhotoEdit', function(context)

        -- ── Pre-flight dialog ──────────────────────────────────
        local f     = LrView.osFactory()
        local props = LrBinding.makePropertyTable(context)

        -- Load persisted values; most panels on by default, Detail off by default
        props.stylePrompt     = pluginPrefs.stylePrompt     or ''
        props.useWhiteBalance = pluginPrefs.useWhiteBalance ~= false
        props.useTone         = pluginPrefs.useTone         ~= false
        props.usePresence     = pluginPrefs.usePresence     ~= false
        props.useToneCurve    = pluginPrefs.useToneCurve    ~= false
        props.useHSL          = pluginPrefs.useHSL          ~= false
        props.useColorGrading = pluginPrefs.useColorGrading ~= false
        props.useDetail       = pluginPrefs.useDetail       == true

        -- Prompt history picker
        local history       = loadPromptHistory()
        props.historyItems  = historyMenuItems(history)
        props.historyPick   = 0
        props.hasHistory    = #history > 0
        props:addObserver('historyPick', function(_, _, value)
            local idx = tonumber(value) or 0
            if idx > 0 and history[idx] then
                props.stylePrompt = history[idx]
                props.historyPick = 0   -- reset so the same entry can be picked again
            end
        end)

        local contents = f:column {
            bind_to_object = props,
            spacing        = f:dialog_spacing(),

            f:group_box {
                title           = 'Style',
                fill_horizontal = 1,
                f:column {
                    spacing         = f:label_spacing(),
                    fill_horizontal = 1,
                    f:row {
                        fill_horizontal = 1,
                        f:popup_menu {
                            items           = LrView.bind 'historyItems',
                            value           = LrView.bind 'historyPick',
                            enabled         = LrView.bind 'hasHistory',
                            fill_horizontal = 1,
                            width_in_chars  = 50,
                        },
                        f:push_button {
                            title   = 'Clear History',
                            enabled = LrView.bind 'hasHistory',
                            action  = function()
                              LrTasks.startAsyncTask(function()
                                local confirm = LrDialogs.confirm(
                                    'Clear prompt history?',
                                    'This removes all ' .. #history .. ' saved prompts.',
                                    'Clear', 'Cancel')
                                if confirm == 'ok' then
                                    history = {}
                                    savePromptHistory(history)
                                    props.historyItems = historyMenuItems(history)
                                    props.historyPick  = 0
                                    props.hasHistory   = false
                                end
                              end)
                            end,
                        },
                    },
                    f:edit_field {
                        value           = LrView.bind 'stylePrompt',
                        fill_horizontal = 1,
                        height_in_lines = 4,
                        width_in_chars  = 60,
                    },
                    f:static_text {
                        title = 'Tip: describe mood, colour palette, and contrast together for the best results.\n' ..
                                'e.g. "moody cinematic with teal shadows and warm highlights" or "bright airy portrait, lifted blacks, clean whites"',
                        font  = '<system/small>',
                    },
                },
            },

            f:group_box {
                title           = 'Panels Claude may adjust',
                fill_horizontal = 1,
                f:column {
                    spacing = f:label_spacing(),
                    f:checkbox { title = 'White Balance  (Temperature, Tint)',
                                 value = LrView.bind 'useWhiteBalance' },
                    f:checkbox { title = 'Basic Tone  (Exposure, Contrast, Highlights, Shadows, Whites, Blacks)',
                                 value = LrView.bind 'useTone' },
                    f:checkbox { title = 'Presence  (Clarity, Vibrance, Saturation)',
                                 value = LrView.bind 'usePresence' },
                    f:checkbox { title = 'Tone Curve  (Parametric: Shadows, Darks, Lights, Highlights)',
                                 value = LrView.bind 'useToneCurve' },
                    f:checkbox { title = 'HSL Color Mixer  (Hue, Saturation, Luminance for all 8 colour channels)',
                                 value = LrView.bind 'useHSL' },
                    f:checkbox { title = 'Color Grading  (Shadows, Midtones, Highlights hue/sat; Balance)',
                                 value = LrView.bind 'useColorGrading' },
                    f:checkbox { title = 'Detail  (Sharpening + Noise Reduction)',
                                 value = LrView.bind 'useDetail' },
                },
            },

            f:static_text {
                title = string.format(
                    '%d photo%s selected. Panel selections and your last 100 prompts are remembered. Use Develop \226\150\184 History to undo.',
                    photoCount, photoCount == 1 and '' or 's'),
                font = '<system/small>',
            },
        }

        local dlgResult = LrDialogs.presentModalDialog({
            title      = 'Edit with Claude AI',
            contents   = contents,
            actionVerb = 'Apply Edit',
            cancelVerb = 'Cancel',
        })

        if dlgResult ~= 'ok' then return end

        -- Validate panel selection
        local style = LrStringUtils.trimWhitespace(props.stylePrompt or '')
        local userTyped = style ~= ''
        if not userTyped then style = 'Natural and well-balanced' end

        local anyPanel = props.useWhiteBalance or props.useTone      or
                         props.usePresence     or props.useToneCurve or
                         props.useHSL          or props.useColorGrading or
                         props.useDetail
        if not anyPanel then
            LrDialogs.message(
                'Edit with Claude AI',
                'Please select at least one panel for Claude to adjust.',
                'warning')
            return
        end

        -- Persist for next run
        pluginPrefs.stylePrompt     = style
        if userTyped then addToPromptHistory(style) end
        pluginPrefs.useWhiteBalance = props.useWhiteBalance
        pluginPrefs.useTone         = props.useTone
        pluginPrefs.usePresence     = props.usePresence
        pluginPrefs.useToneCurve    = props.useToneCurve
        pluginPrefs.useHSL          = props.useHSL
        pluginPrefs.useColorGrading = props.useColorGrading
        pluginPrefs.useDetail       = props.useDetail

        -- Plain Lua table — no dependency on the LrBinding property table
        local editParams = {
            stylePrompt     = style,
            useWhiteBalance = props.useWhiteBalance,
            useTone         = props.useTone,
            usePresence     = props.usePresence,
            useToneCurve    = props.useToneCurve,
            useHSL          = props.useHSL,
            useColorGrading = props.useColorGrading,
            useDetail       = props.useDetail,
        }

        -- ── Batch loop ─────────────────────────────────────────
        local progress = LrProgressScope({
            title           = 'Claude AI: Editing photo' .. (photoCount > 1 and 's' or ''),
            functionContext = context,
        })

        local successCount = 0
        local errors       = {}
        local summaries    = {}

        -- Use explicit numeric loop — avoids any ipairs/table edge cases
        -- in Lightroom's photo-array return value.
        for i = 1, photoCount do
            if progress:isCanceled() then break end

            local photo    = photos[i]
            local fileName = photo:getFormattedMetadata('fileName') or ('photo ' .. i)
            progress:setPortionComplete(i - 1, photoCount)
            progress:setCaption(string.format('%s  (%d / %d)', fileName, i, photoCount))
            LrTasks.yield()

            -- Read current settings (outside write access — may yield)
            local currentSettings = readCurrentSettings(photo)

            -- Get thumbnail
            local jpegData, thumbErr = getPhotoThumbnail(photo, thumbSize)
            if not jpegData then
                errors[#errors + 1] = string.format('%-40s  preview error: %s', fileName, thumbErr or '?')
            else
                -- Call Claude
                local result, apiErr = callClaudeAPI(
                    jpegData, currentSettings, apiKey, model, editParams, editParams.stylePrompt)
                if not result then
                    errors[#errors + 1] = string.format('%-40s  API error: %s', fileName, apiErr or '?')
                else
                    -- Apply (no pcall — catalog ops yield internally in Lua 5.1)
                    local written, newSettings = applySettings(catalog, photo, result, editParams)
                    if written then
                        successCount = successCount + 1
                        summaries[#summaries + 1] = {
                            fileName = fileName,
                            summary  = buildSummary(currentSettings, newSettings, result, editParams),
                        }
                    else
                        errors[#errors + 1] = string.format('%-40s  write failed', fileName)
                    end
                end
            end

            -- Brief pause between photos (not after the last one)
            if i < photoCount and not progress:isCanceled() then
                LrTasks.sleep(0.5)
            end
        end

        progress:done()

        -- ── Results dialog ─────────────────────────────────────
        local parts = {}
        parts[#parts + 1] = string.format(
            '%d of %d photo%s edited successfully.',
            successCount, photoCount, photoCount == 1 and '' or 's')

        for _, s in ipairs(summaries) do
            parts[#parts + 1] = '\n\226\148\128\226\148\128\226\148\128 ' .. s.fileName .. ' \226\148\128\226\148\128\226\148\128'
            parts[#parts + 1] = s.summary
        end

        if #errors > 0 then
            parts[#parts + 1] = '\nFailed (' .. #errors .. '):'
            parts[#parts + 1] = table.concat(errors, '\n')
        end

        LrDialogs.message(
            'Claude AI Photo Edit \226\128\148 Done',
            table.concat(parts, '\n'),
            #errors > 0 and 'warning' or 'info')

    end)
end)
