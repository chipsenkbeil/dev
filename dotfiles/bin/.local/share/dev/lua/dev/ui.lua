local devos = require("dev.os")
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
local DEFAULT_PAGER = "less -R"
local POLL_INTERVAL_SECS = 0.1
local POLL_DONE, POLL_RUNNING, POLL_GONE = 0, 1, 2
local SIGINT = 2
local INTERRUPTED = devos.SIGNAL_EXIT_BASE + SIGINT
local stderr = io.stderr

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

---@class dev.ui.ContextOpts
---@field color boolean? color for both streams, instead of asking the environment
---@field interactive boolean? whether a user is at the terminal, instead of asking the terminal
---@field width integer? columns a line may fill, instead of asking the terminal
---@field height integer? rows the screen has, left nil to draw every row outside the picker
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
    local out = assert(io.open(term.TTY_PATH, "w"))
    local into, open_err = io.open(term.TTY_PATH, "r")
    if not into then
        out:close()
        error(open_err, 0)
    end
    for _, line in ipairs(text.wrap(text.words(consequence), ctx.width)) do
        out:write(line, "\n")
    end
    out:write(M.paint(ctx, question, Style.YELLOW), " [y/", M.paint(ctx, "N", Style.BOLD), "] ")
    out:flush()
    local ok, answer = pcall(function()
        local line = into:read("*l")
        return line
    end)
    if not ok then
        out:write("\n")
    end
    out:close()
    into:close()
    if not ok then
        if tostring(answer):find("interrupted!", 1, true) then
            os.exit(INTERRUPTED)
        end
        error(answer, 0)
    end
    answer = answer and answer:lower():match("^%s*(.-)%s*$")
    return answer == "y" or answer == "yes"
end

---@class dev.ui.SpinnerLineOpts
---@field frame integer which frame of the spinner to draw, counting from 1
---@field label string what is running
---@field detail string extra dim text after the label, or an empty string
---@field seconds integer time elapsed

---Draw one line of the spinner: glyph, label, detail and elapsed time.
---@param ctx dev.ui.Context drawing settings
---@param opts dev.ui.SpinnerLineOpts what the line shows
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

local function read_all(path)
    local file = io.open(path, "r")
    if not file then
        return ""
    end
    local body = file:read("*a")
    file:close()
    return body
end

local function capture_or_interrupted(argv)
    local ok, result, code = pcall(devos.capture, argv)
    if not ok then
        local reason = tostring(result)
        if
            reason:find("interrupted!", 1, true)
            or reason:find("capture lost the exit status", 1, true)
        then
            return "", INTERRUPTED
        end
        error(result, 0)
    end
    return result, code
end

local function start_job(argv, dir, streams)
    local launch = {
        "sh",
        "-c",
        'trap "" INT; set -m; dir=$1; shift; ( trap - INT; "$@" >"$dir/out" '
            .. streams
            .. ' </dev/null; echo $? >"$dir/rc" ) >/dev/null 2>&1 & echo $! >"$dir/pid"; echo $!',
        "sh",
        dir,
    }
    for _, word in ipairs(argv) do
        launch[#launch + 1] = word
    end
    local pid, code = capture_or_interrupted(launch)
    return tonumber(pid), code
end

local STOP_POLLS = 40
local STOP_POLL_SECS = 0.05

local STOP = string.format(
    'kill -s TERM -- "-$1" 2>/dev/null; n=0; '
        .. 'while kill -s 0 -- "-$1" 2>/dev/null && [ $n -lt %d ]; do '
        .. "sleep %g; n=$((n+1)); done; true",
    STOP_POLLS,
    STOP_POLL_SECS
)

local PID_POLLS = 200
local PID_POLL_SECS = 0.05

local function launched_pid(dir, wait)
    local polls = 0
    while true do
        local pid = tonumber(read_all(dir .. "/pid"):match("^%d+"))
        if pid or not wait or polls >= PID_POLLS then
            return pid
        end
        polls = polls + 1
        devos.run({ "sleep", tostring(PID_POLL_SECS) })
    end
end

local function stop_job(pid)
    devos.run({ "sh", "-c", STOP, "sh", tostring(pid) })
end

local function finished_code(rc_path)
    return tonumber(read_all(rc_path):match("^%d+"))
end

local POLL = string.format(
    'sleep %g; [ -s "$1" ] && exit %d; kill -0 "$2" 2>/dev/null || exit %d; exit %d',
    POLL_INTERVAL_SECS,
    POLL_DONE,
    POLL_GONE,
    POLL_RUNNING
)

local function poll(rc_path, pid)
    local _, code = capture_or_interrupted({ "sh", "-c", POLL, "sh", rc_path, tostring(pid) })
    return code
end

---@class dev.ui.Job
---@field err dev.ui.Context settings for drawing on standard error
---@field label string what is running
---@field pid integer process group leader of the command
---@field rc_path string file the command's exit status is written to

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
        local state = poll(job.rc_path, job.pid)
        if state > devos.SIGNAL_EXIT_BASE then
            return INTERRUPTED
        end
        if state == POLL_DONE or state == POLL_GONE then
            return finished_code(job.rc_path) or 1
        end
        if state ~= POLL_RUNNING then
            error("spinner poll failed with status " .. state, 0)
        end
    end
end

local function make_workdir(ctx)
    local base = (ctx.getenv("TMPDIR") or ""):gsub("/+$", "")
    if base == "" then
        base = "/tmp"
    end
    local dir, made = devos.capture({ "mktemp", "-d", base .. "/dev-spin.XXXXXX" })
    dir = dir:gsub("\n$", "")
    if made ~= 0 or dir == "" then
        error("spin could not create a temp directory", 0)
    end
    return dir
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

---@class dev.ui.SpinOpts
---@field capture boolean? keep standard output apart and return it, showing only standard error on failure

---Run `argv` with a spinner on standard error, then show a check or a cross and its output.
---
---Without a terminal on both ends, or when TERM is dumb, the command just runs with the
---terminal's streams. Otherwise its output is held back and shown only when it fails. Ctrl-C
---stops the command and every process it started. With `opts.capture`, standard output is
---returned as a second value and never shown, and standard error is what a failure shows.
---@param ctx dev.ui.Context drawing settings
---@param label string what is running
---@param argv string[] command and its arguments, with at least one word
---@param opts dev.ui.SpinOpts? `capture`
---@return integer code exit status of the command, or 130 when the user interrupted it
---@return string? output standard output of the command, only with `opts.capture`
function M.spin(ctx, label, argv, opts)
    local capture = opts ~= nil and opts.capture == true
    if not (ctx.interactive and devos.isatty(2) and ctx.getenv("TERM") ~= "dumb") then
        if capture then
            local out, code = devos.capture(argv)
            return code, out
        end
        return devos.run(argv)
    end
    local err = ctx:stderr()
    local dir, pid
    stderr:write(HIDE_CURSOR)
    local ok, code = pcall(function()
        dir = make_workdir(ctx)
        local launched
        pid, launched = start_job(argv, dir, capture and '2>"$dir/err"' or "2>&1")
        if launched == INTERRUPTED then
            return INTERRUPTED
        end
        if launched ~= 0 or not pid then
            return 1
        end
        return watch({ err = err, label = label, pid = pid, rc_path = dir .. "/rc" })
    end)
    stderr:write(ERASE_LINE, SHOW_CURSOR)
    local captured, output = "", ""
    if dir then
        captured = read_all(dir .. (capture and "/err" or "/out"))
        output = capture and read_all(dir .. "/out") or ""
        local stopping = not ok or code == INTERRUPTED
        pid = pid or launched_pid(dir, stopping)
        if pid and stopping then
            stop_job(pid)
        end
        devos.run({ "rm", "-rf", "--", dir })
    end
    if not ok then
        if tostring(code):find("interrupted!", 1, true) then
            return INTERRUPTED, ""
        end
        error(code, 0)
    end
    if code == INTERRUPTED then
        return code, ""
    end
    report(err, label, code, captured)
    if capture then
        return code, output
    end
    return code
end

---@class dev.ui.PageOpts
---@field pager string? shell command that reads the text, defaulting to `$PAGER`, else `less -R`
---@field allowed boolean? false to print directly, true by default
---@field interactive boolean? whether standard output is a terminal, instead of asking the terminal
---@field rows integer? rows the screen has, instead of asking the terminal
---@field fallback string? the text to print when the pager fails, instead of `content`

---Decide whether `content` goes through a pager.
---
---It does when paging is allowed, standard output is a terminal and the text
---has more lines than the screen has rows.
---@param content string the text to show
---@param opts dev.ui.PageOpts? `allowed`, `interactive` and `rows`, each read from the terminal when nil
---@return boolean page true when the pager should show the text
function M.should_page(content, opts)
    opts = opts or {}
    if opts.allowed == false then
        return false
    end
    local interactive = opts.interactive
    if interactive == nil then
        interactive = devos.isatty(1)
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
---@param opts dev.ui.PageOpts? the pager command, and the settings `should_page` reads
---@return boolean paged true when the pager showed the text
function M.page(content, opts)
    opts = opts or {}
    if not M.should_page(content, opts) then
        io.write(content)
        return false
    end
    local pager = opts.pager
    if pager == nil or pager == "" then
        pager = os.getenv("PAGER")
    end
    if pager == nil or pager == "" then
        pager = DEFAULT_PAGER
    end
    io.flush()
    local path = fs.mktemp({ prefix = "dev-page" })
    local shown = false
    if path then
        if fs.write(path, content) then
            shown = devos.run({ "sh", "-c", "(" .. pager .. '\n) <"$0"', path }) == 0
        end
        fs.remove(path)
    end
    if shown then
        return true
    end
    stderr:write("dev: the pager failed, so the text follows without it\n")
    io.write(opts.fallback or content)
    return false
end

return M
