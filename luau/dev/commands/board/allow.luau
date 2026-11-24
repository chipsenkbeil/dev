local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Replace a card's allow field with the guard rails it lifts",
    flags = {},
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "words", list = true, help = "test-edits, ci-edits or none" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("allow", ctx)
    end,
})
