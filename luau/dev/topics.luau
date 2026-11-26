local fs = require("@dev/fs")
local registry = require("@dev/registry")
local spec_check = require("@dev/spec")
local SEE_ALSO_FIELD = spec_check.SEE_ALSO_FIELD
local runtime = require("@dev/runtime")
local text_width = require("@dev/text").width

local MAX_WIDTH = 80
local CODEPOINT = "[%z\1-\127\194-\244][\128-\191]*"
local NAME = "^[A-Za-z0-9_-]+$"
local ACCEPTED_FLAGS = { ["--"] = true, ["-h"] = true, ["--help"] = true }
for _, flag in ipairs(registry.GLOBAL_FLAGS) do
    ACCEPTED_FLAGS[flag] = true
end
local COMMAND_END = { ["|"] = true, ["||"] = true, ["&&"] = true, [";"] = true, [">"] = true }
local RESERVED_FLAGS_MESSAGE = "the spec declares -h or --help, which dev reserves before --"
local DOCS = "docs"
local OVERVIEW = "overview"

---@class dev.topics.File
---@field name string the topic's name
---@field path string the asset path of a built-in topic, the absolute path of a project one
---@field builtin boolean whether it ships with dev rather than with the project

---@class dev.topics.Problem
---@field file string path shown for the problem, relative to the project when inside it
---@field line integer the line of the problem
---@field message string what is wrong

---@class dev.topics
local M = {}

M.OVERVIEW = OVERVIEW

local function is_own(root)
    return fs.is_file(root .. "/luau/dev/cli.luau")
end

local function builtin_files(names)
    local files = {}
    for _, file in ipairs(names) do
        local name = file:match("^([^.].*)%.md$")
        if name then
            files[#files + 1] = { name = name, path = DOCS .. "/" .. file, builtin = true }
        end
    end
    return files
end

---List the topic files, the built-in ones first.
---@param root string project root
---@return dev.topics.File[] files the topics, each folder in name order
function M.files(root)
    local files = builtin_files(runtime.assets(DOCS))
    local dir = root .. "/.dev/help"
    for _, file in ipairs(fs.list(dir) or {}) do
        local name = file:match("^([^.].*)%.md$")
        if name and fs.is_file(dir .. "/" .. file) then
            files[#files + 1] = { name = name, path = dir .. "/" .. file, builtin = false }
        end
    end
    return files
end

---Read a topic's text.
---@param file dev.topics.File a topic from `files`
---@return string text the file's text, empty when it cannot be read
function M.text(file)
    if file.builtin then
        return runtime.asset(file.path) or ""
    end
    return fs.read(file.path) or ""
end

---Return a topic's one-line summary, the part of its first line after the colon.
---@param file dev.topics.File a topic from `files`
---@return string summary the summary
function M.summary(file)
    local first = M.text(file):match("^[^\n]*")
    local cut = first:find(": ", 1, true)
    return cut and first:sub(cut + 2) or first
end

local function words_of(line)
    local words = {}
    for word in line:gmatch("%S+") do
        words[#words + 1] = word
    end
    return words
end

local function is_placeholder(word)
    return word == "" or word:find("^[<%[-]") ~= nil
end

local function has_sub(reg, parent, sub)
    local words = { table.unpack(parent) }
    words[#words + 1] = sub
    return reg:find(words) ~= nil
end

local function skip_global(words, i)
    while words[i] and (registry.is_bare(words[i]) or registry.VALUE_FLAGS[words[i]]) do
        i = i + (registry.VALUE_FLAGS[words[i]] and 2 or 1)
    end
    return i
end

local function command_error(reg, line)
    local words = words_of(line)
    local i = skip_global(words, 2)
    local name = words[i] or ""
    if is_placeholder(name) or name:sub(1, 2) == "__" then
        return nil
    end
    local path = { name }
    if not reg:find(path) then
        return "no command " .. name
    end
    while reg:is_parent(path) do
        local next_word = words[i + 1] or ""
        if is_placeholder(next_word) then
            break
        end
        if not has_sub(reg, path, next_word) then
            return string.format("dev %s has no subcommand %s", table.concat(path, " "), next_word)
        end
        path[#path + 1] = next_word
        i = i + 1
    end
    local valid = {}
    local shown = table.concat(path, " ")
    for _, flag in ipairs(reg:flags(path)) do
        valid[flag] = true
    end
    for _, flag in ipairs(reg:shadowed_flags(path)) do
        valid[flag] = true
    end
    for j = i + 1, #words do
        local word = words[j]
        if COMMAND_END[word] or word:sub(1, 1) == "#" then
            break
        end
        word = word:gsub("^%[", ""):gsub("%].*$", ""):gsub("=.*$", "")
        if word:sub(1, 1) == "-" and not ACCEPTED_FLAGS[word] and not registry.is_bare(word) then
            if not valid[word] then
                return string.format("dev %s takes no flag %s", shown, word)
            end
        end
    end
end

local function shown_path(root, path)
    local prefix = root .. "/"
    return path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or path
end

local function can_wrap(line)
    if text_width(line) <= MAX_WIDTH then
        return false
    end
    local head = line:match("^" .. string.rep(CODEPOINT, MAX_WIDTH))
    return head ~= nil and line:find(" ", #head + 1, true) ~= nil
end

local function check_file(reg, file, out)
    local shown = file.builtin and file.path or shown_path(reg.root, file.path)
    local function problem(line, message)
        out[#out + 1] = { file = shown, line = line, message = message }
    end
    if not file.name:find(NAME) then
        problem(1, "the help page name must use only letters, digits, - and _")
    end
    local text = file.builtin and (fs.read(reg.root .. "/" .. file.path) or "") or M.text(file)
    local first = text:match("^[^\n]*")
    local prefix = "# " .. file.name .. ": "
    if not (first:sub(1, #prefix) == prefix and #first > #prefix) then
        problem(1, 'the first line must be "# ' .. file.name .. ': <summary>"')
    end
    if
        not file.builtin
        and file.name ~= OVERVIEW
        and runtime.asset(DOCS .. "/" .. file.name .. ".md")
    then
        problem(1, "help page " .. file.name .. " is also a built-in help page")
    end
    if reg:find({ file.name }) then
        problem(1, "help page " .. file.name .. " is also a command")
    end
    local fence = false
    local number = 0
    for line in (text .. (text:sub(-1) == "\n" and "" or "\n")):gmatch("([^\n]*)\n") do
        number = number + 1
        if line:sub(1, 3) == "```" then
            fence = not fence
        elseif fence then
            if line:sub(1, 4) == "dev " then
                local err = command_error(reg, line)
                if err then
                    problem(number, err)
                end
            end
        else
            if line:sub(1, 1) ~= "|" and can_wrap(line) then
                problem(number, "the line is wider than 80 columns")
            end
            for span in line:gmatch("`(dev [^`]*)`") do
                local err = command_error(reg, span)
                if err then
                    problem(number, "`" .. span .. "`: " .. err)
                end
            end
        end
    end
end

local function declares_help(code)
    return code == spec_check.Reason.RESERVED_FLAG
end

---Check the topics and every project command's spec against the real commands and flags.
---
---The built-in topics are baked into dev, so they are checked from the `docs` folder on disk when
---the project is dev itself, detected by `luau/dev/cli.luau` existing, and the project's topics
---in every project. A topic's first line must be `# <name>: <summary>`, its name
---may not clash with a built-in topic or a command, and each backticked `dev ...` span or
---fenced `dev ...` line must name a real command or subcommand and only flags
---`Registry:flags` or `Registry:shadowed_flags` lists. A project command whose spec declares
---`-h` or `--help` is a problem too.
---@param reg dev.Registry the project's registry, whose warnings are ignored
---@return dev.topics.Problem[] problems the problems in the order they were found
function M.check(reg)
    local out = {}
    local own = is_own(reg.root)
    local checked = own and builtin_files(fs.list(reg.root .. "/" .. DOCS) or {}) or {}
    local files = M.files(reg.root)
    for _, file in ipairs(files) do
        if not file.builtin then
            checked[#checked + 1] = file
        end
    end
    for _, file in ipairs(checked) do
        check_file(reg, file, out)
    end
    local pages = {}
    for _, file in ipairs(files) do
        pages[file.name] = true
    end
    for _, script in ipairs(reg:scripts()) do
        if script.source == registry.Source.PROJECT then
            local row = { name = script.name, script = script.path, lang = script.lang }
            local ok, spec, _, code = pcall(reg.spec, reg, row)
            local file = shown_path(reg.root, script.path)
            if ok and declares_help(code) then
                out[#out + 1] = { file = file, line = 1, message = RESERVED_FLAGS_MESSAGE }
            end
            for _, page in ipairs(ok and spec and spec[SEE_ALSO_FIELD] or {}) do
                if not pages[page] then
                    out[#out + 1] = {
                        file = file,
                        line = 1,
                        message = `the spec's {SEE_ALSO_FIELD} names {page}, which is no help page`,
                    }
                end
            end
        end
    end
    return out
end

return M
