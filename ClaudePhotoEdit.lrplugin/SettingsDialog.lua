--[[
  Claude AI Photo Edit for Lightroom Classic
  SettingsDialog.lua — Plug-in settings

  Stores in plugin prefs (read by ClaudeEdit.lua):
    - claudeApiKey   Anthropic API key
    - claudeModel    Model ID sent to the Messages API
    - thumbnailSize  Longest side (px) of the preview sent to Claude

  "Test Connection" sends a tiny text-only request to confirm the
  key and model are accepted before running a real edit.
--]]

local LrBinding          = import 'LrBinding'
local LrDialogs          = import 'LrDialogs'
local LrFunctionContext  = import 'LrFunctionContext'
local LrHttp             = import 'LrHttp'
local LrPrefs            = import 'LrPrefs'
local LrStringUtils      = import 'LrStringUtils'
local LrTasks            = import 'LrTasks'
local LrView             = import 'LrView'

local json = require 'json'

local pluginPrefs = LrPrefs.prefsForPlugin()

local DEFAULT_MODEL      = 'claude-opus-4-5'
local DEFAULT_THUMB_SIZE = 1024

-- Suggested models; the field is editable so any model ID can be entered.
local MODEL_ITEMS = {
    'claude-opus-5-5',
    'claude-sonnet-5-5',
    'claude-haiku-5-5',
    'claude-opus-4-5',
}

local THUMB_ITEMS = {
    { title = '512 px  (fastest, lowest cost)', value = 512  },
    { title = '768 px',                          value = 768  },
    { title = '1024 px  (recommended)',          value = 1024 },
    { title = '1568 px',                         value = 1568 },
    { title = '2048 px  (most detail)',          value = 2048 },
}

-- ─────────────────────────────────────────────────────────
-- Minimal API request to validate key + model
-- ─────────────────────────────────────────────────────────
local function testConnection(apiKey, model)
    local body = json.encode({
        model      = model,
        max_tokens = 16,
        messages   = { { role = 'user', content = 'Reply with OK.' } },
    })
    local headers = {
        { field = 'Content-Type',      value = 'application/json' },
        { field = 'x-api-key',         value = apiKey             },
        { field = 'anthropic-version', value = '2023-06-01'       },
    }

    local responseBody, responseHeaders = LrHttp.post(
        'https://api.anthropic.com/v1/messages', body, headers)

    if not responseBody then
        return false, 'Network error: no response received from Anthropic.'
    end
    if responseHeaders and responseHeaders.status ~= 200 then
        local detail  = ''
        local errData = json.decode(responseBody)
        if errData and errData.error then
            detail = '\n' .. (errData.error.message or errData.error.type or '')
        end
        return false, 'API error ' .. tostring(responseHeaders.status) .. detail
    end
    return true, nil
end

-- ─────────────────────────────────────────────────────────
-- Dialog
-- ─────────────────────────────────────────────────────────
LrFunctionContext.postAsyncTaskWithContext('claudeEditSettings', function(context)
    local f     = LrView.osFactory()
    local props = LrBinding.makePropertyTable(context)

    props.apiKey     = pluginPrefs.claudeApiKey or ''
    props.model      = pluginPrefs.claudeModel  or DEFAULT_MODEL
    props.thumbSize  = tonumber(pluginPrefs.thumbnailSize) or DEFAULT_THUMB_SIZE
    props.testStatus = ''

    local contents = f:column {
        bind_to_object = props,
        spacing        = f:dialog_spacing(),

        f:group_box {
            title           = 'Anthropic API',
            fill_horizontal = 1,
            f:column {
                spacing = f:label_spacing(),
                f:row {
                    f:static_text { title = 'API key:', alignment = 'right', width = LrView.share 'labelWidth' },
                    f:password_field {
                        value          = LrView.bind 'apiKey',
                        width_in_chars = 45,
                    },
                },
                f:row {
                    f:static_text { title = 'Model:', alignment = 'right', width = LrView.share 'labelWidth' },
                    f:combo_box {
                        value          = LrView.bind 'model',
                        items          = MODEL_ITEMS,
                        width_in_chars = 30,
                        immediate      = true,
                    },
                },
                f:row {
                    f:static_text { title = '', width = LrView.share 'labelWidth' },
                    f:static_text {
                        title = 'Get a key at console.anthropic.com. Usage is billed to your Anthropic account.',
                        font  = '<system/small>',
                    },
                },
                f:row {
                    f:static_text { title = '', width = LrView.share 'labelWidth' },
                    f:push_button {
                        title  = 'Test Connection',
                        action = function()
                            LrTasks.startAsyncTask(function()
                                local key   = LrStringUtils.trimWhitespace(props.apiKey or '')
                                local model = LrStringUtils.trimWhitespace(props.model or '')
                                if key == '' then
                                    props.testStatus = 'Enter an API key first.'
                                    return
                                end
                                if model == '' then model = DEFAULT_MODEL end
                                props.testStatus = 'Testing\226\128\166'
                                local ok, err = testConnection(key, model)
                                if ok then
                                    props.testStatus = 'Connected \226\128\148 ' .. model .. ' is ready.'
                                else
                                    props.testStatus = ''
                                    LrDialogs.message('Test Connection Failed', err, 'critical')
                                end
                            end)
                        end,
                    },
                    f:static_text {
                        title          = LrView.bind 'testStatus',
                        width_in_chars = 35,
                    },
                },
            },
        },

        f:group_box {
            title           = 'Preview',
            fill_horizontal = 1,
            f:column {
                spacing = f:label_spacing(),
                f:row {
                    f:static_text { title = 'Size sent:', alignment = 'right', width = LrView.share 'labelWidth' },
                    f:popup_menu {
                        value = LrView.bind 'thumbSize',
                        items = THUMB_ITEMS,
                    },
                },
                f:row {
                    f:static_text { title = '', width = LrView.share 'labelWidth' },
                    f:static_text {
                        title = 'Longest side of the JPEG preview sent to Claude. Larger previews\n' ..
                                'show more detail but cost more and take longer.',
                        font  = '<system/small>',
                    },
                },
            },
        },
    }

    local result = LrDialogs.presentModalDialog({
        title      = 'Claude Edit Settings',
        contents   = contents,
        actionVerb = 'Save',
        cancelVerb = 'Cancel',
    })

    if result ~= 'ok' then return end

    local model = LrStringUtils.trimWhitespace(props.model or '')
    pluginPrefs.claudeApiKey  = LrStringUtils.trimWhitespace(props.apiKey or '')
    pluginPrefs.claudeModel   = (model ~= '') and model or DEFAULT_MODEL
    pluginPrefs.thumbnailSize = tonumber(props.thumbSize) or DEFAULT_THUMB_SIZE
end)
