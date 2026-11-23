local ESCAPES = { b = "\b", t = "\t", n = "\n", f = "\f", r = "\r", ['"'] = '"', ["\\"] = "\\" }

---Read the small part of TOML that dev's config files use.
---
---Tables and dotted table headers, bare and quoted keys, basic strings with
---the single-character escapes, integers, booleans, arrays of scalars
---that may span lines, and comments. Anything else is an error that names its
---line.
---@class dev.toml
---@field SetRefusal table<string, dev.toml.SetRefusal> the reasons `set` refuses a key
local M = {}

---Why `set` writes nothing
---@enum dev.toml.SetRefusal
M.SetRefusal = {
    BAD_KEY = "bad_key",
    BAD_VALUE = "bad_value",
    ALREADY_SET = "already_set",
    UNPARSEABLE = "unparseable",
    RESULT_INVALID = "result_invalid",
}

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

---The escape sequence for each control character, quote and backslash a string value holds.
local UNESCAPES = {
    ["\b"] = "\\b",
    ["\t"] = "\\t",
    ["\n"] = "\\n",
    ["\f"] = "\\f",
    ["\r"] = "\\r",
    ['"'] = '\\"',
    ["\\"] = "\\\\",
}

local function render_string(value)
    return '"' .. value:gsub('[%c"\\]', UNESCAPES) .. '"'
end

local function render(value)
    if type(value) == "string" then
        return render_string(value)
    elseif type(value) == "number" and value == math.floor(value) then
        return string.format("%d", value)
    elseif type(value) == "table" and #value > 0 then
        local items = {}
        for i, item in ipairs(value) do
            if type(item) ~= "string" then
                return nil
            end
            items[i] = render_string(item)
        end
        return "[" .. table.concat(items, ", ") .. "]"
    end
    return nil
end

local function header_of(line)
    local inner = line:match("^%s*%[([^%[%]]*)%]")
    return inner and (inner:gsub("%s*%.%s*", "."):match("^%s*(.-)%s*$"))
end

local function is_content(line)
    return line:find("%S") ~= nil and not line:find("^%s*#")
end

local function split_lines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    if text == "" or text:sub(-1) == "\n" then
        lines[#lines] = nil
    end
    return lines
end

local function insertion_point(lines, section)
    local at
    local inside = section == ""
    for i, line in ipairs(lines) do
        if line:find("^%s*%[") then
            if section == "" then
                break
            end
            inside = header_of(line) == section
            if inside then
                at = i
            end
        elseif inside and is_content(line) then
            at = i
        end
    end
    return at
end

---Add a key to a TOML document, under its section.
---
---The key is dotted: everything before the last dot names the section, which
---the writer makes at the end of the text when it is absent. The rest of the
---text stays as it is, line for line.
---@param text string the document
---@param key string the dotted key, such as `board.pomb.url`
---@param value string|integer|string[] the value to write
---@return string? text the document with the key added, nil when it cannot be
---@return dev.toml.SetRefusal? reason why it cannot
---@return string? detail the parser's `<line>: <reason>`, set for the two parse reasons
function M.set(text, key, value)
    local bare = key:find("^[%w_-]+$") or key:find("^[%w_-]+%.[%w_.-]*[%w_-]$")
    if not bare or key:find("..", 1, true) then
        return nil, M.SetRefusal.BAD_KEY
    end
    local tree, message = M.parse(text)
    if not tree then
        return nil, M.SetRefusal.UNPARSEABLE, message
    end
    local node = tree
    for part in key:gmatch("[^.]+") do
        node = type(node) == "table" and node[part] or nil
    end
    if node ~= nil then
        return nil, M.SetRefusal.ALREADY_SET
    end
    local rendered = render(value)
    if not rendered then
        return nil, M.SetRefusal.BAD_VALUE
    end
    local section, leaf = key:match("^(.-)%.?([^.]+)$")
    local entry = leaf .. " = " .. rendered
    local lines = split_lines(text)
    local at = insertion_point(lines, section)
    if at then
        table.insert(lines, at + 1, entry)
    elseif section == "" then
        table.insert(lines, 1, entry)
    else
        if #lines > 0 and lines[#lines]:find("%S") then
            lines[#lines + 1] = ""
        end
        lines[#lines + 1] = "[" .. section .. "]"
        lines[#lines + 1] = entry
    end
    local result = table.concat(lines, "\n") .. "\n"
    local parsed, parse_message = M.parse(result)
    if not parsed then
        return nil, M.SetRefusal.RESULT_INVALID, parse_message
    end
    return result
end

return M
