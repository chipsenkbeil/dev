local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Print the board's backend and name, or every needs:human card with --all",
    flags = {
        { name = "all", kind = "boolean", help = "List every needs:human card" },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("status", ctx)
    end,
})
