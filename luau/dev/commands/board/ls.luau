local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "List the cards of the board",
    flags = {
        { name = "column", kind = "string", help = "Show this column", complete = "board-column" },
        { name = "label", kind = "string", help = "Show cards with this label" },
        { name = "size", kind = "string", help = "Show cards of this size" },
        { name = "lane", kind = "string", help = "Show cards of this lane" },
        { name = "group", kind = "boolean", help = "Group the cards by column" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("ls", ctx)
    end,
})
