local dev_command = require("@dev/command")
local dev_lock = require("@dev/lock")
local dev_os = require("@dev/os")
local keychain = require("@dev/board/keychain")

local PASS_SECONDS = 10
local WAIT_SECONDS = 120
local TIMED_OUT = 124
local FAILED = 1
local GPG_OPTS = "--pinentry-mode error --batch"
local TOKEN_PATTERN = "^[%w%._~%+/=-]+$"
local CHILD_UNSET = { "BASH_ENV", "ENV", "PS4", "VERBOSE" }

---Read a Pomb token from the password store without a prompt, one process at a time.
---
---The Keychain answers first. A miss waits on one lock every process shares,
---reads the Keychain again in case the holder filled it, then reads the store
---with a locked store failing at once, and caches what it read.
---@class dev.board.passlock
local M = {}

---Where the token came from.
---@enum dev.board.passlock.Source
M.Source = { KEYCHAIN = "keychain", PASS = "pass" }

local function setting(name)
    local value = dev_os.getenv(name)
    if value and value ~= "" then
        return value
    end
end

local function cached(entry)
    local out = keychain.get(entry)
    local first = out:match("^[^\n]*")
    if first:find(TOKEN_PATTERN) then
        return first
    end
end

local function read_locked(entry)
    local token = cached(entry)
    if token then
        return token, 0, M.Source.KEYCHAIN
    end
    local out, code = dev_os.capture_timed(
        { "pass", "show", entry },
        PASS_SECONDS,
        { env = { PASSWORD_STORE_GPG_OPTS = GPG_OPTS }, unset = CHILD_UNSET, stderr = "null" }
    )
    if code ~= 0 then
        return nil, code
    end
    token = out:match("^[^\n]*")
    keychain.put(entry, token)
    return token, 0, M.Source.PASS
end

local function lock_path()
    return setting("DEV_PASS_LOCK") or ("/tmp/dev-pass-" .. dev_os.getuid() .. ".lock")
end

---Read the token of a `pass` entry.
---
---The lock is `DEV_PASS_LOCK`, else `/tmp/dev-pass-UID.lock`, and the wait for it is
---`DEV_PASS_LOCK_SECS` seconds, else 120.
---@param entry string the `pass` entry
---@return string? token the first line `pass` printed or the cached token, nil on failure
---@return integer code 0 on success, 124 when the lock wait or `pass` ran out of time, 1 when the
---   lock could not be taken, else the code of `pass`
---@return dev.board.passlock.Source|string|nil source where the token came from, or the lower
---   layer's message when the lock could not be taken
function M.read(entry)
    local token = cached(entry)
    if token then
        return token, 0, M.Source.KEYCHAIN
    end
    local wait = tonumber((setting("DEV_PASS_LOCK_SECS"))) or WAIT_SECONDS
    local started = dev_os.monotonic()
    local handle, message = dev_lock.lock(lock_path(), { timeout = wait })
    if not handle then
        if dev_os.monotonic() - started >= wait then
            return nil, TIMED_OUT
        end
        return nil, FAILED, tostring(message)
    end
    local ran, found, code, source = pcall(read_locked, entry)
    handle:release()
    if not ran then
        error(found, 0)
    end
    return found, code, source
end

---Run `dev __board passlock ENTRY`: print the token, then `keychain` on a second
---line when the Keychain held it.
---@param entry string the `pass` entry
---@return integer code the exit code of `read`
function M.main(entry)
    local token, code, source = M.read(entry)
    if not token then
        if source then
            dev_command.note(
                "Cannot lock " .. lock_path() .. ": " .. (source:gsub("%.$", "")) .. "."
            )
        end
        return code
    end
    dev_os.stdout:write(token, "\n")
    if source == M.Source.KEYCHAIN then
        dev_os.stdout:write(M.Source.KEYCHAIN, "\n")
    end
    return code
end

return M
