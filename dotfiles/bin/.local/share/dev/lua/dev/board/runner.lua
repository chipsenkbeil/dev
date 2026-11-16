local board = require("dev.board")
local claims = require("dev.board.claims")
local dev_os = require("dev.os")
local guards = require("dev.board.guards")
local limits = require("dev.board.limits")

---The size limit, the refusals and the claim a board runner takes a card with.
---@class dev.board.runner
---@field FLAG string the flag that sets a runner's size limit
---@field FULL integer the exit code of a move into a full column
---@field POLL_SECONDS integer how long a waiting move naps between tries
---@field limits dev.board.limits the in-flight limits Pomb holds
local M = { FLAG = "--max-size", FULL = 3, POLL_SECONDS = 15, limits = limits }

local usage = guards.usage
local failure = guards.failure
local CLAIMANT_CHARS = guards.CLAIMANT_CHARS

---Build the result of a move into a full column.
---@param message string the refusal
---@return dev.cmd.board.Result result the refusal with the full-column code
local function full(message)
    return { message = message, code = M.FULL }
end

---Find a word in a list.
---@param list any[] the list
---@param word any the item to find
---@return integer? index the first index of the item, nil when it is absent
local function index_of(list, word)
    for i, item in ipairs(list) do
        if item == word then
            return i
        end
    end
end

---Refuse a card that carries `needs:human`, which waits on the owner.
---@param card dev.board.Card the card
---@return dev.cmd.board.Result? err the failure, nil when the card is free to change
local function owner_holds(card)
    if index_of(card.labels, board.NEEDS_HUMAN) then
        return failure(
            card.id:sub(1, board.MIN_PREFIX)
                .. " is labelled "
                .. board.NEEDS_HUMAN
                .. ", so it waits on the owner and only the owner moves or edits it"
        )
    end
end

---Refuse a name that is not <repo>/<role>[/<card>] when it would take a new claim.
---@param name string? the agent name, nil when none is set
---@return dev.cmd.board.Result? err the usage error, nil when the name passes
local function shape_refusal(name)
    if name and not board.agent_shape(name) then
        return usage("an agent name is <repo>/<role>[/<card>], got " .. name)
    end
end

---Read a runner's size limit from the flag, else DEV_MAX_SIZE.
---@param flag string? the value of --max-size
---@return integer? limit the most Pomodori the runner takes, nil when it has no limit
---@return dev.cmd.board.Result? err the usage error for a limit that is not 1, 2 or 3
local function limit(flag)
    local word = flag
    if word == nil then
        word = os.getenv("DEV_MAX_SIZE")
        if word == nil or word == "" then
            return nil
        end
    end
    local size = board.SIZE_LIMITS[word]
    if not size then
        return nil, usage((flag and M.FLAG or "DEV_MAX_SIZE") .. " is 1, 2 or 3, not " .. word)
    end
    return size
end

---Refuse a card bigger than the runner's size limit.
---
---@param card dev.board.Card the card
---@param max integer? the most Pomodori the runner takes
---@return dev.cmd.board.Result? err the refusal, nil when the card fits
local function refusal(card, max)
    if board.fits(card, max) then
        return nil
    end
    return failure(
        card.id:sub(1, board.MIN_PREFIX)
            .. " is "
            .. card.size
            .. ", above this runner's limit of "
            .. max
            .. " Pomodori (DEV_MAX_SIZE)"
    )
end

---Name the claimant a claim is held under.
---@param name string? the agent name, nil to name the host and session
---@return string claimant the name the claim carries
local function claimant(name)
    if name then
        return name
    end
    local host = dev_os.capture({ "hostname", "-s" }, { stderr = "null" }):gsub("%s+$", "")
    local session = os.getenv("CLAUDE_SESSION_ID")
    if not session or session == "" then
        local tty = dev_os.capture({ "sh", "-c", "ps -o tty= -p $PPID" }, { stderr = "null" })
        tty = tty:gsub("%s+", "")
        if tty ~= "" and not tty:find("?", 1, true) then
            local user = dev_os.capture({ "id", "-un" }):gsub("%s+$", "")
            session = user .. "-" .. tty
        else
            session = dev_os.capture({ "sh", "-c", "echo $PPID" }):gsub("%s+$", "")
        end
    end
    return ("dev@" .. host .. ":" .. session:gsub("[^%w._-]", "_")):sub(1, CLAIMANT_CHARS)
end

---Refuse `card` when a Pomb limit on `target` forbids the move.
---
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card the caller is about to move
---@param target string the column it moves to
---@return dev.cmd.board.Result? err the refusal naming the cards at the limit, nil when the move
---   fits
local function limited(backend, card, target)
    local message = limits.refusal(backend, card, target)
    return message and failure(message)
end

---Claim a card and start the keepalive that renews the claim.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card to claim
---@param name string? the agent name, nil to name the host and session
---@return dev.cmd.board.Result result the output, or a message and the exit code
---@return integer? fence the fence of the claim, nil when it failed
local function claim_card(backend, card, name)
    local held = claims.read(card.id)
    local who = claimant(name)
    local fence, message = backend:claim(card.id, who, {
        ttl = claims.TTL_SECONDS,
        fence = held and held.fence,
        epic = card.epic,
    })
    if not fence then
        return failure(message)
    end
    claims.stop(card.id)
    local past, why = backend:comments(card.id)
    local ok
    if past and card.claimant ~= who then
        ok, why =
            backend:note(card.id, board.claim_record(who), fence, { kind = board.NoteKind.STATUS })
        past = ok and past
    end
    if not past then
        backend:release(card.id, fence)
        return failure(
            "the claim on " .. card.id:sub(1, board.MIN_PREFIX) .. " was dropped: " .. why
        )
    end
    local ticks, minutes = claims.cap(card.size)
    local state = { card = card.id, fence = fence }
    ok, message = claims.write(state)
    if not ok then
        backend:release(card.id, fence)
        return failure(message)
    end
    local pid
    pid, message = backend:keepalive(card.id, fence, ticks, claims.path(card.id), who)
    if not pid then
        claims.stop(card.id)
        backend:release(card.id, fence)
        return failure(message)
    end
    state.pid = pid
    ok, message = claims.write(state)
    if not ok then
        claims.stop(card.id)
        backend:release(card.id, fence)
        return failure(message)
    end
    if pid == 0 then
        return {
            output = string.format(
                "took %s, fence %d, held for %dm",
                card.id:sub(1, board.MIN_PREFIX),
                fence,
                minutes
            ),
        },
            fence
    end
    return {
        output = string.format(
            "took %s, fence %d, renewing every %dm for up to %dm",
            card.id:sub(1, board.MIN_PREFIX),
            fence,
            claims.TICK_MINUTES,
            minutes
        ),
    },
        fence
end

---Renew the caller's claim on a card and restart its keepalive loop.
---
---A caller that holds no claim state for the card, or whose name is not the card's claimant,
---renews nothing.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card whose claim to renew
---@param name string? the agent name, nil to name the host and session
---@return string? message why the claim could not be renewed, nil when it was or nothing applied
local function renew_claim(backend, card, name)
    local held = claims.read(card.id)
    local who = claimant(name)
    if not held or card.claimant ~= who then
        return nil
    end
    local fence, message = backend:claim(card.id, who, {
        ttl = claims.TTL_SECONDS,
        fence = held.fence,
        epic = card.epic,
    })
    if not fence then
        return message
    end
    local ticks = claims.cap(card.size)
    local ok
    ok, message = claims.write({ card = card.id, fence = fence, pid = held.pid })
    if not ok then
        return message
    end
    local pid
    pid, message = backend:keepalive(card.id, fence, ticks, claims.path(card.id), who)
    if not pid then
        return message
    end
    ok, message = claims.replace({ card = card.id, fence = fence, pid = pid }, held.pid)
    if not ok then
        if pid > 0 then
            dev_os.run({ "kill", tostring(pid) }, { stderr = "null" })
        end
        return message
    end
    return nil
end

M.full = full
M.index_of = index_of
M.owner_holds = owner_holds
M.shape_refusal = shape_refusal
M.limit = limit
M.refusal = refusal
M.claimant = claimant
M.limited = limited
M.claim_card = claim_card
M.renew_claim = renew_claim

return M
