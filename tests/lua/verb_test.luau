local testing = require("dev.testing")
local dev_os = require("dev.os")
local support = require("support")

local function eval(code)
    return dev_os.capture(support.eval(code), { stderr = "stdout" })
end

testing.test("note writes the message and a newline to standard error", function()
    local out, code = eval("require('dev.command').note('dev sync: nothing to pull')")
    testing.eq(code, 0)
    testing.eq(out, "dev sync: nothing to pull\n")
end)

testing.test("relay writes nothing for an empty text", function()
    local out, code = eval("require('dev.command').relay('')")
    testing.eq(code, 0)
    testing.eq(out, "")
end)

testing.test("relay drops one trailing newline and adds the newline say writes", function()
    testing.eq((eval("require('dev.command').relay('one\\n')")), "one\n")
    testing.eq((eval("require('dev.command').relay('plain')")), "plain\n")
end)

testing.test("relay keeps the second of two trailing newlines", function()
    testing.eq((eval("require('dev.command').relay('two\\n\\n')")), "two\n\n")
end)

testing.test("no_args refuses a stray argument with one message", function()
    local out, code = eval("require('dev.command').no_args({ name = 'lint', argv = { 'extra' } })")
    testing.eq(code, 2)
    testing.eq(
        out,
        "dev lint: Unknown argument extra. This command takes no positional arguments.\n"
    )
end)

testing.test("say writes the message and a newline to standard output", function()
    local out, code = eval("require('dev.command').say('dev sync: nothing to pull')")
    testing.eq(code, 0)
    testing.eq(out, "dev sync: nothing to pull\n")
end)

testing.test("calling dev.command checks the spec and names a wrong field", function()
    local out, code = eval("require('dev.command')({ colour = 1, run = function() end })")
    testing.ok(code ~= 0)
    testing.ok(out:find("`colour`", 1, true), out)
end)

testing.test("load returns the reserved flag code for a spec that declares -h", function()
    local fs = require("dev.fs")
    local testenv = require("dev.testenv")
    local dev_command = require("dev.command")
    local spec_check = require("dev.spec")
    local path = testenv.tempdir() .. "/a.luau"
    assert(fs.write(
        path,
        table.concat({
            'local dev_command = require("dev.command")',
            "return dev_command({",
            '    summary = "Do a thing",',
            '    flags = { { name = "x", short = "h", kind = "boolean", help = "X" } },',
            "    run = function() end,",
            "})",
            "",
        }, "\n")
    ))
    local spec, reason, code = dev_command.load(path)
    testing.eq(spec, nil)
    testing.ok(reason, "load names why the spec is refused")
    testing.eq(code, spec_check.Reason.RESERVED_FLAG)
end)
