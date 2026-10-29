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

local function styled(root, width)
    local help = require("dev.help")
    local ui = require("dev.ui")
    local reg = require("dev.registry").load(root)
    local c = ui.context({ color = true, interactive = false, width = width })
    return help.overview_text({ root = root, args = {}, name = "help" }, reg, c)
end

t.test(
    "the curated view on a terminal has bold verbs, dim headings and one cut line per verb",
    function()
        local root = project({
            ["a.sh"] = "#!/usr/bin/env bash\n# A verb with a description that is far too long for a narrow screen.\n",
            ["topics/t.md"] = "# t: A topic with a summary that is also far too long for a narrow screen\n",
        })
        local out = styled(root, 40)
        t.ok(out:find("\27[2mTopics\27[0m\n", 1, true), out)
        t.ok(out:find("  \27[1ma", 1, true), out)
        t.ok(out:find("  \27[1mt", 1, true), out)
        local text = require("dev.text")
        for line in out:gmatch("[^\n]+") do
            t.ok(line:find("^Run ") or text.width(line) <= 40, line)
        end
        t.ok(out:find("…\n", 1, true), out)
        t.ok(not styled(root, 200):find("…", 1, true))
    end
)

t.test("the filter hint is dim and follows the text", function()
    local help = require("dev.help")
    local ui = require("dev.ui")
    local out = help.hinted("body\n", ui.context({ color = true, interactive = false }))
    t.eq(out, "body\n\n\27[2m& filters · / searches · q quits\27[0m\n")
    out = help.hinted("body\n", ui.context({ color = false, interactive = false }))
    t.eq(out, "body\n\n& filters · / searches · q quits\n")
end)

t.test(
    "the curated view pages at any height and less gets -+F, topics keep the height rule",
    function()
        local help = require("dev.help")
        local plan = help.page_plan({ curated = true }, nil, nil)
        t.eq(plan.page.rows, 0)
        t.eq(plan.page.allowed, true)
        t.eq(plan.page.pager, "less -R -+F")
        t.eq(plan.hint, true)
        t.eq(help.page_plan({ curated = true }, "less -FRX", nil).page.pager, "less -FRX -+F")
        t.eq(
            help.page_plan({ curated = true }, "/usr/bin/less", nil).page.pager,
            "/usr/bin/less -+F"
        )
        plan = help.page_plan({ curated = true }, "bat", nil)
        t.eq(plan.page.rows, 0)
        t.eq(plan.page.pager, nil)
        t.eq(plan.hint, false)
        plan = help.page_plan(nil, nil, nil)
        t.eq(plan.page.rows, nil)
        t.eq(plan.page.pager, nil)
        t.eq(plan.hint, false)
        t.eq(help.page_plan({ curated = true, no_pager = true }, nil, nil).page.allowed, false)
        t.eq(help.page_plan({ curated = true }, nil, "0").page.allowed, false)
        t.eq(help.page_plan({}, nil, "0").page.allowed, false)
    end
)

t.test("the hint is for less only", function()
    local help = require("dev.help")
    t.ok(help.uses_less(nil))
    t.ok(help.uses_less(""))
    t.ok(help.uses_less("less -R"))
    t.ok(help.uses_less("/usr/bin/less"))
    t.ok(help.uses_less("  /opt/homebrew/bin/less -FRX"))
    t.ok(not help.uses_less("more"))
    t.ok(not help.uses_less("bat --paging=always"))
    t.ok(not help.uses_less("/usr/bin/lessfilter"))
end)
