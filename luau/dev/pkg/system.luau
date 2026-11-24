local lib = require("dev.pkg.lib")

---@class dev.pkg.system
local M = {}

---Print whether a tool installed outside dev tools is on PATH, as a line starting `[x]` or `[ ]`.
---@param row dev.pkg.Row the tool
---@return integer code 0 when present
function M.check(row)
    return lib.report(row, {
        registered = function()
            return false
        end,
    })
end

---Install nothing: something outside dev tools installs the tool.
---@param row dev.pkg.Row the tool
---@return integer code 0
function M.install(row)
    return lib.skip(row, "installed outside dev tools")
end

return M
