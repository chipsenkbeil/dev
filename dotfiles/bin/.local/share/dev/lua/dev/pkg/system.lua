local lib = require("dev.pkg.lib")

---@class dev.pkg.system
local M = {}

---Print whether a tool the OS ships is on PATH, as a line starting `[x]` or `[ ]`.
---@param row dev.pkg.Row the tool
---@return integer code 0 when present
function M.check(row)
    return lib.report(row, {
        registered = function()
            return false
        end,
    })
end

---Install nothing: the OS ships the tool.
---@param row dev.pkg.Row the tool
---@return integer code 0
function M.install(row)
    return lib.skip(row, "ships with the OS")
end

return M
