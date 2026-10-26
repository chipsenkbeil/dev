local MAX_DEPTH = 200
local TAG = "json\0"
local ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}
local UNESCAPES =
    { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

---Read and write JSON.
---
---Integers beyond 2^53 lose precision. Invalid UTF-8 passes through decode and
---encode unchanged. A repeated object key keeps its last value.
---@class dev.json
---@field null table<string, any> sentinel for JSON null, which keeps array lengths whole
local M = {
    null = setmetatable({}, {
        __tostring = function()
            return "json.null"
        end,
    }),
}

---@class dev.json.EncodeOpts
---@field order? string[] keys that come first, in this order, at every level

local function utf8_char(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(
            0xE0 + math.floor(cp / 0x1000),
            0x80 + math.floor(cp / 0x40) % 0x40,
            0x80 + cp % 0x40
        )
    end
    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40,
        0x80 + cp % 0x40
    )
end

---Mark `t` so `encode` writes it as an object even when it is empty.
---@param t? table<string, any> fields to mark, a new table when omitted
---@return table<string, any> t the same table
function M.object(t)
    return setmetatable(t or {}, { __jsonobject = true })
end

local function raise(message)
    error(TAG .. message, 0)
end

local function fail(pos, message)
    raise(message .. " at offset " .. pos)
end

local function unwrap(err)
    if type(err) ~= "string" or err:sub(1, #TAG) ~= TAG then
        error(err, 0)
    end
    return err:sub(#TAG + 1)
end

local function skip(s, pos)
    return s:find("[^ \t\r\n]", pos) or #s + 1
end

local decode_value

local function decode_string(s, pos)
    local out, i = {}, pos + 1
    while true do
        local stop = s:find('["\\%z\1-\31]', i)
        if not stop then
            fail(#s + 1, "unterminated string")
        end
        out[#out + 1] = s:sub(i, stop - 1)
        local c = s:sub(stop, stop)
        if c == '"' then
            return table.concat(out), stop + 1
        elseif c ~= "\\" then
            fail(stop, "control character in string")
        end
        local e = s:sub(stop + 1, stop + 1)
        if e == "u" then
            local hex = s:match("^%x%x%x%x", stop + 2)
            if not hex then
                fail(stop, "bad unicode escape")
            end
            local cp = tonumber(hex, 16)
            i = stop + 6
            if cp >= 0xD800 and cp < 0xDC00 then
                local low = s:match("^\\u(%x%x%x%x)", i)
                low = low and tonumber(low, 16)
                if not low or low < 0xDC00 or low > 0xDFFF then
                    fail(stop, "unpaired surrogate")
                end
                cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
                i = i + 6
            elseif cp >= 0xDC00 and cp <= 0xDFFF then
                fail(stop, "unpaired surrogate")
            end
            out[#out + 1] = utf8_char(cp)
        elseif UNESCAPES[e] then
            out[#out + 1] = UNESCAPES[e]
            i = stop + 2
        else
            fail(stop, "bad escape")
        end
    end
end

local function decode_number(s, pos)
    local lit = s:match("^-?%d+", pos)
    if not lit or s:match("^-?0%d", pos) then
        fail(pos, "bad number")
    end
    local tail = pos + #lit
    if s:sub(tail, tail) == "." then
        local frac = s:match("^%.%d+", tail)
        if not frac then
            fail(pos, "bad number")
        end
        lit, tail = lit .. frac, tail + #frac
    end
    if s:match("^[eE]", tail) then
        local exp = s:match("^[eE][+-]?%d+", tail)
        if not exp then
            fail(pos, "bad number")
        end
        lit = lit .. exp
    end
    local n = tonumber(lit)
    if n == math.huge or n == -math.huge then
        fail(pos, "number out of range")
    end
    return n, pos + #lit
end

local function decode_array(s, pos, depth)
    local out, n = {}, 0
    pos = skip(s, pos + 1)
    if s:sub(pos, pos) == "]" then
        return out, pos + 1
    end
    while true do
        n = n + 1
        out[n], pos = decode_value(s, pos, depth)
        pos = skip(s, pos)
        local c = s:sub(pos, pos)
        if c == "]" then
            return out, pos + 1
        elseif c ~= "," then
            fail(pos, "expected , or ]")
        end
        pos = skip(s, pos + 1)
    end
end

local function decode_object(s, pos, depth)
    local out = M.object({})
    pos = skip(s, pos + 1)
    if s:sub(pos, pos) == "}" then
        return out, pos + 1
    end
    while true do
        if s:sub(pos, pos) ~= '"' then
            fail(pos, "expected string key")
        end
        local key
        key, pos = decode_string(s, pos)
        pos = skip(s, pos)
        if s:sub(pos, pos) ~= ":" then
            fail(pos, "expected :")
        end
        out[key], pos = decode_value(s, skip(s, pos + 1), depth)
        pos = skip(s, pos)
        local c = s:sub(pos, pos)
        if c == "}" then
            return out, pos + 1
        elseif c ~= "," then
            fail(pos, "expected , or }")
        end
        pos = skip(s, pos + 1)
    end
end

local LITERALS = { ["true"] = true, ["false"] = false, ["null"] = M.null }

function decode_value(s, pos, depth)
    local c = s:sub(pos, pos)
    if c == "{" or c == "[" then
        if depth >= MAX_DEPTH then
            fail(pos, "nesting too deep")
        end
        if c == "{" then
            return decode_object(s, pos, depth + 1)
        end
        return decode_array(s, pos, depth + 1)
    elseif c == '"' then
        return decode_string(s, pos)
    elseif c == "-" or c:match("%d") then
        return decode_number(s, pos)
    end
    for word, value in pairs(LITERALS) do
        if s:sub(pos, pos + #word - 1) == word then
            return value, pos + #word
        end
    end
    fail(pos, pos > #s and "unexpected end" or "unexpected character")
end

---Parse one JSON document.
---@param text string the document
---@return any|nil value tables for objects and arrays, `json.null` for null; nil on failure
---@return string|nil err what went wrong, with the 1-based byte offset
function M.decode(text)
    local ok, value = pcall(function()
        local v, p = decode_value(text, skip(text, 1), 0)
        p = skip(text, p)
        if p <= #text then
            fail(p, "unexpected trailing data")
        end
        return v
    end)
    if ok then
        return value
    end
    return nil, unwrap(value)
end

local function is_object_marked(t)
    local mt = getmetatable(t)
    return mt ~= nil and mt.__jsonobject == true
end

local function is_array(t)
    if is_object_marked(t) then
        return false
    end
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then
            return false
        end
    end
    return true
end

local function encode_string(s)
    return '"'
        .. s:gsub('[%c"\\]', function(c)
            return ESCAPES[c] or string.format("\\u%04x", c:byte())
        end)
        .. '"'
end

local function encode_number(n)
    if n ~= n or n == math.huge or n == -math.huge then
        raise("cannot encode " .. tostring(n))
    end
    if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
        return string.format("%d", n)
    end
    for digits = 15, 16 do
        local text = string.format("%." .. digits .. "g", n)
        if tonumber(text) == n then
            return text
        end
    end
    return string.format("%.17g", n)
end

local function ordered_keys(t, order)
    local keys, seen = {}, {}
    for _, key in ipairs(order) do
        if t[key] ~= nil then
            keys[#keys + 1] = key
            seen[key] = true
        end
    end
    local rest = {}
    for key in pairs(t) do
        if type(key) ~= "string" then
            raise("object key is not a string: " .. tostring(key))
        end
        if not seen[key] then
            rest[#rest + 1] = key
        end
    end
    table.sort(rest)
    for _, key in ipairs(rest) do
        keys[#keys + 1] = key
    end
    return keys
end

local function encode_value(v, order, depth)
    local kind = type(v)
    if v == M.null then
        return "null"
    elseif kind == "boolean" then
        return tostring(v)
    elseif kind == "number" then
        return encode_number(v)
    elseif kind == "string" then
        return encode_string(v)
    elseif kind ~= "table" then
        raise("cannot encode a " .. kind)
    elseif depth >= MAX_DEPTH then
        raise("nesting too deep")
    end
    local parts = {}
    if is_array(v) then
        for i = 1, #v do
            parts[i] = encode_value(v[i], order, depth + 1)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for i, key in ipairs(ordered_keys(v, order)) do
        parts[i] = encode_string(key) .. ":" .. encode_value(v[key], order, depth + 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

---Write `value` as compact JSON with a stable key order.
---
---A table with keys 1..n only is an array, an empty one included. Any other
---table is an object, as is one passed through `json.object`.
---@param value any strings, numbers, booleans, `json.null` and tables of them
---@param opts? dev.json.EncodeOpts
---@return string|nil text the document; nil on failure
---@return string|nil err what could not be encoded
function M.encode(value, opts)
    local order = opts and opts.order or {}
    local ok, text = pcall(encode_value, value, order, 0)
    if ok then
        return text
    end
    return nil, unwrap(text)
end

return M
