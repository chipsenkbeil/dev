local dev_os = require("@dev/os")

local ui = require("@dev/ui")

local yes =
    ui.confirm(ui.context(), arg[1] or "Delete box?", arg[2] or "Its projects are archived first.")
dev_os.exit(yes and 0 or 1)
