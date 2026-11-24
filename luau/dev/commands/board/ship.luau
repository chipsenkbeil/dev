local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Move tested Release cards to Done after the release command",
    passthrough = true,
    flags = {
        { name = "rev", kind = "string", help = "The revision to ship" },
    },
    args = {},
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("ship", ctx)
    end,
})
