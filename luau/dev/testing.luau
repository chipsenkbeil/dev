---A test case, named by a sentence about the behavior under test, whose body raises to fail
export type Case = {
    ---sentence naming the behavior under test
    name: string,
    ---test body, which raises to fail
    fn: () -> (),
}

---@class testing
local M = {}

local registered: { Case } = {}

local function render(value, seen)
    if type(value) == "string" then
        return string.format("%q", value :: string)
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

local function same(a, b, seen)
    if type(a) ~= "table" or type(b) ~= "table" then
        return a == b
    end
    seen = seen or {}
    seen[a] = seen[a] or {}
    if seen[a][b] then
        return true
    end
    seen[a][b] = true
    for key, value in pairs(a) do
        if not same(value, b[key], seen) then
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
---@param name sentence naming the behavior under test
---@param fn test body, which raises to fail
function M.test(name: string, fn: () -> ())
    registered[#registered + 1] = { name = name, fn = fn }
end

---Fail unless `got` deeply equals `want`.
---@param got value under test
---@param want expected value
---@param message text printed under the mismatch, such as the command's output
function M.eq(got: any, want: any, message: string?)
    if not same(got, want) then
        local text = string.format("got %s, want %s", render(got), render(want))
        if message ~= nil then
            text = text .. "\n" .. tostring(message)
        end
        error(text, 2)
    end
end

---Fail unless `value` is truthy.
---@param value value expected to be truthy
---@param message failure message
function M.ok(value: any, message: string?)
    if not value then
        error(message or "expected a truthy value", 2)
    end
end

---Fail unless `fn` raises an error that matches `pattern`.
---@param fn function expected to raise
---@param pattern pattern in Lua syntax the error message must match
function M.raises(fn: () -> (), pattern: string?)
    local ok, err = pcall(fn)
    if ok then
        error("expected an error, got none", 2)
    end
    if pattern and not tostring(err):find(pattern) then
        error(string.format("error %s does not match %q", render(tostring(err)), pattern), 2)
    end
end

---List the registered test cases in registration order.
---@return every case registered so far
function M.tests(): { Case }
    return registered
end

return M
