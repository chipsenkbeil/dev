local dev_os = require("dev.os")

local TIMEOUT_SECONDS = 3
local NOT_FOUND = 44
local FAILED = 1
local UNKNOWN_SUBCOMMAND = 2
local SERVICE_PREFIX = "dev-pomb-token:"
local ENTRY_PATTERN = "^[%w_./ %-]+$"
local TOKEN_PATTERN = "^[%w%._~%+/=-]+$"
local CHILD_UNSET = { "BASH_ENV", "ENV", "PS4", "VERBOSE" }

---The macOS Keychain cache of Pomb tokens read from the password store, one generic
---password per password store entry, each call limited to 3 seconds.
---A token reaches the Keychain on standard input, never in an argument list.
---@class dev.board.keychain
local M = {}

local function account()
    local user = dev_os.getenv("USER")
    if user and user ~= "" then
        return user
    end
    local out = dev_os.capture({ "id", "-un" }, { stderr = "null" })
    return (out:gsub("\n$", ""))
end

local function security(args, input)
    local argv = { "security" }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    return dev_os.capture_timed(
        argv,
        TIMEOUT_SECONDS,
        { input = input, unset = CHILD_UNSET, stderr = "null" }
    )
end

local function usable(entry)
    return dev_os.which("security") ~= nil
        and type(entry) == "string"
        and entry:find(ENTRY_PATTERN) ~= nil
end

---Read the cached token of an entry.
---@param entry string the `pass` entry
---@return string out what `security` wrote, the token and a newline when found
---@return integer code 0 when found, 1 when `security` is missing or the entry is not usable, else
---   the code of `security`
function M.get(entry)
    if not usable(entry) then
        return "", FAILED
    end
    return security({
        "find-generic-password",
        "-a",
        account(),
        "-s",
        SERVICE_PREFIX .. entry,
        "-w",
    })
end

---Cache the token of an entry, replacing any cached one.
---@param entry string the `pass` entry
---@param token string the token
---@return integer code 0 when stored, 1 when `security` is missing or the entry or token is not
---   usable, else the code of `security`
function M.put(entry, token)
    if not usable(entry) or not token:find(TOKEN_PATTERN) then
        return FAILED
    end
    local line = string.format(
        'add-generic-password -U -a "%s" -s "%s" -T /usr/bin/security -w "%s"\n',
        account(),
        SERVICE_PREFIX .. entry,
        token
    )
    local _, code = security({ "-i" }, line)
    return code
end

---Delete the cached token of an entry.
---@param entry string the `pass` entry
---@return integer code 0 when it is gone or was never there, else 1
function M.drop(entry)
    if not usable(entry) then
        return FAILED
    end
    local _, code = security({
        "delete-generic-password",
        "-a",
        account(),
        "-s",
        SERVICE_PREFIX .. entry,
    })
    if code == 0 or code == NOT_FOUND then
        return 0
    end
    return FAILED
end

---Run `dev __board keychain SUBCOMMAND ENTRY`: get prints the token, put reads
---it from standard input, drop deletes it.
---@param subcommand string? `get`, `put` or `drop`
---@param entry string? the `pass` entry
---@return integer code the exit code, 2 for an unknown subcommand
function M.main(subcommand, entry)
    if not usable(entry) then
        return FAILED
    end
    if subcommand == "get" then
        local out, code = M.get(entry)
        dev_os.stdout:write(out)
        return code
    elseif subcommand == "put" then
        return M.put(entry, dev_os.stdin:read("*l") or "")
    elseif subcommand == "drop" then
        return M.drop(entry)
    end
    return UNKNOWN_SUBCOMMAND
end

return M
