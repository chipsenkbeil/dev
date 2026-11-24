local box = require("@dev/cmd/box")
local dev_command = require("@dev/command")

return dev_command({
    summary = "Show one box as key: value lines",
    group = "Boxes",
    remote = false,
    flags = {
        { name = "json", kind = "boolean", help = "Print the ci document" },
    },
    args = {
        { name = "box", complete = "box" },
    },
    run = box.show,
})
