---The columns where the board locks a card's outcomes, read from the board's own column setting.
---@class dev.board.outcome_lock
local M = {}

---Name the refusal of an outcome change on a card in a column the board locks.
---@param rows dev.board.ColumnRow[] the board's columns
---@param column string the column the card sits in
---@param what string the change, as the refusal names it
---@return string? message the refusal, nil when the card's outcomes may change
function M.refusal(rows, column, what)
    local lowered = column:lower()
    for _, row in ipairs(rows) do
        if row.outcomes_locked == true and row.name:lower() == lowered then
            return "The card is in "
                .. column
                .. ", where the board locks outcomes, so "
                .. what
                .. " is refused. Move the card to Backlog first."
        end
    end
    return nil
end

return M
