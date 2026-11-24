local board = require("dev.board")
local dev_lock = require("dev.lock")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local xdg = require("dev.xdg")

local PRIVATE_MODE = tonumber("600", 8)
local SHARED_MODE = tonumber("644", 8)
local STATE_NAME = "dev/boards"
local ID_BYTES = 16

---The files a local board and the offline queue live in: where they sit, a
---lock that keeps two processes from writing at once, and writes that rename a
---finished file into place.
---@class dev.board.store
local M = {}

---@class dev.board.store.Opts
---@field private boolean? whether the files are state no one else may read

---Find the directory that holds the boards and the queues.
---@return string dir the `dev/boards` directory under the state home
function M.dir()
    return xdg.state_home() .. "/" .. STATE_NAME
end

---Make a random id, the shape of a version 4 UUID.
---@return string id the id, in lower case hex
function M.id()
    local bytes = assert(dev_os.random_bytes(ID_BYTES))
    local hex = bytes:gsub(".", function(char)
        return string.format("%02x", char:byte())
    end)
    return string.format(
        "%s-%s-4%s-%x%s-%s",
        hex:sub(1, 8),
        hex:sub(9, 12),
        hex:sub(14, 16),
        8 + tonumber(hex:sub(17, 17), 16) % 4,
        hex:sub(18, 20),
        hex:sub(21, 32)
    )
end

---@type fun(): integer
M.now = os.time

---Tell the time as an RFC 3339 stamp in UTC.
---@param at integer? seconds since the epoch, `now()` when nil
---@return string stamp the stamp, such as `2026-10-27T22:28:05Z`
function M.stamp(at)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", at or M.now())
end

---Make a directory, at mode 700 when it holds private state.
---@param dir string the directory
---@param private boolean? whether the directory holds state no one else may read
---@return true? ok true on success
---@return string? message the lower layer's message, nil when the reason names the refusal
---@return dev.board.FileReason? reason the fixed reason it failed
---@return string? detail the directory the reason names
local function prepare(dir, private)
    local ok, message = fs.mkdir(dir, { parents = true })
    if not ok then
        return nil, message
    end
    if private and dev_os.run({ "chmod", "700", dir }) ~= 0 then
        return nil, nil, board.FileReason.PROTECT, dir
    end
    return true
end

---Run a function while holding the exclusive lock beside a file.
---
---The lock is `<path>.lock` for a private file. Any other file keeps its lock in the
---state directory, named for the file's path, so the project tree gets no lock
---file. The system drops it when the process ends, so a crash never leaves one
---behind.
---@generic A, B
---@param path string the file the lock guards
---@param opts dev.board.store.Opts? whether the files are private
---@param fn fun(): A?, B? what to run
---@return A? first what `fn` returned, nil when the lock could not be taken
---@return B|string? second the second value of `fn`, or the lower layer's message when the lock
---   could not be taken
---@return dev.board.FileReason? reason the fixed reason the lock could not be taken
---@return string? detail the path or directory the reason names
function M.locked(path, opts, fn)
    local private = opts and opts.private
    local lock = path .. ".lock"
    if not private then
        lock = M.dir() .. "/locks/" .. path:gsub("[^%w._-]", "_") .. ".lock"
    end
    local ok, message, reason, detail = prepare(fs.dirname(lock), true)
    if not ok then
        return nil, message, reason, detail
    end
    ok, message, reason, detail = prepare(fs.dirname(path), private)
    if not ok then
        return nil, message, reason, detail
    end
    local handle, err = dev_lock.lock(lock, { mode = PRIVATE_MODE })
    if not handle then
        return nil, tostring(err), board.FileReason.LOCK, path
    end
    local ran, first, second = pcall(fn)
    handle:release()
    if not ran then
        error(first, 0)
    end
    return first, second
end

---Read a JSON file.
---@param path string the file
---@return any? doc the decoded document, nil when the file is missing or unreadable
---@return string? message the lower layer's message, nil when the file is missing or the reason
---   names the refusal
---@return dev.board.FileReason? reason the fixed reason it could not be used
---@return string? detail the path the reason names
function M.read(path)
    if not fs.exists(path) then
        return nil
    end
    local text, err = fs.read(path)
    if not text then
        return nil, tostring(err), board.FileReason.READ, path
    end
    local doc = json.decode(text)
    if doc == nil then
        return nil, nil, board.FileReason.NOT_JSON, path
    end
    return doc
end

---Write a file by making a temporary one beside it and renaming it over.
---@param path string the file
---@param text string what it holds
---@param opts dev.board.store.Opts? whether to make it readable by its owner alone
---@return true? ok true on success
---@return string? message the lower layer's message, nil when the reason names the refusal
---@return dev.board.FileReason? reason the fixed reason it failed
---@return string? detail the path or directory the reason names
function M.write(path, text, opts)
    local private = opts and opts.private
    local ok, message, reason, detail = prepare(fs.dirname(path), private)
    if not ok then
        return nil, message, reason, detail
    end
    local mode = private and PRIVATE_MODE or SHARED_MODE
    ok, message = fs.write(path, text, { mode = mode, atomic = true })
    if not ok then
        return nil, tostring(message), board.FileReason.WRITE, path
    end
    return true
end

return M
