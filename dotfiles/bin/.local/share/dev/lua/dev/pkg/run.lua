local devos = require("dev.os")

---@class dev.pkg.run
local M = {}

local BRIDGE =
    'set -o pipefail; lib=$1; driver=$2; fn=$3; PKG_LOG_FILE=$4; export PKG_FORCE=$5; shift 5; . "$lib" && . "$driver" && "$fn" "$@"'

---@class dev.pkg.run.Opts
---@field scripts string absolute path of the `scripts` directory holding `pkg/`
---@field handler string the driver's name, `brew` for `pkg/brew.sh`
---@field fn dev.pkg.Fn the driver function to call
---@field args string[] the function's arguments
---@field force boolean whether the driver reinstalls what is present
---@field log_file string the file the driver's commands log to, empty for the terminal

---Run one function of a bash driver.
---
---The driver's output goes to the terminal.
---@param opts dev.pkg.run.Opts the driver, the function and its arguments
---@return integer? code the function's exit status
function M.driver(opts)
    local argv = {
        "bash",
        "-c",
        BRIDGE,
        "pkg",
        opts.scripts .. "/pkg/lib.sh",
        opts.scripts .. "/pkg/" .. opts.handler .. ".sh",
        opts.fn,
        opts.log_file,
        opts.force and "1" or "0",
    }
    for _, arg in ipairs(opts.args) do
        argv[#argv + 1] = arg
    end
    return devos.run(argv)
end

return M
