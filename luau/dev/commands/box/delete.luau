local box = require("@dev/cmd/box")
local dev_command = require("@dev/command")

return dev_command({
    summary = "Archive a box's projects and delete it",
    group = "Boxes",
    remote = false,
    flags = {
        { name = "yes", short = "y", kind = "boolean", help = "Do not ask first" },
        { name = "no-archive", kind = "boolean", help = "Delete without archiving projects" },
    },
    args = {
        { name = "box", complete = "box" },
    },
    run = box.delete,
})
