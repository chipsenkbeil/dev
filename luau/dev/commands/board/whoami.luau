local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Show the Pomb credential dev board uses",
    flags = {},
    args = {},
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("whoami", ctx)
    end,
})
