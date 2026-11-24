local dev_command = require("dev.command")
local follow = require("dev.cmd.follow")

return dev_command({
    summary = "Move the main checkout onto trunk",
    group = "Share it",
    remote = false,
    requires = { "workspace" },
    run = function(_, _, ctx)
        return follow.run(ctx)
    end,
})
