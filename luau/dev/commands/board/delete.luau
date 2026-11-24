local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Move a card to Pomb's recycle bin with the lead token",
    flags = {
        { name = "reason", kind = "string", help = "Why the card is deleted" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("delete", ctx)
    end,
})
