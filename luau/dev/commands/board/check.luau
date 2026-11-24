local dev_command = require("@dev/command")

return dev_command({
    group = "Share it",
    remote = false,
    summary = "Run a card's checks rows, print each ci run id and record the results",
    flags = {
        { name = "expect-fail", kind = "boolean", help = "Expect the checks to fail" },
        { name = "timeout", kind = "string", help = "Seconds to wait for each row" },
        { name = "run", kind = "string", help = "A ci run id to record" },
    },
    args = {
        { name = "card", help = "The card", complete = "board-card" },
    },
    run = function(_opts, _args, ctx)
        return require("@dev/cmd/board").invoke("check", ctx)
    end,
})
