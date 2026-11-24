local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Land a card's change on trunk under the landing turn",
    requires = { "workspace" },
    flags = {
        { name = "wait", kind = "string", help = "Seconds to wait for the landing turn" },
        { name = "ignore-change-run", kind = "string", help = "Why the change run may be ignored" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        {
            name = "rest",
            list = true,
            help = "More cards to land with it",
            complete = "board-card",
        },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("land", ctx)
    end,
})
