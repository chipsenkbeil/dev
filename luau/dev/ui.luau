local dev_os = require("dev.os")
local fs = require("dev.fs")
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
local FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ERASE_LINE = "\r\27[K"
local HIDE_CURSOR = "\27[?25l"
local SHOW_CURSOR = "\27[?25h"
local POLL_INTERVAL_SECS = 0.1
local SIGINT = 2
local INTERRUPTED = dev_os.SIGNAL_EXIT_BASE + SIGINT
local stderr = dev_os.stderr

---@class dev.ui.Context
---@field color boolean whether standard output takes color
---@field stderr_color boolean whether standard error takes color
---@field interactive boolean whether standard input and output are terminals
---@field width integer columns a line may fill
---@field height integer? rows the screen has, or nil to draw every row outside the picker
---@field size fun(): integer, integer terminal rows and columns
---@field getenv fun(name: string): string? environment lookup
local Context = {}
Context.__index = Context

---@class dev.ui.context.Opts
---@field color boolean? color for both streams, instead of asking the environment
---@field interactive boolean? whether a user is at the terminal, instead of asking the terminal
---@field width integer? columns a line may fill, instead of asking the terminal
---@field height integer? rows the screen has, left nil to draw every row outside the picker
---@field getenv (fun(name: string): string?)? environment lookup, defaulting to `dev.os.getenv`
---@field isatty (fun(fd: integer): boolean)? terminal check, defaulting to `dev.os.isatty`
---@field size (fun(): integer, integer)? terminal size, defaulting to `dev.term.size`

---Read the terminal and the environment once into a context.
---@param opts dev.ui.context.Opts? overrides for what would be read
---@return dev.ui.Context ctx the settings every drawing function takes
function M.context(opts)
    opts = opts or {}
    local getenv = opts.getenv or dev_os.getenv
    local isatty = opts.isatty or dev_os.isatty
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
        width = term.DEFAULT_COLS
        if isatty(1) then
            local _, cols = size()
            width = cols
        end
    end
    return setmetatable({
        color = color,
        stderr_color = stderr_color,
        interactive = interactive,
        width = width,
        height = opts.height,
        size = size,
        getenv = getenv,
    }, Context)
end

---Derive a context that has `rows` rows.
---@param rows integer rows the screen has
---@return dev.ui.Context ctx a copy whose `height` is `rows`
function Context:with_height(rows)
    local copy = setmetatable({}, Context)
    for key, value in pairs(self) do
        copy[key] = value
    end
    copy.height = rows
    return copy
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

---@class dev.ui.table.Opts
---@field bold_column integer? index of the column to draw bold

---Lay out `rows` under `headers` with every column padded to its widest cell.
---
---Each line is cut to the context's width. The header is dim and bold.
---@param ctx dev.ui.Context drawing settings
---@param headers string[] column titles
---@param rows (string|dev.ui.StyledCell)[][] one list of cells per row
---@param opts dev.ui.table.Opts? how to draw the table
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
            parts[#parts + 1] = M.paint(ctx, s, table.unpack(styles)) .. pad
        end
        return text.fit(table.concat(parts, text.GAP), ctx.width)
    end

    local lines = { line(headers, { Style.DIM, Style.BOLD }) }
    for _, row in ipairs(rows) do
        lines[#lines + 1] = line(row)
    end
    return lines
end

---@class dev.ui.bar.Opts
---@field used number amount filled
---@field total number amount that fills the bar
---@field width integer cells the bar spans

---Draw a bar of `opts.width` cells that is `opts.used` of `opts.total` full.
---@param ctx dev.ui.Context drawing settings
---@param opts dev.ui.bar.Opts how full the bar is and how wide
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

---@class dev.ui.require_terminal.Opts
---@field command string name of the command that needs the terminal
---@field missing string what the user did not give
---@field hint string how to give it without a terminal

---Exit with status 2 and a message on standard error unless a user is at the terminal.
---@param ctx dev.ui.Context drawing settings
---@param opts dev.ui.require_terminal.Opts what to say when there is no terminal
function M.require_terminal(ctx, opts)
    if ctx.interactive then
        return
    end
    stderr:write(
        M.mark(ctx:stderr(), Mark.FAIL),
        " ",
        opts.command,
        ": No ",
        opts.missing,
        " given and no terminal to pick one. Pass ",
        opts.hint,
        ".\n"
    )
    dev_os.exit(2)
end

---Ask a yes or no question on the controlling terminal, where no is the default.
---
---The consequence is wrapped to the context's width on lines of its own, and the question
---comes last, on the line that takes the answer. Exits with status 2 and a message on standard
---error when no user is at the terminal. Ctrl-C ends the line, closes the terminal and exits
---with status 130.
---@param ctx dev.ui.Context drawing settings
---@param question string the question, drawn in yellow
---@param consequence string what saying yes does
---@return boolean yes true for y or yes in any case, false for anything else
function M.confirm(ctx, question, consequence)
    M.require_terminal(ctx, { command = "dev", missing = "confirmation", hint = "-y" })
    local fd, open_err = term.open_tty()
    if not fd then
        error(open_err, 0)
    end
    local lines = {}
    for _, line in ipairs(text.wrap(text.words(consequence), ctx.width)) do
        lines[#lines + 1] = line .. "\n"
    end
    lines[#lines + 1] = M.paint(ctx, question, Style.YELLOW)
        .. " [y/"
        .. M.paint(ctx, "N", Style.BOLD)
        .. "] "
    term.write(fd, table.concat(lines))
    local ok, answer, why = pcall(term.read_line, fd)
    if not ok or why == "interrupted" then
        term.write(fd, "\n")
    end
    term.close(fd)
    if not ok then
        if tostring(answer):find("interrupted!", 1, true) then
            dev_os.exit(INTERRUPTED)
        end
        error(answer, 0)
    end
    if why == "interrupted" then
        dev_os.exit(INTERRUPTED)
    end
    answer = answer and answer:lower():match("^%s*(.-)%s*$")
    return answer == "y" or answer == "yes"
end

---@class dev.ui.spinner_line.Opts
---@field frame integer which frame of the spinner to draw, counting from 1
---@field label string what is running
---@field detail string extra dim text after the label, or an empty string
---@field seconds integer time elapsed

---Draw one line of the spinner: glyph, label, detail and elapsed time.
---@param ctx dev.ui.Context drawing settings
---@param opts dev.ui.spinner_line.Opts what the line shows
---@return string line the painted line
function M.spinner_line(ctx, opts)
    local glyph = FRAMES[(opts.frame - 1) % #FRAMES + 1]
    local parts = { M.paint(ctx, glyph, Style.GREEN), " ", opts.label }
    if opts.detail ~= "" then
        parts[#parts + 1] = " " .. M.paint(ctx, "· " .. opts.detail, Style.DIM)
    end
    local clock = string.format("%d:%02d", math.floor(opts.seconds / 60), opts.seconds % 60)
    parts[#parts + 1] = " " .. M.paint(ctx, clock, Style.DIM)
    return table.concat(parts)
end

local STOP_POLLS = 40

local SPIN_PREFIX = "dev-spin"

local function read_all(path)
    return fs.read(path) or ""
end

local function was_interrupted(reason)
    return tostring(reason):find("interrupted!", 1, true) ~= nil
end

local function report(err, label, code, captured)
    if code == 0 then
        stderr:write(M.mark(err, Mark.OK), " ", label, "\n")
        return
    end
    stderr:write(M.mark(err, Mark.FAIL), " ", label, "\n", captured)
    if captured ~= "" and captured:sub(-1) ~= "\n" then
        stderr:write("\n")
    end
end

---Ask the command to stop and wait a moment for it to go.
---
---A second interrupt while waiting, or a command that outlasts the wait, gets KILL.
local function stop(proc)
    local ok, gone = pcall(function()
        proc:kill("TERM")
        for _ = 1, STOP_POLLS do
            if proc:wait(POLL_INTERVAL_SECS) ~= nil then
                return true
            end
        end
        return false
    end)
    if ok and gone then
        return
    end
    pcall(function()
        proc:kill("KILL")
        proc:wait(POLL_INTERVAL_SECS)
    end)
end

---@class dev.ui.Job
---@field err dev.ui.Context settings for drawing on standard error
---@field label string what is running
---@field proc { pid: number, wait: (self: any, secs: number?) -> number?, kill: (self: any, signal: (number | string)?) -> boolean } the running command, from `dev.os.spawn`

---Draw the spinner until the command ends, returning its exit status.
local function watch(job)
    local started, frame = os.time(), 0
    while true do
        frame = frame + 1
        stderr:write(
            ERASE_LINE,
            M.spinner_line(
                job.err,
                { frame = frame, label = job.label, detail = "", seconds = os.time() - started }
            )
        )
        stderr:flush()
        local code = job.proc:wait(POLL_INTERVAL_SECS)
        if code ~= nil then
            return code
        end
    end
end

local function discard(path)
    if path then
        fs.remove(path)
    end
end

---@class dev.ui.SpinRun
---@field ctx dev.ui.Context drawing settings
---@field label string what is running
---@field argv string[] command and its arguments
---@field capture boolean whether standard output is kept apart
---@field files { out: string?, err: string? } filled in with the paths of the temp files

---Run the job under the spinner and return its code and standard output.
---
---Each temp file goes into `run.files` as soon as it exists, so the caller can remove them
---whatever happens here.
---@param run dev.ui.SpinRun the job and where its temp files are recorded
---@return integer code exit status of the command
---@return string output standard output of the command, only with `run.capture`
local function run_job(run)
    local err = run.ctx:stderr()
    local files = run.files
    files.out = fs.mktemp({ prefix = SPIN_PREFIX })
    files.err = run.capture and fs.mktemp({ prefix = SPIN_PREFIX }) or nil
    if not files.out or (run.capture and not files.err) then
        error("spin could not create a temp file", 0)
    end
    local proc, spawn_err = dev_os.spawn(run.argv, {
        stdin = "null",
        stdout = files.out,
        stderr = run.capture and files.err or "stdout",
    })
    if not proc then
        stderr:write(M.mark(err, Mark.FAIL), " ", run.label, "\n", tostring(spawn_err), "\n")
        return dev_os.EXEC_FAILED, ""
    end
    local ok, code = pcall(function()
        stderr:write(HIDE_CURSOR)
        return watch({ err = err, label = run.label, proc = proc })
    end)
    stderr:write(ERASE_LINE, SHOW_CURSOR)
    if not ok then
        stop(proc)
        error(code, 0)
    end
    report(err, run.label, code, read_all(run.capture and files.err or files.out))
    return code, run.capture and read_all(files.out) or ""
end

---@class dev.ui.spin.Opts
---@field capture boolean? keep standard output apart and return it, showing only standard error on
---   failure

---Run `argv` with a spinner on standard error, then show a check or a cross and its output.
---
---Without a terminal on both ends, or when TERM is dumb, the command just runs with the
---terminal's streams. Otherwise its output is held back and shown only when it fails. Ctrl-C
---stops the command and every process it started. With `opts.capture`, standard output is
---returned as a second value and never shown, and standard error is what a failure shows.
---@param ctx dev.ui.Context drawing settings
---@param label string what is running
---@param argv string[] command and its arguments, with at least one word
---@param opts dev.ui.spin.Opts? `capture`
---@return integer code exit status of the command, or 130 when the user interrupted it
---@return string? output standard output of the command, only with `opts.capture`
function M.spin(ctx, label, argv, opts)
    local capture = opts ~= nil and opts.capture == true
    if not (ctx.interactive and dev_os.isatty(2) and ctx.getenv("TERM") ~= "dumb") then
        if capture then
            local out, code = dev_os.capture(argv)
            return code, out
        end
        return dev_os.run(argv)
    end
    local files: { out: string?, err: string? } = {}
    local ok, code, output = pcall(run_job, {
        ctx = ctx,
        label = label,
        argv = argv,
        capture = capture,
        files = files,
    })
    discard(files.out)
    discard(files.err)
    if not ok then
        if was_interrupted(code) then
            return INTERRUPTED, ""
        end
        error(code, 0)
    end
    if capture then
        return code, output
    end
    return code
end

---@class dev.ui.page.Opts
---@field pager string? command to run instead of `$PAGER`
---@field allowed boolean? false to print directly, true by default
---@field interactive boolean? whether standard output is a terminal, instead of asking the terminal
---@field rows integer? rows the screen has, instead of asking the terminal
---@field fallback string? the text to print when the pager fails, instead of `content`

---Decide whether `content` goes through a pager.
---
---It does when paging is allowed, standard output is a terminal and the text
---has more lines than the screen has rows.
---@param content string the text to show
---@param opts dev.ui.page.Opts? `allowed`, `interactive` and `rows`, each read from the terminal
---   when nil
---@return boolean page true when the pager should show the text
function M.should_page(content, opts)
    opts = opts or {}
    if opts.allowed == false then
        return false
    end
    local interactive = opts.interactive
    if interactive == nil then
        interactive = dev_os.isatty(1)
    end
    if not interactive then
        return false
    end
    local _, newlines = content:gsub("\n", "")
    local lines = newlines + (content:find("\n$") and 0 or 1)
    local rows = opts.rows or term.size()
    return lines > rows
end

---Show `content` through a pager when it is taller than the screen, else print it.
---
---A pager that quits early is not an error.
---A pager that is missing or exits non-zero gets one warning line and the text printed directly.
---@param content string the text to show
---@param opts dev.ui.page.Opts? the pager command, and the settings `should_page` reads
---@return boolean paged true when the pager showed the text
function M.page(content, opts)
    opts = opts or {}
    if not M.should_page(content, opts) then
        dev_os.stdout:write(content)
        return false
    end
    local shown = term.page(content, { pager = opts.pager, rows = opts.rows, interactive = true })
    if shown ~= nil then
        return shown
    end
    stderr:write("The pager failed, so the text follows without it.\n")
    dev_os.stdout:write(opts.fallback or content)
    return false
end

return M
