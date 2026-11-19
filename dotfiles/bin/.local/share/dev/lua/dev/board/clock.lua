local board = require("dev.board")
local claims = require("dev.board.claims")
local fs = require("dev.fs")
local guards = require("dev.board.guards")

local SUFFIX = ".clock"
local SECONDS_PER_MINUTE = 60
local START = "start"
local STOP = "stop"

---The role clock `dev board time start` runs: one state file per card beside
---the claim state, holding the role and the start time on this machine.
---@class dev.board.clock
local M = {}

---The most minutes one entry logs.
M.MAX_MINUTES = 1440

---The words after `dev board time` that run the clock.
M.WORDS = { [START] = true, [STOP] = true }

---Trim a role flag and refuse a blank one or one with control characters.
---@param flag string? the `--as` value
---@return string? role the role, nil when the flag is missing or unusable
function M.role(flag)
    local role = flag and flag:match("^%s*(.-)%s*$")
    if not role or role == "" or role:find("%c") then
        return nil
    end
    return role
end

---@class dev.board.clock.State
---@field card string the card's full id
---@field role string the role the stretch counts for
---@field start integer the epoch seconds the clock started

---Read the seconds since the epoch. Tests replace it.
---@return integer seconds the current time
function M.now()
    return os.time()
end

---Name the state file of a card's clock.
---@param card string the card's full id
---@return string path the file
function M.path(card)
    return claims.path(card) .. SUFFIX
end

---Read a card's running clock.
---@param card string the card's full id
---@return dev.board.clock.State? state the clock, nil when none runs
function M.read(card)
    local text = fs.read(M.path(card))
    local start = text and tonumber(text:match("start=(%d+)"))
    local role = text and text:match("role=([^\n]+)")
    if not start or not role then
        return nil
    end
    return { card = card, role = role, start = start }
end

---Count the minutes a stretch logs, rounded and held within 1 to 1440.
---@param seconds integer the elapsed seconds
---@return integer minutes the minutes
function M.minutes(seconds)
    local minutes = math.floor(seconds / SECONDS_PER_MINUTE + 0.5)
    return math.min(M.MAX_MINUTES, math.max(1, minutes))
end

---Start a card's clock.
---@param card dev.board.Card the card
---@param role string the role the stretch counts for
---@return dev.cmd.board.Result result the refusal, or the start line
function M.start(card, role)
    local prefix = card.id:sub(1, board.MIN_PREFIX)
    for _, label in ipairs(card.labels or {}) do
        if label == board.NEEDS_HUMAN then
            return guards.failure(
                "Card " .. prefix .. " is " .. board.NEEDS_HUMAN .. ". Nobody works it."
            )
        end
    end
    local running = M.read(card.id)
    if running then
        return guards.failure(
            "Card " .. prefix .. " already has a running " .. running.role .. " clock."
        )
    end
    local ok, message = fs.mkdir(claims.dir(), { parents = true })
    if ok then
        ok, message = fs.write(
            M.path(card.id),
            string.format("card=%s\nrole=%s\nstart=%d\n", card.id, role, M.now())
        )
    end
    if not ok then
        return guards.failure(message)
    end
    return { output = "started the " .. role .. " clock on " .. prefix }
end

---Stop a card's clock and log its stretch on the card.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@param note string? the note stored with the entry
---@return dev.cmd.board.Result result the refusal, or the line naming the logged minutes
function M.stop(backend, card, note)
    local prefix = card.id:sub(1, board.MIN_PREFIX)
    local running = M.read(card.id)
    if not running then
        return guards.failure("Card " .. prefix .. " has no running clock.")
    end
    local minutes = M.minutes(M.now() - running.start)
    local ok, message = backend:log_time(card.id, minutes, running.role, note)
    if not ok then
        return guards.failure(message)
    end
    fs.remove(M.path(card.id))
    return { output = "logged " .. minutes .. " minutes as " .. running.role .. " on " .. prefix }
end

---Run `time start` or `time stop` from its parsed words and flags.
---@param backend dev.board.Backend the board
---@param positional string[] the words, the clock word then the card
---@param as_flag string? the `--as` value
---@param note string? the `--note` value
---@param find fun(word: string): dev.board.Card?, dev.cmd.board.Result? the card lookup
---@return dev.cmd.board.Result result the outcome of the verb
function M.run(backend, positional, as_flag, note, find)
    local word = positional[1]
    if #positional ~= 2 then
        return guards.usage("Needs a card after " .. word .. ".")
    elseif word == START and not M.role(as_flag) then
        return guards.usage(
            "The " .. guards.AS_FLAG .. " flag needs the role the clock counts for."
        )
    elseif word == STOP and as_flag then
        return guards.usage(
            "A stop takes no " .. guards.AS_FLAG .. " flag. The clock keeps its role."
        )
    end
    local card, missing = find(positional[2])
    if not card then
        return missing
    end
    if word == START then
        return M.start(card, M.role(as_flag))
    end
    return M.stop(backend, card, note)
end

return M
