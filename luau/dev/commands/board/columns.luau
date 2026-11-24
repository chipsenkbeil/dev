local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "List the columns of a board in board order",
    flags = {},
    args = {
        { name = "board", help = "The board name" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("columns", ctx)
    end,
})
