local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Hand a needs:planner card up to a lead",
    flags = {
        { name = "question", kind = "string", help = "Refused here, use dev board ask" },
        { name = "choice", kind = "string", help = "Refused here, use dev board ask" },
        { name = "recommend", kind = "string", help = "Refused here, use dev board ask" },
        { name = "why", kind = "string", help = "Refused here, use dev board ask" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "text", help = "The reason", list = true },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("escalate", ctx)
    end,
})
