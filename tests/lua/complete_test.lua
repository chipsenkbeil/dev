local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/dotfiles/bin/.local/share/dev/main.lua"
local SELF = REPO .. "/dotfiles/bin/.local/bin/dev"
local GLOBAL_TAIL = "-v\n--verbose\n-vv\n--remote\n--detach\n"

local function project(files)
    local root = support.tempdir()
    for name, source in pairs(files) do
        local path = root .. "/.dev/" .. name
        assert(fs.mkdir(fs.dirname(path), { parents = true }))
        assert(fs.write(path, source))
        if name:find("%.sh$") then
            assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
        end
    end
    return root
end

local function dev(root, args)
    local argv = { "luajit", MAIN }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    return devos.capture(argv, { cwd = root, stderr = "null", env = { DEV_SELF = SELF } })
end

t.test("__verbs lists a .lua project verb as local with its description", function()
    local root = project({ ["a.lua"] = "--[[\nFrom Lua.\n]]\nreturn 0\n" })
    local out = dev(root, { "__verbs" })
    t.ok(out:find("\na\tlocal\tFrom Lua.\n", 1, true), out)
    t.ok(out:find("^lint\tbuiltin\t"), out)
    fs.remove(root, { recursive = true })
end)

t.test("__subs lists a noun's subcommands and nothing for a word that is not a noun", function()
    local root = project({ ["n/x.sh"] = "#!/usr/bin/env bash\n# Sub x.\n" })
    t.eq(dev(root, { "__subs", "n" }), "x\tlocal\tSub x.\n")
    t.eq(dev(root, { "__subs", "lint" }), "")
    t.eq(dev(root, { "__subs" }), "")
    fs.remove(root, { recursive = true })
end)

t.test("__flags lists the verb's flags, then the global ones, and ignores a third word", function()
    local root = project({ ["a.lua"] = "--[[\nA.\nflags: --ok\n]]\nreturn 0\n" })
    t.eq(dev(root, { "__flags", "a" }), "--ok\n" .. GLOBAL_TAIL)
    t.eq(dev(root, { "__flags", "box", "ls", "extra" }), "--all\n" .. GLOBAL_TAIL)
    t.eq(dev(root, { "__flags", "nope" }), GLOBAL_TAIL)
    t.eq(dev(root, { "__flags" }), GLOBAL_TAIL)
    fs.remove(root, { recursive = true })
end)

t.test("__check-topics reports a .lua flags line with -h and exits 1", function()
    local root = project({ ["a.lua"] = "--[[\nA.\nflags: -h\n]]\nreturn 0\n" })
    local out, code = devos.capture(
        { "luajit", MAIN, "__check-topics" },
        { cwd = root, stderr = "stdout", env = { DEV_SELF = SELF } }
    )
    t.eq(code, 1)
    local line =
        ".dev/a.lua:1: the flags line declares -h or --help, which dev reserves before --\n"
    t.eq(out, line)
    fs.remove(root, { recursive = true })
end)

t.test("__check-topics checks the built-in topics in the dotfiles clone itself", function()
    local root = project({ ["a.lua"] = "--[[\nA.\n]]\nreturn 0\n" })
    assert(fs.mkdir(root .. "/docs/dev", { parents = true }))
    assert(fs.write(root .. "/docs/dev/bad.md", "# bad: A topic\n\n`dev nope`\n"))
    local out, code = devos.capture(
        { "luajit", MAIN, "__check-topics" },
        { cwd = root, stderr = "stdout", env = { DEV_SELF = SELF, DOTFILES = fs.realpath(root) } }
    )
    t.eq(code, 1)
    t.eq(out, "docs/dev/bad.md:3: `dev nope`: no verb nope\n")
    fs.remove(root, { recursive = true })
end)

t.test("__check-topics skips the built-in topics when DOTFILES names another directory", function()
    local root = project({ ["a.lua"] = "--[[\nA.\n]]\nreturn 0\n" })
    local other = support.tempdir()
    assert(fs.mkdir(other .. "/docs/dev", { parents = true }))
    assert(fs.write(other .. "/docs/dev/bad.md", "# bad: A topic\n\n`dev nope`\n"))
    local out, code = devos.capture(
        { "luajit", MAIN, "__check-topics" },
        { cwd = root, stderr = "stdout", env = { DEV_SELF = SELF, DOTFILES = fs.realpath(other) } }
    )
    t.eq({ out, code }, { "", 0 })
    fs.remove(root, { recursive = true })
    fs.remove(other, { recursive = true })
end)
