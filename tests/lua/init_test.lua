local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local header = require("dev.header")
local pipelines = require("dev.pipelines")
local support = require("support")
local templates = require("dotfiles.templates")
local Kind = require("dev.project").Kind

local function project()
    local root = support.sandbox({ ["a.lua"] = "print(1)\n" }, {})
    assert(fs.write(root .. "/bin/pass", "#!/bin/sh\nexit 1\n"))
    assert(dev_os.run({ "chmod", "755", root .. "/bin/pass" }) == 0, "chmod failed")
    return root
end

local GERRIT_CONFIG = '[gerrit]\nhost = "me@gerrit.example"\nport = 29418\n'
local BOARD_CONFIG =
    '[board.pomb]\nurl = "https://pomb.example"\ntoken = "pass:secrets/worker/token/pomb.example"\n'

local function user_env(text)
    local home = support.tempdir()
    local config = home .. "/.config"
    assert(fs.mkdir(config .. "/dev", { parents = true }), "mkdir failed")
    assert(fs.write(config .. "/dev/config.toml", text), "write failed")
    for _, name in ipairs({ "commands", "lua" }) do
        local target = assert(fs.realpath("dotfiles/dev/.config/dev/" .. name))
        assert(fs.symlink(target, config .. "/dev/" .. name), "symlink failed")
    end
    return { env = { HOME = home, XDG_CONFIG_HOME = config } }
end

local function names(dir)
    local out = fs.list(dir) or {}
    table.sort(out)
    return out
end

local function created_in(out)
    local items = {}
    for item in out:gmatch("\ncreated: ([^\n]+)") do
        items[#items + 1] = item
    end
    return items
end

testing.test("the global init plans the lint files the style guide and the README", function()
    local root = project()
    local before = names(root)
    local out, code = support.dev(root, { "init", "--type", "lua", "--dry-run" }, user_env(""))
    testing.eq(code, 0)
    testing.ok(out:find("would create: .ci/jobs.lua", 1, true), out)
    testing.ok(out:find("would create: .dev/lint.lua", 1, true), out)
    testing.ok(out:find("would create: .dev/lua/lintset.lua", 1, true), out)
    testing.ok(out:find("would create: docs/STYLE.md", 1, true), out)
    testing.ok(out:find("would create: .dev/README.md", 1, true), out)
    testing.ok(out:find("(dry run, nothing written)", 1, true), out)
    testing.ok(not out:find("\ncreated:"), out)
    testing.eq(names(root), before)
    fs.remove(root, { recursive = true })
end)

testing.test("the built-in init writes no lint file and takes no type", function()
    local root = project()
    local out, code = support.dev(root, { "builtin:init", "--dry-run" })
    testing.eq(code, 0, out)
    testing.ok(not out:find(".dev/lint.lua", 1, true), out)
    testing.ok(not out:find("docs/STYLE.md", 1, true), out)
    testing.ok(not out:find(".ci/jobs.lua", 1, true), out)
    testing.ok(not out:find(".editorconfig", 1, true), out)
    out, code = support.dev(root, { "builtin:init", "--type", "lua", "--dry-run" })
    testing.eq(code, 2, out)
    testing.ok(out:find("Unknown flag --type.", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("a second init skips every file the first one created", function()
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = project()
    local user = user_env("")
    local first, first_code = support.dev(root, { "init", "--type", "lua" }, user)
    testing.eq(first_code, 0)
    local items = created_in("\n" .. first)
    testing.ok(#items > 0, first)
    testing.ok(fs.is_file(root .. "/.ci/jobs.lua"), first)
    testing.ok(fs.is_file(root .. "/.dev/lint.lua"), first)
    testing.ok(fs.is_file(root .. "/.dev/fmt.lua"), first)
    testing.ok(fs.is_file(root .. "/.dev/lua/lintset.lua"), first)
    for _, name in ipairs(names(root .. "/.dev")) do
        testing.ok(not name:find("%.sh$"), name)
    end
    local second, second_code = support.dev(root, { "init", "--type", "lua" }, user)
    testing.eq(second_code, 0)
    testing.ok(not second:find("\ncreated:"), second)
    for _, item in ipairs(items) do
        local file = item:match("^%S+$")
        if file then
            testing.ok(
                second:find("skipped: " .. file .. " exists", 1, true),
                file .. "\n" .. second
            )
        end
    end
    fs.remove(root, { recursive = true })
end)

testing.test("init names the Gerrit project after the project in a dry run", function()
    local root = project()
    local out = support.dev(
        root,
        { "init", "--type", "lua", "--dry-run", "--name", "zz" },
        user_env(GERRIT_CONFIG)
    )
    local want =
        "would create: gerrit project zz (create-project when absent) and remote gerrit gr:zz"
    testing.ok(out:find(want, 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("init skips the Gerrit step with no gerrit host", function()
    local root = project()
    local out, code =
        support.dev(root, { "init", "--type", "lua", "--dry-run", "--name", "zz" }, user_env(""))
    testing.eq(code, 0, out)
    testing.ok(out:find("skipped: gerrit: no [gerrit] host in the user config", 1, true), out)
    testing.ok(out:find("set host under [gerrit]", 1, true), out)
    testing.ok(not out:find("gerrit project", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("the global init runs the built-in init and then the Gerrit step", function()
    local root = project()
    local out, code = support.dev(
        root,
        { "init", "--type", "lua", "--dry-run", "--name", "zz" },
        user_env(GERRIT_CONFIG)
    )
    testing.eq(code, 0, out)
    local builtin = out:find("init zz: dry run 1", 1, true)
    local summary = out:find("Summary (dry run, nothing written)", 1, true)
    local files = out:find("\nFiles (dry run, nothing written)\nCreated:\n", 1, true)
    local want =
        "would create: gerrit project zz (create-project when absent) and remote gerrit gr:zz"
    local gerrit = out:find(want, 1, true)
    testing.ok(builtin and summary and files and gerrit, out)
    testing.ok(builtin < summary and summary < files and files < gerrit, out)
    testing.ok(
        out:find("\nGerrit (dry run, nothing written)\nCreated:\n  gerrit project zz", 1, true),
        out
    )
    fs.remove(root, { recursive = true })
end)

testing.test("the global init skips the Gerrit step with the no-gerrit flag", function()
    local root = project()
    local out, code = support.dev(
        root,
        { "init", "--type", "lua", "--dry-run", "--no-gerrit" },
        user_env(GERRIT_CONFIG)
    )
    testing.eq(code, 0, out)
    testing.ok(out:find("skipped: gerrit: --no-gerrit", 1, true), out)
    testing.ok(not out:find("gerrit project", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("the built-in init refuses the no-gerrit flag", function()
    local root = project()
    local out, code = support.dev(root, { "builtin:init", "--no-gerrit" })
    testing.eq(code, 2, out)
    testing.ok(out:find("--no-gerrit", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("init prints the no lint templates sentence for a clone with no lint set", function()
    if dev_os.getuid() == 0 then
        return
    end
    local root = project()
    local clone = support.sandbox({}, {})
    local user = user_env("")
    user.env.DOTFILES = clone
    local out, code = support.dev(root, { "init", "--type", "lua", "--dry-run" }, user)
    testing.eq(code, 1, out)
    testing.ok(out:find("There are no lint templates at " .. clone, 1, true), out)
    testing.ok(out:find("Set DOTFILES to the dotfiles repo.", 1, true), out)
    fs.remove(clone, { recursive = true })
    fs.remove(root, { recursive = true })
end)

testing.test("init skips the lint set for a type that has none", function()
    local root = project()
    local out = support.dev(root, { "init", "--type", "godot", "--dry-run" }, user_env(""))
    testing.ok(out:find("skipped: lint set: none yet for godot projects", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("init plans a lint set exactly for the types templates.set_for knows", function()
    for _, kind in ipairs({ Kind.RUST, Kind.LOVE2D, Kind.LUA, Kind.GODOT, Kind.NODE }) do
        local root = project()
        local out = support.dev(root, { "init", "--type", kind, "--dry-run" }, user_env(""))
        local none = out:find("skipped: lint set: none yet for " .. kind, 1, true) ~= nil
        testing.eq(none, templates.set_for(kind) == nil, kind .. "\n" .. out)
        fs.remove(root, { recursive = true })
    end
end)

testing.test("init refuses a type it has no name for", function()
    local root = project()
    local out, code = support.dev(root, { "init", "--type", "cobol" }, user_env(""))
    testing.eq(code, 2)
    testing.eq(out, "dev init: --type takes rust, love2d, lua, godot or node\n")
    out, code = support.dev(root, { "init", "--type" }, user_env(""))
    testing.eq(code, 2)
    testing.eq(out, "dev init: --type needs a value\n")
    out, code = support.dev(root, { "builtin:init", "--name" })
    testing.eq(code, 2)
    testing.eq(out, "dev init: --name needs a value\n")
    fs.remove(root, { recursive = true })
end)

testing.test("init plans no GitHub workflow for any type", function()
    for _, kind in ipairs({ Kind.RUST, Kind.LOVE2D, Kind.LUA, Kind.GODOT, Kind.NODE }) do
        local root = project()
        local out = support.dev(root, { "init", "--type", kind, "--dry-run" }, user_env(""))
        testing.ok(not out:find(".github", 1, true), kind .. "\n" .. out)
        fs.remove(root, { recursive = true })
    end
end)

testing.test("the base pipeline runs on the image that ships dev", function()
    local text = pipelines.jobs(false)
    testing.ok(text:find('target = "linux-x86-dev"', 1, true), text)
    testing.ok(not text:find("linux-x86-base", 1, true), text)
end)

testing.test("the Rust pipeline has a fmt job that keeps the patch", function()
    local text = pipelines.jobs(true)
    local jobs = assert(loadstring(text))().jobs
    testing.ok(jobs.fmt ~= nil, text)
    testing.ok(text:find("fmt.patch", 1, true), text)
    testing.ok(text:find("git diff", 1, true), text)
end)

testing.test("the Rust fmt template names the fmt job and its patch", function()
    local text = assert(fs.read("dotfiles/claude/.claude/skills/style/lint/rust/fmt.lua"))
    testing.eq(header.parse(text, "lua").patch, { job = "fmt", file = "fmt.patch" })
end)

testing.test("the rust pipeline indents with four spaces", function()
    local text = pipelines.jobs(true)
    local number = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        number = number + 1
        testing.ok(
            not line:match("^  %S"),
            "line " .. number .. " is indented by two spaces: " .. line
        )
    end
end)

local function stub(root, name, text)
    assert(fs.write(root .. "/bin/" .. name, text))
    assert(dev_os.run({ "chmod", "755", root .. "/bin/" .. name }) == 0, "chmod failed")
end

testing.test("init creates the Gerrit project and its remote when the server lacks it", function()
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = project()
    local log = root .. "/ssh.log"
    stub(
        root,
        "ssh",
        '#!/bin/sh\necho "$*" >>' .. log .. '\n[ "$5" = ls-projects ] && echo other\nexit 0\n'
    )
    local user = user_env(GERRIT_CONFIG)
    local out, code = support.dev(root, { "init", "--type", "lua", "--name", "zz" }, user)
    testing.eq(code, 0)
    testing.ok(out:find("created: gerrit project zz\n", 1, true), out)
    testing.ok(out:find("created: remote gerrit gr:zz\n", 1, true), out)
    testing.ok((fs.read(log) or ""):find("create-project zz", 1, true), out)
    local again = support.dev(root, { "init", "--type", "lua", "--name", "zz" }, user)
    testing.ok(again:find("skipped: remote gerrit exists", 1, true), again)
    fs.remove(root, { recursive = true })
end)

testing.test("init leaves the Gerrit step to the owner when ls-projects fails", function()
    local root = project()
    stub(root, "ssh", "#!/bin/sh\necho denied\nexit 255\n")
    local user = user_env(GERRIT_CONFIG)
    local out, code =
        support.dev(root, { "init", "--type", "lua", "--dry-run", "--name", "zz" }, user)
    testing.eq(code, 0)
    testing.ok(not (out:match("\nGerrit.*") or ""):find("Left for you:"), out)
    out, code = support.dev(root, { "init", "--type", "lua", "--name", "zz" }, user)
    testing.eq(code, 0)
    testing.ok(out:find("Gerrit ls-projects failed.\ndenied\n", 1, true), out)
    testing.ok(
        out:find("create the Gerrit project and remote: ssh -p 29418 me@gerrit.example", 1, true),
        out
    )
    fs.remove(root, { recursive = true })
end)

testing.test(
    "init hints at a missing Pomb board and keeps the token off the command line",
    function()
        local root = project()
        local log = root .. "/curl.log"
        local user = user_env(BOARD_CONFIG)
        stub(root, "pass", "#!/bin/sh\necho secret-token\n")
        stub(
            root,
            "curl",
            '#!/bin/sh\necho "curl $*" >>'
                .. log
                .. '\ncat >/dev/null\nprintf \'[{"name":"General"}]\\n200\'\n'
        )
        local out = support.dev(
            root,
            { "init", "--type", "lua", "--dry-run", "--no-gerrit", "--name", "zz" },
            user
        )
        testing.ok(out:find("No Pomb board for zz", 1, true), out)
        testing.ok(not out:find("General", 1, true), out)
        local logged = fs.read(log) or ""
        testing.ok(logged:find("-K - ", 1, true), logged)
        testing.ok(not logged:find("secret-token", 1, true), logged)
        stub(root, "curl", "#!/bin/sh\ncat >/dev/null\nprintf 'not json\\n200'\n")
        out = support.dev(
            root,
            { "init", "--type", "lua", "--dry-run", "--no-gerrit", "--name", "zz" },
            user
        )
        testing.ok(not out:find("No Pomb board", 1, true), out)
        stub(root, "curl", "#!/bin/sh\ncat >/dev/null\nprintf '\\n401'\nexit 22\n")
        out = support.dev(
            root,
            { "init", "--type", "lua", "--dry-run", "--no-gerrit", "--name", "zz" },
            user
        )
        testing.ok(out:find("Pomb refused the worker token", 1, true), out)
        testing.ok(not out:find("No Pomb board", 1, true), out)
        stub(root, "curl", "#!/bin/sh\ncat >/dev/null\nprintf '\\n000'\nexit 7\n")
        out = support.dev(
            root,
            { "init", "--type", "lua", "--dry-run", "--no-gerrit", "--name", "zz" },
            user
        )
        testing.ok(not out:find("Pomb refused", 1, true), out)
        testing.ok(not out:find("No Pomb board", 1, true), out)
        fs.remove(root, { recursive = true })
    end
)

testing.test("init treats an empty --type and --name as unset", function()
    local root = project()
    local out, code =
        support.dev(root, { "init", "--type", "", "--name", "", "--dry-run" }, user_env(""))
    testing.eq(code, 0)
    testing.ok(out:find("init " .. fs.basename(root) .. ": type lua", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("init leaves a project on bash verbs without Lua verbs", function()
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = project()
    assert(fs.write(root .. "/.dev/lint.sh", "#!/bin/sh\n"), "fixture setup failed")
    local out, code = support.dev(root, { "init", "--type", "lua" }, user_env(""))
    testing.eq(code, 0)
    testing.ok(out:find("skipped: .dev/lint.sh exists, left on bash", 1, true), out)
    testing.ok(not fs.exists(root .. "/.dev/lint.lua"), out)
    testing.ok(not fs.exists(root .. "/.dev/fmt.lua"), out)
    testing.ok(not fs.exists(root .. "/.dev/lua/lintset.lua"), out)
    fs.remove(root, { recursive = true })
end)

testing.test("init seeds .dev/README.md from the template", function()
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end
    for _, kind in ipairs({ Kind.LUA, Kind.GODOT }) do
        local root = project()
        local out, code = support.dev(root, { "init", "--type", kind }, user_env(""))
        testing.eq(code, 0)
        testing.ok(out:find("created: .dev/README.md", 1, true), out)
        testing.eq(fs.read(root .. "/.dev/README.md"), fs.read(templates.readme_template()))
        fs.remove(root, { recursive = true })
    end
end)

testing.test("a second init keeps an edited .dev/README.md", function()
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = project()
    local user = user_env("")
    local _, first = support.dev(root, { "init", "--type", "lua" }, user)
    testing.eq(first, 0)
    local edited = "# my own readme\n"
    assert(fs.write(root .. "/.dev/README.md", edited))
    local out, code = support.dev(root, { "init", "--type", "lua" }, user)
    testing.eq(code, 0)
    testing.ok(out:find("skipped: .dev/README.md exists", 1, true), out)
    testing.eq(fs.read(root .. "/.dev/README.md"), edited)
    fs.remove(root, { recursive = true })
end)

testing.test("init writes an .editorconfig with indent_size 4", function()
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = project()
    local user = user_env("")
    local out, code = support.dev(root, { "init", "--type", "lua" }, user)
    testing.eq(code, 0)
    testing.ok(out:find("created: .editorconfig", 1, true), out)
    testing.ok(fs.read(root .. "/.editorconfig"):find("indent_size = 4", 1, true))
    local edited = "root = true\n"
    assert(fs.write(root .. "/.editorconfig", edited))
    local again = support.dev(root, { "init", "--type", "lua" }, user)
    testing.ok(again:find("skipped: .editorconfig exists", 1, true), again)
    testing.eq(fs.read(root .. "/.editorconfig"), edited)
    fs.remove(root, { recursive = true })
end)
