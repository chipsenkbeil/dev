local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Show, set or clear the session responsible for a card",
    flags = {
        { name = "clear", kind = "boolean", help = "Clear the session" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "name", help = "The session name" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("responsible", ctx)
    end,
})
