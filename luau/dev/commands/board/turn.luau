local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Take the landing turn for a card early and keep it",
    flags = {
        { name = "hold", kind = "string", help = "Seconds to hold the turn" },
        { name = "wait", kind = "string", help = "Seconds to wait for the turn" },
        { name = "release", kind = "boolean", help = "Give the turn back" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("turn", ctx)
    end,
})
