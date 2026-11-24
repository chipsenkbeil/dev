local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Replace a card's description from a file or standard input",
    flags = {
        { name = "board", kind = "string", help = "The board the card is on" },
        { name = "file", kind = "string", help = "Read the description from this file" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "text", help = "The description" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("edit", ctx)
    end,
})
