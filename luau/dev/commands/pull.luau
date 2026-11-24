local dev_command = require("@dev/command")
local pull = require("@dev/cmd/pull")

return dev_command({
    summary = "Fetch the remote and rebase local work onto it",
    group = "Share it",
    remote = false,
    requires = { "workspace" },
    run = function(_, _, ctx)
        return pull.run(ctx)
    end,
})
