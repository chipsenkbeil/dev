local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "List a card's links",
    long = "Lists the links that `card` holds. `dev board link` adds one, and `dev board unlink` removes one.",
    flags = {},
    args = {
        { name = "card", help = "The card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("links", ctx)
    end,
})
