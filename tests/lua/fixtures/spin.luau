local dev_os = require("dev.os")
local runtime = require("dev.runtime")

runtime.dofile(arg[0]:match("^(.*)/fixtures/[^/]*$") .. "/boot.luau")

local ui = require("dev.ui")

dev_os.exit(ui.spin(ui.context(), "Working", { table.unpack(arg) }))
