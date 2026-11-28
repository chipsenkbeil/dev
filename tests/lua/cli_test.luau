local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local registry = require("@dev/registry")
local support = require("./support")
local version = require("@dev/version")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local FIXTURES = REPO .. "/tests/lua/fixtures/commands/"

local OUTSIDE_COMMANDS = { ["config.toml"] = true }
local LUAURC = '{ "aliases": { "lib": "./.dev/lib" } }\n'

local function project(files)
    -- Make a project with a Luau alias for its lib folder
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev", { parents = true }))
    assert(fs.write(root .. "/.luaurc", LUAURC))

    -- Write each file where its kind belongs, copying a fixture when it names one
    for name, source in pairs(files) do
        local inside = OUTSIDE_COMMANDS[name] or name:find("^helpers/") or name:find("^lib/")
        local path = root .. "/.dev/" .. (inside and "" or "commands/") .. name
        assert(fs.mkdir(fs.dirname(path), { parents = true }))
        local text = source:sub(1, 1) == "@" and assert(fs.read(FIXTURES .. source:sub(2)))
            or source
        assert(fs.write(path, text))
        assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
    end

    -- Hand back the project root
    return root
end

local function luau(spec_body, run_body)
    return table.concat({
        'local dev_command = require("@dev/command")',
        "return dev_command({",
        spec_body,
        "    run = function(opts, args, ctx)",
        run_body,
        "    end,",
        "})",
        "",
    }, "\n")
end

local function dev(root, args, env)
    -- Put the dev binary before the words
    local argv = { support.DEV }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end

    -- Start from a quiet local environment and apply the caller's changes
    local merged = { CI = "", DEV_REMOTE = "0", XDG_CONFIG_HOME = support.tempdir() }
    for key, value in pairs(env or {}) do
        merged[key] = value
    end

    -- Run dev in the project with its output merged
    return dev_os.capture(argv, { cwd = root, stderr = "stdout", env = merged })
end

testing.test("-vv gives level 2 and a bare -v after -- stays an argument", function()
    -- Write a command that reports its verbosity
    local root = project({ ["v.luau"] = "@v.luau" })

    -- Expect level 2 for -vv
    local out = dev(root, { "-vv", "v" })
    testing.ok(out:find("v\ttrue\t2", 1, true), out)

    -- Expect a -v after -- to stay an argument at level 0
    out = dev(root, { "v", "--", "-v" })
    testing.ok(out:find("args\t-v", 1, true), out)
    testing.ok(out:find("v\ttrue\t0", 1, true), out)
end)

testing.test("a .luau command gets positional args and KEY=value vars", function()
    local out = dev(project({ ["v.luau"] = "@v.luau" }), { "v", "a", "B=1", "--", "--x" })
    testing.ok(out:find("args\ta,--x", 1, true), out)
    testing.ok(out:find("vars\tB=1", 1, true), out)
end)

testing.test(
    "a positional command keeps KEY=value words in args, and other commands split them",
    function()
        -- Make one command positional and keep another as it was
        local body = assert(fs.read(FIXTURES .. "v.luau"))
        local root = project({
            ["p.luau"] = body:gsub(
                "summary = ([^\n]*)\n",
                table.concat({
                    "summary = %1",
                    "    positional = true,",
                    "",
                }, "\n"),
                1
            ),
            ["q.luau"] = body,
        })

        -- Expect the positional command to keep KEY=value words in args
        local out = dev(root, { "p", "Season=1", "a", "B=2" })
        testing.ok(out:find("args\tSeason=1,a,B=2\n", 1, true), out)
        testing.ok(out:find("vars\t\n", 1, true), out)

        -- Expect the other command to split them into vars
        out = dev(root, { "q", "Season=1", "a" })
        testing.ok(out:find("args\ta\n", 1, true), out)
        testing.ok(out:find("vars\tSeason=1\n", 1, true), out)

        -- Remove the project
        fs.remove(root, { recursive = true })
    end
)

testing.test("a .luau command's integer is the exit code", function()
    local root = project({ ["seven.luau"] = "@seven.luau" })
    local _, code = dev(root, { "seven" })
    testing.eq(code, 7)
end)

testing.test("an error in a .luau command prints one line and exits 1", function()
    local out, code = dev(project({ ["boom.luau"] = "@boom.luau" }), { "boom" })
    testing.eq(code, 1)
    testing.eq(out, "boom\n")
    testing.ok(not out:find("stack traceback", 1, true), out)
end)

testing.test("a script error prints no program prefix", function()
    local out, code = dev(project({ ["boom.luau"] = "@boom.luau" }), { "boom" })
    testing.eq(code, 1)
    testing.ok(not out:find("dev boom", 1, true), out)
end)

testing.test("a syntax error in a .luau command is handled the same way", function()
    local out, code = dev(project({ ["bad.luau"] = "local = =\n" }), { "bad" })
    testing.eq(code, 1)
    testing.ok(out:find("The command bad did not load: ", 1, true), out)
    testing.ok(not out:find("stack traceback", 1, true), out)
end)

testing.test("a .luau command beats a .sh command of the same name", function()
    local out = dev(project({ ["both.luau"] = "@both.luau", ["both.sh"] = "@both.sh" }), { "both" })
    testing.eq(out, "luau ran\n")
end)

testing.test("a .sh command runs by exec with its arguments", function()
    -- Write a script that echoes its arguments and VERBOSE
    local script = table.concat({
        "#!/usr/bin/env bash",
        'echo "sh $* ${VERBOSE:-unset}"',
        "",
    }, "\n")
    local root = project({ ["s.sh"] = script })

    -- Run it plainly and expect no VERBOSE
    testing.eq(dev(root, { "s", "a", "B=1" }), "sh a B=1 unset\n")

    -- Run it with -v and expect the trace line and VERBOSE set
    testing.eq(
        dev(root, { "-v", "s" }),
        table.concat({
            "+ .dev/commands/s.sh",
            "sh  1",
            "",
        }, "\n")
    )
end)

testing.test("dev run -- -h reaches a command", function()
    local out = dev(project({ ["run.luau"] = "@run.luau" }), { "run", "--", "-h" })
    testing.eq(out, "run got\t-h\n")
end)

testing.test("a .luau command finds modules under .dev/lib", function()
    local root = project({
        ["helper.luau"] = "@helper.luau",
        ["lib/tools/shout.luau"] = "return { shout = function(s) return s:upper() end }\n",
    })
    testing.eq(dev(root, { "helper" }), "HI\n")
end)

testing.test("a global .luau command requires through the global .luaurc", function()
    -- Make a global config whose lib alias points at its own lib folder
    local config = support.tempdir()
    assert(fs.mkdir(config .. "/dev/lib/tools", { parents = true }))
    assert(fs.write(config .. "/dev/.luaurc", '{ "aliases": { "lib": "lib" } }\n'))

    -- Add a module under the global lib
    assert(
        fs.write(
            config .. "/dev/lib/tools/shout.luau",
            "return { shout = function(s) return s:upper() end }\n"
        )
    )

    -- Add a global command that requires it
    assert(fs.mkdir(config .. "/dev/commands", { parents = true }))
    assert(
        fs.write(config .. "/dev/commands/helper.luau", assert(fs.read(FIXTURES .. "helper.luau")))
    )

    -- Run the command from a project that has no commands of its own
    local root = project({})
    local env = { XDG_CONFIG_HOME = config }
    testing.eq(dev(root, { "helper" }, env), "HI\n")
end)

local function dev_as(root, args, env)
    -- Load the fake root module before the words
    local words = { "-l", REPO .. "/tests/dev/fixtures/fake_root.luau" }

    -- Append the caller's words
    for _, word in ipairs(args) do
        words[#words + 1] = word
    end

    -- Run dev with the module loaded
    return dev(root, words, env)
end

testing.test("the root gate refuses a command other than tools install and check", function()
    -- Pretend to be root on Linux in a project with a command
    local root = project({ ["v.luau"] = "@v.luau" })
    local env = { FAKE_UID = "0", FAKE_OS = "Linux" }

    -- Refuse a project command
    local out, code = dev_as(root, { "v" }, env)
    testing.eq(code, 2)
    testing.eq(out, "As root, dev runs only `dev tools install` and `dev tools check`.\n")

    -- Refuse tools check off Linux
    env.FAKE_OS = "Darwin"
    out, code = dev_as(root, { "tools", "check" }, env)
    testing.eq(code, 2)
    testing.eq(out, "As root, dev runs only on Linux.\n")
end)

testing.test("as root no project command is read, even a broken one", function()
    local root = project({ ["bad.luau"] = "error('project code ran')\n" })
    local out, code = dev_as(root, { "bad" }, { FAKE_UID = "0", FAKE_OS = "Linux" })
    testing.eq(code, 2)
    testing.ok(not out:find("project code ran", 1, true), out)
end)

testing.test(
    "--remote refuses a machine-local command and an unknown subcommand is a usage error",
    function()
        -- Make a project with a command
        local root = project({ ["v.luau"] = "@v.luau" })

        -- Refuse --remote on a machine-local built-in
        local out, code = dev(root, { "--remote", "fmt" })
        testing.eq(code, 2)
        testing.ok(
            out:find("dev fmt: runs on this machine only, so --remote does not apply", 1, true),
            out
        )

        -- Refuse an unknown subcommand
        out, code = dev(root, { "tools", "zap" })
        testing.eq(code, 2)
        testing.ok(out:find("dev tools: unknown subcommand zap", 1, true), out)
    end
)

testing.test("a parent command runs its subcommand and lists a hidden one only in help", function()
    -- Write a visible and a hidden subcommand under one parent
    local root = project({
        ["n/x.sh"] = table.concat({
            "#!/usr/bin/env bash",
            "echo x ran",
            "",
        }, "\n"),
        ["n/h.sh"] = table.concat({
            "#!/usr/bin/env bash",
            "# Helper.",
            "# hidden",
            "echo helper",
            "",
        }, "\n"),
    })

    -- Run each subcommand by name
    testing.eq(dev(root, { "n", "x" }), "x ran\n")
    testing.eq(dev(root, { "n", "h" }), "helper\n")

    -- List only the visible one when the parent runs bare
    local out, code = dev(root, { "n" })
    testing.eq(code, 2)
    testing.ok(
        out:find(
            table.concat({
                "subcommands",
                "  x",
            }, "\n"),
            1,
            true
        ),
        out
    )
    testing.ok(not out:find("  h", 1, true), out)
end)

testing.test("a .luau command's children see VERBOSE only when it is on", function()
    -- Write a command that reports the VERBOSE its child sees
    local root = project({
        ["e.luau"] = luau(
            '    summary = "Show VERBOSE.",',
            table.concat({
                '        local seen = require("@dev/os").capture({ "sh", "-c", \'printf %s "${VERBOSE-unset}"\' })',
                '        require("@dev/os").stdout:write(seen, "|", tostring(ctx.verbose))',
            }, "\n")
        ),
    })

    -- Expect VERBOSE unset when the caller turns it off
    testing.eq(dev(root, { "e" }, { VERBOSE = "no" }), "unset|0")
    testing.eq(dev(root, { "e" }, { VERBOSE = "0" }), "unset|0")

    -- Expect VERBOSE set when the caller turns it on
    local out = dev(root, { "e" }, { VERBOSE = "yes" })
    testing.ok(out:find("1|1", 1, true), out)
end)

testing.test("a .luau command's exit code is taken modulo 256 like a shell's", function()
    -- Write commands that return codes outside 0 to 255
    local root = project({
        ["big.luau"] = luau('    summary = "Big.",', "        return 300"),
        ["neg.luau"] = luau('    summary = "Neg.",', "        return -1"),
        ["huge.luau"] = luau('    summary = "Huge.",', "        return 1099511627776"),
    })

    -- Reduce a code above 255
    local _, code = dev(root, { "big" })
    testing.eq(code, 44)

    -- Wrap a negative code
    _, code = dev(root, { "neg" })
    testing.eq(code, 255)

    -- Reduce a multiple of 256 to zero
    _, code = dev(root, { "huge" })
    testing.eq(code, 0)
end)

testing.test("a .luau command that cannot be read is an error", function()
    -- Skip when root can read any file
    if dev_os.getuid() == 0 then
        return
    end

    -- Lock a command file
    local root = project({ ["locked.luau"] = "return 0\n" })
    assert(
        dev_os.run({ "chmod", "000", root .. "/.dev/commands/locked.luau" }) == 0,
        "chmod failed"
    )

    -- Expect a failure that names the read error
    local out, code = dev(root, { "locked" })
    testing.eq(code, 1)
    testing.ok(out:find("The command locked did not load: cannot read ", 1, true), out)
end)

local function echoing(text)
    return table.concat({ "#!/usr/bin/env bash", "echo " .. text, "" }, "\n")
end

local function overriding_global()
    -- Make a global config folder
    local config = support.tempdir()
    local commands = config .. "/dev/commands"

    -- Write global commands that shadow the built-in ones
    for name, text in pairs({
        ["init.sh"] = echoing("global init ran"),
        ["board/ls.sh"] = echoing("global ls ran"),
        ["shared.sh"] = echoing("global shared ran"),
    }) do
        local path = commands .. "/" .. name
        assert(fs.mkdir(fs.dirname(path), { parents = true }))
        assert(fs.write(path, text))
        assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
    end

    -- Hand back an environment that points at the folder
    return { XDG_CONFIG_HOME = config }
end

testing.test("builtin:init runs the built-in under a global init", function()
    -- Shadow init with a global command
    local env = overriding_global()
    local root = project({})

    -- Expect the global command by its bare name
    testing.eq(dev(root, { "init" }, env), "global init ran\n")

    -- Expect the built-in help under the builtin prefix
    local out, code = dev(root, { "builtin:init", "-h" }, env)
    testing.eq(code, 0)
    testing.ok(out:find("Set up a project's version control and remotes", 1, true), out)
    testing.ok(not out:find("global init ran", 1, true), out)
end)

testing.test("builtin:board ls reaches the built-in subcommand under an override", function()
    -- Shadow board ls with a global command
    local env = overriding_global()
    local root = project({})

    -- Expect the global command by its bare name
    testing.eq(dev(root, { "board", "ls" }, env), "global ls ran\n")

    -- Expect the built-in help under the builtin prefix
    local out, code = dev(root, { "builtin:board", "ls", "-h" }, env)
    testing.eq(code, 0)
    testing.ok(out:find("List the cards of the board", 1, true), out)
end)

testing.test("global:shared answers from the global folder and skips the project script", function()
    -- Shadow a global command with a project script of the same name
    local env = overriding_global()
    local root = project({ ["shared.sh"] = echoing("project shared ran") })

    -- Expect the project script by its bare name
    testing.eq(dev(root, { "shared" }, env), "project shared ran\n")

    -- Expect the global script by its prefix
    testing.eq(dev(root, { "global:shared" }, env), "global shared ran\n")

    -- Expect a global subcommand by its prefix
    testing.eq(dev(root, { "global:board", "ls" }, env), "global ls ran\n")
end)

testing.test("an unknown source is a usage error naming it", function()
    -- Make a project and an environment with global commands
    local env = overriding_global()
    local root = project({})

    -- Refuse a source that is neither built-in nor global
    local out, code = dev(root, { "project:lint" }, env)
    testing.eq(code, 2)
    testing.eq(out, "The source project is not builtin or global.\n")

    -- Refuse a missing built-in command
    out, code = dev(root, { "builtin:nope" }, env)
    testing.eq(code, 2)
    testing.eq(out, "The built-in commands have no command nope.\n")

    -- Refuse a missing global command
    out, code = dev(root, { "global:lint" }, env)
    testing.eq(code, 2)
    testing.eq(out, "The global commands have no command lint.\n")
end)

local REFUSAL = ". Pass it after -- to reach the command.\n"

local function marked(root)
    return fs.is_file(root .. "/marker")
end

local function touching(flag)
    -- List the script's lines without a flag
    local lines = {
        "#!/usr/bin/env bash",
        "# Touch.",
        "# passthrough",
        "# arg: words list",
        'touch "$MARKER"',
        'echo "sh $*"',
        "",
    }

    -- Declare the flag after the summary when one is given
    if flag then
        table.insert(lines, 3, "# flag: " .. flag .. " -- A count")
    end

    -- Join the lines into the script
    return table.concat(lines, "\n")
end

local function undeclared_project()
    local root = project({
        ["s.sh"] = touching("days"),
        ["d.sh"] = table.concat({
            "#!/usr/bin/env bash",
            "# Days.",
            "# flag: days -- A count",
            'echo "days=${DEV_FLAG_DAYS-unset}|$*"',
            "",
        }, "\n"),
        ["l.luau"] = luau(
            table.concat({
                '    summary = "Touch.",',
                '    flags = { { name = "days" } },',
                '    args = { { name = "words", list = true } },',
                "    passthrough = true,",
            }, "\n"),
            table.concat({
                '        require("@dev/fs").write(require("@dev/os").getenv("MARKER"), "")',
                '        print("luau", table.concat(args.words, ","), table.concat(ctx.passthrough or {}, ","), opts.days)',
            }, "\n")
        ),
        ["n/x.sh"] = touching("days"),
        ["n/y.luau"] = luau(
            '    summary = "Touch.",',
            '        require("@dev/fs").write(require("@dev/os").getenv("MARKER"), "")'
        ),
    })
    return root, { MARKER = root .. "/marker" }
end

testing.test("an undeclared flag is refused before a .sh command runs", function()
    local root, env = undeclared_project()
    local out, code = dev(root, { "s", "--nope" }, env)
    testing.eq(code, 2)
    testing.eq(out, "dev s: Unknown flag --nope" .. REFUSAL .. "usage: dev s [--days] [words...]\n")
    testing.ok(not marked(root), "script ran")
end)

testing.test("an undeclared flag is refused before a .luau command runs", function()
    local root, env = undeclared_project()
    local out, code = dev(root, { "l", "a", "--nope=1" }, env)
    testing.eq(code, 2)
    testing.eq(out, "dev l: Unknown flag --nope" .. REFUSAL .. "usage: dev l [--days] [words...]\n")
    testing.ok(not marked(root), "script ran")
end)

testing.test("an undeclared flag of a parent command subcommand names both words", function()
    local root, env = undeclared_project()
    for _, sub in ipairs({ "x", "y" }) do
        local out, code = dev(root, { "n", sub, "-z" }, env)
        testing.eq(code, 2)
        testing.ok(out:find("dev n " .. sub .. ": Unknown flag -z", 1, true), out)
        testing.ok(not marked(root), "script ran")
    end
end)

testing.test("a declared flag reaches the script as DEV_FLAG_NAME", function()
    -- Make a project whose commands declare a days flag
    local root, env = undeclared_project()

    -- Pass the value as the next word
    testing.eq(dev(root, { "d", "--days", "7" }, env), "days=7|\n")

    -- Pass the value after =
    testing.eq(dev(root, { "d", "--days=7" }, env), "days=7|\n")

    -- Pass the value to a .luau command
    testing.ok(dev(root, { "l", "--days", "7" }, env):find("\t7\n", 1, true))

    -- Pass the value to a subcommand
    testing.eq(dev(root, { "n", "x", "--days=7" }, env), "sh \n")
end)

testing.test("a value that starts with a dash goes after = or as the next word", function()
    -- Make a project whose commands declare a days flag
    local root, env = undeclared_project()

    -- Pass a dash-leading value after =
    testing.eq(dev(root, { "d", "--days=-1" }, env), "days=-1|\n")

    -- Pass a dash-leading value as the next word
    testing.eq(dev(root, { "d", "--days", "-1" }, env), "days=-1|\n")
end)

testing.test("everything after -- reaches the command untouched", function()
    -- Make a project whose commands declare a days flag
    local root, env = undeclared_project()

    -- Pass undeclared words to a .sh command after --
    testing.eq(dev(root, { "s", "--", "--anything", "x" }, env), "sh --anything x\n")

    -- Pass undeclared words to a .luau command after --
    local out = dev(root, { "l", "--", "-q", "--anything" }, env)
    testing.ok(out:find("-q,--anything", 1, true), out)
end)

testing.test("plain words and a lone dash are not flags", function()
    local root, env = undeclared_project()
    testing.eq(dev(root, { "s", "word", "-", "K=v" }, env), "sh word - K=v\n")
end)

testing.test("the verbose flags work in any position", function()
    -- Make a project with a .sh command
    local root, env = undeclared_project()

    -- Trace with -v before the command
    testing.ok(dev(root, { "-v", "s" }, env):find("+ .dev/commands/s.sh", 1, true))

    -- Trace with -v after the command
    testing.ok(dev(root, { "s", "-v" }, env):find("+ .dev/commands/s.sh", 1, true))

    -- Trace with --verbose after the command
    testing.ok(dev(root, { "s", "--verbose" }, env):find("+ .dev/commands/s.sh", 1, true))
end)

testing.test("a command with globals = false takes -v as its own flag", function()
    local root = project({
        ["own.luau"] = luau(
            table.concat({
                '    summary = "Own.",',
                "    globals = false,",
                '    flags = { { name = "verbose", short = "v", kind = "boolean" } },',
            }, "\n"),
            '        print("own", tostring(opts.verbose), ctx.verbose)'
        ),
    })
    testing.eq(dev(root, { "own", "-v" }), "own\ttrue\t0\n")
end)

testing.test("-h after a command is help and never runs the script", function()
    local root, env = undeclared_project()
    local _, code = dev(root, { "s", "-h" }, env)
    testing.eq(code, 0)
    testing.ok(not marked(root), "help ran the script")
end)

testing.test("-h and --help in a later position are help, and never run a command", function()
    -- Make a project with a .sh command
    local root, env = undeclared_project()

    -- Ask for short help after a flag
    local short, code = dev(root, { "s", "--days", "7", "-h" }, env)
    testing.eq(code, 0)
    testing.ok(short:find("usage", 1, true), short)

    -- Ask for long help after a flag
    local _, long_code = dev(root, { "s", "--days", "7", "--help" }, env)
    testing.eq(long_code, 0)

    -- Expect no script to have run
    testing.ok(not marked(root), "help ran the script")
end)

testing.test(
    "-h in a later position is help for a parent command subcommand and a .luau command",
    function()
        -- Make a project with a subcommand and a .luau command
        local root, env = undeclared_project()

        -- Ask for help on the subcommand
        local out, code = dev(root, { "n", "x", "--days=7", "-h" }, env)
        testing.eq(code, 0)
        testing.ok(out:find("dev n x", 1, true), out)

        -- Ask for help on the .luau command
        out, code = dev(root, { "l", "a", "-h" }, env)
        testing.eq(code, 0)
        testing.ok(out:find("dev l", 1, true), out)

        -- Expect no script to have run
        testing.ok(not marked(root), "help ran the script")
    end
)

testing.test("-h after -- still reaches the script", function()
    local root, env = undeclared_project()
    testing.eq(dev(root, { "s", "--", "-h" }, env), "sh -h\n")
    testing.ok(marked(root), "script did not run")
end)

testing.test(
    "a parent command with no subcommand or an unknown one prints its subcommands on stderr",
    function()
        -- Make a project with a parent command
        local root, env = undeclared_project()

        -- Run the parent with no subcommand
        local out, code = dev(root, { "n" }, env)
        testing.eq(code, 2)
        testing.ok(
            out:find(
                table.concat({
                    "dev n: needs a subcommand",
                    "",
                    "",
                }, "\n"),
                1,
                true
            ),
            out
        )
        testing.ok(out:find("subcommands", 1, true), out)

        -- Run the parent with an unknown subcommand
        out, code = dev(root, { "n", "nope" }, env)
        testing.eq(code, 2)
        testing.ok(
            out:find(
                table.concat({
                    "dev n: unknown subcommand nope",
                    "",
                    "",
                }, "\n"),
                1,
                true
            ),
            out
        )

        -- Ask the parent for help after a flag
        out, code = dev(root, { "n", "--days", "-h" }, env)
        testing.eq(code, 0)
        testing.ok(out:find("Run `dev help n <sub>`", 1, true), out)
    end
)

testing.test("--remote after the command word belongs to the command", function()
    local root, env = undeclared_project()
    local out, code = dev(root, { "s", "--remote" }, env)
    testing.eq(code, 2)
    testing.eq(
        out,
        "dev s: Unknown flag --remote" .. REFUSAL .. "usage: dev s [--days] [words...]\n"
    )
end)

testing.test("a project that needs a newer dev is refused", function()
    -- Write a project whose minimum is a far future version
    local config = table.concat({
        "[dev]",
        'min_version = "99.0.0"',
        "",
    }, "\n")
    local root = project({ ["v.luau"] = "@v.luau", ["config.toml"] = config })

    -- Run a command and expect a failure
    local out, code = dev(root, { "v" })
    testing.eq(code, 1)

    -- Expect the message to name the needed and the current version
    local text = "This project needs dev 99.0.0 or newer, and this dev is "
        .. assert(version.current())
        .. "."
    testing.ok(out:find(text, 1, true), out)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a project whose minimum is met or malformed", function()
    -- Write a project whose minimum is the current version
    local met = table.concat({
        "[dev]",
        'min_version = "' .. assert(version.current()) .. '"',
        "",
    }, "\n")
    local root = project({ ["v.luau"] = "@v.luau", ["config.toml"] = met })

    -- Run a command and expect it to run
    local out, code = dev(root, { "v" })
    testing.eq(code, 0)
    testing.ok(out:find("v\ttrue", 1, true), out)

    -- Swap in a project whose minimum is not a version
    fs.remove(root, { recursive = true })
    local malformed = table.concat({
        "[dev]",
        'min_version = "soon"',
        "",
    }, "\n")
    root = project({ ["v.luau"] = "@v.luau", ["config.toml"] = malformed })

    -- Run a command and expect a failure that names the value
    out, code = dev(root, { "v" })
    testing.eq(code, 1)
    testing.ok(
        out:find("The `dev.min_version` setting must be MAJOR.MINOR.PATCH, not soon.", 1, true),
        out
    )

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test(
    "a project command with a requires workspace line is refused in the primary checkout",
    function()
        -- Define a guarded command and an open one in a git checkout run as an implementer
        local root = project({
            ["guarded.luau"] = luau(
                table.concat({
                    '    summary = "Guarded.",',
                    '    requires = { "workspace" },',
                }, "\n"),
                "        print('guarded ran')"
            ),
            ["open.luau"] = luau('    summary = "Open.",', "        print('open ran')"),
        })
        assert(dev_os.run({ "git", "-C", root, "init", "-q" }) == 0, "git init failed")
        local agent = { DEV_AGENT = "repo/implementer/c" }

        -- Refuse the guarded command
        local out, code = dev(root, { "guarded" }, agent)
        testing.eq(code, 2)
        testing.ok(
            out:find(
                "dev guarded: DEV_AGENT is the workspace role implementer, which never runs it in the primary checkout.",
                1,
                true
            ),
            out
        )
        testing.ok(not out:find("guarded ran", 1, true), out)

        -- Run the open command
        out, code = dev(root, { "open" }, agent)
        testing.eq(code, 0)
        testing.ok(out:find("open ran", 1, true), out)

        -- Run the guarded command with no agent
        out, code = dev(root, { "guarded" })
        testing.eq(code, 0)
        testing.ok(out:find("guarded ran", 1, true), out)

        -- Remove the project
        fs.remove(root, { recursive = true })
    end
)

local function words_of(entry)
    return type(entry) == "table" and entry or { entry }
end

testing.test(
    "the built-in commands declare the remote and requires facts they always had",
    function()
        -- Load the built-in registry
        local reg = registry.load(REPO, { warn = function() end }):view(registry.Source.BUILTIN)

        -- Expect these commands to declare they never run remotely
        local never = {
            "fmt",
            "fetch",
            "help",
            "init",
            "push",
            "pull",
            "follow",
            "land",
            "connect",
            { "tools", "check" },
            { "box", "ls" },
            { "ci", "logs" },
            { "board", "status" },
            { "ws", "new" },
        }
        for _, entry in ipairs(never) do
            local words = words_of(entry)
            local remote = reg:declared(words)
            testing.eq({ table.concat(words, " "), remote }, { table.concat(words, " "), false })
        end

        -- Expect these commands to require a workspace
        local guarded = {
            "init",
            "push",
            "pull",
            "follow",
            { "tools", "install" },
        }
        for _, entry in ipairs(guarded) do
            local words = words_of(entry)
            local _, requires = reg:declared(words)
            local name = table.concat(words, " ")
            testing.eq({ name, requires }, { name, { "workspace" } })
        end

        -- Expect these commands to require a workspace and refuse the lead role
        local lead_guarded = { "fmt", "land", "abandon", { "board", "land" } }
        for _, entry in ipairs(lead_guarded) do
            local words = words_of(entry)
            local _, requires = reg:declared(words)
            local name = table.concat(words, " ")
            testing.eq({ name, requires }, { name, { "workspace", "lead" } })
        end

        -- Expect board status to require nothing
        local _, requires = reg:declared({ "board", "status" })
        testing.eq(requires, {})
    end
)

local function stripping_project()
    return project({
        ["p/land.luau"] = luau(
            table.concat({
                '    summary = "Land.",',
                "    globals = false,",
                '    args = { { name = "words", list = true } },',
                "    pass_unknown = true,",
                "",
            }, "\n"),
            '        print("got", table.concat(args.words, ","), ctx.verbose)'
        ),
        ["own.luau"] = luau(
            table.concat({
                '    summary = "Own.",',
                '    flags = { { name = "quick", short = "q", kind = "boolean" } },',
            }, "\n"),
            '        print("own", tostring(opts.quick), ctx.verbose)'
        ),
    })
end

local function without_trace(out)
    -- Start the kept lines
    local kept = {}

    -- Keep each line that is not a trace line
    for line in out:gmatch("[^\n]*\n") do
        if line:sub(1, 2) ~= "+ " then
            kept[#kept + 1] = line
        end
    end

    -- Join the kept lines
    return table.concat(kept)
end

testing.test(
    "a command that opts out of the globals gets every stripped word back in place",
    function()
        -- Make a project with a command that opts out of the globals
        local root = stripping_project()

        -- Put a stripped word back before the subcommand
        testing.eq(dev(root, { "p", "-q", "land" }), "got\t-q\t0\n")

        -- Put every word back after the subcommand
        testing.eq(dev(root, { "p", "land", "a", "-q", "-v", "b" }), "got\ta,-q,-v,b\t0\n")

        -- Put a repeated verbose word back once the trace lines are set aside
        testing.eq(without_trace(dev(root, { "p", "-vv", "land", "a" })), "got\t-vv,a\t0\n")

        -- Remove the project
        fs.remove(root, { recursive = true })
    end
)

testing.test("verbosity words after -- are the command's words, stripped or not", function()
    -- Make a project with a command that opts out of the globals
    local root = stripping_project()

    -- Keep the words after -- untouched
    testing.eq(dev(root, { "p", "land", "a", "--", "-q", "-v" }), "got\ta,-q,-v\t0\n")

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a command that owns only -q keeps it and still counts -v", function()
    -- Make a project with a command that owns -q
    local root = stripping_project()

    -- Count -v beside the owned -q
    testing.eq(dev(root, { "own", "-q", "-v" }), "own\ttrue\t1\n")
    testing.eq(dev(root, { "own", "-v" }), "own\tfalse\t1\n")

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("ctx.args holds the words after the path, argv keeps the dash", function()
    -- Write a command that prints its args, argv and passthrough
    local root = project({
        ["w.luau"] = luau(
            table.concat({
                '    summary = "W.",',
                '    args = { { name = "words", list = true } },',
                "    passthrough = true,",
            }, "\n"),
            '        print("ctx", table.concat(ctx.args, ","), table.concat(ctx.argv, ","), table.concat(ctx.passthrough, ","))'
        ),
    })

    -- Expect the words around -- and the passthrough after it
    testing.eq(dev(root, { "w", "a", "--", "b" }), "ctx\ta,b\ta,--,b\tb\n")

    -- Expect an empty passthrough with no --
    testing.eq(dev(root, { "w", "a" }), "ctx\ta\ta\t\n")

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a usage error prints the usage line drawn from the spec, for a user run", function()
    -- Make a project with a .luau and a .sh command
    local root, env = undeclared_project()

    -- Refuse an unknown flag on the .luau command with its usage line
    local out, code = dev(root, { "l", "--bogus" }, env)
    testing.eq(code, 2)
    testing.ok(out:find("dev l: Unknown flag --bogus", 1, true), out)
    testing.ok(out:find("usage: dev l [--days] [words...]", 1, true), out)

    -- Refuse an unknown flag on the .sh command with its usage line
    out, code = dev(root, { "d", "--bogus" }, env)
    testing.eq(code, 2)
    testing.ok(out:find("usage: dev d [--days]", 1, true), out)
end)
