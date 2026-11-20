local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local registry = require("dev.registry")
local support = require("support")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local DEV_DIR = REPO .. "/dotfiles/bin/.local/share/dev"

local function source(path)
    return assert(fs.read(path), path)
end

local function missing(text, needles)
    local out = {}
    for _, needle in ipairs(needles) do
        if not text:find(needle, 1, true) then
            out[#out + 1] = needle
        end
    end
    return out
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

local function wrapped(flags, left, right)
    local out = {}
    for _, flag in ipairs(flags) do
        out[#out + 1] = left .. flag .. right
    end
    return out
end

testing.test("the launcher consumes each value flag and reads each remote flag", function()
    local text = source(REPO .. "/dotfiles/bin/.local/bin/dev")
    local value = {}
    for _, flag in ipairs(registry.GLOBAL_FLAGS) do
        if registry.VALUE_FLAGS[flag] then
            value[#value + 1] = flag
        end
    end
    testing.eq(missing(text, wrapped(value, "\n    ", ")\n")), {})
    testing.eq(
        missing(text, { "--remote | --detach | --priority | --job-timeout) remote_flag=1" }),
        {}
    )
end)

testing.test("--local exports DEV_LOCAL to a verb and no flag leaves it unset", function()
    local root = assert(fs.realpath(support.tempdir()))
    assert(fs.mkdir(root .. "/.dev", { parents = true }))
    local probe = 'print("DEV_LOCAL=" .. tostring(os.getenv("DEV_LOCAL")))\n'
    assert(fs.write(root .. "/.dev/probe.lua", probe))
    assert(dev_os.run({ "chmod", "755", root .. "/.dev/probe.lua" }) == 0, "chmod failed")
    local function run(args)
        local argv = { "luajit", DEV_DIR .. "/main.lua" }
        for _, word in ipairs(args) do
            argv[#argv + 1] = word
        end
        return dev_os.capture(
            argv,
            { cwd = root, env = { CI = "", DEV_REMOTE = "0" }, unset = { "DEV_LOCAL" } }
        )
    end
    testing.eq(run({ "--local", "probe" }), "DEV_LOCAL=1\n")
    testing.eq(run({ "probe" }), "DEV_LOCAL=nil\n")
    fs.remove(root, { recursive = true })
end)

testing.test("the Lua dispatcher parses each bare flag the registry lists", function()
    local text = source(DEV_DIR .. "/lua/dev/cli.lua")
    local bare = without(
        registry.GLOBAL_FLAGS,
        { ["-v"] = true, ["-vv"] = true, ["--verbose"] = true, ["-C"] = true }
    )
    bare = without(bare, { ["--agent"] = true })
    testing.eq(missing(text, wrapped(bare, 'word == "', '"')), {})
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
    local help = source(DEV_DIR .. "/lua/dev/help.lua")
    local flags = without(registry.GLOBAL_FLAGS, { ["--verbose"] = true })
    testing.eq(unmatched(help, flags, '{%s*"', '[ "]'), {})
end)

testing.test("the completion names each global flag", function()
    local completion = source(REPO .. "/dotfiles/zsh/.config/zsh/completions/_dev")
    local flags = without(registry.GLOBAL_FLAGS, { ["-vv"] = true })
    testing.eq(unmatched(completion, flags, "[^%w%-]", "[^%w%-]"), {})
end)

testing.test("flags.md lists each global flag as a bullet", function()
    local docs = source(REPO .. "/docs/dev/flags.md")
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
