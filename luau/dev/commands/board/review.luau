local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Record that NAME reviewed a commit of the card",
    flags = {
        { name = "kind", kind = "string", help = "code, style or recheck" },
        { name = "by", kind = "string", help = "The reviewer" },
        { name = "rev", kind = "string", help = "The revision reviewed" },
        { name = "verdict", kind = "string", help = "clean, minor or needs-work" },
        { name = "of", kind = "string", help = "code or style, for a recheck" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("review", ctx)
    end,
})
