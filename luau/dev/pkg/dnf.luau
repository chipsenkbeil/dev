local dev_os = require("dev.os")
local kinds = require("dev.pkg.kinds")
local lib = require("dev.pkg.lib")
local note = require("dev.command").note

local stdout = dev_os.stdout
local Channel, Verb = kinds.Channel, kinds.Verb

---@class dev.pkg.dnf
local M = {}

---Print whether a tool is present, as a line starting `[x]`, `[~]` or `[ ]`.
---@param row dev.pkg.Row the tool
---@return integer code 0 when present
function M.check(row)
    return lib.report(row, {
        registered = function()
            return lib.succeeds({ "rpm", "-q", "--", row.package })
        end,
    })
end

local function ensure_copr_plugin()
    if lib.succeeds({ "dnf", "copr", "--help" }) then
        return true
    end
    return dev_os.run(lib.privileged({ "dnf", "install", "-y", "dnf-plugins-core" })) == 0
end

local function plan(row, step)
    local install = { "dnf", step.verb, "-y", "--", row.package }
    if row.channel == Channel.BARE then
        return { install }
    elseif row.channel == Channel.COPR then
        return { { "dnf", "copr", "enable", "-y", row.repo }, install }
    end
end

---Install a tool with dnf, enabling its COPR first for a `copr:` cell.
---@param row dev.pkg.Row the tool
---@param opts dev.pkg.driver.install.Opts the flags
---@return integer code 0 on success
function M.install(row, opts)
    local verb = Verb.INSTALL
    if opts.force then
        verb = lib.succeeds({ "rpm", "-q", row.package }) and Verb.REINSTALL or verb
    elseif lib.skip_on_path(row) then
        return 0
    elseif lib.succeeds({ "rpm", "-q", row.package }) then
        return lib.skip(row, "already installed via dnf")
    end
    local cmds = plan(row, { verb = verb })
    if not cmds then
        note("  ! " .. row.name .. ': unknown dnf channel "' .. row.channel .. '", skipping')
        return 1
    end
    if opts.dry_run then
        local lines = {}
        for i, cmd in ipairs(cmds) do
            lines[i] = lib.privileged_line(cmd)
        end
        return lib.dry_run(row, lines)
    end
    if row.channel == Channel.COPR and not ensure_copr_plugin() then
        return 1
    end
    stdout:write("  + installing ", row.name, "...\n")
    for _, cmd in ipairs(cmds) do
        if lib.run(lib.privileged(cmd), opts) ~= 0 then
            return lib.failed(row, lib.privileged_line(cmd))
        end
    end
    return 0
end

return M
