local dev_command = require("dev.command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Bring the board to the standard",
    flags = {
        { name = "name", kind = "string", help = "Name of the board to make" },
        {
            name = "admin",
            kind = "boolean",
            help = "Sign in as an admin instead of using the lead token",
        },
    },
    run = function(_opts, _args, ctx)
        return require("dev.cmd.board").invoke("init", ctx)
    end,
})
