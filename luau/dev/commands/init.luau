local dev_command = require("@dev/command")
local init = require("@dev/cmd/init")

return dev_command({
    summary = "Set up a project's version control and remotes",
    group = "Set up a machine or project",
    remote = false,
    requires = { "workspace" },
    flags = {
        { name = "name", kind = "string", help = "The project's name" },
        { name = "dry-run", kind = "boolean", help = "Print what would be created" },
    },
    run = function(opts, _, ctx)
        return init.run(opts, ctx)
    end,
})
