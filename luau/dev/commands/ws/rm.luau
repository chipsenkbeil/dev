local dev_command = require("@dev/command")
local ws = require("@dev/cmd/ws")

return dev_command({
    summary = "Remove a workspace of this project and move its folder to the trash",
    group = "Set up a machine or project",
    remote = false,
    flags = {
        { name = "forgotten", kind = "boolean", help = "Trash a folder jj no longer lists" },
    },
    args = {
        { name = "name", required = true },
    },
    run = ws.rm,
})
