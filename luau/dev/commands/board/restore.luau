local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Bring a card back from Pomb's recycle bin",
    flags = {},
    args = {
        { name = "card", help = "The card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("restore", ctx)
    end,
})
