local board = require("dev.board")
local store = require("dev.board.store")

---The landing turn, the claim on a card named `landing turn`.
---@class dev.board.turn
local M = {}

M.NAME = "landing turn"

M.LEASE_SECONDS = 900

M.POLL_SECONDS = 5

M.ASK_GRACE_SECONDS = 10

M.HOLD_SECONDS = 3600

M.MAX_HOLD_SECONDS = 7200

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

local function find(cards)
    local found
    for _, card in ipairs(cards) do
        if card.name == M.NAME and not card.done and (not found or card.id < found.id) then
            found = card
        end
    end
    return found
end

local function turn_card(backend)
    local cards, message = backend:cards()
    if not cards then
        return nil, message
    end
    local card = find(cards)
    if card then
        return card
    end
    local added
    added, message = backend:add(M.NAME, backend.roles.icebox, {})
    if not added then
        return nil, message
    end
    cards, message = backend:cards()
    if not cards then
        return nil, message
    end
    return find(cards), "the landing turn card could not be read"
end

local function taken_at(backend, card, name)
    local comments, message = backend:comments(card.id)
    if not comments then
        return nil, message
    end
    local newest
    for _, comment in ipairs(comments) do
        local held = record(comment.body)
        if held and held.name == name then
            newest = held.taken
        end
    end
    return newest or false
end

---Read who holds the turn.
---@param backend dev.board.Backend the board backend
---@return dev.board.turn.Holder? holder who holds it, nil when no one does
---@return string? message why the board could not be read
function M.holder(backend)
    local cards, message = backend:cards()
    if not cards then
        return nil, message
    end
    local card = find(cards)
    if not card or not card.claimant then
        return nil
    end
    local taken
    taken, message = taken_at(backend, card, card.claimant)
    if taken == nil then
        return nil, message
    end
    return { name = card.claimant, since = taken or nil }
end

---Describe `holder` for a refusal.
---@param holder dev.board.turn.Holder who holds the turn
---@return string text the holder and since when
function M.describe(holder)
    return string.format(
        "the landing turn is held by %s%s",
        holder.name,
        holder.since and (" since " .. holder.since) or ""
    )
end

---@class dev.board.turn.Asker
---@field name string the name that waits
---@field card string the short id of the card that wants to land
---@field expires string when the wait ends, an RFC 3339 stamp

---List the cards waiting for the turn, the one that asked first at the top.
---
---An ask ends when its card takes the turn, leaves, or passes its own wait.
---@param backend dev.board.Backend the board backend
---@return dev.board.turn.Asker[]? line the waiting cards, oldest ask first
---@return string? message why the board could not be read
function M.waiting(backend)
    local ASK_PATTERN = "^dev%-turn: ask holder=(%S+) card=(%S+) until=(%S+)$"
    local holding, message = turn_card(backend)
    if not holding then
        return nil, message
    end
    local comments
    comments, message = backend:comments(holding.id)
    if not comments then
        return nil, message
    end
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

---@class dev.board.turn.AskOpts
---@field name string the name that waits
---@field card string the short id of the card that wants to land
---@field seconds integer how long the wait lasts

---Join the line for the turn.
---@param backend dev.board.Backend the board backend
---@param opts dev.board.turn.AskOpts the asker and how long it waits
---@return true? ok true once the ask is on the board
---@return string? message why it could not be written
function M.ask(backend, opts)
    local holding, message = turn_card(backend)
    if not holding then
        return nil, message
    end
    local expires = store.stamp(os.time() + opts.seconds + M.ASK_GRACE_SECONDS)
    return backend:note(
        holding.id,
        string.format(
            "%sask holder=%s card=%s until=%s",
            RECORD_PREFIX,
            opts.name,
            opts.card,
            expires
        ),
        nil,
        { kind = board.NoteKind.STATUS }
    )
end

---Leave the line for the turn.
---@param backend dev.board.Backend the board backend
---@param name string the name that waited
---@param card string the short id of the card that wanted to land
function M.leave(backend, name, card)
    local holding = turn_card(backend)
    if holding then
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

---@class dev.board.turn.TakeOpts
---@field hold boolean? whether to keep the turn across a check, which needs `seconds`
---@field seconds integer? the lease of a hold, `LEASE_SECONDS` when nil

---Ask for the turn once, which only the first card in line gets.
---@param backend dev.board.Backend the board backend
---@param name string the name that asks
---@param card string the short id of the card that wants to land
---@param opts dev.board.turn.TakeOpts? a hold and how long its lease lasts
---@return dev.board.turn.Turn? turn the turn, nil when it is not free
---@return string? message who holds it, or why the board failed
function M.take(backend, name, card, opts)
    local lease = opts and opts.seconds or M.LEASE_SECONDS
    local hold = opts and opts.hold or false
    local holding, message = turn_card(backend)
    if not holding then
        return nil, message
    end
    local line
    line, message = M.waiting(backend)
    if not line then
        return nil, message
    end
    local first = line[1]
    if first and not (first.name == name and first.card == card) then
        local holder = M.holder(backend)
        local ahead = "next for " .. first.name
        return nil, holder and (M.describe(holder) .. ", and it is " .. ahead) or ahead
    end
    local fence
    fence, message = backend:claim(holding.id, name, lease, nil, { lease = true })
    local cards
    if fence then
        cards, message = backend:cards()
        local canonical = cards and find(cards)
        if not canonical then
            backend:release(holding.id, fence)
            return nil, message or "the landing turn card could not be read"
        end
        if canonical.id ~= holding.id then
            backend:release(holding.id, fence)
            return M.take(backend, name, card, opts)
        end
    end
    if not fence then
        local holder = M.holder(backend)
        return nil, holder and M.describe(holder) or message
    end
    local mine = {
        card = holding.id,
        fence = fence,
        holder = name,
        lease = lease,
        hold = hold,
        for_card = card,
        taken = store.stamp(),
    }
    local noted
    noted, message = note_holder(backend, mine)
    if not noted then
        backend:release(holding.id, fence)
        return nil, "the landing turn was taken but could not be noted: " .. message
    end
    return mine
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
    local cards, message = backend:cards()
    if not cards then
        return nil, message
    end
    local holding = find(cards)
    if not holding then
        return nil
    end
    local comments
    comments, message = backend:comments(holding.id)
    if not comments then
        return nil, message
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
    if holding.claimant ~= name then
        return nil,
            string.format(
                "the landing turn held for %s ran out or was taken by another, so take it again with dev board turn %s",
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
    if turn.hold and store.stamp(os.time() - M.MAX_HOLD_SECONDS) >= turn.taken then
        return nil,
            string.format(
                "the landing turn has been held since %s, the most it may be kept (%d seconds), so it is given back and has to be asked for again",
                turn.taken,
                M.MAX_HOLD_SECONDS
            ),
            true
    end
    local fence, message =
        backend:claim(turn.card, turn.holder, turn.lease, turn.fence, { lease = true })
    if not fence then
        return nil, "the landing turn was lost: " .. message
    end
    if fence ~= turn.fence then
        backend:release(turn.card, fence)
        return nil, "the landing turn ran out and was lost, so ask for it again"
    end
    return true
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
function M.extend(backend, held, seconds)
    held.lease = seconds
    local ok, message, capped = M.renew(backend, held)
    if not ok then
        return nil, message, capped
    end
    local noted
    noted, message = note_holder(backend, held)
    if not noted then
        return nil, "the hold was renewed but its lease could not be noted: " .. message
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
    return released, message
end

return M
