local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Drop a seat and add it back open, for a token with seats.manage",
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "seat", help = "The seat, such as code, style or recheck" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("seat reset", ctx)
    end,
})
