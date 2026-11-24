local dev_command = require("@dev/command")
local tools = require("@dev/cmd/tools")

return dev_command({
    summary = "Install the manifest's tools, by install scope",
    group = "Set up a machine or project",
    remote = false,
    requires = { "workspace" },
    flags = {
        { name = "dry-run", kind = "boolean", help = "Print the commands without running them" },
        { name = "force", kind = "boolean", help = "Reinstall what is already present" },
        { name = "group", kind = "string", help = "Keep only this group" },
        { name = "system", kind = "boolean", help = "Install the system packages, as root" },
        { name = "user", kind = "boolean", help = "Install into the user's home" },
    },
    args = { { name = "tool", list = true, help = "Tools to install" } },
    run = function(opts, args, ctx)
        return tools.install(opts, args.tool or {}, ctx)
    end,
})
