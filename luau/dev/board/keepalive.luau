local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local http = require("@dev/http")
local keychain = require("@dev/board/keychain")
local passlock = require("@dev/board/passlock")

local CONNECT_SECONDS = 10
local REQUEST_SECONDS = 30
local UNAUTHORIZED = 401
local SUCCESS_LOW, SUCCESS_HIGH = 200, 299
local CLIENT_LOW, CLIENT_HIGH = 400, 499
local TOKEN_PATTERN = "^[%w%._~%+/=-]+$"

---The loop that renews a claim on Pomb every tick while its state file still
---holds the claim's fence, started by `dev board take` as its own process.
---@class dev.board.keepalive
local M = {}

---@class dev.board.keepalive.Args
---@field state string the claim's state file
---@field card string the card's full id
---@field fence string the fence of the claim
---@field ticks integer the most renewals to send
---@field url string the server's base URL
---@field entry string the `pass` entry of the token
---@field tick number the seconds between two renewals
---@field name string the holder's name
---@field lease string the lease in seconds each renewal asks for
---@field tokenfile string? the role token file of the holder

local function holds(state, fence)
    local text = fs.read(state)
    if not text then
        return false
    end
    return ("\n" .. text .. "\n"):find("\nfence=" .. fence .. "\n", 1, true) ~= nil
end

local function nap(seconds)
    local sleeper = dev_os.spawn({ "sleep", tostring(seconds) })
    if not sleeper then
        dev_os.nap(seconds)
    elseif sleeper:wait() == nil then
        sleeper:kill()
    end
end

local function filed(path)
    local text = fs.read(path) or ""
    local token, expires = text:match("^([^\n]*)\n?([^\n]*)")
    if not expires:find("^%d+$") then
        return nil
    end
    if expires ~= "0" and tonumber(expires) <= os.time() then
        return nil
    end
    return token
end

local function read_token(args)
    local issued = dev_os.getenv("DEV_BOARD_TOKEN")
    if issued and issued ~= "" then
        return issued:match("^([^\n]*)\n?(.*)")
    end
    if args.tokenfile and args.tokenfile ~= "" and fs.is_file(args.tokenfile) then
        return filed(args.tokenfile)
    end
    local token, _, source = passlock.read(args.entry)
    return token, source
end

local function renew(args, token)
    local answer = http.request({
        method = "POST",
        url = args.url .. "/api/tasks/" .. args.card .. "/owner/renew",
        headers = {
            Authorization = "Bearer " .. token,
            ["Content-Type"] = "application/json",
            ["If-Owner-Fence"] = args.fence,
        },
        body = '{"name":"' .. args.name .. '","ttl_seconds":' .. args.lease .. "}",
        timeout = REQUEST_SECONDS,
        connect_timeout = CONNECT_SECONDS,
    })
    return answer and answer.status
end

---Renew a claim until its state file loses the fence, Pomb refuses a renewal
---or the ticks run out, then delete the state file if it still holds the fence.
---@param args dev.board.keepalive.Args what the loop renews and how often
---@return integer code 0, while TERM, INT or HUP raise the interrupt out of it
function M.run(args)
    local healed = false
    local n = 0
    while n < args.ticks do
        nap(args.tick)
        if not holds(args.state, args.fence) then
            return 0
        end
        local token, origin = read_token(args)
        if token and token:find(TOKEN_PATTERN) then
            local status = renew(args, token)
            if status and status >= SUCCESS_LOW and status <= SUCCESS_HIGH then
                healed = false
                fs.write(args.state .. ".beat", os.time() .. "\n")
            elseif status == UNAUTHORIZED then
                if origin ~= passlock.Source.KEYCHAIN or healed then
                    break
                end
                healed = true
                if keychain.drop(args.entry) ~= 0 then
                    break
                end
            elseif status and status >= CLIENT_LOW and status <= CLIENT_HIGH then
                break
            end
        end
        n = n + 1
    end
    if holds(args.state, args.fence) then
        fs.remove(args.state)
    end
    return 0
end

return M
