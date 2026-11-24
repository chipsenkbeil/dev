local dev_command = require("@dev/command")
local tools = require("@dev/cmd/tools")

return dev_command({
    summary = "Report which of the manifest's tools are missing from PATH",
    remote = false,
    flags = {
        { name = "group", kind = "string", help = "Keep only this group" },
    },
    run = function(opts, _, ctx)
        return tools.check(opts, ctx)
    end,
})
