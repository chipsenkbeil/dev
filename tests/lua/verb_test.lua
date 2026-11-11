local testing = require("dev.testing")
local dev_os = require("dev.os")
local support = require("support")

testing.test("note writes the message and a newline to standard error", function()
    local script = string.format(
        "package.path = %q; require('dev.verb').note('dev sync: nothing to pull')",
        support.absolute_path()
    )
    local out, code = dev_os.capture({ "luajit", "-e", script }, { stderr = "stdout" })
    testing.eq(code, 0)
    testing.eq(out, "dev sync: nothing to pull\n")
end)
