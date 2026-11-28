local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local project = require("@dev/project")
local registry = require("@dev/registry")
local support = require("./support")

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

local function described(text)
    return table.concat({ "#!/usr/bin/env bash", "# " .. text, "" }, "\n")
end

local SPEC_A = table.concat({
    'local dev_command = require("@dev/command")',
    "return dev_command({",
    '    summary = "From the Luau command.",',
    '    flags = { { name = "lua", kind = "boolean" } },',
    "    run = function() end,",
    "})",
    "",
}, "\n")

local function make_project()
    local root = support.tempdir()
    scripted(root, ".dev/commands/a.sh", described("From the shell script."))
    scripted(root, ".dev/commands/a.luau", SPEC_A, "644")
    scripted(
        root,
        ".dev/commands/n/x.sh",
        table.concat({ "#!/usr/bin/env bash", "# Sub x.", "# group: Mine", "" }, "\n")
    )
    scripted(
        root,
        ".dev/commands/n/y.sh",
        table.concat({ "#!/usr/bin/env bash", "# Hidden sub.", "# hidden", "" }, "\n")
    )
    scripted(
        root,
        ".dev/commands/h.sh",
        table.concat({ "#!/usr/bin/env bash", "# Helper.", "# hidden", "" }, "\n")
    )
    scripted(
        root,
        ".dev/commands/quiet.sh",
        table.concat({ "#!/usr/bin/env bash", "# Quiet one.", "# hidden", "" }, "\n")
    )
    scripted(root, ".dev/commands/off.sh", described("Not executable."), "644")
    return root
end

testing.test(
    ".luau beats .sh and needs no exec bit, while an unexecutable .sh is no command",
    function()
        local root = make_project()
        scripted(root, ".dev/commands/a.ps1", "# From powershell.\n", "644")
        local reg = registry.load(root)
        local row = reg:find({ "a" })
        testing.eq(row.lang, "luau")
        testing.eq(row.desc, "From the Luau command.")
        testing.eq(row.kind, "local")
        testing.eq(reg:find({ "off" }), nil)
        testing.eq(reg:flags({ "a" }), { "--lua" })
        fs.remove(root, { recursive = true })
    end
)

testing.test("a .sh command beats a .ps1 command and a .lua file is refused", function()
    -- Shadow and mislabel commands with lower-priority and wrongly named files
    local root = make_project()
    scripted(root, ".dev/commands/b.ps1", "# Powershell b.\n", "644")
    scripted(root, ".dev/commands/b.sh", described("Shell b."))
    scripted(root, ".dev/commands/c.lua", "return {}\n", "644")

    -- Load the project while collecting every warning it raises
    local warned = {}
    local reg = registry.load(root, {
        warn = function(message)
            warned[#warned + 1] = message
        end,
    })

    -- Check the shell script wins and the .lua file is refused with a warning
    testing.eq(reg:find({ "b" }).lang, "sh")
    testing.eq(reg:find({ "c" }), nil)
    testing.eq(warned, {
        "Command files end in .luau, not .lua: " .. root .. "/.dev/commands/c.lua.",
    })
    fs.remove(root, { recursive = true })
end)

testing.test(
    "a directory with commands is a parent command whose subs leave out the hidden ones",
    function()
        local root = make_project()
        local reg = registry.load(root)
        testing.ok(reg:is_parent("n"), "n should be a parent command")
        testing.eq(words(reg:subs("n")), { "n x" })
        testing.eq(reg:find({ "n", "y" }).desc, "Hidden sub.")
        testing.eq(reg:find({ "n", "y" }).hidden, true)
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
    assert(
        fs.write(
            root .. "/.dev/commands/n/DESCRIPTION",
            table.concat({ "The n parent command", "second line", "" }, "\n")
        )
    )
    testing.eq(registry.load(root):find({ "n" }).desc, "The n parent command")
    fs.remove(root, { recursive = true })
end)

testing.test("commands lists builtins, then project commands, and lists hidden ones", function()
    -- Load every command the registry lists
    local root = make_project()
    local rows = registry.load(root):commands()
    local names = words(rows)

    -- Check builtins come first and project commands follow, hidden ones included
    testing.eq(rows[1].source, registry.Source.BUILTIN)
    testing.eq({ table.unpack(names, #names - 3) }, { "a", "h", "quiet", "n" })
    testing.eq(registry.load(root):find({ "h" }).desc, "Helper.")

    -- Check the unexecutable script is not listed
    local seen = {}
    for _, name in ipairs(names) do
        seen[name] = true
    end
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
    -- Make a config home to hold the global commands
    local home = support.tempdir()
    local dir = home .. "/dev/commands"

    -- Write each global script under it
    for rel, text in pairs(files) do
        scripted(dir, rel, text)
    end

    -- Run the body with that home as the config directory
    support.with_env("XDG_CONFIG_HOME", home, function()
        run(dir)
    end)

    -- Remove the home again
    fs.remove(home, { recursive = true })
end

testing.test("a global script answers a command the project lacks", function()
    local root = make_project()
    with_global({
        ["hello.sh"] = described("Say hello."),
        ["g/sub.sh"] = described("Global sub."),
    }, function(dir)
        local reg = registry.load(root)
        local row = reg:find({ "hello" })
        testing.eq(row.source, registry.Source.GLOBAL)
        testing.eq(row.kind, "local")
        testing.eq(row.script, dir .. "/hello.sh")
        testing.eq(row.desc, "Say hello.")
        testing.eq(reg:find({ "g", "sub" }).source, registry.Source.GLOBAL)
        testing.eq(reg:is_parent("g"), true)
        testing.eq(reg:find({ "a" }).source, registry.Source.PROJECT)
        testing.eq(reg:find({ "lint" }).source, registry.Source.BUILTIN)
        testing.eq(registry.relative(row, root), "hello.sh")
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("a project script beats a global script", function()
    local root = make_project()
    scripted(root, ".dev/commands/lint.sh", described("Project lint."))
    scripted(root, ".dev/commands/both.sh", described("Project both."))
    scripted(root, ".dev/commands/deploy/up.sh", described("Project up."))
    with_global({
        ["deploy.sh"] = described("Global deploy."),
        ["lint.sh"] = described("Global lint."),
        ["both.sh"] = described("Global both."),
        ["n/x.sh"] = described("Global x."),
        ["n/more.sh"] = described("Global more."),
    }, function()
        local reg = registry.load(root)
        testing.eq(reg:is_parent("deploy"), true)
        testing.eq(reg:find({ "deploy", "up" }).source, registry.Source.PROJECT)
        testing.eq(reg:find({ "both" }).desc, "Project both.")
        testing.eq(reg:find({ "both" }).source, registry.Source.PROJECT)
        testing.eq(reg:find({ "lint" }).desc, "Project lint.")
        testing.eq(reg:find({ "n", "x" }).desc, "Sub x.")
        testing.eq(reg:find({ "n", "x" }).source, registry.Source.PROJECT)
        testing.eq(reg:find({ "n", "more" }).source, registry.Source.GLOBAL)
        testing.eq(words(reg:subs("n")), { "n x", "n more" })
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("a global script replaces a built-in subcommand", function()
    local root = make_project()
    with_global({
        ["tools/install.sh"] = table.concat({
            "#!/usr/bin/env bash",
            "# Global install.",
            "# flag: mine kind=boolean",
            "",
        }, "\n"),
        ["box.sh"] = described("Global box."),
    }, function()
        local reg = registry.load(root)
        local row = reg:find({ "tools", "install" })
        testing.eq(row.kind, "override")
        testing.eq(row.source, registry.Source.GLOBAL)
        testing.eq(row.desc, "Global install.")
        testing.eq(reg:flags({ "tools", "install" }), { "--mine" })
        testing.eq(reg:shadowed_flags({ "tools", "install" })[1], "--dry-run")
        testing.eq(reg:find({ "box" }).kind, registry.Kind.BUILTIN)
        scripted(root, ".dev/commands/tools/install.sh", described("Project install."))
        local project_row = registry.load(root):find({ "tools", "install" })
        testing.eq(project_row.source, registry.Source.PROJECT)
        testing.eq(project_row.desc, "Project install.")
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("a builtin word answers from the built-ins under an override", function()
    local root = make_project()
    scripted(root, ".dev/commands/lint.sh", described("Project lint."))
    with_global({
        ["board/ls.sh"] = described("Global ls."),
    }, function()
        -- Reach a built-in command that a project script overrides
        local reg = registry.load(root)
        testing.eq(reg:find({ "lint" }).kind, "override")
        local row = reg:find({ "builtin:lint" })
        testing.eq(row.kind, registry.Kind.BUILTIN)
        testing.eq(row.words, { "lint" })

        -- Reach a built-in subcommand that a global script overrides
        testing.eq(reg:find({ "board", "ls" }).kind, "override")
        local sub = reg:find({ "builtin:board", "ls" })
        testing.eq(sub.kind, registry.Kind.BUILTIN)
        testing.eq(sub.words, { "board", "ls" })

        -- Report a word the built-ins lack, with the reason
        local missing, reason = reg:find({ "builtin:a" })
        testing.eq(missing, nil)
        testing.eq(reason, "no builtin command a")

        -- Read the built-in flags and subcommands past the override
        testing.eq(reg:flags({ "builtin:board", "ls" })[1], "--column")
        local listed = {}
        for _, name in ipairs(words(reg:subs({ "builtin:board" }))) do
            listed[name] = true
        end
        testing.eq(listed["board status"], true)
        testing.eq(listed["board ls"], true)
    end)
    fs.remove(root, { recursive = true })
end)

testing.test(
    "a project script shadowing a global folder warns with the global folder's path",
    function()
        local root = make_project()
        scripted(root, ".dev/commands/g.sh", described("Project g."))
        with_global({
            ["g/sub.sh"] = described("Global sub."),
        }, function(dir)
            local warned = {}
            local reg = registry.load(root, {
                warn = function(message)
                    warned[#warned + 1] = message
                end,
            })
            testing.eq(reg:find({ "g" }).source, registry.Source.PROJECT)
            testing.eq(reg:find({ "g", "sub" }), nil)
            testing.eq(warned, {
                "The script "
                    .. root
                    .. "/.dev/commands/g.sh shadows the folder "
                    .. dir
                    .. "/g. Its subcommands never run.",
            })
        end)
        fs.remove(root, { recursive = true })
    end
)

testing.test("a global word skips the project script of its name", function()
    local root = make_project()
    scripted(root, ".dev/commands/both.sh", described("Project both."))
    scripted(root, ".dev/commands/lint.sh", described("Project lint."))
    with_global({
        ["both.sh"] = described("Global both."),
        ["n/more.sh"] = described("Global more."),
    }, function(dir)
        -- Reach the global script that a project script shadows
        local reg = registry.load(root)
        local row = reg:find({ "global:both" })
        testing.eq(row.source, registry.Source.GLOBAL)
        testing.eq(row.script, dir .. "/both.sh")
        testing.eq(row.desc, "Global both.")
        testing.eq(reg:find({ "both" }).source, registry.Source.PROJECT)

        -- List only the global subcommands of a parent
        testing.eq(words(reg:subs({ "global:n" })), { "n more" })

        -- Report words the global commands lack, with the reason
        local missing, reason = reg:find({ "global:a" })
        testing.eq(missing, nil)
        testing.eq(reason, "no global command a")
        _, reason = reg:find({ "global:lint" })
        testing.eq(reason, "no global command lint")
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("another prefix is an unknown source and the sentence names it", function()
    -- Look up a word under a source that does not exist
    local reg = registry.load(make_project())
    local row, reason = reg:find({ "project:a" })
    testing.eq(row, nil)
    testing.eq(reason, "unknown source project")

    -- Phrase each reason as a sentence naming the source or command
    testing.eq(registry.sentence(reason), "The source project is not builtin or global.")
    testing.eq(
        registry.sentence("no builtin command x y"),
        "The built-in commands have no command x y."
    )
    testing.eq(registry.sentence("no global command x"), "The global commands have no command x.")

    -- Split a prefixed word into its source and name
    testing.eq({ registry.split("builtin:lint") }, { registry.Source.BUILTIN, "lint" })
    testing.eq({ registry.split("lint") }, {})
end)

testing.test("the override row names the replaced source", function()
    local root = make_project()
    scripted(root, ".dev/commands/lint.sh", described("My lint."))
    scripted(root, ".dev/commands/tools/install.sh", described("Project install."))
    scripted(root, ".dev/commands/shared.sh", described("Project shared."))
    scripted(root, ".dev/commands/own.sh", described("Own."))
    with_global({
        ["fmt.sh"] = described("Global fmt."),
        ["shared.sh"] = described("Global shared."),
        ["tools/check.sh"] = described("Global check."),
    }, function()
        local reg = registry.load(root)
        testing.eq(reg:find({ "lint" }).replaces, registry.Source.BUILTIN)
        testing.eq(reg:find({ "fmt" }).replaces, registry.Source.BUILTIN)
        testing.eq(reg:find({ "fmt" }).source, registry.Source.GLOBAL)
        testing.eq(reg:find({ "tools", "install" }).replaces, registry.Source.BUILTIN)
        testing.eq(reg:find({ "tools", "check" }).replaces, registry.Source.BUILTIN)
        testing.eq(reg:find({ "shared" }).replaces, registry.Source.GLOBAL)
        testing.eq(reg:find({ "shared" }).source, registry.Source.PROJECT)
        testing.eq(reg:find({ "own" }).replaces, nil)
        testing.eq(reg:find({ "test" }).replaces, nil)
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("a script replaces a built-in subcommand but not a built-in parent command", function()
    local root = make_project()
    scripted(root, ".dev/commands/box.sh", described("Fake box."))
    scripted(
        root,
        ".dev/commands/tools/install.sh",
        table.concat({
            "#!/usr/bin/env bash",
            "# Fake install.",
            "# flag: fake kind=boolean",
            "",
        }, "\n")
    )
    scripted(root, ".dev/commands/tools/extra.sh", described("Extra tool."))
    local reg = registry.load(root)
    testing.eq(reg:find({ "box" }).kind, registry.Kind.BUILTIN)
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
    scripted(
        root,
        ".dev/commands/lint.sh",
        table.concat({ "#!/usr/bin/env bash", "# My lint.", "# flag: mine kind=boolean", "" }, "\n")
    )
    scripted(
        root,
        ".dev/commands/deploy.sh",
        table.concat({ "#!/usr/bin/env bash", "# My deploy.", "# group: Elsewhere", "" }, "\n")
    )
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
    -- Add a flat script beside the directory of the same name
    local root = make_project()
    scripted(root, ".dev/commands/n.sh", described("Flat n."))

    -- Load the project while collecting every warning it raises
    local warned = {}
    local reg = registry.load(root, {
        warn = function(message)
            warned[#warned + 1] = message
        end,
    })

    -- Check the script replaces the folder and a warning says the subs never run
    testing.eq(reg:is_parent("n"), false)
    testing.eq(reg:find({ "n" }).desc, "Flat n.")
    testing.eq(reg:find({ "n", "x" }), nil)
    testing.eq(reg:find({ "n" }).desc, "Flat n.")
    testing.eq(warned, {
        "The script "
            .. root
            .. "/.dev/commands/n.sh shadows the folder "
            .. root
            .. "/.dev/commands/n. Its subcommands never run.",
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

testing.test("a flag named help makes the command's spec fail to load", function()
    local root = make_project()
    scripted(
        root,
        ".dev/commands/w.sh",
        table.concat({ "#!/usr/bin/env bash", "# W.", "# flag: help", "" }, "\n")
    )
    local reg = registry.load(root)
    local row = reg:find({ "w" })
    testing.ok(row.broken and row.broken:find("reserved", 1, true), tostring(row.broken))
    testing.eq(reg:flags({ "w" }), {})
    fs.remove(root, { recursive = true })
end)

testing.test("a parent command with no description file lists its subcommand names", function()
    local root = make_project()
    scripted(root, ".dev/commands/n/z.sh", described("Sub z."))
    testing.eq(registry.load(root):find({ "n" }).desc, "x, z")
    fs.remove(root, { recursive = true })
end)

testing.test("helpers, lib and topics beside commands are never commands", function()
    -- Put scripts in folders that are not command folders
    local root = make_project()
    scripted(root, ".dev/helpers/remote.luau", "return function() end\n", "644")
    scripted(root, ".dev/lib/tools/shout.luau", "return {}\n", "644")
    scripted(root, ".dev/help/guide.sh", described("Not a command."))
    scripted(root, ".dev/own.sh", described("Not in commands."))

    -- Check none of them resolves to a command
    local reg = registry.load(root)
    testing.eq(reg:find({ "helpers" }), nil)
    testing.eq(reg:find({ "remote" }), nil)
    testing.eq(reg:find({ "lib" }), nil)
    testing.eq(reg:find({ "help" }).source, registry.Source.BUILTIN)
    testing.eq(reg:find({ "own" }), nil)

    -- Check no reserved folder shows up in the command list
    for _, row in ipairs(reg:commands()) do
        testing.ok(
            row.source == registry.Source.BUILTIN
                or (row.name ~= "helpers" and row.name ~= "lib" and row.name ~= "help"),
            "reserved folder listed as " .. row.name
        )
    end
    fs.remove(root, { recursive = true })
end)

testing.test("a command has the flags its spec declares and an unknown command has none", function()
    local reg = registry.load(support.tempdir())
    testing.eq(reg:flags({ "nope" }), {})
    testing.eq(reg:find({ "bad word" }), nil)
end)

testing.test("detect_type follows the existing order", function()
    -- Detect no type in an empty directory
    local root = support.tempdir()
    testing.eq(project.detect_type(root), nil)

    -- Detect make from a Makefile
    assert(fs.write(root .. "/Makefile", ""))
    testing.eq(project.detect_type(root), "make")

    -- Detect lua once a nested Lua file appears
    scripted(root, "src/deep/x.lua", "", "644")
    testing.eq(project.detect_type(root), "lua")

    -- Detect node over lua once package.json appears
    assert(fs.write(root .. "/package.json", "{}"))
    testing.eq(project.detect_type(root), "node")

    -- Detect godot over node once project.godot appears
    assert(fs.write(root .. "/project.godot", ""))
    testing.eq(project.detect_type(root), "godot")

    -- Detect love2d over godot once main.lua and conf.lua appear
    assert(fs.write(root .. "/main.lua", ""))
    assert(fs.write(root .. "/conf.lua", ""))
    testing.eq(project.detect_type(root), "love2d")

    -- Detect rust over everything once Cargo.toml appears
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
    local code = (opts.uid0 and "require('@dev/os').getuid = function() return 0 end; " or "")
        .. "print(require('@dev/project').root())"
    return dev_os.capture(support.eval(code), { cwd = dir, env = opts.env })
end

testing.test("root finds the nearest .dev from a subdirectory", function()
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev"))
    assert(fs.mkdir(root .. "/sub/deep", { parents = true }))
    testing.eq(root_from(root .. "/sub/deep", {}), assert(fs.realpath(root)) .. "\n")
    fs.remove(root, { recursive = true })
end)

testing.test("as uid 0, root only tests for .jj, .git and .dev and runs no VCS command", function()
    -- Mark a root with .git and put VCS stubs that record any run on PATH
    local root = support.tempdir()
    local bin = support.tempdir()
    local marker = bin .. "/ran"
    local stub = table.concat({ "#!/bin/sh", "touch %s", "echo /wrong", "" }, "\n")
    scripted(bin, "jj", string.format(stub, marker))
    scripted(bin, "git", string.format(stub, marker))
    assert(fs.write(root .. "/.git", ""))
    assert(fs.mkdir(root .. "/sub/deep", { parents = true }))

    -- Resolve the root as uid 0 from a nested directory
    local env = { PATH = bin .. ":" .. dev_os.getenv("PATH") }
    testing.eq(
        root_from(root .. "/sub/deep", { uid0 = true, env = env }),
        assert(fs.realpath(root)) .. "\n"
    )

    -- Check no stub ran
    testing.eq(fs.exists(marker), false)
    fs.remove(root, { recursive = true })
    fs.remove(bin, { recursive = true })
end)

testing.test(
    "dotfile scripts and dot directories are neither commands nor parent commands",
    function()
        -- Add scripts under dot names
        local root = make_project()
        scripted(root, ".dev/commands/.hid.sh", described("Hidden file."))
        scripted(root, ".dev/commands/.dd/x.sh", described("In a dot dir."))
        scripted(root, ".dev/commands/n/.dot.sh", described("Dot sub."))

        -- Check no listed command has a dot name
        local reg = registry.load(root)
        for _, row in ipairs(reg:commands()) do
            testing.ok(row.name:sub(1, 1) ~= ".", "dot name listed as " .. row.name)
        end

        -- Check a dot sub is not found or listed
        testing.eq(reg:find({ "n", ".dot" }), nil)
        testing.eq(words(reg:subs("n")), { "n x" })
        fs.remove(root, { recursive = true })
    end
)

testing.test("a parent command with a hidden-group sub and a visible one stays visible", function()
    local root = make_project()
    scripted(
        root,
        ".dev/commands/m/a.sh",
        table.concat({ "#!/usr/bin/env bash", "# A.", "# group: hidden", "" }, "\n")
    )
    scripted(root, ".dev/commands/m/b.sh", described("B."))
    local reg = registry.load(root)
    testing.eq(reg:find({ "m" }).hidden, false)
    testing.eq(reg:find({ "m" }).desc, "b")
    testing.eq(words(reg:subs("m")), { "m b" })
    fs.remove(root, { recursive = true })
end)

testing.test("local commands come in byte order", function()
    local root = support.tempdir()
    for _, name in ipairs({ "UP", "a", "B", "b-c", "Zed" }) do
        scripted(root, ".dev/commands/" .. name .. ".sh", described(name .. "."))
    end
    local want = { "B", "UP", "Zed", "a", "b-c" }
    local got = words(registry.load(root):commands())
    testing.eq({ table.unpack(got, #got - #want + 1) }, want)
    fs.remove(root, { recursive = true })
end)

local function git_repo(root)
    return dev_os.run({ "git", "init", "-q", root }, { stdout = "null" }) == 0
end

testing.test("root asks git for the toplevel when no jj answers", function()
    -- Skip when git is not installed
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end

    -- Make a git repository with a nested directory
    local root = support.tempdir()
    assert(git_repo(root), "git init failed")
    assert(fs.mkdir(root .. "/sub/deep", { parents = true }))

    -- Resolve the root with only git reachable on PATH
    local env = { PATH = "/usr/bin:/bin:" .. fs.dirname(dev_os.which("git")) }
    testing.eq(root_from(root .. "/sub/deep", { env = env }), assert(fs.realpath(root)) .. "\n")
    fs.remove(root, { recursive = true })
end)

testing.test("root asks jj for the workspace root first", function()
    -- Skip when jj or git is not installed
    if not (dev_os.which("jj") and dev_os.which("git")) then
        print("skip - jj or git is not installed")
        return
    end

    -- Make a jj repository with a nested directory
    local root = support.tempdir()
    assert(
        dev_os.run({ "jj", "git", "init", root }, { stdout = "null", stderr = "null" }) == 0,
        "jj init failed"
    )
    assert(fs.mkdir(root .. "/sub/deep", { parents = true }))

    -- Resolve the root from the nested directory
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
    -- Skip when jj or git is not installed
    if not have_vcs() then
        return
    end

    -- Make a colocated jj checkout with one commit
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

    -- Nest a git worktree with a deeper directory inside it
    assert(quiet({ "git", "worktree", "add", "--detach", root .. "/wt/tree" }, root))
    assert(fs.mkdir(root .. "/wt/tree/sub/deep", { parents = true }))

    -- Check the worktree is its own root and the checkout above it stays its own
    local want = assert(fs.realpath(root .. "/wt/tree")) .. "\n"
    testing.eq(root_from(root .. "/wt/tree", {}), want)
    testing.eq(root_from(root .. "/wt/tree/sub/deep", {}), want)
    testing.eq(root_from(root, {}), assert(fs.realpath(root)) .. "\n")
    fs.remove(root, { recursive = true })
end)

testing.test("root keeps the jj checkout over an unrelated git clone nested in it", function()
    -- Skip when jj or git is not installed
    if not have_vcs() then
        return
    end

    -- Nest an unrelated git clone with a subdirectory in a jj checkout
    local root = support.tempdir()
    assert(quiet({ "jj", "git", "init", "--colocate", root }), "jj init failed")
    assert(git_repo(root .. "/clone"), "git init failed")
    assert(fs.mkdir(root .. "/clone/sub", { parents = true }))

    -- Check the jj checkout stays the root from inside the clone
    local want = assert(fs.realpath(root)) .. "\n"
    testing.eq(root_from(root .. "/clone", {}), want)
    testing.eq(root_from(root .. "/clone/sub", {}), want)
    fs.remove(root, { recursive = true })
end)

testing.test("root keeps a jj workspace nested in a foreign git repo", function()
    -- Skip when jj or git is not installed
    if not have_vcs() then
        return
    end

    -- Put a jj repository inside a foreign git repository
    local outer = support.tempdir()
    assert(git_repo(outer), "git init failed")
    assert(fs.mkdir(outer .. "/main", { parents = true }))
    assert(quiet({ "jj", "git", "init", outer .. "/main" }), "jj init failed")

    -- Add a jj workspace with a subdirectory beside it
    assert(
        quiet({ "jj", "workspace", "add", outer .. "/ws" }, outer .. "/main"),
        "workspace failed"
    )
    assert(fs.mkdir(outer .. "/ws/sub", { parents = true }))

    -- Check the workspace stays the root over the foreign git repository
    local want = assert(fs.realpath(outer .. "/ws")) .. "\n"
    testing.eq(root_from(outer .. "/ws", {}), want)
    testing.eq(root_from(outer .. "/ws/sub", {}), want)
    fs.remove(outer, { recursive = true })
end)

testing.test("detect_type finds a nested Lua file within the search depth only", function()
    -- Start from a Makefile project
    local root = support.tempdir()
    assert(fs.write(root .. "/Makefile", ""))

    -- Add one Lua file within the search depth and one beyond it
    scripted(root, "a/b/c/deep.lua", "", "644")
    scripted(root, "a/b/c/d/e/too_deep.lua", "", "644")

    -- Check only the shallow file makes the project lua
    testing.eq(project.detect_type(root), "lua")

    -- Check the project falls back to make without it
    fs.remove(root .. "/a/b/c/deep.lua")
    testing.eq(project.detect_type(root), "make")
    fs.remove(root, { recursive = true })
end)
