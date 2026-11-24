local box = require("@dev/cmd/box")
local dev_command = require("@dev/command")

return dev_command({
    summary = "Stop a box, which ci deletes later unless it is resumed",
    group = "Boxes",
    remote = false,
    args = {
        { name = "box", complete = "box" },
    },
    run = box.stop,
})
