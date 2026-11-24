local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Set a card's title to TEXT",
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "title", help = "The new title", list = true },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("rename", ctx)
    end,
})
