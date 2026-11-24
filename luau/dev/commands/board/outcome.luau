local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Append, reword, tick, untick or delete a card's outcome",
    flags = {
        { name = "rename", kind = "string", help = "Reword outcome N, with TEXT and --reason" },
        { name = "tick", kind = "string", help = "Tick outcome N" },
        { name = "untick", kind = "string", help = "Untick outcome N" },
        { name = "delete", kind = "string", help = "Delete outcome N, with --reason" },
        { name = "reason", kind = "string", help = "Why the outcome is reworded or deleted" },
        { name = "convert", kind = "boolean", help = "Turn the Done when checklist into outcomes" },
        { name = "as", kind = "string", help = "The name that ticks, unticks or converts" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "text", help = "The outcome text, or the new text of --rename" },
        { name = "rest", list = true, help = "More words of the reason" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("outcome", ctx)
    end,
})
