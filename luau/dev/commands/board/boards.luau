local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "List the names of the boards the token sees",
    flags = {},
    args = {},
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("boards", ctx)
    end,
})
