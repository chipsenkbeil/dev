local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Replay the changes queued while Pomb was unreachable",
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("sync", ctx)
    end,
})
