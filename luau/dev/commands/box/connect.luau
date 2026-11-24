local connect = require("dev.cmd.connect")
local dev_command = require("dev.command")

return dev_command({
    summary = "Same as dev connect",
    group = "Boxes",
    remote = false,
    flags = {
        { name = "ssh", kind = "boolean", help = "Go through ci ssh instead of et" },
    },
    args = {
        { name = "box", complete = "box" },
    },
    run = connect.run,
})
