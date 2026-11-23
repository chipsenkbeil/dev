local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local registry = require("dev.registry")
local support = require("support")
local topics = require("dev.topics")

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

testing.test("a topic naming a missing verb is reported at its line", function()
    local root = project({ ["topics/a.md"] = "# a: A topic\n\nSee `dev nope` here.\n" })
    testing.eq(problems(root), { ".dev/topics/a.md:3: `dev nope`: no command nope" })
    fs.remove(root, { recursive = true })
end)

testing.test("a fenced command is checked, a placeholder and a global flag are not", function()
    local root = project({
        ["topics/a.md"] = "# a: A topic\n\n```\ndev -vv --remote lint\ndev -C some/dir lint\n"
            .. "dev <verb> --x\ndev nope\n```\n",
    })
    testing.eq(problems(root), { ".dev/topics/a.md:7: no command nope" })
    fs.remove(root, { recursive = true })
end)

testing.test("a flag the verb does not list and a missing subcommand are reported", function()
    local root = project({
        ["topics/a.md"] = "# a: A topic\n\n`dev help --nope`\n`dev tools nope`\n`dev help -a`\n"
            .. "`dev box ls [--all] --x=1`\n",
    })
    testing.eq(problems(root), {
        ".dev/topics/a.md:3: `dev help --nope`: dev help takes no flag --nope",
        ".dev/topics/a.md:4: `dev tools nope`: dev tools has no subcommand nope",
        ".dev/topics/a.md:6: `dev box ls [--all] --x=1`: dev box ls takes no flag --x",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("a bad first line and a topic named like a verb are reported", function()
    local root = project({
        ["topics/a.md"] = "# b: Wrong name\n",
        ["topics/lint.md"] = "# lint: A topic\n",
        ["topics/c.md"] = "# c: \n",
    })
    testing.eq(problems(root), {
        '.dev/topics/a.md:1: the first line must be "# a: <summary>"',
        '.dev/topics/c.md:1: the first line must be "# c: <summary>"',
        ".dev/topics/lint.md:1: topic lint is also a command",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("a script that declares -h or --help is reported", function()
    local root = project({
        ["a.sh"] = "#!/usr/bin/env bash\n# A.\n# flags: -h --ok\n",
        ["n/x.sh"] = "#!/usr/bin/env bash\n# X.\n# flags: --help\n",
        ["fine.sh"] = "#!/usr/bin/env bash\n# Fine.\n# flags: --ok\n",
    })
    local message = "the flags line declares -h or --help, which dev reserves before --"
    testing.eq(problems(root), { ".dev/a.sh:1: " .. message, ".dev/n/x.sh:1: " .. message })
    fs.remove(root, { recursive = true })
end)

testing.test("a project verb's declared flags are accepted in a topic", function()
    local root = project({
        ["a.sh"] = "#!/usr/bin/env bash\n# A.\n# flags: --ok\n",
        ["topics/b.md"] = "# b: A topic\n\n`dev a --ok` and `dev a --bad`\n",
    })
    testing.eq(problems(root), { ".dev/topics/b.md:3: `dev a --bad`: dev a takes no flag --bad" })
    fs.remove(root, { recursive = true })
end)

testing.test("a topic accepts a flag of the built-in verb a project script replaces", function()
    local root = project({
        ["sync.lua"] = "--[[\nSync.\n]]\nreturn 0\n",
        ["topics/b.md"] = "# b: A topic\n\n`dev sync --check` and `dev sync --bad`\n",
    })
    testing.eq(
        problems(root),
        { ".dev/topics/b.md:3: `dev sync --bad`: dev sync takes no flag --bad" }
    )
    fs.remove(root, { recursive = true })
end)

testing.test("a .lua script that declares -h in its flags line is reported", function()
    local root = project({ ["a.lua"] = "--[[\nA.\nflags: -h --ok\n]]\nreturn 0\n" })
    testing.eq(problems(root), {
        ".dev/a.lua:1: the flags line declares -h or --help, which dev reserves before --",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("built-in topics are not checked against another project's verbs", function()
    local root = project({ ["topics/b.md"] = "# b: A topic\n\n`dev nope`\n" })
    local reg = registry.load(root, { warn = function() end })
    for _, found in ipairs(topics.check(reg)) do
        testing.ok(found.file:sub(1, 5) == ".dev/", found.file .. ": " .. found.message)
    end
    testing.eq(#problems(root), 1)
    fs.remove(root, { recursive = true })
end)
