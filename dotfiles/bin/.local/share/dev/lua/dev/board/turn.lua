local board = require("dev.board")
local dev_os = require("dev.os")
local store = require("dev.board.store")

local ENTROPY_BYTES = 4

---The landing turn, the claim on a card named `landing turn`.
---@class dev.board.turn
local M = {}

M.NAME = board.TURN_NAME

M.LEASE_SECONDS = 900

M.RECHECK_LEASE_SECONDS = 3000

M.POLL_SECONDS = 5

M.POLL_MAX_SECONDS = 30

M.POLL_BACKOFF = 1.5

M.POLL_JITTER = 0.2

M.ASK_GRACE_SECONDS = 10

M.HOLD_SECONDS = 1800

M.MAX_HOLD_SECONDS = 3600

M.MAX_NOTES = 500

local RECORD_PREFIX = board.TURN_PREFIX .. " "
local HOLDER_PATTERN =
    "^dev%-turn: holder=(%S+) card=(%S+) taken=(%S+) fence=(%d+) lease=(%d+) hold=([01])$"
local LEFT_PATTERN = "^dev%-turn: left holder=(%S+) card=(%S+)$"

---@class dev.board.turn.Turn
---@field card string the full id of the turn card
---@field fence integer the fence of the claim
---@field holder string the name that holds the turn
---@field lease integer the seconds each renewal lasts
---@field hold boolean whether the holder asked to keep the turn across a check
---@field for_card string the short id of the card the turn is for
---@field taken string when the turn was first taken, an RFC 3339 stamp

---A source of numbers in [0, 1).
---@alias dev.board.turn.Random fun(): number

---@class dev.board.turn.poller.Opts
---@field random dev.board.turn.Random? `M.entropy` when nil

---@class dev.board.turn.Poll
---@field private __delay number the sleep before jitter, in seconds
---@field private __random dev.board.turn.Random the jitter source of this waiter
---@field private __key string? the line last seen by a poll, nil before the first
---@field private __started boolean whether a poll has been paced yet, false until the first

---@class dev.board.turn.Holder
---@field name string who holds the turn
---@field since string? when the holder took it, an RFC 3339 stamp

---@class dev.board.turn.Record
---@field name string who took the turn
---@field card string the short id of the card it was taken for
---@field taken string when it was taken, an RFC 3339 stamp
---@field fence integer the fence of the claim
---@field lease integer the seconds each renewal lasts
---@field hold boolean whether it is a hold

---Parse a holder record from the body of a note.
---@param body string the text of a note
---@return dev.board.turn.Record? record the fields, nil when the body is no holder record
local function record(body)
    local name, card, taken, fence, lease, hold = body:match(HOLDER_PATTERN)
    if not name then
        return nil
    end
    return {
        name = name,
        card = card,
        taken = taken,
        fence = tonumber(fence),
        lease = tonumber(lease),
        hold = hold == "1",
    }
end

---Turn the backend's `reason` into a sentence that follows another sentence.
---@param reason string? the backend's message
---@return string sentence a space and the reason as a capitalized sentence, empty when none
local function sentence_after(reason)
    if not reason or reason == "" then
        return ""
    end
    local lead = reason:match("^%w+") or ""
    local is_id = #lead >= 8 and lead:find("^%x+$") ~= nil
    local text = is_id and reason or reason:sub(1, 1):upper() .. reason:sub(2)
    return " " .. (text:find("[.!?]$") and text or text .. ".")
end

local function find(cards)
    local found
    for _, card in ipairs(cards) do
        if card.name == M.NAME and not card.done and (not found or card.id < found.id) then
            found = card
        end
    end
    return found
end

---@type table<dev.board.Backend, string> the id of the turn card each backend read last
local remembered = setmetatable({}, { __mode = "k" })

---@class dev.board.turn.lookup.Opts
---@field relist boolean? true to list the board even when a turn card is remembered

local function lookup(backend, opts)
    local id = remembered[backend]
    if id and not (opts and opts.relist) then
        local card = backend:card(id)
        if card and card.name == M.NAME and not card.done then
            return card
        end
    end
    local cards, message = backend:cards()
    if not cards then
        return nil, message
    end
    local found = find(cards)
    remembered[backend] = found and found.id or nil
    return found
end

local function turn_card(backend)
    local card, message = lookup(backend)
    if card then
        return card
    end
    if message then
        return nil, "The landing turn card could not be read." .. sentence_after(message)
    end
    local added
    added, message = backend:add(M.NAME, backend.roles.icebox, { once = true })
    if not added then
        return nil, "The landing turn card could not be added." .. sentence_after(message)
    end
    card, message = lookup(backend)
    if card then
        return card
    end
    return nil, "The landing turn card could not be read." .. sentence_after(message)
end

---Find the newest holder record `name` wrote.
---@param comments {body: string}[] the notes of the turn card, oldest first
---@param name string the name that took the turn
---@return dev.board.turn.Record? newest the record, nil when `name` wrote none
local function newest_note(comments, name)
    local newest
    for _, comment in ipairs(comments) do
        local held = record(comment.body)
        if held and held.name == name then
            newest = held
        end
    end
    return newest
end

local function taken_at(backend, card, name)
    local comments, message = backend:comments(card.id)
    if not comments then
        return nil, message
    end
    local newest = newest_note(comments, name)
    return newest and newest.taken or false
end

---@class dev.board.turn.own_claim.Opts
---@field holding dev.board.Card the turn card
---@field comments {body: string}[] the notes of the turn card, oldest first
---@field name string the name that may hold the claim
---@field card string the short id of the card the claim was taken for

---@param opts dev.board.turn.own_claim.Opts
local function own_claim(opts)
    local holding = opts.holding
    if holding.claimant ~= opts.name or type(holding.claim_fence) ~= "number" then
        return nil
    end
    local newest = newest_note(opts.comments, opts.name)
    if not newest or newest.card ~= opts.card then
        return nil
    end
    return {
        card = holding.id,
        fence = holding.claim_fence,
        holder = opts.name,
        lease = newest.lease,
        hold = newest.hold,
        for_card = opts.card,
        taken = newest.taken,
    }
end

---Find the live hold `name` has on the turn card for `card`, whatever its notes say.
---
---The hold counts when its claimant is `name` and the newest holder note of `name` is a hold
---for `card`, so a stale fence or a `left` note does not hide it.
---@param backend dev.board.Backend the board backend
---@param name string the name that holds
---@param card string the short id of the card the claim was taken for
---@return dev.board.turn.Turn? turn the claim under its live fence, nil when `name` has none
---@return string? message why the board could not be read
function M.claimed(backend, name, card)
    local holding, message = lookup(backend, { relist = true })
    if not holding then
        return nil,
            message and ("The landing turn card could not be read." .. sentence_after(message))
    end
    local comments
    comments, message = backend:comments(holding.id)
    if not comments then
        return nil,
            "The notes of the landing turn card could not be read." .. sentence_after(message)
    end
    local own = own_claim({ holding = holding, comments = comments, name = name, card = card })
    return own and own.hold and own or nil
end

local function holder_of(backend, card)
    if not card or not card.claimant then
        return nil
    end
    local taken, message = taken_at(backend, card, card.claimant)
    if taken == nil then
        return nil, message
    end
    return { name = card.claimant, since = taken or nil }
end

---Read who holds the turn.
---@param backend dev.board.Backend the board backend
---@return dev.board.turn.Holder? holder who holds it, nil when no one does
---@return string? message why the board could not be read
function M.holder(backend)
    local card, message = lookup(backend, { relist = true })
    if not card then
        return nil, message
    end
    return holder_of(backend, card)
end

---Describe `holder` for a refusal.
---@param holder dev.board.turn.Holder who holds the turn
---@return string text the holder and since when
function M.describe(holder)
    return string.format(
        "The landing turn is held by %s%s.",
        holder.name,
        holder.since and (" since " .. holder.since) or ""
    )
end

---@class dev.board.turn.Asker
---@field name string the name that waits
---@field card string the short id of the card that wants to land
---@field expires string when the wait ends, an RFC 3339 stamp

local function queue(comments)
    local ASK_PATTERN = "^dev%-turn: ask holder=(%S+) card=(%S+) until=(%S+)$"
    local line = {}
    local function drop(name, card)
        for i = #line, 1, -1 do
            if line[i].name == name and line[i].card == card then
                table.remove(line, i)
            end
        end
    end
    for _, comment in ipairs(comments) do
        local name, card, expires = comment.body:match(ASK_PATTERN)
        if name then
            drop(name, card)
            line[#line + 1] = { name = name, card = card, expires = expires }
        end
        name, card = comment.body:match(LEFT_PATTERN)
        if not name then
            local held = record(comment.body)
            name, card = held and held.name, held and held.card
        end
        if name then
            drop(name, card)
        end
    end
    local now = store.stamp()
    local live = {}
    for _, asker in ipairs(line) do
        if asker.expires > now then
            live[#live + 1] = asker
        end
    end
    return live
end

local function note_ask(backend, id, asker)
    return backend:note(
        id,
        string.format(
            "%sask holder=%s card=%s until=%s",
            RECORD_PREFIX,
            asker.name,
            asker.card,
            asker.expires
        ),
        nil,
        { kind = board.NoteKind.STATUS }
    )
end

local function rotate(backend, card, comments)
    local line = queue(comments)
    local current = backend:card(card.id)
    if not current or current.claimant then
        return card
    end
    local moved, message = backend:move(card.id, backend.roles:done_column())
    if not moved and (message or ""):find("limit reached", 1, true) then
        return nil,
            string.format(
                "The landing turn card %s is full and Pomb refuses to move it. "
                    .. "Rename it to have dev make a fresh one.",
                card.id:sub(1, 8)
            )
    end
    if not moved then
        return nil, "The full landing turn card could not be retired." .. sentence_after(message)
    end
    local fresh_card
    fresh_card, message = turn_card(backend)
    if not fresh_card then
        return nil, message
    end
    for _, asker in ipairs(line) do
        local ok
        ok, message = note_ask(backend, fresh_card.id, asker)
        if not ok then
            return nil, message
        end
    end
    return fresh_card
end

local function open_card(backend)
    local holding, message = turn_card(backend)
    if not holding then
        return nil, nil, message
    end
    local comments
    comments, message = backend:comments(holding.id)
    if not comments then
        return nil, nil, message
    end
    if holding.claimant or #comments < M.MAX_NOTES then
        return holding, comments
    end
    holding, message = rotate(backend, holding, comments)
    if not holding then
        return nil, nil, message
    end
    comments, message = backend:comments(holding.id)
    if not comments then
        return nil, nil, message
    end
    return holding, comments
end

---@class dev.board.turn.ask.Opts
---@field name string the name that waits
---@field card string the short id of the card that wants to land
---@field seconds integer how long the wait lasts

---Join the line for the turn.
---@param backend dev.board.Backend the board backend
---@param opts dev.board.turn.ask.Opts the asker and how long it waits
---@return true? ok true once the ask is on the board
---@return string? message why it could not be written
function M.ask(backend, opts)
    local holding, _, message = open_card(backend)
    if not holding then
        return nil, message
    end
    local expires = store.stamp(store.now() + opts.seconds + M.ASK_GRACE_SECONDS)
    return note_ask(backend, holding.id, { name = opts.name, card = opts.card, expires = expires })
end

---Leave the line for the turn, which a live hold of the same name and card survives.
---@param backend dev.board.Backend the board backend
---@param name string the name that waited
---@param card string the short id of the card that wanted to land
function M.leave(backend, name, card)
    local holding = turn_card(backend)
    if holding and not M.held(backend, name, card) then
        backend:note(
            holding.id,
            string.format("%sleft holder=%s card=%s", RECORD_PREFIX, name, card),
            nil,
            { kind = board.NoteKind.STATUS }
        )
    end
end

local function note_holder(backend, held)
    return backend:note(
        held.card,
        string.format(
            "%sholder=%s card=%s taken=%s fence=%d lease=%d hold=%d",
            RECORD_PREFIX,
            held.holder,
            held.for_card,
            held.taken,
            held.fence,
            held.lease,
            held.hold and 1 or 0
        ),
        held.fence,
        { kind = board.NoteKind.STATUS }
    )
end

---@class dev.board.turn.take.Opts
---@field hold boolean? whether to keep the turn across a check, which needs `seconds`
---@field seconds integer? the lease of a hold, `LEASE_SECONDS` when nil

---Ask for the turn once, which only the first card in line gets.
---@param backend dev.board.Backend the board backend
---@param name string the name that asks
---@param card string the short id of the card that wants to land
---@param opts dev.board.turn.take.Opts? a hold and how long its lease lasts
---@return dev.board.turn.Turn? turn the turn, nil when it is not free
---@return string? message who holds it, or why the board failed
---@return string? place a key for `Poll:pace` that changes with the line or the holder, nil when
---   this card takes the turn or the board could not be read
function M.take(backend, name, card, opts)
    local seconds = opts and opts.seconds
    local lease = seconds or M.LEASE_SECONDS
    local hold = opts and opts.hold or false
    local holding, comments, message = open_card(backend)
    if not holding then
        return nil, message
    end
    local line = queue(comments)
    local place = #line + 1
    for index, asker in ipairs(line) do
        if asker.name == name and asker.card == card then
            place = index
            break
        end
    end
    local first = line[1]
    local own = own_claim({ holding = holding, comments = comments, name = name, card = card })
    if first and not own and not (first.name == name and first.card == card) then
        local holder = holder_of(backend, holding)
        local ahead = "next for " .. first.name .. "."
        return nil,
            holder and (M.describe(holder) .. " It is " .. ahead)
                or ("The landing turn is " .. ahead),
            place .. ":" .. (holder and holder.name or "")
    end
    if own and own.hold then
        if store.stamp(store.now() - M.MAX_HOLD_SECONDS) >= own.taken then
            local released, reason = M.release(backend, own)
            local ending = released and "It is given back and has to be asked for again." or reason
            return nil,
                string.format(
                    "The landing turn has been held since %s, the most it may be kept "
                        .. "(%d seconds). %s",
                    own.taken,
                    M.MAX_HOLD_SECONDS,
                    ending
                )
        end
        lease, hold = seconds or own.lease, true
    end
    local fence
    fence, message =
        backend:claim(holding.id, name, { ttl = lease, lease = true, fence = own and own.fence })
    if fence then
        local canonical
        canonical, message = lookup(backend, { relist = true })
        if not canonical then
            backend:release(holding.id, fence)
            return nil, "The landing turn card could not be read." .. sentence_after(message)
        end
        if canonical.id ~= holding.id then
            backend:release(holding.id, fence)
            return M.take(backend, name, card, opts)
        end
    end
    if not fence then
        local holder = holder_of(backend, lookup(backend) or holding)
        return nil,
            holder and M.describe(holder)
                or ("The landing turn could not be taken." .. sentence_after(message)),
            place .. ":" .. (holder and holder.name or "")
    end
    local mine = {
        card = holding.id,
        fence = fence,
        holder = name,
        lease = lease,
        hold = hold,
        for_card = card,
        taken = own and own.hold and own.taken or store.stamp(),
    }
    local noted
    noted, message = note_holder(backend, mine)
    if not noted then
        backend:release(holding.id, fence)
        return nil, "The landing turn was taken but could not be noted." .. sentence_after(message)
    end
    return mine
end

local Poll = {}
Poll.__index = Poll

---Draw a number in [0, 1) from the system's random bytes.
---@return number fraction the number drawn
function M.entropy()
    local bytes = assert(dev_os.random_bytes(ENTROPY_BYTES))
    local n = 0
    for i = 1, ENTROPY_BYTES do
        n = n * 256 + bytes:byte(i)
    end
    return n / 4294967296
end

---Start pacing the polls of one waiter.
---@param opts dev.board.turn.poller.Opts? the source of jitter
---@return dev.board.turn.Poll poll the state `Poll:pace` advances
function M.poller(opts)
    local random = opts and opts.random or M.entropy
    return setmetatable({ __delay = M.POLL_SECONDS, __random = random, __started = false }, Poll)
end

---Say how long to sleep before the next poll.
---
---The delay grows from `POLL_SECONDS` toward `POLL_MAX_SECONDS` while `key` stays the
---same and starts over when it changes, and jitter shortens each sleep by up to `POLL_JITTER`.
---@param key string? the place `take` returned, nil when the board failed
---@return number seconds how long to sleep
function Poll:pace(key)
    if self.__started and key == self.__key then
        self.__delay = math.min(self.__delay * M.POLL_BACKOFF, M.POLL_MAX_SECONDS)
    else
        self.__delay = M.POLL_SECONDS
    end
    self.__started = true
    self.__key = key
    return self.__delay * (1 - M.POLL_JITTER * self.__random())
end

---Find the turn `name` took with a hold for `card`.
---
---A hold stays on the board until its holder lands, gives it back or loses it,
---so a hold whose claim is gone is reported as lost, and a card that never
---held one gets neither a turn nor a message.
---@param backend dev.board.Backend the board backend
---@param name string the name that holds
---@param card string the short id of the card the hold is for
---@return dev.board.turn.Turn? turn the turn in hand, nil with no live hold
---@return string? message why a hold that was taken is gone, or why the board failed
---@return boolean? lost true when the hold ran out or was taken by another, nil otherwise
function M.held(backend, name, card)
    local holding, message = lookup(backend)
    if not holding and message then
        return nil, "The landing turn card could not be read." .. sentence_after(message)
    end
    if not holding then
        return nil
    end
    local comments
    comments, message = backend:comments(holding.id)
    if not comments then
        return nil,
            "The notes of the landing turn card could not be read." .. sentence_after(message)
    end
    local newest
    for _, comment in ipairs(comments) do
        local held = record(comment.body)
        if held and held.name == name and held.card == card then
            newest = held
        end
        local left, left_card = comment.body:match(LEFT_PATTERN)
        if left == name and left_card == card then
            newest = nil
        end
    end
    if not newest or not newest.hold then
        return nil
    end
    if holding.claimant ~= name or holding.claim_fence ~= newest.fence then
        return nil,
            string.format(
                "The landing turn held for %s ran out or was taken by another. "
                    .. "Take it again with dev board turn %s.",
                card,
                card
            ),
            true
    end
    return {
        card = holding.id,
        fence = newest.fence,
        holder = name,
        lease = newest.lease,
        hold = true,
        for_card = card,
        taken = newest.taken,
    }
end

---Renew `turn`, which fails once another card has it.
---@param backend dev.board.Backend the board backend
---@param turn dev.board.turn.Turn the turn in hand
---@return true? ok true while the turn is still this holder's
---@return string? message why the turn is lost or over the cap of a hold
---@return boolean? capped true when a hold has been kept for `MAX_HOLD_SECONDS` already
function M.renew(backend, turn)
    if turn.hold and store.stamp(store.now() - M.MAX_HOLD_SECONDS) >= turn.taken then
        return nil,
            string.format(
                "The landing turn has been held since %s, the most it may be kept (%d seconds). "
                    .. "It is given back and has to be asked for again.",
                turn.taken,
                M.MAX_HOLD_SECONDS
            ),
            true
    end
    local fence, message = backend:claim(
        turn.card,
        turn.holder,
        { ttl = turn.lease, fence = turn.fence, lease = true }
    )
    if not fence then
        return nil, "The landing turn was lost." .. sentence_after(message)
    end
    if fence ~= turn.fence then
        backend:release(turn.card, fence)
        return nil, "The landing turn ran out and was lost. Ask for it again."
    end
    return true
end

---Renew `turn` for at least `seconds`, then go back to the lease the holder asked for.
---@param backend dev.board.Backend the board backend
---@param turn dev.board.turn.Turn the turn in hand
---@param seconds integer the lease of this one renewal, never below the turn's own lease
---@return true? ok true while the turn is still this holder's
---@return string? message why the turn is lost or over the cap of a hold
---@return boolean? capped true when a hold has been kept for `MAX_HOLD_SECONDS` already
function M.stretch(backend, turn, seconds)
    local own = turn.lease
    turn.lease = math.max(own, seconds)
    local ok, message, capped = M.renew(backend, turn)
    turn.lease = own
    return ok, message, capped
end

---Renew a hold for `seconds` and record that lease, so a later landing renews to it.
---
---Sets `held.lease` to `seconds` before renewing and keeps it when the renewal fails.
---@param backend dev.board.Backend the board backend
---@param held dev.board.turn.Turn the hold in hand
---@param seconds integer the new lease
---@return true? ok true while the hold is still this holder's
---@return string? message why the hold is lost, over its cap or the record not written
---@return boolean? capped true when the hold has been kept for `MAX_HOLD_SECONDS` already
---@return boolean? renewed true when the claim was renewed but the lease could not be noted
function M.extend(backend, held, seconds)
    held.lease = seconds
    local ok, message, capped = M.renew(backend, held)
    if not ok then
        return nil, message, capped
    end
    local noted
    noted, message = note_holder(backend, held)
    if not noted then
        return nil,
            "The hold was renewed but its lease could not be noted." .. sentence_after(message),
            nil,
            true
    end
    return true
end

---Give `turn` back, and end a hold on the board too, so a later `held` finds nothing.
---@param backend dev.board.Backend the board backend
---@param turn dev.board.turn.Turn the turn in hand
---@return true? ok true when the claim was released
---@return string? message why the claim was not released
function M.release(backend, turn)
    local released, message = backend:release(turn.card, turn.fence)
    if released and turn.hold then
        M.leave(backend, turn.holder, turn.for_card)
    end
    if not released then
        return nil, "The landing turn could not be released." .. sentence_after(message)
    end
    return released
end

return M
