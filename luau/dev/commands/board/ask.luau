local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Ask the owner a structured question through Pomb",
    flags = {
        { name = "question", kind = "string", help = "The question" },
        { name = "choice", kind = "string", help = "A choice as COLUMN=LABEL", repeatable = true },
        { name = "recommend", kind = "string", help = "The number of the recommended choice" },
        { name = "why", kind = "string", help = "Why this choice" },
        {
            name = "list",
            kind = "string",
            choices = { "secrets", "destroy", "spend", "restart", "taste" },
            help = "The closed list of what only the owner decides",
        },
        { name = "searched", kind = "string", help = "The precedent search that was run" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("ask", ctx)
    end,
})
