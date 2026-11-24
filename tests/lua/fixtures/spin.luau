local dev_os = require("@dev/os")

local ui = require("@dev/ui")

dev_os.exit(ui.spin(ui.context(), "Working", { table.unpack(arg) }))
