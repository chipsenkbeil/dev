local box = require("@dev/cmd/box")
local dev_command = require("@dev/command")

return dev_command({
    summary = "Replace a running box's lifetime, counted from now",
    group = "Boxes",
    remote = false,
    flags = {
        { name = "ttl", kind = "string", help = "Hours to live, a whole number" },
        { name = "keep", kind = "boolean", help = "Keep the box with no expiry" },
    },
    args = {
        { name = "box", complete = "box" },
    },
    run = box.extend,
})
