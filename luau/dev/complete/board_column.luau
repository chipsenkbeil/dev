local board = require("dev.board")

---@class dev.complete.board_column
local M = {}

---List the default column names of a board.
---@return dev.complete.Item[] items one per column
function M.candidates()
    local items = {}
    for _, name in ipairs(board.stages().list) do
        items[#items + 1] = { value = name }
    end
    return items
end

return M
