local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Add a card to the board",
    flags = {
        { name = "board", kind = "string", help = "Add to this board" },
        {
            name = "blocked-by",
            kind = "string",
            help = "Card that blocks the new one",
            repeatable = true,
            complete = "board-card",
        },
        { name = "from", kind = "string", help = "Card to copy from", complete = "board-card" },
        { name = "epic", kind = "boolean", help = "Make the card an epic" },
        { name = "id-only", kind = "boolean", help = "Print only the new card id" },
        { name = "top", kind = "boolean", help = "Put the card at the top" },
        {
            name = "before",
            kind = "string",
            help = "Put the card before this card",
            complete = "board-card",
        },
        {
            name = "after",
            kind = "string",
            help = "Put the card after this card",
            complete = "board-card",
        },
        {
            name = "column",
            kind = "string",
            help = "Add to this column",
            complete = "board-column",
        },
        { name = "lane", kind = "string", help = "Add to this lane" },
        { name = "description", kind = "string", help = "The whole description" },
        { name = "problem", kind = "string", repeatable = true, help = "The Problem section" },
        { name = "change", kind = "string", help = "A Change line", repeatable = true },
        {
            name = "out-of-scope",
            kind = "string",
            repeatable = true,
            help = "The Out of scope section",
        },
        { name = "source", kind = "string", repeatable = true, help = "The Source section" },
        { name = "size", kind = "string", help = "The size" },
        { name = "label", kind = "string", help = "A label", repeatable = true },
        { name = "checks", kind = "string", help = "A checks row", repeatable = true },
        { name = "done-when", kind = "string", help = "An outcome", repeatable = true },
    },
    args = {
        { name = "name", help = "The card name", list = true },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("add", ctx)
    end,
})
