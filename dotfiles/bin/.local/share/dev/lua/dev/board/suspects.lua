local fs = require("dev.fs")
local land = require("dev.board.land")

---The landed cards of a red ship batch that touched a failing test's files.
---@class dev.board.suspects
local M = {}

---The roots a required module is searched under
local SOURCE_ROOTS = { "dotfiles/bin/.local/share/dev/lua/", "tests/lua/", ".dev/lua/" }
---The suffixes a module path may carry
local MODULE_SUFFIXES = { ".lua", "/init.lua" }

---@class dev.board.suspects.Entry
---@field label string the card as the ship prints it
---@field landed string the card's landed commit
---@field card dev.board.Card the card

local function module_file(root, name)
    local relative = (name:gsub("%.", "/"))
    for _, base in ipairs(SOURCE_ROOTS) do
        for _, suffix in ipairs(MODULE_SUFFIXES) do
            local path = base .. relative .. suffix
            if fs.read(root .. "/" .. path) then
                return path
            end
        end
    end
end

---List a file and every Lua file it loads, directly or through another, with `require`.
---@param root string the project root
---@param path string the file, relative to the root
---@return table<string, boolean> loaded the paths, the file itself included
function M.loaded(root, path)
    local seen, queue = { [path] = true }, { path }
    local at = 1
    while queue[at] do
        local text = fs.read(root .. "/" .. queue[at]) or ""
        at = at + 1
        for name in text:gmatch('require%("([%w_.%-]+)"%)') do
            local file = module_file(root, name)
            if file and not seen[file] then
                seen[file] = true
                queue[#queue + 1] = file
            end
        end
    end
    return seen
end

---Name, for each failing test file, the cards whose landed commit touched what it loads.
---@param root string the project root
---@param failed string[] the failing test files
---@param entries dev.board.suspects.Entry[] the cards that would ship
---@return string[] lines the suspect list
---@return dev.board.suspects.Entry[] named each card the list names, once
function M.lines(root, failed, entries)
    if #failed == 0 then
        return { "The failing row printed no FAIL line, so no suspect is named." }, {}
    end
    local named, listed = {}, {}
    local touched, unread = {}, {}
    for i, entry in ipairs(entries) do
        local set = {}
        local files = land.touched(root, entry.landed)
        if not files then
            unread[#unread + 1] = "  The files of " .. entry.label .. " could not be read."
        end
        for _, path in ipairs(files or {}) do
            set[path] = true
        end
        touched[i] = set
    end
    local lines = { "Suspects among the landed cards:" }
    for _, line in ipairs(unread) do
        lines[#lines + 1] = line
    end
    for _, path in ipairs(failed) do
        local loaded = M.loaded(root, path)
        local hits = {}
        for i, entry in ipairs(entries) do
            for file in pairs(loaded) do
                if touched[i][file] then
                    if not listed[i] then
                        listed[i] = true
                        named[#named + 1] = entry
                    end
                    hits[#hits + 1] = "    "
                        .. entry.label
                        .. " ("
                        .. land.short(entry.landed)
                        .. ")"
                    break
                end
            end
        end
        if #hits == 0 then
            lines[#lines + 1] = "  "
                .. path
                .. ": no landed card in this batch touched it or the code it loads."
        else
            lines[#lines + 1] = "  " .. path .. ":"
            for _, hit in ipairs(hits) do
                lines[#lines + 1] = hit
            end
        end
    end
    if #entries > 1 and #named == #entries then
        return { "Every landed card matches the failing files, so no suspect is named." }, {}
    end
    return lines, named
end

return M
