local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Issue a role token to a runner the lead starts by hand",
    flags = {
        { name = "role", kind = "string", help = "The role the token carries" },
        { name = "as", kind = "string", help = "The runner the token is for" },
        { name = "hours", kind = "string", help = "Hours the token lasts" },
        { name = "renew", kind = "boolean", help = "Renew a token that is already issued" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("token mint", ctx)
    end,
})
