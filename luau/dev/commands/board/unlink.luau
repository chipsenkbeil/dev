local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Remove a link the card holds",
    flags = {},
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "kind", help = "The kind of link" },
        { name = "other", help = "The other card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("unlink", ctx)
    end,
})
