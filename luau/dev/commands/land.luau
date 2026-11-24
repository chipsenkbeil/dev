local dev_command = require("@dev/command")
local land = require("@dev/cmd/land")

return dev_command({
    summary = "Land the workspace's card, or its change with no board",
    group = "Share it",
    remote = false,
    requires = { "workspace" },
    flags = {
        { name = "card", kind = "string", help = "The card to land" },
        { name = "wait", kind = "number", help = "Seconds to wait for the landing turn" },
        {
            name = "ignore-change-run",
            kind = "string",
            help = "Land past a change run, with the reason",
        },
    },
    run = function(opts, _, ctx)
        return land.run(opts, ctx)
    end,
})
