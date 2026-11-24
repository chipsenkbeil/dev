local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Upload files to a Pomb card",
    flags = {},
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "files", help = "Files to upload", list = true },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("attach", ctx)
    end,
})
