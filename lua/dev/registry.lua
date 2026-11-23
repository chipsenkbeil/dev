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
---@field replaces dev.Source? `global` when a project script has a global script of its name

---@class dev.Row
---@field words string[] the command words, with the parent command first in a subcommand's
---@field name string the words joined by a space
---@field kind "builtin"|"override"|"local" where the row comes from, `override` for a project
---   script that replaces a built-in command
---@field source dev.Source which layer answers, a global or project script beating a built-in
---   row
---@field replaces dev.Source? the source a script row replaces, `builtin` or `global`
---@field parent boolean whether the row is a command with subcommands
---@field handler string? the built-in handler, nil for a parent command, a local command or the
---   project type's
---   builtin
---@field flags string? flags a built-in row takes, space separated
---@field usage string? usage line of a built-in row
---@field desc string description shown in `dev help`
---@field group string? heading in `dev help`, set on a command and a parent command
---@field hidden boolean? whether `dev help` keeps the row to `-a`, set on a command and a parent
---   command
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
---   parent command
---@field private dirs table<string, dev.Dir|false> the directories read so far by the space-joined
---   words of the parent command, `""` for `.dev`
---@field private headers table<string, dev.Header> parsed headers by script path
---@field private rows table<string, dev.Row|false> resolved command rows by name
---@field private only dev.Source? the one source a view answers from, nil for the whole registry
---@field private views table<string, dev.Registry> the views made so far by source
local Registry = {}
Registry.__index = Registry

---@class dev.registry
local M = {}

M.Source = Source

---The flags dev takes before any command's own, in the order completion lists them.
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
---never parent commands.
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
        views = {},
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
                if part == project and global.scripts[script] then
                    part.scripts[script].replaces = Source.GLOBAL
                end
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
        local project = not self.only
            and read_dir(fs.join(self.root, ".dev", rel), name, Source.PROJECT)
        local global = self.only ~= Source.BUILTIN
            and read_dir(fs.join(self.global, rel), name, Source.GLOBAL)
        dir = merge_dirs(project or nil, global or nil)
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

function Registry:__parent_desc(parent)
    local builtin = self.builtin[parent]
    if builtin and builtin.desc ~= "" then
        return builtin.desc
    end
    local rel = parent:gsub(" ", "/")
    for _, base in ipairs({ fs.join(self.root, ".dev"), self.global }) do
        local first = fs.read(fs.join(base, rel, "DESCRIPTION"))
        local line = first and first:match("^[^\n]*") or ""
        if line ~= "" then
            return line
        end
    end
    return table.concat(self:__sub_names(parent), ", ")
end

function Registry:__sub_names(parent)
    local names, seen = {}, {}
    for _, builtin in ipairs(self.builtin_subs[parent] or {}) do
        local word = builtin.words[#builtin.words]
        seen[word] = true
        names[#names + 1] = word
    end
    local dir = self:__dir(parent)
    if dir then
        for _, sub in ipairs(dir.order) do
            if sub:sub(1, 2) ~= "__" and not seen[sub] then
                seen[sub] = true
                names[#names + 1] = sub
            end
        end
        for _, sub in ipairs(dir.subs) do
            if
                sub:sub(1, 2) ~= "__"
                and not seen[sub]
                and self:__has_subs(parent .. " " .. sub)
            then
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
        elseif row.parent then
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

function Registry:__command(name)
    local cached = self.rows[name]
    if cached ~= nil then
        return cached or nil
    end
    local builtin, script = self.builtin[name], self:__flat(name)
    local row
    if builtin then
        row = copy(builtin)
        row.kind, row.source = "builtin", Source.BUILTIN
        if script and not builtin.parent then
            row.kind, row.script, row.lang = "override", script.path, script.lang
            row.source, row.replaces = script.source, script.replaces or Source.BUILTIN
            local h = self:__header(script.path, script.lang)
            row.desc = h.desc ~= "" and h.desc or builtin.desc
            declare(row, h)
        end
    elseif script then
        row = {
            words = { name },
            kind = "local",
            source = script.source,
            replaces = script.replaces,
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
        row = { words = { name }, kind = "local", parent = true, source = self:__dir(name).source }
        row.desc = self:__parent_desc(name)
    end
    if row then
        row.name = name
        row.parent = row.parent or false
        self:__place(row)
    end
    self.rows[name] = row or false
    return row
end

function Registry:__sub(parent, sub)
    local name = parent.name .. " " .. sub
    local words = {}
    for i, word in ipairs(parent.words) do
        words[i] = word
    end
    words[#words + 1] = sub
    local builtin = self.builtin[name]
    local dir = self:__dir(parent.name)
    local script = dir and dir.scripts[sub]
    if builtin then
        local row = copy(builtin)
        row.name, row.kind, row.parent = name, "builtin", builtin.parent or false
        row.source, row.group, row.hidden = Source.BUILTIN, parent.group, false
        if script and not builtin.parent then
            row.kind, row.script, row.lang = "override", script.path, script.lang
            row.source, row.replaces = script.source, script.replaces or Source.BUILTIN
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
            replaces = script.replaces,
            parent = false,
            script = script.path,
            lang = script.lang,
            desc = h.desc,
            group = parent.group,
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
            parent = true,
            desc = self:__parent_desc(name),
            group = parent.group,
            hidden = false,
        }
    end
end

---Make the registry that answers from one source alone.
---
---The built-in view holds the built-in rows and no script. The global view holds the scripts of the
---global folder and no built-in row, so a global script of a built-in's name is a local row there.
---@param source dev.Source `builtin` or `global`
---@return dev.Registry view the registry of that source
function Registry:view(source)
    local view = self.views[source]
    if not view then
        local builtin = source == Source.BUILTIN
        view = setmetatable({
            root = self.root,
            global = self.global,
            warn = self.warn,
            builtin = builtin and self.builtin or {},
            builtin_subs = builtin and self.builtin_subs or {},
            dirs = {},
            headers = self.headers,
            rows = {},
            views = {},
            only = source,
        }, Registry)
        self.views[source] = view
    end
    return view
end

local PREFIXED = "^([A-Za-z0-9_-]+):([A-Za-z0-9_-]+)$"

---Split a word such as `builtin:board` into its source and its bare word.
---@param word string the command word
---@return string? source nil when the word has no prefix
---@return string? bare the word without the prefix
function M.split(word)
    return word:match(PREFIXED)
end

---Split a first word such as `builtin:board` and pick the view it names.
---@param self dev.Registry the registry
---@param words string[] the command words
---@return dev.Registry? view the registry to ask, `self` for an unprefixed word, nil on a reason
---@return string[]|string? bare the words without the prefix, or the reason when the view is nil
---@return string? source the prefix, nil for an unprefixed word
local function scope(self, words)
    local source, first = M.split(words[1] or "")
    if not source then
        return self, words
    end
    if source ~= Source.BUILTIN and source ~= Source.GLOBAL then
        return nil, "unknown source " .. source
    end
    local bare = { first }
    for i = 2, #words do
        bare[i] = words[i]
    end
    return self:view(source), bare, source
end

---Turn a reason from `find` into the sentence `dev` prints.
---@param reason string the reason, `unknown source NAME`, `no builtin command WORD` or
---   `no global command WORD`
---@return string sentence the sentence for standard error
function M.sentence(reason)
    local name = reason:match("^unknown source (.+)$")
    if name then
        return "The source " .. name .. " is not builtin or global."
    end
    local source, word = reason:match("^no (%a+) command (.+)$")
    if source == Source.BUILTIN then
        return "The built-in commands have no command " .. word .. "."
    end
    return "The " .. source .. " commands have no command " .. word .. "."
end

---Find the row for a command.
---
---A project script beats a global script, which beats a built-in command or
---subcommand, though no script replaces a built-in parent command. A script
---`.dev/<command>.<ext>` beats a directory of the same name, but a project
---directory beats a global script of that name. A `__` script is found here
---though `commands` and `subs` list it.
---
---A first word `builtin:WORD` or `global:WORD` answers from that source alone, and the row's
---words are the bare ones.
---@param words string[] one word for a command, then one for each level of subcommand
---@return dev.Row? row nil when nothing answers to the words
---@return string? reason `unknown source NAME`, `no builtin command WORDS` or `no global command
---   WORDS` for a prefixed word the registry cannot answer
function Registry:find(words)
    local view, bare, source = scope(self, words)
    if not view then
        return nil, bare
    end
    if view ~= self then
        local row = view:find(bare)
        if row then
            return row
        end
        return nil, "no " .. source .. " command " .. table.concat(bare, " ")
    end
    for _, word in ipairs(words) do
        if not word:find(WORD) then
            return nil
        end
    end
    local row = words[1] and self:__command(words[1])
    for i = 2, #words do
        if not (row and row.parent) then
            return nil
        end
        row = self:__sub(row, words[i])
    end
    return row
end

---Collect what a command and the commands above it declare.
---
---A `remote: false` or a `requires` word on a parent command covers its subcommands.
---@param words string[] the command words
---@return false? remote false when the command or a parent command above it never runs on a remote
---   runner
---@return string[] requires the preconditions the command and the parent commands above it declare
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

---List the commands.
---
---The built-in rows come first, in the order of the built-in table, then the
---project's scripts, then its directories of subcommands. A `__` script is left out.
---@return dev.Row[] rows the rows, with the built-in ones overridden by a project script
function Registry:commands()
    local rows = {}
    for _, builtin in ipairs(builtins) do
        if #builtin.words == 1 then
            rows[#rows + 1] = self:__command(builtin.words[1])
        end
    end
    local top = self:__dir("")
    for _, name in ipairs(top.order) do
        if name:sub(1, 2) ~= "__" and not self.builtin[name] then
            rows[#rows + 1] = self:__command(name)
        end
    end
    for _, name in ipairs(top.subs) do
        local row = name:sub(1, 2) ~= "__" and not self.builtin[name] and self:__command(name)
        if row and row.parent then
            rows[#rows + 1] = row
        end
    end
    return rows
end

---List the subcommands of a command.
---@param path string|string[] the parent command's words, or its name when it is one word
---@return dev.Row[] rows the built-in subcommands, then the project's, none for words that are not
---   a parent command
function Registry:subs(path)
    local words = type(path) == "string" and { path } or path
    local view, bare = scope(self, words)
    if not view then
        return {}
    end
    if view ~= self then
        return view:subs(bare)
    end
    local found = self:find(words)
    local rows = {}
    if not (found and found.parent) then
        return rows
    end
    for _, sub in ipairs(self:__sub_names(found.name)) do
        rows[#rows + 1] = self:__sub(found, sub)
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

---List every script in `.dev` and in its parent command directories, `__` helpers included.
---@return dev.Script[] scripts the scripts, each directory's own before the ones inside it
function Registry:scripts()
    local out = {}
    collect(self, "", out, {})
    return out
end

---Read the header of the script behind a row.
---@param row dev.Row a row from `find`, `commands` or `subs`
---@return dev.Header? header nil when the row has no script
function Registry:header(row)
    return row.script and self:__header(row.script, row.lang) or nil
end

---Check whether a word is a parent command, one that has subcommands.
---@param word string|string[] the words to check, or the name when it is one word
---@return boolean parent true for a built-in parent command or a directory of scripts no script of
---   the same name shadows
function Registry:is_parent(word)
    local row = self:find(type(word) == "string" and { word } or word)
    return row ~= nil and row.parent
end

---List the flags a command takes.
---
---A project script's `flags:` line decides when the row has a script, and a
---`-h` or `--help` in it is dropped with a warning, since dev reserves both.
---@param words string[] the command words
---@return string[] flags the flags, empty when nothing answers to the words
function Registry:flags(words)
    local view, bare = scope(self, words)
    if not view then
        return {}
    end
    if view ~= self then
        return view:flags(bare)
    end
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
