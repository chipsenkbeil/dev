local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Claim a card and keep the claim renewed, or take over NAME's claim",
    flags = {
        { name = "as", kind = "string", help = "Claim as NAME" },
        { name = "from", kind = "string", help = "Take over the claim held by NAME" },
        { name = "max-size", kind = "string", help = "Largest size to take" },
        { name = "wait", kind = "string", help = "Seconds to wait for room" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("take", ctx)
    end,
})
