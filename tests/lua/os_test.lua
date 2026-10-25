local t = require("testing")
local devos = require("dev.os")

t.test("quote wraps in single quotes and escapes embedded ones", function()
    t.eq(devos.quote("it's"), [['it'\''s']])
    t.eq(devos.quote(""), "''")
end)

t.test("quote refuses a NUL byte", function()
    t.raises(function()
        devos.quote("a\0b")
    end, "NUL")
end)

t.test("command joins the quoted words", function()
    t.eq(devos.command({ "echo", "a b", "it's" }), [['echo' 'a b' 'it'\''s']])
end)

t.test("capture passes hostile text through unchanged", function()
    local out, code = devos.capture({ "printf", "%s", "a b;$(id)'\"`" })
    t.eq(out, "a b;$(id)'\"`")
    t.eq(code, 0)
end)

t.test("capture keeps trailing newlines", function()
    local out = devos.capture({ "printf", "a\n\n" })
    t.eq(out, "a\n\n")
end)

t.test("capture returns the exit code", function()
    t.eq(select(2, devos.capture({ "sh", "-c", "exit 3" })), 3)
end)

t.test("run returns the exit code", function()
    t.eq(devos.run({ "sh", "-c", "exit 7" }), 7)
    t.eq(devos.run({ "true" }), 0)
end)

t.test("run reports a signal death as 128 plus the signal", function()
    t.eq(devos.run({ "sh", "-c", "kill -TERM $$" }), 143)
end)

t.test("which finds a tool or returns nil", function()
    local path = devos.which("sh")
    t.ok(path and path:sub(1, 1) == "/", "sh should resolve to an absolute path")
    t.eq(devos.which("no-such-tool-xyz"), nil)
end)

t.test("getuid matches id -u", function()
    local out = devos.capture({ "id", "-u" })
    t.eq(devos.getuid(), tonumber(out))
end)

t.test("isatty is false for stdin from /dev/null", function()
    local snippet = ("package.path = %q; "):format(package.path)
        .. 'io.write(tostring(require("dev.os").isatty(0)))'
    local out = devos.capture({ "sh", "-c", [[luajit -e "$1" </dev/null]], "sh", snippet })
    t.eq(out, "false")
end)

t.test("exec returns nil and a message on failure", function()
    local res, err = devos.exec({ "no-such-tool-xyz" })
    t.eq(res, nil)
    t.ok(type(err) == "string" and err ~= "", "expected an error message")
end)

t.test("run returns 127 for a missing tool", function()
    t.eq(devos.run({ "no-such-tool-xyz" }), 127)
end)

t.test("capture passes a newline and a leading dash through", function()
    local out = devos.capture({ "printf", "%s", "-x\ny" })
    t.eq(out, "-x\ny")
end)

t.test("run and capture flush Lua output before the child writes", function()
    local snippet = ("package.path = %q; local o = require('dev.os'); "):format(package.path)
        .. "io.write('a'); o.run({'printf', 'b'}); io.write('c'); "
        .. "local out = o.capture({'printf', 'd'}); io.write(out)"
    local out = devos.capture({ "sh", "-c", [[luajit -e "$1" | cat]], "sh", snippet })
    t.eq(out, "abcd")
end)
