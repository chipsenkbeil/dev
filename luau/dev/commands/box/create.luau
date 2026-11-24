local box = require("@dev/cmd/box")
local dev_command = require("@dev/command")

return dev_command({
    summary = "Create a box for 4 hours by default and wait until it runs",
    group = "Boxes",
    remote = false,
    flags = {
        { name = "target", kind = "string", help = "The target to run" },
        { name = "shape", kind = "string", help = "The shape of the box" },
        { name = "arch", kind = "string", help = "The architecture" },
        { name = "by", kind = "string", help = "A label for who made it" },
        { name = "ttl", kind = "string", help = "Hours to live, a whole number" },
        { name = "keep", kind = "boolean", help = "Keep the box with no expiry" },
    },
    args = {
        { name = "projects", list = true },
    },
    run = box.create_from_flags,
})
