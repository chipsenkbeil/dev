local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Replace a card's files field with the paths, one per line",
    flags = {},
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "names", list = true, help = "The paths" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("files", ctx)
    end,
})
