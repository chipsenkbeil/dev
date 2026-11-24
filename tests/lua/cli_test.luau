local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local registry = require("dev.registry")
local support = require("support")
local version = require("dev.version")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local FIXTURES = REPO .. "/tests/lua/fixtures/commands/"

local OUTSIDE_COMMANDS = { ["config.toml"] = true }

local function project(files)
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev", { parents = true }))
    for name, source in pairs(files) do
        local inside = OUTSIDE_COMMANDS[name] or name:find("^helpers/") or name:find("^lib/")
        local path = root .. "/.dev/" .. (inside and "" or "commands/") .. name
        assert(fs.mkdir(fs.dirname(path), { parents = true }))
        local text = source:sub(1, 1) == "@" and assert(fs.read(FIXTURES .. source:sub(2)))
            or source
        assert(fs.write(path, text))
        assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
    end
    return root
end

local function luau(spec_body, run_body)
    return 'local dev_command = require("dev.command")\n'
        .. "return dev_command({\n"
        .. spec_body
        .. "\n    run = function(opts, args, ctx)\n"
        .. run_body
        .. "\n    end,\n})\n"
end

local function dev(root, args, env)
    local argv = { support.DEV }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    local merged = { CI = "", DEV_REMOTE = "0", XDG_CONFIG_HOME = support.tempdir() }
    for key, value in pairs(env or {}) do
        merged[key] = value
    end
    return dev_os.capture(argv, { cwd = root, stderr = "stdout", env = merged })
end

testing.test("-vv gives level 2 and a bare -v after -- stays an argument", function()
    local root = project({ ["v.luau"] = "@v.luau" })
    local out = dev(root, { "-vv", "v" })
    testing.ok(out:find("v\ttrue\t2", 1, true), out)
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
        local body = assert(fs.read(FIXTURES .. "v.luau"))
        local root = project({
            ["p.luau"] = body:gsub(
                "summary = ([^\n]*)\n",
                "summary = %1\n    positional = true,\n",
                1
            ),
            ["q.luau"] = body,
        })
        local out = dev(root, { "p", "Season=1", "a", "B=2" })
        testing.ok(out:find("args\tSeason=1,a,B=2\n", 1, true), out)
        testing.ok(out:find("vars\t\n", 1, true), out)
        out = dev(root, { "q", "Season=1", "a" })
        testing.ok(out:find("args\ta\n", 1, true), out)
        testing.ok(out:find("vars\tSeason=1\n", 1, true), out)
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
    testing.eq(out, "dev boom: boom\n")
    testing.ok(not out:find("stack traceback", 1, true), out)
end)

testing.test("a syntax error in a .luau command is handled the same way", function()
    local out, code = dev(project({ ["bad.luau"] = "local = =\n" }), { "bad" })
    testing.eq(code, 1)
    testing.ok(out:find("dev bad: ", 1, true), out)
    testing.ok(not out:find("stack traceback", 1, true), out)
end)

testing.test("a .luau command beats a .sh command of the same name", function()
    local out = dev(project({ ["both.luau"] = "@both.luau", ["both.sh"] = "@both.sh" }), { "both" })
    testing.eq(out, "luau ran\n")
end)

testing.test("a .sh command runs by exec with its arguments", function()
    local root = project({ ["s.sh"] = '#!/usr/bin/env bash\necho "sh $* ${VERBOSE:-unset}"\n' })
    testing.eq(dev(root, { "s", "a", "B=1" }), "sh a B=1 unset\n")
    testing.eq(dev(root, { "-v", "s" }), "+ .dev/commands/s.sh\nsh  1\n")
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

testing.test("a global .luau command requires from the global lib folder", function()
    local config = support.tempdir()
    assert(fs.mkdir(config .. "/dev/lib/tools", { parents = true }))
    assert(
        fs.write(
            config .. "/dev/lib/tools/shout.luau",
            "return { shout = function(s) return s:upper() end }\n"
        )
    )
    assert(fs.mkdir(config .. "/dev/commands", { parents = true }))
    assert(
        fs.write(config .. "/dev/commands/helper.luau", assert(fs.read(FIXTURES .. "helper.luau")))
    )
    local root = project({})
    local env = { XDG_CONFIG_HOME = config }
    testing.eq(dev(root, { "helper" }, env), "HI\n")
end)

local function dev_as(root, args, env)
    local words = { "-l", REPO .. "/tests/dev/fixtures/fake_root.luau" }
    for _, word in ipairs(args) do
        words[#words + 1] = word
    end
    return dev(root, words, env)
end

testing.test("the root gate refuses a command other than tools install and check", function()
    local root = project({ ["v.luau"] = "@v.luau" })
    local env = { FAKE_UID = "0", FAKE_OS = "Linux" }
    local out, code = dev_as(root, { "v" }, env)
    testing.eq(code, 2)
    testing.eq(out, "As root, dev runs only `dev tools install` and `dev tools check`.\n")
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
        local root = project({ ["v.luau"] = "@v.luau" })
        local out, code = dev(root, { "--remote", "fmt" })
        testing.eq(code, 2)
        testing.ok(
            out:find("dev fmt: runs on this machine only, so --remote does not apply", 1, true),
            out
        )
        out, code = dev(root, { "tools", "zap" })
        testing.eq(code, 2)
        testing.ok(out:find("dev tools: unknown subcommand zap", 1, true), out)
    end
)

testing.test("a parent command runs its subcommand and lists a hidden one only in help", function()
    local root = project({
        ["n/x.sh"] = "#!/usr/bin/env bash\necho x ran\n",
        ["n/h.sh"] = "#!/usr/bin/env bash\n# Helper.\n# hidden\necho helper\n",
    })
    testing.eq(dev(root, { "n", "x" }), "x ran\n")
    testing.eq(dev(root, { "n", "h" }), "helper\n")
    local out, code = dev(root, { "n" })
    testing.eq(code, 2)
    testing.ok(out:find("subcommands\n  x", 1, true), out)
    testing.ok(not out:find("  h", 1, true), out)
end)

testing.test("a .luau command's children see VERBOSE only when it is on", function()
    local root = project({
        ["e.luau"] = luau(
            '    summary = "Show VERBOSE.",',
            '        local seen = require("dev.os").capture({ "sh", "-c", \'printf %s "${VERBOSE-unset}"\' })\n'
                .. '        require("dev.os").stdout:write(seen, "|", tostring(ctx.verbose))'
        ),
    })
    testing.eq(dev(root, { "e" }, { VERBOSE = "no" }), "unset|0")
    testing.eq(dev(root, { "e" }, { VERBOSE = "0" }), "unset|0")
    local out = dev(root, { "e" }, { VERBOSE = "yes" })
    testing.ok(out:find("1|1", 1, true), out)
end)

testing.test("a .luau command's exit code is taken modulo 256 like a shell's", function()
    local root = project({
        ["big.luau"] = luau('    summary = "Big.",', "        return 300"),
        ["neg.luau"] = luau('    summary = "Neg.",', "        return -1"),
        ["huge.luau"] = luau('    summary = "Huge.",', "        return 1099511627776"),
    })
    local _, code = dev(root, { "big" })
    testing.eq(code, 44)
    _, code = dev(root, { "neg" })
    testing.eq(code, 255)
    _, code = dev(root, { "huge" })
    testing.eq(code, 0)
end)

testing.test("a .luau command that cannot be read is an error", function()
    if dev_os.getuid() == 0 then
        return
    end
    local root = project({ ["locked.luau"] = "return 0\n" })
    assert(
        dev_os.run({ "chmod", "000", root .. "/.dev/commands/locked.luau" }) == 0,
        "chmod failed"
    )
    local out, code = dev(root, { "locked" })
    testing.eq(code, 1)
    testing.ok(out:find("dev locked: cannot read ", 1, true), out)
end)

local function echoing(text)
    return table.concat({ "#!/usr/bin/env bash", "echo " .. text, "" }, "\n")
end

local function overriding_global()
    local config = support.tempdir()
    local commands = config .. "/dev/commands"
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
    return { XDG_CONFIG_HOME = config }
end

testing.test("builtin:init runs the built-in under a global init", function()
    local env = overriding_global()
    local root = project({})
    testing.eq(dev(root, { "init" }, env), "global init ran\n")
    local out, code = dev(root, { "builtin:init", "-h" }, env)
    testing.eq(code, 0)
    testing.ok(out:find("Set up a project's version control and remotes", 1, true), out)
    testing.ok(not out:find("global init ran", 1, true), out)
end)

testing.test("builtin:board ls reaches the built-in subcommand under an override", function()
    local env = overriding_global()
    local root = project({})
    testing.eq(dev(root, { "board", "ls" }, env), "global ls ran\n")
    local out, code = dev(root, { "builtin:board", "ls", "-h" }, env)
    testing.eq(code, 0)
    testing.ok(out:find("List the cards of the board", 1, true), out)
end)

testing.test("global:shared answers from the global folder and skips the project script", function()
    local env = overriding_global()
    local root = project({ ["shared.sh"] = echoing("project shared ran") })
    testing.eq(dev(root, { "shared" }, env), "project shared ran\n")
    testing.eq(dev(root, { "global:shared" }, env), "global shared ran\n")
    testing.eq(dev(root, { "global:board", "ls" }, env), "global ls ran\n")
end)

testing.test("an unknown source is a usage error naming it", function()
    local env = overriding_global()
    local root = project({})
    local out, code = dev(root, { "project:lint" }, env)
    testing.eq(code, 2)
    testing.eq(out, "The source project is not builtin or global.\n")
    out, code = dev(root, { "builtin:nope" }, env)
    testing.eq(code, 2)
    testing.eq(out, "The built-in commands have no command nope.\n")
    out, code = dev(root, { "global:lint" }, env)
    testing.eq(code, 2)
    testing.eq(out, "The global commands have no command lint.\n")
end)

local REFUSAL = ". Pass it after -- to reach the command.\n"

local function marked(root)
    return fs.is_file(root .. "/marker")
end

local function touching(flag)
    local header = flag and ("# flag: " .. flag .. " -- A count\n") or ""
    return "#!/usr/bin/env bash\n# Touch.\n"
        .. header
        .. "# passthrough\n"
        .. "# arg: words list\n"
        .. 'touch "$MARKER"\necho "sh $*"\n'
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
            '    summary = "Touch.",\n    flags = { { name = "days" } },\n    args = { { name = "words", list = true } },\n    passthrough = true,',
            '        require("dev.fs").write(require("dev.os").getenv("MARKER"), "")\n'
                .. '        print("luau", table.concat(args.words, ","), table.concat(ctx.passthrough or {}, ","), opts.days)'
        ),
        ["n/x.sh"] = touching("days"),
        ["n/y.luau"] = luau(
            '    summary = "Touch.",',
            '        require("dev.fs").write(require("dev.os").getenv("MARKER"), "")'
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
    local root, env = undeclared_project()
    testing.eq(dev(root, { "d", "--days", "7" }, env), "days=7|\n")
    testing.eq(dev(root, { "d", "--days=7" }, env), "days=7|\n")
    testing.ok(dev(root, { "l", "--days", "7" }, env):find("\t7\n", 1, true))
    testing.eq(dev(root, { "n", "x", "--days=7" }, env), "sh \n")
end)

testing.test("a value that starts with a dash goes after = or as the next word", function()
    local root, env = undeclared_project()
    testing.eq(dev(root, { "d", "--days=-1" }, env), "days=-1|\n")
    testing.eq(dev(root, { "d", "--days", "-1" }, env), "days=-1|\n")
end)

testing.test("everything after -- reaches the command untouched", function()
    local root, env = undeclared_project()
    testing.eq(dev(root, { "s", "--", "--anything", "x" }, env), "sh --anything x\n")
    local out = dev(root, { "l", "--", "-q", "--anything" }, env)
    testing.ok(out:find("-q,--anything", 1, true), out)
end)

testing.test("plain words and a lone dash are not flags", function()
    local root, env = undeclared_project()
    testing.eq(dev(root, { "s", "word", "-", "K=v" }, env), "sh word - K=v\n")
end)

testing.test("the verbose flags work in any position", function()
    local root, env = undeclared_project()
    testing.ok(dev(root, { "-v", "s" }, env):find("+ .dev/commands/s.sh", 1, true))
    testing.ok(dev(root, { "s", "-v" }, env):find("+ .dev/commands/s.sh", 1, true))
    testing.ok(dev(root, { "s", "--verbose" }, env):find("+ .dev/commands/s.sh", 1, true))
end)

testing.test("a command with globals = false takes -v as its own flag", function()
    local root = project({
        ["own.luau"] = luau(
            '    summary = "Own.",\n    globals = false,\n    flags = { { name = "verbose", short = "v", kind = "boolean" } },',
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
    local root, env = undeclared_project()
    local short, code = dev(root, { "s", "--days", "7", "-h" }, env)
    testing.eq(code, 0)
    testing.ok(short:find("usage", 1, true), short)
    local _, long_code = dev(root, { "s", "--days", "7", "--help" }, env)
    testing.eq(long_code, 0)
    testing.ok(not marked(root), "help ran the script")
end)

testing.test(
    "-h in a later position is help for a parent command subcommand and a .luau command",
    function()
        local root, env = undeclared_project()
        local out, code = dev(root, { "n", "x", "--days=7", "-h" }, env)
        testing.eq(code, 0)
        testing.ok(out:find("dev n x", 1, true), out)
        out, code = dev(root, { "l", "a", "-h" }, env)
        testing.eq(code, 0)
        testing.ok(out:find("dev l", 1, true), out)
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
        local root, env = undeclared_project()
        local out, code = dev(root, { "n" }, env)
        testing.eq(code, 2)
        testing.ok(out:find("dev n: needs a subcommand\n\n", 1, true), out)
        testing.ok(out:find("subcommands", 1, true), out)
        out, code = dev(root, { "n", "nope" }, env)
        testing.eq(code, 2)
        testing.ok(out:find("dev n: unknown subcommand nope\n\n", 1, true), out)
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
    local root =
        project({ ["v.luau"] = "@v.luau", ["config.toml"] = '[dev]\nmin_version = "99.0.0"\n' })
    local out, code = dev(root, { "v" })
    testing.eq(code, 1)
    local text = "This project needs dev 99.0.0 or newer, and this dev is "
        .. assert(version.current())
        .. "."
    testing.ok(out:find(text, 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("a project whose minimum is met or malformed", function()
    local met = '[dev]\nmin_version = "' .. assert(version.current()) .. '"\n'
    local root = project({ ["v.luau"] = "@v.luau", ["config.toml"] = met })
    local out, code = dev(root, { "v" })
    testing.eq(code, 0)
    testing.ok(out:find("v\ttrue", 1, true), out)
    fs.remove(root, { recursive = true })
    root = project({ ["v.luau"] = "@v.luau", ["config.toml"] = '[dev]\nmin_version = "soon"\n' })
    out, code = dev(root, { "v" })
    testing.eq(code, 1)
    testing.ok(
        out:find("The `dev.min_version` setting must be MAJOR.MINOR.PATCH, not soon.", 1, true),
        out
    )
    fs.remove(root, { recursive = true })
end)

testing.test(
    "a project command with a requires workspace line is refused in the primary checkout",
    function()
        local root = project({
            ["guarded.luau"] = luau(
                '    summary = "Guarded.",\n    requires = { "workspace" },',
                "        print('guarded ran')"
            ),
            ["open.luau"] = luau('    summary = "Open.",', "        print('open ran')"),
        })
        assert(dev_os.run({ "git", "-C", root, "init", "-q" }) == 0, "git init failed")
        local agent = { DEV_AGENT = "repo/implementer/c" }
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
        out, code = dev(root, { "open" }, agent)
        testing.eq(code, 0)
        testing.ok(out:find("open ran", 1, true), out)
        out, code = dev(root, { "guarded" })
        testing.eq(code, 0)
        testing.ok(out:find("guarded ran", 1, true), out)
        fs.remove(root, { recursive = true })
    end
)

local function words_of(entry)
    return type(entry) == "table" and entry or { entry }
end

testing.test(
    "the built-in commands declare the remote and requires facts they always had",
    function()
        local reg = registry.load(REPO, { warn = function() end }):view(registry.Source.BUILTIN)
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
        local guarded = {
            "fmt",
            "init",
            "push",
            "pull",
            "follow",
            "land",
            "abandon",
            { "tools", "install" },
            { "board", "land" },
        }
        for _, entry in ipairs(guarded) do
            local words = words_of(entry)
            local _, requires = reg:declared(words)
            local name = table.concat(words, " ")
            testing.eq({ name, requires }, { name, { "workspace" } })
        end
        local _, requires = reg:declared({ "board", "status" })
        testing.eq(requires, {})
    end
)

local function stripping_project()
    local words = '    args = { { name = "words", list = true } },\n    pass_unknown = true,\n'
    return project({
        ["p/land.luau"] = luau(
            '    summary = "Land.",\n    globals = false,\n' .. words,
            '        print("got", table.concat(args.words, ","), ctx.verbose)'
        ),
        ["own.luau"] = luau(
            '    summary = "Own.",\n    flags = { { name = "quick", short = "q", kind = "boolean" } },',
            '        print("own", tostring(opts.quick), ctx.verbose)'
        ),
    })
end

local function without_trace(out)
    local kept = {}
    for line in out:gmatch("[^\n]*\n") do
        if line:sub(1, 2) ~= "+ " then
            kept[#kept + 1] = line
        end
    end
    return table.concat(kept)
end

testing.test(
    "a command that opts out of the globals gets every stripped word back in place",
    function()
        local root = stripping_project()
        testing.eq(dev(root, { "p", "-q", "land" }), "got\t-q\t0\n")
        testing.eq(dev(root, { "p", "land", "a", "-q", "-v", "b" }), "got\ta,-q,-v,b\t0\n")
        testing.eq(without_trace(dev(root, { "p", "-vv", "land", "a" })), "got\t-vv,a\t0\n")
        fs.remove(root, { recursive = true })
    end
)

testing.test("verbosity words after -- are the command's words, stripped or not", function()
    local root = stripping_project()
    testing.eq(dev(root, { "p", "land", "a", "--", "-q", "-v" }), "got\ta,-q,-v\t0\n")
    fs.remove(root, { recursive = true })
end)

testing.test("a command that owns only -q keeps it and still counts -v", function()
    local root = stripping_project()
    testing.eq(dev(root, { "own", "-q", "-v" }), "own\ttrue\t1\n")
    testing.eq(dev(root, { "own", "-v" }), "own\tfalse\t1\n")
    fs.remove(root, { recursive = true })
end)

testing.test("ctx.args holds the words after the path, argv keeps the dash", function()
    local root = project({
        ["w.luau"] = luau(
            '    summary = "W.",\n    args = { { name = "words", list = true } },\n    passthrough = true,',
            '        print("ctx", table.concat(ctx.args, ","), table.concat(ctx.argv, ","), table.concat(ctx.passthrough, ","))'
        ),
    })
    testing.eq(dev(root, { "w", "a", "--", "b" }), "ctx\ta,b\ta,--,b\tb\n")
    testing.eq(dev(root, { "w", "a" }), "ctx\ta\ta\t\n")
    fs.remove(root, { recursive = true })
end)

testing.test("a usage error prints the usage line drawn from the spec, for a user run", function()
    local root, env = undeclared_project()
    local out, code = dev(root, { "l", "--bogus" }, env)
    testing.eq(code, 2)
    testing.ok(out:find("dev l: Unknown flag --bogus", 1, true), out)
    testing.ok(out:find("usage: dev l [--days] [words...]", 1, true), out)
    out, code = dev(root, { "d", "--bogus" }, env)
    testing.eq(code, 2)
    testing.ok(out:find("usage: dev d [--days]", 1, true), out)
end)
