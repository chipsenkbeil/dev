local dev_os = require("dev.os")
local ffi = require("ffi")
local fs = require("dev.fs")
local json = require("dev.json")
local xdg = require("dev.xdg")

ffi.cdef([[
typedef struct dev_file dev_file;
int flock(int fd, int operation);
int fileno(dev_file *stream);
unsigned int umask(unsigned int mask);
]])

local LOCK_EX = 2
local LOCK_UN = 8
local PRIVATE_UMASK = 63
local SHARED_UMASK = 18
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
    local file = assert(io.open("/dev/urandom", "rb"))
    local bytes = assert(file:read(ID_BYTES))
    file:close()
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
---@return string? message why it failed
local function prepare(dir, private)
    local ok, message = fs.mkdir(dir, { parents = true })
    if not ok then
        return nil, message
    end
    if private and dev_os.run({ "chmod", "700", dir }) ~= 0 then
        return nil, "cannot protect " .. dir
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
---@return B|string? second the second value of `fn`, or why the lock could not be taken
function M.locked(path, opts, fn)
    local private = opts and opts.private
    local lock = path .. ".lock"
    if not private then
        lock = M.dir() .. "/locks/" .. path:gsub("[^%w._-]", "_") .. ".lock"
    end
    local ok, message = prepare(fs.dirname(lock), true)
    if not ok then
        return nil, message
    end
    ok, message = prepare(fs.dirname(path), private)
    if not ok then
        return nil, message
    end
    local previous = ffi.C.umask(PRIVATE_UMASK)
    local file, err = io.open(lock, "a")
    ffi.C.umask(previous)
    if not file then
        return nil, "cannot lock " .. path .. ": " .. tostring(err)
    end
    local fd = ffi.C.fileno(file)
    if ffi.C.flock(fd, LOCK_EX) ~= 0 then
        file:close()
        return nil, "cannot lock " .. path
    end
    local ran, first, second = pcall(fn)
    ffi.C.flock(fd, LOCK_UN)
    file:close()
    if not ran then
        error(first, 0)
    end
    return first, second
end

---Read a JSON file.
---@param path string the file
---@return any? doc the decoded document, nil when the file is missing or unreadable
---@return string? message why, nil when the file is simply missing
function M.read(path)
    if not fs.exists(path) then
        return nil
    end
    local text, err = fs.read(path)
    if not text then
        return nil, "cannot read " .. path .. ": " .. tostring(err)
    end
    local doc = json.decode(text)
    if doc == nil then
        return nil, path .. " is not valid JSON"
    end
    return doc
end

---Write a file by making a temporary one beside it and renaming it over.
---@param path string the file
---@param text string what it holds
---@param opts dev.board.store.Opts? whether to make it readable by its owner alone
---@return true? ok true on success
---@return string? message why it failed
function M.write(path, text, opts)
    local private = opts and opts.private
    local ok, message = prepare(fs.dirname(path), private)
    if not ok then
        return nil, message
    end
    local pending = string.format("%s.%d.%s.new", path, os.time(), M.id():sub(1, 8))
    local previous = ffi.C.umask(private and PRIVATE_UMASK or SHARED_UMASK)
    ok, message = fs.write(pending, text)
    ffi.C.umask(previous)
    if not ok then
        return nil, "cannot write " .. path .. ": " .. tostring(message)
    end
    local renamed, err = os.rename(pending, path)
    if not renamed then
        fs.remove(pending)
        return nil, "cannot write " .. path .. ": " .. tostring(err)
    end
    return true
end

return M
