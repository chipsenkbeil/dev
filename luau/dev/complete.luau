local dev_os = require("@dev/os")
local registry = require("@dev/registry")
local topics = require("@dev/topics")

local VALUE_FLAGS = registry.VALUE_FLAGS
local HELP_FLAGS = { "-h", "--help" }

---@class dev.complete.Item
---@field value string the word a shell inserts
---@field desc string? the text shown beside it

---@class dev.complete.Context
---@field root string the project root
---@field reg dev.Registry the project's registry
---@field words string[] the words before the one being typed, command words first
---@field positional string[] the words of `words` after the command that are arguments
---@field cur string the word being typed
---@field flag string? the flag whose value is being typed
---@field home string? the home folder, for `~` in a file word

---@class dev.complete
local M = {}

local function item(entry)
    if type(entry) == "string" then
        return { value = entry }
    end
    return { value = entry.value or entry[1], desc = entry.desc or entry[2] }
end

local function items_of(list)
    local out = {}
    for _, entry in ipairs(list or {}) do
        out[#out + 1] = item(entry)
    end
    return out
end

local function provider(name)
    local ok, module = pcall(require, "@dev/complete/" .. name:gsub("-", "_"))
    return ok and module or nil
end

---List the values a flag or an argument's `complete` field names.
---@param def { choices: string[]?, complete: any }? the flag or arg of a spec
---@param ctx dev.complete.Context the completion context
---@return dev.complete.Item[] items nothing when the provider errors
function M.values(def, ctx)
    if not def then
        return {}
    end
    local source = def.complete
    local ok, found = true, nil
    if type(source) == "function" then
        ok, found = pcall(source, ctx)
    elseif type(source) == "string" then
        local module = provider(source)
        ok, found = false, nil
        if module then
            ok, found = pcall(module.candidates, ctx)
        end
    elseif type(source) == "table" then
        found = source
    elseif def.choices then
        found = def.choices
    end
    return ok and items_of(found) or {}
end

---List the commands as completion items, hidden ones left out.
---@param reg dev.Registry the project's registry
---@return dev.complete.Item[] items one per command
function M.commands(reg)
    local out = {}
    for _, row in ipairs(reg:commands()) do
        if not row.hidden then
            out[#out + 1] = { value = row.name, desc = row.desc }
        end
    end
    return out
end

---List the subcommands of a parent command as completion items.
---@param reg dev.Registry the project's registry
---@param words string[] the parent's words
---@return dev.complete.Item[] items one per subcommand
function M.subs(reg, words)
    local out = {}
    if reg:is_parent(words) then
        for _, row in ipairs(reg:subs(words)) do
            out[#out + 1] = { value = row.words[#row.words], desc = row.desc }
        end
    end
    return out
end

---List the help pages as completion items.
---@param root string the project root
---@return dev.complete.Item[] items one per help page
function M.topics(root)
    local out, seen = {}, {}
    for _, file in ipairs(topics.files(root)) do
        if not seen[file.name] then
            seen[file.name] = true
            out[#out + 1] = { value = file.name, desc = topics.summary(file) }
        end
    end
    return out
end

local function flag_words(spec)
    local out = {}
    for _, flag in ipairs(spec and spec.flags or {}) do
        out[#out + 1] = { value = "--" .. flag.name, desc = flag.help }
        if flag.short then
            out[#out + 1] = { value = "-" .. flag.short, desc = flag.help }
        end
    end
    return out
end

local function flag_index(spec)
    local index = {}
    for _, flag in ipairs(spec and spec.flags or {}) do
        index["--" .. flag.name] = flag
        if flag.short then
            index["-" .. flag.short] = flag
        end
    end
    return index
end

local function global_items()
    local out = {}
    for _, flag in ipairs(registry.GLOBAL_FLAGS) do
        out[#out + 1] = { value = flag }
    end
    return out
end

local function leading_globals(words)
    local root_dir
    local i = 1
    while words[i] do
        local word = words[i]
        if VALUE_FLAGS[word] then
            if not words[i + 1] then
                return i, root_dir, word
            end
            if word == "-C" then
                root_dir = words[i + 1]
            end
            i = i + 2
        elseif registry.is_bare(word) then
            i = i + 1
        else
            break
        end
    end
    return i, root_dir
end

local function walk_arguments(spec, rest)
    local index = flag_index(spec)
    local positional, pending = {}, nil
    local i = 1
    while i <= #rest do
        local word = rest[i]
        local flag = index[word]
        if word == "--" then
            break
        elseif flag and flag.kind ~= "boolean" then
            if i == #rest then
                pending = flag
            end
            i = i + 2
        elseif word:sub(1, 1) == "-" and #word > 1 then
            i = i + 1
        else
            positional[#positional + 1] = word
            i = i + 1
        end
    end
    return positional, pending, index
end

local function arg_def(spec, count)
    local args = spec and spec.args or {}
    local def = args[count + 1]
    if not def and #args > 0 and args[#args].list then
        def = args[#args]
    end
    return def
end

---List what the word being typed can become.
---
---`words` holds every word typed after `dev`, the last being the one under the cursor. The list
---is not filtered by that word.
---@param root string the project root
---@param reg dev.Registry the project's registry
---@param words string[] the words, the last one possibly empty
---@return dev.complete.Item[] items the candidates
---@return string cur the word being typed
function M.candidates(root, reg, words)
    local typed = { table.unpack(words) }
    local cur = table.remove(typed) or ""
    local start, dir, waiting = leading_globals(typed)
    local home = dev_os.getenv("HOME")
    if dir then
        if home and home ~= "" and (dir == "~" or dir:sub(1, 2) == "~/") then
            dir = home .. dir:sub(2)
        end
        root = dir
        reg = registry.load(dir, { warn = function() end })
    end
    if waiting then
        if waiting == "-C" then
            local ctx =
                { root = root, reg = reg, words = {}, positional = {}, cur = cur, home = home }
            return M.values({ complete = "file" }, ctx), cur
        end
        return {}, cur
    end
    local prior = { table.unpack(typed, start) }
    if #prior == 0 then
        if cur:sub(1, 1) == "-" then
            return global_items(), cur
        end
        return M.commands(reg), cur
    end
    local path = { prior[1] }
    local row = reg:find(path)
    if not row then
        return {}, cur
    end
    local at = 2
    while row.parent do
        local word = prior[at]
        if not word then
            if cur:sub(1, 1) == "-" then
                return items_of(HELP_FLAGS), cur
            end
            return M.subs(reg, path), cur
        end
        path[#path + 1] = word
        row = reg:find(path)
        if not row then
            return {}, cur
        end
        at = at + 1
    end
    local ok, spec = pcall(reg.spec, reg, row)
    spec = ok and spec or nil
    local rest = { table.unpack(prior, at) }
    local positional, pending, index = walk_arguments(spec, rest)
    local ctx = {
        root = root,
        reg = reg,
        words = prior,
        positional = positional,
        cur = cur,
        home = home,
    }
    for _, word in ipairs(rest) do
        if word == "--" then
            return {}, cur
        end
    end
    if pending then
        ctx.flag = pending.name
        return M.values(pending, ctx), cur
    end
    local name, value = cur:match("^(%-%-[^=]+)=(.*)$")
    if name and index[name] and index[name].kind ~= "boolean" then
        ctx.flag = index[name].name
        ctx.cur = value
        local out = {}
        for _, found in ipairs(M.values(index[name], ctx)) do
            out[#out + 1] = { value = name .. "=" .. found.value, desc = found.desc }
        end
        return out, cur
    end
    if cur:sub(1, 1) == "-" then
        local out = flag_words(spec)
        for _, flag in ipairs(HELP_FLAGS) do
            out[#out + 1] = { value = flag }
        end
        for _, global in ipairs(global_items()) do
            out[#out + 1] = global
        end
        return out, cur
    end
    return M.values(arg_def(spec, #positional), ctx), cur
end

---Print `value<TAB>description` for each candidate that starts with the word being typed.
---@param root string the project root
---@param reg dev.Registry the project's registry
---@param words string[] the words typed after `dev`, the last one being completed
---@return integer code 0, also when a provider fails or has nothing
function M.run(root, reg, words)
    local ok, items, cur = pcall(M.candidates, root, reg, words)
    if not ok then
        return 0
    end
    local seen = {}
    for _, found in ipairs(items) do
        if found.value:sub(1, #cur) == cur and not seen[found.value] then
            seen[found.value] = true
            local desc = found.desc and found.desc ~= "" and "\t" .. found.desc or ""

            -- Raw write: the TAB between value and description must reach the shell as it is.
            dev_os.stdout:write(found.value, desc, "\n")
        end
    end
    return 0
end

return M
