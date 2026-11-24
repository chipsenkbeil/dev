local box = require("@dev/cmd/box")
local dev_command = require("@dev/command")

return dev_command({
    summary = "Show the targets a box can run, grouped by machine",
    group = "Boxes",
    remote = false,
    flags = {
        { name = "json", kind = "boolean", help = "Print the ci document" },
    },
    run = box.targets,
})
