local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Block until the board, or one card, changes, then print each change",
    flags = {
        {
            name = "for",
            kind = "string",
            help = "Wait for ready, review, verify, release, human, lead or planner",
        },
        {
            name = "card",
            kind = "string",
            help = "Wait for one card to change",
            complete = "board-card",
        },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("wait", ctx)
    end,
})
