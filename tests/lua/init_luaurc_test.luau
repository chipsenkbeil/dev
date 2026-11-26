local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local json = require("@dev/json")
local init = require("@dev/cmd/init")
local support = require("./support")

local function aliases_of(root)
    return json.decode(assert(fs.read(root .. "/.luaurc"))).aliases
end

testing.test("init writes a .luaurc that aliases lib and dev", function()
    -- Write the file into an empty directory
    local root = support.tempdir()
    testing.eq(init.write_luaurc(root, false), "created")

    -- Alias lib to ./.dev/lib
    testing.eq(aliases_of(root), { lib = "./.dev/lib", dev = "./.dev/types" })

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

testing.test("init merges the lib and dev aliases into an existing .luaurc", function()
    -- Start from a file with its own globals and aliases
    local root = support.tempdir()
    assert(fs.write(root .. "/.luaurc", '{ "globals": ["arg"], "aliases": { "other": "x" } }\n'))

    -- Write the file
    testing.eq(init.write_luaurc(root, false), "created")

    -- Keep what was there and add the two aliases
    local doc = json.decode(assert(fs.read(root .. "/.luaurc")))
    testing.eq(doc.globals, { "arg" })
    testing.eq(doc.aliases, { other = "x", lib = "./.dev/lib", dev = "./.dev/types" })

    -- Remove the directory
    fs.remove(root, { recursive = true })
end)

testing.test("init keeps a lib alias a project already set and adds dev", function()
    -- Start from a file that sets the lib alias
    local root = support.tempdir()
    assert(fs.write(root .. "/.luaurc", '{ "aliases": { "lib": "src" } }\n'))

    -- Write the file
    testing.eq(init.write_luaurc(root, false), "created")

    -- Keep the lib alias as it was
    testing.eq(aliases_of(root), { lib = "src", dev = "./.dev/types" })

    -- Remove the directory
    fs.remove(root, { recursive = true })
end)

testing.test("init keeps a lib alias of .dev/lib a project already set", function()
    -- Start from a file that sets the lib alias without the leading ./
    local root = support.tempdir()
    assert(fs.write(root .. "/.luaurc", '{ "aliases": { "lib": ".dev/lib" } }\n'))

    -- Write the file
    testing.eq(init.write_luaurc(root, false), "created")

    -- Keep the lib alias as it was
    testing.eq(aliases_of(root), { lib = ".dev/lib", dev = "./.dev/types" })

    -- Remove the directory
    fs.remove(root, { recursive = true })
end)

if dev_os.which("luau-analyze") then
    testing.test(
        "a strict file requiring @lib/x type-checks clean under the init .luaurc",
        function()
            -- Write the init .luaurc, a library module and a strict file that requires it
            local root = support.tempdir()
            testing.eq(init.write_luaurc(root, false), "created")
            assert(fs.mkdir(root .. "/.dev/lib", { parents = true }))
            assert(fs.write(root .. "/.dev/lib/x.luau", "return { n = 1 }\n"))
            local source = table.concat({
                "--!strict",
                'local x = require("@lib/x")',
                "local n: number = x.n",
                "return n",
                "",
            }, "\n")
            assert(fs.write(root .. "/a.luau", source))

            -- Expect no finding
            local out, code = dev_os.capture(
                { "luau-analyze", "a.luau" },
                { cwd = root, stderr = "stdout" }
            )
            testing.eq({ out, code }, { "", 0 })

            -- Remove the directory
            fs.remove(root, { recursive = true })
        end
    )
end

testing.test("init skips a .luaurc that sets both aliases", function()
    -- Start from a file that sets both aliases
    local root = support.tempdir()
    local text = '{ "aliases": { "lib": "src", "dev": "types" } }\n'
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

testing.test("init dies when the config it would add a board section to does not parse", function()
    -- Start from a jj project whose config is not TOML
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.jj"))
    assert(fs.mkdir(root .. "/.dev"))
    local text = "[board\n"
    assert(fs.write(root .. "/.dev/config.toml", text))

    -- Run init on it
    local script = string.format(
        "require('@dev/cmd/init').run({ name = 'demo' }, { root = %q, verbose = 0 })",
        root
    )
    local out, code = dev_os.capture(support.eval(script), { stderr = "stdout" })

    -- Expect the failure and a config left as it was
    testing.eq(code, 1)
    testing.ok(out:find("Cannot write .dev/config.toml.", 1, true), out)
    testing.eq(assert(fs.read(root .. "/.dev/config.toml")), text)

    -- Remove the directory
    fs.remove(root, { recursive = true })
end)
