local dev_os = require("dev.os")
local header = require("dev.header")
local registry = require("dev.registry")
local spec = require("dev.spec")

local here = arg[0]:match("^(.*)/[^/]*$") or "."
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

local function holds(text, part)
    if not tostring(text):find(part, 1, true) then
        error(string.format("expected %q inside %q", part, tostring(text)), 2)
    end
end

check("validate names an unknown field", function()
    local checked, reason = spec.validate({ summary = "x", colour = 1 })
    same(checked, nil)
    holds(reason, "`colour`")
end)

check("validate codes a flag that takes --help or -h as reserved", function()
    local _, _, by_name = spec.validate({ flags = { { name = "help" } } })
    same(by_name, spec.Reason.RESERVED_FLAG)
    local _, _, by_short = spec.validate({ flags = { { name = "hint", short = "h" } } })
    same(by_short, spec.Reason.RESERVED_FLAG)
    local _, _, other = spec.validate({ summary = "x", colour = 1 })
    same(other, nil)
end)

check("validate accepts globals and pass_unknown", function()
    local checked = spec.validate({
        globals = false,
        pass_unknown = true,
        args = { { name = "rest", list = true } },
    })
    same(type(checked), "table")
end)

check("parse reads flags, args and passthrough", function()
    local def = {
        passthrough = true,
        flags = {
            { name = "dry-run", kind = "boolean" },
            { name = "n", short = "n", kind = "number" },
        },
        args = { { name = "card", required = true } },
    }
    local opts, args, pass = spec.parse(def, { "--dry-run", "-n", "4", "c1", "--", "x", "y" })
    same(opts.dry_run, true)
    same(opts.n, 4)
    same(args.card, "c1")
    same(table.concat(pass, ","), "x,y")
end)

check("parse returns a usage message", function()
    local opts, message = spec.parse({}, { "--nope" })
    same(opts, nil)
    same(message, "Unknown flag --nope.")
end)

check("header reads the spec fields of a shell command", function()
    local checked = header.parse(
        "#!/usr/bin/env bash\n# summary: Hi\n# flag: label short=l repeatable -- A label\n# arg: t required -- T\n# requires: workspace\n# remote: false\n# hidden\n# plain note\necho\n",
        "x.sh"
    )
    same(checked.summary, "Hi")
    same(checked.flags[1].repeatable, true)
    same(checked.flags[1].short, "l")
    same(checked.args[1].required, true)
    same(checked.requires[1], "workspace")
    same(checked.remote, false)
    same(checked.hidden, true)
    same(checked.long, "plain note")
end)

check("header refuses a gone marker with its replacement", function()
    local checked, reason = header.parse("#!/bin/sh\n# flags: --x\n", "x.sh")
    same(checked, nil)
    holds(reason, "# flag: NAME")
    local _, local_reason = header.parse("#!/bin/sh\n# local\n", "x.sh")
    holds(local_reason, "runs_local")
end)

check("header takes the first plain comment as the summary", function()
    same(
        header.parse("#!/bin/sh\n# shellcheck disable=SC1\n# First line\n", "x.sh").summary,
        "First line"
    )
end)

local registry_ready = type(dev_os.setenv) == "function"
    and type(dev_os.getuid) == "function"
    and type(require("dev.fs").list) == "function"
    and type(require("dev.fs").read) == "function"

local function check_registry(name, body)
    if registry_ready then
        check(name, body)
    else
        print("skip " .. name .. " (the os and fs modules are not built yet)")
    end
end

local function project()
    dev_os.setenv("XDG_CONFIG_HOME", here .. "/fixtures/spec_config")
    local seen = {}
    local reg = registry.load(here .. "/fixtures/spec_project", {
        warn = function(message)
            seen[#seen + 1] = message
        end,
    })
    return reg, seen
end

check_registry("the registry finds luau and sh commands in the project layer", function()
    local reg = project()
    local hello = reg:find({ "hello" })
    same(hello.lang, "luau")
    same(hello.desc, "Say hello")
    same(hello.group, "Greeting")
    local shell = reg:find({ "shell" })
    same(shell.lang, "sh")
    same(shell.remote, false)
    same(shell.requires[1], "workspace")
    same(table.concat(reg:flags({ "hello" }), " "), "--times -n")
end)

check_registry("luau beats sh for one name", function()
    local reg = project()
    same(reg:find({ "both" }).lang, "luau")
end)

check_registry("a parent command takes its description and first group from its folder", function()
    local reg = project()
    local nested = reg:find({ "nested" })
    same(nested.parent, true)
    same(nested.desc, "Nested things")
    same(nested.group, "Nested group")
    same(reg:find({ "nested", "inner" }).desc, "Inner command")
end)

check_registry("a broken header marks the row and a .lua file is refused", function()
    local reg, seen = project()
    holds(reg:find({ "old" }).broken, "# flag: NAME")
    reg:find({ "hello" })
    reg:commands()
    local refused = false
    for _, message in ipairs(seen) do
        refused = refused or message:find("Command files end in .luau, not .lua:", 1, true) ~= nil
    end
    same(refused, true)
end)

check_registry("builtin: and global: prefixes answer from one layer", function()
    local reg = project()
    local row, reason = reg:find({ "builtin:hello" })
    same(row, nil)
    same(registry.sentence(reason), "The built-in commands have no command hello.")
end)

if failures > 0 then
    dev_os.exit(1)
end
