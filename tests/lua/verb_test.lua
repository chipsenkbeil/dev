local testing = require("dev.testing")
local dev_os = require("dev.os")
local support = require("support")

testing.test("note writes the message and a newline to standard error", function()
    local script = string.format(
        "package.path = %q; require('dev.command').note('dev sync: nothing to pull')",
        support.absolute_path()
    )
    local out, code = dev_os.capture({ "luajit", "-e", script }, { stderr = "stdout" })
    testing.eq(code, 0)
    testing.eq(out, "dev sync: nothing to pull\n")
end)

local function relayed(text)
    local script = string.format(
        "package.path = %q; require('dev.command').relay(%q)",
        support.absolute_path(),
        text
    )
    return dev_os.capture({ "luajit", "-e", script })
end

testing.test("relay writes nothing for an empty text", function()
    local out, code = relayed("")
    testing.eq(code, 0)
    testing.eq(out, "")
end)

testing.test("relay drops one trailing newline and adds the newline say writes", function()
    testing.eq((relayed("one\n")), "one\n")
    testing.eq((relayed("plain")), "plain\n")
end)

testing.test("relay keeps the second of two trailing newlines", function()
    testing.eq((relayed("two\n\n")), "two\n\n")
end)

testing.test("no_args refuses a stray argument with one message", function()
    local script = string.format(
        "package.path = %q; require('dev.command').no_args({ name = 'lint', args = { 'extra' } })",
        support.absolute_path()
    )
    local out, code = dev_os.capture({ "luajit", "-e", script }, { stderr = "stdout" })
    testing.eq(code, 2)
    testing.eq(out, "dev lint: Unknown argument extra. This verb takes no positional arguments.\n")
end)

testing.test("say writes the message and a newline to standard output", function()
    local script = string.format(
        "package.path = %q; require('dev.command').say('dev sync: nothing to pull')",
        support.absolute_path()
    )
    local out, code = dev_os.capture({ "luajit", "-e", script })
    testing.eq(code, 0)
    testing.eq(out, "dev sync: nothing to pull\n")
end)
