local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
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
        assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
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
    return devos.capture(argv, { cwd = root, stderr = "stdout", env = merged })
end

t.test("-vvv gives level 2 and a bare -v after -- stays an argument", function()
    local root = project({ ["v.lua"] = "@v.lua" })
    local out = dev(root, { "-vvv", "v" })
    t.ok(out:find("v\ttrue\t2", 1, true), out)
    out = dev(root, { "v", "--", "-v" })
    t.ok(out:find("args\t-v", 1, true), out)
    t.ok(out:find("v\ttrue\t0", 1, true), out)
end)

t.test("a .lua verb gets positional args and KEY=value vars", function()
    local out = dev(project({ ["v.lua"] = "@v.lua" }), { "v", "a", "B=1", "--", "--x" })
    t.ok(out:find("args\ta,--x", 1, true), out)
    t.ok(out:find("vars\tB=1", 1, true), out)
end)

t.test("a positional header keeps KEY=value words in args, and other verbs split them", function()
    local body = assert(fs.read(FIXTURES .. "v.lua"))
    local root = project({
        ["p.lua"] = "--[[\nShow the arguments.\npositional\n]]\n" .. body,
        ["q.lua"] = "--[[\nShow the arguments.\n]]\n" .. body,
    })
    local out = dev(root, { "p", "Season=1", "a", "B=2" })
    t.ok(out:find("args\tSeason=1,a,B=2\n", 1, true), out)
    t.ok(out:find("vars\t\n", 1, true), out)
    out = dev(root, { "q", "Season=1", "a" })
    t.ok(out:find("args\ta\n", 1, true), out)
    t.ok(out:find("vars\tSeason=1\n", 1, true), out)
    out = dev(root, { "help", "p" })
    t.ok(not out:find("positional", 1, true), out)
    fs.remove(root, { recursive = true })
end)

t.test("a .lua verb's integer is the exit code", function()
    local root = project({ ["seven.lua"] = "@seven.lua" })
    local _, code = dev(root, { "seven" })
    t.eq(code, 7)
end)

t.test("an error in a .lua verb prints one line and exits 1", function()
    local out, code = dev(project({ ["boom.lua"] = "@boom.lua" }), { "boom" })
    t.eq(code, 1)
    t.eq(out, "dev boom: boom\n")
    t.ok(not out:find("stack traceback", 1, true), out)
end)

t.test("a syntax error in a .lua verb is handled the same way", function()
    local out, code = dev(project({ ["bad.lua"] = "local = =\n" }), { "bad" })
    t.eq(code, 1)
    t.ok(out:find("dev bad: ", 1, true), out)
    t.ok(not out:find("stack traceback", 1, true), out)
end)

t.test("a .lua verb beats a .sh verb of the same name", function()
    local out = dev(project({ ["both.lua"] = "@both.lua", ["both.sh"] = "@both.sh" }), { "both" })
    t.eq(out, "lua ran\n")
end)

t.test("a .sh verb runs by exec with its arguments", function()
    local root = project({ ["s.sh"] = '#!/usr/bin/env bash\necho "sh $* ${VERBOSE:-unset}"\n' })
    t.eq(dev(root, { "s", "a", "B=1" }), "sh a B=1 unset\n")
    t.eq(dev(root, { "-v", "s" }), "+ .dev/s.sh\nsh  1\n")
end)

t.test("dev run -- -h reaches a verb", function()
    local out = dev(project({ ["run.lua"] = "@run.lua" }), { "run", "--", "-h" })
    t.eq(out, "run got\t-h\n")
end)

t.test("a .lua verb finds modules under .dev/lua", function()
    local root = project({ ["helper.lua"] = "@helper.lua" })
    assert(fs.mkdir(root .. "/.dev/lua/tools", { parents = true }))
    assert(
        fs.write(
            root .. "/.dev/lua/tools/shout.lua",
            "return { shout = function(s) return s:upper() end }\n"
        )
    )
    t.eq(dev(root, { "helper" }), "HI\n")
end)

t.test("the root gate refuses a verb other than tools install and check", function()
    local root = project({ ["v.lua"] = "@v.lua" })
    local env = {
        LUA_INIT = "@" .. REPO .. "/tests/lua/fake_env.lua",
        FAKE_UID = "0",
        FAKE_OS = "Linux",
    }
    local out, code = dev(root, { "v" }, env)
    t.eq(code, 2)
    t.eq(out, "dev: as root, dev runs only tools install and tools check\n")
    env.FAKE_OS = "Darwin"
    out, code = dev(root, { "tools", "check" }, env)
    t.eq(code, 2)
    t.eq(out, "dev: as root, dev runs only on Linux\n")
end)

t.test(
    "--remote refuses a machine-local verb and an unknown subcommand is a usage error",
    function()
        local root = project({ ["v.lua"] = "@v.lua" })
        local out, code = dev(root, { "--remote", "fmt" })
        t.eq(code, 2)
        t.ok(
            out:find("dev fmt: runs on this machine only, so --remote does not apply", 1, true),
            out
        )
        out, code = dev(root, { "tools", "zap" })
        t.eq(code, 2)
        t.ok(out:find("dev tools: unknown subcommand zap", 1, true), out)
    end
)

t.test("a noun runs its subcommand script and refuses a __ helper", function()
    local root = project({
        ["n/x.sh"] = "#!/usr/bin/env bash\necho x ran\n",
        ["n/__h.sh"] = "#!/usr/bin/env bash\necho helper\n",
    })
    t.eq(dev(root, { "n", "x" }), "x ran\n")
    local out, code = dev(root, { "n", "__h" })
    t.eq(code, 2)
    t.ok(out:find("dev n: unknown subcommand __h", 1, true), out)
end)

t.test("a .lua verb's children see VERBOSE only when it is on", function()
    local root = project({
        ["e.lua"] = 'local o = require("dev.os")\n'
            .. 'io.write(o.capture({ "sh", "-c", \'printf %s "${VERBOSE-unset}"\' }), "|", (...).verbose)\n',
    })
    t.eq(dev(root, { "e" }, { VERBOSE = "no" }), "unset|0")
    t.eq(dev(root, { "e" }, { VERBOSE = "0" }), "unset|0")
    local out = dev(root, { "e" }, { VERBOSE = "yes" })
    t.ok(out:find("1|1", 1, true), out)
end)

t.test("a .lua verb's exit code is taken modulo 256 like a shell's", function()
    local root = project({
        ["big.lua"] = "return 300\n",
        ["neg.lua"] = "return -1\n",
        ["huge.lua"] = "return 1099511627776\n",
    })
    local _, code = dev(root, { "big" })
    t.eq(code, 44)
    _, code = dev(root, { "neg" })
    t.eq(code, 255)
    _, code = dev(root, { "huge" })
    t.eq(code, 0)
end)

t.test("a .lua verb that cannot be read is an error", function()
    if devos.getuid() == 0 then
        return
    end
    local root = project({ ["locked.lua"] = "return 0\n" })
    assert(devos.run({ "chmod", "000", root .. "/.dev/locked.lua" }) == 0, "chmod failed")
    local out, code = dev(root, { "locked" })
    t.eq(code, 1)
    t.ok(out:find("dev locked: cannot read ", 1, true), out)
end)

local REFUSAL = "; pass it after -- to reach the script, or add it to the script's # flags: line\n"

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

t.test("an undeclared flag is refused before a .sh verb runs", function()
    local root, env = undeclared_project()
    local out, code = dev(root, { "s", "--nope" }, env)
    t.eq(code, 2)
    t.eq(out, "dev s: unknown flag --nope" .. REFUSAL)
    t.ok(not marked(root), "script ran")
end)

t.test("an undeclared flag is refused before a .lua verb runs", function()
    local root, env = undeclared_project()
    local out, code = dev(root, { "l", "a", "--nope=1" }, env)
    t.eq(code, 2)
    t.eq(out, "dev l: unknown flag --nope" .. REFUSAL)
    t.ok(not marked(root), "script ran")
end)

t.test("an undeclared flag of a noun subcommand names both words", function()
    local root, env = undeclared_project()
    for _, sub in ipairs({ "x", "y" }) do
        local out, code = dev(root, { "n", sub, "-z" }, env)
        t.eq(code, 2)
        t.eq(out, "dev n " .. sub .. ": unknown flag -z" .. REFUSAL)
        t.ok(not marked(root), "script ran")
    end
end)

t.test("a declared flag reaches the script, with a separate or an = value", function()
    local root, env = undeclared_project()
    t.eq(dev(root, { "s", "--days", "7" }, env), "sh --days 7\n")
    t.eq(dev(root, { "s", "--days=7" }, env), "sh --days=7\n")
    t.eq(dev(root, { "l", "--days", "7" }, env), "lua\t--days,7\n")
    t.eq(dev(root, { "n", "x", "--days=7" }, env), "sh --days=7\n")
end)

t.test("a separate value that starts with a dash is a flag, so it goes after =", function()
    local root, env = undeclared_project()
    local out, code = dev(root, { "s", "--days", "-1" }, env)
    t.eq(code, 2)
    t.eq(out, "dev s: unknown flag -1" .. REFUSAL)
    t.eq(dev(root, { "s", "--days=-1" }, env), "sh --days=-1\n")
end)

t.test("everything after -- reaches the script untouched", function()
    local root, env = undeclared_project()
    t.eq(dev(root, { "s", "--", "--anything", "x" }, env), "sh --anything x\n")
    t.eq(dev(root, { "l", "--", "-q", "--anything" }, env), "lua\t-q,--anything\n")
end)

t.test("plain words and a lone dash are not flags", function()
    local root, env = undeclared_project()
    t.eq(dev(root, { "s", "word", "-", "K=v" }, env), "sh word - K=v\n")
end)

t.test("the verbose flags work in any position", function()
    local root, env = undeclared_project()
    t.ok(dev(root, { "-v", "s" }, env):find("+ .dev/s.sh", 1, true))
    t.ok(dev(root, { "s", "-v" }, env):find("+ .dev/s.sh", 1, true))
    t.ok(dev(root, { "s", "--verbose" }, env):find("+ .dev/s.sh", 1, true))
end)

t.test("-h after a verb is help and never runs the script", function()
    local root, env = undeclared_project()
    local _, code = dev(root, { "s", "-h" }, env)
    t.eq(code, 0)
    t.ok(not marked(root), "help ran the script")
end)

t.test("-h and --help in a later position are help, and never run a .sh verb", function()
    local root, env = undeclared_project()
    local short, code = dev(root, { "s", "--days", "7", "-h" }, env)
    t.eq(code, 0)
    t.ok(short:find("usage", 1, true), short)
    local long = dev(root, { "s", "--days", "7", "--help" }, env)
    t.ok(long:find("s.sh header", 1, true), long)
    t.ok(not marked(root), "help ran the script")
end)

t.test("-h in a later position is help for a noun subcommand and a .lua verb", function()
    local root, env = undeclared_project()
    local out, code = dev(root, { "n", "x", "--days=7", "-h" }, env)
    t.eq(code, 0)
    t.ok(out:find("dev n x", 1, true), out)
    out, code = dev(root, { "l", "a", "-h" }, env)
    t.eq(code, 0)
    t.ok(out:find("dev l", 1, true), out)
    t.ok(not marked(root), "help ran the script")
end)

t.test("-h after -- still reaches the script", function()
    local root, env = undeclared_project()
    t.eq(dev(root, { "s", "--", "-h" }, env), "sh -h\n")
    t.ok(marked(root), "script did not run")
end)

t.test("a noun with no subcommand or an unknown one prints its subcommands on stderr", function()
    local root, env = undeclared_project()
    local out, code = dev(root, { "n" }, env)
    t.eq(code, 2)
    t.ok(out:find("dev n: needs a subcommand\n\n", 1, true), out)
    t.ok(out:find("subcommands", 1, true), out)
    out, code = dev(root, { "n", "nope" }, env)
    t.eq(code, 2)
    t.ok(out:find("dev n: unknown subcommand nope\n\n", 1, true), out)
    out, code = dev(root, { "n", "--days", "-h" }, env)
    t.eq(code, 0)
    t.ok(out:find("Run `dev help n <sub>`", 1, true), out)
end)

t.test("--remote is never an unknown flag", function()
    local root, env = undeclared_project()
    local out = dev(root, { "s", "--remote" }, env)
    t.ok(not out:find("unknown flag", 1, true), out)
end)

t.test("root-tests and bootstrap-arch are unknown verbs", function()
    for _, name in ipairs({ "root-tests", "bootstrap-arch" }) do
        local out, code = devos.capture(
            { REPO .. "/dotfiles/bin/.local/bin/dev", name },
            { cwd = REPO, stderr = "stdout" }
        )
        t.eq(code, 2)
        t.ok(out:find("dev: unknown verb " .. name .. "\n", 1, true), out)
    end
end)

t.test("guard maps an interrupted error to 130 and raises any other", function()
    local cli = require("dev.cli")
    t.eq(
        cli.guard(function()
            error("luajit: x.lua:1: interrupted!", 0)
        end),
        130
    )
    t.eq(cli.guard(function() end), nil)
    local ok, err = pcall(cli.guard, function()
        error("boom", 0)
    end)
    t.ok(not ok and tostring(err):find("boom", 1, true), tostring(err))
end)

t.test("help for a built-in outside the type verbs runs no project detection", function()
    local root = support.tempdir()
    assert(fs.write(root .. "/Makefile", ""))
    local out = dev(root, { "pull", "--help" })
    t.ok(out:find("the built-in runs", 1, true), out)
    t.ok(not out:find(" project)", 1, true), out)
    out = dev(root, { "lint", "--help" })
    t.ok(out:find("(make project)", 1, true), out)
    fs.remove(root, { recursive = true })
end)

t.test("a project Lua verb that is interrupted exits 130 with nothing on stderr", function()
    local root = project({ ["stop.lua"] = 'error("interrupted!", 0)\n' })
    local out, code = dev(root, { "stop" })
    t.eq(code, 130)
    t.eq(out, "")
    fs.remove(root, { recursive = true })
end)
