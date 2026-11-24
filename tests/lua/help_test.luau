local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")
local help = require("dev.help")
local registry = require("dev.registry")
local runtime = require("dev.runtime")
local ui = require("dev.ui")

local function project(files)
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev/help", { parents = true }))
    for name, source in pairs(files) do
        local path = root .. "/.dev/" .. (name:find("^help/") and "" or "commands/") .. name
        assert(fs.mkdir(fs.dirname(path), { parents = true }))
        assert(fs.write(path, source))
        if name:find("%.sh$") then
            assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
        end
    end
    return root
end

local function dev(root, args, env)
    local argv = { runtime.exe }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    env = env or {}
    return dev_os.capture(argv, { cwd = root, stderr = "stdout", env = env })
end

testing.test("help prints no escape under NO_COLOR or into a pipe", function()
    local root = project({ ["a.sh"] = "#!/usr/bin/env bash\n# A command.\n" })
    for _, args in ipairs({ {}, { "help", "-a" }, { "help", "a" }, { "a", "-h" } }) do
        local out = dev(root, args, { NO_COLOR = "1" })
        testing.ok(not out:find("\27", 1, true), out)
        out = dev(root, args, { NO_COLOR = "" })
        testing.ok(not out:find("\27", 1, true), out)
    end
end)

testing.test("dev help | head -1 ends without a traceback", function()
    local root = project({ ["a.sh"] = "#!/usr/bin/env bash\n# A command.\n" })
    local out, code = dev_os.capture(
        { "sh", "-c", '"$1" help | head -1', "sh", runtime.exe },
        { cwd = root, stderr = "stdout" }
    )
    testing.eq(code, 0)
    testing.ok(out:find("^dev: [^\n]*project at "), out)
    testing.ok(not out:find("traceback", 1, true), out)
end)

testing.test(
    "the curated view lists a project command and its topics, and -a adds the helpers",
    function()
        local root = project({
            ["a.sh"] = "#!/usr/bin/env bash\n# A command.\n",
            ["q.sh"] = "#!/usr/bin/env bash\n# Quiet.\n# hidden\n",
            ["help/t.md"] = "# t: A topic: with a colon\n\nbody\n",
        })
        local out = dev(root, { "help" })
        testing.ok(out:find("\n  a +A command%.\n"), out)
        testing.ok(not out:find("  q ", 1, true), out)
        testing.ok(out:find("\nHelp pages\n", 1, true), out)
        testing.ok(out:find("\n  t +A topic: with a colon\n"), out)
        out = dev(root, { "help", "-a" })
        testing.ok(out:find("\nHidden\n", 1, true), out)
        testing.ok(out:find("\n  help +builtin +"), out)
        testing.ok(out:find("\n  q +project +Quiet%.\n"), out)
        testing.eq(dev(root, { "help", "-k", "t" }), "# t: A topic: with a colon\n\nbody\n")
        testing.eq(
            dev(root, { "help", "--topics" }):find("\nt\tA topic: with a colon\n", 1, true) ~= nil,
            true
        )
    end
)

testing.test("a usage error of dev help names the command and exits 2", function()
    local root = project({})
    local out, code = dev(root, { "help", "-a", "x" })
    testing.eq(out, "dev help: The -a flag takes no arguments, but got x.\n")
    testing.eq(code, 2)
    out, code = dev(root, { "help", "nosuch" })
    testing.eq(out, "dev help: Unknown command nosuch, and no help page has that name.\n")
    testing.eq(code, 2)
    out, code = dev(root, { "help", "-k" })
    testing.eq(
        out,
        "dev help: The flag `-k` needs a value.\n"
            .. "usage: dev help [--all] [--topics] [--topic NAME] [--no-pager] "
            .. "[--check-topics] [target...]\n"
    )
    testing.eq(code, 2)
    out, code = dev(root, { "help", "lint", "x" })
    testing.eq(out, "dev help: The command lint has no subcommands.\n")
    testing.eq(code, 2)
end)

testing.test("dev help takes a source prefix and names a bad one", function()
    local root = project({})
    local out, code = dev(root, { "help", "builtin:board" })
    testing.eq(code, 0)
    testing.ok(out:find("dev builtin:board", 1, true), out)
    out, code = dev(root, { "help", "builtin:board", "ls" })
    testing.eq(code, 0)
    testing.ok(out:find("List the cards of the board", 1, true), out)
    out, code = dev(root, { "help", "project:x" })
    testing.eq(out, "dev help: The source project is not builtin or global.\n")
    testing.eq(code, 2)
    out, code = dev(root, { "help", "project:x", "y" })
    testing.eq(out, "dev help: The source project is not builtin or global.\n")
    testing.eq(code, 2)
    out, code = dev(root, { "help", "builtin:nosuch" })
    testing.eq(out, "dev help: The built-in commands have no command nosuch.\n")
    testing.eq(code, 2)
end)

testing.test("a source prefix is refused with --remote", function()
    local env = { CI = "", DEV_BOX_MARKER = "/nonexistent/box-marker" }
    local out, code = dev(project({}), { "--remote", "builtin:lint" }, env)
    testing.eq(out, "The flag `--remote` does not take a command with a source prefix.\n")
    testing.eq(code, 2)
end)

testing.test("a topic that shares a command's name is reported by the topic check", function()
    local root = project({
        ["a.sh"] = "#!/usr/bin/env bash\n# A command.\n",
        ["help/a.md"] = "# a: A topic named like a command\n",
    })
    local out, code = dev(root, { "help", "--check-topics" })
    testing.eq(code, 1)
    testing.ok(out:find("help page a is also a command", 1, true), out)
end)

testing.test("see_also ends the help with one pointer per listed page", function()
    local root = project({
        ["one.sh"] = "#!/usr/bin/env bash\n# One.\n# see_also: boards\n",
        ["two.sh"] = "#!/usr/bin/env bash\n# Two.\n# see_also: boards flags\n",
        ["three.luau"] = 'return require("dev.command")({ summary = "Three.", '
            .. 'see_also = { "boards", "flags", "remote" }, run = function() return 0 end })\n',
    })
    local out = dev(root, { "help", "one" })
    testing.ok(out:find("\nSee `dev help boards`.\n", 1, true), out)
    out = dev(root, { "help", "two" })
    testing.ok(out:find("\nSee `dev help boards` and `dev help flags`.\n", 1, true), out)
    out = dev(root, { "three", "--help" })
    testing.ok(
        out:find("See `dev help boards`, `dev help flags` and `dev help remote`.", 1, true),
        out
    )
end)

testing.test("--no-pager is accepted by help and changes nothing off a terminal", function()
    local root = project({ ["help/t.md"] = "# t: A topic\n\nbody\n" })
    testing.eq(dev(root, { "help", "--no-pager", "-k", "t" }), "# t: A topic\n\nbody\n")
    testing.eq(dev(root, { "help", "t", "--no-pager" }), "# t: A topic\n\nbody\n")
    testing.eq(dev(root, { "help", "-k", "t" }, { DEV_PAGER = "0" }), "# t: A topic\n\nbody\n")
end)

local function styled(root, width)
    local reg = require("dev.registry").load(root)
    local c = ui.context({ color = true, interactive = false, width = width })
    return help.overview_text({ root = root, args = {}, name = "help" }, reg, c)
end

testing.test(
    "the curated view on a terminal has bold commands, dim headings and one cut line per command",
    function()
        local root = project({
            ["a.sh"] = "#!/usr/bin/env bash\n# A command with a description that is far too long for a narrow screen.\n",
            ["help/t.md"] = "# t: A topic with a summary that is also far too long for a narrow screen\n",
        })
        local out = styled(root, 40)
        testing.ok(out:find("\27[2mHelp pages\27[0m\n", 1, true), out)
        testing.ok(out:find("  \27[1ma", 1, true), out)
        testing.ok(out:find("  \27[1mt", 1, true), out)
        local text = require("dev.text")
        for line in out:gmatch("[^\n]+") do
            testing.ok(text.width((line:gsub("\27%[[%d;]*m", ""))) <= 40, line)
        end
        testing.ok(out:find("\27[36mdev help -a\27[0m", 1, true), out)
        testing.ok(not styled(root, 200):find("`", 1, true))
        testing.ok(out:find("…\n", 1, true), out)
        testing.ok(not styled(root, 200):find("…", 1, true))
    end
)

testing.test("the filter hint is dim and follows the text", function()
    local out = help.hinted("body\n", ui.context({ color = true, interactive = false }))
    testing.eq(out, "body\n\n\27[2m& filters · / searches · q quits\27[0m\n")
    out = help.hinted("body\n", ui.context({ color = false, interactive = false }))
    testing.eq(out, "body\n\n& filters · / searches · q quits\n")
end)

testing.test(
    "the curated view pages at any height and less gets -+F, topics keep the height rule",
    function()
        local plan = help.page_plan({ curated = true }, nil, nil)
        testing.eq(plan.page.rows, 0)
        testing.eq(plan.page.allowed, true)
        testing.eq(plan.page.pager, nil)
        testing.eq(plan.hint, false)
        testing.eq(help.page_plan({ curated = true }, "less -FRX", nil).page.pager, "less -FRX -+F")
        testing.eq(
            help.page_plan({ curated = true }, "/usr/bin/less", nil).page.pager,
            "/usr/bin/less -+F"
        )
        plan = help.page_plan({ curated = true }, "bat", nil)
        testing.eq(plan.page.rows, 0)
        testing.eq(plan.page.pager, nil)
        testing.eq(plan.hint, false)
        plan = help.page_plan(nil, nil, nil)
        testing.eq(plan.page.rows, nil)
        testing.eq(plan.page.pager, nil)
        testing.eq(plan.hint, false)
        testing.eq(
            help.page_plan({ curated = true, no_pager = true }, nil, nil).page.allowed,
            false
        )
        testing.eq(help.page_plan({ curated = true }, nil, "0").page.allowed, false)
        testing.eq(help.page_plan({}, nil, "0").page.allowed, false)
    end
)

testing.test("the hint is for less only", function()
    testing.ok(not help.uses_less(nil))
    testing.ok(not help.uses_less(""))
    testing.ok(help.uses_less("less -R"))
    testing.ok(help.uses_less("/usr/bin/less"))
    testing.ok(help.uses_less("  /opt/homebrew/bin/less -FRX"))
    testing.ok(not help.uses_less("more"))
    testing.ok(not help.uses_less("bat --paging=always"))
    testing.ok(not help.uses_less("/usr/bin/lessfilter"))
end)

local function parent_fixture()
    return project({
        ["n/DESCRIPTION"] = "The n parent command\n",
        ["n/a.sh"] = "#!/usr/bin/env bash\n# Run a with a description that is far too long for one line of a narrow screen.\n",
        ["n/bb.sh"] = "#!/usr/bin/env bash\n# Short.\n",
    })
end

testing.test("parent command help wraps a long subcommand description under its column", function()
    local text = require("dev.text")
    local reg = require("dev.registry").load(parent_fixture())
    local c = ui.context({ color = true, interactive = false, width = 40 })
    local plain = help.parent_text(reg, c, { "n" }):gsub("\27%[[%d;]*m", "")
    testing.ok(
        plain:find(
            "\n  a   Run a with a description that is\n      far too long for one line of a\n      narrow screen.\n",
            1,
            true
        ),
        plain
    )
    for line in plain:gmatch("\n(  [^\n]+)") do
        testing.ok(text.width(line) <= 40, line)
    end
end)

testing.test("parent command help keeps a short subcommand description on one line", function()
    local reg = require("dev.registry").load(parent_fixture())
    local c = ui.context({ color = true, interactive = false, width = 40 })
    local plain = help.parent_text(reg, c, { "n" }):gsub("\27%[[%d;]*m", "")
    testing.ok(plain:find("\n  bb  Short.\n", 1, true), plain)
    local bare = ui.context({ color = false, interactive = false, width = 40 })
    local out = help.parent_text(reg, bare, { "n" })
    testing.ok(
        out:find(
            "\n  a   Run a with a description that is far too long for one line of a narrow screen.\n",
            1,
            true
        ),
        out
    )
end)

testing.test("every global flag description starts at one column", function()
    local root = project({ ["a.sh"] = "#!/usr/bin/env bash\n# A command.\n" })
    local out = dev(root, { "a", "--help" })
    local column, seen, inside = nil, 0, false
    for line in out:gmatch("([^\n]*)\n") do
        if line == "Global flags:" then
            inside = true
        elseif inside and line:sub(1, 2) == "  " then
            local _, stop = line:find("  +", 3)
            testing.ok(stop ~= nil, line)
            column = column or stop + 1
            testing.ok(stop + 1 == column, line)
            seen = seen + 1
        elseif inside then
            break
        end
    end
    testing.ok(seen > 0, out)
end)

local function global_config(files)
    local home = support.tempdir()
    for name, source in pairs(files) do
        local path = home .. "/dev/commands/" .. name
        assert(fs.mkdir(fs.dirname(path), { parents = true }))
        assert(fs.write(path, source))
        assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
    end
    return home
end

local function sourced_fixture()
    local root = project({
        ["a.sh"] = "#!/usr/bin/env bash\n# A command.\n",
        ["lint.sh"] = "#!/usr/bin/env bash\n# My lint.\n",
        ["shared.sh"] = "#!/usr/bin/env bash\n# Project shared.\n",
    })
    local home = global_config({
        ["hello.sh"] = "#!/usr/bin/env bash\n# Say hello.\n",
        ["fmt.sh"] = "#!/usr/bin/env bash\n# Global fmt.\n",
        ["shared.sh"] = "#!/usr/bin/env bash\n# Global shared.\n",
    })
    return root, { XDG_CONFIG_HOME = home }
end

testing.test("help -a names the source of each command", function()
    local root, env = sourced_fixture()
    local out = dev(root, { "help", "-a" }, env)
    testing.ok(out:find("\n  a +project +A command%.\n"), out)
    testing.ok(out:find("\n  hello +global +Say hello%.\n"), out)
    testing.ok(out:find("\n  test +builtin +"), out)
    testing.ok(out:find("\n  help +builtin +"), out)
    testing.ok(not out:find("(override)", 1, true), out)
    testing.ok(dev(root, { "help" }, env):find("\n  lint +%(override%) +My lint%.\n"))
end)

testing.test("help -a names the source an override replaces", function()
    local root, env = sourced_fixture()
    local out = dev(root, { "help", "-a" }, env)
    testing.ok(out:find("\n  lint +project over builtin +My lint%.\n"), out)
    testing.ok(out:find("\n  fmt +global over builtin +Global fmt%.\n"), out)
    testing.ok(out:find("\n  shared +project over global +Project shared%.\n"), out)
end)

testing.test("help of one command names its source and the one it replaces", function()
    local root, env = sourced_fixture()
    testing.ok(dev(root, { "help", "lint" }, env):find("^dev lint %(project over builtin%)\n"))
    testing.ok(dev(root, { "lint", "-h" }, env):find("^dev lint %(project over builtin%)\n"))
    testing.ok(dev(root, { "help", "fmt" }, env):find("^dev fmt %(global over builtin%)\n"))
    testing.ok(dev(root, { "help", "shared" }, env):find("^dev shared %(project over global%)\n"))
    testing.ok(dev(root, { "help", "hello" }, env):find("^dev hello\n"))
end)

local WAIT_SPEC = [[return require("dev.command")({
    summary = "Wait for a card",
    group = "Check your work",
    flags = {
        { name = "wait", short = "w", kind = "number", default = 30, help = "Seconds to wait" },
        { name = "mode", kind = "string", choices = { "fast", "slow" }, repeatable = true, help = "How" },
    },
    args = { { name = "card", required = true, help = "The card" }, { name = "rest", list = true } },
    run = function() return 0 end,
})
]]

testing.test(
    "-h lists flag names and --help draws every flag and argument from the spec",
    function()
        local root = project({ ["w.luau"] = WAIT_SPEC })
        local short = dev(root, { "w", "-h" })
        testing.ok(short:find("^dev w\n  Wait for a card\n"), short)
        testing.ok(short:find("dev w [flags] <card> [rest...]", 1, true), short)
        testing.ok(short:find("\n  -w, --wait <number>\n", 1, true), short)
        testing.ok(not short:find("Seconds to wait", 1, true), short)
        local long = dev(root, { "w", "--help" })
        testing.ok(long:find("Seconds to wait (default 30)", 1, true), long)
        testing.ok(long:find("(repeatable; one of fast, slow)", 1, true), long)
        testing.ok(long:find("\n  <card>  +The card %(required%)\n"), long)
        testing.ok(long:find("[rest...]  ", 1, true) and long:find("(list)", 1, true), long)
    end
)

testing.test("a hidden spec is listed by -a only, and the layer shows", function()
    local root = project({
        ["w.luau"] = WAIT_SPEC:gsub("group = ", "hidden = true, group = "),
    })
    testing.ok(not dev(root, { "help" }):find("\n  w ", 1, true))
    testing.ok(dev(root, { "help", "-a" }):find("\n  w +project +Wait for a card\n"))
end)

testing.test("a hidden subcommand is listed by -a under its parent only", function()
    local root = project({
        ["n/x.sh"] = "#!/usr/bin/env bash\n# Shown.\n",
        ["n/y.sh"] = "#!/usr/bin/env bash\n# Secret.\n# hidden\n",
    })
    testing.ok(not dev(root, { "help" }):find("n y", 1, true))
    testing.ok(not dev(root, { "help", "n" }):find("\n  y ", 1, true))
    testing.ok(dev(root, { "help", "-a" }):find("\n  n y +.-Secret%.\n"))
    fs.remove(root, { recursive = true })
end)

testing.test("-a lists a hidden command two levels down", function()
    local root = project({
        ["n/m/x.sh"] = "#!/usr/bin/env bash\n# Shown.\n",
        ["n/m/h.sh"] = "#!/usr/bin/env bash\n# Secret.\n# hidden\n",
    })
    testing.ok(not dev(root, { "help" }):find("n m h", 1, true))
    testing.ok(dev(root, { "help", "-a" }):find("\n  n m h +.-Secret%.\n"))
    fs.remove(root, { recursive = true })
end)
