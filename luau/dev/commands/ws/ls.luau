local dev_command = require("@dev/command")
local ws = require("@dev/cmd/ws")

return dev_command({
    summary = "List this project's workspaces with their paths",
    group = "Set up a machine or project",
    remote = false,
    run = ws.ls,
})
