local testing = require("@dev/testing")
local fs = require("@dev/fs")
local json = require("@dev/json")
local init = require("@dev/cmd/init")
local support = require("./support")

local function aliases_of(root)
    return json.decode(assert(fs.read(root .. "/.luaurc"))).aliases
end

testing.test("init writes a .luaurc that aliases lib to .dev/lib", function()
    local root = support.tempdir()
    testing.eq(init.write_luaurc(root, false), "created")
    testing.eq(aliases_of(root), { lib = ".dev/lib" })
    fs.remove(root, { recursive = true })
end)

testing.test("init writes nothing on a dry run", function()
    local root = support.tempdir()
    testing.eq(init.write_luaurc(root, true), "created")
    testing.eq(fs.exists(root .. "/.luaurc"), false)
    fs.remove(root, { recursive = true })
end)

testing.test("init merges the lib alias into an existing .luaurc", function()
    local root = support.tempdir()
    assert(fs.write(root .. "/.luaurc", '{ "globals": ["arg"], "aliases": { "other": "x" } }\n'))
    testing.eq(init.write_luaurc(root, false), "created")
    local doc = json.decode(assert(fs.read(root .. "/.luaurc")))
    testing.eq(doc.globals, { "arg" })
    testing.eq(doc.aliases, { other = "x", lib = ".dev/lib" })
    fs.remove(root, { recursive = true })
end)

testing.test("init keeps a lib alias a project already set", function()
    local root = support.tempdir()
    local text = '{ "aliases": { "lib": "src" } }\n'
    assert(fs.write(root .. "/.luaurc", text))
    testing.eq(init.write_luaurc(root, false), "skipped")
    testing.eq(assert(fs.read(root .. "/.luaurc")), text)
    fs.remove(root, { recursive = true })
end)

testing.test("init leaves a .luaurc it cannot read as plain JSON", function()
    local root = support.tempdir()
    local text = '{ // comment\n "aliases": {} }\n'
    assert(fs.write(root .. "/.luaurc", text))
    local outcome, message = init.write_luaurc(root, false)
    testing.eq(outcome, "left")
    testing.ok(message:find("plain JSON", 1, true), message)
    testing.eq(assert(fs.read(root .. "/.luaurc")), text)
    fs.remove(root, { recursive = true })
end)
