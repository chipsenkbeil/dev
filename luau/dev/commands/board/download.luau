local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Save a card's attachment and print its path",
    flags = {
        { name = "out", kind = "string", help = "Directory to save into" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "attachment", help = "The attachment id or name" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("download", ctx)
    end,
})
