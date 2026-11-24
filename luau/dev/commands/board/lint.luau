local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Report every card, or just CARD, that breaks the board's rules",
    flags = {
        { name = "strict", kind = "boolean", help = "Count every rule as a finding" },
        { name = "open", kind = "boolean", help = "Skip cards in a done column" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("lint", ctx)
    end,
})
