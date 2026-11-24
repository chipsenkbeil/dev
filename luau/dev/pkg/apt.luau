local dev_os = require("@dev/os")
local kinds = require("@dev/pkg/kinds")
local lib = require("@dev/pkg/lib")
local note = require("@dev/command").note

local stdout = dev_os.stdout
local Channel = kinds.Channel

local INSTALLED_STATUS = "^install ok installed"

local refreshed = false

---@class dev.pkg.apt
local M = {}

local function installed(package)
    local out = dev_os.capture(
        { "dpkg-query", "-W", "-f=${Status}", "--", package },
        { stdin = "null", stderr = "null" }
    )
    return out:find(INSTALLED_STATUS) ~= nil
end

---Print whether a tool is present, as a line starting `[x]`, `[~]` or `[ ]`.
---@param row dev.pkg.Row the tool
---@return integer code 0 when present
function M.check(row)
    return lib.report(row, {
        registered = function()
            return installed(row.package)
        end,
    })
end

local function apt_get(...)
    local argv = { "env", "DEBIAN_FRONTEND=noninteractive", "apt-get" }
    for _, word in ipairs({ ... }) do
        argv[#argv + 1] = word
    end
    return argv
end

local function plan(row, verb)
    local cmds = {}
    if not refreshed then
        cmds[1] = apt_get("update")
    end
    local install = apt_get("install", "-y")
    if verb == kinds.Verb.REINSTALL then
        install[#install + 1] = "--reinstall"
    end
    install[#install + 1] = "--"
    install[#install + 1] = row.package
    cmds[#cmds + 1] = install
    return cmds
end

---Install a tool with apt-get, refreshing the package lists once before the first install of a run.
---@param row dev.pkg.Row the tool
---@param opts dev.pkg.driver.install.Opts the flags
---@return integer code 0 on success
function M.install(row, opts)
    local verb = kinds.Verb.INSTALL
    if opts.force then
        verb = installed(row.package) and kinds.Verb.REINSTALL or verb
    elseif lib.skip_on_path(row) then
        return 0
    elseif installed(row.package) then
        return lib.skip(row, "already installed via apt")
    end
    if row.channel ~= Channel.BARE then
        note("  ! " .. row.name .. ': unknown apt channel "' .. row.channel .. '", skipping')
        return 1
    end
    local cmds = plan(row, verb)
    if opts.dry_run then
        local lines = {}
        for i, cmd in ipairs(cmds) do
            lines[i] = lib.privileged_line(cmd)
        end
        refreshed = true
        return lib.dry_run(row, lines)
    end
    stdout:write("  + installing ", row.name, "...\n")
    for _, cmd in ipairs(cmds) do
        if lib.run(lib.privileged(cmd), opts) ~= 0 then
            return lib.failed(row, lib.privileged_line(cmd))
        end
        refreshed = true
    end
    return 0
end

return M
