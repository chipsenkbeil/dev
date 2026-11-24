local dev_os = require("@dev/os")
local runtime = require("@dev/runtime")
local fs = require("@dev/fs")

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local failures = 0

local function check(name, body)
    local ok, err = pcall(body)
    if ok then
        print("ok   " .. name)
    else
        failures += 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local function same(actual, expected)
    if actual ~= expected then
        error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
    end
end

local function holds(text, part)
    if not tostring(text):find(part, 1, true) then
        error(string.format("expected %q inside %q", part, tostring(text)), 2)
    end
end

check("require serves a dev module from the embedded tree once", function()
    local text = require("@dev/text")
    same(type(text), "table")
    same(require("@dev/text"), text)
    same(runtime.loaded["@dev/text"], text)
end)

check("require serves a native module ahead of any file", function()
    same(type(dev_os.exit), "function")
    same(require("@dev/os"), dev_os)
    same(type(runtime.load), "function")
end)

check("require names every place tried for a missing module", function()
    local ok, err = pcall(require, "@dev/nope")
    same(ok, false)
    holds(err, "module '@dev/nope' not found")
    holds(err, "no embedded file 'luau/dev/nope.luau'")
    holds(err, "no embedded file 'luau/dev/nope/init.luau'")
end)

check("require refuses a dotted dev name with the @dev form", function()
    local ok, err = pcall(require, "dev.os")
    same(ok, false)
    holds(err, 'The require name "dev.os" is the dotted form, so write "@dev/os".')
end)

check("require refuses a dotted project name with the Luau forms", function()
    local ok, err = pcall(require, "myproj.checks")
    same(ok, false)
    holds(err, '"./myproj/checks"')
    holds(err, '"@lib/myproj/checks"')
    holds(select(2, pcall(require, "flat")), '"./flat"')
end)

check("require loads a ./ path for a file and an init file", function()
    same(require("./fixtures/lib/flat").name, "flat")
    same(require("./fixtures/lib/flat").name, "flat")
    same(_G.flat_loads, 1)
    same(require("./fixtures/lib/demo").name, "demo")
    same(require("./fixtures/../fixtures/lib/flat").name, "flat")
    same(_G.flat_loads, 1)
end)

check("require loads a module through an alias of the nearest .luaurc", function()
    same(require("@fx/flat").name, "flat")
    same(require("@fx/demo").name, "demo")
    same(_G.flat_loads, 1)
    local ok, err = pcall(require, "@nope/flat")
    same(ok, false)
    holds(err, 'defines the alias "@nope"')
end)

check("require resolves an alias from the requiring file, not the start folder", function()
    local root = assert(fs.mktemp({ prefix = "alias", dir = true }))
    assert(fs.mkdir(root .. "/mods", { parents = true }))
    assert(fs.write(root .. "/.luaurc", '{ "aliases": { "lib": "mods" } }\n'))
    assert(fs.write(root .. "/mods/where.luau", 'return { name = "copied tree" }\n'))
    assert(fs.write(root .. "/main.luau", 'print(require("@lib/where").name)\n'))
    local out = dev_os.capture({ runtime.exe, "-l", root .. "/main.luau" }, { cwd = here })
    same(out, "copied tree\n")
    fs.remove(root, { recursive = true })
end)

check("require refuses a module that requires itself", function()
    local ok, err = pcall(require, "./fixtures/lib/loop")
    same(ok, false)
    holds(err, "loop or previous error loading module './loop'")
end)

check("load compiles a chunk, in an environment when given", function()
    same(runtime.load("return 1 + 1", "=sum")(), 2)
    same(runtime.load("return value", "=env", { value = 5 })(), 5)
    local chunk, err = runtime.load("return +", "=broken")
    same(chunk, nil)
    holds(err, "broken:1")
end)

check("dofile runs a file and returns its values", function()
    same(runtime.dofile(here .. "/fixtures/lib/demo/init.luau").name, "demo")
    same((pcall(runtime.dofile, here .. "/fixtures/none.luau")), false)
end)

check("asset reads an embedded file and assets lists a folder", function()
    holds(runtime.asset("docs/flags.md"), "-C")
    same(type(runtime.asset("luau/dev/cli.luau")), "string")
    same(runtime.asset("docs/none.md"), nil)
    local names = runtime.assets("luau/dev")
    same(table.find(names, "cli.luau") ~= nil, true)
    for index = 2, #names do
        same(names[index - 1] < names[index], true)
    end
    same(#runtime.assets("nowhere"), 0)
end)

check("signatures lists each native function with its Luau type", function()
    local found
    for _, entry in runtime.signatures() do
        if entry.module == "os" and entry.name == "exit" then
            found = entry
        end
    end
    same(found.signature, "(code: (number | boolean)?) -> never")
    same(type(found.docs[1]), "string")
end)

check("parse_globals splits the global flags from the command words", function()
    local parsed = runtime.parse_globals({ "--remote", "--job-timeout", "5m", "test", "-vv", "x" })
    same(parsed.remote, true)
    same(parsed.job_timeout, "5m")
    same(parsed.args[1], "test")
    same(parsed.args[2], "x")
    same(parsed.stripped[1].word, "-vv")
end)

check("parse_globals returns nil and the usage message for an unknown flag", function()
    local parsed, message = runtime.parse_globals({ "--nope", "test" })
    same(parsed, nil)
    same(message, "The flag `--nope` is not a global flag of dev.")
end)

check("a native function raises on a wrong argument type", function()
    same((pcall(runtime.load)), false)
    same((pcall(dev_os.on_exit, "not a function")), false)
end)

check("exe names the running binary", function()
    holds(runtime.exe, "dev")
end)

check("chdir enters a folder or returns nil and the reason", function()
    local ok, reason = dev_os.chdir(here .. "/fixtures/none")
    same(ok, nil)
    holds(reason, "failed to enter " .. here .. "/fixtures/none")
    same(dev_os.chdir(here .. "/fixtures/lib"), true)
    same(runtime.dofile("demo/init.luau").name, "demo")
end)

if failures > 0 then
    print(failures .. " failed")
    dev_os.exit(1)
end
