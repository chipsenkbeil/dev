local dev_command = require("@dev/command")
local ws = require("@dev/cmd/ws")

return dev_command({
    summary = "Move a workspace folder of this project into the central root",
    group = "Set up a machine or project",
    remote = false,
    args = {
        { name = "path", required = true },
    },
    run = ws.adopt_path,
})
