local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")
local builtins = require("dev.builtins")
local cmd_board = require("dev.cmd.board")
local help = require("dev.help")
local registry = require("dev.registry")
local ui = require("dev.ui")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
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
            assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
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
    return dev_os.capture(argv, { cwd = root, stderr = "stdout", env = env })
end

testing.test("help prints no escape under NO_COLOR or into a pipe", function()
    local root = project({ ["a.sh"] = "#!/usr/bin/env bash\n# A verb.\n" })
    for _, args in ipairs({ {}, { "help", "-a" }, { "help", "a" }, { "a", "-h" } }) do
        local out = dev(root, args, { NO_COLOR = "1" })
        testing.ok(not out:find("\27", 1, true), out)
        out = dev(root, args, { NO_COLOR = "" })
        testing.ok(not out:find("\27", 1, true), out)
    end
end)

testing.test("dev help | head -1 ends without a traceback", function()
    local root = project({ ["a.sh"] = "#!/usr/bin/env bash\n# A verb.\n" })
    local out, code = dev_os.capture(
        { "sh", "-c", 'luajit "$1" help | head -1', "sh", MAIN },
        { cwd = root, stderr = "stdout", env = { DEV_SELF = SELF } }
    )
    testing.eq(code, 0)
    testing.ok(out:find("^dev: [^\n]*project at "), out)
    testing.ok(not out:find("traceback", 1, true), out)
end)

testing.test(
    "the curated view lists a project verb and its topics, and -a adds the helpers",
    function()
        local root = project({
            ["a.sh"] = "#!/usr/bin/env bash\n# A verb.\n",
            ["q.sh"] = "#!/usr/bin/env bash\n# Quiet.\n# hidden\n",
            ["topics/t.md"] = "# t: A topic: with a colon\n\nbody\n",
        })
        local out = dev(root, { "help" })
        testing.ok(out:find("\n  a +A verb%.\n"), out)
        testing.ok(not out:find("  q ", 1, true), out)
        testing.ok(out:find("\nTopics\n", 1, true), out)
        testing.ok(out:find("\n  t +A topic: with a colon\n"), out)
        out = dev(root, { "help", "-a" })
        testing.ok(out:find("\nHidden\n", 1, true), out)
        testing.ok(out:find("  __topics check ", 1, true), out)
        testing.ok(out:find("\n  q +Quiet%.\n"), out)
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
    testing.eq(out, "dev help: -a takes no arguments, got x\n")
    testing.eq(code, 2)
    out, code = dev(root, { "help", "nosuch" })
    testing.eq(out, "dev help: unknown command nosuch, and no topic of that name\n")
    testing.eq(code, 2)
    out, code = dev(root, { "help", "-k" })
    testing.eq(out, "dev help: -k needs one topic name\n")
    testing.eq(code, 2)
    out, code = dev(root, { "help", "lint", "x" })
    testing.eq(out, "dev help: lint has no subcommands\n")
    testing.eq(code, 2)
end)

testing.test("a topic that shares a verb's name is reported by the topic check", function()
    local root = project({
        ["a.sh"] = "#!/usr/bin/env bash\n# A verb.\n",
        ["topics/a.md"] = "# a: A topic named like a verb\n",
    })
    local out, code = dev(root, { "__topics", "check" })
    testing.eq(code, 1)
    testing.ok(out:find("topic a is also a command", 1, true), out)
end)

testing.test("--no-pager is accepted by help and changes nothing off a terminal", function()
    local root = project({ ["topics/t.md"] = "# t: A topic\n\nbody\n" })
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
    "the curated view on a terminal has bold verbs, dim headings and one cut line per verb",
    function()
        local root = project({
            ["a.sh"] = "#!/usr/bin/env bash\n# A verb with a description that is far too long for a narrow screen.\n",
            ["topics/t.md"] = "# t: A topic with a summary that is also far too long for a narrow screen\n",
        })
        local out = styled(root, 40)
        testing.ok(out:find("\27[2mTopics\27[0m\n", 1, true), out)
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
        testing.eq(plan.page.pager, "less -R -+F")
        testing.eq(plan.hint, true)
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
    testing.ok(help.uses_less(nil))
    testing.ok(help.uses_less(""))
    testing.ok(help.uses_less("less -R"))
    testing.ok(help.uses_less("/usr/bin/less"))
    testing.ok(help.uses_less("  /opt/homebrew/bin/less -FRX"))
    testing.ok(not help.uses_less("more"))
    testing.ok(not help.uses_less("bat --paging=always"))
    testing.ok(not help.uses_less("/usr/bin/lessfilter"))
end)

local function noun_fixture()
    return project({
        ["n/DESCRIPTION"] = "The n noun\n",
        ["n/a.sh"] = "#!/usr/bin/env bash\n# Run a with a description that is far too long for one line of a narrow screen.\n",
        ["n/bb.sh"] = "#!/usr/bin/env bash\n# Short.\n",
    })
end

testing.test("noun help wraps a long subcommand description under its column", function()
    local text = require("dev.text")
    local reg = require("dev.registry").load(noun_fixture())
    local c = ui.context({ color = true, interactive = false, width = 40 })
    local plain = help.noun_text(reg, c, { "n" }):gsub("\27%[[%d;]*m", "")
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

testing.test("noun help keeps a short subcommand description on one line", function()
    local reg = require("dev.registry").load(noun_fixture())
    local c = ui.context({ color = true, interactive = false, width = 40 })
    local plain = help.noun_text(reg, c, { "n" }):gsub("\27%[[%d;]*m", "")
    testing.ok(plain:find("\n  bb  Short.\n", 1, true), plain)
    local bare = ui.context({ color = false, interactive = false, width = 40 })
    local out = help.noun_text(reg, bare, { "n" })
    testing.ok(
        out:find(
            "\n  a   Run a with a description that is far too long for one line of a narrow screen.\n",
            1,
            true
        ),
        out
    )
end)

local BOARD_SOURCE = REPO .. "/dotfiles/bin/.local/share/dev/lua/dev/cmd/board.lua"

local function board_rows()
    local rows = {}
    for _, row in ipairs(builtins) do
        if row.words[1] == "board" and #row.words == 2 then
            rows[#rows + 1] = row
        end
    end
    return rows
end

testing.test("dev help board names every board verb of the builtins table", function()
    local reg = registry.load(project({}))
    local c = ui.context({ color = false, interactive = false, width = 100 })
    local out = help.noun_text(reg, c, { "board" })
    local rows = board_rows()
    testing.ok(#rows > 0, "no board rows")
    for _, row in ipairs(rows) do
        if not row.hidden then
            testing.ok(out:find("\n  " .. row.words[2] .. " ", 1, true), row.words[2])
        end
    end
end)

testing.test("every board verb the commands table or handlers run has a builtins row", function()
    local rowed = {}
    for _, row in ipairs(board_rows()) do
        rowed[row.words[2]] = true
    end
    local verbs = {}
    for name in assert(fs.read(BOARD_SOURCE)):gmatch("\nfunction commands%.(%a+)%(") do
        verbs[#verbs + 1] = name
    end
    for key in pairs(cmd_board.handlers) do
        verbs[#verbs + 1] = key:match("^board (%a+)")
    end
    table.sort(verbs)
    testing.ok(#verbs > 30, "found only " .. #verbs .. " board verbs")
    for _, name in ipairs(verbs) do
        testing.ok(rowed[name], "board " .. name .. " has no builtins row")
    end
end)

testing.test("every global flag description starts at one column", function()
    local root = project({ ["a.sh"] = "#!/usr/bin/env bash\n# A verb.\n" })
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
