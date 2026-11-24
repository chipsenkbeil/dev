local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Log a role's minutes on a card to Pomb",
    flags = {
        { name = "as", kind = "string", help = "The role the time was logged in" },
        { name = "note", kind = "string", help = "A note for the entry" },
    },
    args = {
        { name = "first", help = "The card, or start or stop" },
        { name = "second", help = "The minutes, or the card after start or stop" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("time", ctx)
    end,
})
