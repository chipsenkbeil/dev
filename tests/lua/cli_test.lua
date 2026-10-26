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
    return devos.capture(argv, { cwd = root, stderr = "stdout", env = env })
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
    local out = dev(project({ ["v.lua"] = "@v.lua" }), { "v", "a", "B=1", "--x" })
    t.ok(out:find("args\ta,--x", 1, true), out)
    t.ok(out:find("vars\tB=1", 1, true), out)
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

t.test("--ci refuses a machine-local verb and an unknown subcommand is a usage error", function()
    local root = project({ ["v.lua"] = "@v.lua" })
    local out, code = dev(root, { "--ci", "fmt" })
    t.eq(code, 2)
    t.ok(out:find("dev fmt: --ci cannot run this verb", 1, true), out)
    out, code = dev(root, { "tools", "zap" })
    t.eq(code, 2)
    t.ok(out:find("dev tools: unknown subcommand zap", 1, true), out)
end)

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
