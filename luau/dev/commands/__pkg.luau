local dev_command = require("dev.command")
local pkg = require("dev.pkg")

return dev_command({
    summary = "Run the tools package driver, check or install",
    hidden = true,
    remote = false,
    flags = {
        { name = "manifest", kind = "string", help = "The tools manifest" },
        { name = "group", kind = "string", help = "Keep only this group" },
        { name = "scope", kind = "string", choices = { "system", "user" }, help = "Install scope" },
        { name = "log-file", kind = "string", help = "Append the commands' output here" },
        { name = "dry-run", kind = "boolean", help = "Print the commands without running them" },
        { name = "force", kind = "boolean", help = "Reinstall what is already present" },
    },
    args = {
        { name = "subcommand", help = "check or install" },
        { name = "tool", list = true, help = "Tools to install" },
    },
    passthrough = true,
    run = function(_, _, ctx)
        return pkg.main(ctx.argv)
    end,
})
