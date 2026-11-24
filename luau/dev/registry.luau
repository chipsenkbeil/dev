local command = require("@dev/command")
local fs = require("@dev/fs")
local header = require("@dev/header")
local runtime = require("@dev/runtime")
local dev_os = require("@dev/os")
local xdg = require("@dev/xdg")

local WORD = "^[A-Za-z0-9_-]+$"
local stderr = dev_os.stderr
local HIDDEN_GROUP = "hidden"
local BUILTIN_BASE = "luau/dev/commands"
local BARE_FLAGS = {
    "-v",
    "--verbose",
    "-vv",
    "--remote",
    "--local",
    "--detach",
    "--priority",
    "--version",
    "-V",
}
local VALUE_FLAGS = { "-C", "--agent", "--job-timeout" }
local GLOBAL_FLAGS = {}
local EXTENSIONS = { luau = 1, sh = 2, ps1 = 3 }

---@enum dev.Source
local Source = { BUILTIN = "builtin", GLOBAL = "global", PROJECT = "project" }

---@enum dev.Kind
local Kind = { BUILTIN = "builtin", OVERRIDE = "override", LOCAL = "local" }
---The layers from the one that wins to the one that loses
local LAYERS = { Source.PROJECT, Source.GLOBAL, Source.BUILTIN }

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
---@field path string path of the script, or the embedded asset path of a builtin command
---@field lang "luau"|"sh"|"ps1" language of the script
---@field source dev.Source the layer the script sits in
---@field replaces dev.Source? the nearest lower layer with a script of the same words

---@class dev.Row
---@field words string[] the command words, with the parent command first in a subcommand's
---@field name string the words joined by a space
---@field kind dev.Kind `override` for a script that replaces a builtin
---   command, `builtin` for a builtin one
---@field source dev.Source which layer answers
---@field replaces dev.Source? the nearest lower layer with a script of the same words
---@field parent boolean whether the row is a command with subcommands
---@field desc string description shown in `dev help`, the spec's summary
---@field group string? heading in `dev help`
---@field hidden boolean? whether `dev help` keeps the row to `-a`
---@field remote false? false when the command never runs on a remote runner
---@field requires string[]? the preconditions the command declares, `workspace` the only one known
---@field script string? path of the file behind the row, or its embedded asset path
---@field lang "luau"|"sh"|"ps1"? language of that file
---@field broken string? why the file's spec could not be loaded

---@class dev.Dir
---@field scripts table<string, dev.Script> the scripts in the folder by name
---@field order string[] names in `scripts` in listing order
---@field subs string[] names of the folders inside it in listing order
---@field source dev.Source the layer the folder sits in
---@field path string the folder's path

---@class dev.Registry
---@field root string project root
---@field global string the global commands folder
---@field warn fun(message: string) receives each warning about a command file
---@field private dirs table<string, dev.Dir|false> the folders read so far by layer and path
---@field private rows table<string, dev.Row|false> resolved command rows by name
---@field private specs table<string, dev.Spec|false> loaded specs by file path
---@field private reasons table<string, string> why a spec failed to load, by file path
---@field private codes table<string, string> the `dev.spec` `Reason` of a failed load, by file path
---@field private only dev.Source? the one layer a view answers from, nil for the whole registry
---@field private views table<string, dev.Registry> the views made so far by source
local Registry = {}
Registry.__index = Registry

---@class dev.registry
local M = {}

M.Source = Source
M.Kind = Kind

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

---Find the folder of the user's global commands.
---@return string dir `dev/commands` under the user config folder
function M.global_dir()
    return fs.join(xdg.config_home(), "dev", "commands")
end

---Show a script's path the way `-v` prints it.
---@param row dev.Row a row with a script
---@param root string project root
---@return string path relative to the project root, or to the global folder for a global script,
---   or the embedded path of a builtin one
function M.relative(row, root)
    if row.source == Source.BUILTIN then
        return row.script
    end
    local base = row.source == Source.GLOBAL and M.global_dir() or root
    return row.script:sub(#base + 2)
end

local function base_of(self, source)
    if source == Source.PROJECT then
        return fs.join(self.root, ".dev", "commands")
    end
    if source == Source.GLOBAL then
        return self.global
    end
    return BUILTIN_BASE
end

local function is_folder(source, path)
    if source == Source.BUILTIN then
        return #runtime.assets(path) > 0
    end
    return fs.is_dir(path)
end

local function names_in(source, path)
    if source == Source.BUILTIN then
        return runtime.assets(path)
    end
    local names = fs.list(path) or {}
    table.sort(names)
    return names
end

local function copy(row)
    local out = {}
    for key, value in pairs(row) do
        out[key] = value
    end
    return out
end

local function join_rel(rel, word)
    if rel == "" or word == "" then
        return rel .. word
    end
    return rel .. "/" .. word
end

function Registry:__layers()
    if self.only then
        return { self.only }
    end
    return LAYERS
end

local function read_dir(self, source, rel)
    local path = join_rel(base_of(self, source), rel)
    if not is_folder(source, path) then
        return nil
    end
    local dir = { scripts = {}, order = {}, subs = {}, source = source, path = path }
    local rank = {}
    for _, file in ipairs(names_in(source, path)) do
        local full = path .. "/" .. file
        local name, ext = file:match("^(.+)%.(%w+)$")
        if name and ext == "lua" and source ~= Source.BUILTIN and fs.is_file(full) then
            self.warn("Command files end in .luau, not .lua: " .. full .. ".")
        elseif name and EXTENSIONS[ext] and name:find(WORD) then
            local usable = source == Source.BUILTIN
                or (fs.is_file(full) and (ext ~= "sh" or fs.is_exec(full)))
            if usable and (not rank[name] or EXTENSIONS[ext] < rank[name]) then
                if not rank[name] then
                    dir.order[#dir.order + 1] = name
                end
                rank[name] = EXTENSIONS[ext]
                dir.scripts[name] = { path = full, lang = ext, source = source }
            end
        elseif file:find(WORD) and is_folder(source, full) then
            dir.subs[#dir.subs + 1] = file
        end
    end
    return dir
end

function Registry:__dir(source, rel)
    local key = source .. ":" .. rel
    local cached = self.dirs[key]
    if cached ~= nil then
        return cached or nil
    end
    local dir = read_dir(self, source, rel)
    self.dirs[key] = dir or false
    return dir
end

function Registry:__has_subs(source, rel)
    local dir = self:__dir(source, rel)
    if not dir then
        return false
    end
    if #dir.order > 0 then
        return true
    end
    for _, sub in ipairs(dir.subs) do
        if self:__has_subs(source, join_rel(rel, sub)) then
            return true
        end
    end
    return false
end

---Pick what answers to a path: a script from the highest layer that has one, or a parent command.
---
---A folder in a higher layer hides a script of a lower one, a script beats a folder of its own
---layer, and no script replaces a builtin parent command.
function Registry:__resolve(rel)
    local layers = self:__layers()
    local builtin = false
    for _, source in ipairs(layers) do
        if source == Source.BUILTIN then
            local dir = self:__dir(source, rel)
            local up = rel:match("^(.*)/[^/]*$") or ""
            local parent_dir = self:__dir(source, up)
            local word = rel:match("([^/]*)$")
            builtin = dir ~= nil
                and self:__has_subs(source, rel)
                and not (parent_dir and parent_dir.scripts[word])
        end
    end
    local up = rel:match("^(.*)/[^/]*$") or ""
    local word = rel:match("([^/]*)$")
    local folders = {}
    for _, source in ipairs(layers) do
        if self:__has_subs(source, rel) then
            folders[#folders + 1] = source
        end
    end
    if not builtin then
        for _, source in ipairs(layers) do
            local dir = self:__dir(source, up)
            local script = dir and dir.scripts[word]
            if script then
                return { script = script, folders = folders }
            end
            if self:__has_subs(source, rel) then
                break
            end
        end
    end
    if #folders > 0 then
        return { folders = folders }
    end
    return nil
end

---The spec behind a row, loaded on first use.
---@param row dev.Row a row from `find`, `commands` or `subs`
---@return dev.Spec? spec nil when the row has no file or the file does not load
---@return string? reason why the file does not load
---@return string? code a `dev.spec` `Reason` when the reason has one
function Registry:spec(row)
    if not row.script then
        return nil, "the row has no file"
    end
    local path = row.script
    local cached = self.specs[path]
    if cached ~= nil then
        if cached then
            return cached
        end
        return nil, self.reasons[path], self.codes[path]
    end
    local spec, reason, code
    if row.lang == "luau" then
        spec, reason, code = command.load(path, row.source == Source.BUILTIN)
    else
        local text, why = fs.read(path)
        if text then
            spec, reason, code = header.parse(text, path)
        else
            reason = "cannot read " .. path .. ": " .. tostring(why)
        end
    end
    self.specs[path] = spec or false
    self.reasons[path] = reason
    self.codes[path] = code
    return spec, reason, code
end

local function declare(row, spec)
    if spec.remote == false then
        row.remote = false
    end
    if spec.requires and #spec.requires > 0 then
        row.requires = { table.unpack(spec.requires) }
    end
end

function Registry:__place(row, spec)
    local group = spec and spec.group or ""
    local hidden = spec and spec.hidden or false
    if group == HIDDEN_GROUP then
        hidden = true
    end
    if group == "" or group == HIDDEN_GROUP then
        group = fs.basename(self.root)
    end
    row.group, row.hidden = group, hidden
end

function Registry:__description(rel, folders)
    for _, source in ipairs(folders) do
        local path = join_rel(base_of(self, source), rel) .. "/DESCRIPTION"
        local text = source == Source.BUILTIN and runtime.asset(path) or fs.read(path)
        local line = text and text:match("^[^\n]*") or ""
        if line ~= "" then
            return line
        end
    end
    return nil
end

function Registry:__sub_names(rel, folders)
    local names, seen = {}, {}
    local order = {}
    for _, source in ipairs({ Source.BUILTIN, Source.PROJECT, Source.GLOBAL }) do
        for _, kept in ipairs(folders) do
            if kept == source then
                order[#order + 1] = source
            end
        end
    end
    for _, source in ipairs(order) do
        local dir = self:__dir(source, rel)
        for _, sub in ipairs(dir and dir.order or {}) do
            if not seen[sub] then
                seen[sub] = true
                names[#names + 1] = sub
            end
        end
        for _, sub in ipairs(dir and dir.subs or {}) do
            if not seen[sub] and self:__has_subs(source, join_rel(rel, sub)) then
                seen[sub] = true
                names[#names + 1] = sub
            end
        end
    end
    return names
end

local function hides(spec)
    return spec ~= nil and (spec.hidden == true or spec.group == HIDDEN_GROUP)
end

---Report whether the command at `rel` stays out of its parent's listing: a script marked hidden,
---or a folder whose subcommands are all hidden.
---@private
function Registry:__is_hidden(rel)
    local found = self:__resolve(rel)
    if not found then
        return false
    end
    local script = found.script
    if script then
        local spec = self:spec({ script = script.path, lang = script.lang, source = script.source })
        return hides(spec)
    end
    local _, hidden = self:__first_group(rel, found.folders)
    return hidden
end

function Registry:__parent_desc(rel, folders)
    local line = self:__description(rel, folders)
    if line then
        return line
    end
    local shown = {}
    for _, sub in ipairs(self:__sub_names(rel, folders)) do
        if not self:__is_hidden(join_rel(rel, sub)) then
            shown[#shown + 1] = sub
        end
    end
    return table.concat(shown, ", ")
end

function Registry:__first_group(rel, folders)
    local group
    local names = self:__sub_names(rel, folders)
    local all_hidden = #names > 0
    for _, sub in ipairs(names) do
        local child = join_rel(rel, sub)
        local found = self:__resolve(child)
        local script = found and found.script
        local spec = script
            and self:spec({ script = script.path, lang = script.lang, source = script.source })
        local hidden = hides(spec)
        if
            spec
            and spec.group
            and spec.group ~= ""
            and spec.group ~= HIDDEN_GROUP
            and not group
        then
            group = spec.group
        end
        if found and not script then
            local below, below_hidden = self:__first_group(child, found.folders)
            group = group or below
            hidden = below_hidden
        end
        all_hidden = all_hidden and hidden
    end
    return group, all_hidden
end

local function lower_script(self, source, rel)
    local up = rel:match("^(.*)/[^/]*$") or ""
    local word = rel:match("([^/]*)$")
    local below = false
    local found, builtin
    for _, layer in ipairs(self:__layers()) do
        if layer == source then
            below = true
        elseif below then
            local dir = self:__dir(layer, up)
            local script = dir and dir.scripts[word]
            if script then
                found = found or script
                builtin = builtin or (layer == Source.BUILTIN and script)
            end
        end
    end
    return found, builtin
end

function Registry:__row(rel)
    local cached = self.rows[rel]
    if cached ~= nil then
        return cached or nil
    end
    local words = {}
    for word in rel:gmatch("[^/]+") do
        words[#words + 1] = word
    end
    local up = #words > 1 and table.concat(words, "/", 1, #words - 1) or nil
    local parent = up and self:__row(up)
    if up and not (parent and parent.parent) then
        self.rows[rel] = false
        return nil
    end
    local found = self:__resolve(rel)
    local row
    if found and found.script then
        local script = found.script
        local lower, builtin = lower_script(self, script.source, rel)
        row = {
            words = words,
            kind = script.source == Source.BUILTIN and Kind.BUILTIN
                or (builtin and Kind.OVERRIDE or Kind.LOCAL),
            source = script.source,
            replaces = lower and lower.source or nil,
            parent = false,
            script = script.path,
            lang = script.lang,
            desc = "",
            shadowed = builtin and builtin.path or nil,
        }
        local spec, reason = self:spec(row)
        if spec then
            row.desc = spec.summary or ""
            declare(row, spec)
        else
            row.broken = reason
        end
        row.name = table.concat(words, " ")
        local placed = spec
        if builtin and not (spec and spec.group and spec.group ~= "") then
            placed = self:spec({
                script = builtin.path,
                lang = builtin.lang,
                source = builtin.source,
            }) or spec
        end
        self:__place(row, placed)
        for _, source in ipairs(found.folders) do
            if source == script.source and source ~= Source.BUILTIN then
                self.warn(
                    "The script "
                        .. script.path
                        .. " shadows the folder "
                        .. join_rel(base_of(self, source), rel)
                        .. ". Its subcommands never run."
                )
            end
        end
    elseif found then
        row = {
            words = words,
            kind = found.folders[1] == Source.BUILTIN and Kind.BUILTIN or Kind.LOCAL,
            source = found.folders[1],
            parent = true,
            folders = found.folders,
        }
        row.desc = self:__parent_desc(rel, found.folders)
        row.name = table.concat(words, " ")
        local group, hidden = self:__first_group(rel, found.folders)
        self:__place(row, { group = group, hidden = hidden })
    end
    if row and parent then
        row.group, row.hidden = parent.group, row.hidden
        if not row.parent and row.script then
            row.group = parent.group
        end
    end
    self.rows[rel] = row or false
    return row
end

---Read the command folders of a project, the global folder and the builtin commands.
---
---Each layer is noun folders plus `.luau`, `.sh` and `.ps1` files. A `.sh` command needs its exec
---bit. For one name `.luau` beats `.sh`, which beats `.ps1`. A `.lua` file is refused with a
---warning.
---@param root string project root
---@param opts {warn: fun(message: string)?}? `warn` receives the warnings and writes to standard
---   error by default
---@return dev.Registry registry the registry of the project
function M.load(root, opts)
    return setmetatable({
        root = root,
        global = M.global_dir(),
        warn = opts and opts.warn or function(message)
            stderr:write(message, "\n")
        end,
        dirs = {},
        specs = {},
        reasons = {},
        codes = {},
        rows = {},
        views = {},
    }, Registry)
end

---Make the registry that answers from one layer alone.
---
---The builtin view holds the builtin rows and no other. The global view holds the commands of the
---global folder and no builtin row, so a global command of a builtin's name is a local row there.
---@param source dev.Source `builtin` or `global`
---@return dev.Registry view the registry of that layer
function Registry:view(source)
    local view = self.views[source]
    if not view then
        view = setmetatable({
            root = self.root,
            global = self.global,
            warn = self.warn,
            dirs = self.dirs,
            specs = self.specs,
            reasons = self.reasons,
            codes = self.codes,
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
---A project command beats a global one, which beats a builtin one, though no script replaces a
---builtin parent command. A script beats a folder of the same name in its own layer, but a folder
---beats a script of a lower layer. A first word `builtin:WORD` or `global:WORD` answers from that
---layer alone, and the row's words are the bare ones.
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
    if #words == 0 then
        return nil
    end
    for _, word in ipairs(words) do
        if not word:find(WORD) then
            return nil
        end
    end
    return self:__row(table.concat(words, "/"))
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
        local row = self:find({ table.unpack(words, 1, count) })
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

local function top_names(self)
    local names, seen = {}, {}
    for _, source in ipairs({ Source.BUILTIN, Source.PROJECT, Source.GLOBAL }) do
        local kept = false
        for _, layer in ipairs(self:__layers()) do
            kept = kept or layer == source
        end
        local dir = kept and self:__dir(source, "")
        for _, name in ipairs(dir and dir.order or {}) do
            if not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
        for _, name in ipairs(dir and dir.subs or {}) do
            if not seen[name] and self:__has_subs(source, name) then
                seen[name] = true
                names[#names + 1] = name
            end
        end
    end
    return names
end

---List the commands.
---
---The builtin ones come first, then the project's and the global ones.
---@return dev.Row[] rows the rows, with a builtin one overridden by a script in a higher layer
function Registry:commands()
    local rows = {}
    for _, name in ipairs(top_names(self)) do
        rows[#rows + 1] = self:__row(name)
    end
    return rows
end

---@class dev.registry.subs.Opts
---@field all boolean? whether the hidden subcommands are listed too

---List the subcommands of a command, leaving out the hidden ones unless `opts.all` is set.
---@param path string|string[] the parent command's words, or its name when it is one word
---@param opts dev.registry.subs.Opts? the options
---@return dev.Row[] rows the subcommands, none for words that are not a parent command
function Registry:subs(path, opts)
    local words = type(path) == "string" and { path } or path
    local view, bare = scope(self, words)
    if not view then
        return {}
    end
    if view ~= self then
        return view:subs(bare, opts)
    end
    local found = self:find(words)
    local rows = {}
    if not (found and found.parent) then
        return rows
    end
    local rel = table.concat(found.words, "/")
    for _, sub in ipairs(self:__sub_names(rel, found.folders)) do
        local row = self:__row(join_rel(rel, sub))
        if row and ((opts and opts.all) or not row.hidden) then
            rows[#rows + 1] = row
        end
    end
    return rows
end

local function collect(self, source, rel, out, seen)
    local dir = self:__dir(source, rel)
    if not dir or seen[dir] then
        return
    end
    seen[dir] = true
    for _, script in ipairs(dir.order) do
        local entry = dir.scripts[script]
        entry.name = (rel == "" and "" or rel:gsub("/", " ") .. " ") .. script
        out[#out + 1] = entry
    end
    for _, sub in ipairs(dir.subs) do
        collect(self, source, join_rel(rel, sub), out, seen)
    end
end

---List every command file of the project and the global folder, each folder's own before the ones
---inside it.
---@return dev.Script[] scripts the files
function Registry:scripts()
    local out = {}
    for _, source in ipairs({ Source.PROJECT, Source.GLOBAL }) do
        collect(self, source, "", out, {})
    end
    return out
end

---Check whether a word is a parent command, one that has subcommands.
---@param word string|string[] the words to check, or the name when it is one word
---@return boolean parent true for a folder of commands no script of its own layer or a higher one
---   shadows
function Registry:is_parent(word)
    local row = self:find(type(word) == "string" and { word } or word)
    return row ~= nil and row.parent
end

local function flag_words(spec)
    local flags = {}
    for _, flag in ipairs(spec and spec.flags or {}) do
        flags[#flags + 1] = "--" .. flag.name
        if flag.short then
            flags[#flags + 1] = "-" .. flag.short
        end
    end
    return flags
end

---List the flags a command takes, a long name then its short one.
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
    if not (row and row.script) then
        return {}
    end
    return flag_words((self:spec(row)))
end

---List the flags of the builtin command a project or global command replaces.
---@param words string[] the command words
---@return string[] flags the builtin command's flags, empty unless a command of kind `override`
---   answers to the words
function Registry:shadowed_flags(words)
    local row = self:find(words)
    if not (row and row.kind == Kind.OVERRIDE) then
        return {}
    end
    local below = self:view(Source.BUILTIN):find(row.words)
    return flag_words(below and self:view(Source.BUILTIN):spec(below))
end

return M
