local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local registry = require("dev.registry")
local support = require("support")
local topics = require("dev.topics")

local function project(files)
    local root = support.tempdir()
    for name, source in pairs(files) do
        local path = root .. "/.dev/" .. (name:find("^help/") and "" or "commands/") .. name
        assert(fs.mkdir(fs.dirname(path), { parents = true }))
        assert(fs.write(path, source))
        if name:find("%.sh$") then
            assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
        end
    end
    return root
end

local function problems(root)
    local out = {}
    local reg = registry.load(root, { warn = function() end })
    for _, found in ipairs(topics.check(reg)) do
        if found.file:sub(1, 5) == ".dev/" then
            out[#out + 1] = found.file .. ":" .. found.line .. ": " .. found.message
        end
    end
    return out
end

testing.test("a topic naming a missing command is reported at its line", function()
    local root = project({ ["help/a.md"] = "# a: A topic\n\nSee `dev nope` here.\n" })
    testing.eq(problems(root), { ".dev/help/a.md:3: `dev nope`: no command nope" })
    fs.remove(root, { recursive = true })
end)

testing.test("a fenced command is checked, a placeholder and a global flag are not", function()
    local root = project({
        ["help/a.md"] = "# a: A topic\n\n```\ndev -vv --remote lint\ndev -C some/dir lint\n"
            .. "dev <command> --x\ndev nope\n```\n",
    })
    testing.eq(problems(root), { ".dev/help/a.md:7: no command nope" })
    fs.remove(root, { recursive = true })
end)

testing.test("a flag the command does not list and a missing subcommand are reported", function()
    local root = project({
        ["help/a.md"] = "# a: A topic\n\n`dev help --nope`\n`dev tools nope`\n`dev help -a`\n"
            .. "`dev box ls [--all] --x=1`\n",
    })
    testing.eq(problems(root), {
        ".dev/help/a.md:3: `dev help --nope`: dev help takes no flag --nope",
        ".dev/help/a.md:4: `dev tools nope`: dev tools has no subcommand nope",
        ".dev/help/a.md:6: `dev box ls [--all] --x=1`: dev box ls takes no flag --x",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("a bad first line and a topic named like a command are reported", function()
    local root = project({
        ["help/a.md"] = "# b: Wrong name\n",
        ["help/lint.md"] = "# lint: A topic\n",
        ["help/c.md"] = "# c: \n",
    })
    testing.eq(problems(root), {
        '.dev/help/a.md:1: the first line must be "# a: <summary>"',
        '.dev/help/c.md:1: the first line must be "# c: <summary>"',
        ".dev/help/lint.md:1: help page lint is also a command",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("a script that declares -h or --help is reported", function()
    local root = project({
        ["a.sh"] = "#!/usr/bin/env bash\n# A.\n# flag: help short=h -- Bad\n# flag: ok -- Fine\n",
        ["n/x.sh"] = "#!/usr/bin/env bash\n# X.\n# flag: help -- Bad\n",
        ["fine.sh"] = "#!/usr/bin/env bash\n# Fine.\n# flag: ok -- Fine\n",
    })
    local message = "the spec declares -h or --help, which dev reserves before --"
    testing.eq(
        problems(root),
        { ".dev/commands/a.sh:1: " .. message, ".dev/commands/n/x.sh:1: " .. message }
    )
    fs.remove(root, { recursive = true })
end)

testing.test("a project command's declared flags are accepted in a topic", function()
    local root = project({
        ["a.sh"] = "#!/usr/bin/env bash\n# A.\n# flag: ok -- Fine\n",
        ["help/b.md"] = "# b: A topic\n\n`dev a --ok` and `dev a --bad`\n",
    })
    testing.eq(problems(root), { ".dev/help/b.md:3: `dev a --bad`: dev a takes no flag --bad" })
    fs.remove(root, { recursive = true })
end)

testing.test("a topic accepts a flag of the built-in command a project script replaces", function()
    local root = project({
        ["push.sh"] = "#!/usr/bin/env bash\n# Push.\n",
        ["help/b.md"] = "# b: A topic\n\n`dev push --tag` and `dev push --bad`\n",
    })
    testing.eq(
        problems(root),
        { ".dev/help/b.md:3: `dev push --bad`: dev push takes no flag --bad" }
    )
    fs.remove(root, { recursive = true })
end)

testing.test("a see_also name that is no help page is reported", function()
    local root = project({
        ["a.sh"] = "#!/usr/bin/env bash\n# A.\n# see_also: boards nope mine\n",
        ["help/mine.md"] = "# mine: A topic\n",
    })
    testing.eq(problems(root), {
        ".dev/commands/a.sh:1: the spec's see_also names nope, which is no help page",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("a .luau spec that declares -h is reported", function()
    local root = project({
        ["a.luau"] = 'return require("dev.command")({ summary = "A.", flags = { { name = "ok", kind = "boolean" }, { name = "x", short = "h", kind = "boolean" } }, run = function() return 0 end })\n',
    })
    testing.eq(problems(root), {
        ".dev/commands/a.luau:1: the spec declares -h or --help, which dev reserves before --",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("built-in topics are not checked against another project's commands", function()
    local root = project({ ["help/b.md"] = "# b: A topic\n\n`dev nope`\n" })
    local reg = registry.load(root, { warn = function() end })
    for _, found in ipairs(topics.check(reg)) do
        testing.ok(found.file:sub(1, 5) == ".dev/", found.file .. ": " .. found.message)
    end
    testing.eq(#problems(root), 1)
    fs.remove(root, { recursive = true })
end)
