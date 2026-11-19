local testing = require("dev.testing")
local dev_os = require("dev.os")

local LUAJIT = assert(dev_os.which("luajit"))
local FIXTURE = "tests/lua/fixtures/runner_cases.lua"

local function run(name)
    return dev_os.capture({ LUAJIT, "tests/lua/run.lua", FIXTURE, name }, { stderr = "stdout" })
end

testing.test("the runner keeps only the cases whose name contains the filter", function()
    local out, code = run("alpha")
    testing.eq(code, 0, out)
    testing.ok(out:find("ok - alpha case", 1, true), out)
    testing.ok(not out:find("beta case", 1, true), out)
end)

testing.test("the runner runs no case for a name that matches nothing", function()
    local out, code = run("no such case")
    testing.eq(code, 0, out)
    testing.ok(not out:find("ok - ", 1, true), out)
end)
