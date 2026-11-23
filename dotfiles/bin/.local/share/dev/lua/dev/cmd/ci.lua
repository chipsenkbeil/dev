local box = require("dev.cmd.box")
local dev_os = require("dev.os")
local dev_command = require("dev.command")

---@class dev.cmd.ci
---@field handlers table<string, fun(ctx: dev.Ctx): integer> the handlers of the `ci` subcommands
local M = { handlers = {} }

M.handlers["ci logs"] = function(ctx)
    -- Read RUN and --job from the arguments
    local run, job
    local args = ctx.args
    local i = 1
    while i <= #args do
        local arg = args[i]
        i = i + 1
        if arg == "--job" then
            if i > #args then
                dev_command.usage_error(ctx, "Flag --job needs a value.")
            end
            job = args[i]
            i = i + 1
        elseif #arg > 1 and arg:sub(1, 1) == "-" then
            dev_command.usage_error(ctx, "Unknown flag " .. arg .. ".")
        elseif run then
            dev_command.usage_error(ctx, "Unexpected argument " .. arg .. ".")
        else
            run = arg
        end
    end
    if not run then
        dev_command.usage_error(ctx, "Missing RUN.")
    end

    -- Refuse to go on without ci
    box.need_ci()

    -- Run ci logs in the project root
    local argv = { "ci", "-C", ctx.root, "logs", run }
    if job then
        argv[#argv + 1] = "--job"
        argv[#argv + 1] = job
    end
    return dev_os.run(argv) or 1
end

return M
