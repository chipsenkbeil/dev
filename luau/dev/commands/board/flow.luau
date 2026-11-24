local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Print the median and p90 minutes cards wait from Verify to Done",
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("flow", ctx)
    end,
})
