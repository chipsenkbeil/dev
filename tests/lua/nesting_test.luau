local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local registry = require("dev.registry")
local support = require("support")

local RAN = "#!/usr/bin/env bash\n# summary: Run x.\n# flag: now kind=boolean -- Right away\n"
    .. '# arg: words list\necho ran-x "$@"\n'
local RAN_Y = 'local dev_command = require("dev.command")\n'
    .. 'return dev_command({ summary = "Run y.", run = function() print("ran-y") return 0 end })\n'

local function project(files)
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev/commands", { parents = true }))
    for name, source in pairs(files) do
        local path = root .. "/.dev/commands/" .. name
        assert(fs.mkdir(fs.dirname(path), { parents = true }))
        assert(fs.write(path, source))
        assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
    end
    return root
end

local function dev(root, args)
    local argv = { support.DEV }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    return dev_os.capture(argv, {
        cwd = root,
        stderr = "stdout",
        env = { DEV_SELF = support.DEV, XDG_CONFIG_HOME = root .. "/config" },
    })
end

local function nested()
    return project({
        ["n/m/x.sh"] = RAN,
        ["n/m/h.sh"] = "#!/usr/bin/env bash\n# summary: Hidden.\n# hidden\n",
        ["n/m/o/y.luau"] = RAN_Y,
        ["n/m/DESCRIPTION"] = "The m parent command\n",
    })
end

testing.test("a command three words deep runs with its arguments", function()
    local root = nested()
    local out, code = dev(root, { "n", "m", "x", "--now", "a b" })
    testing.eq({ out, code }, { "ran-x a b\n", 0 })
    out, code = dev(root, { "n", "m", "o", "y" })
    testing.eq({ out, code }, { "ran-y\n", 0 })
    fs.remove(root, { recursive = true })
end)

testing.test("a parent command that holds only a parent command is a parent command", function()
    local root = project({ ["n/m/x.sh"] = RAN })
    local out, code = dev(root, { "n" })
    testing.eq(code, 2)
    testing.ok(out:find("dev n: needs a subcommand", 1, true), out)
    testing.ok(out:find("\n  m ", 1, true), out)
    out, code = dev(root, { "n", "m" })
    testing.eq(code, 2)
    testing.ok(out:find("dev n m: needs a subcommand", 1, true), out)
    out, code = dev(root, { "n", "m", "nope" })
    testing.eq(code, 2)
    testing.ok(out:find("dev n m: unknown subcommand nope", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("dev help lists the subcommands at each depth and shows a leaf", function()
    local root = nested()
    local out = dev(root, { "help", "n" })
    testing.ok(out:find("\n  m +The m parent command\n"), out)
    out = dev(root, { "help", "n", "m" })
    testing.ok(out:find("\n  x +Run x%.\n"), out)
    testing.ok(out:find("\n  o ", 1, true), out)
    out = dev(root, { "help", "n", "m", "x" })
    testing.ok(out:find("dev n m x", 1, true) and out:find("--now", 1, true), out)
    out = dev(root, { "n", "m", "--help" })
    testing.ok(out:find("\n  x +Run x%.\n"), out)
    out = dev(root, { "n", "m", "x", "-h" })
    testing.ok(out:find("usage\n  dev n m x", 1, true), out)
    local _, code = dev(root, { "help", "n", "m", "zap" })
    testing.eq(code, 2)
    fs.remove(root, { recursive = true })
end)

testing.test("the registry answers one word per level", function()
    local root = nested()
    local reg = registry.load(root, { warn = function() end })
    local names = {}
    for _, row in ipairs(reg:subs({ "n", "m" })) do
        names[#names + 1] = row.name
    end
    table.sort(names)
    testing.eq(names, { "n m o", "n m x" })
    testing.eq(reg:find({ "n", "m", "h" }).hidden, true)
    testing.eq(reg:find({ "n", "m", "x" }).hidden, false)
    testing.eq(reg:flags({ "n", "m", "x" }), { "--now" })
    fs.remove(root, { recursive = true })
end)

testing.test("the topic check follows a parent command to any depth", function()
    local root = nested()
    assert(fs.mkdir(root .. "/.dev/help", { parents = true }))
    assert(
        fs.write(
            root .. "/.dev/help/t.md",
            "# t: A topic\n\n`dev n m x --now` and `dev n m o y`.\n\n```\ndev n m x\n```\n"
        )
    )
    testing.eq({ dev(root, { "help", "--check-topics" }) }, { "", 0 })
    assert(
        fs.write(
            root .. "/.dev/help/t.md",
            "# t: A topic\n\n`dev n m nope`\n\n`dev n m x --bogus`\n\n`dev n m o frob`\n"
        )
    )
    local out, code = dev(root, { "help", "--check-topics" })
    testing.eq(code, 1)
    testing.ok(
        out:find(".dev/help/t.md:3: `dev n m nope`: dev n m has no subcommand nope", 1, true),
        out
    )
    testing.ok(out:find("dev n m x takes no flag --bogus", 1, true), out)
    testing.ok(out:find("dev n m o has no subcommand frob", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("the old hyphenated words are gone", function()
    local root = project({})
    local out, code = dev(root, { "box", "install-tools", "b" })
    testing.eq(code, 2)
    testing.ok(out:find("dev box: unknown subcommand install-tools", 1, true), out)
    out, code = dev(root, { "box", "tools", "install" })
    testing.eq(code, 2)
    testing.ok(out:find("No box given and no terminal to pick one", 1, true), out)
    fs.remove(root, { recursive = true })
end)

local function names_below(reg, words, found)
    for _, row in ipairs(reg:subs(words)) do
        found[#found + 1] = row.name
        if row.parent then
            names_below(reg, row.words, found)
        end
    end
end

testing.test("no command word of this repository has a hyphen, at any depth", function()
    local root = support.tempdir()
    local reg = registry.load(root, { warn = function() end }):view(registry.Source.BUILTIN)
    local found = {}
    for _, row in ipairs(reg:commands()) do
        found[#found + 1] = row.name
        if row.parent then
            names_below(reg, row.words, found)
        end
    end
    testing.ok(#found > 20, "too few commands found: " .. #found)
    testing.ok(
        table.concat(found, "\n"):find("box tools install", 1, true),
        "box tools install missing"
    )
    for _, name in ipairs(found) do
        testing.ok(not name:find("-", 1, true), "hyphenated command " .. name)
    end
    fs.remove(root, { recursive = true })
end)
