local dev_command = require("dev.command")
local ws = require("dev.cmd.ws")

return dev_command({
    summary = "Make a workspace for this project and print its path",
    group = "Set up a machine or project",
    remote = false,
    args = {
        { name = "name", required = true },
    },
    run = ws.new,
})
