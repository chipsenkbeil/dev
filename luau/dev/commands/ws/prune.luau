local dev_command = require("dev.command")
local ws = require("dev.cmd.ws")

return dev_command({
    summary = "Forget finished workspaces and abandon empty heads",
    group = "Set up a machine or project",
    remote = false,
    flags = {
        { name = "dry-run", kind = "boolean", help = "Print the plan and remove nothing" },
    },
    run = ws.prune,
})
