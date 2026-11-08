local board = require("dev.board")

---The in-flight limits Pomb holds, and the refusal an agent gets at one.
---@class dev.board.limits
---@field REFUSED string the prefix of a refusal Pomb makes at a limit
local M = { REFUSED = "Pomb refused the move: " }

---@class dev.board.limits.Group
---@field columns string[] the column names the group spans, in board order
---@field limit integer how many cards the columns hold together at most
---@field count integer? how many cards the columns hold now, nil when Pomb does not say

---@class dev.board.limits.Limits
---@field columns table<string, integer> column name -> its own limit
---@field units table<string, string> column name -> what its limit counts, `count` or `hours`
---@field groups dev.board.limits.Group[] the limit groups

local function short(cards)
    local ids = {}
    for _, card in ipairs(cards) do
        ids[#ids + 1] = card.id:sub(1, board.MIN_PREFIX)
    end
    return table.concat(ids, ", ")
end

local function spoken(names)
    if #names == 1 then
        return names[1]
    end
    return table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names]
end

local function holding(cards, card, columns)
    local inside = {}
    for _, name in ipairs(columns) do
        inside[name] = true
    end
    local held = {}
    for _, other in ipairs(cards) do
        if other.id ~= card.id and other.kind ~= board.Kind.EPIC and inside[other.column] then
            held[#held + 1] = other
        end
    end
    return held
end

---Say why `card` may not enter `target`, when a Pomb limit forbids it.
---
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card the caller is about to move
---@param target string the column it moves to
---@return string? message the refusal naming the cards, or the read failure, nil when the move fits
function M.refusal(backend, card, target)
    -- A limit that cannot be read must stop the move, since a guess could overfill a column
    local limits, message = backend:limits()
    if not limits then
        return message
    end
    local cards
    cards, message = backend:cards()
    if not cards then
        return message
    end

    -- A column's own limit counts the cards already in it, so a card staying put is never refused
    local own = limits.columns[target]
    if own and card.column ~= target then
        local held = holding(cards, card, { target })
        if #held >= own then
            return string.format(
                "%s holds %d %s (%s), at its limit of %d. Land one first.",
                target,
                #held,
                #held == 1 and "card" or "cards",
                short(held),
                own
            )
        end
    end

    -- A group limit applies only to a card coming from outside the group, because a move inside it adds nothing
    for _, group in ipairs(limits.groups) do
        local entering, leaving = false, true
        for _, name in ipairs(group.columns) do
            entering = entering or name == target
            leaving = leaving and name ~= card.column
        end
        if entering and leaving then
            local held = holding(cards, card, group.columns)
            if #held >= group.limit then
                return string.format(
                    "%d cards are in flight in %s (%s), at the limit of %d. Land one first.",
                    #held,
                    spoken(group.columns),
                    short(held),
                    group.limit
                )
            end
        end
    end
end

return M
