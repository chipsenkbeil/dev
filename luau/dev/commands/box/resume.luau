local box = require("@dev/cmd/box")
local dev_command = require("@dev/command")

return dev_command({
    summary = "Start a stopped box again",
    group = "Boxes",
    remote = false,
    flags = {
        { name = "ttl", kind = "string", help = "Hours to live, a whole number" },
        { name = "keep", kind = "boolean", help = "Keep the box with no expiry" },
    },
    args = {
        { name = "box", complete = "box" },
    },
    run = box.resume,
})
