dofile(arg[0]:match("^(.*)/fixtures/[^/]*$") .. "/boot.lua")

local ui = require("dev.ui")

local yes = ui.confirm(ui.context(), "Delete box?", "Its projects are archived first.")
os.exit(yes and 0 or 1)
