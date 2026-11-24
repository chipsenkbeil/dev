local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Show the limits of a board and the cards in flight, or set the group limit",
    flags = {
        { name = "set", kind = "string", help = "Set the group limit to N" },
    },
    args = {
        { name = "board", help = "The board name" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("limits", ctx)
    end,
})
