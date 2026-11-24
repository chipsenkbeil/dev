local branch = require("@dev/cmd/branch")
local dev_command = require("@dev/command")

return dev_command({
    summary = "List branches, remote branches and anonymous jj heads as landed or unlanded",
    group = "Share it",
    remote = false,
    run = function(_, _, ctx)
        return branch.ls(ctx)
    end,
})
