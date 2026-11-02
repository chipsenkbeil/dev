local board = require("dev.board")
local store = require("dev.board.store")

---The landing turn, the claim on a card named `landing turn`.
---@class dev.board.turn
local M = {}

M.NAME = "landing turn"

M.LEASE_SECONDS = 900

M.POLL_SECONDS = 5

M.ASK_GRACE_SECONDS = 10

local RECORD_PREFIX = board.TURN_PREFIX .. " "
local HOLDER_PATTERN = "^dev%-turn: holder=(%S+) card=(%S+) taken=(%S+)$"

---@class dev.board.turn.Turn
---@field card string the full id of the turn card
---@field fence integer the fence of the claim
---@field holder string the name that holds the turn

---@class dev.board.turn.Holder
---@field name string who holds the turn
---@field since string? when the holder took it, an RFC 3339 stamp

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
        local holder, _, taken = comment.body:match(HOLDER_PATTERN)
        if holder == name then
            newest = taken
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
    local LEFT_PATTERN = "^dev%-turn: left holder=(%S+) card=(%S+)$"
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
            name, card = comment.body:match(HOLDER_PATTERN)
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
        { kind = "status" }
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
            { kind = "status" }
        )
    end
end

---Ask for the turn once, which only the first card in line gets.
---@param backend dev.board.Backend the board backend
---@param name string the name that asks
---@param card string the short id of the card that wants to land
---@return dev.board.turn.Turn? turn the turn, nil when it is not free
---@return string? message who holds it, or why the board failed
function M.take(backend, name, card)
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
    fence, message = backend:claim(holding.id, name, M.LEASE_SECONDS, nil, { lease = true })
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
            return M.take(backend, name, card)
        end
    end
    if not fence then
        local holder = M.holder(backend)
        return nil, holder and M.describe(holder) or message
    end
    local noted
    noted, message = backend:note(
        holding.id,
        string.format("%sholder=%s card=%s taken=%s", RECORD_PREFIX, name, card, store.stamp()),
        fence,
        { kind = "status" }
    )
    if not noted then
        backend:release(holding.id, fence)
        return nil, "the landing turn was taken but could not be noted: " .. message
    end
    return { card = holding.id, fence = fence, holder = name }
end

---Renew `turn`, which fails once another card has it.
---@param backend dev.board.Backend the board backend
---@param turn dev.board.turn.Turn the turn in hand
---@return true? ok true while the turn is still this holder's
---@return string? message why the turn is lost
function M.renew(backend, turn)
    local fence, message =
        backend:claim(turn.card, turn.holder, M.LEASE_SECONDS, turn.fence, { lease = true })
    if not fence then
        return nil, "the landing turn was lost: " .. message
    end
    if fence ~= turn.fence then
        backend:release(turn.card, fence)
        return nil, "the landing turn ran out and was lost, so ask for it again"
    end
    return true
end

---Give `turn` back.
---@param backend dev.board.Backend the board backend
---@param turn dev.board.turn.Turn the turn in hand
function M.release(backend, turn)
    backend:release(turn.card, turn.fence)
end

return M
