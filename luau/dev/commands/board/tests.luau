local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Replace a card's tests field with the test names, one per line",
    flags = {},
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "names", list = true, help = "The test names" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("tests", ctx)
    end,
})
