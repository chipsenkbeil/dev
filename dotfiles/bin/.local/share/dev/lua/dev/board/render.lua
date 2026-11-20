local board = require("dev.board")
local dev_text = require("dev.text")
local ui = require("dev.ui")

---The terminal table and summary the `board ls` verb prints.
---@class dev.board.render
local M = {}

local DOT = "●"
local HOLLOW = "○"
local UNSIZED_CELLS = 3
local METER_CELLS = 4
local GROUP_INDENT = "  "
---The size colors from smallest to largest.
local SIZE_ORDER = { board.SIZES["1"], board.SIZES["2"], board.SIZES["3"], board.SIZES["3+"] }
---How many dots each size color draws.
local SIZE_DOTS = {
    [board.SIZES["1"]] = 1,
    [board.SIZES["2"]] = 2,
    [board.SIZES["3"]] = 3,
    [board.SIZES["3+"]] = 4,
}
---The word the legend gives each size color.
local SIZE_WORDS = {
    [board.SIZES["1"]] = "1",
    [board.SIZES["2"]] = "2",
    [board.SIZES["3"]] = "3",
    [board.SIZES["3+"]] = ">3",
}
---The style each size color paints with.
local SIZE_STYLES = {
    [board.SIZES["1"]] = ui.Style.YELLOW,
    [board.SIZES["2"]] = ui.Style.GREEN,
    [board.SIZES["3"]] = ui.Style.BLUE,
    [board.SIZES["3+"]] = ui.Style.RED,
}
---The table headers, before a column is left out.
local HEADERS = { "ID", "COLUMN", "LANE", "SIZE", "LABELS", "DONE", "HELD BY", "NAME" }

local function column_style(stages, column)
    if column == stages.progress then
        return ui.Style.GREEN
    elseif column == stages.blocked then
        return ui.Style.YELLOW
    end
    return ui.Style.DIM
end

local function size_cell(screen, card)
    local color = card.color or board.SIZES.unsized
    local dots = SIZE_DOTS[color]
    if not dots then
        return ui.paint(screen, HOLLOW:rep(UNSIZED_CELLS), ui.Style.DIM)
    end
    return ui.paint(screen, DOT:rep(dots), SIZE_STYLES[color])
end

local function paint_run(screen, glyph, count, style)
    if count == 0 then
        return ""
    end
    return ui.paint(screen, glyph:rep(count), style)
end

local function meter_cell(screen, card)
    local total = #card.outcomes
    if total == 0 then
        return ui.paint(screen, "-", ui.Style.DIM)
    end
    local ticked = 0
    for _, outcome in ipairs(card.outcomes) do
        if outcome.done then
            ticked = ticked + 1
        end
    end
    local filled = math.floor(METER_CELLS * ticked / total + 0.5)
    return paint_run(screen, "▰", filled, ui.Style.GREEN)
        .. paint_run(screen, "▱", METER_CELLS - filled, ui.Style.DIM)
        .. " "
        .. ticked
        .. "/"
        .. total
end

---@class dev.board.render.View
---@field holders boolean whether a claimant column is drawn
---@field with_column boolean whether each row names its column
---@field lanes boolean whether each row names its lane
---@field stages dev.board.Stages the board's stages

local function terminal_cells(screen, card, view)
    local labels = #card.labels > 0 and table.concat(card.labels, ",") or "-"
    local cells = { card.id:sub(1, board.MIN_PREFIX) }
    if view.with_column then
        local style = column_style(view.stages, card.column)
        cells[#cells + 1] = ui.paint(screen, card.column, style)
    end
    if view.lanes then
        cells[#cells + 1] = ui.paint(screen, card.lane or "-", ui.Style.DIM)
    end
    cells[#cells + 1] = size_cell(screen, card)
    cells[#cells + 1] =
        ui.paint(screen, labels, #card.labels > 0 and ui.Style.YELLOW or ui.Style.DIM)
    cells[#cells + 1] = meter_cell(screen, card)
    if view.holders then
        cells[#cells + 1] = card.claimant or ui.paint(screen, "-", ui.Style.DIM)
    end
    cells[#cells + 1] = board.epic_mark(card) .. card.name
    return cells
end

local function terminal_table(screen, cards, view)
    local headers = {}
    for _, header in ipairs(HEADERS) do
        local shown = (header ~= "COLUMN" or view.with_column)
            and (header ~= "LANE" or view.lanes)
            and (header ~= "HELD BY" or view.holders)
        if shown then
            headers[#headers + 1] = header
        end
    end
    local rows = {}
    for _, card in ipairs(cards) do
        rows[#rows + 1] = terminal_cells(screen, card, view)
    end
    return ui.table(screen, headers, rows)
end

local function summary_lines(screen, cards, stages)
    local counts = {}
    for _, card in ipairs(cards) do
        counts[card.column] = (counts[card.column] or 0) + 1
    end
    local parts = { ui.paint(screen, dev_text.count(#cards, "card"), ui.Style.BOLD) }
    local shown = {}
    for _, column in ipairs(stages.list) do
        shown[#shown + 1] = column
    end
    for _, column in ipairs(stages.finished) do
        shown[#shown + 1] = column
    end
    local seen = {}
    for _, column in ipairs(shown) do
        if counts[column] and not seen[column] then
            seen[column] = true
            parts[#parts + 1] =
                ui.paint(screen, counts[column] .. " " .. column:lower(), ui.Style.DIM)
        end
    end
    local legend = { ui.paint(screen, "size", ui.Style.DIM) }
    for _, color in ipairs(SIZE_ORDER) do
        legend[#legend + 1] = ui.paint(screen, DOT:rep(SIZE_DOTS[color]), SIZE_STYLES[color])
            .. " "
            .. SIZE_WORDS[color]
    end
    legend[#legend + 1] = ui.paint(screen, HOLLOW:rep(UNSIZED_CELLS), ui.Style.DIM) .. " unsized"
    return { table.concat(parts, " · "), table.concat(legend, "  ") }
end

local function terminal_flat(screen, cards, opts)
    return terminal_table(
        screen,
        cards,
        { holders = opts.holders, with_column = true, lanes = opts.lanes, stages = opts.stages }
    )
end

local function terminal_grouped(screen, cards, opts)
    local inner = screen:with_height(screen.height)
    inner.width = screen.width - #GROUP_INDENT
    local lines = terminal_table(
        inner,
        cards,
        { holders = opts.holders, with_column = false, lanes = opts.lanes, stages = opts.stages }
    )
    local groups, order = {}, {}
    for at, card in ipairs(cards) do
        if not groups[card.column] then
            groups[card.column] = {}
            order[#order + 1] = card.column
        end
        table.insert(groups[card.column], lines[at + 1])
    end
    local out = {}
    for _, column in ipairs(order) do
        if #out > 0 then
            out[#out + 1] = ""
        end
        out[#out + 1] = ui.paint(screen, column, ui.Style.BOLD)
            .. "  "
            .. ui.paint(screen, dev_text.count(#groups[column], "card"), ui.Style.DIM)
        for _, line in ipairs(groups[column]) do
            out[#out + 1] = GROUP_INDENT .. line
        end
    end
    if not opts.shows_done then
        out[#out + 1] = ""
        out[#out + 1] = ui.paint(
            screen,
            opts.stages:done_column()
                .. " is left out unless --column "
                .. opts.stages:done_column():lower(),
            ui.Style.DIM
        )
    end
    return out
end

---@class dev.board.render.Options
---@field holders boolean whether a claimant column is drawn
---@field lanes boolean whether a lane column is drawn
---@field grouped boolean whether the rows sit under a heading per column
---@field want string? the column the listing was asked for
---@field stages dev.board.Stages the board's stages

---Draw the summary lines and the card table for a color terminal.
---@param screen dev.ui.Context the terminal to draw for
---@param cards dev.board.Card[] the cards to show
---@param opts dev.board.render.Options how to draw them
---@return string[] lines the lines to print
function M.ls(screen, cards, opts)
    local lines = summary_lines(screen, cards, opts.stages)
    local finished = {}
    for _, name in ipairs(opts.stages.finished) do
        finished[name] = true
    end
    lines[#lines + 1] = ""
    local body
    if opts.grouped then
        body = terminal_grouped(screen, cards, {
            holders = opts.holders,
            lanes = opts.lanes,
            shows_done = opts.want ~= nil and finished[opts.want],
            stages = opts.stages,
        })
    else
        body = terminal_flat(
            screen,
            cards,
            { holders = opts.holders, lanes = opts.lanes, stages = opts.stages }
        )
    end
    for _, line in ipairs(body) do
        lines[#lines + 1] = line
    end
    return lines
end

---Format a card's history as aligned rows, one per event.
---@param events dev.board.HistoryEvent[] the events, newest first
---@return string text the rows, or `no history` when there are none
function M.history(events)
    if #events == 0 then
        return "no history"
    end
    local rows = {}
    for index, event in ipairs(events) do
        local change = "-"
        if event.from or event.to then
            change = (event.from or "-") .. " -> " .. (event.to or "-")
        end
        local stamp = event.at:sub(1, 16):gsub("T", " ")
        rows[index] = { stamp, event.kind, change, event.actor, event.token or "-" }
    end
    return table.concat(board.table_lines(rows), "\n")
end

return M
