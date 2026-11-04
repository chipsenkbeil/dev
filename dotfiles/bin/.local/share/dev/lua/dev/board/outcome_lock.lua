---The columns where a card's outcomes are fixed, read from the board's resolved roles.
---@class dev.board.outcome_lock
local M = {}

local LOCKED_ROLES = { "ready", "progress", "review", "verify", "release" }

---Name the refusal of an outcome delete on a card whose outcomes are fixed.
---@param roles dev.board.Roles the board's resolved columns
---@param column string the column the card sits in
---@return string? message the refusal, nil when the card may still lose an outcome
function M.refusal(roles, column)
    local names = { roles.done }
    for _, role in ipairs(LOCKED_ROLES) do
        names[#names + 1] = roles[role]
    end
    for _, name in ipairs(roles.finished) do
        names[#names + 1] = name
    end
    local lowered = column:lower()
    local locked = false
    for _, name in ipairs(names) do
        locked = locked or name:lower() == lowered
    end
    if locked then
        return "the card is in "
            .. column
            .. ", where outcomes are fixed from Ready on, so --delete is refused"
    end
end

return M
