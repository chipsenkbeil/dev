local t = require("dev.testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/dotfiles/bin/.local/share/dev/main.lua"
local SELF = REPO .. "/dotfiles/bin/.local/bin/dev"
local RAN = '#!/usr/bin/env bash\n# flags: --now\n# Run x.\necho ran-x "$@"\n'

local function project(files)
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev", { parents = true }))
    for name, source in pairs(files) do
        local path = root .. "/.dev/" .. name
        assert(fs.mkdir(fs.dirname(path), { parents = true }))
        assert(fs.write(path, source))
        assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
    end
    return root
end

local function dev(root, args)
    local argv = { "luajit", MAIN }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    return devos.capture(argv, { cwd = root, stderr = "stdout", env = { DEV_SELF = SELF } })
end

local function nested()
    return project({
        ["n/m/x.sh"] = RAN,
        ["n/m/__h.sh"] = "#!/usr/bin/env bash\n# Hidden.\n",
        ["n/m/o/y.lua"] = "-- Run y.\nprint('ran-y')\nreturn 0\n",
        ["n/m/DESCRIPTION"] = "The m noun\n",
    })
end

t.test("a script three words deep runs with its arguments", function()
    local root = nested()
    local out, code = dev(root, { "n", "m", "x", "--now", "a b" })
    t.eq({ out, code }, { "ran-x --now a b\n", 0 })
    out, code = dev(root, { "n", "m", "o", "y" })
    t.eq({ out, code }, { "ran-y\n", 0 })
    fs.remove(root, { recursive = true })
end)

t.test("a noun that holds only a noun is a noun", function()
    local root = project({ ["n/m/x.sh"] = RAN })
    local out, code = dev(root, { "n" })
    t.eq(code, 2)
    t.ok(out:find("dev n: needs a subcommand", 1, true), out)
    t.ok(out:find("\n  m ", 1, true), out)
    out, code = dev(root, { "n", "m" })
    t.eq(code, 2)
    t.ok(out:find("dev n m: needs a subcommand", 1, true), out)
    out, code = dev(root, { "n", "m", "nope" })
    t.eq(code, 2)
    t.ok(out:find("dev n m: unknown subcommand nope", 1, true), out)
    fs.remove(root, { recursive = true })
end)

t.test("dev help lists the subcommands at each depth and shows a leaf", function()
    local root = nested()
    local out = dev(root, { "help", "n" })
    t.ok(out:find("\n  m +The m noun\n"), out)
    out = dev(root, { "help", "n", "m" })
    t.ok(out:find("\n  x +Run x%.\n"), out)
    t.ok(out:find("\n  o ", 1, true), out)
    t.ok(not out:find("__h", 1, true), out)
    out = dev(root, { "help", "n", "m", "x" })
    t.ok(out:find("dev n m x", 1, true) and out:find("--now", 1, true), out)
    out = dev(root, { "n", "m", "--help" })
    t.ok(out:find("\n  x +Run x%.\n"), out)
    out = dev(root, { "n", "m", "x", "-h" })
    t.ok(out:find("usage\n  dev n m x [flags]", 1, true), out)
    local _, code = dev(root, { "help", "n", "m", "zap" })
    t.eq(code, 2)
    fs.remove(root, { recursive = true })
end)

t.test("__subs and __flags take one word per level", function()
    local root = nested()
    t.eq(dev(root, { "__subs", "n" }), "m\tlocal\tThe m noun\n")
    t.eq(dev(root, { "__subs", "n", "m" }), "x\tlocal\tRun x.\no\tlocal\ty\n")
    t.eq(dev(root, { "__subs", "n", "m", "x" }), "")
    local out = dev(root, { "__flags", "n", "m", "x" })
    t.ok(out:find("^%-%-now\n%-v\n"), out)
    fs.remove(root, { recursive = true })
end)

t.test("the topic check follows a noun to any depth", function()
    local root = nested()
    assert(fs.mkdir(root .. "/.dev/topics", { parents = true }))
    assert(
        fs.write(
            root .. "/.dev/topics/t.md",
            "# t: A topic\n\n`dev n m x --now` and `dev n m o y`.\n\n```\ndev n m x\n```\n"
        )
    )
    t.eq({ dev(root, { "__topics", "check" }) }, { "", 0 })
    assert(
        fs.write(
            root .. "/.dev/topics/t.md",
            "# t: A topic\n\n`dev n m nope`\n\n`dev n m x --bogus`\n\n`dev n m o frob`\n"
        )
    )
    local out, code = dev(root, { "__topics", "check" })
    t.eq(code, 1)
    t.ok(
        out:find(".dev/topics/t.md:3: `dev n m nope`: dev n m has no subcommand nope", 1, true),
        out
    )
    t.ok(out:find("dev n m x takes no flag --bogus", 1, true), out)
    t.ok(out:find("dev n m o has no subcommand frob", 1, true), out)
    fs.remove(root, { recursive = true })
end)

t.test("the old hyphenated words are gone", function()
    local root = project({})
    local out, code = dev(root, { "box", "install-tools", "b" })
    t.eq(code, 2)
    t.ok(out:find("dev box: unknown subcommand install-tools", 1, true), out)
    out, code = dev(root, { "__check-topics" })
    t.eq(code, 2)
    t.ok(out:find("unknown", 1, true), out)
    out, code = dev(root, { "__topics" })
    t.eq(code, 2)
    t.ok(out:find("dev __topics: needs a subcommand", 1, true), out)
    out, code = dev(root, { "__topics", "frob" })
    t.eq(code, 2)
    t.ok(out:find("dev __topics: unknown subcommand frob", 1, true), out)
    out, code = dev(root, { "box", "tools", "install" })
    t.eq(code, 2)
    t.ok(out:find("no box given and no terminal to pick one", 1, true), out)
    fs.remove(root, { recursive = true })
end)

local function names_below(words, found)
    local out = dev(REPO, { "__subs", unpack(words) })
    for line in out:gmatch("[^\n]+") do
        local name = line:match("^[^\t]+")
        local deeper = { unpack(words) }
        deeper[#deeper + 1] = name
        found[#found + 1] = table.concat(deeper, " ")
        names_below(deeper, found)
    end
end

t.test("no command word of this repository has a hyphen, at any depth", function()
    local found = {}
    for line in dev(REPO, { "__verbs" }):gmatch("[^\n]+") do
        local name = line:match("^[^\t]+")
        found[#found + 1] = name
        names_below({ name }, found)
    end
    t.ok(#found > 20, "too few commands found: " .. #found)
    t.ok(table.concat(found, "\n"):find("box tools install", 1, true), "box tools install missing")
    local listed = dev(REPO, { "help", "-a" }):match("^(.-)\nTopics\n")
    for name in listed:gmatch("\n  (%S+)") do
        found[#found + 1] = name
    end
    for _, name in ipairs(found) do
        t.ok(not name:find("-", 1, true), "hyphenated command " .. name)
    end
end)
