local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "List the cards that sat too long in a column",
    flags = {
        { name = "days", kind = "string", help = "Days a card may sit" },
        { name = "icebox-days", kind = "string", help = "Days a card may sit in Icebox" },
        { name = "lead-hours", kind = "string", help = "Hours a lead card may sit" },
        { name = "flight-hours", kind = "string", help = "Hours an in-flight card may sit" },
    },
    args = {},
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("stale", ctx)
    end,
})
