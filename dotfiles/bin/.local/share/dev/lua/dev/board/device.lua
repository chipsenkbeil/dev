local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")

local CONNECT_SECONDS = "10"
local REQUEST_SECONDS = "30"
local CHILD_UNSET = { "BASH_ENV", "ENV", "PS4", "VERBOSE" }
local HTTP_ERROR = 400
local TOKEN_PATTERN = "^[%w%._~%+/=-]+$"
local SLOW_DOWN_SECONDS = 5
local DEFAULT_INTERVAL = 5
local STATUS_CODES = {
    [428] = "authorization_pending",
    [429] = "slow_down",
    [403] = "access_denied",
    [410] = "device_code_expired",
}
local FINAL = {
    access_denied = "the sign-in was denied",
    device_code_expired = "the sign-in was not approved in time",
    invalid_grant = "pomb no longer knows this sign-in",
    quota_exceeded = "the account holds too many tokens, revoke one and run it again",
}

---Pomb's device sign-in (RFC 8628), which hands the person who approves it in
---a browser a token for one run.
---
---The token lives in the returned string alone. It is in no argument list, no
---environment variable, no file and no output, and the code that redeems it
---goes to curl through a file only its owner can read, which is gone when the
---poll ends.
---@class dev.board.device
local M = {}

---@class dev.board.device.Opts
---@field url string the server's base URL
---@field client_name string what the approver sees, 1 to 80 characters
---@field scope string the scope asked for
---@field say fun(line: string) prints one line

local function post(url, body_arg)
    local argv = {
        "curl",
        "-sS",
        "--connect-timeout",
        CONNECT_SECONDS,
        "--max-time",
        REQUEST_SECONDS,
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "-w",
        "\n%{http_code}",
    }
    for _, word in ipairs(body_arg) do
        argv[#argv + 1] = word
    end
    argv[#argv + 1] = url
    local out, code = devos.capture(argv, { unset = CHILD_UNSET, stderr = "null" })
    if code ~= 0 then
        return nil, "cannot reach " .. url .. " (curl exit " .. tostring(code) .. ")"
    end
    local text, status = out:match("^(.*)\n(%d+)$")
    local doc = text and json.decode(text)
    status = tonumber(status)
    if not status or type(doc) ~= "table" then
        return nil, "pomb sent an answer dev cannot read"
    end
    return doc, status
end

local function wait(seconds)
    devos.run({ "sleep", string.format("%d", seconds) })
end

local function code_of(doc, status)
    if type(doc.code) == "string" then
        return doc.code
    end
    return STATUS_CODES[status]
end

---Pair with the server and wait for the person to approve.
---@param opts dev.board.device.Opts the server, the client's name, the scope and where to print
---@return string? token the token, to hold in memory
---@return string? message why no token came
function M.pair(opts)
    local start, status = post(opts.url .. "/api/v1/auth/device", {
        "--data-raw",
        assert(json.encode({ client_name = opts.client_name, scopes = { opts.scope } })),
    })
    if not start then
        return nil, status
    end
    if status >= HTTP_ERROR then
        return nil,
            "pomb answered " .. status .. ": " .. tostring(
                json.present(start.message) or "no message"
            )
    end
    if type(start.device_code) ~= "string" or type(start.user_code) ~= "string" then
        return nil, "pomb sent a sign-in with no code"
    end
    opts.say("approve the " .. opts.scope .. " sign-in at " .. tostring(start.verification_url))
    opts.say("code: " .. start.user_code)
    local body = fs.mktemp({ prefix = "dev-device" })
    if not body then
        return nil, "cannot make a temporary file for the sign-in"
    end
    local interval = tonumber(start.interval_seconds) or DEFAULT_INTERVAL
    local budget = tonumber(start.expires_in_seconds) or 0
    local waited = 0
    local token, message
    local written = fs.write(body, assert(json.encode({ device_code = start.device_code })))
    while written do
        wait(interval)
        waited = waited + interval
        local reply, reply_status = post(opts.url .. "/api/v1/auth/device/token", {
            "--data-binary",
            "@" .. body,
        })
        if not reply then
            message = reply_status
            break
        end
        if reply_status < HTTP_ERROR and type(reply.token) == "string" then
            if reply.token:find(TOKEN_PATTERN) then
                token = reply.token
            else
                message = "pomb sent a token that is not plain text"
            end
            break
        end
        local code = code_of(reply, reply_status)
        if code == "slow_down" then
            interval = interval + SLOW_DOWN_SECONDS
        elseif code ~= "authorization_pending" then
            message = FINAL[code]
                or (
                    "pomb answered "
                    .. reply_status
                    .. ": "
                    .. tostring(json.present(reply.message) or "no message")
                )
            break
        end
        if budget > 0 and waited > budget then
            message = FINAL.device_code_expired
            break
        end
    end
    fs.remove(body)
    if not written then
        return nil, "cannot write the temporary file for the sign-in"
    end
    return token, message
end

return M
