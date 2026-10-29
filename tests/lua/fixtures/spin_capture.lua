dofile(arg[0]:match("^(.*)/fixtures/[^/]*$") .. "/boot.lua")

local ui = require("dev.ui")

local code, out = ui.spin(ui.context(), "Working", { unpack(arg) }, { capture = true })
print("[" .. out .. "]")
os.exit(code)
