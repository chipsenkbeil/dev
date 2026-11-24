local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Show, set or clear a card's due date",
    flags = {
        { name = "clear", kind = "boolean", help = "Clear the date" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "date", help = "The date, YYYY-MM-DD" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("due", ctx)
    end,
})
