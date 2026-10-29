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
---@field description string? the card's description, nil when it has none
---@field claimant string? who holds a live claim on it
---@field checks string[] the run commands in its checks rows, empty when it has none

---@class dev.board.Backend
---@field describe fun(self: dev.board.Backend): string the backend and board, as `status` prints them
---@field cards fun(self: dev.board.Backend): dev.board.Card[]?, string? every card in column order, or nil and a message
---@field checks_field fun(self: dev.board.Backend): boolean?, string? whether the board has the checks field, or nil and a message
---@field next fun(self: dev.board.Backend): dev.board.Card?, string? the top unclaimed, unblocked Ready card, or nil and a message when it failed
---@field add fun(self: dev.board.Backend, name: string, column: string, opts: dev.board.AddOpts?): dev.board.Card?, string? the new card
---@field entered fun(self: dev.board.Backend): table<string, string>?, string? the time each card entered its column, as an RFC 3339 stamp by card id, or nil and a message
---@field set_size fun(self: dev.board.Backend, id: string, color: string, fence: integer?): boolean?, string? the card given the palette colour of that value, checked against the claim's fence when one is given
---@field set_labels fun(self: dev.board.Backend, id: string, labels: string[], fence: integer?): boolean?, string? the card's whole label list replaced, checked against the claim's fence when one is given
---@field set_description fun(self: dev.board.Backend, id: string, text: string, fence: integer?): boolean?, string? the card's description replaced, checked against the claim's fence when one is given
---@field note fun(self: dev.board.Backend, id: string, body: string, fence: integer?): boolean?, string? a comment of kind agent added to the card, checked against the claim's fence when one is given
---@field comments fun(self: dev.board.Backend, id: string): dev.board.Comment[]?, string? the card's comments, oldest first
---@field edit_note fun(self: dev.board.Backend, id: string, comment: string, body: string): boolean?, string? the body of one of the caller's own comments replaced, or nil and a message
---@field delete_note fun(self: dev.board.Backend, id: string, comment: string): boolean?, string? one of the caller's own comments deleted, or nil and a message
---@field link fun(self: dev.board.Backend, id: string, kind: string, other: string): boolean?, string? a link of that kind (`blocked_by`, `blocks` or `related`) from the card to the card with that full id, which may sit on another board; linking twice changes nothing
---@field other_board fun(self: dev.board.Backend, name: string): dev.board.Backend?, string? the backend of another board on the same server, or nil and a message
---@field move fun(self: dev.board.Backend, id: string, column: string, fence: integer?): boolean?, string? the card moved to the top of a column, checked against the claim's fence when one is given
---@field claim fun(self: dev.board.Backend, id: string, claimant: string, ttl: integer, fence: integer?): integer?, string? the fence of the claim taken, or renewed when the caller's live fence is given
---@field release fun(self: dev.board.Backend, id: string, fence: integer): boolean?, string? the claim given up
---@field keepalive fun(self: dev.board.Backend, id: string, fence: integer, ticks: integer, state: string): integer?, string? the pid of a detached loop that renews the claim every tick until the state file loses the fence or the ticks run out

---@class dev.board.Comment
---@field id string the comment's full id
---@field who string the token's name, else the kind of actor that wrote it
---@field at string when it was written, as an RFC 3339 stamp
---@field body string its text

---@class dev.board.AddOpts
---@field description string? the card's description
---@field color string? the standard value of the palette colour to give it
---@field labels string[]? the labels to give it
---@field checks string[] the run commands to give it, one checks row each

---@class dev.board.Layout
---@field find fun(self: dev.board.Layout): boolean?, string? whether the board exists, or nil and a message
---@field create fun(self: dev.board.Layout): boolean?, string? the board made, with the name of the template it came from
---@field read fun(self: dev.board.Layout): dev.board.LayoutState?, string? the board's columns, colours and cards
---@field add_column fun(self: dev.board.Layout, name: string, is_done: boolean): boolean?, string? a column at the end
---@field move_column fun(self: dev.board.Layout, id: string, position: integer): boolean?, string? a column moved, 0 first
---@field mark_done fun(self: dev.board.Layout, id: string): boolean?, string? a column made the one of finished cards
---@field set_color fun(self: dev.board.Layout, id: string, fields: table<string, any>): boolean?, string? a colour's label, description, default flag or enabled flag
---@field set_card fun(self: dev.board.Layout, id: string, fields: table<string, any>): boolean?, string? a card's name or colour
---@field add_checks_field fun(self: dev.board.Layout): boolean?, string? the checks field defined on the board

---@class dev.board.LayoutState
---@field columns {id: string, name: string, is_done: boolean}[] the columns in board order
---@field colors {id: string, value: string, label: string, description: string, is_default: boolean, enabled: boolean}[] the palette
---@field cards {id: string, name: string, color_id: string?}[] every card
---@field has_checks boolean whether the board has the checks field

---The columns in board order.
M.COLUMNS = { "Icebox", "Backlog", "Ready", "In Progress", "In Review", "Blocked", "Done" }

---The key of the custom field that holds a card's checks.
M.CHECKS_FIELD = "dev.checks"

---The key of the checks table column that holds the command to run.
M.CHECKS_RUN = "run"

---The column a card is added to when none is named.
M.DEFAULT_COLUMN = "Backlog"

---The column of cards that are free-form, which are never scaffolded or checked.
M.ICEBOX = "Icebox"

---The column a worker takes cards from.
M.READY = "Ready"

---The column of cards waiting for review.
M.REVIEW = "In Review"

---The column of cards being worked, where a move keeps a claim's loop alive.
M.WORKING = "In Progress"

---The columns where a card that sits untouched is stale.
M.STALE_COLUMNS = {
    [M.DEFAULT_COLUMN] = true,
    [M.READY] = true,
    [M.WORKING] = true,
    [M.REVIEW] = true,
}
---The label of a card that waits on the owner, which `stale` lists apart at any age.
M.NEEDS_HUMAN = "needs:human"

---The column of finished cards, which `ls` leaves out.
M.DONE = "Done"

---The backends a project may name.
M.Backend = { POMB = "pomb", LOCAL = "local" }

---The kinds of link between two cards.
M.LinkKind = { BLOCKED_BY = "blocked_by", BLOCKS = "blocks", RELATED = "related" }

---The link kinds in the order help lists them.
M.LINK_KINDS = { M.LinkKind.BLOCKED_BY, M.LinkKind.BLOCKS, M.LinkKind.RELATED }

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

---Find the card, or other item with an id, that an id or a unique prefix of it names.
---@generic T: {id: string}
---@param items T[] the board's cards, or a card's comments
---@param word string the id or a prefix of at least 8 characters
---@param noun string? what the items are called in a message, `card` by default
---@return T? item the item
---@return string? message why no item matched
function M.resolve(items, word, noun)
    noun = noun or "card"
    local prefix = word:lower()
    if #prefix < M.MIN_PREFIX or not prefix:find("^[%x-]+$") then
        return nil,
            "a " .. noun .. " id needs at least " .. M.MIN_PREFIX .. " hex characters: " .. word
    end
    local found
    for _, item in ipairs(items) do
        if item.id:lower():sub(1, #prefix) == prefix then
            if item.id:lower() == prefix then
                return item
            end
            if found then
                return nil, word .. " matches more than one " .. noun .. ", give more characters"
            end
            found = item
        end
    end
    if not found then
        return nil, "no " .. noun .. " starts with " .. word
    end
    return found
end

---The headings of card format v1, in order.
M.HEADINGS = { "Problem", "Change", "Out of scope", "Done when" }

local DONE_WHEN = M.HEADINGS[4]

local function lines_of(description)
    return ((description or "") .. "\n"):gmatch("(.-)\n")
end

local function heading_of(line)
    return line:match("^##%s+(.-)%s*$")
end

---Give a description the four v1 headings, filling Problem from the text given. A text that already
---holds a v1 heading is kept as it is.
---@param description string? the text the caller gave, if any
---@return string description the text with the headings
function M.scaffold(description)
    local given = (description or ""):match("^%s*(.-)%s*$")
    for line in lines_of(given) do
        local name = heading_of(line)
        for _, heading in ipairs(M.HEADINGS) do
            if name == heading then
                return given
            end
        end
    end
    local parts = {}
    for i, heading in ipairs(M.HEADINGS) do
        parts[i] = "## " .. heading .. "\n" .. (i == 1 and given ~= "" and given .. "\n" or "")
    end
    return table.concat(parts, "\n")
end

---List what a description lacks of card format v1: each missing heading, and a Done when with no
---checklist item.
---@param description string? the card's description
---@return string[] missing the problems, empty when the card follows the format
function M.missing_v1(description)
    local seen, items, current = {}, 0, nil
    for line in lines_of(description) do
        local name = heading_of(line)
        if name then
            current = name
            seen[name] = true
        elseif current == DONE_WHEN and line:find("^%s*[-*]%s%[[ xX]%]%s+%S") then
            items = items + 1
        end
    end
    local missing = {}
    for _, heading in ipairs(M.HEADINGS) do
        if not seen[heading] then
            missing[#missing + 1] = "## " .. heading
        end
    end
    if seen[DONE_WHEN] and items == 0 then
        missing[#missing + 1] = "a checklist item under ## " .. DONE_WHEN
    end
    return missing
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
