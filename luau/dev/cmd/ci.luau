local box = require("dev.cmd.box")
local dev_os = require("dev.os")

---@class dev.cmd.ci
local M = {}

---Print a ci run's log through `ci logs` in the project root.
---@param run string the ci run id
---@param job string? the job whose log to print, nil for the run's own
---@param ctx dev.Ctx the command's context
---@return integer code the exit code of `ci logs`, 1 when it did not run
function M.logs(run, job, ctx)
    box.need_ci()
    local argv = { "ci", "-C", ctx.root, "logs", run }
    if job then
        argv[#argv + 1] = "--job"
        argv[#argv + 1] = job
    end
    return dev_os.run(argv) or 1
end

return M
