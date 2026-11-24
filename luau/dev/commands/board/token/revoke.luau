local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Revoke the role token that token mint issued as NAME",
    flags = {
        { name = "as", kind = "string", help = "The runner whose token to revoke" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("token revoke", ctx)
    end,
})
