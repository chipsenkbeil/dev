local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local function tree(project, user)
    local root = support.tempdir()
    local home = support.tempdir()
    if project then
        assert(fs.mkdir(root .. "/.dev", { parents = true }))
        assert(fs.write(root .. "/.dev/config.toml", project))
    end
    if user then
        assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
        assert(fs.write(home .. "/.config/dev/config.toml", user))
    end
    return root, home
end

local function get(root, home, key)
    local script = string.format(
        "package.path = %q; local v = require('dev.config').get(%q, %q); io.write(type(v), ':', tostring(v))",
        support.absolute_path(),
        root,
        key
    )
    local out, code = devos.capture(
        { "luajit", "-e", script },
        { stderr = "stdout", env = { HOME = home } }
    )
    return out, code
end

t.test("get reads the user file", function()
    local root, home = tree(nil, '[remote]\nrunner = "ci"\n')
    t.eq(get(root, home, "remote.runner"), "string:ci")
    t.eq(get(root, home, "remote.other"), "nil:nil")
    t.eq(get(root, home, "remote.runner.deeper"), "nil:nil")
end)

t.test("a project value beats the user value and the rest falls through", function()
    local root, home = tree('[remote]\nrunner = "mine"\n', '[remote]\nrunner = "ci"\nother = 2\n')
    t.eq(get(root, home, "remote.runner"), "string:mine")
    t.eq(get(root, home, "remote.other"), "number:2")
end)

t.test("a project false still beats the user value", function()
    local root, home = tree("flag = false\n", "flag = true\n")
    t.eq(get(root, home, "flag"), "boolean:false")
end)

t.test("get reads a nested table across the two files", function()
    local root, home = tree(
        '[board]\nbackend = "pomb"\nname = "dotfiles"\n',
        '[board.pomb]\nurl = "https://x"\ntoken = "pass:Agents/t"\n'
    )
    t.eq(get(root, home, "board.backend"), "string:pomb")
    t.eq(get(root, home, "board.pomb.url"), "string:https://x")
    t.eq(get(root, home, "board.pomb.token"), "string:pass:Agents/t")
end)

t.test("get is nil with no files", function()
    local root, home = tree()
    t.eq(get(root, home, "remote.runner"), "nil:nil")
end)

t.test("get ends with the path, line and exit 1 for a malformed project file", function()
    local root, home = tree("a = 1\nb = {c = 1}\n", nil)
    local out, code = get(root, home, "a")
    t.eq(code, 1)
    t.ok(out:find("dev: " .. root .. "/.dev/config.toml:2: inline tables", 1, true), out)
end)

t.test("get validates the user file even when the project sets the key", function()
    local root, home = tree("x = 1\n", "x = {}\n")
    local out, code = get(root, home, "x")
    t.eq(code, 1)
    t.ok(out:find(home .. "/.config/dev/config.toml:1: inline tables", 1, true), out)
end)
