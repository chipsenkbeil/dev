local builtins = require("dev.builtins")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local header = require("dev.header")
local xdg = require("dev.xdg")

local WORD = "^[A-Za-z0-9_-]+$"
local stderr = io.stderr
local RESERVED_DIRS = { lua = true, topics = true, standalone = true }
local HIDDEN_GROUP = "hidden"
local BARE_FLAGS = { "-v", "--verbose", "-vv", "--remote", "--local", "--detach", "--priority" }
local VALUE_FLAGS = { "-C", "--agent", "--job-timeout" }
local GLOBAL_FLAGS = {}

---@enum dev.Source
local Source = { BUILTIN = "builtin", GLOBAL = "global", PROJECT = "project" }

---The global flags that take no value, keyed by flag
local BARE_SET = {}

---The global flags that take a value, keyed by flag
local VALUE_SET = {}
for _, flag in ipairs(BARE_FLAGS) do
    GLOBAL_FLAGS[#GLOBAL_FLAGS + 1] = flag
    BARE_SET[flag] = true
end
for _, flag in ipairs(VALUE_FLAGS) do
    GLOBAL_FLAGS[#GLOBAL_FLAGS + 1] = flag
    VALUE_SET[flag] = true
end

---@class dev.Script
---@field path string path of the script
---@field lang "sh"|"lua" language of the script
---@field source dev.Source the folder the script sits in, `global` or `project`

---@class dev.Row
---@field words string[] the command words, with a noun first in a subcommand's
---@field name string the words joined by a space
---@field kind "builtin"|"override"|"local" where the row comes from, `override` for a project
---   script that replaces a built-in verb
---@field source dev.Source which layer answers, a global or project script beating a built-in
---   row
---@field noun boolean whether the row is a noun
---@field handler string? the built-in handler, nil for a noun, a local verb or the project type's
---   builtin
---@field flags string? flags a built-in row takes, space separated
---@field usage string? usage line of a built-in row
---@field desc string description shown in `dev help`
---@field group string? heading in `dev help`, set on a verb and a noun
---@field hidden boolean? whether `dev help` keeps the row to `-a`, set on a verb and a noun
---@field remote false? false when the command never runs on a remote runner
---@field requires string[]? the preconditions the command declares, `workspace` the only one known
---@field script string? path of the project script behind the row
---@field lang "sh"|"lua"? language of that script

---@class dev.Dir
---@field scripts table<string, dev.Script> the scripts in the directory by name
---@field order string[] names in `scripts` in listing order
---@field subs string[] names of the directories inside it in listing order

---@class dev.Registry
---@field root string project root
---@field global string the global commands folder
---@field warn fun(message: string) receives each warning about a script's header
---@field private builtin table<string, dev.Builtin> built-in rows by name
---@field private builtin_subs table<string, dev.Builtin[]> built-in rows by the name of their
---   parent noun
---@field private dirs table<string, dev.Dir|false> the directories read so far by the space-joined
---   words of the noun, `""` for `.dev`
---@field private headers table<string, dev.Header> parsed headers by script path
---@field private rows table<string, dev.Row|false> resolved verb rows by name
local Registry = {}
Registry.__index = Registry

---@class dev.registry
local M = {}

M.Source = Source

---The flags dev takes before any verb's own, in the order completion lists them.
M.GLOBAL_FLAGS = GLOBAL_FLAGS

---The global flags that take a value, the word after one of them being its value.
M.VALUE_FLAGS = VALUE_SET

---Count the verbosity a word adds, one for `--verbose` and one per `v` of a run such as `-vv`.
---@param word string the word to check
---@return integer? count nil when the word is no verbosity flag
function M.verbose_count(word)
    if word == "--verbose" then
        return 1
    end
    if word:find("^%-v+$") then
        return #word - 1
    end
    return nil
end

---Check whether a word is a global flag that takes no value, any run of `v` included.
---@param word string the word to check
---@return boolean
function M.is_bare(word)
    return BARE_SET[word] == true or M.verbose_count(word) ~= nil
end

local function glob_names(dir)
    local present = {}
    for _, name in ipairs(fs.list(dir) or {}) do
        present[name] = true
    end
    local out = dev_os.capture(
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

---Find the folder of the user's global commands.
---@return string dir `dev/commands` under the user config folder
function M.global_dir()
    return fs.join(xdg.config_home(), "dev", "commands")
end

---Show a script's path the way `-v` prints it.
---@param row dev.Row a row with a script
---@param root string project root
---@return string path relative to the project root, or to the global folder for a global script
function M.relative(row, root)
    local base = row.source == Source.GLOBAL and M.global_dir() or root
    return row.script:sub(#base + 2)
end

local function scripts_in(dir, source)
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
                by_name[name] = { path = path, lang = lang, source = source }
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

local function declare(row, h)
    if h.remote == false then
        row.remote = false
    end
    if #h.requires > 0 then
        local merged, seen = {}, {}
        for _, list in ipairs({ row.requires or {}, h.requires }) do
            for _, word in ipairs(list) do
                if not seen[word] then
                    seen[word] = true
                    merged[#merged + 1] = word
                end
            end
        end
        row.requires = merged
    end
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
---@param opts {warn: fun(message: string)?}? `warn` receives header warnings and writes to standard
---   error by default
---@return dev.Registry registry the registry of the project
function M.load(root, opts)
    local self = setmetatable({
        root = root,
        global = M.global_dir(),
        warn = opts and opts.warn or stderr_warn,
        builtin = {},
        builtin_subs = {},
        dirs = {},
        headers = {},
        rows = {},
    }, Registry)
    for _, row in ipairs(builtins) do
        self.builtin[table.concat(row.words, " ")] = row
        if #row.words > 1 then
            local parent = table.concat(row.words, " ", 1, #row.words - 1)
            local subs = self.builtin_subs[parent] or {}
            subs[#subs + 1] = row
            self.builtin_subs[parent] = subs
        end
    end
    return self
end

local function read_dir(path, name, source)
    if not fs.is_dir(path) then
        return nil
    end
    local scripts, order = scripts_in(path, source)
    local subs = {}
    for _, word in ipairs(glob_names(path)) do
        if fs.is_dir(fs.join(path, word)) and not (name == "" and RESERVED_DIRS[word]) then
            subs[#subs + 1] = word
        end
    end
    return { scripts = scripts, order = order, subs = subs, source = source }
end

local function merge_dirs(project, global)
    if not (project and global) then
        return project or global
    end
    local dir = { scripts = {}, order = {}, subs = {}, source = Source.PROJECT }
    local project_subs = {}
    for _, sub in ipairs(project.subs) do
        project_subs[sub] = true
    end
    for _, part in ipairs({ project, global }) do
        for _, script in ipairs(part.order) do
            local hidden = part == global and project_subs[script]
            if not (dir.scripts[script] or hidden) then
                dir.scripts[script] = part.scripts[script]
                dir.order[#dir.order + 1] = script
            end
        end
    end
    local seen = {}
    for _, part in ipairs({ project, global }) do
        for _, sub in ipairs(part.subs) do
            if not seen[sub] then
                seen[sub] = true
                dir.subs[#dir.subs + 1] = sub
            end
        end
    end
    return dir
end

function Registry:__dir(name)
    local cached = self.dirs[name]
    if cached ~= nil then
        return cached or nil
    end
    local rel = (name:gsub(" ", "/"))
    local dir
    if not RESERVED_DIRS[name:match("^%S+")] then
        dir = merge_dirs(
            read_dir(fs.join(self.root, ".dev", rel), name, Source.PROJECT),
            read_dir(fs.join(self.global, rel), name, Source.GLOBAL)
        )
    end
    dir = dir or name == "" and { scripts = {}, order = {}, subs = {}, source = Source.PROJECT }
    self.dirs[name] = dir or false
    return dir or nil
end

function Registry:__flat(name)
    return self:__dir("").scripts[name]
end

function Registry:__header(path, lang)
    local cached = self.headers[path]
    if not cached then
        cached = header.parse(fs.read(path) or "", lang, path)
        self.headers[path] = cached
    end
    return cached
end

function Registry:__has_subs(name)
    local dir = self:__dir(name)
    if not dir then
        return false
    end
    if has_visible(dir.scripts, dir.order) then
        return true
    end
    for _, sub in ipairs(dir.subs) do
        if sub:sub(1, 2) ~= "__" and self:__has_subs(name .. " " .. sub) then
            return true
        end
    end
    return false
end

function Registry:__noun_desc(noun)
    local builtin = self.builtin[noun]
    if builtin and builtin.desc ~= "" then
        return builtin.desc
    end
    local rel = noun:gsub(" ", "/")
    for _, base in ipairs({ fs.join(self.root, ".dev"), self.global }) do
        local first = fs.read(fs.join(base, rel, "DESCRIPTION"))
        local line = first and first:match("^[^\n]*") or ""
        if line ~= "" then
            return line
        end
    end
    return table.concat(self:__sub_names(noun), ", ")
end

function Registry:__sub_names(noun)
    local names, seen = {}, {}
    for _, builtin in ipairs(self.builtin_subs[noun] or {}) do
        local word = builtin.words[#builtin.words]
        seen[word] = true
        names[#names + 1] = word
    end
    local dir = self:__dir(noun)
    if dir then
        for _, sub in ipairs(dir.order) do
            if sub:sub(1, 2) ~= "__" and not seen[sub] then
                seen[sub] = true
                names[#names + 1] = sub
            end
        end
        for _, sub in ipairs(dir.subs) do
            if sub:sub(1, 2) ~= "__" and not seen[sub] and self:__has_subs(noun .. " " .. sub) then
                seen[sub] = true
                names[#names + 1] = sub
            end
        end
    end
    return names
end

function Registry:__first_group(name)
    local dir = self:__dir(name)
    if not dir then
        return nil
    end
    for _, sub in ipairs(dir.order) do
        local h = self:__header(dir.scripts[sub].path, dir.scripts[sub].lang)
        if h.group then
            return h.group, h.hidden
        end
    end
    for _, sub in ipairs(dir.subs) do
        local group, hidden = self:__first_group(name .. " " .. sub)
        if group then
            return group, hidden
        end
    end
end

function Registry:__place(row)
    local builtin = self.builtin[row.name]
    local group, hidden = "", false
    if row.kind ~= "builtin" then
        if row.script then
            local h = self:__header(row.script, row.lang)
            group, hidden = h.group or "", h.hidden
        elseif row.noun then
            local found, found_hidden = self:__first_group(row.name)
            if found then
                group, hidden = found, found_hidden
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
    local builtin, script = self.builtin[name], self:__flat(name)
    local row
    if builtin then
        row = copy(builtin)
        row.kind, row.source = "builtin", Source.BUILTIN
        if script and not builtin.noun then
            row.kind, row.script, row.lang = "override", script.path, script.lang
            row.source = script.source
            local h = self:__header(script.path, script.lang)
            row.desc = h.desc ~= "" and h.desc or builtin.desc
            declare(row, h)
        end
    elseif script then
        row = {
            words = { name },
            kind = "local",
            source = script.source,
            script = script.path,
            lang = script.lang,
        }
        local h = self:__header(script.path, script.lang)
        row.desc = h.desc
        declare(row, h)
        if self:__has_subs(name) then
            local shadowed = fs.join(self.root, ".dev", (name:gsub(" ", "/")))
            if not fs.is_dir(shadowed) then
                shadowed = fs.join(self.global, (name:gsub(" ", "/")))
            end
            self.warn(
                "The script "
                    .. script.path
                    .. " shadows the directory "
                    .. shadowed
                    .. ". Its subcommands never run."
            )
        end
    elseif self:__has_subs(name) then
        row = { words = { name }, kind = "local", noun = true, source = self:__dir(name).source }
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
    local name = noun.name .. " " .. sub
    local words = {}
    for i, word in ipairs(noun.words) do
        words[i] = word
    end
    words[#words + 1] = sub
    local builtin = self.builtin[name]
    local dir = self:__dir(noun.name)
    local script = dir and dir.scripts[sub]
    if builtin then
        local row = copy(builtin)
        row.name, row.kind, row.noun = name, "builtin", builtin.noun or false
        row.source, row.group, row.hidden = Source.BUILTIN, noun.group, false
        if script and not builtin.noun then
            row.kind, row.script, row.lang = "override", script.path, script.lang
            row.source = script.source
            local h = self:__header(script.path, script.lang)
            row.desc = h.desc ~= "" and h.desc or builtin.desc
            declare(row, h)
        end
        return row
    end
    if script then
        local h = self:__header(script.path, script.lang)
        local row = {
            words = words,
            name = name,
            kind = "local",
            source = script.source,
            noun = false,
            script = script.path,
            lang = script.lang,
            desc = h.desc,
            group = noun.group,
            hidden = false,
        }
        declare(row, h)
        return row
    end
    if dir and self:__has_subs(name) then
        return {
            words = words,
            name = name,
            kind = "local",
            source = self:__dir(name).source,
            noun = true,
            desc = self:__noun_desc(name),
            group = noun.group,
            hidden = false,
        }
    end
end

---Find the row for a command.
---
---A project script beats a global script, which beats a built-in verb or
---subcommand, though no script replaces a built-in noun. A script
---`.dev/<verb>.<ext>` beats a directory of the same name, but a project
---directory beats a global script of that name. A `__` script is found here
---though `verbs` and `subs` list it.
---@param words string[] one word for a verb or noun, then one for each level of subcommand
---@return dev.Row? row nil when nothing answers to the words
function Registry:find(words)
    for _, word in ipairs(words) do
        if not word:find(WORD) then
            return nil
        end
    end
    local row = words[1] and self:__verb(words[1])
    for i = 2, #words do
        if not (row and row.noun) then
            return nil
        end
        row = self:__sub(row, words[i])
    end
    return row
end

---Collect what a command and the commands above it declare.
---
---A `remote: false` or a `requires` word on a noun covers its subcommands.
---@param words string[] the command words
---@return false? remote false when the command or a noun above it never runs on a remote runner
---@return string[] requires the preconditions the command and the nouns above it declare
function Registry:declared(words)
    local remote, requires, seen = nil, {}, {}
    for count = 1, #words do
        local row = self:find({ unpack(words, 1, count) })
        if row and row.remote == false then
            remote = false
        end
        for _, word in ipairs(row and row.requires or {}) do
            if not seen[word] then
                seen[word] = true
                requires[#requires + 1] = word
            end
        end
    end
    return remote, requires
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
    local top = self:__dir("")
    for _, name in ipairs(top.order) do
        if name:sub(1, 2) ~= "__" and not self.builtin[name] then
            rows[#rows + 1] = self:__verb(name)
        end
    end
    for _, name in ipairs(top.subs) do
        local row = name:sub(1, 2) ~= "__" and not self.builtin[name] and self:__verb(name)
        if row and row.noun then
            rows[#rows + 1] = row
        end
    end
    return rows
end

---List the subcommands of a noun.
---@param noun string|string[] the noun's words, or its name when it is one word
---@return dev.Row[] rows the built-in subcommands, then the project's, none for words that are not
---   a noun
function Registry:subs(noun)
    local words = type(noun) == "string" and { noun } or noun
    local parent = self:find(words)
    local rows = {}
    if not (parent and parent.noun) then
        return rows
    end
    for _, sub in ipairs(self:__sub_names(parent.name)) do
        rows[#rows + 1] = self:__sub(parent, sub)
    end
    return rows
end

local function collect(self, name, out, seen)
    local dir = self:__dir(name)
    if not dir or seen[dir] then
        return
    end
    seen[dir] = true
    for _, script in ipairs(dir.order) do
        out[#out + 1] = dir.scripts[script]
    end
    for _, sub in ipairs(dir.subs) do
        collect(self, name == "" and sub or name .. " " .. sub, out, seen)
    end
end

---List every script in `.dev` and in its noun directories, `__` helpers included.
---@return dev.Script[] scripts the scripts, each directory's own before the ones inside it
function Registry:scripts()
    local out = {}
    collect(self, "", out, {})
    return out
end

---Read the header of the script behind a row.
---@param row dev.Row a row from `find`, `verbs` or `subs`
---@return dev.Header? header nil when the row has no script
function Registry:header(row)
    return row.script and self:__header(row.script, row.lang) or nil
end

---Check whether a word is a noun.
---@param word string|string[] the words to check, or the name when it is one word
---@return boolean noun true for a built-in noun or a directory of scripts no script of the same
---   name shadows
function Registry:is_noun(word)
    local row = self:find(type(word) == "string" and { word } or word)
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

---List the flags of the built-in row a project script replaces.
---@param words string[] the command words
---@return string[] flags the built-in row's flags, empty unless a script of kind `override` answers
---   to the words
function Registry:shadowed_flags(words)
    local row = self:find(words)
    local flags = {}
    if row and row.kind == "override" then
        for flag in (self.builtin[row.name].flags or ""):gmatch("%S+") do
            flags[#flags + 1] = flag
        end
    end
    return flags
end

return M
