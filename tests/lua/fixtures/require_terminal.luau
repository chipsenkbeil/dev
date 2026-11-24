local dev_os = require("dev.os")
local runtime = require("dev.runtime")

runtime.dofile(arg[0]:match("^(.*)/fixtures/[^/]*$") .. "/boot.luau")

local ui = require("dev.ui")
ui.require_terminal(ui.context(), { command = "dev connect", missing = "box", hint = "a box name" })
dev_os.stdout:write("reached\n")
