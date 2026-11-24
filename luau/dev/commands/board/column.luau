local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Set the clears-blockers or blocked flag of a Pomb column",
    flags = {
        { name = "clears-blockers", kind = "string", help = "on or off" },
        { name = "blocked", kind = "string", help = "on or off" },
    },
    args = {
        { name = "name", help = "The column", complete = "board-column" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("column", ctx)
    end,
})
