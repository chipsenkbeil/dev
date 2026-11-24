local branch = require("dev.cmd.branch")
local dev_command = require("dev.command")

return dev_command({
    summary = "Push a revision to refs/archive/DATE/NAME on every remote",
    remote = false,
    requires = { "workspace" },
    flags = {
        { name = "to", kind = "string", help = "Archive to this one remote" },
    },
    args = { { name = "rev", required = true, help = "The revision to archive" } },
    run = function(opts, args, ctx)
        return branch.archive(args.rev, opts.to, ctx)
    end,
})
