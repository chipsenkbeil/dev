local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Add labels to a card or remove them with --remove",
    flags = {
        { name = "remove", kind = "string", help = "A label to remove", repeatable = true },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "rest", help = "Labels to add, with + or - in front", list = true },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("label", ctx)
    end,
})
