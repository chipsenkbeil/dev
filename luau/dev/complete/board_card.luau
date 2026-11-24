local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local hash = require("@dev/hash")
local lock = require("@dev/lock")
local runtime = require("@dev/runtime")

local FRESH_SECONDS = 60
local LOCK_SECONDS = 20
local STALE_TEMP_SECONDS = 600

---@class dev.complete.board_card
local M = {}

local function cache_dir()
    local base = dev_os.getenv("XDG_CACHE_HOME")
    if not base or base == "" then
        base = (dev_os.getenv("HOME") or "") .. "/.cache"
    end
    return base .. "/dev"
end

---Return the cache file of a project's card list.
---@param root string the project root
---@return string path the file under the cache folder, named by a hash of the root
function M.cache_file(root)
    return cache_dir() .. "/cards-" .. hash.sha256(root):sub(1, 16)
end

local function sweep(file)
    local dir, prefix = fs.dirname(file), fs.basename(file) .. "."
    for _, name in ipairs(fs.list(dir) or {}) do
        local stamp = name:sub(1, #prefix) == prefix and name:match("%.%d+%.(%d+)%.tmp$")
        if stamp and os.time() - tonumber(stamp) > STALE_TEMP_SECONDS then
            fs.remove(dir .. "/" .. name)
        end
    end
end

---Write the cache from the card list of a project, the work of the detached refresh.
---@param root string the project root
---@param file string the cache file
---@return boolean written false when the card list could not be read or written
function M.refresh(root, file)
    sweep(file)
    local out, code = dev_os.capture(
        { runtime.exe, "-C", root, "board", "ls" },
        { stderr = "null" }
    )
    fs.remove(file .. ".lock")
    if code ~= 0 then
        return false
    end
    local tmp = file .. "." .. dev_os.getpid() .. "." .. os.time() .. ".tmp"
    fs.mkdir(fs.dirname(file), { parents = true })
    if not fs.write(tmp, os.time() .. "\n" .. out) then
        return false
    end
    if not fs.move(tmp, file) then
        fs.remove(tmp)
        return false
    end
    return true
end

local function lock_is_live(lock)
    local stamp = tonumber((fs.read(lock) or ""):match("^%d+"))
    return stamp ~= nil and os.time() - stamp < LOCK_SECONDS
end

local function start_refresh(root, file)
    fs.mkdir(fs.dirname(file), { parents = true })
    local guard = lock.try_lock(file .. ".guard")
    if not guard then
        return
    end
    local stamp_file = file .. ".lock"
    if not lock_is_live(stamp_file) then
        fs.write(stamp_file, tostring(os.time()))
        dev_os.spawn({ runtime.exe, "-C", root, "__complete", "--refresh-cards", file }, {
            detach = true,
            stdin = "null",
            stdout = "null",
            stderr = "null",
        })
    end
    guard:release()
end

---List the card ids the cache holds, and refresh the cache in the background when it is stale.
---@param ctx dev.complete.Context the completion context
---@return dev.complete.Item[] items an id and the rest of its line
function M.candidates(ctx)
    local file = M.cache_file(ctx.root)
    local text = fs.read(file)
    local stamp = text and tonumber(text:match("^(%d+)\n"))
    if not stamp or os.time() - stamp >= FRESH_SECONDS then
        start_refresh(ctx.root, file)
    end
    local items = {}
    for line in (text or ""):gmatch("[^\n]+") do
        local id, rest = line:match("^(%x%x%x%x%x%x%x%x)%s+(.-)%s*$")
        if id then
            items[#items + 1] = { value = id, desc = rest }
        end
    end
    return items
end

return M
