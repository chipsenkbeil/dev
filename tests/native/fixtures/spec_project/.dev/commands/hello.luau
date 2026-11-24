local dev_command = require("@dev/command")

return dev_command({
    summary = "Say hello",
    group = "Greeting",
    flags = {
        { name = "times", short = "n", kind = "number", default = 1, help = "How often" },
    },
    args = { { name = "who", required = true } },
    run = function(opts, args, ctx)
        for _ = 1, opts.times do
            ctx.say(args.who)
        end
        return 3
    end,
})
