local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")
local version = require("dev.version")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/dotfiles/bin/.local/share/dev/main.lua"
local FIXTURES = REPO .. "/tests/lua/fixtures/verbs/"

local function project(files)
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev", { parents = true }))
    for name, source in pairs(files) do
        local path = root .. "/.dev/" .. name
        assert(fs.mkdir(fs.dirname(path), { parents = true }))
        local text = source:sub(1, 1) == "@" and assert(fs.read(FIXTURES .. source:sub(2)))
            or source
        assert(fs.write(path, text))
        assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
    end
    return root
end

local function dev(root, args, env)
    local argv = { "luajit", MAIN }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    local merged = { CI = "", DEV_REMOTE = "0" }
    for key, value in pairs(env or {}) do
        merged[key] = value
    end
    return dev_os.capture(argv, { cwd = root, stderr = "stdout", env = merged })
end

testing.test("-vvv gives level 2 and a bare -v after -- stays an argument", function()
    local root = project({ ["v.lua"] = "@v.lua" })
    local out = dev(root, { "-vvv", "v" })
    testing.ok(out:find("v\ttrue\t2", 1, true), out)
    out = dev(root, { "v", "--", "-v" })
    testing.ok(out:find("args\t-v", 1, true), out)
    testing.ok(out:find("v\ttrue\t0", 1, true), out)
end)

testing.test("a .lua verb gets positional args and KEY=value vars", function()
    local out = dev(project({ ["v.lua"] = "@v.lua" }), { "v", "a", "B=1", "--", "--x" })
    testing.ok(out:find("args\ta,--x", 1, true), out)
    testing.ok(out:find("vars\tB=1", 1, true), out)
end)

testing.test(
    "a positional header keeps KEY=value words in args, and other verbs split them",
    function()
        local body = assert(fs.read(FIXTURES .. "v.lua"))
        local root = project({
            ["p.lua"] = "--[[\nShow the arguments.\npositional\n]]\n" .. body,
            ["q.lua"] = "--[[\nShow the arguments.\n]]\n" .. body,
        })
        local out = dev(root, { "p", "Season=1", "a", "B=2" })
        testing.ok(out:find("args\tSeason=1,a,B=2\n", 1, true), out)
        testing.ok(out:find("vars\t\n", 1, true), out)
        out = dev(root, { "q", "Season=1", "a" })
        testing.ok(out:find("args\ta\n", 1, true), out)
        testing.ok(out:find("vars\tSeason=1\n", 1, true), out)
        out = dev(root, { "help", "p" })
        testing.ok(not out:find("positional", 1, true), out)
        fs.remove(root, { recursive = true })
    end
)

testing.test("a .lua verb's integer is the exit code", function()
    local root = project({ ["seven.lua"] = "@seven.lua" })
    local _, code = dev(root, { "seven" })
    testing.eq(code, 7)
end)

testing.test("an error in a .lua verb prints one line and exits 1", function()
    local out, code = dev(project({ ["boom.lua"] = "@boom.lua" }), { "boom" })
    testing.eq(code, 1)
    testing.eq(out, "dev boom: boom\n")
    testing.ok(not out:find("stack traceback", 1, true), out)
end)

testing.test("a syntax error in a .lua verb is handled the same way", function()
    local out, code = dev(project({ ["bad.lua"] = "local = =\n" }), { "bad" })
    testing.eq(code, 1)
    testing.ok(out:find("dev bad: ", 1, true), out)
    testing.ok(not out:find("stack traceback", 1, true), out)
end)

testing.test("a .lua verb beats a .sh verb of the same name", function()
    local out = dev(project({ ["both.lua"] = "@both.lua", ["both.sh"] = "@both.sh" }), { "both" })
    testing.eq(out, "lua ran\n")
end)

testing.test("a .sh verb runs by exec with its arguments", function()
    local root = project({ ["s.sh"] = '#!/usr/bin/env bash\necho "sh $* ${VERBOSE:-unset}"\n' })
    testing.eq(dev(root, { "s", "a", "B=1" }), "sh a B=1 unset\n")
    testing.eq(dev(root, { "-v", "s" }), "+ .dev/s.sh\nsh  1\n")
end)

testing.test("dev run -- -h reaches a verb", function()
    local out = dev(project({ ["run.lua"] = "@run.lua" }), { "run", "--", "-h" })
    testing.eq(out, "run got\t-h\n")
end)

testing.test("a .lua verb finds modules under .dev/lua", function()
    local root = project({ ["helper.lua"] = "@helper.lua" })
    assert(fs.mkdir(root .. "/.dev/lua/tools", { parents = true }))
    assert(
        fs.write(
            root .. "/.dev/lua/tools/shout.lua",
            "return { shout = function(s) return s:upper() end }\n"
        )
    )
    testing.eq(dev(root, { "helper" }), "HI\n")
end)

testing.test("the root gate refuses a verb other than tools install and check", function()
    local root = project({ ["v.lua"] = "@v.lua" })
    local env = {
        LUA_INIT = "@" .. REPO .. "/tests/lua/fake_env.lua",
        FAKE_UID = "0",
        FAKE_OS = "Linux",
    }
    local out, code = dev(root, { "v" }, env)
    testing.eq(code, 2)
    testing.eq(out, "As root, dev runs only `dev tools install` and `dev tools check`.\n")
    env.FAKE_OS = "Darwin"
    out, code = dev(root, { "tools", "check" }, env)
    testing.eq(code, 2)
    testing.eq(out, "As root, dev runs only on Linux.\n")
end)

testing.test(
    "--remote refuses a machine-local verb and an unknown subcommand is a usage error",
    function()
        local root = project({ ["v.lua"] = "@v.lua" })
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

testing.test("a noun runs its subcommand script and refuses a __ helper", function()
    local root = project({
        ["n/x.sh"] = "#!/usr/bin/env bash\necho x ran\n",
        ["n/__h.sh"] = "#!/usr/bin/env bash\necho helper\n",
    })
    testing.eq(dev(root, { "n", "x" }), "x ran\n")
    local out, code = dev(root, { "n", "__h" })
    testing.eq(code, 2)
    testing.ok(out:find("dev n: unknown subcommand __h", 1, true), out)
end)

testing.test("a .lua verb's children see VERBOSE only when it is on", function()
    local root = project({
        ["e.lua"] = 'local o = require("dev.os")\n'
            .. 'io.write(o.capture({ "sh", "-c", \'printf %s "${VERBOSE-unset}"\' }), "|", (...).verbose)\n',
    })
    testing.eq(dev(root, { "e" }, { VERBOSE = "no" }), "unset|0")
    testing.eq(dev(root, { "e" }, { VERBOSE = "0" }), "unset|0")
    local out = dev(root, { "e" }, { VERBOSE = "yes" })
    testing.ok(out:find("1|1", 1, true), out)
end)

testing.test("a .lua verb's exit code is taken modulo 256 like a shell's", function()
    local root = project({
        ["big.lua"] = "return 300\n",
        ["neg.lua"] = "return -1\n",
        ["huge.lua"] = "return 1099511627776\n",
    })
    local _, code = dev(root, { "big" })
    testing.eq(code, 44)
    _, code = dev(root, { "neg" })
    testing.eq(code, 255)
    _, code = dev(root, { "huge" })
    testing.eq(code, 0)
end)

testing.test("a .lua verb that cannot be read is an error", function()
    if dev_os.getuid() == 0 then
        return
    end
    local root = project({ ["locked.lua"] = "return 0\n" })
    assert(dev_os.run({ "chmod", "000", root .. "/.dev/locked.lua" }) == 0, "chmod failed")
    local out, code = dev(root, { "locked" })
    testing.eq(code, 1)
    testing.ok(out:find("dev locked: cannot read ", 1, true), out)
end)

local REFUSAL = ". Pass it after -- to reach the script, or add it to the script's # flags: line.\n"

local function marked(root)
    return fs.is_file(root .. "/marker")
end

local function touching(flags)
    local header = flags and ("# flags: " .. flags .. "\n") or ""
    return "#!/usr/bin/env bash\n# Touch.\n" .. header .. 'touch "$MARKER"\necho "sh $*"\n'
end

local function undeclared_project()
    local root = project({
        ["s.sh"] = touching("--days"),
        ["l.lua"] = '--[[\nTouch.\nflags: --days\n]]\nio.open(os.getenv("MARKER"), "w"):close()\nprint("lua", table.concat((...).args, ","))\n',
        ["n/x.sh"] = touching("--days"),
        ["n/y.lua"] = '--[[\nTouch.\n]]\nio.open(os.getenv("MARKER"), "w"):close()\n',
    })
    return root, { MARKER = root .. "/marker" }
end

testing.test("an undeclared flag is refused before a .sh verb runs", function()
    local root, env = undeclared_project()
    local out, code = dev(root, { "s", "--nope" }, env)
    testing.eq(code, 2)
    testing.eq(out, "dev s: Unknown flag --nope" .. REFUSAL)
    testing.ok(not marked(root), "script ran")
end)

testing.test("an undeclared flag is refused before a .lua verb runs", function()
    local root, env = undeclared_project()
    local out, code = dev(root, { "l", "a", "--nope=1" }, env)
    testing.eq(code, 2)
    testing.eq(out, "dev l: Unknown flag --nope" .. REFUSAL)
    testing.ok(not marked(root), "script ran")
end)

testing.test("an undeclared flag of a noun subcommand names both words", function()
    local root, env = undeclared_project()
    for _, sub in ipairs({ "x", "y" }) do
        local out, code = dev(root, { "n", sub, "-z" }, env)
        testing.eq(code, 2)
        testing.eq(out, "dev n " .. sub .. ": Unknown flag -z" .. REFUSAL)
        testing.ok(not marked(root), "script ran")
    end
end)

testing.test("a declared flag reaches the script, with a separate or an = value", function()
    local root, env = undeclared_project()
    testing.eq(dev(root, { "s", "--days", "7" }, env), "sh --days 7\n")
    testing.eq(dev(root, { "s", "--days=7" }, env), "sh --days=7\n")
    testing.eq(dev(root, { "l", "--days", "7" }, env), "lua\t--days,7\n")
    testing.eq(dev(root, { "n", "x", "--days=7" }, env), "sh --days=7\n")
end)

testing.test("a separate value that starts with a dash is a flag, so it goes after =", function()
    local root, env = undeclared_project()
    local out, code = dev(root, { "s", "--days", "-1" }, env)
    testing.eq(code, 2)
    testing.eq(out, "dev s: Unknown flag -1" .. REFUSAL)
    testing.eq(dev(root, { "s", "--days=-1" }, env), "sh --days=-1\n")
end)

testing.test("everything after -- reaches the script untouched", function()
    local root, env = undeclared_project()
    testing.eq(dev(root, { "s", "--", "--anything", "x" }, env), "sh --anything x\n")
    testing.eq(dev(root, { "l", "--", "-q", "--anything" }, env), "lua\t-q,--anything\n")
end)

testing.test("plain words and a lone dash are not flags", function()
    local root, env = undeclared_project()
    testing.eq(dev(root, { "s", "word", "-", "K=v" }, env), "sh word - K=v\n")
end)

testing.test("the verbose flags work in any position", function()
    local root, env = undeclared_project()
    testing.ok(dev(root, { "-v", "s" }, env):find("+ .dev/s.sh", 1, true))
    testing.ok(dev(root, { "s", "-v" }, env):find("+ .dev/s.sh", 1, true))
    testing.ok(dev(root, { "s", "--verbose" }, env):find("+ .dev/s.sh", 1, true))
end)

testing.test("-h after a verb is help and never runs the script", function()
    local root, env = undeclared_project()
    local _, code = dev(root, { "s", "-h" }, env)
    testing.eq(code, 0)
    testing.ok(not marked(root), "help ran the script")
end)

testing.test("-h and --help in a later position are help, and never run a .sh verb", function()
    local root, env = undeclared_project()
    local short, code = dev(root, { "s", "--days", "7", "-h" }, env)
    testing.eq(code, 0)
    testing.ok(short:find("usage", 1, true), short)
    local long = dev(root, { "s", "--days", "7", "--help" }, env)
    testing.ok(long:find("s.sh header", 1, true), long)
    testing.ok(not marked(root), "help ran the script")
end)

testing.test("-h in a later position is help for a noun subcommand and a .lua verb", function()
    local root, env = undeclared_project()
    local out, code = dev(root, { "n", "x", "--days=7", "-h" }, env)
    testing.eq(code, 0)
    testing.ok(out:find("dev n x", 1, true), out)
    out, code = dev(root, { "l", "a", "-h" }, env)
    testing.eq(code, 0)
    testing.ok(out:find("dev l", 1, true), out)
    testing.ok(not marked(root), "help ran the script")
end)

testing.test("-h after -- still reaches the script", function()
    local root, env = undeclared_project()
    testing.eq(dev(root, { "s", "--", "-h" }, env), "sh -h\n")
    testing.ok(marked(root), "script did not run")
end)

testing.test(
    "a noun with no subcommand or an unknown one prints its subcommands on stderr",
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

testing.test("--remote is never an unknown flag", function()
    local root, env = undeclared_project()
    local out = dev(root, { "s", "--remote" }, env)
    testing.ok(not out:find("Unknown flag", 1, true), out)
end)

testing.test("root-tests and bootstrap-arch are unknown verbs", function()
    for _, name in ipairs({ "root-tests", "bootstrap-arch" }) do
        local out, code = dev_os.capture(
            { REPO .. "/dotfiles/bin/.local/bin/dev", name },
            { cwd = REPO, stderr = "stdout" }
        )
        testing.eq(code, 2)
        testing.ok(out:find("dev: unknown verb " .. name .. "\n", 1, true), out)
    end
end)

testing.test("guard maps an interrupted error to 130 and raises any other", function()
    local cli = require("dev.cli")
    testing.eq(
        cli.guard(function()
            error("luajit: x.lua:1: interrupted!", 0)
        end),
        130
    )
    testing.eq(cli.guard(function() end), nil)
    local ok, err = pcall(cli.guard, function()
        error("boom", 0)
    end)
    testing.ok(not ok and tostring(err):find("boom", 1, true), tostring(err))
end)

testing.test("help for a built-in outside the type verbs runs no project detection", function()
    local root = support.tempdir()
    assert(fs.write(root .. "/Makefile", ""))
    local out = dev(root, { "pull", "--help" })
    testing.ok(out:find("the built-in runs", 1, true), out)
    testing.ok(not out:find(" project)", 1, true), out)
    out = dev(root, { "lint", "--help" })
    testing.ok(out:find("(make project)", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test(
    "dev help over a deep tree returns within its bound and reports no lua project",
    function()
        local bound_secs = 10
        local levels = 8
        local lua_level = 6
        local root = project({})
        local deep = root
        local lua_dir
        for level = 1, levels do
            deep = deep .. "/level" .. level
            if level == lua_level then
                lua_dir = deep
            end
        end
        assert(fs.mkdir(deep, { parents = true }))
        assert(fs.write(lua_dir .. "/below_the_cap.lua", "return {}\n"))
        local out, code = dev_os.capture_timed({ "luajit", MAIN, "help" }, bound_secs, {
            cwd = deep,
            merge = true,
            env = { CI = "", DEV_REMOTE = "0" },
        })
        testing.eq(code, 0)
        testing.ok(out:find("dev: project at", 1, true), out)
        testing.ok(not out:find("lua project at", 1, true), out)
        fs.remove(root, { recursive = true })
    end
)

testing.test("an interrupt while a dev module loads exits 130 with no traceback", function()
    for _, module in ipairs({ "dev.cli", "dev.os" }) do
        local preload =
            string.format('package.preload["%s"] = function() error("interrupted!", 0) end', module)
        local out, code = dev_os.capture(
            { "luajit", "-e", preload, MAIN, "help" },
            { stderr = "stdout", env = { CI = "", DEV_REMOTE = "0" } }
        )
        testing.ok(code == 130, module .. " exited " .. tostring(code))
        testing.ok(out == "", module .. " printed " .. out)
    end
end)

testing.test("a dev module that fails to load for another reason still shows the error", function()
    local preload = 'package.preload["dev.cli"] = function() error("boom", 0) end'
    local out, code = dev_os.capture(
        { "luajit", "-e", preload, MAIN, "help" },
        { stderr = "stdout", env = { CI = "", DEV_REMOTE = "0" } }
    )
    testing.ok(code ~= 0 and code ~= 130, "exited " .. tostring(code))
    testing.ok(out:find("boom", 1, true), out)
end)

testing.test("a project that needs a newer dev is refused", function()
    local root =
        project({ ["v.lua"] = "@v.lua", ["config.toml"] = '[dev]\nmin_version = "99.0.0"\n' })
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
    local root = project({ ["v.lua"] = "@v.lua", ["config.toml"] = met })
    local out, code = dev(root, { "v" })
    testing.eq(code, 0)
    testing.ok(out:find("v\ttrue", 1, true), out)
    fs.remove(root, { recursive = true })
    root = project({ ["v.lua"] = "@v.lua", ["config.toml"] = '[dev]\nmin_version = "soon"\n' })
    out, code = dev(root, { "v" })
    testing.eq(code, 1)
    testing.ok(
        out:find("The `dev.min_version` setting must be MAJOR.MINOR.PATCH, not soon.", 1, true),
        out
    )
    fs.remove(root, { recursive = true })
end)

testing.test("a project Lua verb that is interrupted exits 130 with nothing on stderr", function()
    local root = project({ ["stop.lua"] = 'error("interrupted!", 0)\n' })
    local out, code = dev(root, { "stop" })
    testing.eq(code, 130)
    testing.eq(out, "")
    fs.remove(root, { recursive = true })
end)
