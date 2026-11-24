local dev_os = require("@dev/os")
local runtime = require("@dev/runtime")

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

local FILES = {
    "lint",
    "fmt",
    "test",
    "build",
    "run",
    "fetch",
    "push",
    "pull",
    "follow",
    "land",
    "abandon",
    "init",
    "config",
    "__pkg",
    "branch/ls",
    "branch/archive",
    "branch/prune",
    "tools/install",
    "tools/check",
    "ci/logs",
}
local LIBRARIES = {
    "abandon",
    "branch",
    "ci",
    "config",
    "follow",
    "init",
    "land",
    "pull",
    "push",
    "tools",
    "types",
}

for _, name in ipairs(FILES) do
    check("the command file " .. name .. " compiles", function()
        local source = runtime.asset("luau/dev/commands/" .. name .. ".luau")
        assert(source, "the command file is not embedded")
        local chunk, err = runtime.load(source, "=" .. name)
        assert(chunk, err)
    end)
end

for _, name in ipairs(LIBRARIES) do
    check("the library dev.cmd." .. name .. " compiles", function()
        local source = runtime.asset("luau/dev/cmd/" .. name .. ".luau")
        assert(source, "the library is not embedded")
        local chunk, err = runtime.load(source, "=" .. name)
        assert(chunk, err)
    end)
end

for _, name in ipairs({
    "apt",
    "brew",
    "cargo",
    "dnf",
    "lib",
    "luarocks",
    "pacman",
    "release",
    "script",
    "system",
}) do
    check("the driver module dev.pkg." .. name .. " compiles", function()
        local source = runtime.asset("luau/dev/pkg/" .. name .. ".luau")
        assert(source, "the module is not embedded")
        local chunk, err = runtime.load(source, "=" .. name)
        assert(chunk, err)
    end)
end

check("the builtin table is no longer embedded", function()
    assert(runtime.asset("luau/dev/builtins.luau") == nil)
end)

if failures > 0 then
    dev_os.exit(1)
end
