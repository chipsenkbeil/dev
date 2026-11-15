local ESCAPES = { b = "\b", t = "\t", n = "\n", f = "\f", r = "\r", ['"'] = '"', ["\\"] = "\\" }

---Read the small part of TOML that dev's config files use.
---
---Tables and dotted table headers, bare and quoted keys, basic strings with
---the single-character escapes, integers, booleans, arrays of scalars
---that may span lines, and comments. Anything else is an error that names its
---line.
---@class dev.toml
local M = {}

local FAILURE = "toml\0"
local arrays = setmetatable({}, { __mode = "k" })

local function fail(msg)
    error(FAILURE .. msg, 0)
end

local function skip_space(line, pos)
    return line:match("^[ \t]*()", pos)
end

local function parse_string(line, pos)
    local out = {}
    pos = pos + 1
    while true do
        local chunk, stop = line:match('^([^"\\]*)()', pos)
        out[#out + 1] = chunk
        local char = line:sub(stop, stop)
        if char == "" then
            fail("unterminated string")
        elseif char == '"' then
            return table.concat(out), stop + 1
        end
        local escape = line:sub(stop + 1, stop + 1)
        local value = ESCAPES[escape]
        if not value then
            fail("unsupported escape \\" .. escape)
        end
        out[#out + 1] = value
        pos = stop + 2
    end
end

local parse_value

local function skip_gap(line, pos, reader, opened)
    while true do
        pos = skip_space(line, pos)
        local char = line:sub(pos, pos)
        if char ~= "" and char ~= "#" then
            return line, pos
        end
        line = reader.next()
        if not line then
            fail("array opened on line " .. opened .. " is not closed")
        end
        pos = 1
    end
end

local function parse_array(line, pos, reader)
    local items = {}
    arrays[items] = true
    local opened = reader.number
    line, pos = skip_gap(line, pos + 1, reader, opened)
    while true do
        local char = line:sub(pos, pos)
        if char == "]" then
            return items, pos + 1, line
        elseif char == "[" then
            fail("nested arrays are not supported")
        end
        local value
        value, pos, line = parse_value(line, pos, reader)
        items[#items + 1] = value
        line, pos = skip_gap(line, pos, reader, opened)
        char = line:sub(pos, pos)
        if char == "," then
            line, pos = skip_gap(line, pos + 1, reader, opened)
        elseif char ~= "]" then
            fail("expected , or ] in an array")
        end
    end
end

function parse_value(line, pos, reader)
    local char = line:sub(pos, pos)
    if char == '"' then
        if line:sub(pos, pos + 2) == '"""' then
            fail("multi-line strings are not supported")
        end
        local value
        value, pos = parse_string(line, pos)
        return value, pos, line
    elseif char == "[" then
        return parse_array(line, pos, reader)
    elseif char == "{" then
        fail("inline tables are not supported")
    elseif char == "'" then
        fail("literal strings are not supported")
    end
    local word, stop = line:match("^([^%s,%]#]+)()", pos)
    if word == "true" then
        return true, stop, line
    elseif word == "false" then
        return false, stop, line
    elseif word and word:find("^[+-]?%d+$") then
        if #word > 18 then
            fail("integer " .. word .. " is too large")
        end
        return tonumber(word), stop, line
    elseif word and word:find("^%d") and word:find("[-:]") then
        fail("dates are not supported")
    end
    fail(word and ("unsupported value " .. word) or "missing value")
end

local function parse_key(line, pos)
    if line:sub(pos, pos) == '"' then
        return parse_string(line, pos)
    end
    local key, stop = line:match("^([%w_-]+)()", pos)
    if not key then
        fail("invalid key")
    end
    return key, stop
end

local function end_of_line(line, pos)
    pos = skip_space(line, pos)
    local char = line:sub(pos, pos)
    if char ~= "" and char ~= "#" then
        fail("unexpected text after the value")
    end
end

local function open_table(root, explicit, line, pos)
    if line:sub(pos, pos) == "[" then
        fail("arrays of tables are not supported")
    end
    local current = root
    while true do
        local key
        pos = skip_space(line, pos)
        key, pos = parse_key(line, pos)
        pos = skip_space(line, pos)
        local child = current[key]
        if child == nil then
            child = {}
            current[key] = child
        elseif type(child) ~= "table" or arrays[child] then
            fail("key " .. key .. " is not a table")
        end
        current = child
        local char = line:sub(pos, pos)
        if char == "." then
            pos = pos + 1
        elseif char == "]" then
            end_of_line(line, pos + 1)
            if explicit[current] then
                fail("table defined twice")
            end
            explicit[current] = true
            return current
        else
            fail("expected . or ] in a table header")
        end
    end
end

local function assign(current, line, pos, reader)
    local key
    key, pos = parse_key(line, pos)
    pos = skip_space(line, pos)
    if line:sub(pos, pos) == "." then
        fail("dotted keys are not supported")
    elseif line:sub(pos, pos) ~= "=" then
        fail("expected = after the key")
    end
    pos = skip_space(line, pos + 1)
    local value
    value, pos, line = parse_value(line, pos, reader)
    end_of_line(line, pos)
    if current[key] ~= nil then
        fail("key " .. key .. " defined twice")
    end
    current[key] = value
end

---Parse a TOML document.
---@param text string the document
---@return table<string, any>? tree the parsed tables and values, or nil on error
---@return string? message `<line>: <reason>` for the first line that fails
function M.parse(text)
    local root = {}
    local current = root
    local explicit = {}
    local lines = (text .. "\n"):gmatch("([^\n]*)\n")
    local reader = { number = 0 }
    function reader.next()
        local line = lines()
        if line then
            reader.number = reader.number + 1
            line = line:gsub("\r$", "")
        end
        return line
    end
    for line in reader.next do
        local ok, err = pcall(function()
            local pos = skip_space(line, 1)
            local char = line:sub(pos, pos)
            if char == "" or char == "#" then
                return
            elseif char == "[" then
                current = open_table(root, explicit, line, pos + 1)
            else
                assign(current, line, pos, reader)
            end
        end)
        if not ok then
            if err:sub(1, #FAILURE) ~= FAILURE then
                error(err, 0)
            end
            return nil, reader.number .. ": " .. err:sub(#FAILURE + 1)
        end
    end
    return root
end

return M
