local dev_command = require("@dev/command")
local push = require("@dev/cmd/push")

return dev_command({
    summary = "Push the trunk or current branch to the remote of record",
    group = "Share it",
    remote = false,
    requires = { "workspace" },
    flags = {
        { name = "tag", kind = "string", repeatable = true, help = "Push only this tag" },
    },
    args = { { name = "remote", list = true, help = "Remotes to push to" } },
    run = function(opts, args, ctx)
        return push.run(opts, args.remote or {}, ctx)
    end,
})
