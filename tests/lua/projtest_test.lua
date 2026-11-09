local testing = require("dev.testing")
local testenv = require("dev.testenv")
local fs = require("dev.fs")

local ENV = { CI = "true", DEV_REMOTE = "0" }
local TEST_VERB = 'local ctx = ...\nreturn require("dev.testrun").run(ctx.root)\n'
local TEST_HEADER = 'local t = require("dev.testing")\n'

local function project(tests)
    local root = assert(fs.realpath(testenv.tempdir()))
    assert(fs.mkdir(root .. "/.dev", { parents = true }))
    assert(fs.write(root .. "/.dev/test.lua", TEST_VERB))
    if tests then
        assert(fs.mkdir(root .. "/.dev/tests", { parents = true }))
        for name, body in pairs(tests) do
            assert(fs.write(root .. "/.dev/tests/" .. name, TEST_HEADER .. body))
        end
    end
    return root
end

local function run(root)
    return testenv.verb(root, { "test" }, { env = ENV })
end

testing.test("a passing .dev/tests file runs and dev test exits 0", function()
    local root = project({ ["a_test.lua"] = 't.test("adds", function() t.eq(1 + 1, 2) end)\n' })
    local out, code, err = run(root)
    testing.eq(code, 0, err)
    testing.ok(out:find("ok - adds", 1, true), out)
end)

testing.test("a failing case prints not ok with its message and dev test exits 1", function()
    local root = project({
        ["a_test.lua"] = 't.test("breaks", function() error("boom here") end)\n'
            .. 't.test("fine", function() end)\n',
    })
    local out, code = run(root)
    testing.eq(code, 1)
    testing.ok(out:find("not ok - breaks", 1, true), out)
    testing.ok(out:find("boom here", 1, true), out)
    testing.ok(out:find("ok - fine", 1, true), out)
end)

testing.test("a test file that fails to load fails the run", function()
    local root = project({ ["a_test.lua"] = "this is not lua (\n" })
    local out, code = run(root)
    testing.eq(code, 1)
    testing.ok(out:find("not ok - load a_test.lua", 1, true), out)
end)

testing.test("no .dev/tests prints SKIP and exits 0", function()
    local out, code, err = run(project())
    testing.eq(code, 0, err)
    testing.ok(out:find("SKIP .dev/tests (none)", 1, true), out)
end)

testing.test(
    "testenv.fake puts a command on PATH and verb returns its exit code and stderr",
    function()
        local root = project()
        testenv.fake(root, "tool", { code = 3, out = "hello", err = "oops" })
        local probe = 'return require("dev.os").run({ "tool", "a", "b" })\n'
        assert(fs.write(root .. "/.dev/probe.lua", probe))
        local out, code, err = testenv.verb(root, { "probe" }, { env = ENV })
        testing.eq(code, 3)
        testing.ok(out:find("hello", 1, true), out)
        testing.ok(err:find("oops", 1, true), err)
        testing.eq(testenv.calls(root, "tool"), { "a b" })
    end
)

testing.test("the files run in sorted order", function()
    local root = project({
        ["b_test.lua"] = 't.test("second", function() end)\n',
        ["a_test.lua"] = 't.test("first", function() end)\n',
    })
    local out, code, err = run(root)
    testing.eq(code, 0, err)
    testing.ok(out:find("ok - first\nok - second\n", 1, true), out)
end)
