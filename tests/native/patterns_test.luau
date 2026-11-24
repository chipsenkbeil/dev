local dev_os = require("dev.os")

local failures = 0

local function check(name, body)
    local ok, err = pcall(body)
    if ok then
        print("ok   " .. name)
    else
        failures += 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local function same(actual, expected)
    if actual ~= expected then
        error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
    end
end

check("a negated class with a NUL escape splits a NUL-separated list", function()
    local found = {}
    for path in ("a.luau\0b.luau\0c"):gmatch("([^\0]+)") do
        found[#found + 1] = path
    end
    same(table.concat(found, "|"), "a.luau|b.luau|c")
end)

check("find and gsub match a NUL byte", function()
    same(("x\0y"):find("\0", 1, true), 2)
    same(("x\0y"):find("\0"), 2)
    same((("x\0y"):gsub("\0", "-")), "x-y")
end)

check("a NUL escape in a class does not stop the match at the first NUL", function()
    same(#("ab\0cd"):match("[^\0]+$"), 2)
    same(("ab\0cd"):match("^[^\0]+"), "ab")
end)

if failures > 0 then
    dev_os.exit(1)
end
