local devos = require("dev.os")
local fs = require("dev.fs")

---@class support
local M = {}

---Rewrite the relative entries of `package.path` against the current directory.
---@return string path a search path that works from any directory
function M.absolute_path()
    local cwd = devos.capture({ "pwd" }):gsub("\n$", "")
    return ((";" .. package.path):gsub(";%./", ";" .. cwd .. "/"):sub(2))
end

---Make a temporary directory.
---@return string dir the new directory
function M.tempdir()
    return assert(fs.mktemp({ prefix = "test", dir = true }))
end

return M
