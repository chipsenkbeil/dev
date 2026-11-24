local dev_os = require("dev.os")
local fs = require("dev.fs")

---The test suites a change touches, which a card's check runs in place of the whole suite.
---@class dev.board.select
local M = {}

local ROW = { "dev", "--remote", "test" }
local TESTS_PREFIX = "tests/"
local REQUIRE = "require%s*%(?%s*[\"']([%w_%.%-]+)[\"']"
local PREFIX_REQUIRE = "require%s*%(?%s*[\"']([%w_%.%-]+%.)[\"']%s*%.%."

local function is_suite(path)
    if path:sub(1, #TESTS_PREFIX) ~= TESTS_PREFIX then
        return false
    end
    local base = path:match("[^/]+$")
    return base:match("_test%.lua$") ~= nil
        or base:match("%.bats$") ~= nil
        or base:match("_test%.sh$") ~= nil
        or base:match("^test%-.*%.sh$") ~= nil
end

local function module_name(path)
    local tail = ("/" .. path):match("/lua/(.+)%.lua$")
    if not tail then
        return nil
    end
    return (tail:gsub("/init$", ""):gsub("/", "."))
end

local function is_verb(path)
    return path:match("%.lua$") ~= nil
        and path:sub(1, #TESTS_PREFIX) ~= TESTS_PREFIX
        and module_name(path) == nil
end

local function requires(text)
    return text:gmatch(REQUIRE)
end

---Find the modules that load a module, by name and by the prefix of a concatenated require.
---@param sources table<string, string> the text of each file by path
---@param names table<string, string> the module name of each Lua path
---@return table<string, table<string, boolean>> users the loaders by required name
---@return table<string, table<string, boolean>> prefix_users the loaders by name prefix
local function loaders(sources, names)
    local users, prefix_users = {}, {}
    for path, text in pairs(sources) do
        local name = names[path] or path
        for dep in requires(text) do
            users[dep] = users[dep] or {}
            users[dep][name] = true
        end
        for prefix in text:gmatch(PREFIX_REQUIRE) do
            prefix_users[prefix] = prefix_users[prefix] or {}
            prefix_users[prefix][name] = true
        end
    end
    return users, prefix_users
end

local function closure_of(start, users, prefix_users)
    local closure, queue = { [start] = true }, { start }
    local head = 1
    while head <= #queue do
        local name = queue[head]
        local found = { users[name] or {} }
        for prefix, loading in pairs(prefix_users) do
            if name:sub(1, #prefix) == prefix then
                found[#found + 1] = loading
            end
        end
        for _, set in ipairs(found) do
            for user in pairs(set) do
                if not closure[user] then
                    closure[user] = true
                    queue[#queue + 1] = user
                end
            end
        end
        head = head + 1
    end
    return closure
end

---Pick the suites that cover a change from the text of every Lua file and suite.
---
---A touched suite is picked itself. A touched Lua module picks every Lua suite that requires it,
---directly, through the modules that require it, or through a concatenated require, and no other.
---A touched file that is not a Lua module or a suite, a touched test helper, or a touched module
---that no Lua suite reaches or that a command file loads leaves the map unsure.
---@param sources table<string, string> the text of each Lua file and suite by path from the root
---@param touched string[] the paths the change touches
---@return string[]? suites the sorted suite paths, nil when the whole suite should run
function M.pick(sources, touched)
    if #touched == 0 then
        return nil
    end
    local names = {}
    for path in pairs(sources) do
        names[path] = module_name(path)
    end
    local users, prefix_users = loaders(sources, names)
    local selected, changed = {}, {}
    for _, path in ipairs(touched) do
        if is_suite(path) then
            if sources[path] then
                selected[path] = true
            end
        elseif names[path] and path:sub(1, #TESTS_PREFIX) ~= TESTS_PREFIX then
            changed[#changed + 1] = path
        else
            return nil
        end
    end
    for _, path in ipairs(changed) do
        local closure = closure_of(names[path], users, prefix_users)
        for member in pairs(closure) do
            if sources[member] and is_verb(member) then
                return nil
            end
        end
        local reached = false
        for suite, text in pairs(sources) do
            if is_suite(suite) and suite:match("%.lua$") then
                for dep in requires(text) do
                    if closure[dep] then
                        selected[suite] = true
                        reached = true
                    end
                end
            end
        end
        if not reached then
            return nil
        end
    end
    local out = {}
    for path in pairs(selected) do
        out[#out + 1] = path
    end
    if #out == 0 then
        return nil
    end
    table.sort(out)
    return out
end

---Read the text of every Lua file and suite under a project.
---@param root string the project root
---@return table<string, string>? sources the text by path, nil when the files could not be listed
function M.sources(root)
    local out, code = dev_os.capture({
        "find",
        root,
        "(",
        "-name",
        ".jj",
        "-o",
        "-name",
        ".git",
        ")",
        "-prune",
        "-o",
        "-type",
        "f",
        "(",
        "-name",
        "*.lua",
        "-o",
        "-name",
        "*.bats",
        "-o",
        "-name",
        "*.sh",
        ")",
        "-print0",
    }, { stderr = "null" })
    if code ~= 0 then
        return nil
    end
    local sources = {}
    local prefix = root:gsub("/+$", "") .. "/"
    for full in out:gmatch("([^%z]+)%z") do
        local path = full:sub(#prefix + 1)
        if path:match("%.lua$") or is_suite(path) then
            local text = fs.read(full)
            if text then
                sources[path] = text
            end
        end
    end
    return sources
end

---Narrow a plain `dev --remote test` row to the suites a change covers.
---@param root string the project root
---@param argv string[] the row's words
---@param touched fun(): string[]? the paths the change touches, called for a plain test row only
---@return string[] argv the row with `-- SUITES` after it, or the row as given when unsure
---@return integer count how many suites the row names, 0 when it is unchanged
function M.narrow(root, argv, touched)
    if #argv ~= #ROW then
        return argv, 0
    end
    for i, word in ipairs(ROW) do
        if argv[i] ~= word then
            return argv, 0
        end
    end
    local paths = touched()
    local sources = paths and M.sources(root)
    local suites = sources and M.pick(sources, paths)
    if not suites then
        return argv, 0
    end
    local out = { table.unpack(argv) }
    out[#out + 1] = "--"
    for _, suite in ipairs(suites) do
        out[#out + 1] = suite
    end
    return out, #suites
end

---Narrow every plain test row of a card's checks, leaving a negated row as it is.
---@param root string the project root
---@param commands string[] the card's checks rows as it holds them
---@param argvs string[][] the rows' words
---@param touched fun(): string[]? the paths the change touches
---@param note fun(row: integer, count: integer) says which row was narrowed
---@return string[][] argvs the rows' words after narrowing
function M.narrow_rows(root, commands, argvs, touched, note)
    local out = {}
    for i, argv in ipairs(argvs) do
        local count = 0
        out[i] = argv
        if not commands[i]:match("^! ") then
            out[i], count = M.narrow(root, argv, touched)
        end
        if count > 0 then
            note(i, count)
        end
    end
    return out
end

return M
