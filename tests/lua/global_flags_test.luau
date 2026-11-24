local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local registry = require("dev.registry")
local support = require("support")

local REPO = arg[0]:match("^(.*)/tests/lua/") or "."

local function source(path)
    return assert(fs.read(path), path)
end

local function without(flags, skip)
    local out = {}
    for _, flag in ipairs(flags) do
        if not skip[flag] then
            out[#out + 1] = flag
        end
    end
    return out
end

local function project(files)
    local root = assert(fs.realpath(support.tempdir()))
    assert(fs.mkdir(root .. "/.dev/commands", { parents = true }))
    for name, text in pairs(files) do
        assert(fs.write(root .. "/.dev/commands/" .. name, text))
    end
    return root
end

local function run(root, args)
    local argv = { support.DEV }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    return dev_os.capture(argv, {
        cwd = root,
        stderr = "stdout",
        env = { CI = "", DEV_REMOTE = "0", XDG_CONFIG_HOME = root .. "/config" },
        unset = { "DEV_LOCAL" },
    })
end

testing.test("--local exports DEV_LOCAL to a command and no flag leaves it unset", function()
    local root = project({
        ["probe.luau"] = 'local dev_command = require("dev.command")\n'
            .. 'local dev_os = require("dev.os")\n'
            .. 'return dev_command({ summary = "Probe", run = function()\n'
            .. '    print("DEV_LOCAL=" .. tostring(dev_os.getenv("DEV_LOCAL")))\n'
            .. "end })\n",
    })
    testing.eq(run(root, { "--local", "probe" }), "DEV_LOCAL=1\n")
    testing.eq(run(root, { "probe" }), "DEV_LOCAL=nil\n")
    fs.remove(root, { recursive = true })
end)

testing.test("the binary takes each global flag the registry lists before the command", function()
    local root = project({})
    local skip = { ["-C"] = true, ["--agent"] = true, ["--job-timeout"] = true }
    for _, flag in ipairs(without(registry.GLOBAL_FLAGS, skip)) do
        local out = run(root, { flag, "help" })
        testing.ok(not out:find("is not a global flag", 1, true), flag .. ": " .. out)
    end
    local out = run(root, { "--agent", "x/y", "help" })
    testing.ok(not out:find("is not a global flag", 1, true), out)
    out = run(root, { "-C", root, "help" })
    testing.ok(not out:find("is not a global flag", 1, true), out)
    out = run(root, { "--job-timeout", "5m", "help" })
    testing.ok(not out:find("is not a global flag", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("a word that is not a global flag before the command is a usage error", function()
    local root = project({})
    local out, code = run(root, { "--nope", "help" })
    testing.eq(code, 2)
    testing.ok(out:find("The flag `--nope` is not a global flag of dev.", 1, true), out)
    fs.remove(root, { recursive = true })
end)

local function escaped(flag)
    return (flag:gsub("%p", "%%%0"))
end

local function unmatched(text, flags, before, after)
    local out = {}
    for _, flag in ipairs(flags) do
        if not text:find(before .. escaped(flag) .. after) then
            out[#out + 1] = flag
        end
    end
    return out
end

testing.test("help names each global flag as a table row", function()
    local help = source(REPO .. "/luau/dev/help.luau")
    local flags = without(registry.GLOBAL_FLAGS, { ["--verbose"] = true })
    testing.eq(unmatched(help, flags, '{%s*"', '[ "]'), {})
end)

testing.test("flags.md lists each global flag as a bullet", function()
    local docs = source(REPO .. "/docs/flags.md")
    local listed = {}
    for head in docs:gmatch("\n%- ([^\n]-):") do
        for flag in head:gmatch("`(%-[%w%-]+)") do
            listed[flag] = true
        end
    end
    local out = {}
    for _, flag in ipairs(registry.GLOBAL_FLAGS) do
        if not listed[flag] then
            out[#out + 1] = flag
        end
    end
    testing.eq(out, {})
end)
