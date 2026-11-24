local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Drop a card, labelled discarded, into Done",
    flags = {
        { name = "board", kind = "string", help = "The board the card is on" },
        { name = "reason", kind = "string", help = "Why the card is dropped" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("discard", ctx)
    end,
})
