local dev_os = require("@dev/os")

local ui = require("@dev/ui")

local code, out = ui.spin(ui.context(), "Working", { table.unpack(arg) }, { capture = true })
print("[" .. out .. "]")
dev_os.exit(code)
