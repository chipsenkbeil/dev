---@class dev.pkg.Row
---@field name string the first cell, with variables unexpanded
---@field binary string the second cell, with variables unexpanded
---@field fields string[] every cell of the row, with variables unexpanded
---@field groups string[] the names in the row's `groups` cell, empty with no such column

---@class dev.pkg.Rows: dev.pkg.Row[]
---@field header string[] the cells of the header row
---@field defaults table<string, string> the values of the `# @env` lines

---@class dev.pkg.Selected
---@field name string the row's name
---@field binary string the row's binary column
---@field cell string the row's cell for one manager

---@class dev.pkg.SelectOpts
---@field column integer the manager's column from `column`
---@field group string? keep only the rows listing this group, every row when nil or empty

---@class dev.pkg.manifest
local M = {}

local FIRST_MANAGER_FIELD = 3
local GROUPS_COLUMN = "groups"
local VARIABLE_NAME = "^[A-Za-z0-9_]+$"

local function tokenize(line)
    local fields, current = {}, {}
    local quoted, started = false, false
    for i = 1, #line do
        local char = line:sub(i, i)
        if quoted then
            if char == '"' then
                quoted = false
            else
                current[#current + 1] = char
            end
        elseif char == '"' then
            quoted, started = true, true
        elseif char == " " or char == "\t" then
            if started then
                fields[#fields + 1] = table.concat(current)
                current, started = {}, false
            end
        else
            current[#current + 1] = char
            started = true
        end
    end
    if started then
        fields[#fields + 1] = table.concat(current)
    end
    return fields
end

local function env_default(line)
    local rest = line:gsub("^%s*#%s*@env%s+", "", 1)
    local name = rest:match("^[A-Za-z_][A-Za-z0-9_]*")
    if not name then
        return nil
    end
    rest = rest:sub(#name + 1):gsub("^%s+", "")
    if rest:sub(1, 1) == '"' then
        rest = rest:sub(2)
        local close = rest:find('"', 1, true)
        return name, close and rest:sub(1, close - 1) or rest
    end
    return name, rest:match("^%S+") or ""
end

local function split_groups(cell)
    local names = {}
    for name in (cell or ""):gmatch("[^,]+") do
        names[#names + 1] = name
    end
    return names
end

local function group_column(header)
    local found
    for i = FIRST_MANAGER_FIELD, #header do
        if header[i] == GROUPS_COLUMN then
            found = i
        end
    end
    return found
end

---Read a manifest into its rows.
---
---Columns split on runs of spaces and tabs, a double-quoted cell is one cell with
---its quotes removed, and `# @env NAME value` lines set the defaults of the
---variables a cell may name. The first row that is not a comment is the header.
---@param text string the manifest's text
---@return dev.pkg.Rows rows the data rows in file order
function M.parse(text)
    local rows = { header = {}, defaults = {} }
    local header
    for line in text:gmatch("[^\n]*") do
        if line:find("^%s*#%s*@env%s") then
            local name, value = env_default(line)
            if name then
                rows.defaults[name] = value
            end
        elseif not line:find("^%s*#") and not line:find("^%s*$") then
            local fields = tokenize(line)
            if not header then
                header = fields
                rows.header = fields
            else
                local gi = group_column(header)
                local names = gi and split_groups(fields[gi]) or {}
                rows[#rows + 1] = {
                    name = fields[1] or "",
                    binary = fields[2] or "",
                    fields = fields,
                    groups = names,
                }
            end
        end
    end
    return rows
end

---Find the column of a package manager in the header.
---@param rows dev.pkg.Rows rows from `parse`
---@param manager string the manager's name
---@return integer? column the 1-based cell index, nil when the header has none
function M.column(rows, manager)
    if manager == GROUPS_COLUMN then
        return nil
    end
    for i = FIRST_MANAGER_FIELD, #rows.header do
        if rows.header[i] == manager then
            return i
        end
    end
end

local function resolve(rows, name, row)
    local value = os.getenv(name)
    if value == nil then
        value = rows.defaults[name]
    end
    if value == nil then
        return nil, "Variable ${" .. name .. "} is undefined in row " .. row .. "."
    end
    return value
end

local function expand(rows, text, row)
    local out = {}
    local i, size = 1, #text
    while i <= size do
        local char = text:sub(i, i)
        local nxt = text:sub(i + 1, i + 1)
        if char ~= "$" then
            out[#out + 1] = char
            i = i + 1
        elseif nxt == "$" then
            out[#out + 1] = "$"
            i = i + 2
        elseif nxt == "{" then
            local close = text:find("}", i + 2, true)
            local name = close and text:sub(i + 2, close - 1)
            if name and name:find(VARIABLE_NAME) then
                local value, err = resolve(rows, name, row)
                if not value then
                    return nil, err
                end
                out[#out + 1] = value
                i = close + 1
            else
                out[#out + 1] = "$"
                i = i + 1
            end
        elseif nxt:find("^[A-Za-z0-9_]$") then
            local name = text:match("^[A-Za-z0-9_]+", i + 1)
            local value, err = resolve(rows, name, row)
            if not value then
                return nil, err
            end
            out[#out + 1] = value
            i = i + 1 + #name
        else
            out[#out + 1] = "$"
            i = i + 1
        end
    end
    return table.concat(out)
end

---Pick the rows of one package manager, with their variables expanded.
---
---A variable takes the environment's value, else its `# @env` default, else the
---call fails before any row is returned.
---@param rows dev.pkg.Rows rows from `parse`
---@param opts dev.pkg.SelectOpts the manager's column and the group to keep
---@return dev.pkg.Selected[]? selected one entry per kept row, nil when a variable is undefined
---@return string? err the message naming the variable and the row
function M.select(rows, opts)
    local group = opts.group
    local kept = {}
    for _, row in ipairs(rows) do
        local hit = group == nil or group == ""
        for _, name in ipairs(row.groups) do
            hit = hit or name == group
        end
        if hit then
            kept[#kept + 1] = row
        end
    end
    local selected = {}
    for i, row in ipairs(kept) do
        local texts = { row.name, row.binary, row.fields[opts.column] or "" }
        local values = {}
        for j, text in ipairs(texts) do
            local value, err = expand(rows, text, row.name)
            if not value then
                return nil, err
            end
            values[j] = value
        end
        selected[i] = { name = values[1], binary = values[2], cell = values[3] }
    end
    return selected
end

return M
