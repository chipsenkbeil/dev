local box = require("@dev/cmd/box")
local dev_command = require("@dev/command")

return dev_command({
    summary = "Move a box to another target its machine offers",
    group = "Boxes",
    remote = false,
    flags = {
        { name = "target", kind = "string", help = "The target to move to" },
    },
    args = {
        { name = "box", complete = "box" },
    },
    run = box.retag,
})
