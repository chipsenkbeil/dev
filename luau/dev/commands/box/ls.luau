local box = require("dev.cmd.box")
local dev_command = require("dev.command")

return dev_command({
    summary = "Show the room on each machine and the boxes",
    group = "Boxes",
    remote = false,
    flags = {
        { name = "all", kind = "boolean", help = "Include every box" },
        { name = "json", kind = "boolean", help = "Print the ci document" },
    },
    run = box.ls,
})
