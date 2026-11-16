local dev_os = require("dev.os")
local lib = require("dev.pkg.lib")

local stdout = io.stdout

---@class dev.pkg.luarocks
local M = {}

local function installed_rock(package)
    local out, code = dev_os.capture({ "luarocks", "list", package }, { stderr = "null" })
    if code ~= 0 then
        return false
    end
    for line in out:gmatch("[^\n]*") do
        if line == package then
            return true
        end
    end
    return false
end

---Install a rock with luarocks.
---@param row dev.pkg.Row the tool
---@param opts dev.pkg.lib.install.Opts the flags
---@return integer code 0 on success
function M.install(row, opts)
    local force = {}
    if opts.force then
        force = { "--force" }
    elseif lib.skip_on_path(row) then
        return 0
    elseif installed_rock(row.package) then
        return lib.skip(row, "already installed via luarocks")
    end
    local cmd = { "luarocks", "install", unpack(force) }
    cmd[#cmd + 1] = row.package
    if opts.dry_run then
        return lib.dry_run(row, { lib.privileged_line(cmd) })
    end
    stdout:write("  + installing ", row.name, " (luarocks)...\n")
    return lib.run(lib.privileged(cmd), opts) or 1
end

return M
