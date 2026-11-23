local fs = require("dev.fs")
local header = require("dev.header")
local project = require("dev.project")
local registry = require("dev.registry")
local text_width = require("dev.text").width

local MAX_WIDTH = 80
local CODEPOINT = "[%z\1-\127\194-\244][\128-\191]*"
local NAME = "^[A-Za-z0-9_-]+$"
local ACCEPTED_FLAGS = { ["--"] = true, ["-h"] = true, ["--help"] = true }
for _, flag in ipairs(registry.GLOBAL_FLAGS) do
    ACCEPTED_FLAGS[flag] = true
end
local COMMAND_END = { ["|"] = true, ["||"] = true, ["&&"] = true, [";"] = true, [">"] = true }
local RESERVED_FLAGS_MESSAGE = "the flags line declares -h or --help, which dev reserves before --"

---@class dev.topics.File
---@field name string the topic's name
---@field path string absolute path of the topic
---@field builtin boolean whether it ships with dev rather than with the project

---@class dev.topics.Problem
---@field file string path shown for the problem, relative to the project when inside it
---@field line integer the line of the problem
---@field message string what is wrong

---@class dev.topics
local M = {}

---List the topic files, the built-in ones first.
---@param root string project root
---@return dev.topics.File[] files the topics, each directory in name order
function M.files(root)
    local builtin = project.share .. "/docs"
    local files = {}
    for _, dir in ipairs({ builtin, root .. "/.dev/topics" }) do
        for _, file in ipairs(fs.list(dir) or {}) do
            local name = file:match("^([^.].*)%.md$")
            if name and fs.is_file(dir .. "/" .. file) then
                files[#files + 1] =
                    { name = name, path = dir .. "/" .. file, builtin = dir == builtin }
            end
        end
    end
    return files
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

local function has_sub(reg, noun, sub)
    for _, row in ipairs(reg:subs(noun)) do
        if row.words[#row.words] == sub then
            return true
        end
    end
    return false
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
    while reg:is_noun(path) do
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
    local shown = shown_path(reg.root, file.path)
    local function problem(line, message)
        out[#out + 1] = { file = shown, line = line, message = message }
    end
    if not file.name:find(NAME) then
        problem(1, "the topic name must use only letters, digits, - and _")
    end
    local text = fs.read(file.path) or ""
    local first = text:match("^[^\n]*")
    local prefix = "# " .. file.name .. ": "
    if not (first:sub(1, #prefix) == prefix and #first > #prefix) then
        problem(1, 'the first line must be "# ' .. file.name .. ': <summary>"')
    end
    if not file.builtin and fs.is_file(project.share .. "/docs/" .. file.name .. ".md") then
        problem(1, "topic " .. file.name .. " is also a built-in topic")
    end
    if reg:find({ file.name }) then
        problem(1, "topic " .. file.name .. " is also a command")
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

---Check the topics and every script header against the real commands and flags.
---
---The built-in topics sit in the `docs` folder beside `main.lua`, so they are
---checked when that folder lies inside the project, and the project's topics in
---every project. A topic's first line must be `# <name>: <summary>`, its name
---may not clash with a built-in topic or a command, and each backticked `dev ...` span or
---fenced `dev ...` line must name a real command or subcommand and only flags
---`Registry:flags` or `Registry:shadowed_flags` lists. A script whose flags line declares
---`-h` or `--help` is a problem too.
---@param reg dev.Registry the project's registry, whose warnings are ignored
---@return dev.topics.Problem[] problems the problems in the order they were found
function M.check(reg)
    local out = {}
    local here, share = fs.realpath(reg.root), fs.realpath(project.share)
    local own = here ~= nil
        and share ~= nil
        and (share == here or share:sub(1, #here + 1) == here .. "/")
    for _, file in ipairs(M.files(reg.root)) do
        if own or not file.builtin then
            check_file(reg, file, out)
        end
    end
    for _, script in ipairs(reg:scripts()) do
        local parsed = header.parse(fs.read(script.path) or "", script.lang, script.path)
        if script.source == registry.Source.PROJECT and #parsed.warnings > 0 then
            out[#out + 1] = {
                file = shown_path(reg.root, script.path),
                line = 1,
                message = RESERVED_FLAGS_MESSAGE,
            }
        end
    end
    return out
end

return M
