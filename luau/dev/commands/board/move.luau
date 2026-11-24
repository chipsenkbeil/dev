local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Move a card to the top of a column, of another Pomb board with --to-board",
    flags = {
        { name = "board", kind = "string", help = "The board the card is on" },
        { name = "lane", kind = "string", help = "Put the card in this lane" },
        { name = "max-size", kind = "string", help = "Refuse a card larger than this size" },
        {
            name = "to-board",
            kind = "string",
            help = "Move the card to a column of this other board",
        },
        {
            name = "wait",
            kind = "string",
            help = "Seconds to keep trying while the column is full",
        },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "column", list = true, help = "The column", complete = "board-column" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("move", ctx)
    end,
})
