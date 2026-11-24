local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Print a card with its description and comments",
    flags = {
        { name = "board", kind = "string", help = "The board the card is on" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("show", ctx)
    end,
})
