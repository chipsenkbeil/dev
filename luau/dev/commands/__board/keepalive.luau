local dev_command = require("dev.command")
local keepalive = require("dev.board.keepalive")

return dev_command({
    summary = "Renew a claim on Pomb every tick while its state file holds the fence",
    hidden = true,
    remote = false,
    args = {
        { name = "state", required = true },
        { name = "card", required = true },
        { name = "fence", required = true },
        { name = "ticks", required = true },
        { name = "url", required = true },
        { name = "entry", required = true },
        { name = "tick", required = true },
        { name = "name", required = true },
        { name = "lease", required = true },
        { name = "tokenfile" },
    },
    run = function(_, args)
        return keepalive.run({
            state = args.state,
            card = args.card,
            fence = args.fence,
            ticks = tonumber(args.ticks) or 0,
            url = args.url,
            entry = args.entry,
            tick = tonumber(args.tick) or 0,
            name = args.name,
            lease = args.lease,
            tokenfile = args.tokenfile,
        })
    end,
})
