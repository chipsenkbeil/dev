local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/dotfiles/bin/.local/share/dev/main.lua"
local SELF = REPO .. "/dotfiles/bin/.local/bin/dev"
local GLOBAL_TAIL =
    "-v\n--verbose\n-vv\n--remote\n--local\n--detach\n--priority\n-C\n--agent\n--job-timeout\n"

local function project(files)
    local root = support.tempdir()
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

local function dev(root, args)
    local argv = { "luajit", MAIN }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    return dev_os.capture(argv, { cwd = root, stderr = "null", env = { DEV_SELF = SELF } })
end

testing.test("__verbs lists a .lua project verb as local with its description", function()
    local root = project({ ["a.lua"] = "--[[\nFrom Lua.\n]]\nreturn 0\n" })
    local out = dev(root, { "__verbs" })
    testing.ok(out:find("\na\tlocal\tFrom Lua.\n", 1, true), out)
    testing.ok(out:find("^lint\tbuiltin\t"), out)
    fs.remove(root, { recursive = true })
end)

testing.test(
    "__subs lists a noun's subcommands and nothing for a word that is not a noun",
    function()
        local root = project({ ["n/x.sh"] = "#!/usr/bin/env bash\n# Sub x.\n" })
        testing.eq(dev(root, { "__subs", "n" }), "x\tlocal\tSub x.\n")
        testing.eq(dev(root, { "__subs", "lint" }), "")
        testing.eq(dev(root, { "__subs" }), "")
        fs.remove(root, { recursive = true })
    end
)

testing.test(
    "__flags lists the verb's flags, then the global ones, and takes a word per level",
    function()
        local root = project({ ["a.lua"] = "--[[\nA.\nflags: --ok\n]]\nreturn 0\n" })
        testing.eq(dev(root, { "__flags", "a" }), "--ok\n" .. GLOBAL_TAIL)
        testing.eq(dev(root, { "__flags", "box", "ls" }), "--all\n--json\n" .. GLOBAL_TAIL)
        testing.eq(dev(root, { "__flags", "box", "ls", "extra" }), GLOBAL_TAIL)
        testing.eq(dev(root, { "__flags", "nope" }), GLOBAL_TAIL)
        testing.eq(dev(root, { "__flags" }), GLOBAL_TAIL)
        fs.remove(root, { recursive = true })
    end
)

testing.test("__topics check reports a .lua flags line with -h and exits 1", function()
    local root = project({ ["a.lua"] = "--[[\nA.\nflags: -h\n]]\nreturn 0\n" })
    local out, code = dev_os.capture(
        { "luajit", MAIN, "__topics", "check" },
        { cwd = root, stderr = "stdout", env = { DEV_SELF = SELF } }
    )
    testing.eq(code, 1)
    local line =
        ".dev/a.lua:1: the flags line declares -h or --help, which dev reserves before --\n"
    testing.eq(out, line)
    fs.remove(root, { recursive = true })
end)

local function share_copy(dir)
    assert(
        dev_os.run({ "cp", "-R", REPO .. "/dotfiles/bin/.local/share/dev", dir }) == 0,
        "cp failed"
    )
    local share = dir .. "/dev"
    assert(fs.remove(share .. "/docs", { recursive = true }))
    assert(fs.mkdir(share .. "/docs"))
    assert(fs.write(share .. "/docs/bad.md", "# bad: A topic\n\n`dev nope`\n"))
    return share
end

local function check_with(share, root, env)
    return dev_os.capture({ "luajit", share .. "/main.lua", "__topics", "check" }, {
        cwd = root,
        stderr = "stdout",
        env = env,
        unset = { "DOTFILES" },
    })
end

testing.test(
    "__topics check checks the built-in topics when the share folder is in the project",
    function()
        local root = project({ ["a.lua"] = "--[[\nA.\n]]\nreturn 0\n" })
        local share = share_copy(root)
        local out, code = check_with(share, root, { DEV_SELF = SELF })
        testing.eq(code, 1)
        testing.eq(out, "dev/docs/bad.md:3: `dev nope`: no verb nope\n")
        fs.remove(root, { recursive = true })
    end
)

testing.test("__topics check reads the built-in topics beside main.lua", function()
    local root = project({ ["a.lua"] = "--[[\nA.\n]]\nreturn 0\n" })
    local share = share_copy(root)
    assert(fs.write(share .. "/docs/good.md", "# good: A topic\n\n`dev lint`\n"))
    assert(fs.mkdir(root .. "/.dev/topics", { parents = true }))
    assert(fs.write(root .. "/.dev/topics/good.md", "# good: Clash\n\nText.\n"))
    local out, code = check_with(share, root, { DEV_SELF = SELF })
    testing.eq(code, 1)
    testing.ok(out:find("dev/docs/bad.md:3:", 1, true), out)
    testing.ok(out:find(".dev/topics/good.md:1: topic good is also a built-in topic", 1, true), out)
    testing.ok(not out:find("dev/docs/good.md", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test(
    "__topics check skips the built-in topics when the share folder is outside the project",
    function()
        local root = project({ ["a.lua"] = "--[[\nA.\n]]\nreturn 0\n" })
        local other = support.tempdir()
        local share = share_copy(other)
        local out, code = check_with(share, root, { DEV_SELF = SELF })
        testing.eq({ out, code }, { "", 0 })
        fs.remove(root, { recursive = true })
        fs.remove(other, { recursive = true })
    end
)

local CARDS = table.concat({
    "11111111  Ready  3 Pomodori  -  first card",
    "22222222  Icebox  Unsized  -  second card",
    "",
}, "\n")

local function sandbox(tools)
    local root = support.sandbox({}, {})
    local cache = support.tempdir()
    for name, body in pairs(tools or {}) do
        assert(fs.write(root .. "/bin/" .. name, "#!/bin/sh\n" .. body))
        assert(dev_os.run({ "chmod", "755", root .. "/bin/" .. name }) == 0, "chmod failed")
    end
    return root, cache
end

local function args(root, cache, words, path)
    local argv = { "__args" }
    for _, word in ipairs(words) do
        argv[#argv + 1] = word
    end
    return support.dev(root, argv, {
        env = { XDG_CACHE_HOME = cache, HOME = cache, PATH = path },
    })
end

local function cache_file(root, cache)
    return cache .. "/dev/cards-" .. root:gsub("[^%w]", "_")
end

local function seed(root, cache, stamp)
    assert(fs.mkdir(cache .. "/dev", { parents = true }))
    assert(fs.write(cache_file(root, cache), stamp .. "\n" .. CARDS))
end

local function wait_for(done)
    for _ = 1, 50 do
        if done() then
            return true
        end
        dev_os.nap(0.1)
    end
    return false
end

testing.test("__args completes card ids from a fresh cache after a board subcommand", function()
    local root, cache = sandbox()
    seed(root, cache, os.time())
    local out, code = args(root, cache, { "board", "show" })
    testing.eq(code, 0, out)
    local expected = table.concat({
        "11111111\tReady  3 Pomodori  -  first card",
        "22222222\tIcebox  Unsized  -  second card",
        "",
    }, "\n")
    testing.eq(out, expected)
end)

testing.test("__args prints a stale card cache and refreshes it in the background", function()
    local marker = support.tempdir() .. "/ran"
    local root, cache =
        sandbox({ dev = 'echo "$*" >"' .. marker .. '"; echo "33333333  Ready  3  -  new"' })
    seed(root, cache, os.time() - 600)
    local out, code = args(root, cache, { "board", "move" })
    testing.eq(code, 0, out)
    testing.ok(out:find("11111111\t", 1, true), out)
    testing.ok(wait_for(function()
        return fs.read(marker) == "-C " .. root .. " board ls\n"
    end))
    testing.ok(wait_for(function()
        return (fs.read(cache_file(root, cache)) or ""):find("33333333", 1, true) ~= nil
    end))
end)

testing.test("__args prints nothing for a missing card cache and starts a refresh", function()
    local root, cache = sandbox({ dev = 'echo "33333333  Ready  3  -  new"' })
    local out, code = args(root, cache, { "board", "show" })
    testing.eq(code, 0, out)
    testing.eq(out, "")
    testing.ok(wait_for(function()
        return fs.exists(cache_file(root, cache))
    end))
end)

testing.test("__args completes nothing for a board subcommand without a card argument", function()
    local root, cache = sandbox()
    seed(root, cache, os.time())
    testing.eq(args(root, cache, { "board", "ls" }), "")
    testing.eq(args(root, cache, { "board", "show", "11111111" }), "")
end)

testing.test("__args takes box, connectable and run ids from ci __complete", function()
    local root, cache = sandbox({ ci = 'printf "%s-1\\tlabel\\n" "$2"' })
    testing.eq(args(root, cache, { "box", "delete" }), "boxes-1\tlabel\n")
    local both = "boxes-1\tlabel\nconnectables-1\tlabel\n"
    testing.eq(args(root, cache, { "box", "connect" }), both)
    testing.eq(args(root, cache, { "connect" }), both)
    testing.eq(args(root, cache, { "ps", "--run" }), "runs-1\tlabel\n")
end)

testing.test("__args prints nothing and exits 0 when ci fails", function()
    local root, cache = sandbox({ ci = "echo partial; exit 3" })
    local out, code = args(root, cache, { "connect" })
    testing.eq(code, 0, out)
    testing.eq(out, "")
end)

testing.test("__args returns within the timeout and prints nothing when ci is slow", function()
    local root, cache = sandbox({ ci = "echo late; sleep 20" })
    local started = os.time()
    local out, code = args(root, cache, { "box", "delete" })
    testing.eq(code, 0, out)
    testing.eq(out, "")
    testing.ok(os.time() - started < 10, "the helper waited " .. os.time() - started .. " seconds")
end)

testing.test("__args prints nothing and exits 0 when ci is missing", function()
    local root, cache = sandbox()
    local luajit = assert(dev_os.which("luajit"))
    assert(fs.mkdir(root .. "/lua", { parents = true }))
    assert(fs.symlink(luajit, root .. "/lua/luajit"))
    local path = root .. "/bin:" .. root .. "/lua:/usr/bin:/bin"
    local out, code = args(root, cache, { "connect" }, path)
    testing.eq(code, 0, out)
    testing.eq(out, "")
end)
