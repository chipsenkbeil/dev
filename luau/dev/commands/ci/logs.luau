local ci = require("dev.cmd.ci")
local dev_command = require("dev.command")

return dev_command({
    summary = "Print a ci run's log",
    group = "Boxes",
    remote = false,
    flags = {
        { name = "job", kind = "string", help = "The job whose log to print" },
    },
    args = { { name = "run", required = true, help = "The ci run id" } },
    run = function(opts, args, ctx)
        return ci.logs(args.run, opts.job, ctx)
    end,
})
