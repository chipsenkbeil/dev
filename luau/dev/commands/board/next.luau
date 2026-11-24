local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Show the top unclaimed Ready card",
    flags = {
        {
            name = "column",
            kind = "string",
            help = "Take the next card of this column",
            complete = "board-column",
        },
        { name = "for", kind = "string", help = "planner or lead, with --column Blocked" },
        { name = "lane", kind = "string", help = "Take a card of this lane" },
        { name = "max-size", kind = "string", help = "Skip cards bigger than this size" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("next", ctx)
    end,
})
