local branch = require("@dev/cmd/branch")
local dev_command = require("@dev/command")

return dev_command({
    summary = "Delete a branch that is landed by content or archived everywhere",
    remote = false,
    requires = { "workspace" },
    args = { { name = "name", required = true, help = "The branch to delete" } },
    run = function(_, args, ctx)
        return branch.prune(args.name, ctx)
    end,
})
