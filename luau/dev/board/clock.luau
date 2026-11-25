local board = require("@dev/board")
local claims = require("@dev/board/claims")
local fs = require("@dev/fs")
local guards = require("@dev/board/guards")

local SUFFIX = ".clock"
local BEAT_SUFFIX = ".beat"
local STOPPING_SUFFIX = ".stopping"
local SECONDS_PER_MINUTE = 60
local START = "start"
local STOP = "stop"
---The role of a column's holder, by stage name, in board order.
local COLUMN_ROLES = {
    { stage = "icebox", role = "scoper" },
    { stage = "backlog", role = "planner" },
    { stage = "progress", role = "implementer" },
    { stage = "review", role = "reviewer" },
    { stage = "blocked", role = "lead" },
}

---The role clock `dev board time start` runs: one state file per card beside
---the claim state, holding the role and the start time on this machine.
---@class dev.board.clock
local M = {}

---Why a clock could not follow a card.
---@enum dev.board.clock.Reason
M.Reason = { DROPPED = "dropped", NOT_STARTED = "not_started" }

---The most minutes one entry logs.
M.MAX_MINUTES = 1440

---The words after `dev board time` that run the clock.
M.WORDS = { [START] = true, [STOP] = true }

---Trim a role flag and refuse a blank one or one with control characters.
---@param flag string? the `--as` value
---@return string? role the role, nil when the flag is missing or unusable
function M.role(flag: string?)
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

---@class dev.board.clock.Running
---@field id string the card's full id
---@field role string the role the clock counts for
---@field minutes integer the whole minutes it has run
---@field name string the card's name

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

---Name the file a stop moves the clock to while it logs the stretch.
---@param card string the card's full id
---@return string path the file
function M.stopping_path(card)
    return M.path(card) .. STOPPING_SUFFIX
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

---Count the minutes a stretch logs, rounded and held within 1 to 1440, or 0 under a minute.
---@param seconds integer the elapsed seconds
---@return integer minutes the minutes
function M.minutes(seconds: number)
    if seconds < SECONDS_PER_MINUTE then
        return 0
    end
    local minutes = math.floor(seconds / SECONDS_PER_MINUTE + 0.5)
    return math.min(M.MAX_MINUTES, minutes)
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
    fs.remove(M.stopping_path(card.id))
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

---Name the file where the keep-alive loop leaves the time of its last renewal.
---@param card string the card's full id
---@return string path the file
function M.beat_path(card)
    return claims.path(card) .. BEAT_SUFFIX
end

---Find the second a running clock stopped counting.
---
---A live claim keeps the clock counting up to now. A claim that went quiet for longer than its
---lease stops it at the last renewal, or at its start when none came. A clock with no claim
---stops at twice the card's size.
---@param card dev.board.Card the card, whose size sets the cap
---@param running dev.board.clock.State the clock
---@param now integer the epoch seconds the caller counts to
---@return integer ended the epoch seconds the clock stopped counting
function M.ended(card, running, now: number)
    local text = fs.read(M.beat_path(card.id))
    local beat = text and tonumber(text:match("^%d+"))
    if beat and beat < running.start then
        beat = nil
    end
    if claims.read(card.id) then
        local last = beat or running.start
        return now - last <= claims.TTL_SECONDS and now or last
    end
    if beat then
        return math.min(beat, now)
    end
    local _, minutes = claims.cap(card.size or "")
    return math.min(now, running.start + minutes * SECONDS_PER_MINUTE)
end

---Stop a card's clock and log its stretch on the card.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@param note string? the note stored with the entry
---@param at integer? the epoch seconds to count to, now when nil
---@return dev.cmd.board.Result result the refusal, or the line naming the logged minutes
function M.stop(backend, card, note, at: number?)
    local prefix = card.id:sub(1, board.MIN_PREFIX)
    local running = M.read(card.id)
    if not running then
        return guards.failure("Card " .. prefix .. " has no running clock.")
    end
    local minutes = M.minutes((at or M.now()) - running.start)
    local claimed = M.stopping_path(card.id)
    local ok, message = fs.move(M.path(card.id), claimed)
    if not ok then
        return guards.failure("Card " .. prefix .. " has a clock another stop already claimed.")
    end
    if minutes == 0 then
        ok = true
    else
        ok, message = backend:log_time(card.id, minutes, running.role, note)
    end
    if not ok then
        local restored, why = fs.move(claimed, M.path(card.id))
        if not restored then
            return guards.failure(message .. " The clock could not be put back: " .. why)
        end
        return guards.failure(message)
    end
    fs.remove(claimed)
    fs.remove(M.beat_path(card.id))
    if minutes == 0 then
        return { output = `logged nothing as {running.role} on {prefix}, under a minute` }
    end
    return { output = "logged " .. minutes .. " minutes as " .. running.role .. " on " .. prefix }
end

---Stop every clock whose claim lapsed or whose cap passed, and name the ones still running.
---@param backend dev.board.Backend the board
---@param cards dev.board.Card[] the board's cards
---@param now integer the epoch seconds to count to
---@return dev.board.clock.Running[] running the clocks still counting
---@return string[] warnings why a clock could not be stopped
function M.sweep(backend, cards, now: number)
    local running, warnings = {}, {}
    if backend.timed == false then
        return running, warnings
    end
    local by_id = {}
    for _, card in ipairs(cards) do
        by_id[card.id] = card
    end
    for _, entry in ipairs(fs.list(claims.dir()) or {}) do
        local id = entry:match("^(.+)" .. SUFFIX:gsub("%.", "%%.") .. "$")
        local card = id and by_id[id]
        local clock = card and M.read(id)
        if clock then
            local ended = M.ended(card, clock, now)
            if ended < now then
                local stopped = M.stop(backend, card, nil, ended)
                if stopped.code then
                    warnings[#warnings + 1] = "Could not stop the clock on "
                        .. id:sub(1, board.MIN_PREFIX)
                        .. ". "
                        .. stopped.message
                end
            else
                running[#running + 1] = {
                    id = id,
                    role = clock.role,
                    minutes = math.floor((now - clock.start) / SECONDS_PER_MINUTE),
                    name = card.name or "",
                }
            end
        end
    end
    return running, warnings
end

---Name the role a card's holder works in while it sits in a column.
---
---Icebox is the scoper's, Backlog the planner's, In Progress the implementer's, Review the
---reviewer's and Blocked the lead's. Ready and Verify take the role from the claimant's name,
---`repo/role/card`, and any other column counts no time.
---@param stages dev.board.Stages the board's stages
---@param column string the column the card sits in
---@param claimant string the name the claim is held under
---@return string? role the role, nil when the column counts no time
function M.column_role(stages, column, claimant)
    for _, pair in ipairs(COLUMN_ROLES) do
        if stages[pair.stage] == column then
            return pair.role
        end
    end
    if column == stages.ready or column == stages.verify then
        return claimant:match("^[^/]+/([^/]+)")
    end
    return nil
end

---Move a card's clock to a column: log the running stretch and start the column's role.
---
---A stop the board refuses drops the clock with a warning, so a card never keeps a stale clock.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@param column string? the column the card is in now, nil to only stop
---@param claimant string the name the claim is held under
---@return dev.board.clock.Reason? reason why the clock could not follow, nil when it did
---@return string? detail the clock's own message for the reason
function M.follow(backend, card, column, claimant)
    if backend.timed == false then
        return nil
    end
    local role = column and M.column_role(backend.stages, column, claimant)
    local running = M.read(card.id)
    if running and running.role == role then
        return nil
    end
    local reason, detail
    if running then
        local stopped = M.stop(backend, card)
        if stopped.code then
            fs.remove(M.path(card.id))
            reason, detail = M.Reason.DROPPED, stopped.message
        end
    end
    if role and not board.labelled(card, board.NEEDS_HUMAN) then
        local started = M.start(card, role)
        if started.code and not reason then
            reason, detail = M.Reason.NOT_STARTED, started.message
        end
    end
    return reason, detail
end

---Run `time start` or `time stop` from its parsed words and flags.
---@param backend dev.board.Backend the board
---@param positional string[] the words, the clock word then the card
---@param as_flag string? the `--as` value
---@param note string? the `--note` value
---@param find fun(word: string): dev.board.Card?, dev.cmd.board.Result? the card lookup
---@return dev.cmd.board.Result result the outcome of the command
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
