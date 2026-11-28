local abandon = require("@dev/cmd/abandon")
local dev_command = require("@dev/command")

return dev_command({
    summary = "Abandon an open Gerrit change by its number or Change-Id",
    group = "Share it",
    requires = { "workspace", "lead" },
    flags = {
        { name = "reason", kind = "string", help = "The message to abandon with" },
    },
    args = { { name = "change", required = true, help = "Change number or Change-Id" } },
    run = function(opts, args, ctx)
        return abandon.run(args.change, opts.reason, ctx)
    end,
})
