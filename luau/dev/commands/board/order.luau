local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Put cards of one column first, in the order named",
    args = {
        { name = "cards", help = "The cards, in order", complete = "board-card", list = true },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("order", ctx)
    end,
})
