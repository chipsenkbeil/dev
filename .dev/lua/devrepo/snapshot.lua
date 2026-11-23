local dev_os = require("dev.os")
local fs = require("dev.fs")
local xdg = require("dev.xdg")

---@class devrepo.snapshot
---@field SHARE string[] the entries of a checkout that an install ships
local M = {}

local KEEP = 3
local MAX_PER_SECOND = 100

M.SHARE = { "main.lua", "pkg.lua", "VERSION", "xtrace.bash", "lua", "docs", "init", "board" }

---Find the directory that holds the published snapshots of dev.
---@return string dir `dev/snapshot` under the user's state directory
function M.dir()
    return xdg.state_home() .. "/dev/snapshot"
end

local function prune(versions)
    local names = fs.list(versions) or {}
    table.sort(names)
    for index = 1, #names - KEEP do
        fs.remove(versions .. "/" .. names[index], { recursive = true })
    end
end

local function new_version(versions)
    local stamp = os.date("!%Y%m%d%H%M%S")
    local first = 0
    for _, name in ipairs(fs.list(versions) or {}) do
        local taken = name:match("^" .. stamp .. "%.(%d+)$")
        if taken then
            first = math.max(first, tonumber(taken) + 1)
        end
    end
    for count = first, MAX_PER_SECOND - 1 do
        local path = string.format("%s/%s.%02d", versions, stamp, count)
        if fs.mkdir(path) then
            return path
        end
    end
end

---Copy dev's tree to a new version directory and point `current` at it.
---
---A reader of `current` sees the old tree or the new one, never a partial copy. The newest three
---versions stay, so a dev that started on an older one can lose modules it loads late.
---@param root string the checkout whose `M.SHARE` entries are copied, written to `ORIGIN` for the
---   launcher to compare with its own
---@param dir string the snapshot directory, as `M.dir` returns it
---@return string? version the new version directory, nil on failure
---@return string? message why it failed
function M.publish(root, dir)
    local versions = dir .. "/versions"
    local ok, message = fs.mkdir(versions, { parents = true })
    if not ok then
        return nil, message
    end
    local version = new_version(versions)
    if not version then
        return nil, "Cannot make a version directory under " .. versions .. "."
    end
    local argv = { "cp", "-R" }
    for _, name in ipairs(M.SHARE) do
        argv[#argv + 1] = root .. "/" .. name
    end
    argv[#argv + 1] = version .. "/"
    local copied = dev_os.run(argv) == 0
    if not (copied and fs.write(version .. "/ORIGIN", root .. "\n")) then
        fs.remove(version, { recursive = true })
        return nil, "Cannot copy " .. root .. " to " .. version .. "."
    end
    local name = fs.basename(version)
    local pending = dir .. "/" .. name .. ".link"
    ok, message = fs.symlink("versions/" .. name, pending)
    if not ok then
        fs.remove(version, { recursive = true })
        return nil, message
    end
    local moved, why = os.rename(pending, dir .. "/current")
    if not moved then
        fs.remove(pending)
        fs.remove(version, { recursive = true })
        return nil, why
    end
    prune(versions)
    return version
end

return M
