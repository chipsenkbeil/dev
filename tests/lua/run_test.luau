local testing = require("dev.testing")
local dev_os = require("dev.os")
local runtime = require("dev.runtime")
local FIXTURE = "tests/lua/fixtures/runner_cases.luau"

local function run(name)
    return dev_os.capture(
        { runtime.exe, "-l", "tests/lua/run.luau", FIXTURE, name },
        { stderr = "stdout" }
    )
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
