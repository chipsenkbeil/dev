local builtins = require("dev.builtins")
local devos = require("dev.os")
local fs = require("dev.fs")
local header = require("dev.header")

local WORD = "^[A-Za-z0-9_-]+$"
local stderr = io.stderr
local RESERVED_DIRS = { lua = true, topics = true }
local HIDDEN_GROUP = "hidden"

---@class dev.Script
---@field path string path of the script
---@field lang "sh"|"lua" language of the script

---@class dev.Row
---@field words string[] the command words, with a noun first in a subcommand's
---@field name string the words joined by a space
---@field kind "builtin"|"override"|"local" where the row comes from, `override` for a project script that replaces a built-in verb
---@field noun boolean whether the row is a noun
---@field handler string? the built-in handler, nil for a noun, a local verb or the project type's builtin
---@field flags string? flags a built-in row takes, space separated
---@field usage string? usage line of a built-in row
---@field desc string description shown in `dev help`
---@field group string? heading in `dev help`, set on a verb and a noun
---@field hidden boolean? whether `dev help` keeps the row to `-a`, set on a verb and a noun
---@field script string? path of the project script behind the row
---@field lang "sh"|"lua"? language of that script

---@class dev.Registry
---@field root string project root
---@field warn fun(message: string) receives each warning about a script's header
---@field private builtin table<string, dev.Builtin> built-in rows by name
---@field private builtin_subs table<string, dev.Builtin[]> built-in subcommand rows by noun
---@field private flat table<string, dev.Script> verb scripts in `.dev` by name
---@field private flat_order string[] names in `flat` in listing order
---@field private dirs table<string, {scripts: table<string, dev.Script>, order: string[]}> subcommand scripts by noun directory
---@field private dir_order string[] names in `dirs` in listing order
---@field private headers table<string, dev.Header> parsed headers by script path
---@field private rows table<string, dev.Row|false> resolved verb rows by name
local Registry = {}
Registry.__index = Registry

---@class dev.registry
local M = {}

local function glob_names(dir)
    local present = {}
    for _, name in ipairs(fs.list(dir) or {}) do
        present[name] = true
    end
    local out = devos.capture(
        { "bash", "-c", [=[printf '%s\0' *]=] },
        { cwd = dir, stderr = "null" }
    )
    local names = {}
    for name in out:gmatch("([^%z]+)%z") do
        if present[name] then
            names[#names + 1] = name
        end
    end
    return names
end

local function scripts_in(dir)
    local by_name, order = {}, {}
    for _, file in ipairs(glob_names(dir)) do
        local path = fs.join(dir, file)
        local name, lang = file:match("^(.+)%.lua$"), "lua"
        if not name then
            name, lang = file:match("^(.+)%.sh$"), "sh"
        end
        if name and fs.is_file(path) and (lang == "lua" or fs.is_exec(path)) then
            if not by_name[name] then
                order[#order + 1] = name
            end
            if lang == "lua" or not by_name[name] then
                by_name[name] = { path = path, lang = lang }
            end
        end
    end
    return by_name, order
end

local function has_visible(scripts, order)
    for _, name in ipairs(order) do
        if name:sub(1, 2) ~= "__" and scripts[name] then
            return true
        end
    end
    return false
end

local function copy(row)
    local out = {}
    for key, value in pairs(row) do
        out[key] = value
    end
    return out
end

local function stderr_warn(message)
    stderr:write(message, "\n")
end

---Read the `.dev` directory of a project.
---
---Nothing is wired to dispatch yet, so the registry only answers questions.
---`.lua` scripts need no exec bit, `.sh` scripts do, and `.lua` beats `.sh`
---for one name. The `lua` and `topics` directories hold helpers and topics,
---never nouns.
---@param root string project root
---@param opts {warn: fun(message: string)?}? `warn` receives header warnings and writes to standard error by default
---@return dev.Registry registry the registry of the project
function M.load(root, opts)
    local self = setmetatable({
        root = root,
        warn = opts and opts.warn or stderr_warn,
        builtin = {},
        builtin_subs = {},
        dirs = {},
        dir_order = {},
        headers = {},
        rows = {},
    }, Registry)
    for _, row in ipairs(builtins) do
        self.builtin[table.concat(row.words, " ")] = row
        if #row.words == 2 then
            local subs = self.builtin_subs[row.words[1]] or {}
            subs[#subs + 1] = row
            self.builtin_subs[row.words[1]] = subs
        end
    end
    local dev_dir = fs.join(root, ".dev")
    self.flat, self.flat_order = scripts_in(dev_dir)
    for _, name in ipairs(glob_names(dev_dir)) do
        local path = fs.join(dev_dir, name)
        if fs.is_dir(path) and not RESERVED_DIRS[name] then
            local scripts, order = scripts_in(path)
            self.dirs[name] = { scripts = scripts, order = order }
            self.dir_order[#self.dir_order + 1] = name
        end
    end
    return self
end

function Registry:__header(path, lang)
    local cached = self.headers[path]
    if not cached then
        cached = header.parse(fs.read(path) or "", lang, path)
        self.headers[path] = cached
    end
    return cached
end

function Registry:__has_subs(noun)
    local dir = self.dirs[noun]
    return dir ~= nil and has_visible(dir.scripts, dir.order)
end

function Registry:__noun_desc(noun)
    local builtin = self.builtin[noun]
    if builtin and builtin.desc ~= "" then
        return builtin.desc
    end
    local first = fs.read(fs.join(self.root, ".dev", noun, "DESCRIPTION"))
    local line = first and first:match("^[^\n]*") or ""
    if line ~= "" then
        return line
    end
    return table.concat(self:__sub_names(noun), ", ")
end

function Registry:__sub_names(noun)
    local names = {}
    for _, builtin in ipairs(self.builtin_subs[noun] or {}) do
        names[#names + 1] = builtin.words[2]
    end
    local dir = self.dirs[noun]
    for _, sub in ipairs(dir and dir.order or {}) do
        if sub:sub(1, 2) ~= "__" and not self.builtin[noun .. " " .. sub] then
            names[#names + 1] = sub
        end
    end
    return names
end

function Registry:__place(row)
    local builtin = self.builtin[row.name]
    local group, hidden = "", false
    if row.kind ~= "builtin" then
        if row.script then
            local h = self:__header(row.script, row.lang)
            group, hidden = h.group or "", h.hidden
        elseif row.noun then
            local dir = self.dirs[row.name]
            for _, sub in ipairs(dir.order) do
                local h = self:__header(dir.scripts[sub].path, dir.scripts[sub].lang)
                if h.group then
                    group, hidden = h.group, h.hidden
                    break
                end
            end
        end
    end
    if group == "" and row.kind ~= "local" then
        group = builtin.group or (builtin.hidden and HIDDEN_GROUP) or ""
        hidden = hidden or group == HIDDEN_GROUP
    end
    if group == "" or group == HIDDEN_GROUP then
        group = fs.basename(self.root)
    end
    row.group, row.hidden = group, hidden
end

function Registry:__verb(name)
    local cached = self.rows[name]
    if cached ~= nil then
        return cached or nil
    end
    local builtin, script = self.builtin[name], self.flat[name]
    local row
    if builtin then
        row = copy(builtin)
        row.kind = "builtin"
        if script and not builtin.noun then
            row.kind, row.script, row.lang = "override", script.path, script.lang
            row.desc = self:__header(script.path, script.lang).desc
            row.desc = row.desc ~= "" and row.desc or builtin.desc
        end
    elseif script then
        row = { words = { name }, kind = "local", script = script.path, lang = script.lang }
        row.desc = self:__header(script.path, script.lang).desc
    elseif self:__has_subs(name) then
        row = { words = { name }, kind = "local", noun = true }
        row.desc = self:__noun_desc(name)
    end
    if row then
        row.name = name
        row.noun = row.noun or false
        self:__place(row)
    end
    self.rows[name] = row or false
    return row
end

function Registry:__sub(noun, sub)
    for _, builtin in ipairs(self.builtin_subs[noun.name] or {}) do
        if builtin.words[2] == sub then
            local row = copy(builtin)
            row.name, row.kind, row.noun = noun.name .. " " .. sub, "builtin", false
            row.group, row.hidden = noun.group, false
            return row
        end
    end
    local dir = self.dirs[noun.name]
    local script = dir and dir.scripts[sub]
    if script then
        return {
            words = { noun.name, sub },
            name = noun.name .. " " .. sub,
            kind = "local",
            noun = false,
            script = script.path,
            lang = script.lang,
            desc = self:__header(script.path, script.lang).desc,
            group = noun.group,
            hidden = false,
        }
    end
end

---Find the row for a command.
---
---A project script replaces a built-in verb, never a built-in noun or a
---built-in subcommand, and a script `.dev/<verb>.<ext>` beats a directory of
---the same name. A `__` script is found here though `verbs` and `subs` list it.
---@param words string[] one word for a verb or noun, two for a noun's subcommand
---@return dev.Row? row nil when nothing answers to the words
function Registry:find(words)
    for _, word in ipairs(words) do
        if not word:find(WORD) then
            return nil
        end
    end
    if #words == 1 then
        return self:__verb(words[1])
    elseif #words == 2 then
        local noun = self:__verb(words[1])
        return noun and noun.noun and self:__sub(noun, words[2]) or nil
    end
end

---List the verbs and nouns.
---
---The built-in rows come first, in the order of the built-in table, then the
---project's scripts, then its noun directories. A `__` script is left out.
---@return dev.Row[] rows the rows, with the built-in ones overridden by a project script
function Registry:verbs()
    local rows = {}
    for _, builtin in ipairs(builtins) do
        if #builtin.words == 1 then
            rows[#rows + 1] = self:__verb(builtin.words[1])
        end
    end
    for _, name in ipairs(self.flat_order) do
        if name:sub(1, 2) ~= "__" and not self.builtin[name] then
            rows[#rows + 1] = self:__verb(name)
        end
    end
    for _, name in ipairs(self.dir_order) do
        local row = name:sub(1, 2) ~= "__" and not self.builtin[name] and self:__verb(name)
        if row and row.noun then
            rows[#rows + 1] = row
        end
    end
    return rows
end

---List the subcommands of a noun.
---@param noun string the noun's name
---@return dev.Row[] rows the built-in subcommands, then the project's, none for a word that is not a noun
function Registry:subs(noun)
    local parent = self:find({ noun })
    local rows = {}
    if not (parent and parent.noun) then
        return rows
    end
    for _, sub in ipairs(self:__sub_names(noun)) do
        rows[#rows + 1] = self:__sub(parent, sub)
    end
    return rows
end

---Check whether a word is a noun.
---@param word string word to check
---@return boolean noun true for a built-in noun or a directory of scripts no flat script shadows
function Registry:is_noun(word)
    local row = self:find({ word })
    return row ~= nil and row.noun
end

---List the flags a command takes.
---
---A project script's `flags:` line decides when the row has a script, and a
---`-h` or `--help` in it is dropped with a warning, since dev reserves both.
---@param words string[] the command words
---@return string[] flags the flags, empty when nothing answers to the words
function Registry:flags(words)
    local row = self:find(words)
    local flags = {}
    if row and row.script then
        local parsed = self:__header(row.script, row.lang)
        for _, message in ipairs(parsed.warnings) do
            self.warn(message)
        end
        return parsed.flags
    end
    for flag in (row and row.flags or ""):gmatch("%S+") do
        flags[#flags + 1] = flag
    end
    return flags
end

return M
