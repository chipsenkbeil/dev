local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")

---@enum dev.board.device.Reason
local Reason = {
    UNREACHABLE = "unreachable",
    UNREADABLE = "unreadable",
    REFUSED = "refused",
    NO_CODE = "no_code",
    NO_TEMP = "no_temp",
    WRITE_TEMP = "write_temp",
    BAD_TOKEN = "bad_token",
    DENIED = "denied",
    EXPIRED = "expired",
    UNKNOWN = "unknown",
    QUOTA = "quota",
}

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
    access_denied = Reason.DENIED,
    device_code_expired = Reason.EXPIRED,
    invalid_grant = Reason.UNKNOWN,
    quota_exceeded = Reason.QUOTA,
}

---Pomb's device sign-in (RFC 8628), which hands the person who approves it in
---a browser a token for one run.
---
---The token lives in the returned string alone. It is in no argument list, no
---environment variable, no file and no output, and the code that redeems it
---goes to curl through a file only its owner can read, which is gone when the
---poll ends.
---@class dev.board.device
---@field Reason table<string, dev.board.device.Reason> the reasons `pair` names when no token comes
local M = { Reason = Reason }

---@class dev.board.device.Opts
---@field url string the server's base URL
---@field client_name string what the approver sees, 1 to 80 characters
---@field scope string the scope asked for
---@field say fun(line: string) prints one line

---@class dev.board.device.Detail
---@field url string? the server that did not answer
---@field curl_exit integer? curl's exit code
---@field status integer? the HTTP status of the reply
---@field message string? Pomb's message, ended with a period

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
    local out, code = dev_os.capture(argv, { unset = CHILD_UNSET, stderr = "null" })
    if code ~= 0 then
        return nil, Reason.UNREACHABLE, { url = url, curl_exit = code }
    end
    local text, status = out:match("^(.*)\n(%d+)$")
    local doc = text and json.decode(text)
    status = tonumber(status)
    if not status or type(doc) ~= "table" then
        return nil, Reason.UNREADABLE
    end
    return doc, status
end

local function wait(seconds)
    dev_os.run({ "sleep", string.format("%d", seconds) })
end

local function code_of(doc, status)
    if type(doc.code) == "string" then
        return doc.code
    end
    return STATUS_CODES[status]
end

local function answered(status, doc)
    local message = json.present(doc.message)
    if message ~= nil then
        message = tostring(message)
        if not message:find("%.$") then
            message = message .. "."
        end
    end
    return { status = status, message = message }
end

---Pair with the server and wait for the person to approve.
---@param opts dev.board.device.Opts the server, the client's name, the scope and where to print
---@return string? token the token, to hold in memory
---@return dev.board.device.Reason? reason why no token came
---@return dev.board.device.Detail? detail the url and curl exit, or the status and Pomb's message,
---   when the reason has one
function M.pair(opts)
    local start, status, detail = post(opts.url .. "/api/v1/auth/device", {
        "--data-raw",
        assert(json.encode({ client_name = opts.client_name, scopes = { opts.scope } })),
    })
    if not start then
        return nil, status, detail
    end
    if status >= HTTP_ERROR then
        return nil, Reason.REFUSED, answered(status, start)
    end
    if type(start.device_code) ~= "string" or type(start.user_code) ~= "string" then
        return nil, Reason.NO_CODE
    end
    opts.say(
        "Open "
            .. tostring(start.verification_url)
            .. " to approve the "
            .. opts.scope
            .. " sign-in."
    )
    opts.say("The code is " .. start.user_code .. ".")
    local body = fs.mktemp({ prefix = "dev-device" })
    if not body then
        return nil, Reason.NO_TEMP
    end
    local interval = tonumber(start.interval_seconds) or DEFAULT_INTERVAL
    local budget = tonumber(start.expires_in_seconds) or 0
    local waited = 0
    local token, reason, why
    local written = fs.write(body, assert(json.encode({ device_code = start.device_code })))
    while written do
        wait(interval)
        waited = waited + interval
        local reply, reply_status, reply_detail = post(opts.url .. "/api/v1/auth/device/token", {
            "--data-binary",
            "@" .. body,
        })
        if not reply then
            reason, why = reply_status, reply_detail
            break
        end
        if reply_status < HTTP_ERROR and type(reply.token) == "string" then
            if reply.token:find(TOKEN_PATTERN) then
                token = reply.token
            else
                reason = Reason.BAD_TOKEN
            end
            break
        end
        local code = code_of(reply, reply_status)
        if code == "slow_down" then
            interval = interval + SLOW_DOWN_SECONDS
        elseif code ~= "authorization_pending" then
            reason = FINAL[code]
            if not reason then
                reason, why = Reason.REFUSED, answered(reply_status, reply)
            end
            break
        end
        if budget > 0 and waited > budget then
            reason = Reason.EXPIRED
            break
        end
    end
    fs.remove(body)
    if not written then
        return nil, Reason.WRITE_TEMP
    end
    return token, reason, why
end

return M
