local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/dotfiles/bin/.local/share/dev/main.lua"
local SELF = REPO .. "/dotfiles/bin/.local/bin/dev"

local function project(files)
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev/topics", { parents = true }))
    for name, source in pairs(files) do
        local path = root .. "/.dev/" .. name
        assert(fs.mkdir(fs.dirname(path), { parents = true }))
        assert(fs.write(path, source))
        if name:find("%.sh$") then
            assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
        end
    end
    return root
end

local function dev(root, args, env)
    local argv = { "luajit", MAIN }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    env = env or {}
    env.DEV_SELF = SELF
    return devos.capture(argv, { cwd = root, stderr = "stdout", env = env })
end

t.test("help prints no escape under NO_COLOR or into a pipe", function()
    local root = project({ ["a.sh"] = "#!/usr/bin/env bash\n# A verb.\n" })
    for _, args in ipairs({ {}, { "help", "-a" }, { "help", "a" }, { "a", "-h" } }) do
        local out = dev(root, args, { NO_COLOR = "1" })
        t.ok(not out:find("\27", 1, true), out)
        out = dev(root, args, { NO_COLOR = "" })
        t.ok(not out:find("\27", 1, true), out)
    end
end)

t.test("dev help | head -1 ends without a traceback", function()
    local root = project({ ["a.sh"] = "#!/usr/bin/env bash\n# A verb.\n" })
    local out, code = devos.capture(
        { "sh", "-c", 'luajit "$1" help | head -1', "sh", MAIN },
        { cwd = root, stderr = "stdout", env = { DEV_SELF = SELF } }
    )
    t.eq(code, 0)
    t.ok(out:find("^dev: [^\n]*project at "), out)
    t.ok(not out:find("traceback", 1, true), out)
end)

t.test("the curated view lists a project verb and its topics, and -a adds the helpers", function()
    local root = project({
        ["a.sh"] = "#!/usr/bin/env bash\n# A verb.\n",
        ["q.sh"] = "#!/usr/bin/env bash\n# Quiet.\n# hidden\n",
        ["topics/t.md"] = "# t: A topic: with a colon\n\nbody\n",
    })
    local out = dev(root, { "help" })
    t.ok(out:find("\n  a +A verb%.\n"), out)
    t.ok(not out:find("  q ", 1, true), out)
    t.ok(out:find("\nTopics\n", 1, true), out)
    t.ok(out:find("\n  t +A topic: with a colon\n"), out)
    out = dev(root, { "help", "-a" })
    t.ok(out:find("\nHidden\n", 1, true), out)
    t.ok(out:find("  __topics check ", 1, true), out)
    t.ok(out:find("\n  q +Quiet%.\n"), out)
    t.eq(dev(root, { "help", "-k", "t" }), "# t: A topic: with a colon\n\nbody\n")
    t.eq(
        dev(root, { "help", "--topics" }):find("\nt\tA topic: with a colon\n", 1, true) ~= nil,
        true
    )
end)

t.test("a usage error of dev help names the command and exits 2", function()
    local root = project({})
    local out, code = dev(root, { "help", "-a", "x" })
    t.eq(out, "dev help: -a takes no arguments, got x\n")
    t.eq(code, 2)
    out, code = dev(root, { "help", "nosuch" })
    t.eq(out, "dev help: unknown verb nosuch, and no topic of that name\n")
    t.eq(code, 2)
    out, code = dev(root, { "help", "-k" })
    t.eq(out, "dev help: -k needs one topic name\n")
    t.eq(code, 2)
    out, code = dev(root, { "help", "lint", "x" })
    t.eq(out, "dev help: lint has no subcommands\n")
    t.eq(code, 2)
end)

t.test("a topic that shares a verb's name is reported by the topic check", function()
    local root = project({
        ["a.sh"] = "#!/usr/bin/env bash\n# A verb.\n",
        ["topics/a.md"] = "# a: A topic named like a verb\n",
    })
    local out, code = dev(root, { "__topics", "check" })
    t.eq(code, 1)
    t.ok(out:find("topic a is also a verb", 1, true), out)
end)

t.test("--no-pager is accepted by help and changes nothing off a terminal", function()
    local root = project({ ["topics/t.md"] = "# t: A topic\n\nbody\n" })
    t.eq(dev(root, { "help", "--no-pager", "-k", "t" }), "# t: A topic\n\nbody\n")
    t.eq(dev(root, { "help", "t", "--no-pager" }), "# t: A topic\n\nbody\n")
    t.eq(dev(root, { "help", "-k", "t" }, { DEV_PAGER = "0" }), "# t: A topic\n\nbody\n")
end)
