local dev_command = require("@dev/command")
local dev_os = require("@dev/os")
local scripts = require("@dev/complete/scripts")

return dev_command({
    summary = "Print the shell completion script for bash, zsh, fish or powershell",
    group = "Set up a machine or project",
    remote = false,
    args = {
        {
            name = "shell",
            required = true,
            help = "bash, zsh, fish or powershell",
            complete = scripts.SHELLS,
        },
    },
    run = function(_, args, ctx)
        local script = scripts.for_shell(args.shell)
        if not script then
            dev_command.usage_error(
                ctx,
                "Unknown shell "
                    .. args.shell
                    .. ". The shells are "
                    .. table.concat(scripts.SHELLS, ", ")
                    .. "."
            )
        end

        -- Raw write: the shell must receive the script bytes exactly.
        dev_os.stdout:write(script)
        return 0
    end,
})
