local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "List a card's attachments",
    flags = {},
    args = {
        { name = "card", help = "The card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("attachments", ctx)
    end,
})
