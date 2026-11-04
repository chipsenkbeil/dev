---The columns where a card's outcomes may be deleted, read from the board's resolved roles.
---@class dev.board.outcome_lock
local M = {}

local ALLOWED_ROLES = { "blocked", "backlog", "icebox" }

---Name the refusal of an outcome delete on a card outside the columns that allow one.
---@param roles dev.board.Roles the board's resolved columns
---@param column string the column the card sits in
---@return string? message the refusal, nil when the card may lose an outcome
function M.refusal(roles, column)
    local lowered = column:lower()
    for _, role in ipairs(ALLOWED_ROLES) do
        if roles[role]:lower() == lowered then
            return nil
        end
    end
    return "the card is in "
        .. column
        .. ", where outcomes are fixed from Ready on, so --delete is refused"
end

return M
