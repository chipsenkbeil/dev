local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Add, edit or delete a comment on a card",
    flags = {
        { name = "board", kind = "string", help = "The board the card is on" },
        { name = "kind", kind = "string", help = "The kind of note" },
        { name = "as", kind = "string", help = "The role to note as" },
        { name = "edit", kind = "string", help = "Edit this comment" },
        { name = "delete", kind = "string", help = "Delete this comment" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "text", help = "The note text", list = true, rest = true },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("note", ctx)
    end,
})
