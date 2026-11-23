local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local project = require("dev.project")
local registry = require("dev.registry")
local support = require("support")

local function scripted(dir, rel, text, mode)
    local path = fs.join(dir, rel)
    assert(fs.mkdir(fs.dirname(path), { parents = true }))
    assert(fs.write(path, text))
    assert(dev_os.run({ "chmod", mode or "755", path }) == 0, "chmod failed")
    return path
end

local function words(rows)
    local names = {}
    for _, row in ipairs(rows) do
        names[#names + 1] = row.name
    end
    return names
end

local function make_project()
    local root = support.tempdir()
    scripted(root, ".dev/a.sh", "#!/usr/bin/env bash\n# From the shell script.\n")
    scripted(root, ".dev/a.lua", "--[[\nFrom the Lua script.\nflags: --lua\n]]\n", "644")
    scripted(root, ".dev/n/x.sh", "#!/usr/bin/env bash\n# Sub x.\n# group: Mine\n")
    scripted(root, ".dev/n/__y.sh", "#!/usr/bin/env bash\n# Hidden sub.\n")
    scripted(root, ".dev/__h.sh", "#!/usr/bin/env bash\n# Helper.\n")
    scripted(root, ".dev/quiet.sh", "#!/usr/bin/env bash\n# Quiet one.\n# hidden\n")
    scripted(root, ".dev/off.sh", "#!/usr/bin/env bash\n# Not executable.\n", "644")
    return root
end

testing.test(
    ".lua beats .sh and needs no exec bit, while an unexecutable .sh is no command",
    function()
        local root = make_project()
        local reg = registry.load(root)
        local row = reg:find({ "a" })
        testing.eq(row.lang, "lua")
        testing.eq(row.desc, "From the Lua script.")
        testing.eq(row.kind, "local")
        testing.eq(reg:find({ "off" }), nil)
        testing.eq(reg:flags({ "a" }), { "--lua" })
        fs.remove(root, { recursive = true })
    end
)

testing.test(
    "a directory with scripts is a parent command whose subs are listed without __ helpers",
    function()
        local root = make_project()
        local reg = registry.load(root)
        testing.ok(reg:is_parent("n"), "n should be a parent command")
        testing.eq(words(reg:subs("n")), { "n x" })
        testing.eq(reg:find({ "n", "__y" }).desc, "Hidden sub.")
        testing.eq(reg:find({ "n" }).group, "Mine")
        testing.eq(reg:find({ "n" }).desc, "x")
        testing.eq(reg:is_parent("a"), false)
        testing.eq(reg:subs("a"), {})
        fs.remove(root, { recursive = true })
    end
)

testing.test("verbose_count counts the v letters and --verbose, and nothing else", function()
    testing.eq(registry.verbose_count("-v"), 1)
    testing.eq(registry.verbose_count("-vv"), 2)
    testing.eq(registry.verbose_count("-vvv"), 3)
    testing.eq(registry.verbose_count("--verbose"), 1)
    testing.eq(registry.verbose_count("plain"), nil)
end)

testing.test("DESCRIPTION supplies a parent command's description", function()
    local root = make_project()
    assert(fs.write(root .. "/.dev/n/DESCRIPTION", "The n parent command\nsecond line\n"))
    testing.eq(registry.load(root):find({ "n" }).desc, "The n parent command")
    fs.remove(root, { recursive = true })
end)

testing.test("commands lists builtins, then project commands, and keeps __ helpers out", function()
    local root = make_project()
    local names = words(registry.load(root):commands())
    testing.eq(names[1], "lint")
    testing.eq({ unpack(names, #names - 2) }, { "a", "quiet", "n" })
    testing.eq(registry.load(root):find({ "__h" }).desc, "Helper.")
    local seen = {}
    for _, name in ipairs(names) do
        seen[name] = true
    end
    testing.eq(seen.__h, nil)
    testing.eq(seen.off, nil)
    fs.remove(root, { recursive = true })
end)

testing.test("a hidden header and a group header place a local command", function()
    local root = make_project()
    local reg = registry.load(root)
    testing.eq(reg:find({ "quiet" }).hidden, true)
    testing.eq(reg:find({ "quiet" }).group, fs.basename(root))
    testing.eq(reg:find({ "a" }).hidden, false)
    testing.eq(reg:find({ "lint" }).group, "Check your work")
    fs.remove(root, { recursive = true })
end)

local function with_global(files, run)
    local home = support.tempdir()
    local dir = home .. "/dev/commands"
    for rel, text in pairs(files) do
        scripted(dir, rel, text)
    end
    support.with_env("XDG_CONFIG_HOME", home, function()
        run(dir)
    end)
    fs.remove(home, { recursive = true })
end

testing.test("a global script answers a command the project lacks", function()
    local root = make_project()
    with_global({
        ["hello.sh"] = "#!/usr/bin/env bash\n# Say hello.\n",
        ["g/sub.sh"] = "#!/usr/bin/env bash\n# Global sub.\n",
        ["lua/helper.lua"] = "return {}\n",
    }, function(dir)
        local reg = registry.load(root)
        local row = reg:find({ "hello" })
        testing.eq(row.source, "global")
        testing.eq(row.kind, "local")
        testing.eq(row.script, dir .. "/hello.sh")
        testing.eq(row.desc, "Say hello.")
        testing.eq(reg:find({ "g", "sub" }).source, "global")
        testing.eq(reg:is_parent("g"), true)
        testing.eq(reg:find({ "lua" }), nil)
        testing.eq(reg:find({ "a" }).source, "project")
        testing.eq(reg:find({ "lint" }).source, "builtin")
        testing.eq(registry.relative(row, root), "hello.sh")
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("a project script beats a global script", function()
    local root = make_project()
    scripted(root, ".dev/lint.sh", "#!/usr/bin/env bash\n# Project lint.\n")
    scripted(root, ".dev/both.sh", "#!/usr/bin/env bash\n# Project both.\n")
    scripted(root, ".dev/deploy/up.sh", "#!/usr/bin/env bash\n# Project up.\n")
    with_global({
        ["deploy.sh"] = "#!/usr/bin/env bash\n# Global deploy.\n",
        ["lint.sh"] = "#!/usr/bin/env bash\n# Global lint.\n",
        ["both.sh"] = "#!/usr/bin/env bash\n# Global both.\n",
        ["n/x.sh"] = "#!/usr/bin/env bash\n# Global x.\n",
        ["n/more.sh"] = "#!/usr/bin/env bash\n# Global more.\n",
    }, function()
        local reg = registry.load(root)
        testing.eq(reg:is_parent("deploy"), true)
        testing.eq(reg:find({ "deploy", "up" }).source, "project")
        testing.eq(reg:find({ "both" }).desc, "Project both.")
        testing.eq(reg:find({ "both" }).source, "project")
        testing.eq(reg:find({ "lint" }).desc, "Project lint.")
        testing.eq(reg:find({ "n", "x" }).desc, "Sub x.")
        testing.eq(reg:find({ "n", "x" }).source, "project")
        testing.eq(reg:find({ "n", "more" }).source, "global")
        testing.eq(words(reg:subs("n")), { "n x", "n more" })
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("a global script replaces a built-in subcommand", function()
    local root = make_project()
    with_global({
        ["tools/install.sh"] = "#!/usr/bin/env bash\n# Global install.\n# flags: --mine\n",
        ["box.sh"] = "#!/usr/bin/env bash\n# Global box.\n",
    }, function()
        local reg = registry.load(root)
        local row = reg:find({ "tools", "install" })
        testing.eq(row.kind, "override")
        testing.eq(row.source, "global")
        testing.eq(row.desc, "Global install.")
        testing.eq(reg:flags({ "tools", "install" }), { "--mine" })
        testing.eq(reg:shadowed_flags({ "tools", "install" })[1], "--dry-run")
        testing.eq(reg:find({ "box" }).kind, "builtin")
        scripted(root, ".dev/tools/install.sh", "#!/usr/bin/env bash\n# Project install.\n")
        local project_row = registry.load(root):find({ "tools", "install" })
        testing.eq(project_row.source, "project")
        testing.eq(project_row.desc, "Project install.")
    end)
    fs.remove(root, { recursive = true })
end)

local function described(text)
    return table.concat({ "#!/usr/bin/env bash", "# " .. text, "" }, "\n")
end

testing.test("a builtin word answers from the built-ins under an override", function()
    local root = make_project()
    scripted(root, ".dev/lint.sh", described("Project lint."))
    with_global({
        ["board/ls.sh"] = described("Global ls."),
    }, function()
        local reg = registry.load(root)
        testing.eq(reg:find({ "lint" }).kind, "override")
        local row = reg:find({ "builtin:lint" })
        testing.eq(row.kind, "builtin")
        testing.eq(row.words, { "lint" })
        testing.eq(reg:find({ "board", "ls" }).kind, "override")
        local sub = reg:find({ "builtin:board", "ls" })
        testing.eq(sub.kind, "builtin")
        testing.eq(sub.words, { "board", "ls" })
        local missing, reason = reg:find({ "builtin:a" })
        testing.eq(missing, nil)
        testing.eq(reason, "no builtin command a")
        testing.eq(reg:flags({ "builtin:board", "ls" })[1], "--column")
        testing.eq(words(reg:subs({ "builtin:board" }))[1], "board status")
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("a global word skips the project script of its name", function()
    local root = make_project()
    scripted(root, ".dev/both.sh", described("Project both."))
    scripted(root, ".dev/lint.sh", described("Project lint."))
    with_global({
        ["both.sh"] = described("Global both."),
        ["n/more.sh"] = described("Global more."),
    }, function(dir)
        local reg = registry.load(root)
        local row = reg:find({ "global:both" })
        testing.eq(row.source, "global")
        testing.eq(row.script, dir .. "/both.sh")
        testing.eq(row.desc, "Global both.")
        testing.eq(reg:find({ "both" }).source, "project")
        testing.eq(words(reg:subs({ "global:n" })), { "n more" })
        local missing, reason = reg:find({ "global:a" })
        testing.eq(missing, nil)
        testing.eq(reason, "no global command a")
        _, reason = reg:find({ "global:lint" })
        testing.eq(reason, "no global command lint")
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("another prefix is an unknown source and the sentence names it", function()
    local reg = registry.load(make_project())
    local row, reason = reg:find({ "project:a" })
    testing.eq(row, nil)
    testing.eq(reason, "unknown source project")
    testing.eq(registry.sentence(reason), "The source project is not builtin or global.")
    testing.eq(
        registry.sentence("no builtin command x y"),
        "The built-in commands have no command x y."
    )
    testing.eq(registry.sentence("no global command x"), "The global commands have no command x.")
    testing.eq({ registry.split("builtin:lint") }, { "builtin", "lint" })
    testing.eq({ registry.split("lint") }, {})
end)

testing.test("the override row names the replaced source", function()
    local root = make_project()
    scripted(root, ".dev/lint.sh", "#!/usr/bin/env bash\n# My lint.\n")
    scripted(root, ".dev/tools/install.sh", "#!/usr/bin/env bash\n# Project install.\n")
    scripted(root, ".dev/shared.sh", "#!/usr/bin/env bash\n# Project shared.\n")
    scripted(root, ".dev/own.sh", "#!/usr/bin/env bash\n# Own.\n")
    with_global({
        ["fmt.sh"] = "#!/usr/bin/env bash\n# Global fmt.\n",
        ["shared.sh"] = "#!/usr/bin/env bash\n# Global shared.\n",
        ["tools/check.sh"] = "#!/usr/bin/env bash\n# Global check.\n",
    }, function()
        local reg = registry.load(root)
        testing.eq(reg:find({ "lint" }).replaces, "builtin")
        testing.eq(reg:find({ "fmt" }).replaces, "builtin")
        testing.eq(reg:find({ "fmt" }).source, "global")
        testing.eq(reg:find({ "tools", "install" }).replaces, "builtin")
        testing.eq(reg:find({ "tools", "check" }).replaces, "builtin")
        testing.eq(reg:find({ "shared" }).replaces, "global")
        testing.eq(reg:find({ "shared" }).source, "project")
        testing.eq(reg:find({ "own" }).replaces, nil)
        testing.eq(reg:find({ "test" }).replaces, nil)
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("a script replaces a built-in subcommand but not a built-in parent command", function()
    local root = make_project()
    scripted(root, ".dev/box.sh", "#!/usr/bin/env bash\n# Fake box.\n")
    scripted(
        root,
        ".dev/tools/install.sh",
        "#!/usr/bin/env bash\n# Fake install.\n# flags: --fake\n"
    )
    scripted(root, ".dev/tools/extra.sh", "#!/usr/bin/env bash\n# Extra tool.\n")
    local reg = registry.load(root)
    testing.eq(reg:find({ "box" }).kind, "builtin")
    testing.eq(reg:is_parent("box"), true)
    testing.eq(reg:find({ "tools", "install" }).kind, "override")
    testing.eq(reg:flags({ "tools", "install" }), { "--fake" })
    testing.eq(reg:flags({ "tools" }), {})
    testing.eq(reg:find({ "tools", "extra" }).kind, "local")
    testing.eq(reg:find({ "tools" }).desc, "Install and check the tools in .dev/tools.tsv")
    fs.remove(root, { recursive = true })
end)

testing.test("a script named like a builtin command overrides it and keeps its place", function()
    local root = make_project()
    scripted(root, ".dev/lint.sh", "#!/usr/bin/env bash\n# My lint.\n# flags: --mine\n")
    scripted(root, ".dev/deploy.sh", "#!/usr/bin/env bash\n# My deploy.\n# group: Elsewhere\n")
    local reg = registry.load(root)
    local lint = reg:find({ "lint" })
    testing.eq(lint.kind, "override")
    testing.eq(lint.desc, "My lint.")
    testing.eq(lint.group, "Check your work")
    testing.eq(reg:flags({ "lint" }), { "--mine" })
    testing.eq(reg:find({ "deploy" }).group, "Elsewhere")
    fs.remove(root, { recursive = true })
end)

testing.test("a flat script takes the whole name from a directory of the same name", function()
    local root = make_project()
    scripted(root, ".dev/n.sh", "#!/usr/bin/env bash\n# Flat n.\n")
    local warned = {}
    local reg = registry.load(root, {
        warn = function(message)
            warned[#warned + 1] = message
        end,
    })
    testing.eq(reg:is_parent("n"), false)
    testing.eq(reg:find({ "n" }).desc, "Flat n.")
    testing.eq(reg:find({ "n", "x" }), nil)
    testing.eq(reg:find({ "n" }).desc, "Flat n.")
    testing.eq(warned, {
        "The script "
            .. root
            .. "/.dev/n.sh shadows the directory "
            .. root
            .. "/.dev/n. Its subcommands never run.",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("a directory with no flat script of the same name gives no warning", function()
    local root = make_project()
    local warned = {}
    local reg = registry.load(root, {
        warn = function(message)
            warned[#warned + 1] = message
        end,
    })
    testing.eq(reg:is_parent("n"), true)
    testing.eq(warned, {})
    fs.remove(root, { recursive = true })
end)

testing.test("--help in a flags line is dropped with the warning", function()
    local root = make_project()
    scripted(root, ".dev/w.sh", "#!/usr/bin/env bash\n# W.\n# flags: --ok --help\n")
    local warned = {}
    local reg = registry.load(root, {
        warn = function(message)
            warned[#warned + 1] = message
        end,
    })
    testing.eq(reg:flags({ "w" }), { "--ok" })
    testing.eq(warned, {
        "The flags line of " .. root .. "/.dev/w.sh declares --help, which dev reserves before --.",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("a parent command with no description file lists its subcommand names", function()
    local root = make_project()
    scripted(root, ".dev/n/z.sh", "#!/usr/bin/env bash\n# Sub z.\n")
    testing.eq(registry.load(root):find({ "n" }).desc, "x, z")
    fs.remove(root, { recursive = true })
end)

testing.test(".dev/lua, .dev/topics and .dev/standalone are never parent commands", function()
    local root = make_project()
    scripted(root, ".dev/lua/helper.lua", "return {}\n", "644")
    scripted(root, ".dev/topics/guide.sh", "#!/usr/bin/env bash\n# Not a command.\n")
    scripted(root, ".dev/standalone/run.sh", "#!/usr/bin/env bash\n# Not a command.\n")
    local reg = registry.load(root)
    testing.eq(reg:is_parent("lua"), false)
    testing.eq(reg:is_parent("topics"), false)
    testing.eq(reg:find({ "lua" }), nil)
    testing.eq(reg:find({ "topics", "guide" }), nil)
    testing.eq(reg:is_parent("standalone"), false)
    testing.eq(reg:find({ "standalone", "run" }), nil)
    for _, row in ipairs(reg:commands()) do
        testing.ok(
            row.name ~= "lua" and row.name ~= "topics" and row.name ~= "standalone",
            "reserved directory listed as " .. row.name
        )
    end
    fs.remove(root, { recursive = true })
end)

testing.test("builtin flags come from the table and unknown commands give none", function()
    local reg = registry.load(support.tempdir())
    testing.eq(reg:flags({ "help" }), { "-a", "-k", "--topics", "--no-pager" })
    testing.eq(reg:flags({ "lint" }), {})
    testing.eq(reg:flags({ "nope" }), {})
    testing.eq(reg:find({ "bad word" }), nil)
end)

testing.test("detect_type follows the existing order", function()
    local root = support.tempdir()
    testing.eq(project.detect_type(root), nil)
    assert(fs.write(root .. "/Makefile", ""))
    testing.eq(project.detect_type(root), "make")
    scripted(root, "src/deep/x.lua", "", "644")
    testing.eq(project.detect_type(root), "lua")
    assert(fs.write(root .. "/package.json", "{}"))
    testing.eq(project.detect_type(root), "node")
    assert(fs.write(root .. "/project.godot", ""))
    testing.eq(project.detect_type(root), "godot")
    assert(fs.write(root .. "/main.lua", ""))
    assert(fs.write(root .. "/conf.lua", ""))
    testing.eq(project.detect_type(root), "love2d")
    assert(fs.write(root .. "/Cargo.toml", ""))
    testing.eq(project.detect_type(root), "rust")
    fs.remove(root, { recursive = true })
end)

testing.test(
    "detect_type ignores Lua files in hidden, node_modules and target directories",
    function()
        local root = support.tempdir()
        for _, dir in ipairs({ ".hidden", "node_modules", "target" }) do
            scripted(root, dir .. "/x.lua", "", "644")
        end
        scripted(root, ".dot.lua", "", "644")
        testing.eq(project.detect_type(root), nil)
        fs.remove(root, { recursive = true })
    end
)

local function root_from(dir, opts)
    local script = string.format(
        "package.path = %q; %sprint(require('dev.project').root())",
        support.absolute_path(),
        opts.uid0 and "require('dev.os').getuid = function() return 0 end; " or ""
    )
    return dev_os.capture({ "luajit", "-e", script }, { cwd = dir, env = opts.env })
end

testing.test("root finds the nearest .dev from a subdirectory", function()
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev"))
    assert(fs.mkdir(root .. "/sub/deep", { parents = true }))
    testing.eq(root_from(root .. "/sub/deep", {}), assert(fs.realpath(root)) .. "\n")
    fs.remove(root, { recursive = true })
end)

testing.test("as uid 0, root only tests for .jj, .git and .dev and runs no VCS command", function()
    local root = support.tempdir()
    local bin = support.tempdir()
    local marker = bin .. "/ran"
    scripted(bin, "jj", string.format("#!/bin/sh\ntouch %s\necho /wrong\n", marker))
    scripted(bin, "git", string.format("#!/bin/sh\ntouch %s\necho /wrong\n", marker))
    assert(fs.write(root .. "/.git", ""))
    assert(fs.mkdir(root .. "/sub/deep", { parents = true }))
    local env = { PATH = bin .. ":" .. os.getenv("PATH") }
    testing.eq(
        root_from(root .. "/sub/deep", { uid0 = true, env = env }),
        assert(fs.realpath(root)) .. "\n"
    )
    testing.eq(fs.exists(marker), false)
    fs.remove(root, { recursive = true })
    fs.remove(bin, { recursive = true })
end)

testing.test(
    "dotfile scripts and dot directories are neither commands nor parent commands",
    function()
        local root = make_project()
        scripted(root, ".dev/.hid.sh", "#!/usr/bin/env bash\n# Hidden file.\n")
        scripted(root, ".dev/.dd/x.sh", "#!/usr/bin/env bash\n# In a dot dir.\n")
        scripted(root, ".dev/n/.dot.sh", "#!/usr/bin/env bash\n# Dot sub.\n")
        local reg = registry.load(root)
        for _, row in ipairs(reg:commands()) do
            testing.ok(row.name:sub(1, 1) ~= ".", "dot name listed as " .. row.name)
        end
        testing.eq(reg:find({ "n", ".dot" }), nil)
        testing.eq(words(reg:subs("n")), { "n x" })
        fs.remove(root, { recursive = true })
    end
)

testing.test("local commands come in the order the shell glob gives", function()
    local root = support.tempdir()
    for _, name in ipairs({ "UP", "Up.Case", "a", "B", "b-c", "Zed" }) do
        scripted(root, ".dev/" .. name .. ".sh", "#!/usr/bin/env bash\n# " .. name .. ".\n")
    end
    local want = {}
    local out = dev_os.capture({ "bash", "-c", "printf '%s\\n' *.sh" }, { cwd = root .. "/.dev" })
    for name in out:gmatch("([^\n]+)%.sh\n") do
        want[#want + 1] = name
    end
    local got = words(registry.load(root):commands())
    testing.eq({ unpack(got, #got - #want + 1) }, want)
    fs.remove(root, { recursive = true })
end)

local function git_repo(root)
    return dev_os.run({ "git", "init", "-q", root }, { stdout = "null" }) == 0
end

testing.test("root asks git for the toplevel when no jj answers", function()
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = support.tempdir()
    assert(git_repo(root), "git init failed")
    assert(fs.mkdir(root .. "/sub/deep", { parents = true }))
    local env = { PATH = "/usr/bin:/bin:" .. fs.dirname(dev_os.which("git")) }
    testing.eq(root_from(root .. "/sub/deep", { env = env }), assert(fs.realpath(root)) .. "\n")
    fs.remove(root, { recursive = true })
end)

testing.test("root asks jj for the workspace root first", function()
    if not (dev_os.which("jj") and dev_os.which("git")) then
        print("skip - jj or git is not installed")
        return
    end
    local root = support.tempdir()
    assert(
        dev_os.run({ "jj", "git", "init", root }, { stdout = "null", stderr = "null" }) == 0,
        "jj init failed"
    )
    assert(fs.mkdir(root .. "/sub/deep", { parents = true }))
    testing.eq(root_from(root .. "/sub/deep", {}), assert(fs.realpath(root)) .. "\n")
    fs.remove(root, { recursive = true })
end)

local function quiet(argv, dir)
    return dev_os.run(argv, { cwd = dir, stdout = "null", stderr = "null" }) == 0
end

local function have_vcs()
    if dev_os.which("jj") and dev_os.which("git") then
        return true
    end
    print("skip - jj or git is not installed")
    return false
end

testing.test("root is a git worktree nested under a colocated jj checkout", function()
    if not have_vcs() then
        return
    end
    local root = support.tempdir()
    assert(quiet({ "jj", "git", "init", "--colocate", root }), "jj init failed")
    assert(
        quiet({
            "jj",
            "--config=user.name=t",
            "--config=user.email=t@example.com",
            "commit",
            "-m",
            "x",
        }, root),
        "jj commit failed"
    )
    assert(quiet({ "git", "worktree", "add", "--detach", root .. "/wt/tree" }, root))
    assert(fs.mkdir(root .. "/wt/tree/sub/deep", { parents = true }))
    local want = assert(fs.realpath(root .. "/wt/tree")) .. "\n"
    testing.eq(root_from(root .. "/wt/tree", {}), want)
    testing.eq(root_from(root .. "/wt/tree/sub/deep", {}), want)
    testing.eq(root_from(root, {}), assert(fs.realpath(root)) .. "\n")
    fs.remove(root, { recursive = true })
end)

testing.test("root keeps the jj checkout over an unrelated git clone nested in it", function()
    if not have_vcs() then
        return
    end
    local root = support.tempdir()
    assert(quiet({ "jj", "git", "init", "--colocate", root }), "jj init failed")
    assert(git_repo(root .. "/clone"), "git init failed")
    assert(fs.mkdir(root .. "/clone/sub", { parents = true }))
    local want = assert(fs.realpath(root)) .. "\n"
    testing.eq(root_from(root .. "/clone", {}), want)
    testing.eq(root_from(root .. "/clone/sub", {}), want)
    fs.remove(root, { recursive = true })
end)

testing.test("root keeps a jj workspace nested in a foreign git repo", function()
    if not have_vcs() then
        return
    end
    local outer = support.tempdir()
    assert(git_repo(outer), "git init failed")
    assert(fs.mkdir(outer .. "/main", { parents = true }))
    assert(quiet({ "jj", "git", "init", outer .. "/main" }), "jj init failed")
    assert(
        quiet({ "jj", "workspace", "add", outer .. "/ws" }, outer .. "/main"),
        "workspace failed"
    )
    assert(fs.mkdir(outer .. "/ws/sub", { parents = true }))
    local want = assert(fs.realpath(outer .. "/ws")) .. "\n"
    testing.eq(root_from(outer .. "/ws", {}), want)
    testing.eq(root_from(outer .. "/ws/sub", {}), want)
    fs.remove(outer, { recursive = true })
end)

testing.test("detect_type finds a nested Lua file within the search depth only", function()
    local root = support.tempdir()
    assert(fs.write(root .. "/Makefile", ""))
    scripted(root, "a/b/c/deep.lua", "", "644")
    scripted(root, "a/b/c/d/e/too_deep.lua", "", "644")
    testing.eq(project.detect_type(root), "lua")
    fs.remove(root .. "/a/b/c/deep.lua")
    testing.eq(project.detect_type(root), "make")
    fs.remove(root, { recursive = true })
end)
