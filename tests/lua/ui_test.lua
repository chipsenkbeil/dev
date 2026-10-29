local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local text = require("dev.text")
local ui = require("dev.ui")

local plain = ui.context({ color = false, interactive = true, width = 80 })

local function column_of(lines, word)
    for _, line in ipairs(lines) do
        local at = line:find(word, 1, true)
        if at then
            return text.width(line:sub(1, at - 1))
        end
    end
end

t.test("table lines up columns by display width", function()
    local lines = ui.table(
        plain,
        { "NAME", "STATE" },
        { { "é-box", "running" }, { "ci-abc", "stopped" } }
    )
    t.eq(#lines, 3)
    t.eq(column_of(lines, "running"), column_of(lines, "stopped"))
    t.eq(column_of(lines, "STATE"), column_of(lines, "running"))
end)

t.test("table cuts every line to the width", function()
    local ctx = ui.context({ color = false, interactive = true, width = 10 })
    local lines = ui.table(ctx, { "NAME", "STATE" }, { { "a-very-long-name", "running" } })
    for _, line in ipairs(lines) do
        t.ok(text.width(line) <= 10)
    end
    t.ok(lines[2]:find("…", 1, true) ~= nil)
end)

t.test("table paints styled cells and the header", function()
    local ctx = ui.context({ color = true, interactive = true, width = 80 })
    local lines = ui.table(ctx, { "A" }, { { { text = "x", style = { ui.Style.RED } } } })
    t.eq(lines[1], "\27[2m\27[1mA\27[0m")
    t.eq(lines[2], "\27[31mx\27[0m")
end)

t.test("bar is fill then rest", function()
    t.eq(
        ui.bar(plain, { used = 2, total = 3, width = 21 }),
        string.rep("█", 14) .. string.rep("░", 7)
    )
end)

t.test("bar is empty when not interactive", function()
    local ctx = ui.context({ color = false, interactive = false, width = 80 })
    t.eq(ui.bar(ctx, { used = 2, total = 3, width = 21 }), "")
end)

t.test("paint wraps in SGR when color is on and passes through when off", function()
    local on = ui.context({ color = true, interactive = true, width = 80 })
    t.eq(ui.paint(on, "x", ui.Style.GREEN), "\27[32mx\27[0m")
    t.eq(ui.paint(plain, "x", ui.Style.GREEN), "x")
end)

t.test("mark draws the glyphs", function()
    local on = ui.context({ color = true, interactive = true, width = 80 })
    t.eq(ui.mark(on, ui.Mark.RUNNING), "\27[32m●\27[0m")
    t.eq(ui.mark(on, ui.Mark.STOPPED), "\27[2m○\27[0m")
    t.eq(ui.mark(on, ui.Mark.OK), "\27[32m✓\27[0m")
    t.eq(ui.mark(on, ui.Mark.FAIL), "\27[31m✗\27[0m")
    t.eq(ui.mark(plain, ui.Mark.FAIL), "✗")
end)

local function env_of(vars)
    return function(name)
        return vars[name]
    end
end

local function tty(...)
    local set = {}
    for _, fd in ipairs({ ... }) do
        set[fd] = true
    end
    return function(fd)
        return set[fd] == true
    end
end

local function size()
    return 30, 100
end

t.test("context turns color off for NO_COLOR, but not for an empty one", function()
    local function ctx(vars)
        return ui.context({ getenv = env_of(vars), isatty = tty(0, 1), size = size })
    end
    t.eq(ctx({ NO_COLOR = "1", TERM = "xterm" }).color, false)
    t.eq(ctx({ NO_COLOR = "", TERM = "xterm" }).color, true)
    t.eq(ctx({ TERM = "xterm" }).color, true)
    t.eq(ctx({ TERM = "dumb" }).color, false)
end)

t.test("context takes width from the terminal", function()
    t.eq(ui.context({ getenv = env_of({}), isatty = tty(0, 1), size = size }).width, 100)
end)

t.test("context is not interactive unless stdin and stdout are terminals", function()
    local function ctx(isatty)
        return ui.context({ getenv = env_of({ TERM = "xterm" }), isatty = isatty, size = size })
    end
    t.eq(ctx(tty(0, 1)).interactive, true)
    t.eq(ctx(tty(0)).interactive, false)
    t.eq(ctx(tty(1)).interactive, false)
    t.eq(ctx(tty(0)).color, false)
end)

t.test("explicit options win over the environment", function()
    local ctx = ui.context({
        color = true,
        interactive = false,
        width = 40,
        getenv = env_of({ NO_COLOR = "1" }),
    })
    t.eq(ctx.color, true)
    t.eq(ctx.interactive, false)
    t.eq(ctx.width, 40)
end)

t.test("context decides stderr color from fd 2, not stdout", function()
    local function ctx(isatty)
        return ui.context({ getenv = env_of({ TERM = "xterm" }), isatty = isatty, size = size })
    end
    local out_only = ctx(tty(1))
    t.eq(out_only.color, true)
    t.eq(out_only.stderr_color, false)
    t.eq(ctx(tty(2)).stderr_color, true)
    t.eq(
        ui.context({ getenv = env_of({ TERM = "dumb" }), isatty = tty(2), size = size }).stderr_color,
        false
    )
end)

local function lines_of(count)
    return string.rep("row\n", count)
end

t.test("should_page pages only text taller than the screen on a terminal", function()
    local tall = { interactive = true, rows = 24 }
    t.eq(ui.should_page(lines_of(25), tall), true)
    t.eq(ui.should_page(lines_of(24), tall), false)
    t.eq(ui.should_page(string.rep("row\n", 24) .. "last", tall), true)
    t.eq(ui.should_page("", tall), false)
end)

t.test("should_page prints directly when output is piped or paging is off", function()
    t.eq(ui.should_page(lines_of(100), { interactive = false, rows = 24 }), false)
    t.eq(ui.should_page(lines_of(100), { interactive = true, rows = 24, allowed = false }), false)
end)

local function fake_pager(body)
    local dir = assert(fs.mktemp({ dir = true }))
    assert(fs.write(dir .. "/fakepager", "#!/bin/sh\n" .. body))
    assert(devos.run({ "chmod", "755", dir .. "/fakepager" }) == 0, "chmod failed")
    return dir
end

t.test("page sends a tall text to the pager command on PATH", function()
    local dir = fake_pager('cat >"$1"\n')
    local record = dir .. "/record"
    local content = lines_of(50)
    local paged = ui.page(content, {
        pager = "PATH=" .. devos.quote(dir) .. ':"$PATH"; export PATH; fakepager ' .. devos.quote(
            record
        ),
        interactive = true,
        rows = 24,
    })
    t.eq(paged, true)
    t.eq(fs.read(record), content)
    fs.remove(dir, { recursive = true })
end)

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")

local function page_output(rows, opts)
    local code = string.format(
        'package.path = %q .. package.path; local ui = require("dev.ui"); '
            .. "local paged = ui.page(string.rep('row\\n', %d), "
            .. "{ pager = %q, interactive = true, rows = 24 }); "
            .. "io.write(tostring(paged))",
        REPO .. "/dotfiles/bin/.local/share/dev/lua/?.lua;",
        rows,
        opts.pager
    )
    return devos.capture({ "luajit", "-e", code }, { stderr = "stdout" })
end

t.test("page prints a short text without starting the pager", function()
    local dir = fake_pager('cat >"$1"\n')
    local record = dir .. "/record"
    local out = page_output(3, { pager = dir .. "/fakepager " .. devos.quote(record) })
    t.eq(out, lines_of(3) .. "false")
    t.eq(fs.exists(record), false)
    fs.remove(dir, { recursive = true })
end)

t.test("page survives a pager that quits before it reads the text", function()
    local dir = fake_pager("exit 0\n")
    local paged = ui.page(string.rep("a long line of text\n", 200000), {
        pager = dir .. "/fakepager",
        interactive = true,
        rows = 24,
    })
    t.eq(paged, true)
    fs.remove(dir, { recursive = true })
end)

local WARNING = "dev: the pager failed, so the text follows without it\n"

t.test("page prints the text and a warning when the pager command is missing", function()
    local out = page_output(30, { pager = "no-such-pager-command-xyz" })
    t.ok(out:find(WARNING, 1, true), out)
    t.ok(out:find(lines_of(30) .. "false", 1, true), out)
end)

t.test("page prints the text and a warning when the pager exits non-zero", function()
    local dir = fake_pager("cat >/dev/null\nexit 3\n")
    local out = page_output(30, { pager = dir .. "/fakepager" })
    t.ok(out:find(WARNING, 1, true), out)
    t.ok(out:find(lines_of(30) .. "false", 1, true), out)
    fs.remove(dir, { recursive = true })
end)

t.test("page prints nothing but the pager's own output when the pager succeeds", function()
    local dir = fake_pager("cat\n")
    local out = page_output(30, { pager = dir .. "/fakepager" })
    t.eq(out, lines_of(30) .. "true")
    fs.remove(dir, { recursive = true })
end)
