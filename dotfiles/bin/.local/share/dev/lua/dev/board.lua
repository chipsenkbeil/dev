local text = require("dev.text")

---The board seam: the column names, the card helpers and the one interface the
---`dev board` commands call, which a backend implements.
---@class dev.board
local M = {}

---@class dev.board.Card
---@field id string the card's full id
---@field name string the card's title
---@field column string the name of the column it sits in
---@field size string the colour's palette label, or `unsized`
---@field color string? the colour's standard value (`yellow`, `green`, `blue`, `red`, `white`), nil when the card has none
---@field labels string[] the card's labels
---@field claimant string? who holds a live claim on it

---@class dev.board.Backend
---@field describe fun(self: dev.board.Backend): string the backend and board, as `status` prints them
---@field cards fun(self: dev.board.Backend): dev.board.Card[]?, string? every card in column order, or nil and a message
---@field next fun(self: dev.board.Backend): dev.board.Card?, string? the top unclaimed, unblocked Ready card, or nil and a message when it failed
---@field add fun(self: dev.board.Backend, name: string, column: string, opts: dev.board.AddOpts?): dev.board.Card?, string? the new card
---@field set_size fun(self: dev.board.Backend, id: string, color: string, fence: integer?): boolean?, string? the card given the palette colour of that value, checked against the claim's fence when one is given
---@field set_labels fun(self: dev.board.Backend, id: string, labels: string[], fence: integer?): boolean?, string? the card's whole label list replaced, checked against the claim's fence when one is given
---@field note fun(self: dev.board.Backend, id: string, body: string, fence: integer?): boolean?, string? a comment of kind agent added to the card, checked against the claim's fence when one is given
---@field move fun(self: dev.board.Backend, id: string, column: string, fence: integer?): boolean?, string? the card moved to the top of a column, checked against the claim's fence when one is given
---@field claim fun(self: dev.board.Backend, id: string, claimant: string, ttl: integer, fence: integer?): integer?, string? the fence of the claim taken, or renewed when the caller's live fence is given
---@field release fun(self: dev.board.Backend, id: string, fence: integer): boolean?, string? the claim given up
---@field keepalive fun(self: dev.board.Backend, id: string, fence: integer, ticks: integer, state: string): integer?, string? the pid of a detached loop that renews the claim every tick until the state file loses the fence or the ticks run out

---@class dev.board.AddOpts
---@field description string? the card's description
---@field color string? the standard value of the palette colour to give it
---@field labels string[]? the labels to give it

---@class dev.board.Layout
---@field find fun(self: dev.board.Layout): boolean?, string? whether the board exists, or nil and a message
---@field create fun(self: dev.board.Layout): boolean?, string? the board made, with the name of the template it came from
---@field read fun(self: dev.board.Layout): dev.board.LayoutState?, string? the board's columns, colours and cards
---@field add_column fun(self: dev.board.Layout, name: string, is_done: boolean): boolean?, string? a column at the end
---@field move_column fun(self: dev.board.Layout, id: string, position: integer): boolean?, string? a column moved, 0 first
---@field mark_done fun(self: dev.board.Layout, id: string): boolean?, string? a column made the one of finished cards
---@field set_color fun(self: dev.board.Layout, id: string, fields: table<string, any>): boolean?, string? a colour's label, description or default flag
---@field set_card fun(self: dev.board.Layout, id: string, fields: table<string, any>): boolean?, string? a card's name or colour

---@class dev.board.LayoutState
---@field columns {id: string, name: string, is_done: boolean}[] the columns in board order
---@field colors {id: string, value: string, label: string, description: string, is_default: boolean}[] the palette
---@field cards {id: string, name: string, color_id: string?}[] every card

---The columns in board order.
M.COLUMNS = { "Icebox", "Backlog", "Ready", "In Progress", "In Review", "Blocked", "Done" }

---The column a card is added to when none is named.
M.DEFAULT_COLUMN = "Backlog"

---The column a worker takes cards from.
M.READY = "Ready"

---The column of cards being worked, where a move keeps a claim's loop alive.
M.WORKING = "In Progress"

---The column of finished cards, which `ls` leaves out.
M.DONE = "Done"

---The backends a project may name.
M.Backend = { POMB = "pomb", LOCAL = "local" }

---The fewest characters of a card id that name a card.
M.MIN_PREFIX = 8

local SHORT_FORMS = {
    progress = "In Progress",
    review = "In Review",
}

local UNSIZED = "unsized"

---The size words a user may type, with the palette colour each names.
M.SIZES = { ["1"] = "yellow", ["2"] = "green", ["3"] = "blue", ["3+"] = "red", [UNSIZED] = "white" }

local SIZE_WORDS = { "1", "2", "3", "3+", UNSIZED }

---Name a column from its full name or a short form, in any case.
---@param word string `ready`, `progress`, `In Review` and so on
---@return string? column the column's name, or nil when it is not one of the seven
function M.column(word)
    local lowered = word:lower():gsub("%s+", " ")
    local short = SHORT_FORMS[lowered]
    if short then
        return short
    end
    for _, name in ipairs(M.COLUMNS) do
        if name:lower() == lowered then
            return name
        end
    end
end

---List the column names a user may type.
---@return string names the seven names and the short forms
function M.column_help()
    return table.concat(M.COLUMNS, ", ") .. " (or progress, review, in any case)"
end

---Name a palette colour from a size word.
---@param word string `1`, `2`, `3`, `3+` or `unsized`
---@return string? color the colour's standard value, nil when the word is not a size
function M.size_color(word)
    return M.SIZES[word:lower()]
end

---List the size words a user may type.
---@return string words the five size words
function M.size_help()
    return table.concat(SIZE_WORDS, ", ")
end

---Tell whether a card has the colour a size word names, where no colour counts as white.
---@param card dev.board.Card the card
---@param color string the colour's standard value
---@return boolean
function M.has_color(card, color)
    return (card.color or M.SIZES[UNSIZED]) == color
end

---Find the card an id or a unique prefix of it names.
---@param cards dev.board.Card[] the board's cards
---@param word string the id or a prefix of at least 8 characters
---@return dev.board.Card? card the card
---@return string? message why no card matched
function M.resolve(cards, word)
    local prefix = word:lower()
    if #prefix < M.MIN_PREFIX or not prefix:find("^[%x-]+$") then
        return nil, "a card id needs at least " .. M.MIN_PREFIX .. " hex characters: " .. word
    end
    local found
    for _, card in ipairs(cards) do
        if card.id:lower():sub(1, #prefix) == prefix then
            if card.id:lower() == prefix then
                return card
            end
            if found then
                return nil, word .. " matches more than one card, give more characters"
            end
            found = card
        end
    end
    if not found then
        return nil, "no card starts with " .. word
    end
    return found
end

---Show the label for a card's colour.
---@param label string? the palette label, nil when the card has no colour
---@return string size the label or `unsized`
function M.size(label)
    if label == nil or label == "" then
        return UNSIZED
    end
    return label
end

---Say a card in one line.
---@param card dev.board.Card the card
---@param holders boolean? add the claim holder before the name
---@return string[] cells id prefix, column, size, labels, the holder when asked for, and name
function M.cells(card, holders)
    local labels = #card.labels > 0 and table.concat(card.labels, ",") or "-"
    local cells = { card.id:sub(1, M.MIN_PREFIX), card.column, card.size, labels }
    if holders then
        cells[#cells + 1] = card.claimant or "-"
    end
    cells[#cells + 1] = card.name
    return cells
end

---Pad rows into aligned columns, with no trailing spaces.
---@param rows string[][] the cells of each row
---@return string[] lines one line per row
function M.table_lines(rows)
    local widths = {}
    for _, row in ipairs(rows) do
        for c, value in ipairs(row) do
            widths[c] = math.max(widths[c] or 0, text.width(value))
        end
    end
    local lines = {}
    for r, row in ipairs(rows) do
        local parts = {}
        for c, value in ipairs(row) do
            parts[c] = c < #row and value .. string.rep(" ", widths[c] - text.width(value)) or value
        end
        lines[r] = table.concat(parts, text.GAP):gsub(" +$", "")
    end
    return lines
end

return M
