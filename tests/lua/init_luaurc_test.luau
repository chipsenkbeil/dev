local testing = require("@dev/testing")
local fs = require("@dev/fs")
local json = require("@dev/json")
local init = require("@dev/cmd/init")
local support = require("./support")

local function aliases_of(root)
    return json.decode(assert(fs.read(root .. "/.luaurc"))).aliases
end

testing.test("init writes a .luaurc that aliases lib to .dev/lib", function()
    -- Write the file into an empty directory
    local root = support.tempdir()
    testing.eq(init.write_luaurc(root, false), "created")

    -- Alias lib to .dev/lib
    testing.eq(aliases_of(root), { lib = ".dev/lib" })

    -- Remove the directory
    fs.remove(root, { recursive = true })
end)

testing.test("init writes nothing on a dry run", function()
    -- Write the file on a dry run
    local root = support.tempdir()
    testing.eq(init.write_luaurc(root, true), "created")

    -- Leave no file behind
    testing.eq(fs.exists(root .. "/.luaurc"), false)

    -- Remove the directory
    fs.remove(root, { recursive = true })
end)

testing.test("init merges the lib alias into an existing .luaurc", function()
    -- Start from a file with its own globals and aliases
    local root = support.tempdir()
    assert(fs.write(root .. "/.luaurc", '{ "globals": ["arg"], "aliases": { "other": "x" } }\n'))

    -- Write the file
    testing.eq(init.write_luaurc(root, false), "created")

    -- Keep what was there and add the lib alias
    local doc = json.decode(assert(fs.read(root .. "/.luaurc")))
    testing.eq(doc.globals, { "arg" })
    testing.eq(doc.aliases, { other = "x", lib = ".dev/lib" })

    -- Remove the directory
    fs.remove(root, { recursive = true })
end)

testing.test("init keeps a lib alias a project already set", function()
    -- Start from a file that sets the lib alias
    local root = support.tempdir()
    local text = '{ "aliases": { "lib": "src" } }\n'
    assert(fs.write(root .. "/.luaurc", text))

    -- Write the file and skip it
    testing.eq(init.write_luaurc(root, false), "skipped")

    -- Leave the file as it was
    testing.eq(assert(fs.read(root .. "/.luaurc")), text)

    -- Remove the directory
    fs.remove(root, { recursive = true })
end)

testing.test("init leaves a .luaurc it cannot read as plain JSON", function()
    -- Start from a file with a comment in it
    local root = support.tempdir()
    local text = table.concat({ "{ // comment", ' "aliases": {} }', "" }, "\n")
    assert(fs.write(root .. "/.luaurc", text))

    -- Write the file and leave it
    local outcome, message = init.write_luaurc(root, false)
    testing.eq(outcome, "left")
    testing.ok(message:find("plain JSON", 1, true), message)

    -- Leave the file as it was
    testing.eq(assert(fs.read(root .. "/.luaurc")), text)

    -- Remove the directory
    fs.remove(root, { recursive = true })
end)
