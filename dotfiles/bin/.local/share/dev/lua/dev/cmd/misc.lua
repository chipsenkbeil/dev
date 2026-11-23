local dev_os = require("dev.os")
local project = require("dev.project")
local dev_command = require("dev.command")

---@class dev.cmd.misc
local M = {}

local function exec(argv, opts)
    local _, message = dev_os.exec(argv, opts)
    dev_command.note("The command `" .. argv[1] .. "` could not run: " .. message .. ".")
    return dev_os.EXEC_FAILED
end

---Run `bootstrap.sh` from the dotfiles clone with the arguments untouched.
---@param ctx dev.Ctx the verb's context
---@return integer code the exit code, or 126 when `bash` cannot be started
function M.bootstrap(ctx)
    local root = project.dotfiles_root()
    local argv = { "bash", root .. "/bootstrap.sh" }
    for _, word in ipairs(ctx.args) do
        argv[#argv + 1] = word
    end
    return exec(argv, { cwd = root })
end

return M
