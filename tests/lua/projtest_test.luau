local testing = require("@dev/testing")
local testenv = require("@dev/testenv")
local dev_os = require("@dev/os")
local dev_project = require("@dev/project")
local fs = require("@dev/fs")
local runtime = require("@dev/runtime")

local ENV = { CI = "true", DEV_REMOTE = "0" }
local TEST_COMMAND = table.concat({
    'local dev_command = require("@dev/command")',
    "return dev_command({",
    '    summary = "Run the tests",',
    "    run = function(_, _, ctx)",
    '        return require("@dev/testrun").run(ctx.root)',
    "    end,",
    "})",
    "",
}, "\n")
local TEST_HEADER = 'local t = require("@dev/testing")\n'

local function project(tests)
    local root = assert(fs.realpath(testenv.project()))
    assert(fs.mkdir(root .. "/.dev/commands", { parents = true }))
    assert(fs.write(root .. "/.dev/commands/test.luau", TEST_COMMAND))
    if tests then
        assert(fs.mkdir(root .. "/.dev/tests", { parents = true }))
        for name, body in pairs(tests) do
            assert(fs.write(root .. "/.dev/tests/" .. name, TEST_HEADER .. body))
        end
    end
    return root
end

local function run(root)
    return testenv.command(root, { "test" }, { env = ENV })
end

testing.test("a passing .dev/tests file runs and dev test exits 0", function()
    local root = project({ ["a_test.luau"] = 't.test("adds", function() t.eq(1 + 1, 2) end)\n' })
    local out, code, err = run(root)
    testing.eq(code, 0, err)
    testing.ok(out:find("ok - adds", 1, true), out)
end)

testing.test("a failing case prints not ok with its message and dev test exits 1", function()
    local root = project({
        ["a_test.luau"] = table.concat({
            't.test("breaks", function() error("boom here") end)',
            't.test("fine", function() end)',
            "",
        }, "\n"),
    })
    local out, code = run(root)
    testing.eq(code, 1)
    testing.ok(out:find("not ok - breaks", 1, true), out)
    testing.ok(out:find("boom here", 1, true), out)
    testing.ok(out:find("ok - fine", 1, true), out)
end)

testing.test("a test file that fails to load fails the run", function()
    local root = project({ ["a_test.luau"] = "this is not lua (\n" })
    local out, code = run(root)
    testing.eq(code, 1)
    testing.ok(out:find("not ok - load a_test.luau", 1, true), out)
end)

testing.test("no .dev/tests prints SKIP and exits 0", function()
    local out, code, err = run(project())
    testing.eq(code, 0, err)
    testing.ok(out:find("SKIP .dev/tests (none)", 1, true), out)
end)

testing.test(
    "testenv.fake puts a command on PATH and command returns its exit code and stderr",
    function()
        -- Fake a failing tool and a command that runs it
        local root = project()
        testenv.fake(root, "tool", { code = 3, out = "hello", err = "oops" })
        local probe = table.concat({
            'local dev_command = require("@dev/command")',
            "return dev_command({",
            '    summary = "Run the tool",',
            "    run = function()",
            '        return require("@dev/os").run({ "tool", "a", "b" })',
            "    end,",
            "})",
            "",
        }, "\n")
        assert(fs.write(root .. "/.dev/commands/probe.luau", probe))

        -- Run the command
        local out, code, err = testenv.command(root, { "probe" }, { env = ENV })

        -- Check the exit code, the output streams and the recorded call
        testing.eq(code, 3)
        testing.ok(out:find("hello", 1, true), out)
        testing.ok(err:find("oops", 1, true), err)
        testing.eq(testenv.calls(root, "tool"), { "a b" })
    end
)

testing.test("the files run in sorted order", function()
    local root = project({
        ["b_test.luau"] = 't.test("second", function() end)\n',
        ["a_test.luau"] = 't.test("first", function() end)\n',
    })
    local out, code, err = run(root)
    testing.eq(code, 0, err)
    testing.ok(out:find(table.concat({ "ok - first", "ok - second", "" }, "\n"), 1, true), out)
end)

testing.test("testenv.project makes an @lib require resolve", function()
    local root = assert(fs.realpath(testenv.project()))
    assert(fs.mkdir(root .. "/.dev/lib", { parents = true }))
    assert(fs.write(root .. "/.dev/lib/answer.luau", "return 42\n"))
    local script = root .. "/probe.luau"
    assert(fs.write(script, 'print(require("@lib/answer"))\n'))
    local out, code, err = dev_os.capture({ runtime.exe, "-l", script }, { cwd = root })
    testing.eq(code, 0, err)
    testing.eq(out, "42\n")
end)

testing.test("testenv.project copies the project root's .luaurc", function()
    local root = assert(fs.realpath(testenv.project()))
    local expected = assert(fs.read(dev_project.root() .. "/.luaurc"))
    testing.eq(fs.read(root .. "/.luaurc"), expected)
end)

testing.test("a dev -l script that ran its own cases is not run a second time", function()
    -- Write a script that registers a case and runs its own cases
    local dir = assert(fs.realpath(testenv.tempdir()))
    local script = dir .. "/own_run.luau"
    assert(fs.write(
        script,
        table.concat({
            'local t = require("@dev/testing")',
            't.test("once", function() print("body ran") end)',
            'require("@dev/testrun").execute(0)',
            "",
        }, "\n")
    ))

    -- Run it
    local out, code = dev_os.capture({ runtime.exe, "-l", script })
    testing.eq(code, 0)

    -- Check the case body ran once
    testing.eq(out, table.concat({ "body ran", "ok - once", "" }, "\n"))
end)
