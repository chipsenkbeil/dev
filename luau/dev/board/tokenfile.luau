local board = require("@dev/board")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local hash = require("@dev/hash")
local xdg = require("@dev/xdg")

local TOKENS_DIR = "dev/tokens"
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
    local runtime = dev_os.getenv("XDG_RUNTIME_DIR")
    if runtime and runtime:sub(1, 1) == "/" then
        return runtime .. "/" .. TOKENS_DIR
    end
    return xdg.state_home() .. "/" .. TOKENS_DIR
end

---Name the file of an agent.
---@param name string the agent's name, the `DEV_AGENT` value
---@return string path the file, under the token directory
function M.path(name)
    return M.dir() .. "/" .. hash.sha256(name)
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
---@return string? message the lower layer's message, nil when the reason names the refusal
---@return dev.board.FileReason? reason the fixed reason it failed
---@return string? detail the path or directory the reason names
function M.write(name, token, expires)
    local path = M.path(name)
    local dir = M.dir()
    if
        dev_os.run({ "sh", "-c", 'umask 077 && mkdir -p -- "$1" && chmod 700 "$1"', "sh", dir })
        ~= 0
    then
        return nil, nil, board.FileReason.MAKE_DIR, dir
    end
    local pending = path .. ".new"
    if dev_os.run({ "sh", "-c", 'umask 077 && : >"$1"', "sh", pending }) ~= 0 then
        return nil, nil, board.FileReason.WRITE, path
    end
    local ok, message = fs.write(pending, string.format("%s\n%d\n", token, expires))
    if not ok then
        fs.remove(pending)
        return nil, message
    end
    if dev_os.run({ "mv", "-f", pending, path }) ~= 0 then
        fs.remove(pending)
        return nil, nil, board.FileReason.WRITE, path
    end
    return true
end

---Read an agent's token file.
---@param name string the agent's name
---@return dev.board.tokenfile.Token? found the token, nil when there is no file or it cannot be
---   read
---@return string? message the lower layer's message, nil when the reason names the refusal
---@return dev.board.FileReason? reason why a file that exists cannot be used
---@return string? detail the path of that file
function M.read(name)
    local path = M.path(name)
    if not fs.exists(path) then
        return nil
    end
    local text = fs.read(path)
    local found = text and parse(text)
    if not found then
        return nil, nil, board.FileReason.NOT_TOKEN_FILE, path
    end
    return found
end

---Delete an agent's token file.
---@param name string the agent's name
---@return true? ok true when the file is gone, or there was none
---@return string? message the lower layer's message, nil when the reason names the refusal
---@return dev.board.FileReason? reason the fixed reason it could not be deleted
---@return string? detail the path the reason names
function M.remove(name)
    local path = M.path(name)
    if not fs.exists(path) then
        return true
    end
    if not fs.remove(path) then
        return nil, nil, board.FileReason.DELETE, path
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
