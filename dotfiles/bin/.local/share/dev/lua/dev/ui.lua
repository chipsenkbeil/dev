local devos = require("dev.os")
local term = require("dev.term")
local text = require("dev.text")

---@class dev.ui.Style
---@field BOLD string bold weight
---@field DIM string faint intensity
---@field RED string red foreground
---@field GREEN string green foreground
---@field YELLOW string yellow foreground
---@field BLUE string blue foreground
---@field MAGENTA string magenta foreground
---@field CYAN string cyan foreground

---@class dev.ui.MarkKind
---@field RUNNING string a running thing, a green dot
---@field STOPPED string a stopped thing, a dim hollow dot
---@field OK string a success, a green check
---@field FAIL string a failure, a red cross

---@class dev.ui
---@field Style dev.ui.Style style names `paint` takes
---@field Mark dev.ui.MarkKind kinds of mark `mark` draws
local M = {
    Style = {
        BOLD = "bold",
        DIM = "dim",
        RED = "red",
        GREEN = "green",
        YELLOW = "yellow",
        BLUE = "blue",
        MAGENTA = "magenta",
        CYAN = "cyan",
    },
    Mark = {
        RUNNING = "running",
        STOPPED = "stopped",
        OK = "ok",
        FAIL = "fail",
    },
}

local Style, Mark = M.Style, M.Mark

local SGR = {
    [Style.BOLD] = 1,
    [Style.DIM] = 2,
    [Style.RED] = 31,
    [Style.GREEN] = 32,
    [Style.YELLOW] = 33,
    [Style.BLUE] = 34,
    [Style.MAGENTA] = 35,
    [Style.CYAN] = 36,
}
local MARKS = {
    [Mark.RUNNING] = { "●", Style.GREEN },
    [Mark.STOPPED] = { "○", Style.DIM },
    [Mark.OK] = { "✓", Style.GREEN },
    [Mark.FAIL] = { "✗", Style.RED },
}
local stderr = io.stderr

---@class dev.ui.Context
---@field color boolean whether standard output takes color
---@field stderr_color boolean whether standard error takes color
---@field interactive boolean whether standard input and output are terminals
---@field width integer columns a line may fill
local Context = {}
Context.__index = Context

---@class dev.ui.ContextOpts
---@field color boolean? color for both streams, instead of asking the environment
---@field interactive boolean? whether a user is at the terminal, instead of asking the terminal
---@field width integer? columns a line may fill, instead of asking the terminal
---@field getenv (fun(name: string): string?)? environment lookup, defaulting to `os.getenv`
---@field isatty (fun(fd: integer): boolean)? terminal check, defaulting to `dev.os.isatty`
---@field size (fun(): integer, integer)? terminal size, defaulting to `dev.term.size`

---Read the terminal and the environment once into a context.
---@param opts dev.ui.ContextOpts? overrides for what would be read
---@return dev.ui.Context ctx the settings every drawing function takes
function M.context(opts)
    opts = opts or {}
    local getenv = opts.getenv or os.getenv
    local isatty = opts.isatty or devos.isatty
    local size = opts.size or term.size
    local function color_for(fd)
        local no_color = getenv("NO_COLOR")
        return (no_color == nil or no_color == "") and getenv("TERM") ~= "dumb" and isatty(fd)
    end
    local color, stderr_color = opts.color, opts.color
    if color == nil then
        color, stderr_color = color_for(1), color_for(2)
    end
    local interactive = opts.interactive
    if interactive == nil then
        interactive = isatty(0) and isatty(1)
    end
    local width = opts.width
    if width == nil then
        local _, cols = size()
        width = cols
    end
    return setmetatable({
        color = color,
        stderr_color = stderr_color,
        interactive = interactive,
        width = width,
    }, Context)
end

---Derive the context for drawing on standard error.
---@return dev.ui.Context ctx a copy whose `color` is `stderr_color`
function Context:stderr()
    local copy = setmetatable({}, Context)
    for key, value in pairs(self) do
        copy[key] = value
    end
    copy.color = self.stderr_color
    return copy
end

---Wrap `s` in the escapes for `...`, or return it as it is when color is off.
---@param ctx dev.ui.Context drawing settings
---@param s string text to color
---@param ... string style names from `Style`
---@return string painted text ending in a reset when it was colored
function M.paint(ctx, s, ...)
    local styles = { ... }
    if not ctx.color or #styles == 0 then
        return s
    end
    local out = {}
    for _, style in ipairs(styles) do
        out[#out + 1] = "\27[" .. SGR[style] .. "m"
    end
    return table.concat(out) .. s .. "\27[0m"
end

---Draw the glyph for a kind of mark in its color.
---@param ctx dev.ui.Context drawing settings
---@param kind string kind from `Mark`
---@return string glyph the painted glyph
function M.mark(ctx, kind)
    local mark = MARKS[kind]
    return M.paint(ctx, mark[1], mark[2])
end

local function cell_text(cell)
    return type(cell) == "table" and cell.text or cell
end

---@class dev.ui.StyledCell
---@field text string text shown in the cell
---@field style string[]? style names from `Style` to paint the text with

---@class dev.ui.TableOpts
---@field bold_column integer? index of the column to draw bold

---Lay out `rows` under `headers` with every column padded to its widest cell.
---
---Each line is cut to the context's width. The header is dim and bold.
---@param ctx dev.ui.Context drawing settings
---@param headers string[] column titles
---@param rows (string|dev.ui.StyledCell)[][] one list of cells per row
---@param opts dev.ui.TableOpts? how to draw the table
---@return string[] lines the header line, then one line per row
function M.table(ctx, headers, rows, opts)
    local bold_column = opts and opts.bold_column
    local widths = {}
    local function measure(cells)
        for i, cell in ipairs(cells) do
            widths[i] = math.max(widths[i] or 0, text.width(cell_text(cell)))
        end
    end
    measure(headers)
    for _, row in ipairs(rows) do
        measure(row)
    end

    local function line(cells, forced)
        local parts = {}
        for i, cell in ipairs(cells) do
            local s = cell_text(cell)
            local styles = type(cell) == "table" and cell.style or {}
            if forced then
                styles = forced
            elseif i == bold_column then
                styles = { Style.BOLD }
            end
            local pad = i < #cells and string.rep(" ", widths[i] - text.width(s)) or ""
            parts[#parts + 1] = M.paint(ctx, s, unpack(styles)) .. pad
        end
        return text.fit(table.concat(parts, text.GAP), ctx.width)
    end

    local lines = { line(headers, { Style.DIM, Style.BOLD }) }
    for _, row in ipairs(rows) do
        lines[#lines + 1] = line(row)
    end
    return lines
end

---@class dev.ui.BarOpts
---@field used number amount filled
---@field total number amount that fills the bar
---@field width integer cells the bar spans

---Draw a bar of `opts.width` cells that is `opts.used` of `opts.total` full.
---@param ctx dev.ui.Context drawing settings
---@param opts dev.ui.BarOpts how full the bar is and how wide
---@return string bar the painted bar, or an empty string when the context is not interactive
function M.bar(ctx, opts)
    if not ctx.interactive then
        return ""
    end
    local width = opts.width
    local filled = opts.total > 0 and math.floor(width * opts.used / opts.total + 0.5) or 0
    filled = math.max(0, math.min(width, filled))
    return M.paint(ctx, string.rep("█", filled), Style.GREEN)
        .. M.paint(ctx, string.rep("░", width - filled), Style.DIM)
end

---@class dev.ui.RequireTerminalOpts
---@field command string name of the command that needs the terminal
---@field missing string what the user did not give
---@field hint string how to give it without a terminal

---Exit with status 2 and a message on standard error unless a user is at the terminal.
---@param ctx dev.ui.Context drawing settings
---@param opts dev.ui.RequireTerminalOpts what to say when there is no terminal
function M.require_terminal(ctx, opts)
    if ctx.interactive then
        return
    end
    stderr:write(
        M.mark(ctx:stderr(), Mark.FAIL),
        " ",
        opts.command,
        ": no ",
        opts.missing,
        " given and no terminal to pick one; pass ",
        opts.hint,
        "\n"
    )
    os.exit(2)
end

return M
