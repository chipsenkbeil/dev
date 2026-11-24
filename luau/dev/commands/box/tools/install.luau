local box = require("dev.cmd.box")
local dev_command = require("dev.command")

return dev_command({
    summary = "Reinstall a running box's tools",
    group = "Boxes",
    remote = false,
    args = {
        { name = "box", complete = "box" },
        { name = "rest", list = true },
    },
    run = box.tools_install,
})
