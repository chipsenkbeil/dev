local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local json = require("@dev/json")
local runtime = require("@dev/runtime")
local luautypes = require("@dev/luautypes")
local support = require("./support")

---The native modules a declaration file is written for, by name
local MODULES = {
    runtime = runtime,
    globals = require("@dev/globals"),
    log = require("@dev/log"),
    os = dev_os,
    fs = fs,
    lock = require("@dev/lock"),
    hash = require("@dev/hash"),
    http = require("@dev/http"),
    json = json,
    toml = require("@dev/toml"),
    manifest = require("@dev/manifest"),
    term = require("@dev/term"),
    spec = require("@dev/spec"),
}

local NATIVE = {}
for name in pairs(MODULES) do
    NATIVE[#NATIVE + 1] = name
end
table.sort(NATIVE)

local function native_modules(): { string }
    local found = {}
    for _, entry in runtime.signatures() do
        if entry.module:find("^%l") and not table.find(found, entry.module) then
            found[#found + 1] = entry.module
        end
    end
    table.sort(found)
    return found
end

testing.test("the declarations hold each embedded Luau module as it is", function()
    local files = luautypes.files()
    testing.eq(files["command.luau"], runtime.asset("luau/dev/command.luau"))
    testing.eq(files["ui/picker.luau"], runtime.asset("luau/dev/ui/picker.luau"))
    testing.eq(files["commands/fmt.luau"], nil)
end)

testing.test("a module beside a folder of its name is written as that folder's init", function()
    local files = luautypes.files()
    testing.eq(files["ui/init.luau"], runtime.asset("luau/dev/ui.luau"))
    testing.eq(files["ui.luau"], nil)
    testing.eq(files["board/init.luau"], runtime.asset("luau/dev/board.luau"))
end)

testing.test("the declarations refuse a folder that holds files dev did not write", function()
    -- Write into a folder that holds a file of its own
    local root = support.tempdir()
    assert(fs.write(`{root}/mine.luau`, "return {}\n"))
    local changed, reason = luautypes.write(root)

    -- Expect the refusal and the file left alone
    testing.eq(changed, nil)
    testing.ok(reason and reason:find("did not write", 1, true), tostring(reason))
    testing.eq(fs.read(`{root}/mine.luau`), "return {}\n")

    -- Remove the directory
    fs.remove(root, { recursive = true })
end)

testing.test("the declarations hold a file for each native module", function()
    local files = luautypes.files()
    for _, name in NATIVE do
        testing.ok(files[`{name}.luau`], `no declaration file for {name}`)
    end
    testing.eq(native_modules(), NATIVE)
end)

testing.test("every function of a native module carries a signature", function()
    local signed: { [string]: { [string]: boolean } } = {}
    for _, entry in runtime.signatures() do
        signed[entry.module] = signed[entry.module] or {}
        signed[entry.module][entry.name] = true
        testing.ok(entry.signature ~= "", `{entry.module}.{entry.name} has an empty signature`)
    end
    for _, name in NATIVE do
        for key in pairs(MODULES[name]) do
            testing.ok((signed[name] or {})[key], `dev.{name}.{key} carries no signature`)
        end
    end
end)

testing.test("the declarations write a missing folder, then change nothing", function()
    -- Write into a folder that does not exist yet
    local root = support.tempdir()
    local dest = `{root}/.dev/types`
    local changed = luautypes.write(dest)
    testing.ok(changed and changed > 0, "the first write wrote nothing")

    -- Hold the folder out of version control and the style lints
    testing.eq(fs.read(`{dest}/.gitignore`), "*\n")
    testing.ok(json.decode(assert(fs.read(`{dest}/.luaurc`))).lint, "no lint setting")

    -- Write again and find nothing to change
    testing.eq(luautypes.write(dest), 0)

    -- Change a file, add one dev does not write, and write again
    assert(fs.write(`{dest}/os.luau`, "return {}\n"))
    assert(fs.write(`{dest}/stale.luau`, "return {}\n"))
    testing.eq(luautypes.write(dest), 2)
    testing.eq(fs.exists(`{dest}/stale.luau`), false)
    testing.eq(fs.read(`{dest}/os.luau`), luautypes.files()["os.luau"])

    -- Remove the directory
    fs.remove(root, { recursive = true })
end)

local function project(): string
    local root = support.tempdir()
    assert(luautypes.write(`{root}/{luautypes.FOLDER}`))
    local doc = { aliases = { dev = luautypes.ALIAS }, lint = { ["*"] = false } }
    assert(fs.write(`{root}/.luaurc`, assert(json.encode(doc))))
    return root
end

local function analyze(root: string, ...: string): (string, number)
    return dev_os.capture({ "luau-analyze", ... }, { cwd = root, stderr = "stdout" })
end

if dev_os.which("luau-analyze") then
    testing.test(
        "a strict file that requires @dev/os and @dev/command type-checks clean",
        function()
            -- Write a strict file that calls both modules the right way
            local root = project()
            local source = table.concat({
                "--!strict",
                'local dev_os = require("@dev/os")',
                'local dev_command = require("@dev/command")',
                'local code: number = dev_os.run({ "true" })',
                "dev_os.stdout:write(tostring(code))",
                "return dev_command",
                "",
            }, "\n")
            assert(fs.write(`{root}/ok.luau`, source))

            -- Expect no finding
            local out, code = analyze(root, "ok.luau")
            testing.eq({ out, code }, { "", 0 })

            -- Remove the directory
            fs.remove(root, { recursive = true })
        end
    )

    testing.test("luau-analyze reports a wrong call to a native function", function()
        -- Write a strict file that passes a number where run takes a list of words
        local root = project()
        local source = table.concat({
            "--!strict",
            'local dev_os = require("@dev/os")',
            "dev_os.run(42)",
            "",
        }, "\n")
        assert(fs.write(`{root}/bad.luau`, source))

        -- Expect the call named as a type error
        local out, code = analyze(root, "bad.luau")
        testing.eq(code, 1)
        testing.ok(out:find("bad.luau(3,", 1, true), out)
        testing.ok(out:find("TypeError", 1, true), out)

        -- Remove the directory
        fs.remove(root, { recursive = true })
    end)

    testing.test(
        "luau-analyze reads every generated native declaration without a finding",
        function()
            -- Analyze the file of each native module
            local root = project()
            local argv = {}
            for _, name in NATIVE do
                argv[#argv + 1] = `{luautypes.FOLDER}/{name}.luau`
            end
            local out, code = analyze(root, table.unpack(argv))

            -- Expect no finding
            testing.eq({ out, code }, { "", 0 })

            -- Remove the directory
            fs.remove(root, { recursive = true })
        end
    )
end
