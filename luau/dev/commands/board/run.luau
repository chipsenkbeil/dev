local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Keep a session's run on the board as one card",
    flags = {
        { name = "orders", kind = "string", help = "The run card orders", repeatable = true },
        { name = "end", kind = "boolean", help = "End the run" },
    },
    args = {},
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("run", ctx)
    end,
})
