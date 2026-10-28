local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local builtins = require("dev.builtins")
local project = require("dev.project")
local registry = require("dev.registry")
local support = require("support")

local LEGACY = "dotfiles/bin/.local/share/dev/legacy.bash"
local LUA_ONLY = {
    tools = true,
    ["tools install"] = true,
    ["tools check"] = true,
    help = true,
    lint = true,
    fmt = true,
    test = true,
    build = true,
    run = true,
    fetch = true,
    deploy = true,
    guide = true,
    bootstrap = true,
    push = true,
    pull = true,
    connect = true,
    box = true,
    ["box ls"] = true,
    ["box create"] = true,
    ["box show"] = true,
    ["box stop"] = true,
    ["box resume"] = true,
    ["box extend"] = true,
    ["box tools"] = true,
    ["box tools install"] = true,
    ["box delete"] = true,
    ["box connect"] = true,
    board = true,
    ["board status"] = true,
    ["board init"] = true,
    ["board ls"] = true,
    ["board next"] = true,
    ["board add"] = true,
    ["board note"] = true,
    ["board move"] = true,
    ["board take"] = true,
    ["board release"] = true,
    ["board size"] = true,
}

local function scripted(dir, rel, text, mode)
    local path = fs.join(dir, rel)
    assert(fs.mkdir(fs.dirname(path), { parents = true }))
    assert(fs.write(path, text))
    assert(devos.run({ "chmod", mode or "755", path }) == 0, "chmod failed")
    return path
end

local function words(rows)
    local names = {}
    for _, row in ipairs(rows) do
        names[#names + 1] = row.name
    end
    return names
end

local function make_project()
    local root = support.tempdir()
    scripted(root, ".dev/a.sh", "#!/usr/bin/env bash\n# From the shell script.\n")
    scripted(root, ".dev/a.lua", "--[[\nFrom the Lua script.\nflags: --lua\n]]\n", "644")
    scripted(root, ".dev/n/x.sh", "#!/usr/bin/env bash\n# Sub x.\n# group: Mine\n")
    scripted(root, ".dev/n/__y.sh", "#!/usr/bin/env bash\n# Hidden sub.\n")
    scripted(root, ".dev/__h.sh", "#!/usr/bin/env bash\n# Helper.\n")
    scripted(root, ".dev/quiet.sh", "#!/usr/bin/env bash\n# Quiet one.\n# hidden\n")
    scripted(root, ".dev/off.sh", "#!/usr/bin/env bash\n# Not executable.\n", "644")
    return root
end

t.test("builtins match the legacy table byte for byte, except the rows only Lua serves", function()
    local text = assert(fs.read(LEGACY), "legacy.bash must exist for the table comparison")
    local table_text = text:match("builtin_table%(%) {\n    cat <<'TABLE'\n(.-)\nTABLE\n")
    local want = {}
    for line in table_text:gmatch("[^\n]+") do
        local f = {}
        for field in (line .. "|"):gmatch("([^|]*)|") do
            f[#f + 1] = field
        end
        local handler = (f[2] ~= "" and f[2] ~= "noun") and "legacy" or f[2]
        want[#want + 1] = table.concat({ f[1], handler, f[3], f[4], f[5], f[6] or "" }, "|")
    end
    local got = {}
    for _, row in ipairs(builtins) do
        if not LUA_ONLY[table.concat(row.words, " ")] then
            local handler = row.noun and "noun" or row.handler or ""
            local group = row.hidden and "hidden" or row.group or ""
            got[#got + 1] = table.concat({
                table.concat(row.words, " "),
                handler,
                row.flags or "",
                row.usage or "",
                row.desc,
                group,
            }, "|")
        end
    end
    t.eq(got, want)
end)

t.test(".lua beats .sh and needs no exec bit, while an unexecutable .sh is no verb", function()
    local root = make_project()
    local reg = registry.load(root)
    local row = reg:find({ "a" })
    t.eq(row.lang, "lua")
    t.eq(row.desc, "From the Lua script.")
    t.eq(row.kind, "local")
    t.eq(reg:find({ "off" }), nil)
    t.eq(reg:flags({ "a" }), { "--lua" })
    fs.remove(root, { recursive = true })
end)

t.test("a directory with scripts is a noun whose subs are listed without __ helpers", function()
    local root = make_project()
    local reg = registry.load(root)
    t.ok(reg:is_noun("n"), "n should be a noun")
    t.eq(words(reg:subs("n")), { "n x" })
    t.eq(reg:find({ "n", "__y" }).desc, "Hidden sub.")
    t.eq(reg:find({ "n" }).group, "Mine")
    t.eq(reg:find({ "n" }).desc, "x")
    t.eq(reg:is_noun("a"), false)
    t.eq(reg:subs("a"), {})
    fs.remove(root, { recursive = true })
end)

t.test("DESCRIPTION supplies a noun's description", function()
    local root = make_project()
    assert(fs.write(root .. "/.dev/n/DESCRIPTION", "The n noun\nsecond line\n"))
    t.eq(registry.load(root):find({ "n" }).desc, "The n noun")
    fs.remove(root, { recursive = true })
end)

t.test("verbs lists builtins, then project verbs, and keeps __ helpers out", function()
    local root = make_project()
    local names = words(registry.load(root):verbs())
    t.eq(names[1], "lint")
    t.eq({ unpack(names, #names - 2) }, { "a", "quiet", "n" })
    t.eq(registry.load(root):find({ "__h" }).desc, "Helper.")
    local seen = {}
    for _, name in ipairs(names) do
        seen[name] = true
    end
    t.eq(seen.__h, nil)
    t.eq(seen.off, nil)
    fs.remove(root, { recursive = true })
end)

t.test("a hidden header and a group header place a local verb", function()
    local root = make_project()
    local reg = registry.load(root)
    t.eq(reg:find({ "quiet" }).hidden, true)
    t.eq(reg:find({ "quiet" }).group, fs.basename(root))
    t.eq(reg:find({ "a" }).hidden, false)
    t.eq(reg:find({ "bootstrap" }).hidden, true)
    t.eq(reg:find({ "lint" }).group, "Check your work")
    fs.remove(root, { recursive = true })
end)

t.test("a script named like a builtin noun or builtin subcommand replaces neither", function()
    local root = make_project()
    scripted(root, ".dev/box.sh", "#!/usr/bin/env bash\n# Fake box.\n")
    scripted(
        root,
        ".dev/tools/install.sh",
        "#!/usr/bin/env bash\n# Fake install.\n# flags: --fake\n"
    )
    scripted(root, ".dev/tools/extra.sh", "#!/usr/bin/env bash\n# Extra tool.\n")
    local reg = registry.load(root)
    t.eq(reg:find({ "box" }).kind, "builtin")
    t.eq(reg:is_noun("box"), true)
    t.eq(reg:find({ "tools", "install" }).kind, "builtin")
    t.eq(
        reg:flags({ "tools", "install" }),
        { "--dry-run", "--force", "--group", "--system", "--user" }
    )
    t.eq(reg:flags({ "tools" }), {})
    t.eq(reg:find({ "tools", "extra" }).kind, "local")
    t.eq(reg:find({ "tools" }).desc, "Install and check the tools in .dev/tools.tsv")
    fs.remove(root, { recursive = true })
end)

t.test("a script named like a builtin verb overrides it and keeps its place", function()
    local root = make_project()
    scripted(root, ".dev/lint.sh", "#!/usr/bin/env bash\n# My lint.\n# flags: --mine\n")
    scripted(root, ".dev/deploy.sh", "#!/usr/bin/env bash\n# My deploy.\n# group: Elsewhere\n")
    local reg = registry.load(root)
    local lint = reg:find({ "lint" })
    t.eq(lint.kind, "override")
    t.eq(lint.desc, "My lint.")
    t.eq(lint.group, "Check your work")
    t.eq(reg:flags({ "lint" }), { "--mine" })
    t.eq(reg:find({ "deploy" }).group, "Elsewhere")
    fs.remove(root, { recursive = true })
end)

t.test("a flat script takes the whole name from a directory of the same name", function()
    local root = make_project()
    scripted(root, ".dev/n.sh", "#!/usr/bin/env bash\n# Flat n.\n")
    local reg = registry.load(root)
    t.eq(reg:is_noun("n"), false)
    t.eq(reg:find({ "n" }).desc, "Flat n.")
    t.eq(reg:find({ "n", "x" }), nil)
    fs.remove(root, { recursive = true })
end)

t.test("--help in a flags line is dropped with the warning", function()
    local root = make_project()
    scripted(root, ".dev/w.sh", "#!/usr/bin/env bash\n# W.\n# flags: --ok --help\n")
    local warned = {}
    local reg = registry.load(root, {
        warn = function(message)
            warned[#warned + 1] = message
        end,
    })
    t.eq(reg:flags({ "w" }), { "--ok" })
    t.eq(warned, {
        "dev: "
            .. root
            .. "/.dev/w.sh: the flags line declares --help, which dev reserves before --",
    })
    fs.remove(root, { recursive = true })
end)

t.test("a noun with no description file lists its subcommand names", function()
    local root = make_project()
    scripted(root, ".dev/n/z.sh", "#!/usr/bin/env bash\n# Sub z.\n")
    t.eq(registry.load(root):find({ "n" }).desc, "x, z")
    fs.remove(root, { recursive = true })
end)

t.test(".dev/lua and .dev/topics are never nouns", function()
    local root = make_project()
    scripted(root, ".dev/lua/helper.lua", "return {}\n", "644")
    scripted(root, ".dev/topics/guide.sh", "#!/usr/bin/env bash\n# Not a verb.\n")
    local reg = registry.load(root)
    t.eq(reg:is_noun("lua"), false)
    t.eq(reg:is_noun("topics"), false)
    t.eq(reg:find({ "lua" }), nil)
    t.eq(reg:find({ "topics", "guide" }), nil)
    for _, row in ipairs(reg:verbs()) do
        t.ok(
            row.name ~= "lua" and row.name ~= "topics",
            "reserved directory listed as " .. row.name
        )
    end
    fs.remove(root, { recursive = true })
end)

t.test("builtin flags come from the table and unknown commands give none", function()
    local reg = registry.load(support.tempdir())
    t.eq(reg:flags({ "help" }), { "-a", "-k", "--topics" })
    t.eq(reg:flags({ "lint" }), {})
    t.eq(reg:flags({ "nope" }), {})
    t.eq(reg:find({ "bad word" }), nil)
end)

t.test("detect_type follows the existing order", function()
    local root = support.tempdir()
    t.eq(project.detect_type(root), nil)
    assert(fs.write(root .. "/Makefile", ""))
    t.eq(project.detect_type(root), "make")
    scripted(root, "src/deep/x.lua", "", "644")
    t.eq(project.detect_type(root), "lua")
    assert(fs.write(root .. "/package.json", "{}"))
    t.eq(project.detect_type(root), "node")
    assert(fs.write(root .. "/project.godot", ""))
    t.eq(project.detect_type(root), "godot")
    assert(fs.write(root .. "/main.lua", ""))
    assert(fs.write(root .. "/conf.lua", ""))
    t.eq(project.detect_type(root), "love2d")
    assert(fs.write(root .. "/Cargo.toml", ""))
    t.eq(project.detect_type(root), "rust")
    fs.remove(root, { recursive = true })
end)

t.test("detect_type ignores Lua files in hidden, node_modules and target directories", function()
    local root = support.tempdir()
    for _, dir in ipairs({ ".hidden", "node_modules", "target" }) do
        scripted(root, dir .. "/x.lua", "", "644")
    end
    scripted(root, ".dot.lua", "", "644")
    t.eq(project.detect_type(root), nil)
    fs.remove(root, { recursive = true })
end)

local function root_from(dir, opts)
    local script = string.format(
        "package.path = %q; %sprint(require('dev.project').root())",
        support.absolute_path(),
        opts.uid0 and "require('dev.os').getuid = function() return 0 end; " or ""
    )
    return devos.capture({ "luajit", "-e", script }, { cwd = dir, env = opts.env })
end

t.test("root finds the nearest .dev from a subdirectory", function()
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev"))
    assert(fs.mkdir(root .. "/sub/deep", { parents = true }))
    t.eq(root_from(root .. "/sub/deep", {}), assert(fs.realpath(root)) .. "\n")
    fs.remove(root, { recursive = true })
end)

t.test("as uid 0, root only tests for .jj, .git and .dev and runs no VCS command", function()
    local root = support.tempdir()
    local bin = support.tempdir()
    local marker = bin .. "/ran"
    scripted(bin, "jj", string.format("#!/bin/sh\ntouch %s\necho /wrong\n", marker))
    scripted(bin, "git", string.format("#!/bin/sh\ntouch %s\necho /wrong\n", marker))
    assert(fs.write(root .. "/.git", ""))
    assert(fs.mkdir(root .. "/sub/deep", { parents = true }))
    local env = { PATH = bin .. ":" .. os.getenv("PATH") }
    t.eq(
        root_from(root .. "/sub/deep", { uid0 = true, env = env }),
        assert(fs.realpath(root)) .. "\n"
    )
    t.eq(fs.exists(marker), false)
    fs.remove(root, { recursive = true })
    fs.remove(bin, { recursive = true })
end)

t.test("dotfile scripts and dot directories are neither verbs nor nouns", function()
    local root = make_project()
    scripted(root, ".dev/.hid.sh", "#!/usr/bin/env bash\n# Hidden file.\n")
    scripted(root, ".dev/.dd/x.sh", "#!/usr/bin/env bash\n# In a dot dir.\n")
    scripted(root, ".dev/n/.dot.sh", "#!/usr/bin/env bash\n# Dot sub.\n")
    local reg = registry.load(root)
    for _, row in ipairs(reg:verbs()) do
        t.ok(row.name:sub(1, 1) ~= ".", "dot name listed as " .. row.name)
    end
    t.eq(reg:find({ "n", ".dot" }), nil)
    t.eq(words(reg:subs("n")), { "n x" })
    fs.remove(root, { recursive = true })
end)

t.test("local verbs come in the order the shell glob gives", function()
    local root = support.tempdir()
    for _, name in ipairs({ "UP", "Up.Case", "a", "B", "b-c", "Zed" }) do
        scripted(root, ".dev/" .. name .. ".sh", "#!/usr/bin/env bash\n# " .. name .. ".\n")
    end
    local want = {}
    local out = devos.capture({ "bash", "-c", "printf '%s\\n' *.sh" }, { cwd = root .. "/.dev" })
    for name in out:gmatch("([^\n]+)%.sh\n") do
        want[#want + 1] = name
    end
    local got = words(registry.load(root):verbs())
    t.eq({ unpack(got, #got - #want + 1) }, want)
    fs.remove(root, { recursive = true })
end)

local function git_repo(root)
    return devos.run({ "git", "init", "-q", root }, { stdout = "null" }) == 0
end

t.test("root asks git for the toplevel when no jj answers", function()
    if not devos.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = support.tempdir()
    assert(git_repo(root), "git init failed")
    assert(fs.mkdir(root .. "/sub/deep", { parents = true }))
    local env = { PATH = "/usr/bin:/bin:" .. fs.dirname(devos.which("git")) }
    t.eq(root_from(root .. "/sub/deep", { env = env }), assert(fs.realpath(root)) .. "\n")
    fs.remove(root, { recursive = true })
end)

t.test("root asks jj for the workspace root first", function()
    if not (devos.which("jj") and devos.which("git")) then
        print("skip - jj or git is not installed")
        return
    end
    local root = support.tempdir()
    assert(
        devos.run({ "jj", "git", "init", root }, { stdout = "null", stderr = "null" }) == 0,
        "jj init failed"
    )
    assert(fs.mkdir(root .. "/sub/deep", { parents = true }))
    t.eq(root_from(root .. "/sub/deep", {}), assert(fs.realpath(root)) .. "\n")
    fs.remove(root, { recursive = true })
end)
