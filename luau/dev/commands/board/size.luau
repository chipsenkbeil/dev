local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Set a card's size colour",
    args = {
        { name = "card", help = "The card", complete = "board-card" },
        { name = "size", help = "The size" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("size", ctx)
    end,
})
