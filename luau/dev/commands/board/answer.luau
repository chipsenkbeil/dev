local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Record the owner's answer on a needs:human card",
    flags = {
        { name = "choice", kind = "string", help = "The number of the chosen choice" },
        { name = "quote", kind = "string", help = "The owner words" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "rest", help = "More words of the quote", list = true },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("answer", ctx)
    end,
})
