local board = require("dev.board")
local dev_os = require("dev.os")
local http = require("dev.http")
local json = require("dev.json")

---@enum dev.board.device.Reason
local Reason = {
    UNREACHABLE = "unreachable",
    UNREADABLE = "unreadable",
    REFUSED = "refused",
    NO_CODE = "no_code",
    BAD_TOKEN = "bad_token",
    DENIED = "denied",
    EXPIRED = "expired",
    UNKNOWN = "unknown",
    QUOTA = "quota",
}

local CONNECT_SECONDS = 10
local REQUEST_SECONDS = 30
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
---goes only in the request body.
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
---@field curl_exit integer? the curl exit code the transport failure stands for
---@field status integer? the HTTP status of the reply
---@field message string? Pomb's message, ended with a period

local function post(url, body)
    local answer, _, kind = http.request({
        method = "POST",
        url = url,
        headers = { ["Content-Type"] = "application/json" },
        body = body,
        timeout = REQUEST_SECONDS,
        connect_timeout = CONNECT_SECONDS,
    })
    if not answer then
        return nil, Reason.UNREACHABLE, { url = url, curl_exit = board.curl_exit(kind) }
    end
    local doc = json.decode(answer.body)
    if type(doc) ~= "table" then
        return nil, Reason.UNREADABLE
    end
    return doc, answer.status
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
    local start, status, detail = post(
        opts.url .. "/api/v1/auth/device",
        assert(json.encode({ client_name = opts.client_name, scopes = { opts.scope } }))
    )
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
    local interval = tonumber(start.interval_seconds) or DEFAULT_INTERVAL
    local budget = tonumber(start.expires_in_seconds) or 0
    local waited = 0
    local redeem = assert(json.encode({ device_code = start.device_code }))
    while true do
        wait(interval)
        waited = waited + interval
        local reply, reply_status, reply_detail =
            post(opts.url .. "/api/v1/auth/device/token", redeem)
        if not reply then
            return nil, reply_status, reply_detail
        end
        if reply_status < HTTP_ERROR and type(reply.token) == "string" then
            if reply.token:find(TOKEN_PATTERN) then
                return reply.token
            end
            return nil, Reason.BAD_TOKEN
        end
        local code = code_of(reply, reply_status)
        if code == "slow_down" then
            interval = interval + SLOW_DOWN_SECONDS
        elseif code ~= "authorization_pending" then
            local reason = FINAL[code]
            if not reason then
                return nil, Reason.REFUSED, answered(reply_status, reply)
            end
            return nil, reason
        end
        if budget > 0 and waited > budget then
            return nil, Reason.EXPIRED
        end
    end
end

return M
