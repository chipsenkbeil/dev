local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Remove an attachment from a card",
    flags = {},
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "attachment", help = "The attachment id" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("detach", ctx)
    end,
})
