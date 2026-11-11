local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local kinds = require("dev.pkg.kinds")
local lib = require("dev.pkg.lib")

local stdout, stderr = io.stdout, io.stderr
local Channel, Verb = kinds.Channel, kinds.Verb

local APPLICATIONS = "/Applications"
local QUARANTINE = "com.apple.quarantine"

---@class dev.pkg.brew
local M = {}

local function cask_app(cask)
    local out, code = dev_os.capture({ "brew", "info", "--json=v2", "--cask", cask }, {
        stdin = "null",
        stderr = "null",
    })
    local doc = code == 0 and json.decode(out)
    local casks = type(doc) == "table" and doc.casks
    local first = type(casks) == "table" and casks[1]
    local artifacts = type(first) == "table" and first.artifacts
    for _, artifact in ipairs(type(artifacts) == "table" and artifacts or {}) do
        local app = type(artifact) == "table" and artifact.app
        if type(app) == "table" and type(app[1]) == "string" then
            return app[1]
        end
    end
end

local function app_directories()
    local home = os.getenv("HOME")
    return { APPLICATIONS, home and home .. "/Applications" }
end

local function installed_app(app)
    for _, dir in ipairs(app_directories()) do
        if fs.is_dir(dir .. "/" .. app) then
            return dir .. "/" .. app
        end
    end
end

local function clear_quarantine(cask)
    local app = cask_app(cask)
    if not app then
        return
    end
    local path = APPLICATIONS .. "/" .. app
    if not fs.is_dir(path) then
        return
    end
    if
        lib.succeeds({ "xattr", "-p", QUARANTINE, path })
        and not lib.succeeds({ "spctl", "--assess", "--type", "execute", path })
    then
        stdout:write("  ~ clearing quarantine on ", app, "\n")
        dev_os.run({ "xattr", "-cr", path })
    end
end

local function listed(package)
    return lib.succeeds({ "brew", "list", package })
end

---Print whether a tool is present, as a line starting `[x]`, `[~]` or `[ ]`.
---@param row dev.pkg.Row the tool
---@return integer code 0 when present
function M.check(row)
    return lib.report(row, {
        registered = function()
            return listed(row.package)
        end,
        elsewhere = function()
            local app = row.channel == Channel.CASK and cask_app(row.package)
            return app and installed_app(app)
        end,
    })
end

local function plan(row, step)
    if row.channel == Channel.CASK then
        return { { "brew", step.verb, "--cask", row.package } }
    elseif row.channel == Channel.TAP then
        return { { "brew", "tap", row.repo }, { "brew", step.verb, row.package } }
    elseif row.channel == Channel.BARE then
        return { { "brew", step.verb, row.package } }
    end
end

local function skip_if_present(row)
    if lib.skip_on_path(row) then
        return true
    elseif listed(row.package) then
        lib.skip(row, "already installed via brew")
        return true
    elseif row.channel == Channel.CASK then
        local app = cask_app(row.package)
        if app and installed_app(app) then
            lib.skip(row, "already installed as app")
            return true
        end
    end
    return false
end

---Install a tool with Homebrew unless it is present.
---@param row dev.pkg.Row the tool
---@param opts dev.pkg.DriverOpts the flags
---@return integer code 0 on success
function M.install(row, opts)
    local verb = Verb.INSTALL
    if opts.force then
        verb = listed(row.package) and Verb.REINSTALL or verb
    elseif skip_if_present(row) then
        return 0
    end
    local cmds = plan(row, { verb = verb })
    if not cmds then
        stderr:write("  ! ", row.name, ': unknown brew channel "', row.channel, '", skipping\n')
        return 1
    end
    if opts.dry_run then
        local lines = {}
        for i, cmd in ipairs(cmds) do
            lines[i] = lib.line(cmd)
        end
        return lib.dry_run(row, lines)
    end
    stdout:write("  + installing ", row.name, "...\n")
    for _, cmd in ipairs(cmds) do
        if lib.run(cmd, opts) ~= 0 then
            return lib.failed(row, lib.line(cmd))
        end
    end
    if row.channel == Channel.CASK then
        clear_quarantine(row.package)
    end
    return 0
end

return M
