--[[
  json.lua — Pure-Lua JSON encoder / decoder
  Compatible with Lua 5.1 (Lightroom Classic).

  Avoids null-byte patterns and character-class ranges that break
  Lua 5.1's pattern engine.

  Usage:
    local json = require 'json'
    local str  = json.encode({ key = "value", nums = {1,2,3} })
    local tbl  = json.decode(str)
--]]

local json = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- ENCODER
-- ─────────────────────────────────────────────────────────────────────────────

-- Fast lookup table for the characters that need a named escape sequence.
local NAMED_ESC = {
    ['"']  = '\\"',
    ['\\'] = '\\\\',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
}

-- Iterate byte-by-byte — avoids any Lua 5.1 pattern with null bytes or
-- problematic character-class ranges.
local function escapeString(s)
    local out = {}
    for i = 1, #s do
        local c = s:sub(i, i)
        local esc = NAMED_ESC[c]
        if esc then
            out[#out + 1] = esc
        elseif c:byte() < 32 then
            -- Other ASCII control characters → \u00XX
            out[#out + 1] = string.format('\\u%04x', c:byte())
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

-- Return true when the table should be encoded as a JSON array.
local function isArray(t)
    local max, count = 0, 0
    for k in pairs(t) do
        if type(k) ~= 'number' or k ~= math.floor(k) or k < 1 then
            return false
        end
        if k > max then max = k end
        count = count + 1
    end
    return count == max
end

local encodeValue  -- forward declaration

local function encodeTable(t)
    if isArray(t) then
        local parts = {}
        for i = 1, #t do
            parts[i] = encodeValue(t[i])
        end
        return '[' .. table.concat(parts, ',') .. ']'
    else
        local parts = {}
        for k, v in pairs(t) do
            if type(k) == 'string' then
                parts[#parts + 1] = '"' .. escapeString(k) .. '":' .. encodeValue(v)
            end
            -- non-string keys are silently skipped (JSON requires string keys)
        end
        table.sort(parts)  -- deterministic output order
        return '{' .. table.concat(parts, ',') .. '}'
    end
end

encodeValue = function(v)
    local t = type(v)
    if     t == 'nil'     then return 'null'
    elseif t == 'boolean' then return v and 'true' or 'false'
    elseif t == 'number'  then
        if v ~= v or v == math.huge or v == -math.huge then return 'null' end
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return string.format('%d', v)
        end
        return tostring(v)
    elseif t == 'string' then
        return '"' .. escapeString(v) .. '"'
    elseif t == 'table' then
        return encodeTable(v)
    else
        return 'null'
    end
end

--- Encode a Lua value as a JSON string.
function json.encode(v)
    return encodeValue(v)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- DECODER
-- ─────────────────────────────────────────────────────────────────────────────

-- Advance index past any whitespace characters.
local function skipWS(s, i)
    while i <= #s do
        local b = s:byte(i)
        -- space(32) tab(9) newline(10) CR(13)
        if b == 32 or b == 9 or b == 10 or b == 13 then
            i = i + 1
        else
            break
        end
    end
    return i
end

local decode  -- forward declaration

-- Decode a JSON string value; i must point at the opening '"'.
local function decodeString(s, i)
    i = i + 1  -- consume opening "
    local parts = {}
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(parts), i + 1
        elseif c == '\\' then
            local esc = s:sub(i + 1, i + 1)
            if     esc == '"'  then parts[#parts+1] = '"';  i = i + 2
            elseif esc == '\\' then parts[#parts+1] = '\\'; i = i + 2
            elseif esc == '/'  then parts[#parts+1] = '/';  i = i + 2
            elseif esc == 'n'  then parts[#parts+1] = '\n'; i = i + 2
            elseif esc == 'r'  then parts[#parts+1] = '\r'; i = i + 2
            elseif esc == 't'  then parts[#parts+1] = '\t'; i = i + 2
            elseif esc == 'b'  then parts[#parts+1] = '\b'; i = i + 2
            elseif esc == 'f'  then parts[#parts+1] = '\f'; i = i + 2
            elseif esc == 'u'  then
                -- \uXXXX → UTF-8
                local hex = s:sub(i + 2, i + 5)
                local cp  = tonumber(hex, 16) or 63  -- 63 = '?'
                if cp < 0x80 then
                    parts[#parts+1] = string.char(cp)
                elseif cp < 0x800 then
                    parts[#parts+1] = string.char(
                        0xC0 + math.floor(cp / 64),
                        0x80 + (cp % 64)
                    )
                else
                    parts[#parts+1] = string.char(
                        0xE0 + math.floor(cp / 4096),
                        0x80 + math.floor(cp / 64) % 64,
                        0x80 + (cp % 64)
                    )
                end
                i = i + 6
            else
                parts[#parts+1] = esc
                i = i + 2
            end
        else
            parts[#parts+1] = c
            i = i + 1
        end
    end
    error('JSON decode: unterminated string at position ' .. i)
end

-- Decode a JSON array; i must point at '['.
local function decodeArray(s, i)
    local arr = {}
    i = i + 1  -- consume '['
    i = skipWS(s, i)
    if s:sub(i, i) == ']' then return arr, i + 1 end
    while true do
        local val
        val, i = decode(s, i)
        arr[#arr + 1] = val
        i = skipWS(s, i)
        local ch = s:sub(i, i)
        if     ch == ']' then return arr, i + 1
        elseif ch == ',' then i = skipWS(s, i + 1)
        else   error('JSON decode: expected "," or "]" in array at position ' .. i)
        end
    end
end

-- Decode a JSON object; i must point at '{'.
local function decodeObject(s, i)
    local obj = {}
    i = i + 1  -- consume '{'
    i = skipWS(s, i)
    if s:sub(i, i) == '}' then return obj, i + 1 end
    while true do
        i = skipWS(s, i)
        if s:sub(i, i) ~= '"' then
            error('JSON decode: expected string key at position ' .. i)
        end
        local key
        key, i = decodeString(s, i)
        i = skipWS(s, i)
        if s:sub(i, i) ~= ':' then
            error('JSON decode: expected ":" after key at position ' .. i)
        end
        i = skipWS(s, i + 1)
        local val
        val, i = decode(s, i)
        obj[key] = val
        i = skipWS(s, i)
        local ch = s:sub(i, i)
        if     ch == '}' then return obj, i + 1
        elseif ch == ',' then i = skipWS(s, i + 1)
        else   error('JSON decode: expected "," or "}" in object at position ' .. i)
        end
    end
end

-- Decode a JSON number; i points at '-' or a digit.
local function decodeNumber(s, i)
    -- Match optional minus, integer part, optional fraction, optional exponent
    local num = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', i)
    if not num then
        error('JSON decode: invalid number at position ' .. i)
    end
    return tonumber(num), i + #num
end

decode = function(s, i)
    i = skipWS(s, i)
    local ch = s:sub(i, i)
    if     ch == '"' then return decodeString(s, i)
    elseif ch == '[' then return decodeArray(s,  i)
    elseif ch == '{' then return decodeObject(s, i)
    elseif ch == 't' then
        if s:sub(i, i + 3) == 'true'  then return true,  i + 4 end
    elseif ch == 'f' then
        if s:sub(i, i + 4) == 'false' then return false, i + 5 end
    elseif ch == 'n' then
        if s:sub(i, i + 3) == 'null'  then return nil,   i + 4 end
    elseif ch == '-' or (ch >= '0' and ch <= '9') then
        return decodeNumber(s, i)
    end
    error('JSON decode: unexpected character "' .. ch .. '" at position ' .. i)
end

--- Decode a JSON string into a Lua value. Returns nil on parse error.
function json.decode(s)
    if type(s) ~= 'string' or s == '' then return nil end
    local ok, result = pcall(decode, s, 1)
    if ok then return result end
    return nil
end

return json
