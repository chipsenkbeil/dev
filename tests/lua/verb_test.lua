local t = require("dev.testing")
local devos = require("dev.os")
local support = require("support")

t.test("note writes the message and a newline to standard error", function()
    local script = string.format(
        "package.path = %q; require('dev.verb').note('dev sync: nothing to pull')",
        support.absolute_path()
    )
    local out, code = devos.capture({ "luajit", "-e", script }, { stderr = "stdout" })
    t.eq(code, 0)
    t.eq(out, "dev sync: nothing to pull\n")
end)
