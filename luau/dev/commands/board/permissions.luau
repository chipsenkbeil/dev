local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "List Pomb's permission catalog with each permission's group and presets",
    flags = {},
    args = {},
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("permissions", ctx)
    end,
})
