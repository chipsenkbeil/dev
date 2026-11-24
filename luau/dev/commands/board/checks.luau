local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Replace a card's checks rows with one row per CMD",
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "rows", help = "The commands, one per row", list = true },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("checks", ctx)
    end,
})
