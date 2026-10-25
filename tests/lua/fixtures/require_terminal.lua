dofile(arg[0]:match("^(.*)/fixtures/[^/]*$") .. "/boot.lua")

local ui = require("dev.ui")
ui.require_terminal(ui.context(), { command = "dev connect", missing = "box", hint = "a box name" })
io.write("reached\n")
