dofile(arg[0]:match("^(.*)/fixtures/[^/]*$") .. "/boot.lua")

local ui = require("dev.ui")

os.exit(ui.spin(ui.context(), "Working", { unpack(arg) }))
