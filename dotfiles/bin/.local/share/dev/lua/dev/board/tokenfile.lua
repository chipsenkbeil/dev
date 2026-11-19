local dev_os = require("dev.os")
local fs = require("dev.fs")
local xdg = require("dev.xdg")

local TOKENS_DIR = "dev/tokens"
local HASH_LENGTH = 64
local SOON_SECONDS = 3600

---The role tokens `dev board token mint` keeps for runners: one file per
---agent name, named by a hash of the name, in a directory only the owner can
---enter. A file holds the token on its first line and the expiry, in Unix
---seconds, on its second.
---@class dev.board.tokenfile
local M = {}

---@class dev.board.tokenfile.Token
---@field token string the raw token
---@field expires integer the expiry in Unix seconds, 0 for none

---Find the directory that holds the token files.
---@return string dir `dev/tokens` under `XDG_RUNTIME_DIR` when that is an absolute path, else under
---   the state home
function M.dir()
    local runtime = os.getenv("XDG_RUNTIME_DIR")
    if runtime and runtime:sub(1, 1) == "/" then
        return runtime .. "/" .. TOKENS_DIR
    end
    return xdg.state_home() .. "/" .. TOKENS_DIR
end

local function checksum_command()
    if dev_os.which("shasum") then
        return { "shasum", "-a", "256" }
    elseif dev_os.which("sha256sum") then
        return { "sha256sum" }
    end
end

---Name the file of an agent.
---@param name string the agent's name, the `DEV_AGENT` value
---@return string? path the file, under the token directory
---@return string? message why the name could not be hashed
function M.path(name)
    local argv = checksum_command()
    if not argv then
        return nil, "neither shasum nor sha256sum is on PATH"
    end
    local out, code = dev_os.capture_input(argv, name, { stderr = "null" })
    local sum = code == 0 and out:match("^(%x+)")
    if not sum or #sum ~= HASH_LENGTH then
        return nil, "could not hash the agent name"
    end
    return M.dir() .. "/" .. sum:lower()
end

local function parse(text)
    local token, expires = text:match("^([^\n]+)\n(%d+)\n?$")
    if token then
        return { token = token, expires = tonumber(expires) }
    end
end

---Write an agent's token file, mode 600 in a directory of mode 700.
---@param name string the agent's name
---@param token string the raw token
---@param expires integer the expiry in Unix seconds, 0 for none
---@return true? ok true on success
---@return string? message why it failed
function M.write(name, token, expires)
    local path, message = M.path(name)
    if not path then
        return nil, message
    end
    local dir = M.dir()
    if
        dev_os.run({ "sh", "-c", 'umask 077 && mkdir -p -- "$1" && chmod 700 "$1"', "sh", dir })
        ~= 0
    then
        return nil, "cannot make " .. dir
    end
    local pending = path .. ".new"
    if dev_os.run({ "sh", "-c", 'umask 077 && : >"$1"', "sh", pending }) ~= 0 then
        return nil, "cannot write " .. path
    end
    local ok
    ok, message = fs.write(pending, string.format("%s\n%d\n", token, expires))
    if not ok then
        fs.remove(pending)
        return nil, message
    end
    if dev_os.run({ "mv", "-f", pending, path }) ~= 0 then
        fs.remove(pending)
        return nil, "cannot write " .. path
    end
    return true
end

---Read an agent's token file.
---@param name string the agent's name
---@return dev.board.tokenfile.Token? found the token, nil when there is no file or it cannot be
---   read
---@return string? message why a file that exists cannot be used
function M.read(name)
    local path = M.path(name)
    if not path or not fs.exists(path) then
        return nil
    end
    local text = fs.read(path)
    local found = text and parse(text)
    if not found then
        return nil, "the token file " .. path .. " is not a token file"
    end
    return found
end

---Delete an agent's token file.
---@param name string the agent's name
---@return true? ok true when the file is gone, or there was none
---@return string? message why it could not be deleted
function M.remove(name)
    local path, message = M.path(name)
    if not path then
        return nil, message
    end
    if not fs.exists(path) then
        return true
    end
    local ok
    ok, message = fs.remove(path)
    if not ok then
        return nil, "cannot delete " .. path
    end
    return true
end

---Delete every token file whose expiry has passed.
---@param now integer the time in Unix seconds
---@return integer removed how many files went
function M.sweep(now)
    local dir = M.dir()
    local names = fs.list(dir)
    local removed = 0
    for _, entry in ipairs(names or {}) do
        local text = fs.read(dir .. "/" .. entry)
        local found = text and parse(text)
        if found and found.expires > 0 and found.expires <= now then
            fs.remove(dir .. "/" .. entry)
            removed = removed + 1
        end
    end
    return removed
end

---Count the token files that expire within an hour and those already expired.
---@param now integer the time in Unix seconds
---@return integer soon files that expire within the next hour
---@return integer expired files whose expiry has passed
function M.expiring(now)
    local dir = M.dir()
    local soon, expired = 0, 0
    for _, entry in ipairs(fs.list(dir) or {}) do
        local text = fs.read(dir .. "/" .. entry)
        local found = text and parse(text)
        if found and found.expires > 0 then
            if found.expires <= now then
                expired = expired + 1
            elseif found.expires <= now + SOON_SECONDS then
                soon = soon + 1
            end
        end
    end
    return soon, expired
end

return M
