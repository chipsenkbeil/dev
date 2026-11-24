local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "List who moved a card and with which token",
    args = {
        { name = "card", help = "The card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("history", ctx)
    end,
})
