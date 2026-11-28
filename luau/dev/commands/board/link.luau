local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Link a card to another card",
    long = "Records a link of `kind` from `card` to `other`. `dev board unlink` removes it, and `dev board links` lists the links that `card` holds.",
    flags = {},
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "kind", help = "The kind of link" },
        { name = "other", help = "The other card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("link", ctx)
    end,
})
