---@class testing.Case
---@field name string sentence naming the behavior under test
---@field fn fun() test body, which raises to fail

---@class testing
local M = {}

---@type testing.Case[]
local registered = {}

local function render(value, seen)
    if type(value) == "string" then
        return string.format("%q", value)
    end
    if type(value) ~= "table" then
        return tostring(value)
    end
    seen = seen or {}
    if seen[value] then
        return "<cycle>"
    end
    seen[value] = true
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = string.format("[%s] = %s", render(key, seen), render(value[key], seen))
    end
    seen[value] = nil
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    for key, value in pairs(a) do
        if not same(value, b[key]) then
            return false
        end
    end
    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end
    return true
end

---Register a test case.
---@param name string sentence naming the behavior under test
---@param fn fun() test body, which raises to fail
function M.test(name, fn)
    registered[#registered + 1] = { name = name, fn = fn }
end

---Fail unless `got` deeply equals `want`.
---@param got any value under test
---@param want any expected value
function M.eq(got, want)
    if not same(got, want) then
        error(string.format("got %s, want %s", render(got), render(want)), 2)
    end
end

---Fail unless `value` is truthy.
---@param value any value expected to be truthy
---@param message string? failure message
function M.ok(value, message)
    if not value then
        error(message or "expected a truthy value", 2)
    end
end

---Fail unless `fn` raises an error that matches `pattern`.
---@param fn fun() function expected to raise
---@param pattern string? pattern in Lua syntax the error message must match
function M.raises(fn, pattern)
    local ok, err = pcall(fn)
    if ok then
        error("expected an error, got none", 2)
    end
    if pattern and not tostring(err):find(pattern) then
        error(string.format("error %s does not match %q", render(tostring(err)), pattern), 2)
    end
end

---List the registered test cases in registration order.
---@return testing.Case[] cases every case registered so far
function M.tests()
    return registered
end

return M
