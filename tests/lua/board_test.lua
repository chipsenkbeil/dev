local ffi = require("ffi")

local t = require("testing")
local board = require("dev.board")
local box = require("dev.cmd.box")
local commands = require("dev.cmd.board")
local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local ui = require("dev.ui")
local support = require("support")

local TOKEN = "pomb_SECRETtoken0123456789"
local OLD_TOKEN = "pomb_OLDtoken9876543210"
local ID_A = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
local ID_B = "11111111-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
local ID_C = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
local ID_D = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
local LEAD = "dotfiles/lead/1"
local V1 = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone\n\n## Done when\n- [ ] done"
local SCAFFOLD = "## Problem\nx\n\n## Change\n\n## Out of scope\n"
local V2 = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone"
local LEAD_USER = '[board.pomb]\nurl = "https://pomb.example"\ntoken = "pass:secrets/worker/token/pomb"\n'
    .. 'lead_token = "pass:secrets/lead/token/pomb"\n'

local function executable(path, body)
    assert(fs.write(path, body))
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function fake(cards, times, finished)
    finished = finished or { "Done" }
    local is_finished = {}
    for _, name in ipairs(finished) do
        is_finished[name] = true
    end
    for _, card in ipairs(cards) do
        card.outcomes = card.outcomes or {}
        card.done = is_finished[card.column] == true
    end
    local calls = {}
    local backend = { calls = calls }
    function backend:done_columns()
        return finished
    end
    function backend:columns()
        local rows = {}
        for _, name in ipairs(finished) do
            rows[#rows + 1] = { name = name, is_done = true }
        end
        for _, name in ipairs(backend.limited or {}) do
            rows[#rows + 1] = { name = name, is_done = false, wip_limit = 2 }
        end
        return rows
    end
    function backend:entered()
        return times or {}
    end
    function backend:find()
        return true
    end
    function backend:describe()
        return "fake"
    end
    function backend:cards()
        return cards
    end
    function backend:next(column, opts)
        local label = opts and opts.label
        calls[#calls + 1] = { "next", column, label }
        if not label then
            return cards[1]
        end
        for _, card in ipairs(cards) do
            local labels = table.concat(card.labels or {}, ",")
            if
                card.column == column
                and not card.claimant
                and labels:find(label, 1, true)
                and not labels:find("needs:human", 1, true)
            then
                return card
            end
        end
    end
    function backend:has_field()
        return not backend.nofield
    end
    function backend:add(name, column, opts)
        backend.opts = opts
        calls[#calls + 1] = { "add", name, column, opts.description, opts.color, opts.labels }
        return {
            id = ID_C,
            name = name,
            column = column,
            size = "unsized",
            labels = {},
            checks = {},
            outcomes = {},
        }
    end
    function backend:note(id, text, _, opts)
        calls[#calls + 1] = { "note", id, text, opts }
        return true
    end
    function backend:ask(id, question, fence)
        calls[#calls + 1] = { "ask", id, question, fence }
        return backend.refusal == nil, backend.refusal
    end
    function backend:escalate(id, tier, reason, fence)
        calls[#calls + 1] = { "escalate", id, tier, reason, fence }
        return backend.refusal == nil, backend.refusal
    end
    function backend:answer(id, choice, quote, fence)
        calls[#calls + 1] = { "answer", id, choice, quote, fence }
        return backend.refusal == nil, backend.refusal
    end
    function backend:comments(id)
        calls[#calls + 1] = { "comments", id }
        if backend.listed_error then
            return nil, backend.listed_error
        end
        return backend.listed or {}
    end
    function backend:edit_note(id, comment, text)
        calls[#calls + 1] = { "edit_note", id, comment, text }
        return true
    end
    function backend:delete_note(id, comment)
        calls[#calls + 1] = { "delete_note", id, comment }
        return true
    end
    function backend:set_labels(id, labels, fence)
        calls[#calls + 1] = { "set_labels", id, labels, fence }
        return true
    end
    function backend:add_outcome(id, text, fence)
        calls[#calls + 1] = { "add_outcome", id, text, fence }
        return true
    end
    function backend:delete_outcome(id, outcome, fence)
        calls[#calls + 1] = { "delete_outcome", id, outcome, fence }
        return true
    end
    function backend:set_outcome(id, outcome, fields, fence)
        calls[#calls + 1] = { "set_outcome", id, outcome, fields, fence }
        return true
    end
    function backend:set_description(id, text, fence)
        calls[#calls + 1] = { "set_description", id, text, fence }
        return true
    end
    function backend:set_name(id, name, fence)
        calls[#calls + 1] = { "set_name", id, name, fence }
        return true
    end
    function backend:set_checks(id, runs, fence)
        calls[#calls + 1] = { "set_checks", id, runs, fence }
        return true
    end
    function backend:set_field(id, key, value, fence)
        calls[#calls + 1] = { "set_field", id, key, value, fence }
        return true
    end
    function backend:set_size(id, color, fence)
        calls[#calls + 1] = { "set_size", id, color, fence }
        return true
    end
    function backend:link(id, kind, other)
        calls[#calls + 1] = { "link", id, kind, other }
        return true
    end
    function backend:links(id)
        calls[#calls + 1] = { "links", id }
        return backend.held or {}
    end
    function backend:unlink(id, kind, other)
        calls[#calls + 1] = { "unlink", id, kind, other }
        return true
    end
    function backend:bin(id)
        calls[#calls + 1] = { "bin", id }
        return true
    end
    function backend:family(id)
        calls[#calls + 1] = { "family", id }
        return backend.kin or {}
    end
    function backend:other_board(name)
        calls[#calls + 1] = { "other_board", name }
        if name == "ci" then
            return backend.sibling
        end
        return nil, "pomb has no board named " .. name
    end
    function backend:move(id, column, opts)
        local position = opts and opts.position
        calls[#calls + 1] = { "move", id, column, position }
        if position then
            local moved
            for at, card in ipairs(cards) do
                if card.id == id then
                    moved = table.remove(cards, at)
                    break
                end
            end
            local seen, at = 0, #cards + 1
            for i, other in ipairs(cards) do
                if other.column == column then
                    if seen == position then
                        at = i
                        break
                    end
                    seen = seen + 1
                end
            end
            table.insert(cards, at, moved)
        end
        return true
    end
    return backend
end

local function sample()
    return {
        {
            id = ID_A,
            name = "Write docs",
            column = "Ready",
            size = "1 Pomodoro",
            color = "yellow",
            description = V2,
            labels = { "docs" },
            checks = {},
            outcomes = {},
        },
        {
            id = ID_B,
            name = "Fix lint",
            column = "Backlog",
            size = "unsized",
            labels = {},
            checks = {},
            outcomes = {},
        },
        {
            id = ID_C,
            name = "Old thing",
            column = "Done",
            size = "unsized",
            labels = {},
            checks = {},
            outcomes = {},
        },
    }
end

local function planned()
    return {
        id = ID_C,
        name = "Card",
        column = "Backlog",
        size = "2 Pomodori",
        color = "green",
        description = V2,
        labels = {},
        checks = { "dev test" },
        outcomes = {},
    }
end

t.test("column takes the names and the short forms in any case", function()
    local roles = board.roles()
    t.eq(roles:column("ready"), "Ready")
    t.eq(roles:column("PROGRESS"), "In Progress")
    t.eq(roles:column("review"), "Review")
    for _, short in ipairs({ "blocked", "done", "backlog", "icebox" }) do
        t.eq(roles:column(short):lower(), short)
    end
    t.eq(roles:column("doing"), nil)
end)

t.test("roles take the mapped names, the role words and the finished columns", function()
    local roles = board.roles(
        { ready = "Next", progress = "Doing", done = "Shipped" },
        { "Old", "Shipped" }
    )
    t.eq(roles:column("ready"), "Next")
    t.eq(roles:column("PROGRESS"), "Doing")
    t.eq(roles:column("in progress"), nil)
    t.eq(roles:column("done"), "Shipped")
    t.eq(roles:column("old"), "Old")
    t.eq(roles.list, {
        "Icebox",
        "Backlog",
        "Next",
        "Doing",
        "Review",
        "Verify",
        "Release",
        "Blocked",
        "Shipped",
    })
    t.eq(board.roles(nil, { "Old", "Shipped" }):done_column(), "Old")
    t.eq(board.roles():done_column(), "Done")
end)

t.test("a renamed board runs through the column map", function()
    local backend = fake({
        { id = ID_A, name = "A", column = "Next", size = "1 Pomodoro", labels = {}, checks = {} },
        { id = ID_B, name = "B", column = "Inbox", size = "unsized", labels = {}, checks = {} },
    }, nil, { "Shipped" })
    backend.column_map = { backlog = "Inbox", ready = "Next", done = "Shipped" }
    t.eq(
        commands.run("ls", { "--column", "ready" }, backend).output,
        "11111111  Next  1 Pomodoro  -  A"
    )
    t.eq(
        commands.run("ls", { "--column", "backlog" }, backend).output,
        "11111111  Inbox  unsized  -  B"
    )
    t.eq(commands.run("ls", { "--column", "doing" }, backend).code, 2)
    t.eq(
        commands.run("add", { "C", "--problem", "x", "--size", "1", "--done-when", "a" }, backend).output,
        "added cccccccc Inbox"
    )
end)

t.test("ls hides every finished column and discard picks the mapped one, else the first", function()
    local cards = sample()
    cards[2].column = "Archive"
    local backend = fake(cards, nil, { "Done", "Archive" })
    t.eq(commands.run("ls", {}, backend).output, "11111111  Ready  1 Pomodoro  docs  Write docs")
    t.eq(commands.run("ls", { "--column", "archive" }, backend).message, nil)
    commands.run("discard", { "11111111-a" }, backend)
    t.eq(backend.calls[#backend.calls], { "move", ID_A, "Done" })
    backend = fake(sample(), nil, { "Archive", "Done" })
    backend.column_map = { done = "Done" }
    commands.run("discard", { "11111111-a" }, backend)
    t.eq(backend.calls[#backend.calls], { "move", ID_A, "Done" })
    backend = fake(sample(), nil, { "Archive", "Done" })
    commands.run("discard", { "11111111-a" }, backend)
    t.eq(backend.calls[#backend.calls], { "move", ID_A, "Archive" })
end)

t.test("resolve takes a unique prefix of at least 8 characters", function()
    local cards = sample()
    t.eq(board.resolve(cards, "11111111-a").id, ID_A)
    t.eq(board.resolve(cards, ID_B).id, ID_B)
    t.eq(board.resolve(cards, "CCCCCCCC").id, ID_C)
end)

t.test("resolve refuses a short, unknown or ambiguous prefix", function()
    local cards = sample()
    local card, message = board.resolve(cards, "1111111")
    t.eq(card, nil)
    t.ok(message:find("at least 8", 1, true), message)
    card, message = board.resolve(cards, "11111111")
    t.eq(card, nil)
    t.ok(message:find("more than one card", 1, true), message)
    card, message = board.resolve(cards, "deadbeef")
    t.eq(card, nil)
    t.ok(message:find("no card starts with deadbeef", 1, true), message)
    card, message = board.resolve(cards, "zzzzzzzz")
    t.eq(card, nil)
    t.ok(message:find("hex", 1, true), message)
end)

t.test("ls hides Done and aligns the columns", function()
    local result = commands.run("ls", {}, fake(sample()))
    t.eq(
        result.output,
        "11111111  Ready    1 Pomodoro  docs  Write docs\n11111111  Backlog  unsized     -     Fix lint"
    )
end)

t.test("ls filters by column and label", function()
    local result = commands.run("ls", { "--column", "done" }, fake(sample()))
    t.eq(result.output, "cccccccc  Done  unsized  -  Old thing")
    result = commands.run("ls", { "--label", "docs" }, fake(sample()))
    t.eq(result.output, "11111111  Ready  1 Pomodoro  docs  Write docs")
    result = commands.run("ls", { "--label", "none" }, fake(sample()))
    t.eq(result.output, "no cards")
end)

local function coloured(cards, args)
    local screen = ui.context({ color = true, interactive = true, width = 100 })
    return commands.run("ls", args or {}, fake(cards), nil, screen)
end

local function strip(output)
    return (output:gsub("\27%[[%d;]*m", ""))
end

local function split(output)
    local lines, at = {}, 1
    while at <= #output + 1 do
        local stop = output:find("\n", at, true) or #output + 1
        lines[#lines + 1] = output:sub(at, stop - 1)
        at = stop + 1
    end
    return lines
end

local function progress_sample()
    local cards = sample()
    cards[1].color = "yellow"
    cards[1].outcomes = { { done = true }, { done = false }, { done = true }, { done = false } }
    cards[2].column = "Blocked"
    cards[2].claimant = nil
    return cards
end

t.test("ls on a colour terminal draws the summary, legend, dots and meter", function()
    local result = coloured(progress_sample())
    t.ok(result.page, "output goes through the pager")
    local lines = split(strip(result.output))
    t.eq(lines[1], "2 cards · 1 ready · 1 blocked")
    t.eq(lines[2], "size  ● 1  ●● 2  ●●● 3  ●●●● >3  ○○○ unsized")
    t.eq(lines[3], "")
    t.ok(lines[4]:find("^ID +COLUMN +SIZE +LABELS +DONE +NAME$"), lines[4])
    t.ok(lines[5]:find("^11111111  Ready +● +docs +▰▰▱▱ 2/4 +Write docs$"), lines[5])
    t.ok(lines[6]:find("^11111111  Blocked +○○○ +%- +%- +Fix lint$"), lines[6])
    t.ok(result.output:find("\27[33m", 1, true), "yellow is painted")
end)

t.test("ls on a colour terminal paints no empty colour code in the meter", function()
    local empty_code = "\27%[[%d;]*m\27%[0m"
    local cards = progress_sample()
    cards[1].outcomes = { { done = false }, { done = false } }
    cards[2].outcomes = { { done = true }, { done = true } }
    local result = coloured(cards)
    t.eq(result.output:find(empty_code), nil, result.output)
    t.ok(strip(result.output):find("▱▱▱▱ 0/2", 1, true), result.output)
    t.ok(strip(result.output):find("▰▰▰▰ 2/2", 1, true), result.output)
    t.ok(result.output:find("\27[32m▰▰▰▰\27[0m", 1, true), result.output)
end)

t.test("ls shows the held by column only when a listed card is claimed", function()
    local cards = progress_sample()
    cards[1].claimant = "dev@host:1"
    local result = coloured(cards)
    t.ok(strip(result.output):find("HELD BY", 1, true), result.output)
    t.ok(strip(result.output):find("dev@host:1", 1, true), result.output)
end)

t.test("ls --group lists the cards under a heading and count per column", function()
    local result = coloured(progress_sample(), { "--group" })
    local lines = split(strip(result.output))
    t.eq(lines[3], "")
    t.eq(lines[4], "Ready  1 card")
    t.ok(lines[5]:find("^  11111111 +● +docs +▰▰▱▱ 2/4 +Write docs$"), lines[5])
    t.eq(lines[6], "")
    t.eq(lines[7], "Blocked  1 card")
    t.eq(lines[#lines], "Done is left out unless --column done")
    local filtered = strip(coloured(progress_sample(), { "--group", "--column", "blocked" }).output)
    t.ok(filtered:find("Done is left out unless --column done", 1, true), filtered)
    t.eq(
        coloured(sample(), { "--group", "--column", "done" }).output:find("left out", 1, true),
        nil
    )
end)

t.test("ls filters by column, label and size in both layouts", function()
    for _, group in ipairs({ {}, { "--group" } }) do
        local function run(...)
            local args = { ... }
            for _, word in ipairs(group) do
                args[#args + 1] = word
            end
            return strip(coloured(progress_sample(), args).output)
        end
        t.ok(run("--column", "blocked"):find("Fix lint", 1, true))
        t.eq(run("--column", "blocked"):find("Write docs", 1, true), nil)
        t.ok(run("--label", "docs"):find("Write docs", 1, true))
        t.eq(run("--label", "docs"):find("Fix lint", 1, true), nil)
        t.ok(run("--size", "1"):find("Write docs", 1, true))
        t.eq(run("--size", "1"):find("Fix lint", 1, true), nil)
        t.eq(coloured(progress_sample(), { "--label", "none" }).output, "no cards")
    end
end)

t.test("ls without colour is the plain lines, --group included", function()
    local plain = ui.context({ color = false, interactive = false, width = 100 })
    local expected =
        "11111111  Ready    1 Pomodoro  docs  Write docs\n11111111  Backlog  unsized     -     Fix lint"
    for _, args in ipairs({ {}, { "--group" } }) do
        local result = commands.run("ls", args, fake(sample()), nil, plain)
        t.eq(result.output, expected)
        t.eq(result.page, nil)
    end
end)

t.test("ls refuses an unknown column and an unknown flag with a usage error", function()
    local result = commands.run("ls", { "--column", "doing" }, fake(sample()))
    t.eq(result.code, 2)
    t.ok(result.message:find("unknown column doing", 1, true), result.message)
    result = commands.run("ls", { "--bogus" }, fake(sample()))
    t.eq(result.code, 2)
    result = commands.run("ls", { "--column" }, fake(sample()))
    t.eq(result.code, 2)
end)

t.test("add defaults to Backlog and joins the words of the name", function()
    local backend = fake(sample())
    local result = commands.run(
        "add",
        { "A", "new", "card", "--problem", "x", "--size", "1", "--done-when", "a" },
        backend
    )
    t.eq(result.output, "added cccccccc Backlog")
    t.eq(backend.calls[1], { "add", "A new card", "Backlog", SCAFFOLD, "yellow" })
    result = commands.run(
        "add",
        { "X", "--column", "ready", "--description", V1, "--size", "2", "--checks", "dev test" },
        backend
    )
    t.eq(backend.calls[2], { "add", "X", "Ready", V1, "green" })
    t.eq(commands.run("add", {}, backend).code, 2)
end)

t.test("add --board files on the named board and leaves this one alone", function()
    local backend = fake(sample())
    local sibling = fake(sample())
    backend.sibling = sibling
    local result = commands.run(
        "add",
        { "Far", "--board", "ci", "--problem", "x", "--size", "1", "--done-when", "a" },
        backend
    )
    t.eq(result.output, "added cccccccc Backlog")
    t.eq(backend.calls[1], { "other_board", "ci" })
    t.eq(#backend.calls, 1)
    t.eq(sibling.calls[1], { "add", "Far", "Backlog", SCAFFOLD, "yellow" })
end)

t.test("add --board refuses a board that is not there", function()
    local backend = fake(sample())
    local result = commands.run("add", { "Far", "--board", "nope", "--size", "1" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("no board named nope", 1, true), result.message)
    local sibling = fake(sample())
    function sibling:find()
        return false
    end
    backend.sibling = sibling
    result = commands.run("add", { "Far", "--board", "ci", "--size", "1" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("no board named ci", 1, true), result.message)
    t.eq(#sibling.calls, 0)
end)

t.test("add --blocked-by links the new card to each blocker", function()
    local backend = fake(sample())
    local result = commands.run("add", {
        "X",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "a",
        "--blocked-by",
        "11111111-a",
        "--blocked-by",
        "11111111-b",
    }, backend)
    t.eq(result.output, "added cccccccc Backlog")
    t.eq(backend.calls[2], { "link", ID_C, "blocked_by", ID_A })
    t.eq(backend.calls[3], { "link", ID_C, "blocked_by", ID_B })
    t.eq(#backend.calls, 3)
end)

t.test("add --from links the new card as related to the card it came from", function()
    local backend = fake(sample())
    local result = commands.run("add", {
        "X",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "a",
        "--from",
        "11111111-a",
    }, backend)
    t.eq(result.output, "added cccccccc Backlog")
    t.eq(backend.calls[2], { "link", ID_C, "related", ID_A })
    t.eq(#backend.calls, 2)
end)

t.test("add --from refuses an unknown card before it adds", function()
    local backend = fake(sample())
    local result = commands.run(
        "add",
        { "X", "--problem", "x", "--size", "1", "--done-when", "a", "--from", "deadbeef" },
        backend
    )
    t.eq(result.code, 1)
    t.eq(#backend.calls, 0)
end)

t.test("add --blocked-by refuses an unknown blocker before it adds", function()
    local backend = fake(sample())
    local result = commands.run(
        "add",
        { "X", "--problem", "x", "--size", "1", "--done-when", "a", "--blocked-by", "deadbeef" },
        backend
    )
    t.eq(result.code, 1)
    t.eq(#backend.calls, 0)
end)

t.test("add --board with --blocked-by looks the blocker up on the named board", function()
    local backend = fake(sample())
    local sibling = fake(sample())
    backend.sibling = sibling
    commands.run("add", {
        "X",
        "--board",
        "ci",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "a",
        "--blocked-by",
        "11111111-a",
    }, backend)
    t.eq(sibling.calls[2], { "link", ID_C, "blocked_by", ID_A })
    t.eq(#backend.calls, 1)
end)

t.test("add names the card when its blocked-by link fails", function()
    local backend = fake(sample())
    function backend:link()
        return nil, "pomb refused"
    end
    local result = commands.run(
        "add",
        { "X", "--problem", "x", "--size", "1", "--done-when", "a", "--blocked-by", "11111111-a" },
        backend
    )
    t.eq(result.code, 1)
    t.ok(
        result.message:find("cccccccc was added to Backlog but its blocked_by link", 1, true),
        result.message
    )
    t.ok(result.unqueued)
end)

t.test("add names the card when its from link fails", function()
    local backend = fake(sample())
    function backend:link()
        return nil, "pomb refused"
    end
    local result = commands.run(
        "add",
        { "X", "--problem", "x", "--size", "1", "--done-when", "a", "--from", "11111111-a" },
        backend
    )
    t.eq(result.code, 1)
    t.ok(
        result.message:find("cccccccc was added to Backlog but its related link", 1, true),
        result.message
    )
    t.ok(result.unqueued)
end)

t.test("add --board with --from looks the card up on the named board", function()
    local backend = fake(sample())
    local sibling = fake(sample())
    backend.sibling = sibling
    commands.run("add", {
        "X",
        "--board",
        "ci",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "a",
        "--from",
        "11111111-a",
    }, backend)
    t.eq(sibling.calls[2], { "link", ID_C, "related", ID_A })
    t.eq(#backend.calls, 1)
end)

t.test("add --blocked-by drops a repeated blocker and reaches BOARD:CARD", function()
    local backend = fake(sample())
    local far = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    backend.sibling = {
        cards = function()
            return { { id = far, name = "Far", column = "Ready", labels = {}, checks = {} } }
        end,
    }
    commands.run("add", {
        "X",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "a",
        "--blocked-by",
        "11111111-a",
        "--blocked-by",
        "11111111-a",
        "--blocked-by",
        "ci:dddddddd",
    }, backend)
    t.eq(backend.calls[1], { "other_board", "ci" })
    t.eq(backend.calls[2], { "add", "X", "Backlog", SCAFFOLD, "yellow" })
    t.eq(backend.calls[3], { "link", ID_C, "blocked_by", ID_A })
    t.eq(backend.calls[4], { "link", ID_C, "blocked_by", far })
    t.eq(#backend.calls, 4)
end)

t.test("add --size passes the colour its size word names", function()
    local backend = fake(sample())
    for word, color in pairs({ ["1"] = "yellow", ["2"] = "green", ["3"] = "blue", ["3+"] = "red" }) do
        commands.run("add", { "X", "--problem", "x", "--size", word, "--done-when", "a" }, backend)
        t.eq(backend.calls[#backend.calls], { "add", "X", "Backlog", SCAFFOLD, color })
    end
    local calls = #backend.calls
    local refused = commands.run(
        "add",
        { "X", "--problem", "x", "--size", "UNSIZED", "--done-when", "a" },
        backend
    )
    t.eq(refused.code, 2)
    t.ok(refused.message:find("a size", 1, true), refused.message)
    t.eq(#backend.calls, calls)
    commands.run(
        "add",
        { "X", "--column", "icebox", "--size", "UNSIZED", "--description", "loose" },
        backend
    )
    t.eq(backend.calls[#backend.calls], { "add", "X", "Icebox", "loose", "white" })
    local result = commands.run("add", { "X", "--size", "4" }, backend)
    t.eq(result.code, 2)
    t.ok(result.message:find("unknown size 4", 1, true), result.message)
    t.eq(commands.run("add", { "X", "--size" }, backend).code, 2)
end)

t.test("size sets the colour of each size word and resolves the card by prefix", function()
    local backend = fake(sample())
    local want = { ["1"] = "yellow", ["2"] = "green", ["3"] = "blue", ["3+"] = "red" }
    for word, color in pairs(want) do
        local result = commands.run("size", { "cccccccc", word }, backend)
        t.eq(result.output, "sized cccccccc " .. word)
        t.eq(backend.calls[#backend.calls], { "set_size", ID_C, color, nil })
    end
end)

t.test("size unsized is refused outside Icebox and works inside it", function()
    local backend = fake(sample())
    local result = commands.run("size", { "cccccccc", "unsized" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("keeps a size", 1, true), result.message)
    t.eq(#backend.calls, 0)
    local cards = sample()
    cards[3].column = "Icebox"
    backend = fake(cards)
    result = commands.run("size", { "cccccccc", "unsized" }, backend)
    t.eq(result.output, "sized cccccccc unsized")
    t.eq(backend.calls[#backend.calls], { "set_size", ID_C, "white", nil })
end)

t.test("size refuses a bad size, a missing argument and an unknown card", function()
    local backend = fake(sample())
    local result = commands.run("size", { "cccccccc", "4" }, backend)
    t.eq(result.code, 2)
    t.ok(result.message:find("the sizes are 1, 2, 3, 3+, unsized", 1, true), result.message)
    t.eq(commands.run("size", { "cccccccc" }, backend).code, 2)
    t.eq(commands.run("size", { "cccccccc", "2", "3" }, backend).code, 2)
    result = commands.run("size", { "deadbeef", "2" }, backend)
    t.eq(result.code, 1)
    t.eq(#backend.calls, 0)
end)

t.test("ls --size keeps the cards of one colour and counts no colour as unsized", function()
    local cards = sample()
    cards[1].color = "yellow"
    cards[2].color = "white"
    cards[3].color = "blue"
    local result = commands.run("ls", { "--size", "1" }, fake(cards))
    t.eq(result.output, "11111111  Ready  1 Pomodoro  docs  Write docs")
    result = commands.run("ls", { "--size", "unsized" }, fake(cards))
    t.eq(result.output, "11111111  Backlog  unsized  -  Fix lint")
    cards[2].color = nil
    result = commands.run("ls", { "--size", "unsized" }, fake(cards))
    t.eq(result.output, "11111111  Backlog  unsized  -  Fix lint")
    result = commands.run("ls", { "--size", "3", "--column", "done" }, fake(cards))
    t.eq(result.output, "cccccccc  Done  unsized  -  Old thing")
    result = commands.run("ls", { "--size", "2" }, fake(cards))
    t.eq(result.output, "no cards")
    t.eq(commands.run("ls", { "--size", "9" }, fake(cards)).code, 2)
end)

t.test("add --label may repeat and drops a duplicate", function()
    local backend = fake(sample())
    commands.run("add", {
        "X",
        "--problem",
        "x",
        "--size",
        "2",
        "--done-when",
        "a",
        "--label",
        "a",
        "--label",
        "needs:lead",
        "--label",
        "a",
    }, backend)
    t.eq(backend.calls[1], { "add", "X", "Backlog", SCAFFOLD, "green", { "a", "needs:lead" } })
    commands.run("add", { "X", "--problem", "x", "--size", "2", "--done-when", "a" }, backend)
    t.eq(backend.calls[2], { "add", "X", "Backlog", SCAFFOLD, "green", nil })
end)

t.test("label adds and removes labels and sends the whole list", function()
    local backend = fake(sample())
    local result = commands.run("label", { "11111111-a", "+needs:lead", "+x" }, backend)
    t.eq(result.output, "labelled 11111111 docs,needs:lead,x")
    t.eq(backend.calls[1], { "set_labels", ID_A, { "docs", "needs:lead", "x" }, nil })
    result = commands.run("label", { "11111111-a", "--remove", "docs" }, backend)
    t.eq(result.output, "labelled 11111111 -")
    t.eq(backend.calls[2], { "set_labels", ID_A, {}, nil })
    result = commands.run("label", { "11111111-a", "new", "--remove", "new", "+docs" }, backend)
    t.eq(result.output, "labelled 11111111 docs")
    t.eq(#backend.calls, 2)
    result = commands.run(
        "label",
        { "11111111-a", "x", "--remove", "docs", "--remove", "x", "y" },
        backend
    )
    t.eq(result.output, "labelled 11111111 y")
    t.eq(backend.calls[3], { "set_labels", ID_A, { "y" }, nil })
end)

t.test("label still replays a queued leading-dash removal", function()
    local backend = fake(sample())
    local result =
        commands.run("label", { "11111111-a", "-docs", "+new", "-new", "+docs" }, backend)
    t.eq(result.output, "labelled 11111111 docs")
    result = commands.run("label", { "11111111-a", "-docs" }, backend)
    t.eq(result.output, "labelled 11111111 -")
    t.eq(backend.calls[1], { "set_labels", ID_A, {}, nil })
end)

t.test("adding a label the card has or removing one it lacks sends nothing", function()
    local backend = fake(sample())
    t.eq(commands.run("label", { "11111111-a", "+docs" }, backend).output, "labelled 11111111 docs")
    t.eq(
        commands.run("label", { "11111111-a", "--remove", "nope" }, backend).output,
        "labelled 11111111 docs"
    )
    t.eq(#backend.calls, 0)
end)

t.test("label refuses a bad label, a bad --remove value and a missing card", function()
    local backend = fake(sample())
    for _, word in ipairs({ "+two words", "+--x", "+", "-", "+a\tb", "two words" }) do
        t.eq(commands.run("label", { "11111111-a", word }, backend).code, 2)
    end
    t.eq(commands.run("label", { "11111111-a", "--remove" }, backend).code, 2)
    t.eq(commands.run("label", { "11111111-a", "--remove", "a b" }, backend).code, 2)
    t.eq(commands.run("label", { "11111111-a", "--remove", "-a" }, backend).code, 2)
    t.eq(commands.run("label", { "11111111-a" }, backend).code, 2)
    t.eq(commands.run("add", { "X", "--label", "a b" }, backend).code, 2)
    t.eq(commands.run("add", { "X", "--label", "-a" }, backend).code, 2)
    t.eq(commands.run("label", { "deadbeef", "+x" }, backend).code, 1)
    t.eq(#backend.calls, 0)
end)

t.test("edit sends the whole new description and prints one line", function()
    local backend = fake(sample())
    local text = "## Problem\nnew plan\n\n## Change\n- x\n\n## Out of scope\nnone"
    local result = commands.run("edit", { "11111111-a", text }, backend)
    t.eq(result.output, "edited 11111111")
    t.eq(backend.calls[1], { "set_description", ID_A, text, nil })
end)

t.test("edit outside Icebox refuses a text that drops a v2 section", function()
    local backend = fake(sample())
    local result = commands.run("edit", { "11111111-a", "## Problem\nnew plan" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("## Change, ## Out of scope", 1, true), result.message)
    t.eq(#backend.calls, 0)
    local cards = sample()
    cards[1].column = "Icebox"
    backend = fake(cards)
    t.eq(commands.run("edit", { "11111111-a", "loose" }, backend).code, nil)
    t.eq(#backend.calls, 1)
end)

t.test("rename sends the new title and prints renamed", function()
    local backend = fake(sample())
    local result = commands.run("rename", { "11111111-a", "Better", "title" }, backend)
    t.eq(result.output, "renamed 11111111")
    t.eq(backend.calls[1], { "set_name", ID_A, "Better title", nil })
    t.eq(commands.run("rename", { "11111111-a" }, backend).code, 2)
    t.eq(commands.run("rename", { "11111111-a", "  " }, backend).code, 2)
    t.eq(commands.run("rename", { "11111111-a", "x", "--force" }, backend).code, 2)
    t.eq(commands.run("rename", { "11111111-a", 'say "hi"' }, backend).code, 2)
    t.eq(commands.run("rename", { "deadbeef", "x" }, backend).code, 1)
    t.eq(#backend.calls, 1)
end)

t.test("discard posts the reason, labels the card and moves it to Done", function()
    local backend = fake(sample())
    local result = commands.run("discard", { "11111111-a", "--reason", "Not needed" }, backend)
    t.eq(result.output, "discarded 11111111")
    t.eq(backend.calls[1], { "note", ID_A, "Not needed", { kind = "decision" } })
    t.eq(backend.calls[2][1], "set_labels")
    t.ok(table.concat(backend.calls[2][3], ","):find("discarded", 1, true) ~= nil)
    t.eq(backend.calls[3], { "move", ID_A, "Done" })
    t.eq(#backend.calls, 3)
end)

t.test("discard without a reason only labels and moves, and refuses a blank one", function()
    local backend = fake(sample())
    local result = commands.run("discard", { "11111111-a" }, backend)
    t.eq(result.output, "discarded 11111111")
    t.eq(#backend.calls, 2)
    t.eq(backend.calls[2], { "move", ID_A, "Done" })
    t.eq(commands.run("discard", { "11111111-a", "--reason", " " }, backend).code, 2)
    t.eq(commands.run("discard", {}, backend).code, 2)
    t.eq(commands.run("discard", { "deadbeef" }, backend).code, 1)
    t.eq(#backend.calls, 2)
end)

t.test("discard refuses a needs:human card before anything is written", function()
    local cards = sample()
    cards[1].labels = { "needs:human" }
    local backend = fake(cards)
    local result = commands.run("discard", { "11111111-a", "--reason", "Dropped" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("needs:human", 1, true), result.message)
    t.eq(#backend.calls, 0)
end)

t.test("move to Done refuses a card with unticked outcomes and names them", function()
    local cards = sample()
    cards[1].outcomes = {
        { id = "s1", name = "A works", done = true },
        { id = "s2", name = "B works", done = false },
        { id = "s3", name = "C works", done = false },
    }
    local backend = fake(cards)
    local result = commands.run("move", { "11111111-a", "done" }, backend)
    t.eq(result.code, 1)
    t.eq(result.unqueued, true)
    t.eq(
        result.message,
        "11111111 cannot move to Done: 2 of 3 outcomes are unticked (2. B works, 3. C works); the reviewer ticks them with dev board outcome CARD --tick N --as NAME, or dev board discard CARD drops it"
    )
    t.eq(#backend.calls, 0)
end)

t.test("move to Done takes a planned card whose outcomes are all ticked", function()
    local cards = sample()
    cards[1].outcomes = { { id = "s1", name = "A works", done = true } }
    local backend = fake(cards)
    t.eq(commands.run("move", { "11111111-a", "done" }, backend).output, "moved 11111111 to Done")
    t.eq(backend.calls[#backend.calls], { "move", ID_A, "Done" })
end)

t.test("move refuses an unsized card into every column but Icebox", function()
    for _, column in ipairs({ "backlog", "ready", "progress", "review", "blocked", "done" }) do
        local backend = fake(sample())
        local result = commands.run("move", { "cccccccc", column }, backend)
        t.eq(result.code, 1, column)
        t.ok(result.message:find("size", 1, true), result.message)
        t.eq(#backend.calls, 0, column)
    end
    local backend = fake(sample())
    t.eq(commands.run("move", { "cccccccc", "icebox" }, backend).code, nil)
    t.eq(backend.calls, { { "move", ID_C, "Icebox" } })
end)

t.test("move refuses a sized card that lacks a section or outcomes outside Icebox", function()
    for _, column in ipairs({ "backlog", "progress", "review", "blocked", "done" }) do
        local card = planned()
        card.description = "loose idea"
        local backend = fake({ card })
        local result = commands.run("move", { "cccccccc", column }, backend)
        t.eq(result.code, 1, column)
        t.ok(result.message:find("## Change", 1, true), result.message)
        t.eq(#backend.calls, 0, column)
        card = planned()
        card.description = V2
        backend = fake({ card })
        result = commands.run("move", { "cccccccc", column }, backend)
        t.eq(result.code, 1, column)
        t.ok(result.message:find("Done when outcomes", 1, true), result.message)
        t.eq(#backend.calls, 0, column)
    end
end)

t.test("an epic moves to Done once every child is Done and its outcome is ticked", function()
    local card = planned()
    card.epic = { done = 3, total = 3 }
    card.outcomes = { { id = "s1", name = "a", done = true } }
    local backend = fake({ card })
    backend.kin = { children = card.epic }
    local result = commands.run("move", { "cccccccc", "done" }, backend)
    t.eq(result.output, "moved cccccccc to Done")
    t.eq(backend.calls[#backend.calls], { "move", ID_C, "Done" })
end)

t.test("epic_move_refused", function()
    local card = planned()
    card.column = "Ready"
    card.epic = { done = 1, total = 3 }
    card.outcomes = { { id = "s1", name = "a", done = true } }
    local backend = fake({ card })
    backend.kin = { children = card.epic }
    backend.limited = { "Review" }
    local result = commands.run("move", { "cccccccc", "done" }, backend)
    t.eq(result.code, 1)
    t.eq(result.unqueued, true)
    t.eq(
        result.message,
        "cccccccc is an epic and cannot enter Done, a done column: 2 of 3 children are open"
    )
    result = commands.run("move", { "cccccccc", "review" }, backend)
    t.eq(result.code, 1)
    t.eq(
        result.message,
        "cccccccc is an epic and cannot enter Review, a WIP-limited column: 2 of 3 children are open"
    )
    for _, call in ipairs(backend.calls) do
        t.ok(call[1] ~= "move", "the refused move was sent")
    end
    t.eq(commands.run("move", { "cccccccc", "backlog" }, backend).code, nil)
end)

t.test("discard closes an epic whose children are open", function()
    local backend = fake({ planned() })
    backend.kin = { children = { done = 0, total = 2 } }
    local result = commands.run("discard", { "cccccccc", "--reason", "Dropped" }, backend)
    t.eq(result.output, "discarded cccccccc")
    for _, call in ipairs(backend.calls) do
        t.ok(call[1] ~= "family", "discard read the children")
    end
end)

t.test("an epic needs an outcome to enter a working column like a card without children", function()
    local card = planned()
    card.epic = { done = 0, total = 2 }
    local backend = fake({ card })
    backend.kin = { children = card.epic }
    t.eq(commands.run("move", { "cccccccc", "backlog" }, backend).code, 1)
    card.outcomes = { { id = "s1", name = "a", done = false } }
    t.eq(commands.run("move", { "cccccccc", "backlog" }, backend).code, nil)
    t.eq(commands.run("move", { "cccccccc", "review" }, backend).code, nil)
    backend = fake({ planned() })
    t.eq(commands.run("move", { "cccccccc", "review" }, backend).code, 1)
end)

t.test("an unsized epic is refused and a red one is allowed", function()
    local card = planned()
    card.color = nil
    card.epic = { done = 0, total = 2 }
    card.outcomes = { { id = "s1", name = "a", done = false } }
    local backend = fake({ card })
    backend.kin = { children = card.epic }
    t.eq(commands.run("move", { "cccccccc", "backlog" }, backend).code, 1)
    card.color = "red"
    backend = fake({ card })
    backend.kin = { children = card.epic }
    t.eq(commands.run("move", { "cccccccc", "backlog" }, backend).code, nil)
end)

t.test(
    "discard refuses an unsized card or one without sections, and takes one without outcomes",
    function()
        local card = planned()
        card.color = nil
        local backend = fake({ card })
        local result = commands.run("discard", { "cccccccc", "--reason", "Dropped" }, backend)
        t.eq(result.code, 1)
        t.ok(result.message:find("a size", 1, true), result.message)
        card.column = "Icebox"
        result = commands.run("discard", { "cccccccc" }, fake({ card }))
        t.eq(result.code, 1)
        card.color = "green"
        card.description = "loose"
        result = commands.run("discard", { "cccccccc" }, backend)
        t.eq(result.code, 1)
        t.ok(result.message:find("## Change", 1, true), result.message)
        t.eq(#backend.calls, 0)
        card.description = V2
        t.eq(commands.run("discard", { "cccccccc" }, backend).output, "discarded cccccccc")
    end
)

t.test("move to Done refuses outcomes dev cannot read", function()
    local cards = sample()
    cards[1].outcomes_unreadable = true
    local backend = fake(cards)
    local result = commands.run("move", { "11111111-a", "done" }, backend)
    t.eq(result.code, 1)
    t.eq(result.unqueued, true)
    t.eq(
        result.message,
        "11111111 cannot move to Done: its outcomes cannot be read from Pomb, so they cannot be checked"
    )
    t.eq(#backend.calls, 0)
end)

t.test("move to a working column does not demand outcomes dev cannot read", function()
    local cards = sample()
    cards[1].outcomes_unreadable = true
    local backend = fake(cards)
    local result = commands.run("move", { "11111111-a", "review" }, backend)
    t.eq(result.code, nil)
end)

t.test("move to Done is never queued when the card cannot be read", function()
    local backend = fake(sample())
    local message = "board unavailable: cannot reach pomb.example (curl exit 7)"
    backend.cards = function()
        return nil, message
    end
    local result = commands.run("move", { "11111111-a", "done" }, backend)
    t.eq(result.message, message)
    t.eq(result.unqueued, true)
    result = commands.run("move", { "11111111-a", "review" }, backend)
    t.eq(result.message, message)
    t.eq(result.unqueued, nil)
end)

t.test("discard closes a card with unticked outcomes", function()
    local cards = sample()
    cards[1].outcomes = { { id = "s1", name = "A works", done = false } }
    local backend = fake(cards)
    local result = commands.run("discard", { "11111111-a", "--reason", "Dropped" }, backend)
    t.eq(result.output, "discarded 11111111")
    t.eq(backend.calls[#backend.calls], { "move", ID_A, "Done" })
end)

t.test("checks replaces the rows with one row per command", function()
    local backend = fake(sample())
    local result = commands.run("checks", { "11111111-a", "dev lint", "dev test" }, backend)
    t.eq(result.output, "set checks 11111111, 2 rows")
    t.eq(backend.calls[1], { "set_checks", ID_A, { "dev lint", "dev test" }, nil })
    result = commands.run("checks", { "11111111-a", "dev lint" }, fake(sample()))
    t.eq(result.output, "set checks 11111111, 1 row")
end)

t.test(
    "checks refuses no command, a blank command, an unknown card and a board without the field",
    function()
        local backend = fake(sample())
        t.eq(commands.run("checks", { "11111111-a" }, backend).code, 2)
        t.eq(commands.run("checks", {}, backend).code, 2)
        t.eq(commands.run("checks", { "11111111-a", "dev lint", " " }, backend).code, 2)
        t.eq(commands.run("checks", { "deadbeef", "dev lint" }, backend).code, 1)
        backend.nofield = true
        local result = commands.run("checks", { "11111111-a", "dev lint" }, backend)
        t.eq(result.code, 1)
        t.ok(result.message:find("no checks field", 1, true), result.message)
        t.ok(result.message:find("dev board init", 1, true), result.message)
        t.eq(#backend.calls, 0)
    end
)

t.test("allow replaces the field with the words once each, and none sends null", function()
    local backend = fake(sample())
    local result =
        commands.run("allow", { "11111111-a", "ci-edits", "test-edits", "ci-edits" }, backend)
    t.eq(result.output, "set allow 11111111, ci-edits test-edits")
    t.eq(
        backend.calls[1],
        { "set_field", ID_A, "dev.allow", { "ci-edits", "test-edits" }, nil }
    )
    result = commands.run("allow", { "11111111-a", "none" }, backend)
    t.eq(result.output, "cleared allow 11111111")
    t.eq(backend.calls[2], { "set_field", ID_A, "dev.allow", json.null, nil })
end)

t.test(
    "allow refuses no word, another word, none beside a word, an unknown card and a board without the field",
    function()
        local backend = fake(sample())
        t.eq(commands.run("allow", { "11111111-a" }, backend).code, 2)
        t.eq(commands.run("allow", {}, backend).code, 2)
        t.eq(commands.run("allow", { "11111111-a", "everything" }, backend).code, 2)
        t.eq(commands.run("allow", { "11111111-a", "test-edits", "none" }, backend).code, 2)
        t.eq(commands.run("allow", { "deadbeef", "none" }, backend).code, 1)
        backend.nofield = true
        local result = commands.run("allow", { "11111111-a", "test-edits" }, backend)
        t.eq(result.code, 1)
        t.ok(result.message:find("no dev.allow field", 1, true), result.message)
        t.eq(#backend.calls, 0)
    end
)

t.test("tests and files replace the field with one name per line", function()
    local backend = fake(sample())
    local result =
        commands.run("tests", { "11111111-a", "one_should_be_one", "tests::two" }, backend)
    t.eq(result.output, "set tests 11111111, 2 names")
    t.eq(
        backend.calls[1],
        { "set_field", ID_A, "dev.tests", "one_should_be_one\ntests::two", nil }
    )
    result = commands.run("files", { "11111111-a", "src/a.rs" }, backend)
    t.eq(result.output, "set files 11111111, 1 name")
    t.eq(backend.calls[2], { "set_field", ID_A, "dev.files", "src/a.rs", nil })
end)

t.test(
    "tests and files refuse no name, a blank name, a line break, an unknown card and a board without the field",
    function()
        local backend = fake(sample())
        for _, sub in ipairs({ "tests", "files" }) do
            t.eq(commands.run(sub, { "11111111-a" }, backend).code, 2)
            t.eq(commands.run(sub, {}, backend).code, 2)
            t.eq(commands.run(sub, { "11111111-a", "a", " " }, backend).code, 2)
            t.eq(commands.run(sub, { "11111111-a", "a\nb" }, backend).code, 2)
            t.eq(commands.run(sub, { "deadbeef", "a" }, backend).code, 1)
        end
        backend.nofield = true
        local result = commands.run("files", { "11111111-a", "a" }, backend)
        t.eq(result.code, 1)
        t.ok(result.message:find("no dev.files field", 1, true), result.message)
        result = commands.run("tests", { "11111111-a", "a" }, backend)
        t.ok(result.message:find("no dev.tests field", 1, true), result.message)
        t.eq(#backend.calls, 0)
    end
)

t.test("edit refuses a missing text, an extra word and an unknown card", function()
    local backend = fake(sample())
    t.eq(commands.run("edit", { "11111111-a" }, backend).code, 2)
    t.eq(commands.run("edit", { "11111111-a", "x", "y" }, backend).code, 2)
    t.eq(commands.run("edit", { "deadbeef", "x" }, backend).code, 1)
    t.eq(#backend.calls, 0)
end)

t.test("link sends the full ids of the card and the other card", function()
    local backend = fake(sample())
    local result = commands.run("link", { "11111111-a", "blocked_by", "cccccccc" }, backend)
    t.eq(result.output, "linked 11111111 blocked_by cccccccc")
    t.eq(backend.calls[1], { "link", ID_A, "blocked_by", ID_C })
    result = commands.run("link", { "cccccccc", "blocks", "11111111-b" }, backend)
    t.eq(result.output, "linked cccccccc blocks 11111111")
    t.eq(backend.calls[2], { "link", ID_C, "blocks", ID_B })
    result = commands.run("link", { "cccccccc", "related", "11111111-a" }, backend)
    t.eq(backend.calls[3], { "link", ID_C, "related", ID_A })
end)

t.test("link to BOARD:CARD resolves the card on the other board", function()
    local backend = fake(sample())
    local elsewhere = {
        cards = function()
            return {
                {
                    id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                    name = "Far",
                    column = "Ready",
                    size = "unsized",
                    labels = {},
                    checks = {},
                },
            }
        end,
    }
    backend.sibling = elsewhere
    local result = commands.run("link", { "11111111-a", "blocked_by", "ci:dddddddd" }, backend)
    t.eq(result.output, "linked 11111111 blocked_by ci:dddddddd")
    t.eq(backend.calls[1], { "other_board", "ci" })
    t.eq(backend.calls[2], { "link", ID_A, "blocked_by", "dddddddd-dddd-4ddd-8ddd-dddddddddddd" })
    result = commands.run("link", { "11111111-a", "related", "nope:dddddddd" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("no board named nope", 1, true), result.message)
    result = commands.run("link", { "11111111-a", "related", "ci:eeeeeeee" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("no card starts with eeeeeeee", 1, true), result.message)
    t.eq(#backend.calls, 4)
end)

t.test("links lists each link with the kind, the id prefix and the board", function()
    local backend = fake(sample())
    backend.held = {
        { kind = "blocked_by", id = ID_C },
        { kind = "blocks", id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd", board = "ci" },
        { kind = "related", id = ID_B },
    }
    local result = commands.run("links", { "11111111-a" }, backend)
    t.eq(
        result.output,
        "blocked_by  cccccccc  -\nblocks      dddddddd  ci\nrelated     11111111  -"
    )
    t.eq(backend.calls[1], { "links", ID_A })
    t.eq(commands.run("links", { "11111111-b" }, fake(sample())).output, "no links")
    t.eq(commands.run("links", {}, backend).code, 2)
    t.eq(commands.run("links", { "deadbeef" }, backend).code, 1)
end)

t.test("unlink removes the held link of that kind and target, and refuses one it lacks", function()
    local backend = fake(sample())
    backend.held = { { kind = "blocked_by", id = ID_C }, { kind = "related", id = ID_B } }
    local result = commands.run("unlink", { "11111111-a", "blocked_by", "cccccccc" }, backend)
    t.eq(result.output, "unlinked 11111111 blocked_by cccccccc")
    t.eq(backend.calls[2], { "unlink", ID_A, "blocked_by", ID_C })
    result = commands.run("unlink", { "11111111-a", "blocks", "cccccccc" }, backend)
    t.eq(result.code, 1)
    t.eq(
        result.message,
        "the card holds no blocks link to cccccccc, its links are\n"
            .. "blocked_by  cccccccc  -\nrelated     11111111  -"
    )
    t.eq(backend.calls[3], { "links", ID_A })
    backend.held = {}
    result = commands.run("unlink", { "11111111-a", "related", "cccccccc" }, backend)
    t.eq(result.message, "the card holds no related link to cccccccc, it holds no links")
    t.eq(commands.run("unlink", { "11111111-a", "blocked_by" }, backend).code, 2)
    t.eq(commands.run("unlink", { "11111111-a", "depends", "cccccccc" }, backend).code, 2)
    t.eq(commands.run("unlink", { "deadbeef", "blocked_by", "cccccccc" }, backend).code, 1)
    t.eq(commands.run("unlink", { "11111111-a", "blocked_by", "deadbeef" }, backend).code, 1)
end)

t.test("link takes parent, and show prints the epic and the children", function()
    local backend = fake(sample())
    local result = commands.run("link", { "cccccccc", "parent", "11111111-a" }, backend)
    t.eq(result.output, "linked cccccccc parent 11111111")
    t.eq(backend.calls[1], { "link", ID_C, "parent", ID_A })
    backend.kin = { parent = { id = ID_A, name = "Epic" } }
    result = commands.run("show", { "11111111-b" }, backend)
    t.eq(
        result.output,
        "11111111  Backlog  unsized  -  Fix lint\nparent: 11111111 Epic\n\nno description\n\nno comments"
    )
    backend.kin = { children = { done = 1, total = 3 } }
    result = commands.run("show", { "11111111-b" }, backend)
    t.eq(
        result.output,
        "11111111  Backlog  unsized  -  Fix lint\nchildren: 1 of 3 done\n\nno description\n\nno comments"
    )
end)

t.test("link refuses a bad kind, a missing word and an unknown card", function()
    local backend = fake(sample())
    t.eq(commands.run("link", { "11111111-a", "depends", "cccccccc" }, backend).code, 2)
    t.eq(commands.run("link", { "11111111-a", "blocks" }, backend).code, 2)
    t.eq(commands.run("link", { "11111111-a", "blocks", "cccccccc", "x" }, backend).code, 2)
    t.eq(commands.run("link", { "deadbeef", "blocks", "cccccccc" }, backend).code, 1)
    t.eq(commands.run("link", { "11111111-a", "blocks", "deadbeef" }, backend).code, 1)
    t.eq(#backend.calls, 0)
end)

t.test("note and move resolve the card by prefix", function()
    local cards = sample()
    cards[3].color = "green"
    cards[3].description = V2
    cards[3].outcomes = { { id = "s1", name = "a", done = false } }
    local backend = fake(cards)
    local result = commands.run("note", { "cccccccc", "landed", "as", "abc" }, backend)
    t.eq(result.output, "noted cccccccc")
    t.eq(backend.calls[1], { "note", ID_C, "landed as abc", {} })
    result = commands.run("move", { "cccccccc", "blocked" }, backend)
    t.eq(result.output, "moved cccccccc to Blocked")
    t.eq(backend.calls[2], { "move", ID_C, "Blocked" })
    result = commands.run("move", { "cccccccc", "review" }, backend)
    t.eq(backend.calls[3], { "move", ID_C, "Review" })
end)

local COMMENT_1 = "aaaaaaaa-1111-4111-8111-111111111111"
local COMMENT_2 = "bbbbbbbb-2222-4222-8222-222222222222"
local BODY_COLUMN = 56

local function with_comments()
    local backend = fake(sample())
    backend.listed = {
        {
            id = COMMENT_1,
            who = "worker",
            at = "2026-10-27T09:30:12Z",
            body = "first line\nsecond",
            kind = "decision",
            author = "reviewer",
        },
        { id = COMMENT_2, who = "human", at = "2026-10-27T10:00:00Z", body = "ok" },
    }
    return backend
end

t.test("notes lists each comment with its id prefix, writer, time and first line", function()
    local backend = with_comments()
    local result = commands.run("notes", { "cccccccc" }, backend)
    t.eq(
        result.output,
        "aaaaaaaa  worker  decision  reviewer  2026-10-27 09:30  first line\n"
            .. "bbbbbbbb  human   -         -         2026-10-27 10:00  ok"
    )
    t.eq(commands.run("notes", { "cccccccc" }, fake(sample())).output, "no comments")
    t.eq(commands.run("notes", {}, backend).code, 2)
    t.eq(commands.run("notes", { "deadbeef" }, backend).code, 1)
end)

t.test("show indents the rest of a multi-line body under its body, notes keeps one line", function()
    local backend = fake(sample())
    backend.listed = {
        {
            id = COMMENT_1,
            who = "worker",
            at = "2026-10-27T09:30:12Z",
            body = "1. first\r\n\r\n2. second\n\n",
            kind = "decision",
            author = "reviewer",
        },
        { id = COMMENT_2, who = "human", at = "2026-10-27T10:00:00Z", body = "ok\nmore" },
    }
    local result = commands.run("show", { "cccccccc" }, backend)
    t.eq(
        result.output,
        "cccccccc  Done  unsized  -  Old thing\n\nno description\n\n"
            .. "aaaaaaaa  worker  decision  reviewer  2026-10-27 09:30  1. first\n\n"
            .. (" "):rep(BODY_COLUMN)
            .. "2. second\n"
            .. "bbbbbbbb  human   -         -         2026-10-27 10:00  ok\n"
            .. (" "):rep(BODY_COLUMN)
            .. "more"
    )
    t.eq(
        commands.run("notes", { "cccccccc" }, backend).output,
        "aaaaaaaa  worker  decision  reviewer  2026-10-27 09:30  1. first\n"
            .. "bbbbbbbb  human   -         -         2026-10-27 10:00  ok"
    )
end)

t.test("note --kind question names dev board ask", function()
    local backend = fake(sample())
    local count = #backend.calls
    for _, args in ipairs({
        { "cccccccc", "--kind", "question", "Which way?" },
        { "cccccccc", "--kind", "Question", "Which way?" },
    }) do
        local result = commands.run("note", args, backend)
        t.eq(result.code, 2)
        t.ok(
            result.message:find(
                "dev board ask CARD --question TEXT --choice COLUMN=LABEL --recommend N --why TEXT",
                1,
                true
            ),
            result.message
        )
    end
    t.eq(#backend.calls, count)
end)

t.test("note sends a lowercase kind and a trimmed role, and refuses a bad one", function()
    local backend = fake(sample())
    local args = { "cccccccc", "--kind", "Decision", "--as", " reviewer ", "go", "ahead" }
    local result = commands.run("note", args, backend)
    t.eq(result.output, "noted cccccccc")
    t.eq(backend.calls[1], { "note", ID_C, "go ahead", { kind = "decision", author = "reviewer" } })
    result = commands.run("note", { "cccccccc", "--as", "planner", "text" }, backend)
    t.eq(backend.calls[2], { "note", ID_C, "text", { author = "planner" } })
    local count = #backend.calls
    for _, bad in ipairs({
        { "cccccccc", "--kind", "chatter", "text" },
        { "cccccccc", "--kind" },
        { "cccccccc", "--as", "   ", "text" },
        { "cccccccc", "--as", string.rep("x", 81), "text" },
        { "cccccccc", "--as", "a\nb", "text" },
    }) do
        t.eq(commands.run("note", bad, backend).code, 2)
    end
    t.eq(#backend.calls, count)
    result = commands.run("note", { "cccccccc", "see", "the", "--as", "flag" }, backend)
    t.eq(backend.calls[count + 1], { "note", ID_C, "see the --as flag", {} })
    t.eq(
        commands.run("note", { "cccccccc", "--kind", "done", "--edit", "bbbbbbbb", "x" }, backend).code,
        2
    )
    t.eq(
        #commands.run("note", { "cccccccc", "--as", string.rep("x", 80), "t" }, backend).output > 0,
        true
    )
end)

t.test("show prints the card line, its description and its comments", function()
    local cards = sample()
    cards[1].description = "Why it matters.\nSecond line."
    local backend = with_comments()
    backend.cards = function()
        return cards
    end
    local result = commands.run("show", { "11111111-a" }, backend)
    t.eq(
        result.output,
        "11111111  Ready  1 Pomodoro  docs  Write docs\n\nWhy it matters.\nSecond line.\n\n"
            .. "aaaaaaaa  worker  decision  reviewer  2026-10-27 09:30  first line\n"
            .. (" "):rep(BODY_COLUMN)
            .. "second\n"
            .. "bbbbbbbb  human   -         -         2026-10-27 10:00  ok"
    )
    t.eq(backend.calls[#backend.calls], { "family", ID_A })
    result = commands.run("show", { "bbbbbbbb-b" }, fake(sample()))
    t.eq(result.code, 1)
    result = commands.run("show", { "11111111-b" }, fake(sample()))
    t.eq(result.output, "11111111  Backlog  unsized  -  Fix lint\n\nno description\n\nno comments")
    t.eq(commands.run("show", {}, backend).code, 2)
    t.eq(commands.run("show", { "deadbeef" }, backend).code, 1)
end)

t.test("note --edit and --delete resolve the comment by prefix", function()
    local backend = with_comments()
    local result =
        commands.run("note", { "cccccccc", "--edit", "bbbbbbbb", "fixed", "it" }, backend)
    t.eq(result.output, "edited cccccccc bbbbbbbb")
    t.eq(backend.calls[2], { "edit_note", ID_C, COMMENT_2, "fixed it" })
    result = commands.run("note", { "cccccccc", "--delete", "aaaaaaaa-1" }, backend)
    t.eq(result.output, "deleted cccccccc aaaaaaaa")
    t.eq(backend.calls[4], { "delete_note", ID_C, COMMENT_1 })
end)

t.test("note --edit and --delete refuse a bad comment prefix or a bad shape", function()
    local backend = with_comments()
    for _, args in ipairs({
        { "cccccccc", "--edit", "bbbb", "x" },
        { "cccccccc", "--delete", "zzzzzzzz" },
        { "cccccccc", "--delete", "cccccccc" },
    }) do
        local result = commands.run("note", args, backend)
        t.eq(result.code, 1)
    end
    t.eq(
        commands.run("note", { "cccccccc", "--delete", "bbbb" }, backend).message,
        "a comment id needs at least 8 hex characters: bbbb"
    )
    t.eq(
        commands.run("note", { "cccccccc", "--delete", "cccccccc" }, backend).message,
        "no comment starts with cccccccc"
    )
    for _, args in ipairs({
        { "cccccccc", "--edit", "bbbbbbbb" },
        { "cccccccc", "--edit" },
        { "cccccccc", "--delete" },
        { "cccccccc", "--delete", "bbbbbbbb", "extra" },
    }) do
        t.eq(commands.run("note", args, backend).code, 2)
    end
    for _, call in ipairs(backend.calls) do
        t.ok(call[1] == "comments", call[1])
    end
end)

t.test("move and note refuse before the backend is called", function()
    local backend = fake(sample())
    local result = commands.run("move", { "cccccccc", "doing" }, backend)
    t.eq(result.code, 2)
    result = commands.run("move", { "deadbeef", "ready" }, backend)
    t.eq(result.code, 1)
    result = commands.run("note", { "cccccccc" }, backend)
    t.eq(result.code, 2)
    t.eq(#backend.calls, 0)
end)

t.test(
    "add to Ready refuses a card with no size or a red one before the backend is called",
    function()
        local backend = fake(sample())
        for _, args in ipairs({
            { "X", "--column", "ready" },
            { "X", "--column", "ready", "--size", "unsized" },
            { "X", "--column", "ready", "--size", "3+" },
        }) do
            t.eq(commands.run("add", args, backend).code, 2)
        end
        t.eq(#backend.calls, 0)
        t.eq(
            commands.run(
                "add",
                { "X", "--column", "backlog", "--problem", "x", "--size", "1", "--done-when", "a" },
                backend
            ).code,
            nil
        )
        local full =
            { "X", "--column", "ready", "--size", "3", "--description", V1, "--checks", "dev test" }
        t.eq(commands.run("add", full, backend).code, nil)
    end
)

local function colored(color)
    local card = {
        id = ID_C,
        name = "Card",
        column = "Backlog",
        size = "x",
        labels = {},
        description = V1,
        checks = { "dev test" },
    }
    card.color = color
    return card
end

t.test("move to Ready refuses a white, uncoloured or red card and names dev board size", function()
    for _, color in ipairs({ "white", "red" }) do
        local backend = fake({ colored(color) })
        local result = commands.run("move", { "cccccccc", "ready" }, backend)
        t.eq(result.code, 1)
        t.ok(result.message:find("dev board size", 1, true), result.message)
        t.eq(#backend.calls, 0)
    end
    local backend = fake({ colored(nil) })
    local result = commands.run("move", { "cccccccc", "Ready" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("has no size", 1, true), result.message)
    t.eq(#backend.calls, 0)
end)

t.test("add scaffolds the v2 headings, fills Problem and keeps a text that has them", function()
    local backend = fake(sample())
    commands.run(
        "add",
        { "X", "--description", "It breaks.", "--size", "1", "--done-when", "a" },
        backend
    )
    t.eq(backend.calls[1][4], "## Problem\nIt breaks.\n\n## Change\n\n## Out of scope\n")
    commands.run("add", { "X", "--description", V1, "--size", "1" }, backend)
    t.eq(backend.calls[2][4], V1)
    commands.run("add", { "X", "--column", "icebox", "--description", "loose" }, backend)
    t.eq(backend.calls[3], { "add", "X", "Icebox", "loose", nil })
    commands.run("add", { "X", "--column", "icebox" }, backend)
    t.eq(backend.calls[4], { "add", "X", "Icebox", nil, nil })
end)

t.test("add composes the three sections from --problem, --change and --out-of-scope", function()
    local backend = fake(sample())
    local result = commands.run("add", {
        "X",
        "--problem",
        "It breaks.",
        "--change",
        "- fix it",
        "--out-of-scope",
        "nothing",
        "--size",
        "1",
        "--done-when",
        "a",
    }, backend)
    t.eq(result.output, "added cccccccc Backlog")
    t.eq(
        backend.calls[1][4],
        "## Problem\nIt breaks.\n\n## Change\n- fix it\n\n## Out of scope\nnothing\n"
    )
    commands.run(
        "add",
        { "X", "--problem", "  only  ", "--size", "1", "--done-when", "a" },
        backend
    )
    t.eq(backend.calls[2][4], "## Problem\nonly\n\n## Change\n\n## Out of scope\n")
end)

t.test("add refuses --description together with a section flag", function()
    local backend = fake(sample())
    for _, flag in ipairs({ "--problem", "--change", "--out-of-scope" }) do
        local result = commands.run("add", { "X", "--description", "text", flag, "y" }, backend)
        t.eq(result.code, 2)
        t.ok(result.message:find("--description", 1, true), result.message)
    end
    t.eq(#backend.calls, 0)
end)

t.test("add keeps each repeated --change as its own line, in order", function()
    local backend = fake(sample())
    local result = commands.run("add", {
        "X",
        "--problem",
        "p",
        "--change",
        "- one",
        "--change",
        "- two",
        "--change",
        "- three",
        "--size",
        "1",
        "--done-when",
        "a",
    }, backend)
    t.eq(result.output, "added cccccccc Backlog")
    t.eq(
        backend.calls[1][4],
        "## Problem\np\n\n## Change\n- one\n- two\n- three\n\n## Out of scope\n"
    )
end)

t.test("add refuses a repeated --problem or --out-of-scope by name", function()
    local backend = fake(sample())
    for _, flag in ipairs({ "--problem", "--out-of-scope" }) do
        local result = commands.run("add", { "X", flag, "a", flag, "b" }, backend)
        t.eq(result.code, 2)
        t.ok(result.message:find(flag, 1, true), result.message)
    end
    t.eq(#backend.calls, 0)
end)

t.test("add into Backlog without a Problem is refused before the backend is called", function()
    local backend = fake(sample())
    local result = commands.run("add", { "X" }, backend)
    t.eq(result.code, 2)
    t.ok(result.message:find("text under ## Problem", 1, true), result.message)
    result = commands.run("add", { "X", "--change", "- do" }, backend)
    t.eq(result.code, 2)
    t.ok(result.message:find("text under ## Problem", 1, true), result.message)
    result = commands.run("add", { "X", "--column", "backlog", "--out-of-scope", "n" }, backend)
    t.eq(result.code, 2)
    t.eq(#backend.calls, 0)
end)

t.test("add outside Icebox refuses a missing size, section or outcome in every column", function()
    local backend = fake(sample())
    for _, column in ipairs({ "backlog", "progress", "review", "blocked", "done" }) do
        local cases = {
            { { "--problem", "x", "--done-when", "a" }, "a size" },
            { { "--size", "1", "--done-when", "a" }, "text under ## Problem" },
            { { "--size", "1", "--problem", "x" }, "Done when outcomes" },
            { { "--size", "unsized", "--problem", "x", "--done-when", "a" }, "a size" },
        }
        for _, case in ipairs(cases) do
            local args = { "X", "--column", column }
            for _, word in ipairs(case[1]) do
                args[#args + 1] = word
            end
            local result = commands.run("add", args, backend)
            t.eq(result.code, 2, column)
            t.ok(result.message:find(case[2], 1, true), result.message)
        end
    end
    t.eq(#backend.calls, 0)
end)

t.test("add into Icebox stays free-form", function()
    local backend = fake(sample())
    t.eq(commands.run("add", { "X", "--column", "icebox" }, backend).code, nil)
    t.eq(backend.calls[1], { "add", "X", "Icebox", nil, nil })
    t.eq(
        commands.run("add", { "X", "--column", "icebox", "--description", "loose" }, backend).code,
        nil
    )
    t.eq(backend.calls[2], { "add", "X", "Icebox", "loose", nil })
end)

t.test("missing and backlog_missing count a heading with text, not an empty one", function()
    t.eq(board.backlog_missing(V2), {})
    t.eq(board.backlog_missing(SCAFFOLD), {})
    t.eq(board.backlog_missing("## Problem\n\n## Change\nc\n## Out of scope\no"), {
        "text under ## Problem",
    })
    t.eq(board.backlog_missing("## Problem\nx"), { "## Change", "## Out of scope" })
    t.eq(board.backlog_missing(nil), { "## Problem", "## Change", "## Out of scope" })
    t.eq(board.missing(V1, 0, 0), {})
    t.eq(board.missing("## Problem\nx\n\n## Change\n\n## Out of scope\nn", 3, 0), {
        "text under ## Change",
    })
    t.eq(board.missing("## Problem\nx\n\n## Change\ny\n\n## Out of scope\n", 3, 0), {
        "text under ## Out of scope",
    })
    t.eq(board.missing(V2, 3, 0), {})
end)

t.test(
    "shapes flags an empty Change or Out of scope and a Change: or Out of scope: line",
    function()
        t.eq(board.shapes(V2), {})
        t.eq(board.shapes("## Problem\nx\n\n## Change\n\n## Out of scope\n"), {
            "text under ## Change",
            "text under ## Out of scope",
        })
        t.eq(board.shapes("## Problem\nx\nChange: y\n\n## Change\nc\n\n## Out of scope\nn"), {
            "a Problem free of Change: and Out of scope: lines",
        })
        t.eq(board.shapes("## Problem\nChanged: y\n\n## Change\nc\n\n## Out of scope\nn"), {})
    end
)

t.test("move to Ready refuses an empty Change or Out of scope and accepts all three", function()
    for _, case in ipairs({
        { "## Problem\nx\n\n## Change\n\n## Out of scope\nn", "text under ## Change" },
        { "## Problem\nx\n\n## Change\ny\n\n## Out of scope\n", "text under ## Out of scope" },
        {
            "## Problem\nx\nChange: y\n\n## Change\nc\n\n## Out of scope\nn",
            "a Problem free of Change: and Out of scope: lines",
        },
        {
            "## Problem\nx\nOut of scope: y\n\n## Change\nc\n\n## Out of scope\nn",
            "a Problem free of Change: and Out of scope: lines",
        },
    }) do
        local card = colored("green")
        card.description = case[1]
        card.outcomes =
            { { id = "s1", name = "a" }, { id = "s2", name = "b" }, { id = "s3", name = "c" } }
        local backend = fake({ card })
        local result = commands.run("move", { "cccccccc", "ready" }, backend)
        t.eq(result.code, 1)
        t.ok(result.message:find(case[2], 1, true), result.message)
        t.eq(#backend.calls, 0)
    end
    local card = colored("green")
    card.description = V2
    card.outcomes =
        { { id = "s1", name = "a" }, { id = "s2", name = "b" }, { id = "s3", name = "c" } }
    t.eq(commands.run("move", { "cccccccc", "ready" }, fake({ card })).code, nil)
end)

t.test("move to Backlog refuses a card without a Problem and names what is missing", function()
    local card = colored("green")
    card.description = "loose idea"
    local backend = fake({ card })
    local result = commands.run("move", { "cccccccc", "backlog" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("cannot enter Backlog", 1, true), result.message)
    t.ok(result.message:find("## Problem", 1, true), result.message)
    t.eq(#backend.calls, 0)
    card.description = SCAFFOLD:gsub("x\n", "")
    result = commands.run("move", { "cccccccc", "backlog" }, fake({ card }))
    t.eq(result.code, 1)
    t.ok(result.message:find("text under ## Problem", 1, true), result.message)
    card.description = SCAFFOLD
    card.outcomes = { { id = "s1", name = "a", done = false } }
    t.eq(commands.run("move", { "cccccccc", "backlog" }, fake({ card })).code, nil)
end)

t.test("add to Ready refuses a description without the headings or a Done when item", function()
    local backend = fake(sample())
    local result = commands.run(
        "add",
        { "X", "--column", "ready", "--size", "1", "--description", "why" },
        backend
    )
    t.eq(result.code, 2)
    t.ok(result.message:find("3 to 7 Done when outcomes", 1, true), result.message)
    result = commands.run("add", { "X", "--column", "ready", "--size", "1" }, backend)
    t.eq(result.code, 2)
    t.eq(#backend.calls, 0)
end)

t.test("add --checks gives the card one row per command", function()
    local backend = fake(sample())
    local result = commands.run("add", {
        "X",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "a",
        "--checks",
        "dev lint",
        "--checks",
        "dev test",
    }, backend)
    t.eq(result.output, "added cccccccc Backlog")
    t.eq(backend.opts.checks, { "dev lint", "dev test" })
    result = commands.run("add", { "X", "--problem", "x", "--checks", "  " }, backend)
    t.eq(result.code, 2)
    t.eq(commands.run("add", { "X", "--checks" }, backend).code, 2)
end)

t.test("add to Ready without a checks row names the missing row, or the missing field", function()
    local backend = fake(sample())
    local args = { "X", "--column", "ready", "--size", "1", "--description", V1 }
    local result = commands.run("add", args, backend)
    t.eq(result.code, 2)
    t.ok(result.message:find("checks row", 1, true), result.message)
    t.ok(result.message:find("--checks", 1, true), result.message)
    backend.nofield = true
    result = commands.run("add", args, backend)
    t.eq(result.code, 2)
    t.ok(result.message:find("no checks field", 1, true), result.message)
    t.ok(result.message:find("dev board init", 1, true), result.message)
    result = commands.run(
        "add",
        { "X", "--problem", "x", "--size", "1", "--done-when", "a", "--checks", "dev test" },
        backend
    )
    t.eq(result.code, 2)
    t.ok(result.message:find("no checks field", 1, true), result.message)
    t.eq(#backend.calls, 0)
    t.eq(commands.run("add", { "X", "--column", "icebox" }, backend).code, nil)
end)

t.test("move to Ready counts a card with no checks row as missing them", function()
    local card = colored("green")
    card.checks = {}
    local backend = fake({ card })
    local result = commands.run("move", { "cccccccc", "ready" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("has no checks row", 1, true), result.message)
    backend.nofield = true
    result = commands.run("move", { "cccccccc", "ready" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("no checks field", 1, true), result.message)
    t.ok(result.message:find("dev board init", 1, true), result.message)
    t.eq(#backend.calls, 0)
    t.eq(commands.run("move", { "cccccccc", "icebox" }, backend).code, nil)
end)

t.test("show prints the checks rows under the description", function()
    local card = colored("green")
    card.checks = { "dev lint", "dev test" }
    local result = commands.run("show", { "cccccccc" }, fake({ card }))
    t.ok(result.output:find("\n\nchecks:\n- dev lint\n- dev test\n\n", 1, true), result.output)
    card.checks = {}
    result = commands.run("show", { "cccccccc" }, fake({ card }))
    t.eq(result.output:find("checks:", 1, true), nil)
end)

t.test("show prints the allow, tests and files blocks when set", function()
    local card = colored("green")
    card.checks = { "dev lint" }
    card.allow = { "test-edits" }
    card.tests = { "one", "two" }
    card.files = { "src/a.rs" }
    local result = commands.run("show", { "cccccccc" }, fake({ card }))
    t.ok(
        result.output:find(
            "\n\nchecks:\n- dev lint\n\nallow:\n- test-edits\n\ntests:\n- one\n- two\n\nfiles:\n- src/a.rs\n\n",
            1,
            true
        ),
        result.output
    )
    card.allow, card.tests, card.files = {}, {}, {}
    result = commands.run("show", { "cccccccc" }, fake({ card }))
    t.eq(result.output:find("allow:", 1, true), nil)
    t.eq(result.output:find("tests:", 1, true), nil)
    t.eq(result.output:find("files:", 1, true), nil)
end)

t.test("move to Ready refuses a card missing a heading or a Done when item", function()
    local cases = {
        { nil, "## Problem, ## Change, ## Out of scope, 3 to 7 Done when outcomes" },
        { "## Problem\nx\n\n## Change\ny\n\n## Done when\n- [ ] z", "## Out of scope" },
        {
            "## Problem\nx\n\n## Change\ny\n\n## Out of scope\nn\n\n## Done when\nsoon",
            "3 to 7 Done when outcomes",
        },
        {
            "## Problem\n- [ ] a\n\n## Change\ny\n\n## Out of scope\nn\n\n## Done when\n",
            "3 to 7 Done when outcomes",
        },
    }
    for _, case in ipairs(cases) do
        local card = colored("green")
        card.description = case[1]
        local backend = fake({ card })
        local result = commands.run("move", { "cccccccc", "ready" }, backend)
        t.eq(result.code, 1)
        t.ok(result.message:find(case[2], 1, true), result.message)
        t.eq(#backend.calls, 0)
    end
    local card = colored("green")
    card.description = V1:gsub("%[ %]", "[x]")
    t.eq(commands.run("move", { "cccccccc", "ready" }, fake({ card })).code, nil)
end)

local function outcomes(count, ticked)
    local list = {}
    for i = 1, count do
        list[i] = { id = "s" .. i, name = "Outcome " .. i, done = i <= (ticked or 0) }
    end
    return list
end

t.test("move to Ready counts 3 to 7 outcomes, and a v1 checklist when there are none", function()
    for _, count in ipairs({ 3, 5, 7 }) do
        local card = colored("green")
        card.description = V2
        card.outcomes = outcomes(count)
        t.eq(commands.run("move", { "cccccccc", "ready" }, fake({ card })).code, nil)
    end
    for _, count in ipairs({ 0, 2, 8 }) do
        local card = colored("green")
        card.description = V2
        card.outcomes = outcomes(count)
        local backend = fake({ card })
        local result = commands.run("move", { "cccccccc", "ready" }, backend)
        t.eq(result.code, 1)
        t.ok(result.message:find("card format v2", 1, true), result.message)
        t.ok(result.message:find("3 to 7 Done when outcomes", 1, true), result.message)
        t.eq(#backend.calls, 0)
    end
    local card = colored("green")
    card.outcomes = {}
    t.eq(commands.run("move", { "cccccccc", "ready" }, fake({ card })).code, nil)
end)

t.test("an epic with 1 to 3 outcomes enters Ready", function()
    for _, count in ipairs({ 1, 2, 3 }) do
        local card = colored("green")
        card.description = V2
        card.epic = { done = 2, total = 2 }
        card.outcomes = outcomes(count)
        local backend = fake({ card })
        t.eq(commands.run("move", { "cccccccc", "ready" }, backend).code, nil, count)
        t.eq(backend.calls[#backend.calls], { "move", ID_C, "Ready" })
    end
end)

t.test("an epic with no outcomes or more than 3 is refused with the epic rule", function()
    for _, count in ipairs({ 0, 4, 7 }) do
        local card = colored("green")
        card.description = V2
        card.epic = { done = 2, total = 2 }
        card.outcomes = outcomes(count)
        local backend = fake({ card })
        local result = commands.run("move", { "cccccccc", "ready" }, backend)
        t.eq(result.code, 1)
        t.ok(result.message:find("1 to 3 Done when outcomes for an epic", 1, true), result.message)
        if count > 0 then
            t.ok(result.message:find("not " .. count, 1, true), result.message)
        end
        t.eq(#backend.calls, 0)
    end
end)

t.test("a card without children is still held to 3 to 7 outcomes at Ready", function()
    for _, count in ipairs({ 1, 2, 8 }) do
        local card = colored("green")
        card.description = V2
        card.outcomes = outcomes(count)
        local backend = fake({ card })
        local result = commands.run("move", { "cccccccc", "ready" }, backend)
        t.eq(result.code, 1)
        t.ok(result.message:find("3 to 7 Done when outcomes", 1, true), result.message)
        t.eq(result.message:find("epic", 1, true), nil, result.message)
        t.eq(#backend.calls, 0)
    end
end)

t.test("add --done-when hands the outcomes to the backend and checks them", function()
    local backend = fake(sample())
    local result = commands.run(
        "add",
        { "X", "--problem", "x", "--size", "1", "--done-when", "A works", "--done-when", "B works" },
        backend
    )
    t.eq(result.output, "added cccccccc Backlog")
    t.eq(backend.opts.outcomes, { "A works", "B works" })
    t.eq(commands.run("add", { "X", "--problem", "x", "--done-when", " " }, backend).code, 2)
    t.eq(commands.run("add", { "X", "--done-when" }, backend).code, 2)
    local many = { "X", "--problem", "x" }
    for i = 1, 8 do
        many[#many + 1] = "--done-when"
        many[#many + 1] = "o" .. i
    end
    t.eq(commands.run("add", many, backend).code, 2)
    local ready = {
        "X",
        "--column",
        "ready",
        "--size",
        "1",
        "--description",
        V2,
        "--checks",
        "dev test",
        "--done-when",
        "a",
        "--done-when",
        "b",
    }
    result = commands.run("add", ready, backend)
    t.eq(result.code, 2)
    t.ok(result.message:find("3 to 7 Done when outcomes", 1, true), result.message)
    ready[#ready + 1] = "--done-when"
    ready[#ready + 1] = "c"
    t.eq(commands.run("add", ready, backend).code, nil)
    result = commands.run(
        "add",
        { "X", "--problem", "x", "--size", "1", "--done-when", "see src/a.lua" },
        backend
    )
    t.eq(result.warnings, { "card prose holds a path: src/a.lua" })
end)

t.test("show lists the outcomes with their ticks, and ls adds a done column", function()
    local card = colored("green")
    card.outcomes = outcomes(3, 1)
    local result = commands.run("show", { "cccccccc" }, fake({ card }))
    t.ok(
        result.output:find(
            "\n\ndone when:\n- [x] Outcome 1\n- [ ] Outcome 2\n- [ ] Outcome 3\n\n",
            1,
            true
        ),
        result.output
    )
    result = commands.run("ls", {}, fake({ card }))
    t.eq(result.output, "cccccccc  Backlog  x  -  1/3  Card")
    local plain = colored("green")
    t.eq(commands.run("ls", {}, fake({ plain })).output, "cccccccc  Backlog  x  -  Card")
end)

t.test("show prints the done when block once and only when a card has outcomes", function()
    local function count(text, needle)
        local n = 0
        for _ in text:gmatch(needle) do
            n = n + 1
        end
        return n
    end
    local checklist =
        "## Problem\nwhy\n\n## Done when\n- [ ] Outcome 1\n- [ ] Outcome 2\n- [ ] Outcome 3"
    local card = colored("green")
    card.description = checklist
    card.outcomes = outcomes(3, 1)
    local result = commands.run("show", { "cccccccc" }, fake({ card }))
    t.eq(count(result.output, "Outcome 1"), 1, result.output)
    t.eq(count(result.output, "[Dd]one when"), 1, result.output)
    t.ok(
        result.output:find("## Problem\nwhy\n\ndone when:\n- [x] Outcome 1", 1, true),
        result.output
    )
    card.description = "## Done when\n- [ ] Outcome 1\n- [ ] Outcome 2\n- [ ] Outcome 3"
    result = commands.run("show", { "cccccccc" }, fake({ card }))
    t.eq(count(result.output, "Outcome 1"), 1, result.output)
    t.ok(result.output:find("\n\nno description\n\ndone when:\n", 1, true), result.output)
    card.description = checklist
    card.outcomes = {}
    result = commands.run("show", { "cccccccc" }, fake({ card }))
    t.eq(count(result.output, "done when:"), 0, result.output)
    t.eq(count(result.output, "## Done when"), 1, result.output)
    t.eq(count(result.output, "Outcome 1"), 1, result.output)
end)

t.test("outcome appends, rewords, ticks and unticks by number", function()
    local card = colored("green")
    card.outcomes = outcomes(3, 1)
    local backend = fake({ card })
    local result = commands.run("outcome", { "cccccccc", "Fourth", "works" }, backend)
    t.eq(result.output, "outcome cccccccc 4 added")
    t.eq(backend.calls[1], { "add_outcome", ID_C, "Fourth works", nil })
    result = commands.run(
        "outcome",
        { "cccccccc", "--rename", "2", "New", "words", "--reason", "it was vague" },
        backend
    )
    t.eq(result.output, "outcome cccccccc 2 reworded")
    t.eq(backend.calls[2], { "set_outcome", ID_C, "s2", { name = "New words" }, nil })
    result = commands.run("outcome", { "cccccccc", "--tick", "2" }, backend)
    t.eq(result.output, "outcome cccccccc 2 ticked")
    t.eq(backend.calls[4], { "set_outcome", ID_C, "s2", { done = true }, nil })
    result = commands.run("outcome", { "cccccccc", "--untick", "1" }, backend)
    t.eq(result.output, "outcome cccccccc 1 unticked")
    t.eq(backend.calls[5], { "set_outcome", ID_C, "s1", { done = false }, nil })
end)

t.test(
    "outcome refuses text that holds a flag or is only a number, and accepts a sentence",
    function()
        local card = colored("green")
        card.outcomes = outcomes(3)
        local backend = fake({ card })
        local result = commands.run("outcome", { "cccccccc", "1", "--tick" }, backend)
        t.eq(result.code, 2)
        t.ok(result.message:find("dev board outcome CARD --tick 1", 1, true), result.message)
        t.eq(commands.run("outcome", { "cccccccc", "2", "--untick" }, backend).code, 2)
        t.eq(commands.run("outcome", { "cccccccc", "Fix", "--convert" }, backend).code, 2)
        result = commands.run("outcome", { "cccccccc", "2" }, backend)
        t.eq(result.code, 2)
        t.ok(result.message:find("--tick 2", 1, true), result.message)
        t.eq(#backend.calls, 0)
        result =
            commands.run("outcome", { "cccccccc", "Use --tick 2 to mark an outcome." }, backend)
        t.eq(result.output, "outcome cccccccc 4 added")
        t.eq(backend.calls[1], { "add_outcome", ID_C, "Use --tick 2 to mark an outcome.", nil })
    end
)

t.test("outcome refuses an N past the last outcome and a bad N", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    local result = commands.run("outcome", { "cccccccc", "--tick", "3" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("the card has 2 outcomes, so there is no outcome 3", 1, true))
    t.eq(
        commands.run("outcome", { "cccccccc", "--rename", "9", "x", "--reason", "y" }, backend).code,
        1
    )
    for _, word in ipairs({ "0", "-1", "x", "1.5" }) do
        t.eq(commands.run("outcome", { "cccccccc", "--tick", word }, backend).code, 2)
    end
    t.eq(#backend.calls, 0)
end)

t.test("outcome --rename without --reason is refused and changes nothing", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    local result = commands.run("outcome", { "cccccccc", "--rename", "1", "New" }, backend)
    t.eq(result.code, 2)
    t.ok(result.message:find("--rename needs --reason TEXT", 1, true), result.message)
    t.eq(
        commands.run("outcome", { "cccccccc", "--rename", "1", "New", "--reason" }, backend).code,
        2
    )
    t.eq(
        commands.run("outcome", { "cccccccc", "--rename", "1", "--reason", "why" }, backend).code,
        2
    )
    t.eq(#backend.calls, 0)
end)

t.test("outcome --rename ends the new text at the first --reason", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    local result = commands.run(
        "outcome",
        { "cccccccc", "--rename", "1", "New", "--reason", "use", "--reason", "flag" },
        backend
    )
    t.eq(result.output, "outcome cccccccc 1 reworded")
    t.eq(backend.calls[1], { "set_outcome", ID_C, "s1", { name = "New" }, nil })
    t.ok(backend.calls[2][3]:find("Reason: use --reason flag", 1, true), backend.calls[2][3])
end)

t.test("outcome --rename names the old text and the reason when the note fails", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local old = card.outcomes[2].name
    local backend = fake({ card })
    function backend:note()
        return nil, "board unavailable: cannot reach pomb"
    end
    local result =
        commands.run("outcome", { "cccccccc", "--rename", "2", "New", "--reason", "why" }, backend)
    t.eq(result.code, 1)
    t.eq(result.unqueued, true)
    t.ok(result.message:find("was renamed but the note failed", 1, true), result.message)
    t.ok(result.message:find(old, 1, true) and result.message:find("why", 1, true), result.message)
    result =
        commands.run("outcome", { "cccccccc", "--rename", "1", "New", "--reason", " " }, backend)
    t.eq(result.code, 2)
end)

t.test(
    "outcome --rename posts one decision note with the old text, the new text and the reason",
    function()
        local card = colored("green")
        card.outcomes = outcomes(2)
        local old = card.outcomes[2].name
        local backend = fake({ card })
        local result = commands.run(
            "outcome",
            { "cccccccc", "--rename", "2", "New", "words", "--reason", "it", "was", "vague" },
            backend
        )
        t.eq(result.output, "outcome cccccccc 2 reworded")
        t.eq(#backend.calls, 2)
        t.eq(backend.calls[2], {
            "note",
            ID_C,
            "Renamed outcome 2 from: " .. old .. " to: New words Reason: it was vague",
            { kind = "decision" },
        })
    end
)

t.test("outcome refuses missing arguments, blank text and a missing card", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    t.eq(commands.run("outcome", { "cccccccc" }, backend).code, 2)
    t.eq(commands.run("outcome", { "cccccccc", "--tick" }, backend).code, 2)
    t.eq(commands.run("outcome", { "cccccccc", "--tick", "1", "2" }, backend).code, 2)
    t.eq(commands.run("outcome", { "cccccccc", "--rename", "1" }, backend).code, 2)
    t.eq(commands.run("outcome", { "cccccccc", "   " }, backend).code, 2)
    t.eq(commands.run("outcome", { "deadbeef", "x" }, backend).code, 1)
    t.eq(#backend.calls, 0)
end)

t.test(
    "a claimant cannot tick its card's outcome, another name can, and untick stays open",
    function()
        local card = colored("green")
        card.outcomes = outcomes(2)
        card.claimant = "project-run/a"
        local backend = fake({ card })
        local result =
            commands.run("outcome", { "cccccccc", "--tick", "1", "--as", "project-run/a" }, backend)
        t.eq(result.code, 1)
        t.ok(result.message:find("claimed by project-run/a", 1, true), result.message)
        t.eq(#backend.calls, 0)
        result =
            commands.run("outcome", { "cccccccc", "--tick", "1", "--as", "project-run/b" }, backend)
        t.eq(result.output, "outcome cccccccc 1 ticked by project-run/b")
        t.eq(backend.calls[1], { "set_outcome", ID_C, "s1", { done = true }, nil })
        result = commands.run("outcome", { "cccccccc", "--untick", "1" }, backend)
        t.eq(result.output, "outcome cccccccc 1 unticked")
    end
)

local function as_agent(name, run)
    local previous = os.getenv("DEV_AGENT") or ""
    ffi.C.setenv("DEV_AGENT", name, 1)
    local ok, err = pcall(run)
    ffi.C.setenv("DEV_AGENT", previous, 1)
    assert(ok, err)
end

local function writes(backend)
    local calls = {}
    for _, call in ipairs(backend.calls) do
        if call[1] ~= "comments" then
            calls[#calls + 1] = call
        end
    end
    return calls
end

t.test("outcome delete refuses a name that is not a lead", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    for _, name in ipairs({ "dotfiles/implementer/95f0e009/1", "project-run/a" }) do
        as_agent(name, function()
            local result =
                commands.run("outcome", { "cccccccc", "--delete", "1", "--reason", "x" }, backend)
            t.eq(result.code, 1)
            t.ok(result.message:find("only the lead deletes an outcome", 1, true), result.message)
            t.ok(result.message:find(name, 1, true), result.message)
        end)
    end
    t.eq(#backend.calls, 0)
end)

t.test("outcome delete by a lead notes the reason and the text", function()
    for _, column in ipairs({ "Backlog", "Blocked", "Icebox" }) do
        local card = colored("green")
        card.column = column
        card.outcomes = outcomes(3)
        local backend = fake({ card })
        as_agent(LEAD, function()
            local result = commands.run(
                "outcome",
                { "cccccccc", "--delete", "2", "--reason", "never", "achievable" },
                backend
            )
            t.eq(result.output, "outcome cccccccc 2 deleted")
        end)
        local calls = writes(backend)
        t.eq(calls[1], { "delete_outcome", ID_C, "s2", nil })
        t.eq(
            calls[2][3],
            "Deleted outcome 2: " .. card.outcomes[2].name .. " Reason: never achievable"
        )
        t.eq(calls[2][4], { kind = "decision" })
    end
end)

local function delete_in(backend, id)
    local result
    as_agent(LEAD, function()
        result = commands.run(
            "outcome",
            { id, "--delete", "1", "--reason", "never", "achievable" },
            backend
        )
    end)
    return result
end

local function card_in(column)
    local card = colored("green")
    card.column = column
    card.outcomes = outcomes(2)
    return card
end

t.test("outcome delete refuses a card in a ready-role column", function()
    for _, column in ipairs({ "Ready", "In Progress", "Review", "Verify", "Release" }) do
        local backend = fake({ card_in(column) })
        local result = delete_in(backend, "cccccccc")
        t.eq(result.code, 1)
        t.ok(result.message:find(column, 1, true), result.message)
        t.ok(result.message:find("fixed from Ready on", 1, true), result.message)
        t.eq(result.unqueued, true)
        t.eq(#writes(backend), 0)
    end
end)

t.test("outcome delete refuses a card in a finished column", function()
    for _, column in ipairs({ "Done", "Archive" }) do
        local backend = fake({ card_in(column) }, nil, { "Done", "Archive" })
        local result = delete_in(backend, "cccccccc")
        t.eq(result.code, 1)
        t.ok(result.message:find(column, 1, true), result.message)
        t.eq(#writes(backend), 0)
    end
end)

t.test("outcome delete reads the renamed role columns", function()
    local map = { ready = "Next", progress = "Doing", review = "Looking", done = "Shipped" }
    for _, column in ipairs({ "Next", "Doing", "Looking", "Shipped" }) do
        local backend = fake({ card_in(column) }, nil, { "Shipped" })
        backend.column_map = map
        local result = delete_in(backend, "cccccccc")
        t.eq(result.code, 1, column)
        t.ok(result.message:find(column, 1, true), result.message)
        t.eq(#writes(backend), 0)
    end
    for _, column in ipairs({ "Ready", "In Progress" }) do
        local backend = fake({ card_in(column) }, nil, { "Shipped" })
        backend.column_map = map
        t.eq(delete_in(backend, "cccccccc").code, 1, column)
        t.eq(#writes(backend), 0)
    end
end)

t.test("outcome delete refuses an unmapped column", function()
    local backend = fake({ card_in("QA") })
    local result = delete_in(backend, "cccccccc")
    t.eq(result.code, 1)
    t.ok(result.message:find("QA", 1, true), result.message)
    t.ok(result.message:find("fixed from Ready on", 1, true), result.message)
    t.eq(result.unqueued, true)
    t.eq(#writes(backend), 0)
end)

t.test("outcome delete allows renamed blocked and backlog columns", function()
    local map = { blocked = "Parked", backlog = "Someday" }
    for _, column in ipairs({ "Parked", "parked", "SOMEDAY" }) do
        local backend = fake({ card_in(column) })
        backend.column_map = map
        t.eq(delete_in(backend, "cccccccc").output, "outcome cccccccc 1 deleted")
    end
    for _, column in ipairs({ "Blocked", "Backlog" }) do
        local backend = fake({ card_in(column) })
        backend.column_map = map
        t.eq(delete_in(backend, "cccccccc").code, 1, column)
        t.eq(#writes(backend), 0)
    end
end)

t.test("outcome delete is allowed in Blocked and Backlog", function()
    for _, column in ipairs({ "Blocked", "Backlog", "Icebox" }) do
        local backend = fake({ card_in(column) })
        t.eq(delete_in(backend, "cccccccc").output, "outcome cccccccc 1 deleted")
        local calls = writes(backend)
        t.eq(calls[1], { "delete_outcome", ID_C, "s1", nil })
        t.eq(calls[2][4], { kind = "decision" })
    end
end)

t.test("outcome delete by a lead needs a reason", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    as_agent(LEAD, function()
        t.eq(commands.run("outcome", { "cccccccc", "--delete", "1" }, backend).code, 2)
        t.eq(commands.run("outcome", { "cccccccc", "--delete", "1", "--reason" }, backend).code, 2)
        t.eq(
            commands.run("outcome", { "cccccccc", "--delete", "1", "--reason", "  " }, backend).code,
            2
        )
    end)
    as_agent("dotfiles/implementer/95f0e009/1", function()
        t.eq(commands.run("outcome", { "cccccccc", "--delete", "1" }, backend).code, 2)
    end)
    t.eq(#backend.calls, 0)
end)

t.test("outcome --delete by a lead needs a number, and a bad number deletes nothing", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    as_agent(LEAD, function()
        t.eq(commands.run("outcome", { "cccccccc", "--delete" }, backend).code, 2)
        t.eq(commands.run("outcome", { "cccccccc", "--delete", "1", "why" }, backend).code, 2)
        t.eq(
            commands.run("outcome", { "cccccccc", "--delete", "3", "--reason", "x" }, backend).code,
            1
        )
    end)
    t.eq(#writes(backend), 0)
end)

t.test("the claimant cannot delete an outcome under any name it is given", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    card.claimant = "project-run/a"
    local backend = fake({ card })
    as_agent(LEAD, function()
        local result = commands.run(
            "outcome",
            { "cccccccc", "--delete", "1", "--reason", "x", "--as", "project-run/a" },
            backend
        )
        t.eq(result.code, 1)
        t.ok(result.message:find("claimed by project-run/a", 1, true), result.message)
        t.ok(result.message:find("Pass the change back", 1, true), result.message)
        for _, call in ipairs(backend.calls) do
            t.eq(call[1], "comments")
        end
        result = commands.run(
            "outcome",
            { "cccccccc", "--delete", "1", "--reason", "x", "--as", "project-run/b" },
            backend
        )
        t.eq(result.output, "outcome cccccccc 1 deleted")
    end)
end)

local function released_by(name, claimant)
    local card = colored("green")
    card.claimant = claimant
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    backend.listed = { { id = COMMENT_1, who = "human", body = board.claim_record(name) } }
    return backend
end

t.test("a name that released the card cannot reclaim the finish line", function()
    local released = "project-run/a"
    local backend = released_by(released)
    as_agent(released, function()
        local runs = {
            { "outcome", { "cccccccc", "A", "new", "outcome" } },
            { "outcome", { "cccccccc", "--rename", "1", "New", "--reason", "x" } },
            { "checks", { "cccccccc", "dev test" } },
            { "outcome", { "cccccccc", "--convert" } },
        }
        for _, run in ipairs(runs) do
            local result = commands.run(run[1], run[2], backend)
            t.eq(result.code, 1, run[2][2])
            t.ok(result.message:find("was claimed by " .. released, 1, true), result.message)
        end
    end)
    for _, call in ipairs(backend.calls) do
        t.eq(call[1], "comments")
    end
end)

t.test("an --as name of a former claimant cannot reclaim the finish line", function()
    local released = "project-run/a"
    local backend = released_by(released)
    as_agent("project-run/b", function()
        local result =
            commands.run("outcome", { "cccccccc", "--convert", "--as", released }, backend)
        t.eq(result.code, 1)
        t.ok(result.message:find("was claimed by " .. released, 1, true), result.message)
    end)
    for _, call in ipairs(backend.calls) do
        t.eq(call[1], "comments")
    end
end)

t.test("a failed comments read refuses the reclaim check with its message", function()
    local backend = released_by("project-run/a")
    backend.listed_error = "comments are unavailable"
    as_agent("project-run/b", function()
        local result = commands.run("checks", { "cccccccc", "dev test" }, backend)
        t.eq(result.code, 1)
        t.eq(result.message, "comments are unavailable")
    end)
    for _, call in ipairs(backend.calls) do
        t.eq(call[1], "comments")
    end
end)

t.test("a name that never claimed the card and the lead can still change it", function()
    local backend = released_by("project-run/a")
    as_agent("project-run/b", function()
        t.eq(commands.run("checks", { "cccccccc", "dev test" }, backend).code, nil)
    end)
    as_agent("lead", function()
        local result = commands.run(
            "outcome",
            { "cccccccc", "--rename", "1", "New", "--reason", "x" },
            backend
        )
        t.eq(result.code, nil)
    end)
    backend = released_by("lead", "lead")
    as_agent("lead", function()
        local result = commands.run(
            "outcome",
            { "cccccccc", "--rename", "1", "New", "--reason", "x" },
            backend
        )
        t.eq(result.code, nil)
    end)
end)

t.test("review refuses the claimant for every kind and says a reviewer must record it", function()
    local card = colored("green")
    card.claimant = "project-run/a"
    local backend = fake({ card })
    for _, kind in ipairs({ "code", "style", "recheck" }) do
        local result = commands.run("review", {
            "cccccccc",
            "--kind",
            kind,
            "--by",
            "project-run/a",
            "--rev",
            "@",
            "--verdict",
            "clean",
        }, backend)
        t.eq(result.code, 1)
        t.ok(
            result.message:find(
                "is claimed by project-run/a, so project-run/a cannot review its own change",
                1,
                true
            ),
            result.message
        )
        t.ok(
            result.message:find("; a reviewer other than project-run/a must record it", 1, true),
            result.message
        )
    end
    for _, call in ipairs(backend.calls) do
        t.eq(call[1], "comments")
    end
end)

t.test("--as is read only on a tick or convert, and names one word", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    t.eq(commands.run("outcome", { "cccccccc", "--untick", "1", "--as", "x" }, backend).code, 2)
    t.eq(
        commands.run("outcome", { "cccccccc", "--tick", "1", "--as", "two words" }, backend).code,
        2
    )
    t.eq(#backend.calls, 0)
    local result = commands.run("outcome", { "cccccccc", "Text", "--as", "x" }, backend)
    t.eq(result.output, "outcome cccccccc 3 added")
    t.eq(backend.calls[1], { "add_outcome", ID_C, "Text --as x", nil })
end)

t.test("convert refuses a claimant's ticks but moves an unticked checklist", function()
    local card = colored("green")
    card.description = V1:gsub("%[ %]", "[x]")
    card.claimant = "project-run/a"
    local backend = fake({ card })
    local result =
        commands.run("outcome", { "cccccccc", "--convert", "--as", "project-run/a" }, backend)
    t.eq(result.code, 1)
    for _, call in ipairs(backend.calls) do
        t.eq(call[1], "comments")
    end
    card.description = V1
    result = commands.run("outcome", { "cccccccc", "--convert" }, backend)
    t.ok(not (result.message or ""):find("claimed", 1, true), result.message)
    t.eq(backend.calls[#backend.calls][1], "add_outcome")
end)

t.test("outcome warns about a path in the text and still writes", function()
    local card = colored("green")
    local backend = fake({ card })
    local result = commands.run("outcome", { "cccccccc", "see src/a.lua" }, backend)
    t.eq(result.warnings, { "card prose holds a path: src/a.lua" })
    t.eq(#backend.calls, 1)
end)

t.test("move into Icebox never checks the description", function()
    local card = colored("white")
    card.description = nil
    local backend = fake({ card })
    t.eq(commands.run("move", { "cccccccc", "icebox" }, backend).code, nil)
end)

t.test("move to Ready takes a sized card, and other columns take a planned one", function()
    for _, color in ipairs({ "yellow", "green", "blue" }) do
        local backend = fake({ colored(color) })
        t.eq(
            commands.run("move", { "cccccccc", "ready" }, backend).output,
            "moved cccccccc to Ready"
        )
    end
    for _, column in ipairs({ "backlog", "review", "blocked", "done" }) do
        local backend = fake({ colored("green") })
        t.eq(commands.run("move", { "cccccccc", column }, backend).code, nil)
        t.eq(#backend.calls, 1)
    end
    local backend = fake({ colored("white") })
    t.eq(commands.run("move", { "cccccccc", "icebox" }, backend).code, nil)
    t.eq(#backend.calls, 1)
end)

t.test("move and edit refuse a needs:human card, and label --remove still frees it", function()
    local cards = sample()
    cards[1].labels = { "needs:human" }
    local backend = fake(cards)
    local result = commands.run("move", { "11111111-a", "backlog" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("needs:human", 1, true), result.message)
    result = commands.run("edit", { "11111111-a", "text" }, backend)
    t.eq(result.code, 1)
    result = commands.run("rename", { "11111111-a", "text" }, backend)
    t.eq(result.code, 1)
    t.eq(#backend.calls, 0)
    t.eq(commands.run("note", { "11111111-a", "hello" }, backend).output, "noted 11111111")
    result = commands.run("label", { "11111111-a", "--remove", "needs:human" }, backend)
    t.eq(result.output, "labelled 11111111 -")
end)

local function blocked_cards()
    local cards = sample()
    cards[1].labels = { "needs:human", "docs" }
    cards[1].column = "Blocked"
    return cards
end

t.test("answer sends the choice and the quote to the backend and touches nothing else", function()
    local backend = fake(blocked_cards())
    local result = commands.run(
        "answer",
        { "11111111-a", "--choice", "2", "--quote", "go", "with", "two" },
        backend
    )
    t.eq(result.output, "answered 11111111 with choice 2")
    t.eq(backend.calls, { { "answer", ID_A, 2, "go with two", nil } })
end)

t.test("answer prints the backend's refusal and exits 1", function()
    local backend = fake(blocked_cards())
    backend.refusal = "pomb answered 409: the question is answered already"
    local result =
        commands.run("answer", { "11111111-a", "--choice", "1", "--quote", "yes" }, backend)
    t.eq(result.code, 1)
    t.eq(result.message, backend.refusal)
end)

t.test("ask sends the parts it was given and lets the backend refuse a missing one", function()
    local backend = fake(sample())
    local result = commands.run("ask", {
        "11111111-a",
        "--question",
        "Which?",
        "--choice",
        "Ready=Ship it",
        "--choice",
        "Icebox = Park it",
        "--recommend",
        "1",
    }, backend)
    t.eq(result.output, "asked 11111111")
    t.eq(backend.calls[1], {
        "ask",
        ID_A,
        {
            text = "Which?",
            choices = {
                { column = "Ready", label = "Ship it" },
                { column = "Icebox", label = "Park it" },
            },
            recommended = 1,
        },
        nil,
    })
end)

t.test("ask refuses a bad choice, a bad recommendation, an unknown flag and no card", function()
    local backend = fake(sample())
    for _, args in ipairs({
        { "11111111-a", "--choice", "no equals sign" },
        { "11111111-a", "--choice", "=label" },
        { "11111111-a", "--recommend", "x" },
        { "11111111-a", "--bogus", "x" },
        { "11111111-a", "--why" },
    }) do
        t.eq(commands.run("ask", args, backend).code, 2, table.concat(args, " "))
    end
    t.eq(commands.run("ask", {}, backend).code, 2)
    t.eq(#backend.calls, 0)
end)

t.test("answer refuses a card without needs:human and writes nothing", function()
    local cards = sample()
    local backend = fake(cards)
    local result =
        commands.run("answer", { "11111111-a", "--choice", "1", "--quote", "yes" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("is not needs:human", 1, true), result.message)
    t.eq(#backend.calls, 0)
end)

t.test("answer refuses an empty quote, a bad choice and missing flags", function()
    local backend = fake(blocked_cards())
    for _, args in ipairs({
        { "11111111-a", "--choice", "1", "--quote" },
        { "11111111-a", "--choice", "1", "--quote", "  " },
        { "11111111-a", "--choice", "0", "--quote", "yes" },
        { "11111111-a", "--choice", "x", "--quote", "yes" },
        { "11111111-a", "--quote", "yes" },
        { "11111111-a" },
    }) do
        t.eq(commands.run("answer", args, backend).code, 2, table.concat(args, " "))
    end
    t.eq(#backend.calls, 0)
end)

t.test("a needs:human card moves within its own column and not out of it", function()
    local cards = sample()
    cards[1].labels = { "needs:human" }
    cards[1].column = "Icebox"
    local backend = fake(cards)
    local result = commands.run("move", { "11111111-a", "icebox" }, backend)
    t.eq(result.output, "moved 11111111 to Icebox")
    t.eq(backend.calls, { { "move", ID_A, "Icebox" } })
    result = commands.run("move", { "11111111-a", "backlog" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("needs:human", 1, true), result.message)
    t.eq(#backend.calls, 1)
end)

local function column_of_three()
    local cards = sample()
    cards[2].column = "Ready"
    cards[3].column = "Ready"
    cards[3].labels = { "needs:human" }
    return cards
end

t.test("order moves the named cards to positions 0, 1, 2 and prints the column", function()
    local backend = fake(column_of_three())
    local result = commands.run("order", { "cccccccc", "11111111-a" }, backend)
    t.eq(result.code, nil)
    t.eq(backend.calls, { { "move", ID_C, "Ready", 0 }, { "move", ID_A, "Ready", 1 } })
    t.eq(
        result.output,
        table.concat({
            "cccccccc  Ready  unsized  needs:human  Old thing",
            "11111111  Ready  1 Pomodoro  docs  Write docs",
            "11111111  Ready  unsized  -  Fix lint",
        }, "\n")
    )
end)

t.test("order refuses cards of two columns, an unknown card and a card named twice", function()
    local cards = sample()
    local backend = fake(cards)
    local result = commands.run("order", { "11111111-a", "11111111-b", "cccccccc" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("one column", 1, true), result.message)
    result = commands.run("order", { "11111111-a", "deadbeef" }, backend)
    t.eq(result.code, 1)
    cards = column_of_three()
    backend = fake(cards)
    result = commands.run("order", { "11111111-a", "11111111-a" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("twice", 1, true), result.message)
    t.eq(commands.run("order", {}, backend).code, 2)
    t.eq(commands.run("order", { "--bogus" }, backend).code, 2)
    t.eq(#backend.calls, 0)
end)

t.test("label adds needs:human only to a card in Blocked or Icebox", function()
    local backend = fake(sample())
    local result = commands.run("label", { "11111111-a", "+needs:human" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("Blocked or Icebox", 1, true), result.message)
    t.eq(#backend.calls, 0)
    local added = commands.run("add", { "Idea", "--label", "needs:human" }, backend)
    t.eq(added.code, 2)
    t.eq(#backend.calls, 0)
    for _, column in ipairs({ "Blocked", "Icebox" }) do
        local cards = sample()
        cards[1].column = column
        backend = fake(cards)
        result = commands.run("label", { "11111111-a", "needs:human" }, backend)
        t.eq(result.output, "labelled 11111111 docs,needs:human")
    end
end)

t.test("move to Ready allows an epic and a card without children", function()
    local backend = fake({ colored("green") })
    backend.kin = { children = { done = 0, total = 2 } }
    local result = commands.run("move", { "cccccccc", "ready" }, backend)
    t.eq(result.output, "moved cccccccc to Ready")
    result = commands.run("move", { "cccccccc", "backlog" }, backend)
    t.eq(result.output, "moved cccccccc to Backlog")
end)

t.test("next shows the top card or says none", function()
    local result = commands.run("next", {}, fake(sample()))
    t.eq(result.output, "11111111  Ready  1 Pomodoro  docs  Write docs  0 comments, 0 the owner's")
    result = commands.run("next", {}, fake({}))
    t.eq(result.output, "no ready cards")
end)

t.test("next counts the comments of the card and how many are the owner's", function()
    local backend = fake(sample())
    backend.listed = {
        {
            id = COMMENT_1,
            who = "worker",
            actor = "agent",
            at = "2026-10-27T09:30:12Z",
            body = "a",
        },
        { id = COMMENT_2, who = "me", actor = "human", at = "2026-10-27T10:00:00Z", body = "b" },
    }
    local result = commands.run("next", {}, backend)
    t.eq(result.output, "11111111  Ready  1 Pomodoro  docs  Write docs  2 comments, 1 the owner's")
    backend.listed = { backend.listed[2] }
    result = commands.run("next", {}, backend)
    t.eq(result.output, "11111111  Ready  1 Pomodoro  docs  Write docs  1 comment, 1 the owner's")
    function backend:comments()
        return nil, "no comments for you"
    end
    result = commands.run("next", {}, backend)
    t.eq(result.code, 1)
    t.eq(result.message, "no comments for you")
end)

t.test("next --column takes Backlog or Icebox and refuses other columns", function()
    local backend = fake(sample())
    t.eq(commands.run("next", { "--column", "backlog" }, backend).message, nil)
    t.eq(commands.run("next", { "--column", "done" }, backend).code, 2)
    t.eq(commands.run("next", { "--column" }, backend).code, 2)
    t.eq(commands.run("next", { "extra" }, backend).code, 2)
    t.eq(commands.run("next", { "--column", "backlog" }, fake({})).output, "no cards in Backlog")
end)
t.test("next --column takes the Review, Verify and Release stage columns", function()
    for _, column in ipairs({ "Review", "Verify", "Release" }) do
        local backend = fake({})
        local result = commands.run("next", { "--column", column:lower() }, backend)
        t.eq(result.output, "no cards in " .. column)
        t.eq(backend.calls[#backend.calls], { "next", column, nil })
    end
    t.eq(commands.run("next", { "--column", "progress" }, fake({})).code, 2)
end)

local NOW = assert(box.parse_time("2026-10-27T12:00:00Z"))

local function aged(columns, days, labels)
    local cards, times = {}, {}
    for i, column in ipairs(columns) do
        local id = string.format("%08d-aaaa-4aaa-8aaa-aaaaaaaaaaaa", i)
        cards[i] = {
            id = id,
            name = "Card " .. i,
            column = column,
            size = "unsized",
            color = "green",
            labels = {},
            checks = {},
        }
        for _, label in ipairs(labels and labels[i] or {}) do
            cards[i].labels[#cards[i].labels + 1] = label
        end
        local at = NOW - days[i] * box.SECONDS_PER_DAY - (days[i] > 0 and 60 or 0)
        times[id] = os.date("!%Y-%m-%dT%H:%M:%S+00:00", at)
    end
    return cards, times
end

t.test("stale counts whole days, so 6 days is fresh and 7 is stale", function()
    local cards, times = aged({ "Ready", "Ready", "Ready" }, { 6, 7, 30 })
    cards[2].size = "2 Pomodori"
    local result = commands.run("stale", {}, fake(cards, times), NOW)
    t.eq(
        result.output,
        "00000003  Ready  30d  unsized     Card 3\n00000002  Ready  7d   2 Pomodori  Card 2"
    )
end)

t.test("stale counts a card entered just under the limit as fresh", function()
    local cards, times = aged({ "Ready" }, { 7 })
    times[cards[1].id] = os.date("!%Y-%m-%dT%H:%M:%SZ", NOW - 7 * box.SECONDS_PER_DAY + 1)
    t.eq(commands.run("stale", {}, fake(cards, times), NOW).output, "no stale cards")
end)

t.test("stale covers Backlog, Ready, In Progress, Review, Verify and Release only", function()
    local columns = {
        "Icebox",
        "Backlog",
        "Ready",
        "In Progress",
        "Review",
        "Verify",
        "Release",
        "Blocked",
        "Done",
    }
    local cards, times = aged(columns, { 5, 40, 40, 40, 40, 40, 40, 40, 40 })
    local result = commands.run("stale", {}, fake(cards, times), NOW)
    local lines = {}
    for line in result.output:gmatch("[^\n]+") do
        lines[#lines + 1] = line:match("^%d+%s+(%a+[ %a]-)%s%s")
    end
    t.eq(lines, { "Backlog", "Ready", "In Progress", "Review", "Verify", "Release" })
end)

t.test("stale marks a needs:human card whose newest comment is the owner's", function()
    local human = { "needs:human" }
    local cards, times = aged(
        { "Ready", "Blocked", "Blocked" },
        { 9, 20, 50 },
        { {}, human, human }
    )
    local backend = fake(cards, times)
    local replies = {
        [cards[2].id] = { { actor = "human", at = "2026-01-01T00:00:00Z", body = "yes" } },
        [cards[3].id] = { { actor = "agent", at = "2026-01-01T00:00:00Z", body = "wait" } },
    }
    function backend:comments(id)
        return replies[id] or {}
    end
    local output = commands.run("stale", {}, backend, NOW).output
    t.ok(output:find(cards[2].name .. " (answered, waiting for your move)", 1, true), output)
    t.ok(not output:find(cards[3].name .. " (answered", 1, true), output)
    function backend:comments()
        return nil, "pomb is down"
    end
    output = commands.run("stale", {}, backend, NOW).output
    t.ok(output:find("could not read the comments of " .. cards[2].id, 1, true), output)
end)

t.test("stale lists every needs:human card apart at any age, and never as stale", function()
    local human = { "needs:human" }
    local cards, times = aged(
        { "Ready", "Backlog", "Blocked", "Done", "Ready" },
        { 9, 20, 50, 60, 1 },
        { {}, human, human, human, human }
    )
    cards[2].color = nil
    local result = commands.run("stale", {}, fake(cards, times), NOW)
    t.eq(
        result.output,
        "00000001  Ready  9d  unsized  Card 1\n\nfor the owner (needs:human):\n"
            .. "00000003  Blocked  50d  unsized  Card 3\n\n"
            .. "moved by the owner, remove needs:human:\n"
            .. "00000002  Backlog  20d  unsized  Card 2\n"
            .. "00000005  Ready    1d   unsized  Card 5\n\nunsized outside Icebox:\n"
            .. "00000002  Backlog  Card 2"
    )
    cards, times = aged({ "Ready" }, { 9 }, { human })
    result = commands.run("stale", {}, fake(cards, times), NOW)
    t.eq(
        result.output,
        "no stale cards\n\nmoved by the owner, remove needs:human:\n00000001  Ready  9d  unsized  Card 1"
    )
end)

t.test("stale lists an unlabelled open card whose newest comment is the owner's", function()
    local cards, times = aged(
        { "Ready", "In Progress", "Blocked", "Done", "Ready" },
        { 1, 2, 3, 4, 10 }
    )
    local backend = fake(cards, times)
    local replies = {
        [cards[1].id] = { { actor = "human", at = "2026-01-01T00:00:00Z", body = "1" } },
        [cards[2].id] = {
            { actor = "human", at = "2026-01-01T00:00:00Z", body = "1" },
            { actor = "agent", at = "2026-01-02T00:00:00Z", body = "done" },
        },
        [cards[3].id] = { { actor = "human", at = "2026-01-01T00:00:00Z", body = "2" } },
        [cards[4].id] = { { actor = "human", at = "2026-01-01T00:00:00Z", body = "3" } },
        [cards[5].id] = { { actor = "human", at = "2026-01-01T00:00:00Z", body = "4" } },
    }
    function backend:comments(id)
        return replies[id] or {}
    end
    local output = commands.run("stale", {}, backend, NOW).output
    t.eq(
        output,
        "00000005  Ready  10d  unsized  Card 5\n\nnewest comment is the owner's:\n"
            .. "00000003  Blocked  3d  unsized  Card 3\n"
            .. "00000001  Ready    1d  unsized  Card 1"
    )
end)

t.test(
    "stale lists the unsized cards outside Icebox at any age and leaves sized ones out",
    function()
        local cards, times = aged(
            { "Backlog", "Backlog", "Backlog", "Ready", "Icebox", "Done" },
            { 0, 1, 2, 1, 1, 1 }
        )
        cards[1].color = nil
        cards[3].color = "white"
        cards[4].color = nil
        cards[5].color = nil
        cards[6].color = nil
        t.eq(
            commands.run("stale", {}, fake(cards, times), NOW).output,
            "no stale cards\n\nunsized outside Icebox:\n00000001  Backlog  Card 1\n00000003  Backlog  Card 3\n"
                .. "00000004  Ready    Card 4\n00000006  Done     Card 6"
        )
        cards[1].color = "red"
        cards[3].color = "blue"
        cards[4].color = "green"
        cards[6].color = "green"
        t.eq(commands.run("stale", {}, fake(cards, times), NOW).output, "no stale cards")
    end
)

t.test("stale names a card it could not date instead of skipping it", function()
    local human = { "needs:human" }
    local cards, times = aged(
        { "Ready", "Blocked", "Done", "Icebox", "Ready" },
        { 1, 1, 1, 1, 1 },
        { {}, human, human, {}, {} }
    )
    times[cards[1].id] = nil
    times[cards[2].id] = nil
    times[cards[3].id] = nil
    local result = commands.run("stale", {}, fake(cards, times), NOW)
    t.eq(
        result.output,
        "no stale cards\n\ncould not date "
            .. cards[1].id
            .. " Card 1\ncould not date "
            .. cards[2].id
            .. " Card 2"
    )
end)

t.test("stale --days moves the limit", function()
    local cards, times = aged({ "Ready", "Ready" }, { 2, 3 })
    local result = commands.run("stale", { "--days", "3" }, fake(cards, times), NOW)
    t.eq(result.output, "00000002  Ready  3d  unsized  Card 2")
    result = commands.run("stale", { "--days", "1" }, fake(cards, times), NOW)
    t.eq(
        result.output,
        "00000002  Ready  3d  unsized  Card 2\n00000001  Ready  2d  unsized  Card 1"
    )
end)

local function lead_cards()
    local lead, human = { "needs:lead" }, { "needs:lead", "needs:human" }
    local cards, times = aged(
        { "Blocked", "Blocked", "Blocked", "Ready", "Blocked", "Blocked" },
        { 0, 0, 0, 0, 0, 0 },
        { lead, lead, human, lead, lead, {} }
    )
    for index, hours in ipairs({ 3, 0.5, 5, 5, 7, 9 }) do
        local at = NOW - hours * box.SECONDS_PER_HOUR
        times[cards[index].id] = os.date("!%Y-%m-%dT%H:%M:%S+00:00", at)
    end
    return cards, times
end

t.test("stale lists a Blocked needs:lead card past an hour, oldest first", function()
    local cards, times = lead_cards()
    local result = commands.run("stale", {}, fake(cards, times), NOW)
    t.eq(
        result.output,
        "no stale cards\n\nfor the owner (needs:human):\n00000003  Blocked  0d  unsized  Card 3\n\n"
            .. "for a lead (needs:lead):\n00000005  Blocked  7h  unsized  Card 5\n"
            .. "00000001  Blocked  3h  unsized  Card 1"
    )
end)

t.test("stale --lead-hours moves the bound and refuses a bad value", function()
    local cards, times = lead_cards()
    local result = commands.run("stale", { "--lead-hours", "4" }, fake(cards, times), NOW)
    t.ok(
        result.output:find(
            "for a lead (needs:lead):\n00000005  Blocked  7h  unsized  Card 5",
            1,
            true
        )
    )
    t.ok(not result.output:find("Card 1", 1, true), result.output)
    for _, word in ipairs({ "0", "x", "1.5", "" }) do
        t.eq(commands.run("stale", { "--lead-hours", word }, fake({}), NOW).code, 2, word)
    end
    t.eq(commands.run("stale", { "--lead-hours" }, fake({}), NOW).code, 2)
end)

t.test("next --column blocked asks the backend for a needs:lead card", function()
    local backend = fake(sample())
    commands.run("next", { "--column", "blocked" }, backend)
    t.eq(backend.calls[1], { "next", "Blocked", "needs:lead" })
    backend = fake(sample())
    commands.run("next", {}, backend)
    t.eq(backend.calls[1], { "next", "Ready", nil })
    t.eq(commands.run("next", { "--column", "done" }, fake(sample())).code, 2)
end)

t.test("next --column blocked skips a needs:human card and a claimed one", function()
    local lead = { "needs:lead" }
    local cards = aged(
        { "Blocked", "Blocked", "Blocked", "Ready", "Blocked" },
        { 0, 0, 0, 0, 0 },
        { { "needs:lead", "needs:human" }, lead, lead, lead, lead }
    )
    cards[2].claimant = "someone"
    local result = commands.run("next", { "--column", "blocked" }, fake(cards))
    t.ok(result.output:find("00000003", 1, true), result.output)
    cards[3].claimant = "someone"
    cards[5].labels = {}
    t.eq(commands.run("next", { "--column", "blocked" }, fake(cards)).output, "no cards in Blocked")
end)

t.test("stale lists a Blocked needs:planner card apart from the lead ones", function()
    local planner = { "needs:planner" }
    local cards, times = aged(
        { "Blocked", "Blocked", "Blocked", "Ready" },
        { 0, 0, 0, 0 },
        { planner, { "needs:lead" }, { "needs:planner", "needs:human" }, planner }
    )
    for index, hours in ipairs({ 5, 3, 9, 9 }) do
        local at = NOW - hours * box.SECONDS_PER_HOUR
        times[cards[index].id] = os.date("!%Y-%m-%dT%H:%M:%S+00:00", at)
    end
    local result = commands.run("stale", {}, fake(cards, times), NOW)
    t.ok(
        result.output:find(
            "for a lead (needs:lead):\n00000002  Blocked  3h  unsized  Card 2",
            1,
            true
        ),
        result.output
    )
    t.ok(
        result.output:find(
            "for a planner (needs:planner):\n00000001  Blocked  5h  unsized  Card 1",
            1,
            true
        ),
        result.output
    )
    t.ok(not result.output:find("Card 4", 1, true), result.output)
    result = commands.run("stale", { "--lead-hours", "6" }, fake(cards, times), NOW)
    t.ok(not result.output:find("for a planner", 1, true), result.output)
end)

t.test("next --column blocked --for planner asks for a needs:planner card", function()
    local backend = fake(sample())
    commands.run("next", { "--column", "blocked", "--for", "planner" }, backend)
    t.eq(backend.calls[1], { "next", "Blocked", "needs:planner" })
    backend = fake(sample())
    commands.run("next", { "--column", "blocked", "--for", "lead" }, backend)
    t.eq(backend.calls[1], { "next", "Blocked", "needs:lead" })
    t.eq(commands.run("next", { "--for", "planner" }, fake(sample())).code, 2)
    t.eq(commands.run("next", { "--column", "blocked", "--for", "x" }, fake(sample())).code, 2)
end)

t.test("escalate posts the tier and reason to the endpoint", function()
    local cards = blocked_cards()
    cards[1].labels = { "needs:planner", "docs" }
    local backend = fake(cards)
    local result =
        commands.run("escalate", { "11111111-a", "outcome", "2", "is", "bogus" }, backend)
    t.eq(result.output, "escalated 11111111 to needs:lead")
    t.eq(backend.calls, { { "escalate", ID_A, "lead", "outcome 2 is bogus", nil } })
end)

t.test("escalate refuses a card without needs:planner and an empty reason", function()
    local backend = fake(blocked_cards())
    local result = commands.run("escalate", { "11111111-a", "why" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("is not needs:planner", 1, true), result.message)
    t.eq(commands.run("escalate", { "11111111-a" }, backend).code, 2)
    t.eq(commands.run("escalate", { "11111111-a", "  " }, backend).code, 2)
    t.eq(#backend.calls, 0)
end)

t.test("escalate refuses the ask flags and points to dev board ask", function()
    local cards = blocked_cards()
    cards[1].labels = { "needs:planner" }
    local backend = fake(cards)
    for _, flag in ipairs({ "--question", "--choice", "--recommend", "--why" }) do
        local result = commands.run("escalate", { "11111111-a", flag, "x" }, backend)
        t.eq(result.code, 2, flag)
        t.ok(result.message:find(flag, 1, true), result.message)
        t.ok(result.message:find("dev board ask", 1, true), result.message)
    end
    t.eq(commands.run("escalate", { "11111111-a", "--why=x" }, backend).code, 2)
    t.eq(#backend.calls, 0)
end)

t.test("escalate prints the refusal and writes nothing", function()
    local cards = blocked_cards()
    cards[1].labels = { "needs:planner" }
    local backend = fake(cards)
    backend.refusal = "pomb answered 403: card_locked"
    local result = commands.run("escalate", { "11111111-a", "why" }, backend)
    t.eq(result.code, 1)
    t.eq(result.message, "pomb answered 403: card_locked")
    t.eq(#backend.calls, 1)
    t.eq(backend.calls[1][1], "escalate")
end)

t.test("stale refuses a bad --days with a usage error", function()
    for _, word in ipairs({ "0", "-1", "x", "1.5", "" }) do
        local result = commands.run("stale", { "--days", word }, fake({}), NOW)
        t.eq(result.code, 2, word)
    end
    t.eq(commands.run("stale", { "--days" }, fake({}), NOW).code, 2)
    t.eq(commands.run("stale", { "extra" }, fake({}), NOW).code, 2)
end)

t.test("stale lists untouched Icebox cards", function()
    local human = { "needs:human" }
    local cards, times = aged(
        { "Icebox", "Icebox", "Icebox", "Icebox", "Icebox", "Ready" },
        { 45, 31, 29, 90, 60, 1 },
        { {}, {}, {}, {}, human, {} }
    )
    local backend = fake(cards, times)
    function backend:comments(id)
        if id == cards[2].id then
            return { { at = os.date("!%Y-%m-%dT%H:%M:%SZ", NOW - 2 * box.SECONDS_PER_DAY) } }
        end
        if id == cards[4].id then
            return { { at = os.date("!%Y-%m-%dT%H:%M:%SZ", NOW - 40 * box.SECONDS_PER_DAY) } }
        end
        return {}
    end
    t.eq(
        commands.run("stale", {}, backend, NOW).output,
        "no stale cards\n\nfor the owner (needs:human):\n"
            .. "00000005  Icebox  60d  unsized  Card 5\n\nicebox, untouched for 30 days:\n"
            .. "00000001  Icebox  45d  unsized  Card 1\n"
            .. "00000004  Icebox  40d  unsized  Card 4"
    )
    t.eq(
        commands.run("stale", { "--icebox-days", "10" }, backend, NOW).output,
        "no stale cards\n\nfor the owner (needs:human):\n"
            .. "00000005  Icebox  60d  unsized  Card 5\n\nicebox, untouched for 10 days:\n"
            .. "00000001  Icebox  45d  unsized  Card 1\n"
            .. "00000004  Icebox  40d  unsized  Card 4\n"
            .. "00000003  Icebox  29d  unsized  Card 3"
    )
end)

t.test("stale keeps its output when an Icebox card cannot be dated or its comments read", function()
    local cards, times = aged({ "Ready", "Icebox", "Icebox", "Icebox" }, { 9, 50, 50, 50 })
    times[cards[2].id] = nil
    local backend = fake(cards, times)
    function backend:comments(id)
        if id == cards[3].id then
            return nil, "boom"
        end
        return { { at = "later" } }
    end
    t.eq(
        commands.run("stale", {}, backend, NOW).output,
        "00000001  Ready  9d  unsized  Card 1\n\ncould not date "
            .. cards[2].id
            .. " Card 2\ncould not read the comments of "
            .. cards[3].id
            .. " Card 3\ncould not read the comments of "
            .. cards[4].id
            .. " Card 4"
    )
end)

t.test("stale counts an Icebox card exactly at the limit as untouched", function()
    local cards, times = aged({ "Icebox", "Icebox" }, { 30, 29 })
    t.eq(
        commands.run("stale", {}, fake(cards, times), NOW).output,
        "no stale cards\n\nicebox, untouched for 30 days:\n00000001  Icebox  30d  unsized  Card 1"
    )
end)

t.test("stale refuses a bad --icebox-days with a usage error", function()
    for _, word in ipairs({ "0", "-1", "x", "1.5", "" }) do
        t.eq(commands.run("stale", { "--icebox-days", word }, fake({}), NOW).code, 2, word)
    end
    t.eq(commands.run("stale", { "--icebox-days" }, fake({}), NOW).code, 2)
end)

t.test("stale says so when nothing is stale", function()
    t.eq(commands.run("stale", {}, fake({}), NOW).output, "no stale cards")
    local cards, times = aged({ "Ready" }, { 1 })
    t.eq(commands.run("stale", {}, fake(cards, times), NOW).output, "no stale cards")
end)

t.test("stale fails on a column time it cannot read", function()
    local cards = aged({ "Ready" }, { 9 })
    local result = commands.run("stale", {}, fake(cards, { [cards[1].id] = "yesterday" }), NOW)
    t.eq(result.code, 1)
end)

local BOARDS = '[{"id":"board-1","name":"dotfiles","archived":false}]'
local DETAIL = '{"id":"board-1","name":"dotfiles","swimlanes":[],"columns":['
    .. '{"id":"col-icebox","name":"Icebox"},{"id":"col-backlog","name":"Backlog"},'
    .. '{"id":"col-ready","name":"Ready"},{"id":"col-progress","name":"In Progress"},'
    .. '{"id":"col-review","name":"Review"},{"id":"col-blocked","name":"Blocked"},'
    .. '{"id":"col-done","name":"Done","is_done":true}]}'
local COLORS = '[{"id":"yellow-id","value":"yellow","label":"1 Pomodoro"},'
    .. '{"id":"green-id","value":"green","label":"Two"},{"id":"blue-id","value":"blue","label":"Three"},'
    .. '{"id":"red-id","value":"red","label":"More"},{"id":"white-id","value":"white","label":"Unsized"}]'
local EXPORT = '{"tasks":['
    .. '{"id":"'
    .. ID_B
    .. '","name":"Second","column_id":"col-ready","position":2,"color_id":null,"labels":[]},'
    .. '{"id":"'
    .. ID_A
    .. '","name":"First","column_id":"col-ready","position":1,"color_id":"yellow-id","labels":["docs"],"description":"Why it matters.","fields":{"dev.checks":[{"run":"dev test"},{"on":["local"],"run":"dev lint"}]}},'
    .. '{"id":"'
    .. ID_C
    .. '","name":"Early","column_id":"col-backlog","position":1,"color_id":"white-id","labels":[]}]}'
local PLANNED_TEXT =
    "## Problem\\nwhy\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone\\n\\n## Done when\\n- [%s] a"
local PLANNED_EXPORT = (EXPORT:gsub("Why it matters%.", (PLANNED_TEXT:format(" ")), 1))
local PLANNED_DONE_EXPORT = (EXPORT:gsub("Why it matters%.", (PLANNED_TEXT:format("x")), 1))
local COMMENTS = '[{"id":"aaaaaaaa-1111-4111-8111-111111111111","author":"api-token","actor_kind":"api_token",'
    .. '"token_name":"worker","created_at":"2026-10-27T09:30:12Z","body":"first\\nline"},'
    .. '{"id":"dddddddd-4444-4444-8444-444444444444","author":"x","actor_kind":"user",'
    .. '"token_name":null,"created_at":"2026-10-27T10:00:00Z","body":"mine? no"}]'
local TASK = '{"id":"'
    .. ID_A
    .. '","name":"First","column_id":"col-ready","color_id":"yellow-id","labels":["docs"]}'

local CURL = [[#!/bin/sh
printf 'curl %s\n' "$*" >>"$ROOT/calls"
cat >"$ROOT/stdin"
for last; do :; done
status=${HTTP_STATUS:-200}
case "$last" in
*/api/boards) body=$(cat "$ROOT/boards.json") ;;
*/api/boards/board-1) body=$(cat "$ROOT/detail.json") ;;
*/api/boards/board-2) body=$(cat "$ROOT/general.json") ;;
*/colors) body=$(cat "$ROOT/colors.json") ;;
*/fields) body=$(cat "$ROOT/fields.json") ;;
*/export-data) body=$(cat "$ROOT/export.json") ;;
*/tasks\?limit=500\&cursor=c2) body='{"items":[{"id":"]] .. ID_B .. [[","column_entered_at":"2020-02-01T00:00:00Z"}],"next_cursor":null}' ;;
*/tasks\?limit=500) body='{"items":[{"id":"]] .. ID_A .. [[","column_entered_at":"2020-01-01T00:00:00.5+00:00"}],"next_cursor":"c2"}' ;;
*/tasks\?*) body='{"items":[{"id":"]] .. ID_A .. [["}],"next_cursor":null}' ;;
*/api/tasks/]] .. ID_A .. [[)
    body=$(cat "$ROOT/task.json")
    case "$*" in
    *"-X PATCH"*)
        if [ -f "$ROOT/label_fail" ]; then
            body='{"message":"nope"}'
            status=400
        fi
        ;;
    *"-X DELETE"*)
        if [ -f "$ROOT/delete_body" ]; then
            body=$(cat "$ROOT/delete_body")
            status=403
        fi
        ;;
    esac
    ;;
*/api/tasks) body=$(cat "$ROOT/task.json") ;;
*/api/tasks/]] .. ID_C .. [[/links) body=$(cat "$ROOT/holder_links.json") ;;
*/links) body=$(cat "$ROOT/links.json") ;;
*/subtasks)
    body='{"id":"sub-1","name":"x","done":false}'
    n=$(cat "$ROOT/sub_n" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" >"$ROOT/sub_n"
    if [ -f "$ROOT/sub_fail" ] && [ "$n" = "$(cat "$ROOT/sub_fail")" ]; then
        body='{"message":"nope"}'
        status=400
    fi
    ;;
*/claim/heartbeat)
    body='{"ok":true}'
    if [ -f "$ROOT/hb_status" ]; then status=$(cat "$ROOT/hb_status"); fi
    ;;
*/claim/release) body= ;;
*/comments/dddddddd*)
    body='{"message":"not yours"}'
    status=403
    if [ -f "$ROOT/locked" ]; then body='{"code":"card_locked","message":"locked"}'; fi
    ;;
*/comments/*) body='{"ok":true}' ;;
*/comments)
    body=$(cat "$ROOT/comments.json")
    case "$*" in
    *"-X POST"*)
        if [ -f "$ROOT/locked" ]; then
            body='{"code":"card_locked","message":"locked"}'
            status=403
        fi
        if [ -f "$ROOT/ask_refusal" ]; then
            body=$(cat "$ROOT/ask_refusal")
            status=400
        fi
        ;;
    esac
    ;;
*/claim) body='{"fence":7,"claimant":"x"}' ;;
*) body='{"ok":true}' ;;
esac
printf '%s\n%s' "$body" "$status"
]]

local function curl_with(root, replacement)
    executable(root .. "/bin/curl", (CURL:gsub("%*/claim/release%) body= ;;", replacement, 1)))
end

local function queue_file(home)
    return home .. "/state/dev/boards/dotfiles.queue"
end

local function sandbox(opts)
    opts = opts or {}
    local root = support.sandbox({
        [".dev/config.toml"] = opts.project or '[board]\nbackend = "pomb"\nname = "dotfiles"\n',
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(
        fs.write(
            home .. "/.config/dev/config.toml",
            opts.user
                or '[board.pomb]\nurl = "https://pomb.example"\ntoken = "pass:secrets/worker/token/pomb"\n'
        )
    )
    for name, body in pairs({
        ["boards.json"] = BOARDS,
        ["detail.json"] = opts.detail or DETAIL,
        ["colors.json"] = COLORS,
        ["fields.json"] = opts.fields or support.FIELDS,
        ["export.json"] = opts.export or EXPORT,
        ["task.json"] = opts.task or TASK,
        ["comments.json"] = COMMENTS,
        ["links.json"] = opts.links or "[]",
        ["holder_links.json"] = opts.holder_links or "[]",
    }) do
        assert(fs.write(root .. "/" .. name, body))
    end
    executable(root .. "/bin/curl", CURL)
    executable(root .. "/bin/security", "#!/bin/sh\nexit 1\n")
    executable(root .. "/bin/sleep", "#!/bin/sh\nexec " .. devos.which("sleep") .. " 0.2\n")
    executable(
        root .. "/bin/pass",
        '#!/bin/sh\nprintf "pass %s opts=%s\\n" "$*" "$PASSWORD_STORE_GPG_OPTS" >>"$ROOT/calls"\n'
            .. (opts.locked and "exit 1\n" or ('echo "' .. TOKEN .. '"\n'))
    )
    return root, home
end

local function dev(root, home, args, opts)
    opts = opts or {}
    local env = {
        HOME = home,
        ROOT = root,
        XDG_STATE_HOME = home .. "/state",
        CI = "",
        DEV_AGENT = opts.agent or "",
        DEV_PASS_LOCK = root .. "/pass.lock",
    }
    for name, value in pairs(opts.env or {}) do
        env[name] = value
    end
    return support.dev(root, args, {
        env = env,
        split = opts.split,
        input = opts.input,
        cwd = opts.cwd,
    })
end

local function read(root, name)
    return fs.read(root .. "/" .. name) or ""
end

t.test("every subcommand without a [board] section says so and exits 1", function()
    local root, home = sandbox({ project = "" })
    for _, args in ipairs({ { "board", "status" }, { "board", "ls" }, { "board", "next" } }) do
        local out, code = dev(root, home, args)
        t.eq(out, "dev: no board for this project\n")
        t.eq(code, 1)
    end
    t.eq(read(root, "calls"), "")
end)

t.test("status prints the backend and the board without reaching out", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "status" })
    t.eq(out, "backend: pomb\nboard: dotfiles\n")
    t.eq(code, 0)
    t.eq(read(root, "calls"), "")
end)

t.test("boards lists every board the token sees and columns reads one by name", function()
    local boards = '[{"id":"board-1","name":"dotfiles","archived":false},'
        .. '{"id":"board-2","name":"General","archived":false}]'
    local root, home = sandbox()
    assert(fs.write(root .. "/boards.json", boards))
    assert(
        fs.write(
            root .. "/general.json",
            '{"id":"board-2","name":"General","swimlanes":[],"columns":['
                .. '{"id":"c1","name":"Todo"},{"id":"c2","name":"Doing"},'
                .. '{"id":"c3","name":"Finished","is_done":true}]}'
        )
    )
    local out, code = dev(root, home, { "board", "boards" })
    t.eq(code, 0, out)
    t.eq(out, "dotfiles\nGeneral\n")
    local columns = "Icebox\nBacklog\nReady\nIn Progress\nReview\nBlocked\nDone (done)\n"
    out, code = dev(root, home, { "board", "columns" })
    t.eq(code, 0, out)
    t.eq(out, columns)
    out, code = dev(root, home, { "board", "columns", "General" })
    t.eq(code, 0, out)
    t.eq(out, "Todo\nDoing\nFinished (done)\n")
    out, code = dev(root, home, { "board", "columns", "dotfiles" })
    t.eq(code, 0, out)
    t.eq(out, columns)
    out, code = dev(root, home, { "board", "columns", "nosuch" })
    t.eq(code, 1, out)
    t.ok(out:find("no board named nosuch", 1, true), out)
    out, code = dev(root, home, { "board", "columns", "dotfiles", "extra" })
    t.eq(code, 2, out)
end)

t.test("the board name defaults to the project directory", function()
    local root, home = sandbox({ project = '[board]\nbackend = "pomb"\n' })
    local out = dev(root, home, { "board", "status" })
    t.eq(out, "backend: pomb\nboard: " .. fs.basename(root) .. "\n")
end)

t.test("a local board that was never laid out says to run init", function()
    local root, home = sandbox({ project = '[board]\nbackend = "local"\n' })
    local out, code = dev(root, home, { "board", "ls" })
    t.ok(out:find(", run dev board init\n", 1, true), out)
    t.eq(code, 1)
    out, code = dev(root, home, { "board", "status" })
    t.eq(out, "backend: local\nboard: " .. fs.basename(root) .. "\n")
end)

t.test("an unknown backend is refused", function()
    local root, home = sandbox({ project = '[board]\nbackend = "jira"\n' })
    local out, code = dev(root, home, { "board", "status" })
    t.ok(out:find('must be "pomb" or "local"', 1, true), out)
    t.eq(code, 1)
end)

t.test("ls lists the cards in column order through pass and curl", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 0)
    t.eq(
        out,
        "cccccccc  Backlog  Unsized     -     Early\n"
            .. "11111111  Ready    1 Pomodoro  docs  First\n"
            .. "11111111  Ready    unsized     -     Second\n"
    )
    local calls = read(root, "calls")
    t.ok(
        calls:find(
            "pass show secrets/worker/token/pomb opts=--pinentry-mode error --batch",
            1,
            true
        ),
        calls
    )
    t.ok(calls:find("https://pomb.example/api/boards/board-1/export-data", 1, true), calls)
end)

t.test("the token reaches curl on stdin and nowhere else", function()
    local root, home = sandbox()
    local out = dev(root, home, { "-vv", "board", "ls" })
    t.eq(read(root, "stdin"), 'header = "Authorization: Bearer ' .. TOKEN .. '"\n')
    t.eq(out:find(TOKEN, 1, true), nil)
    t.eq(read(root, "calls"):find(TOKEN, 1, true), nil)
    t.ok(read(root, "calls"):find("-K -", 1, true), read(root, "calls"))
    out = dev(root, home, { "-v", "board", "move", "11111111-a", "done" })
    t.eq(out:find(TOKEN, 1, true), nil)
end)

t.test("the token is not in the environment curl or pass is started with", function()
    local root, home = sandbox()
    executable(root .. "/bin/curl", (CURL:gsub("cat >", 'env >"$ROOT/env"\ncat >', 1)))
    dev(root, home, { "board", "ls" })
    t.eq(read(root, "env"):find(TOKEN, 1, true), nil)
end)

t.test("a locked store fails at once and curl never runs", function()
    local root, home = sandbox({ locked = true })
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("board unavailable: pass is locked", 1, true), out)
    t.eq(read(root, "calls"):find("curl", 1, true), nil)
end)

local SHARE = devos.capture({ "pwd" }):gsub("\n$", "") .. "/dotfiles/bin/.local/share/dev/board/"

local function pass_stub(root, lock)
    executable(
        root .. "/bin/pass",
        "#!/bin/sh\n"
            .. 'echo "start $$ held=$([ -d "'
            .. lock
            .. '" ] && echo 1 || echo 0)" >>"$ROOT/events"\n'
            .. "sleep 1\n"
            .. 'echo "end $$" >>"$ROOT/events"\n'
            .. 'echo "'
            .. TOKEN
            .. '"\n'
    )
end

local function shell(root, lock, script, polls)
    return devos.capture({ "sh", "-c", script }, {
        env = {
            PATH = root .. "/bin:" .. os.getenv("PATH"),
            ROOT = root,
            DEV_PASS_LOCK = lock,
            DEV_PASS_LOCK_POLLS = polls or "600",
        },
        stderr = "stdout",
    })
end

t.test("concurrent pass reads queue on one lock and none times out", function()
    local root = sandbox()
    local lock = root .. "/pass.lock"
    pass_stub(root, lock)
    local cmd = "bash " .. SHARE .. "passlock.sh Agents/x"
    local out = shell(root, lock, "(" .. cmd .. ") & (" .. cmd .. ") & (" .. cmd .. ") & wait")
    t.eq(select(2, out:gsub(TOKEN, "")), 3, out)
    local order = {}
    for kind in read(root, "events"):gmatch("(%a+) %d+") do
        order[#order + 1] = kind
    end
    t.eq(order, { "start", "end", "start", "end", "start", "end" })
    t.eq(fs.read(lock .. "/pid"), nil)
end)

t.test("a lock left by a killed process does not block a later read", function()
    local root = sandbox()
    local lock = root .. "/pass.lock"
    pass_stub(root, lock)
    local out = shell(
        root,
        lock,
        "sh -c 'exit 0' & dead=$!; wait $dead; mkdir "
            .. lock
            .. "; echo $dead >"
            .. lock
            .. "/pid; bash "
            .. SHARE
            .. "passlock.sh Agents/x; echo code=$?",
        "50"
    )
    t.ok(out:find(TOKEN, 1, true), out)
    t.ok(out:find("code=0", 1, true), out)
end)

t.test("an old lock is taken over even when its pid is alive again", function()
    local root = sandbox()
    local lock = root .. "/pass.lock"
    pass_stub(root, lock)
    local out = shell(
        root,
        lock,
        "/bin/sleep 20 & holder=$!; mkdir "
            .. lock
            .. "; echo 0 >"
            .. lock
            .. "/at; echo $holder >"
            .. lock
            .. "/pid; bash "
            .. SHARE
            .. "passlock.sh Agents/x; echo code=$?; kill $holder",
        "50"
    )
    t.ok(out:find(TOKEN, 1, true), out)
    t.ok(out:find("code=0", 1, true), out)
end)

t.test("a lock with no owner is taken over after a short wait", function()
    local root = sandbox()
    local lock = root .. "/pass.lock"
    pass_stub(root, lock)
    local out = shell(
        root,
        lock,
        "mkdir " .. lock .. "; bash " .. SHARE .. "passlock.sh Agents/x; echo code=$?",
        "100"
    )
    t.ok(out:find(TOKEN, 1, true), out)
    t.ok(out:find("code=0", 1, true), out)
end)

t.test("a lock held by a live process times out with 124", function()
    local root = sandbox()
    local lock = root .. "/pass.lock"
    pass_stub(root, lock)
    local out = shell(
        root,
        lock,
        "/bin/sleep 20 & holder=$!; mkdir "
            .. lock
            .. "; date +%s >"
            .. lock
            .. "/at; echo $holder >"
            .. lock
            .. "/pid; bash "
            .. SHARE
            .. "passlock.sh Agents/x; echo code=$?; kill $holder",
        "3"
    )
    t.ok(out:find("code=124", 1, true), out)
    t.eq(out:find(TOKEN, 1, true), nil)
end)

t.test("a process reads each pass entry once", function()
    local root, home = sandbox()
    local script = string.format(
        "package.path = %q; local pomb = require('dev.board.pomb'); "
            .. "local a = pomb.token('pass:secrets/worker/token/pomb'); "
            .. "local b = pomb.token('pass:secrets/worker/token/pomb'); "
            .. "print(a == b and a ~= nil)",
        support.absolute_path()
    )
    local out, code = devos.capture({ "luajit", "-e", script }, {
        env = {
            PATH = root .. "/bin:" .. os.getenv("PATH"),
            HOME = home,
            ROOT = root,
            DEV_PASS_LOCK = root .. "/pass.lock",
        },
        stderr = "stdout",
    })
    t.eq(code, 0, out)
    t.eq(out, "true\n")
    t.eq(select(2, read(root, "calls"):gsub("pass show", "")), 1)
end)

local SECURITY = [[#!/bin/sh
printf 'security %s\n' "$*" >>"$ROOT/seccalls"
case "$1" in
find-generic-password)
    [ -f "$ROOT/kc" ] || exit 44
    cat "$ROOT/kc"
    ;;
-i)
    read -r line
    service=${line#*-s \"}
    printf 'put %s\n' "${service%%\"*}" >>"$ROOT/seccalls"
    token=${line##*-w \"}
    printf '%s\n' "${token%\"}" >"$ROOT/kc"
    ;;
delete-generic-password)
    rm -f "$ROOT/kc"
    ;;
esac
]]

local function with_security(root, body)
    executable(root .. "/bin/security", body or SECURITY)
end

local function passlock_once(root, entry)
    return shell(
        root,
        root .. "/pass.lock",
        "bash " .. SHARE .. "passlock.sh " .. (entry or "Agents/x") .. "; echo code=$?"
    )
end

local function occurrences(text, word)
    return select(2, text:gsub(word, ""))
end

t.test("a pass read is stored in the Keychain and the next read skips pass", function()
    local root = sandbox()
    with_security(root)
    local out = passlock_once(root)
    t.eq(out, TOKEN .. "\ncode=0\n")
    t.eq(read(root, "kc"), TOKEN .. "\n")
    out = passlock_once(root)
    t.eq(out, TOKEN .. "\nkeychain\ncode=0\n")
    t.eq(occurrences(read(root, "calls"), "pass show"), 1)
end)

t.test("the token is in no argument list handed to security", function()
    local root = sandbox()
    with_security(root)
    passlock_once(root)
    passlock_once(root)
    local seen = read(root, "seccalls")
    t.ok(seen:find("security -i", 1, true), seen)
    t.eq(seen:find(TOKEN, 1, true), nil)
end)

t.test("each pass entry has its own Keychain item", function()
    local root = sandbox()
    with_security(root)
    passlock_once(root, "Agents/x")
    assert(os.remove(root .. "/kc"))
    passlock_once(root, "Agents/y")
    local seen = read(root, "seccalls")
    t.ok(seen:find("put dev-pomb-token:Agents/x\n", 1, true), seen)
    t.ok(seen:find("put dev-pomb-token:Agents/y\n", 1, true), seen)
    t.ok(seen:find(" -s dev-pomb-token:Agents/y -w\n", 1, true), seen)
end)

t.test("a failing Keychain falls back to pass and never fails the read", function()
    local root = sandbox()
    with_security(root, "#!/bin/sh\nexit 1\n")
    t.eq(passlock_once(root), TOKEN .. "\ncode=0\n")
    t.eq(passlock_once(root), TOKEN .. "\ncode=0\n")
    t.eq(occurrences(read(root, "calls"), "pass show"), 2)
end)

t.test("a Keychain item that is not plain text is ignored", function()
    local root = sandbox()
    with_security(root)
    assert(fs.write(root .. "/kc", "bad token; evil\n"))
    t.eq(passlock_once(root), TOKEN .. "\ncode=0\n")
    t.eq(occurrences(read(root, "calls"), "pass show"), 1)
end)

t.test("a read that finds the Keychain filled after the lock releases the lock", function()
    local root = sandbox()
    with_security(
        root,
        "#!/bin/sh\n"
            .. 'if [ "$1" = find-generic-password ]; then\n'
            .. '    if [ -f "$ROOT/seen" ]; then echo "'
            .. TOKEN
            .. '"; exit 0; fi\n'
            .. '    : >"$ROOT/seen"; exit 44\n'
            .. "fi\n"
    )
    t.eq(passlock_once(root), TOKEN .. "\nkeychain\ncode=0\n")
    t.eq(occurrences(read(root, "calls"), "pass show"), 0)
    t.eq(fs.read(root .. "/pass.lock/pid"), nil)
    t.eq(fs.exists(root .. "/pass.lock"), false)
end)

t.test("dropping an item that is already gone succeeds and a failing delete does not", function()
    local root = sandbox()
    local drop = "bash " .. SHARE .. "keychain.sh drop Agents/x; echo code=$?"
    with_security(root, "#!/bin/sh\nexit 44\n")
    t.eq(shell(root, root .. "/pass.lock", drop), "code=0\n")
    with_security(root, "#!/bin/sh\nexit 1\n")
    t.eq(shell(root, root .. "/pass.lock", drop), "code=1\n")
end)

t.test("a refused pass read stores nothing", function()
    local root = sandbox({ locked = true })
    with_security(root)
    t.ok(passlock_once(root):find("code=1", 1, true))
    t.eq(fs.read(root .. "/kc"), nil)
end)

t.test("a cached token Pomb refuses is dropped and read again from pass once", function()
    local root, home = sandbox()
    with_security(root)
    assert(fs.write(root .. "/kc", OLD_TOKEN .. "\n"))
    executable(root .. "/bin/curl_real", CURL)
    executable(
        root .. "/bin/curl",
        "#!/bin/sh\n"
            .. 'cat >"$ROOT/in"\n'
            .. 'printf "curl %s\\n" "$*" >>"$ROOT/calls"\n'
            .. 'if grep -q "'
            .. OLD_TOKEN
            .. '" "$ROOT/in"; then printf \'{"message":"bad"}\\n401\'; exit 0; fi\n'
            .. 'exec "$ROOT/bin/curl_real" "$@" <"$ROOT/in"\n'
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 0, out)
    t.eq(occurrences(read(root, "calls"), "pass show"), 1)
    t.ok(read(root, "seccalls"):find("delete-generic-password", 1, true), read(root, "seccalls"))
    t.eq(read(root, "kc"), TOKEN .. "\n")
end)

t.test("a cached token Pomb refuses stays reported when the delete fails", function()
    local root, home = sandbox()
    with_security(root, SECURITY:gsub('rm %-f "%$ROOT/kc"', "exit 1", 1))
    assert(fs.write(root .. "/kc", OLD_TOKEN .. "\n"))
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\ncat >/dev/null\nprintf \'{"message":"bad"}\\n401\'\n'
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("pomb answered 401", 1, true), out)
    t.eq(occurrences(read(root, "calls"), "pass show"), 0)
end)

t.test("a token read fresh from pass that Pomb refuses is not retried", function()
    local root, home = sandbox()
    with_security(root)
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\ncat >/dev/null\nprintf \'curl %s\\n\' "$*" >>"$ROOT/calls"\n'
            .. 'printf \'{"message":"bad"}\\n401\'\n'
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("pomb answered 401", 1, true), out)
    t.eq(occurrences(read(root, "calls"), "pass show"), 1)
end)

t.test("the keep-alive loop drops a refused cached token", function()
    local root = sandbox()
    with_security(root)
    assert(fs.write(root .. "/kc", OLD_TOKEN .. "\n"))
    assert(fs.write(root .. "/state", "fence=7\n"))
    executable(root .. "/bin/curl", "#!/bin/sh\ncat >/dev/null\nprintf 401\n")
    shell(
        root,
        root .. "/pass.lock",
        "bash "
            .. SHARE
            .. "keepalive.sh "
            .. root
            .. "/state card 7 3 https://pomb.example Agents/x 0",
        "600"
    )
    t.ok(read(root, "seccalls"):find("delete-generic-password", 1, true), read(root, "seccalls"))
    t.eq(occurrences(read(root, "calls"), "pass show"), 1)
end)

t.test("the keep-alive loop reads the token under the same lock", function()
    local root = sandbox()
    local lock = root .. "/pass.lock"
    pass_stub(root, lock)
    assert(fs.write(root .. "/state", "fence=7\n"))
    local out = shell(
        root,
        lock,
        "bash "
            .. SHARE
            .. "keepalive.sh "
            .. root
            .. "/state card 7 1 https://pomb.example Agents/x 0",
        "600"
    )
    t.ok(read(root, "events"):find("held=1", 1, true), out .. read(root, "events"))
end)

t.test("a token that is not plain text is refused without echoing it", function()
    local root, home = sandbox()
    executable(root .. "/bin/pass", "#!/bin/sh\necho 'bad token\"; evil'\n")
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("empty or not plain text", 1, true), out)
    t.eq(out:find("evil", 1, true), nil)
end)

t.test("a project config cannot choose the server or the token", function()
    local root, home = sandbox({
        project = '[board]\nbackend = "pomb"\nname = "dotfiles"\n'
            .. '[board.pomb]\nurl = "https://evil.example"\ntoken = "pass:Other/entry"\n',
    })
    dev(root, home, { "board", "ls" })
    local calls = read(root, "calls")
    t.eq(calls:find("evil", 1, true), nil)
    t.eq(calls:find("Other/entry", 1, true), nil)
    t.ok(calls:find("pomb.example", 1, true), calls)
end)

t.test("a missing user url or token reference is a plain error", function()
    local root, home = sandbox({ user = "" })
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("[board.pomb] url", 1, true), out)
    root, home =
        sandbox({ user = '[board.pomb]\nurl = "https://pomb.example"\ntoken = "$(pass x)"\n' })
    out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("pass:<entry>", 1, true), out)
    t.eq(read(root, "calls"), "")
end)

t.test("an http error reports the server's message", function()
    local root, home = sandbox()
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\ncat >/dev/null\nprintf \'{"code":"x","message":"nope"}\\n403\'\n'
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("board unavailable: pomb answered 403: nope", 1, true), out)
end)

t.test("an unreachable server reports the curl exit", function()
    local root, home = sandbox()
    executable(root .. "/bin/curl", "#!/bin/sh\ncat >/dev/null\nexit 7\n")
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(
        out:find("board unavailable: cannot reach https://pomb.example (curl exit 7)", 1, true),
        out
    )
end)

local SUBTASKS_EXPORT = '{"tasks":['
    .. '{"id":"'
    .. ID_A
    .. '","name":"First","column_id":"col-ready","position":1,"color_id":"yellow-id","labels":["docs"],"description":"## Problem\\nWhy.\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone",'
    .. '"subtasks":[{"id":"sub-a","name":"A works","done":false},{"id":"sub-b","name":"B works","done":true}]}]}'

local BACKLOG_EXPORT = (SUBTASKS_EXPORT:gsub("col%-ready", "col-backlog"))

t.test("outcome posts a subtask and patches the Nth by its id", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    local out, code = dev(root, home, { "board", "outcome", "11111111", "C works" })
    t.eq(code, 0, out)
    t.eq(out, "outcome 11111111 3 added\n")
    out, code = dev(root, home, { "board", "outcome", "11111111", "--tick", "1" })
    t.eq(out, "outcome 11111111 1 ticked\n")
    out = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--rename", "2", "B holds", "--reason", "clearer" }
    )
    t.eq(out, "outcome 11111111 2 reworded\n")
    out = dev(root, home, { "board", "outcome", "11111111", "--untick", "2" })
    t.eq(out, "outcome 11111111 2 unticked\n")
    local calls = read(root, "calls")
    t.ok(
        calls:find("-X POST", 1, true) and calls:find("/api/tasks/" .. ID_A .. "/subtasks", 1, true),
        calls
    )
    t.ok(calls:find('--data-raw {"name":"C works"}', 1, true), calls)
    t.ok(calls:find("-X PATCH", 1, true), calls)
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/subtasks/sub-a", 1, true), calls)
    t.ok(calls:find('--data-raw {"done":true}', 1, true), calls)
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/subtasks/sub-b", 1, true), calls)
    t.ok(calls:find('--data-raw {"name":"B holds"}', 1, true), calls)
    t.ok(calls:find('--data-raw {"done":false}', 1, true), calls)
end)

t.test("a claimed card's tick needs a name other than the claimant's", function()
    local claimed = (
        SUBTASKS_EXPORT:gsub(
            '"position":1,',
            '"position":1,"claim":{"claimant":"project-run/a","expires_at":"2999-01-01T00:00:00Z"},',
            1
        )
    )
    local root, home = sandbox({ export = claimed })
    local out, code = dev(root, home, { "board", "outcome", "11111111", "--tick", "1" })
    t.eq(code, 2, out)
    t.ok(out:find("needs the ticker's name", 1, true), out)
    out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--tick", "1" },
        { agent = "project-run/a" }
    )
    t.eq(code, 1, out)
    t.ok(out:find("claimed by project-run/a", 1, true), out)
    t.eq(read(root, "calls"):find('--data-raw {"done":true}', 1, true), nil)
    out, code = dev(root, home, { "board", "outcome", "11111111", "--untick", "2" })
    t.eq(out, "outcome 11111111 2 unticked\n", out)
    t.ok(read(root, "calls"):find('--data-raw {"done":false}', 1, true), out)
    out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--tick", "1" },
        { agent = "project-run/b" }
    )
    t.eq(code, 0, out)
    t.eq(out, "outcome 11111111 1 ticked by project-run/b\n", out)
    t.ok(read(root, "calls"):find('--data-raw {"done":true}', 1, true), out)
end)

t.test("the claimant named by DEV_AGENT cannot delete or reword its outcome", function()
    local claimed = (
        BACKLOG_EXPORT:gsub(
            '"position":1,',
            '"position":1,"claim":{"claimant":"project-run/a","expires_at":"2999-01-01T00:00:00Z"},',
            1
        )
    )
    local root, home = sandbox({ export = claimed, user = LEAD_USER })
    local own = { agent = "project-run/a" }
    local out, code = dev(root, home, {
        "board",
        "outcome",
        "11111111",
        "--delete",
        "1",
        "--reason",
        "x",
        "--as",
        "project-run/a",
    }, { agent = LEAD })
    t.eq(code, 1, out)
    t.ok(out:find("claimed by project-run/a", 1, true), out)
    out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--rename", "1", "New", "--reason", "r" },
        own
    )
    t.eq(code, 1, out)
    t.ok(out:find("claimed by project-run/a", 1, true), out)
    t.eq(read(root, "calls"):find("-X DELETE", 1, true), nil)
    t.eq(read(root, "calls"):find("-X PATCH", 1, true), nil)
    out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--delete", "2", "--reason", "never possible" },
        { agent = LEAD }
    )
    t.eq(code, 0, out)
    t.eq(out, "outcome 11111111 2 deleted\n")
    local calls = read(root, "calls")
    t.ok(calls:find("-X DELETE", 1, true), calls)
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/subtasks/sub-b", 1, true), calls)
    t.ok(calls:find("Deleted outcome 2: B works Reason: never possible", 1, true), calls)
end)

t.test("a refused outcome delete prints Pomb's reason, writes no note and is not queued", function()
    local cases = {
        {
            body = '{"code":"permission_denied","permission":"subtasks.delete","message":"denied"}',
            want = "needs subtasks.delete, which only the lead token holds",
        },
        {
            body = '{"code":"permission_denied","permission":"subtasks.delete","board_id":"board-9","message":"denied"}',
            want = "Set [board.pomb] lead_token",
        },
        {
            body = '{"code":"permission_denied","permission":"subtasks.edit","message":"denied"}',
            want = "lacks the subtasks.edit permission",
        },
        {
            body = '{"code":"card_locked","message":"this task carries a locking label, so only the owner can change it"}',
            want = "pomb locked this card while it is labelled needs:human",
        },
    }
    for _, case in ipairs(cases) do
        local root, home = sandbox({ export = BACKLOG_EXPORT, user = LEAD_USER })
        executable(
            root .. "/bin/curl",
            "#!/bin/sh\nfor last; do :; done\ncase \"$last\" in */subtasks/*) cat >/dev/null; printf '%s\\n403' '"
                .. case.body
                .. "'; exit 0 ;; esac\n"
                .. CURL:gsub("^#!/bin/sh\n", "")
        )
        local out, code = dev(
            root,
            home,
            { "board", "outcome", "11111111", "--delete", "2", "--reason", "never possible" }
        )
        t.eq(code, 1, out)
        t.ok(out:find(case.want, 1, true), out)
        t.eq(read(root, "calls"):find("/comments", 1, true), nil)
        t.eq(fs.exists(queue_file(home)), false)
    end
end)

local WORK_SECRET = "pomb_WORKtoken0123456789"
local LEAD_SECRET = "pomb_LEADtoken0123456789"
local ISSUED_SECRET = "pomb_ISSUEDtoken0123456789"

local function two_tokens(root)
    executable(
        root .. "/bin/pass",
        '#!/bin/sh\nprintf "pass %s\\n" "$*" >>"$ROOT/calls"\ncase "$*" in\n*Lead*) echo '
            .. LEAD_SECRET
            .. " ;;\n*) echo "
            .. WORK_SECRET
            .. " ;;\nesac\n"
    )
    executable(
        root .. "/bin/curl",
        (
            CURL:gsub(
                'cat >"$ROOT/stdin"\n',
                'cat >"$ROOT/stdin"\ncase "$*" in *"-X DELETE"*) cp "$ROOT/stdin" "$ROOT/delete_stdin" ;; esac\n',
                1
            )
        )
    )
end

t.test("outcome delete on a pomb board sends the DELETE with the lead token", function()
    local root, home = sandbox({ export = BACKLOG_EXPORT, user = LEAD_USER })
    two_tokens(root)
    local out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--delete", "2", "--reason", "never possible" },
        { agent = LEAD, env = { DEV_BOARD_TOKEN = ISSUED_SECRET } }
    )
    t.eq(code, 0, out)
    t.eq(out, "outcome 11111111 2 deleted\n")
    local sent = read(root, "delete_stdin")
    t.ok(sent:find("Bearer " .. LEAD_SECRET, 1, true), "the DELETE did not carry the lead token")
    t.eq(sent:find(WORK_SECRET, 1, true), nil)
    t.eq(sent:find(ISSUED_SECRET, 1, true), nil)
end)

t.test("outcome delete with no lead token exits 1 naming subtasks.delete", function()
    local root, home = sandbox({ export = BACKLOG_EXPORT })
    local out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--delete", "2", "--reason", "never possible" },
        { agent = LEAD }
    )
    t.eq(code, 1, out)
    t.ok(out:find("lead_token is not set", 1, true), out)
    t.ok(out:find("subtasks.delete", 1, true), out)
    t.eq(read(root, "calls"), "")
    t.eq(fs.exists(queue_file(home)), false)
end)

t.test("a 403 on outcome delete names subtasks.delete and the lead token", function()
    local root, home = sandbox({ export = BACKLOG_EXPORT, user = LEAD_USER })
    executable(
        root .. "/bin/curl",
        "#!/bin/sh\nfor last; do :; done\ncase \"$last\" in */subtasks/*) cat >/dev/null; printf '%s\\n403' '"
            .. '{"code":"permission_denied","permission":"subtasks.delete","board_id":"board-1","message":"denied"}'
            .. "'; exit 0 ;; esac\n"
            .. CURL:gsub("^#!/bin/sh\n", "")
    )
    local out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--delete", "2", "--reason", "never possible" },
        { agent = LEAD }
    )
    t.eq(code, 1, out)
    t.ok(out:find("subtasks.delete", 1, true), out)
    t.ok(out:find("lead token", 1, true), out)
    t.eq(read(root, "calls"):find("-X POST", 1, true), nil)
    t.eq(fs.exists(queue_file(home)), false)
end)

t.test(
    "outcome delete refuses a non-lead name before any request and a locked column before the DELETE",
    function()
        local root, home = sandbox({ export = SUBTASKS_EXPORT, user = LEAD_USER })
        local out, code = dev(
            root,
            home,
            { "board", "outcome", "11111111", "--delete", "1", "--reason", "x" },
            { agent = "dotfiles/implementer/82f0e002/1" }
        )
        t.eq(code, 1, out)
        t.ok(out:find("only the lead deletes an outcome", 1, true), out)
        t.eq(read(root, "calls"), "")
        out, code = dev(
            root,
            home,
            { "board", "outcome", "11111111", "--delete", "1", "--reason", "x" },
            { agent = LEAD }
        )
        t.eq(code, 1, out)
        t.eq(read(root, "calls"):find("-X DELETE", 1, true), nil)
    end
)

t.test("outcome past the last subtask exits 1 and changes nothing", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    local out, code = dev(root, home, { "board", "outcome", "11111111", "--tick", "3" })
    t.eq(code, 1)
    t.ok(out:find("the card has 2 outcomes, so there is no outcome 3", 1, true), out)
    t.eq(read(root, "calls"):find("-X PATCH", 1, true), nil)
end)

t.test("outcome queues a tick but not an append when the write cannot reach Pomb", function()
    local root, home = sandbox({ export = BACKLOG_EXPORT, user = LEAD_USER })
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\nfor last; do :; done\ncase "$last" in */subtasks*) cat >/dev/null; exit 28 ;; esac\n'
            .. CURL:gsub("^#!/bin/sh\n", "")
    )
    local out, code = dev(root, home, { "board", "outcome", "11111111", "C works" })
    t.eq(code, 1)
    t.ok(out:find("curl exit 28", 1, true), out)
    t.eq(fs.exists(queue_file(home)), false)
    out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--delete", "2", "--reason", "never possible" }
    )
    t.eq(code, 1)
    t.ok(out:find("curl exit 28", 1, true), out)
    t.eq(fs.exists(queue_file(home)), false)
    out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--tick", "1" },
        { agent = "project-run/b" }
    )
    t.eq(code, 0)
    t.eq(out, "queued: Pomb unreachable, will sync\n")
    local queued = assert(fs.read(queue_file(home)))
    t.ok(queued:find('"outcome"', 1, true) and queued:find('"--tick"', 1, true), queued)
    t.ok(queued:find('"--as"', 1, true) and queued:find('"project-run/b"', 1, true), queued)
end)

t.test("outcome --rename is never queued when the write cannot reach Pomb", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\nfor last; do :; done\ncase "$last" in */subtasks*) cat >/dev/null; exit 28 ;; esac\n'
            .. CURL:gsub("^#!/bin/sh\n", "")
    )
    local out, code =
        dev(root, home, { "board", "outcome", "11111111", "--rename", "1", "New", "--reason", "r" })
    t.eq(code, 1, out)
    t.ok(out:find("curl exit 28", 1, true), out)
    t.eq(fs.exists(queue_file(home)), false)
end)

t.test("an unclaimed card's tick ignores an invalid DEV_AGENT", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    local out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--tick", "1" },
        { agent = "bad name" }
    )
    t.eq(code, 0, out)
    t.eq(out, "outcome 11111111 1 ticked\n", out)
    t.ok(read(root, "calls"):find('--data-raw {"done":true}', 1, true), out)
end)

t.test("rename is queued while Pomb is unreachable", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\nfor last; do :; done\ncase "$last" in */api/tasks/*) cat >/dev/null; exit 28 ;; esac\n'
            .. CURL:gsub("^#!/bin/sh\n", "")
    )
    local out, code = dev(root, home, { "board", "rename", "11111111", "Better", "title" })
    t.eq(code, 0)
    t.eq(out, "queued: Pomb unreachable, will sync\n")
    local queued = assert(fs.read(queue_file(home)))
    t.ok(queued:find('"rename"', 1, true) and queued:find('"Better"', 1, true), queued)
end)

t.test("discard queues each step it could not take, in order, once", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\nfor last; do :; done\ncase "$last" in */api/tasks/*) cat >/dev/null; exit 7 ;; esac\n'
            .. CURL:gsub("^#!/bin/sh\n", "")
    )
    local out, code = dev(root, home, { "board", "discard", "11111111", "--reason", "Dropped" })
    t.eq(code, 0)
    t.eq(out, "queued: Pomb unreachable, will sync\n")
    local queued = assert(fs.read(queue_file(home)))
    local note = assert(queued:find('"note"', 1, true), queued)
    local label = assert(queued:find('"label"', note, true), queued)
    local move = assert(queued:find('"discard_move"', label, true), queued)
    t.ok(queued:find('"Dropped"', 1, true) and move > label, queued)
end)

t.test("discard does not queue the note again once it has been posted", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\nfor last; do :; done\ncase "$last" in */comments) ;; */api/tasks/*) cat >/dev/null; exit 7 ;; esac\n'
            .. CURL:gsub("^#!/bin/sh\n", "")
    )
    local out, code = dev(root, home, { "board", "discard", "11111111", "--reason", "Dropped" })
    t.eq(code, 0)
    t.eq(out, "queued: Pomb unreachable, will sync\n")
    local queued = assert(fs.read(queue_file(home)))
    t.ok(not queued:find('"note"', 1, true), queued)
    t.ok(queued:find('"label"', 1, true) < queued:find('"discard_move"', 1, true), queued)
end)

t.test(
    "move to Done on a Pomb board names the open outcomes, and discard still closes it",
    function()
        local root, home = sandbox({ export = SUBTASKS_EXPORT })
        local out, code = dev(root, home, { "board", "move", "11111111", "done" })
        t.eq(code, 1, out)
        t.ok(out:find("1 of 2 outcomes are unticked (1. A works)", 1, true), out)
        t.ok(not read(root, "calls"):find("/move", 1, true), read(root, "calls"))
        out, code = dev(root, home, { "board", "discard", "11111111" })
        t.eq(code, 0, out)
        t.eq(out, "discarded 11111111\n")
    end
)

t.test("move to Done on a Pomb board refuses subtasks dev cannot read", function()
    local export = '{"tasks":[{"id":"'
        .. ID_A
        .. '","name":"First","column_id":"col-ready","position":1,"color_id":"yellow-id","labels":["docs"],"description":"Why.","subtasks":"oops"}]}'
    local root, home = sandbox({ export = export })
    local out, code = dev(root, home, { "board", "move", "11111111", "done" })
    t.eq(code, 1, out)
    t.ok(out:find("cannot be read from Pomb", 1, true), out)
    t.ok(not read(root, "calls"):find("/move", 1, true), read(root, "calls"))
end)

t.test("outcome sends the claim's fence on the subtask call", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    local out, code = dev(root, home, { "board", "take", "11111111" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "outcome", "11111111", "--tick", "1" })
    t.eq(code, 0, out)
    local calls = read(root, "calls")
    t.ok(
        calls:find(
            'If-Claim-Fence: 7 --data-raw {"done":true} https://pomb.example/api/tasks/'
                .. ID_A
                .. "/subtasks/sub-a",
            1,
            true
        ),
        calls
    )
    dev(root, home, { "board", "release", "11111111" })
end)

t.test("a renamed Pomb board is read through the column map and is_done", function()
    local detail = DETAIL:gsub('"Ready"', '"Next"'):gsub(
        '"Done","is_done":true}',
        '"Shipped","is_done":true},{"id":"col-old","name":"Old","is_done":true}'
    )
    local root, home = sandbox({
        detail = detail,
        project = '[board]\nbackend = "pomb"\nname = "dotfiles"\n\n[board.columns]\nready = "Next"\n',
    })
    local out, code = dev(root, home, { "board", "next" })
    t.eq(code, 0, out)
    t.eq(out, "11111111  Next  1 Pomodoro  docs  First  2 comments, 1 the owner's\n")
    t.ok(read(root, "calls"):find("ready=true&column_id=col-ready", 1, true), read(root, "calls"))
    out, code = dev(root, home, { "board", "ls", "--column", "ready" })
    t.eq(code, 0, out)
    t.ok(out:find("Next", 1, true), out)
    out, code = dev(root, home, { "board", "ls", "--column", "old" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "ls", "--column", "In Progress" })
    t.eq(code, 0, out)
end)

t.test("next asks for the unclaimed unblocked top of Ready", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "next" })
    t.eq(code, 0)
    t.eq(out, "11111111  Ready  1 Pomodoro  docs  First  2 comments, 1 the owner's\n")
    t.ok(
        read(root, "calls"):find(
            "/api/boards/board-1/tasks?limit=50&claimed=false&ready=true&column_id=col-ready",
            1,
            true
        ),
        read(root, "calls")
    )
end)

local EPIC_TASK = '{"id":"'
    .. ID_A
    .. '","name":"First","column_id":"col-ready","color_id":"yellow-id","labels":["docs"],"kind":"epic","children_total":3,"children_done":%d}'

t.test("epic_next_skips_open_child", function()
    local root, home = sandbox({ task = EPIC_TASK:format(1) })
    for _, args in ipairs({ { "board", "next" }, { "board", "next", "--column", "review" } }) do
        local out, code = dev(root, home, args)
        t.eq(code, 0, out)
        t.ok(out:find("^no ", 1), out)
    end
    root, home = sandbox({ task = EPIC_TASK:format(3) })
    local out, code = dev(root, home, { "board", "next" })
    t.eq(code, 0, out)
    t.ok(out:find("First", 1, true), out)
end)

t.test("epic_ls_marks", function()
    local export = EXPORT:gsub(
        '"name":"First"',
        '"name":"First","kind":"epic","children_total":3,"children_done":1',
        1
    )
    local root, home = sandbox({ export = export, task = EPIC_TASK:format(1) })
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 0, out)
    t.ok(out:find("[epic 2 of 3 open] First", 1, true), out)
    t.eq(out:find("[epic", out:find("Second", 1, true), true), nil)
    out, code = dev(root, home, { "board", "show", "11111111-a" })
    t.eq(code, 0, out)
    t.ok(out:find("kind: epic, 2 open\n", 1, true), out)
    t.ok(out:find("children: 1 of 3 done\n", 1, true), out)
end)

t.test("epic_move_refused_by_settings", function()
    local detail = DETAIL:gsub('"name":"Backlog"', '"name":"Backlog","wip_limit":2', 1)
    local export = PLANNED_EXPORT:gsub(
        '"name":"First"',
        '"name":"First","kind":"epic","children_total":3,"children_done":1',
        1
    )
    local root, home = sandbox({ export = export, task = EPIC_TASK:format(1), detail = detail })
    for _, column in ipairs({ "backlog", "done" }) do
        local out, code = dev(root, home, { "board", "move", "11111111-a", column })
        t.eq(code, 1, out)
        t.ok(out:find("is an epic and cannot enter", 1, true), out)
        t.ok(out:find("2 of 3 children are open", 1, true), out)
    end
    t.eq(read(root, "calls"):find("/move", 1, true), nil)
    local out, code = dev(root, home, { "board", "move", "11111111-a", "review" })
    t.eq(code, 0, out)
    t.ok(read(root, "calls"):find("/move", 1, true), read(root, "calls"))
end)

t.test("epic_move_pomb_refusal", function()
    local text =
        "the epic still has open children (2), so it cannot enter a WIP-limited or Done column"
    local export = PLANNED_EXPORT:gsub(
        '"name":"First"',
        '"name":"First","kind":"epic","children_total":3,"children_done":3',
        1
    )
    local root, home = sandbox({ export = export, task = EPIC_TASK:format(3) })
    curl_with(
        root,
        '*/move) body=\'{"code":"epic_has_open_children","message":"'
            .. text
            .. "\"}'; status=409 ;;\n*/claim/release) body= ;;"
    )
    local out, code = dev(root, home, { "board", "move", "11111111-a", "review" })
    t.eq(code, 1, out)
    t.ok(out:find(text, 1, true), out)
end)

t.test("epic_reopen_out_of_done", function()
    local export = PLANNED_EXPORT:gsub(
        '"name":"First","column_id":"col%-ready"',
        '"name":"First","kind":"epic","children_total":3,"children_done":1,"column_id":"col-done"',
        1
    )
    local task = EPIC_TASK:format(1):gsub("col%-ready", "col-done", 1)
    local root, home = sandbox({ export = export, task = task })
    local out, code = dev(root, home, { "board", "move", "11111111-a", "backlog" })
    t.eq(code, 0, out)
    local calls = read(root, "calls")
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/move", 1, true), calls)
    t.ok(calls:find('"column_id":"col-backlog"', 1, true), calls)
end)

t.test("next skips a card held by a blocker that is not in Done", function()
    local root, home = sandbox({
        links = '[{"kind":"blocked_by","target_id":"22222222-0000-0000-0000-000000000000"}]',
    })
    local out, code = dev(root, home, { "board", "next" })
    t.ok(code == 0, out)
    t.eq(out, "no ready cards\n")
end)

t.test("add posts the card to the named column", function()
    local root, home = sandbox()
    local out, code = dev(root, home, {
        "board",
        "add",
        "New card",
        "--column",
        "ready",
        "--description",
        V1,
        "--size",
        "1",
        "--checks",
        "dev test",
    })
    t.eq(code, 0)
    t.eq(out, "added 11111111 Ready\n")
    local calls = read(root, "calls")
    t.ok(calls:find('"fields":{"dev.checks":[{"run":"dev test"}]}', 1, true), calls)
    t.ok(calls:find("-X POST", 1, true), calls)
    t.ok(
        calls:find(
            '--data-raw {"name":"New card","column_id":"col-ready","description":"why"}',
            1,
            true
        ) or calls:find('"column_id":"col-ready"', 1, true),
        calls
    )
end)

t.test("add --done-when posts one subtask per outcome after the card", function()
    local root, home = sandbox()
    local out, code = dev(root, home, {
        "board",
        "add",
        "New",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "A works",
        "--done-when",
        "B works",
    })
    t.eq(code, 0)
    t.eq(out, "added 11111111 Ready\n")
    local calls = read(root, "calls")
    local first = calls:find("/api/tasks --", 1, true) or calls:find("-X POST", 1, true)
    t.ok(first, calls)
    local count, at = 0, 1
    while true do
        local found, stop = calls:find("/api/tasks/" .. ID_A .. "/subtasks", at, true)
        if not found then
            break
        end
        count, at = count + 1, stop + 1
    end
    t.eq(count, 2)
    t.ok(calls:find('--data-raw {"name":"A works"}', 1, true), calls)
    t.ok(calls:find('--data-raw {"name":"B works"}', 1, true), calls)
end)

t.test("a failed subtask names the card and what was not added, and is never queued", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/sub_fail", "2"))
    local out, code = dev(root, home, {
        "board",
        "add",
        "New",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "A",
        "--done-when",
        "B",
        "--done-when",
        "C",
    })
    t.eq(code, 1)
    t.ok(out:find("11111111 was added to Backlog but outcome 2 of 3 was not:", 1, true), out)
    t.eq(out:find("queued", 1, true), nil)
end)

t.test("add to Ready with outcomes creates in Backlog and moves after the subtasks", function()
    local root, home = sandbox()
    local out, code = dev(root, home, {
        "board",
        "add",
        "New",
        "--column",
        "ready",
        "--size",
        "1",
        "--description",
        V2,
        "--checks",
        "dev test",
        "--done-when",
        "a",
        "--done-when",
        "b",
        "--done-when",
        "c",
    })
    t.eq(code, 0, out)
    local calls = read(root, "calls")
    t.ok(calls:find('"column_id":"col-backlog"', 1, true), calls)
    local sub = calls:find("/subtasks", 1, true)
    local move = calls:find("/move", 1, true)
    t.ok(sub and move and sub < move, calls)
end)

t.test("show and ls read the subtasks from the export", function()
    local export = EXPORT:gsub(
        '"description":"Why it matters.",',
        '"description":"Why it matters.","subtasks":[{"id":"s1","name":"Docs written","done":true},'
            .. '{"id":"s2","name":"Lint clean","done":false}],'
    )
    local root, home = sandbox({ export = export })
    local out = dev(root, home, { "board", "show", "11111111-a" })
    t.ok(out:find("done when:\n- [x] Docs written\n- [ ] Lint clean\n", 1, true), out)
    out = dev(root, home, { "board", "ls" })
    t.ok(out:find("1/2", 1, true), out)
end)

t.test("add --label needs:human reaches pomb after the card and its outcomes", function()
    local root, home = sandbox()
    local out, code = dev(root, home, {
        "board",
        "add",
        "New",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "A",
        "--column",
        "blocked",
        "--label",
        "needs:human",
    })
    t.eq(code, 0)
    t.ok(out:find("added 11111111", 1, true), out)
    local calls = read(root, "calls")
    local created = calls:find("/api/tasks\n", 1, true)
    local outcome = calls:find("/subtasks", 1, true)
    local labelled = calls:find('--data-raw {"labels":["needs:human"]}', 1, true)
    t.ok(created and outcome and labelled, calls)
    t.ok(created < outcome and outcome < labelled, calls)
    local _, hits = calls:gsub("needs:human", "")
    t.eq(hits, 1)
end)

t.test("a failed subtask on add --label needs:human still labels the card", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/sub_fail", "1"))
    local out, code = dev(root, home, {
        "board",
        "add",
        "New",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "A",
        "--column",
        "blocked",
        "--label",
        "needs:human",
    })
    t.eq(code, 1)
    t.ok(out:find("outcome 1 of 1 was not", 1, true), out)
    t.ok(read(root, "calls"):find('--data-raw {"labels":["needs:human"]}', 1, true))
end)

local function add_locked(root, home)
    return dev(root, home, {
        "board",
        "add",
        "New",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "A",
        "--column",
        "blocked",
        "--label",
        "needs:human",
    })
end

t.test("add --label needs:human names the card when its label is refused", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/label_fail", ""))
    local out, code = add_locked(root, home)
    t.eq(code, 1)
    t.ok(out:find("but its labels were not set, so run dev board label on it", 1, true), out)
end)

t.test("a failed subtask and a refused label on add --label needs:human say both", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/sub_fail", "1"))
    assert(fs.write(root .. "/label_fail", ""))
    local out, code = add_locked(root, home)
    t.eq(code, 1)
    t.ok(out:find("outcome 1 of 1 was not", 1, true), out)
    t.ok(out:find("its labels were not set either", 1, true), out)
end)

t.test("add --size and size reach pomb with the id of the colour, not its label", function()
    local root, home = sandbox()
    local out, code = dev(
        root,
        home,
        { "board", "add", "New", "--problem", "x", "--size", "3+", "--done-when", "a" }
    )
    t.eq(code, 0)
    t.eq(out, "added 11111111 Ready\n")
    local calls = read(root, "calls")
    t.ok(calls:find('"color_id":"red-id"', 1, true), calls)
    out, code = dev(root, home, { "board", "size", "11111111-a", "2" })
    t.eq(code, 0)
    t.eq(out, "sized 11111111 2\n")
    calls = read(root, "calls")
    t.ok(calls:find("-X PATCH", 1, true), calls)
    t.ok(calls:find("/api/tasks/" .. ID_A, 1, true), calls)
    t.ok(calls:find('--data-raw {"color_id":"green-id"}', 1, true), calls)
    out, code = dev(root, home, { "board", "size", "11111111-a", "unsized" })
    t.eq(code, 1)
    t.ok(out:find("keeps a size", 1, true), out)
    t.eq(read(root, "calls"):find('{"color_id":"white-id"}', 1, true), nil)
    local iced = EXPORT:gsub('"column_id":"col%-backlog"', '"column_id":"col-icebox"')
    root, home = sandbox({ export = iced })
    out, code = dev(root, home, { "board", "size", "cccccccc", "unsized" })
    t.eq(code, 0, out)
    t.ok(read(root, "calls"):find('{"color_id":"white-id"}', 1, true))
end)

t.test("a board with no colour of the size asked for is reported", function()
    local root, home = sandbox()
    assert(
        fs.write(root .. "/colors.json", '[{"id":"white-id","value":"white","label":"Unsized"}]')
    )
    local out, code = dev(root, home, { "board", "size", "11111111-a", "1" })
    t.eq(code, 1)
    t.ok(out:find("board unavailable: the board has no yellow colour", 1, true), out)
    out, code = dev(root, home, { "board", "size", "11111111-a", "7" })
    t.eq(code, 2)
end)

t.test("ls --size reads the colour value from the palette whatever its label", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "ls", "--size", "1" })
    t.eq(code, 0)
    t.eq(out, "11111111  Ready  1 Pomodoro  docs  First\n")
    out = dev(root, home, { "board", "ls", "--size", "unsized" })
    t.eq(out, "cccccccc  Backlog  Unsized  -  Early\n11111111  Ready    unsized  -  Second\n")
end)

t.test("add --label and label reach pomb as the whole list", function()
    local root, home = sandbox()
    local out, code = dev(root, home, {
        "board",
        "add",
        "New",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "a",
        "--label",
        "a",
        "--label",
        "b",
    })
    t.eq(code, 0)
    t.eq(out, "added 11111111 Ready\n")
    t.ok(read(root, "calls"):find('"labels":["a","b"]', 1, true), read(root, "calls"))
    out, code = dev(root, home, { "board", "label", "11111111-a", "+needs:lead" })
    t.eq(code, 0)
    t.eq(out, "labelled 11111111 docs,needs:lead\n")
    local calls = read(root, "calls")
    t.ok(calls:find("-X PATCH", 1, true), calls)
    t.ok(calls:find('--data-raw {"labels":["docs","needs:lead"]}', 1, true), calls)
    out, code = dev(root, home, { "board", "label", "11111111-a", "--remove", "docs" })
    t.eq(code, 0)
    t.eq(out, "labelled 11111111 -\n")
    t.ok(read(root, "calls"):find('--data-raw {"labels":[]}', 1, true))
    out, code = dev(root, home, { "board", "label", "11111111-a", "+two words" })
    t.eq(code, 2)
end)

t.test("label sends the fence of a claim this machine holds", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    local _, code = dev(root, home, { "board", "label", "11111111-a", "+x" })
    t.eq(code, 0)
    local patched = read(root, "calls"):match("%-X PATCH.-/api/tasks/")
    t.ok(patched and patched:find("If-Claim-Fence: 7", 1, true), patched)
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("pomb escalate posts the tier and reason with the fence", function()
    local export = EXPORT:gsub('"labels":%["docs"%]', '"labels":["needs:planner"]', 1)
    local root, home = sandbox({ export = export })
    dev(root, home, { "board", "take", "11111111-a" })
    local out, code = dev(root, home, { "board", "escalate", "11111111-a", "pick", "one" })
    t.eq(out, "escalated 11111111 to needs:lead\n")
    t.eq(code, 0)
    local calls = read(root, "calls")
    local posted = calls:match("[^\n]*\n[^\n]*/api/tasks/" .. ID_A:gsub("%-", "%%-") .. "/escalate")
    t.ok(posted and posted:find("If-Claim-Fence: 7", 1, true), calls)
    t.ok(posted:find('"tier":"lead"', 1, true), calls)
    t.ok(posted:find('"reason":"pick one"', 1, true), calls)
    t.ok(not calls:find("-X PATCH", 1, true), calls)
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("checks patches the task's checks field whole, with the claim's fence", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    local out, code = dev(root, home, { "board", "checks", "11111111-a", "dev lint", "dev test" })
    t.eq(code, 0, out)
    t.eq(out, "set checks 11111111, 2 rows\n")
    local calls = read(root, "calls")
    t.ok(
        calls:find(
            '--data-raw {"fields":{"dev.checks":[{"run":"dev lint"},{"run":"dev test"}]}}',
            1,
            true
        ),
        calls
    )
    local patched = calls:match("%-X PATCH.-/api/tasks/")
    t.ok(patched and patched:find("If-Claim-Fence: 7", 1, true), patched)
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("checks on a Pomb board without the checks field is refused before any write", function()
    local root, home = sandbox({ fields = "[]" })
    local out, code = dev(root, home, { "board", "checks", "11111111-a", "dev lint" })
    t.eq(code, 1)
    t.ok(out:find("no checks field", 1, true), out)
    t.eq(read(root, "calls"):find("-X PATCH", 1, true), nil)
end)

t.test("allow, tests and files patch the task's fields whole, with the claim's fence", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    local out, code = dev(root, home, { "board", "allow", "11111111-a", "test-edits", "ci-edits" })
    t.eq(code, 0, out)
    t.eq(out, "set allow 11111111, test-edits ci-edits\n")
    out, code = dev(root, home, { "board", "tests", "11111111-a", "one", "tests::two" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "files", "11111111-a", "src/a.rs", "src/b.rs" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "allow", "11111111-a", "none" })
    t.eq(code, 0, out)
    t.eq(out, "cleared allow 11111111\n")
    local calls = read(root, "calls")
    for _, body in ipairs({
        '--data-raw {"fields":{"dev.allow":["test-edits","ci-edits"]}}',
        '--data-raw {"fields":{"dev.tests":"one\\ntests::two"}}',
        '--data-raw {"fields":{"dev.files":"src/a.rs\\nsrc/b.rs"}}',
        '--data-raw {"fields":{"dev.allow":null}}',
    }) do
        t.ok(calls:find(body, 1, true), calls)
    end
    local patched = calls:match("%-X PATCH.-/api/tasks/")
    t.ok(patched and patched:find("If-Claim-Fence: 7", 1, true), patched)
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test(
    "allow, tests and files on a Pomb board without the field are refused before any write",
    function()
        local root, home = sandbox({ fields = "[]" })
        for _, case in ipairs({
            { "allow", "test-edits", "dev.allow" },
            { "tests", "one", "dev.tests" },
            { "files", "src/a.rs", "dev.files" },
        }) do
            local out, code = dev(root, home, { "board", case[1], "11111111-a", case[2] })
            t.eq(code, 1)
            t.ok(out:find("no " .. case[3] .. " field", 1, true), out)
        end
        t.eq(read(root, "calls"):find("-X PATCH", 1, true), nil)
    end
)

t.test("show prints the allow, tests and files fields a Pomb card holds", function()
    local root, home = sandbox({
        export = '{"tasks":[{"id":"'
            .. ID_A
            .. '","name":"First","column_id":"col-ready","position":1,"color_id":null,"labels":[],'
            .. '"fields":{"dev.allow":["ci-edits"],"dev.tests":"one\\ntwo","dev.files":"src/a.rs"}}]}',
    })
    local out, code = dev(root, home, { "board", "show", "11111111-a" })
    t.eq(code, 0, out)
    t.ok(
        out:find("allow:\n- ci-edits\n\ntests:\n- one\n- two\n\nfiles:\n- src/a.rs\n", 1, true),
        out
    )
end)

t.test("note posts a comment of kind agent and move goes to the top of the column", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    local out = dev(root, home, { "board", "note", "11111111-a", "landed", "it" })
    t.eq(out, "noted 11111111\n")
    local calls = read(root, "calls")
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/comments", 1, true), calls)
    t.ok(calls:find('"kind":"agent"', 1, true), calls)
    t.ok(not calls:find('"author"', 1, true), calls)
    out = dev(
        root,
        home,
        { "board", "note", "11111111-a", "--kind", "decision", "--as", "reviewer", "ok" }
    )
    t.eq(out, "noted 11111111\n")
    calls = read(root, "calls")
    t.ok(calls:find('"kind":"decision"', 1, true), calls)
    t.ok(calls:find('"author":"reviewer"', 1, true), calls)
    out = dev(root, home, { "board", "move", "11111111-a", "review" })
    t.eq(out, "moved 11111111 to Review\n")
    calls = read(root, "calls")
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/move", 1, true), calls)
    t.ok(calls:find('"column_id":"col-review"', 1, true), calls)
    t.ok(calls:find('"position":0', 1, true), calls)
end)

local function owner_card_sandbox()
    local export = EXPORT:gsub(
        '"labels":%["docs"%],"description":"Why it matters',
        '"labels":["docs","needs:human"],"description":"Why it matters',
        1
    )
    return sandbox({ export = export })
end

t.test("ask posts a structured question", function()
    local root, home = sandbox()
    local out, code = dev(root, home, {
        "board",
        "ask",
        "11111111-a",
        "--question",
        "Which way?",
        "--choice",
        "Ready=Ship it",
        "--choice",
        "Icebox=Park it",
        "--recommend",
        "2",
        "--why",
        "Only he can choose",
    })
    t.eq(out, "asked 11111111\n")
    t.eq(code, 0)
    local calls = read(root, "calls")
    t.ok(calls:find("-X POST", 1, true), calls)
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/comments", 1, true), calls)
    t.ok(calls:find('"kind":"question"', 1, true), calls)
    t.ok(calls:find('"text":"Which way?"', 1, true), calls)
    t.ok(calls:find('"label":"Ship it"', 1, true), calls)
    t.ok(calls:find('"column_id":"col-ready"', 1, true), calls)
    t.ok(calls:find('"column_id":"col-icebox"', 1, true), calls)
    t.ok(calls:find('"recommended":2', 1, true), calls)
    t.ok(calls:find('"why":"Only he can choose"', 1, true), calls)
end)

t.test("ask prints the refusal as worded", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/ask_refusal", '{"message":"question.why is required"}'))
    local out, code = dev(root, home, {
        "board",
        "ask",
        "11111111-a",
        "--question",
        "Which way?",
        "--choice",
        "Ready=Ship it",
        "--choice",
        "Icebox=Park it",
        "--recommend",
        "1",
    })
    t.eq(code, 1)
    t.ok(out:find("question.why is required", 1, true), out)
end)

t.test("ask names a choice whose column the board lacks and posts nothing", function()
    local root, home = sandbox()
    local out, code = dev(root, home, {
        "board",
        "ask",
        "11111111-a",
        "--choice",
        "Nowhere=Lost",
    })
    t.eq(code, 1)
    t.ok(out:find("choice 1 names Nowhere, which is no column", 1, true), out)
    t.ok(not read(root, "calls"):find("-X POST", 1, true), read(root, "calls"))
end)

local QUESTION_COMMENT = '[{"id":"qqqqqqqq-1111-4111-8111-111111111111","author":"api-token",'
    .. '"actor_kind":"api_token","token_name":"worker","created_at":"2026-10-27T09:30:12Z",'
    .. '"body":"Which way?","kind":"question","question":{"text":"Which way?","choices":['
    .. '{"label":"Ship it","column_id":"col-ready"},{"label":"Park it","column_id":"col-icebox"}],'
    .. '"recommended":1,"why":"w","answer":%s}}]'

t.test("answer records the choice through Pomb", function()
    local root, home = owner_card_sandbox()
    local plain = '{"id":"pppppppp-2222-4222-8222-222222222222","author":"x","actor_kind":"user",'
        .. '"token_name":null,"created_at":"2026-10-27T10:00:00Z","body":"later","question":null}'
    local listed = QUESTION_COMMENT:format("null")
    assert(fs.write(root .. "/comments.json", listed:sub(1, -2) .. "," .. plain .. "]"))
    local out, code = dev(
        root,
        home,
        { "board", "answer", "11111111-a", "--choice", "2", "--quote", "go with two" }
    )
    t.eq(out, "answered 11111111 with choice 2\n")
    t.eq(code, 0)
    local calls = read(root, "calls")
    t.ok(
        calls:find(
            "/api/tasks/" .. ID_A .. "/comments/qqqqqqqq-1111-4111-8111-111111111111/answer",
            1,
            true
        ),
        calls
    )
    t.ok(calls:find('"choice":2', 1, true), calls)
    t.ok(calls:find('"quote":"go with two"', 1, true), calls)
end)

t.test("answer refuses a card whose question is answered already before calling Pomb", function()
    local root, home = owner_card_sandbox()
    assert(
        fs.write(
            root .. "/comments.json",
            QUESTION_COMMENT:format('{"choice":1,"answered_by":"o","answered_at":"x"}')
        )
    )
    local out, code =
        dev(root, home, { "board", "answer", "11111111-a", "--choice", "1", "--quote", "yes" })
    t.eq(code, 1)
    t.ok(out:find("no open question", 1, true), out)
    t.ok(not read(root, "calls"):find("/answer", 1, true), read(root, "calls"))
end)

t.test("answer refuses an empty quote before calling Pomb", function()
    local root, home = owner_card_sandbox()
    local _, code =
        dev(root, home, { "board", "answer", "11111111-a", "--choice", "1", "--quote", " " })
    t.eq(code, 2)
    t.ok(not read(root, "calls"):find("-X POST", 1, true), read(root, "calls"))
end)

t.test("order sends each position to Pomb and refuses two columns first", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "order", "11111111-b", "11111111-a" })
    t.eq(code, 0, out)
    local calls = read(root, "calls")
    local first = calls:find("/api/tasks/" .. ID_B .. "/move", 1, true)
    local second = calls:find("/api/tasks/" .. ID_A .. "/move", 1, true)
    t.ok(first and second and first < second, calls)
    t.ok(calls:find('"position":0', 1, true), calls)
    t.ok(calls:find('"position":1', 1, true), calls)
    root, home = sandbox()
    out, code = dev(root, home, { "board", "order", "11111111-a", "cccccccc" })
    t.eq(code, 1, out)
    t.ok(out:find("one column", 1, true), out)
    t.ok(not read(root, "calls"):find("/move", 1, true), read(root, "calls"))
end)

t.test("links reads the task's links and names the board of a link to another board", function()
    local links = '[{"id":"l1","kind":"blocked_by","target_id":"'
        .. ID_C
        .. '","board_id":"board-1"},'
        .. '{"id":"l2","kind":"blocks","target_id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","board_id":"board-2"},'
        .. '{"id":"l3","kind":"related","target_id":"'
        .. ID_B
        .. '","board_id":null}]'
    local root, home = sandbox({ links = links })
    assert(
        fs.write(
            root .. "/boards.json",
            '[{"id":"board-1","name":"dotfiles"},{"id":"board-2","name":"ci"}]'
        )
    )
    local out, code = dev(root, home, { "board", "links", "11111111-a" })
    t.eq(code, 0, out)
    t.eq(out, "blocked_by  cccccccc  -\nblocks      dddddddd  ci\nrelated     11111111  -\n")
    t.ok(read(root, "calls"):find("/api/tasks/" .. ID_A .. "/links", 1, true), read(root, "calls"))
    root, home = sandbox()
    out, code = dev(root, home, { "board", "links", "11111111-a" })
    t.eq(code, 0, out)
    t.eq(out, "no links\n")
end)

t.test("unlink deletes the link the token holds and reports a refused delete plainly", function()
    local links = '[{"id":"l1","kind":"blocked_by","target_id":"'
        .. ID_C
        .. '","board_id":"board-1"}]'
    local root, home = sandbox({ links = links })
    local out, code = dev(root, home, { "board", "unlink", "11111111-a", "blocked_by", "cccccccc" })
    t.eq(code, 0, out)
    t.eq(out, "unlinked 11111111 blocked_by cccccccc\n")
    local calls = read(root, "calls")
    t.ok(calls:find("-X DELETE", 1, true), calls)
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/links/l1", 1, true), calls)
    local _, deletes_before = read(root, "calls"):gsub("%-X DELETE", "")
    out, code = dev(root, home, { "board", "unlink", "11111111-a", "related", "cccccccc" })
    t.eq(code, 1, out)
    t.ok(out:find("the card holds no related link to cccccccc, its links are", 1, true), out)
    local _, deletes_after = read(root, "calls"):gsub("%-X DELETE", "")
    t.eq(deletes_after, deletes_before)
    root, home = sandbox({ links = links })
    curl_with(
        root,
        [[*/links/l1) body='{"code":"permission_denied","permission":"links.delete","message":"m","board_id":null}'; status=403 ;;
*/claim/release) body= ;;]]
    )
    out, code = dev(root, home, { "board", "unlink", "11111111-a", "blocked_by", "cccccccc" })
    t.eq(code, 1, out)
    t.eq(
        out,
        "dev: pomb kept the link: this token can delete only the links it created, and this one"
            .. " was made by another token or before Pomb 0.5.40\n"
    )
    t.ok(
        read(root, "calls"):find("/api/tasks/" .. ID_A .. "/links/l1", 1, true),
        read(root, "calls")
    )
    root, home = sandbox({ links = links })
    curl_with(
        root,
        [[*/links/l1) body='{"code":"permission_denied","permission":"tasks.edit","message":"no write","board_id":"board-9"}'; status=403 ;;
*/claim/release) body= ;;]]
    )
    out, code = dev(root, home, { "board", "unlink", "11111111-a", "blocked_by", "cccccccc" })
    t.eq(code, 1, out)
    t.ok(not out:find("kept the link", 1, true), out)
end)

t.test("unlink of a blocks view deletes the blocked_by link on the holder's task", function()
    local links = '[{"id":"l1","kind":"blocks","target_id":"' .. ID_C .. '","board_id":"board-1"}]'
    local holder = '[{"id":"l9","kind":"blocked_by","target_id":"'
        .. ID_A
        .. '","board_id":"board-1"}]'
    local root, home = sandbox({ links = links, holder_links = holder })
    local out, code = dev(root, home, { "board", "unlink", "11111111-a", "blocks", "cccccccc" })
    t.eq(code, 0, out)
    t.eq(out, "unlinked 11111111 blocks cccccccc\n")
    local calls = read(root, "calls")
    t.ok(calls:find("/api/tasks/" .. ID_C .. "/links/l9", 1, true), calls)
    t.ok(not calls:find("/api/tasks/" .. ID_A .. "/links/l1", 1, true), calls)
end)

t.test("notes, note --edit and note --delete reach pomb's comment routes", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "notes", "11111111-a" })
    t.eq(code, 0)
    t.eq(
        out,
        "aaaaaaaa  worker  -  -  2026-10-27 09:30  first\ndddddddd  human   -  x  2026-10-27 10:00  mine? no\n"
    )
    out, code = dev(root, home, { "board", "show", "11111111-a" })
    t.eq(code, 0)
    t.eq(
        out,
        "11111111  Ready  1 Pomodoro  docs  First\n\nWhy it matters.\n\n"
            .. "checks:\n- dev test\n- dev lint\n\n"
            .. "aaaaaaaa  worker  -  -  2026-10-27 09:30  first\n"
            .. (" "):rep(42)
            .. "line\ndddddddd  human   -  x  2026-10-27 10:00  mine? no\n"
    )
    out, code = dev(root, home, { "board", "note", "11111111-a", "--edit", "aaaaaaaa", "better" })
    t.eq(code, 0)
    t.eq(out, "edited 11111111 aaaaaaaa\n")
    local calls = read(root, "calls")
    t.ok(calls:find("-X PATCH", 1, true), calls)
    t.ok(
        calls:find(
            "/api/tasks/" .. ID_A .. "/comments/aaaaaaaa-1111-4111-8111-111111111111",
            1,
            true
        ),
        calls
    )
    t.ok(calls:find('--data-raw {"body":"better"}', 1, true), calls)
    out, code = dev(root, home, { "board", "note", "11111111-a", "--delete", "aaaaaaaa" })
    t.eq(code, 0)
    t.eq(out, "deleted 11111111 aaaaaaaa\n")
    t.ok(read(root, "calls"):find("-X DELETE", 1, true), read(root, "calls"))
end)

t.test("a 403 on a comment says it is not yours and exits 1", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "note", "11111111-a", "--edit", "dddddddd", "x" })
    t.eq(code, 1)
    t.eq(out, "dev: that comment is not yours to change\n")
    out, code = dev(root, home, { "board", "note", "11111111-a", "--delete", "dddddddd" })
    t.eq(code, 1)
    t.eq(out, "dev: that comment is not yours to change\n")
    out, code = dev(root, home, { "board", "note", "11111111-a", "--delete", "eeee" })
    t.eq(code, 1)
    t.eq(out, "dev: a comment id needs at least 8 hex characters: eeee\n")
end)

t.test("a card_locked 403 on a comment says the card is locked and exits 1", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/locked", ""))
    for _, args in ipairs({
        { "board", "note", "11111111-a", "--edit", "dddddddd", "x" },
        { "board", "note", "11111111-a", "--delete", "dddddddd" },
        { "board", "note", "11111111-a", "a new note" },
    }) do
        local out, code = dev(root, home, args)
        t.eq(code, 1)
        t.ok(out:find("labelled needs:human", 1, true), out)
        t.ok(out:find("Reordering and resizing", 1, true), out)
        t.eq(out:find("not yours", 1, true), nil)
    end
end)

t.test("prose warnings reach standard error and the write still happens", function()
    local root, home = sandbox()
    local warning = "warning: card prose holds a path: src/a.lua\n"
    local cases = {
        {
            args = {
                "board",
                "add",
                "Fresh",
                "--description",
                "look in src/a.lua",
                "--size",
                "1",
                "--done-when",
                "a",
            },
            marker = "Fresh",
            verb = "POST",
        },
        {
            args = { "board", "note", "11111111-a", "look", "in", "src/a.lua" },
            marker = "/comments",
            verb = "POST",
        },
        {
            args = { "board", "edit", "11111111-a" },
            input = "## Problem\nlook in src/a.lua\n\n## Change\n- x\n\n## Out of scope\nnone\n",
            marker = "description",
            verb = "PATCH",
        },
    }
    for _, case in ipairs(cases) do
        local before = #read(root, "calls")
        local out, code, errors = dev(root, home, case.args, { split = true, input = case.input })
        t.eq(code, 0)
        t.eq(errors, warning)
        t.eq(out:find("warning", 1, true), nil)
        local calls = read(root, "calls"):sub(before + 1)
        t.ok(calls:find("-X " .. case.verb, 1, true), calls)
        t.ok(calls:find(case.marker, 1, true), calls)
    end
end)

t.test("edit finds the board from a subdirectory and not from outside the project", function()
    local root, home = sandbox()
    local text = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone\n"
    local sub = root .. "/src/deep"
    assert(fs.mkdir(sub, { parents = true }))
    for _, cwd in ipairs({ root, sub }) do
        local out, code = dev(
            root,
            home,
            { "board", "edit", "11111111-a" },
            { input = text, cwd = cwd }
        )
        t.eq(code, 0, out)
        t.eq(out, "edited 11111111\n")
    end
    for _, word in ipairs({ "edit", "show" }) do
        local out, code = dev(
            root,
            home,
            { "board", word, "11111111-a" },
            { input = text, cwd = home }
        )
        t.eq(code, 1, out)
        t.eq(out, "dev: no board for this project\n")
    end
end)

t.test("a nonexistent column on the board is reported", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/detail.json", '{"id":"board-1","name":"dotfiles","columns":[]}'))
    local out, code = dev(
        root,
        home,
        { "board", "add", "x", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    t.eq(code, 1)
    t.ok(out:find("the board has no Backlog column", 1, true), out)
end)

t.test("board refuses --remote like the other machine-local nouns", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "--remote", "--", "board", "ls" })
    t.eq(code, 2)
    t.eq(out, "dev board ls: runs on this machine only, so --remote does not apply\n")
end)

t.test("capture_input hands the input to stdin and keeps it out of argv", function()
    local out, code = devos.capture_input({ "sh", "-c", "cat; echo done" }, "secret\n")
    t.eq(out, "secret\ndone\n")
    t.eq(code, 0)
    out, code = devos.capture_input({ "sh", "-c", "cat >/dev/null; exit 5" }, "x")
    t.eq(code, 5)
    t.raises(function()
        devos.capture_input({ "cat" }, "x", { stdout = "null" })
    end, "standard output")
end)

t.test("capture_input merges standard error into the output when asked", function()
    local out, code = devos.capture_input(
        { "sh", "-c", "cat >/dev/null; echo oops >&2" },
        "x",
        { stderr = "stdout" }
    )
    t.eq(out, "oops\n")
    t.eq(code, 0)
end)

t.test("capture_input leaves no temporary file behind", function()
    local dir = support.tempdir()
    local script = string.format(
        "package.path = %q; local o = require('dev.os'); o.capture_input({'cat'}, 'x'); o.capture_input({'sh', '-c', 'cat >/dev/null; exit 3'}, 'x')",
        support.absolute_path()
    )
    local _, code = devos.capture({ "luajit", "-e", script }, { env = { TMPDIR = dir } })
    t.eq(code, 0)
    t.eq(fs.list(dir), {})
end)

t.test("a non-JSON answer from the server is reported as unreadable", function()
    local root, home = sandbox()
    executable(
        root .. "/bin/curl",
        "#!/bin/sh\ncat >/dev/null\nprintf '<html>bad gateway</html>\\n502'\n"
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("board unavailable: pomb sent an answer dev cannot read", 1, true), out)
end)

t.test("a note may begin with a dash", function()
    local backend = fake(sample())
    local result = commands.run("note", { "cccccccc", "- fixed", "it" }, backend)
    t.eq(backend.calls[1], { "note", ID_C, "- fixed it", {} })
    t.eq(result.output, "noted cccccccc")
end)

local function heartbeats(root)
    local count = 0
    for _ in read(root, "calls"):gmatch("/claim/heartbeat") do
        count = count + 1
    end
    return count
end

local function wait_until(test)
    for _ = 1, 100 do
        if test() then
            return true
        end
        devos.run({ "sleep", "0.1" })
    end
    return false
end

local function state_file(home)
    return home .. "/state/dev/board/" .. ID_A
end

local function loop_pid(home)
    return assert(read(home, "state/dev/board/" .. ID_A):match("pid=(%d+)"))
end

local function loop_gone(pid)
    return wait_until(function()
        return devos
            .capture({ "ps", "-p", pid, "-o", "command=" }, { stderr = "null" })
            :find("keepalive", 1, true) == nil
    end)
end

local function settle(root)
    local before
    repeat
        before = heartbeats(root)
        devos.run({ "sleep", "0.6" })
    until heartbeats(root) == before
    return before
end

t.test("take claims the card and renews the claim while the loop runs", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "take", "11111111-a" })
    t.eq(code, 0)
    t.ok(out:find("took 11111111, fence 7, renewing every 5m for up to 50m", 1, true), out)
    local calls = read(root, "calls")
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/claim", 1, true), calls)
    t.ok(calls:find('"ttl_seconds":900', 1, true), calls)
    t.ok(calls:find('"claimant":"dev@', 1, true), calls)
    t.ok(wait_until(function()
        return heartbeats(root) >= 3
    end))
    t.ok(read(root, "calls"):find('{"fence":7}', 1, true))
    t.ok(read(root, "calls"):find("/api/tasks/" .. ID_A .. "/claim/heartbeat", 1, true))
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("the state file holds the card, the fence and the pid at mode 600", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    local state = read(home, "state/dev/board/" .. ID_A)
    t.ok(state:find("card=" .. ID_A .. "\nfence=7\npid=", 1, true), state)
    t.ok(state:find("pid=%d+\n$"), state)
    t.eq(state:find(TOKEN, 1, true), nil)
    local mode = devos.capture({ "ls", "-l", state_file(home) })
    t.ok(mode:find("^%-rw%-%-%-%-%-%-%-"), mode)
    mode = devos.capture({ "ls", "-ld", home .. "/state/dev/board" })
    t.ok(mode:find("^drwx%-%-%-%-%-%-"), mode)
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("release gives the claim up, removes the state and stops the loop", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    t.ok(wait_until(function()
        return heartbeats(root) >= 2
    end))
    local pid = loop_pid(home)
    local out, code = dev(root, home, { "board", "release", "11111111-a" })
    t.eq(code, 0)
    t.eq(out, "released 11111111\n")
    t.ok(
        read(root, "calls"):find("/api/tasks/" .. ID_A .. "/claim/release", 1, true),
        read(root, "calls")
    )
    t.eq(fs.exists(state_file(home)), false)
    t.ok(loop_gone(pid))
    local after = settle(root)
    t.eq(heartbeats(root), after)
end)

t.test("release without a taken claim is a plain error", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "release", "11111111-a" })
    t.eq(code, 1)
    t.ok(out:find("no claim was taken", 1, true), out)
    t.eq(read(root, "calls"):find("/claim/release", 1, true), nil)
end)

t.test("move out of progress stops the loop and sends the fence", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    dev(root, home, { "board", "take", "11111111-a" })
    t.ok(wait_until(function()
        return heartbeats(root) >= 2
    end))
    local pid = loop_pid(home)
    local out, code = dev(root, home, { "board", "move", "11111111-a", "review" })
    t.eq(code, 0)
    t.eq(out, "moved 11111111 to Review\n")
    local moved = read(root, "calls"):match("[^\n]*/move\n?")
    t.ok(moved:find("If-Claim-Fence: 7", 1, true), moved)
    t.ok(
        read(root, "calls"):find("/api/tasks/" .. ID_A .. "/claim/release", 1, true),
        read(root, "calls")
    )
    t.eq(fs.exists(state_file(home)), false)
    t.ok(loop_gone(pid))
    local after = settle(root)
    t.eq(heartbeats(root), after)
end)

t.test("move into progress does not release the claim", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    dev(root, home, { "board", "take", "11111111-a" })
    dev(root, home, { "board", "move", "11111111-a", "progress" })
    t.eq(read(root, "calls"):find("/claim/release", 1, true), nil)
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("take prints the card with every comment in full after the claim", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "take", "11111111-a" })
    t.eq(code, 0, out)
    t.ok(out:find("^took 11111111, fence 7"), out)
    t.ok(out:find("\n\n11111111  Ready  1 Pomodoro  docs  First\n", 1, true), out)
    t.ok(out:find("first\n", 1, true) and out:find("line", 1, true), out)
    t.ok(out:find("mine? no", 1, true), out)
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("a move into progress that takes the claim prints the card and its comments", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    local out, code = dev(root, home, { "board", "move", "11111111-a", "progress" })
    t.eq(code, 0, out)
    t.ok(out:find("^moved 11111111 to In Progress\n\n11111111  In Progress  "), out)
    t.ok(out:find("mine? no", 1, true), out)
    out, code = dev(root, home, { "board", "move", "11111111-a", "progress" })
    t.eq(code, 0, out)
    t.eq(out, "moved 11111111 to In Progress\n")
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("take keeps the claim and warns when the card cannot be read after it", function()
    local root, home = sandbox()
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\nfor last; do :; done\ncase "$last" in */api/tasks/'
            .. ID_A
            .. ") exit 7 ;; esac\n"
            .. CURL:gsub("^#!/bin/sh\n", "")
    )
    local out, code = dev(root, home, { "board", "take", "11111111-a" })
    t.eq(code, 0, out)
    t.ok(out:find("took 11111111, fence 7", 1, true), out)
    t.ok(out:find("dev: took 11111111, but ", 1, true), out)
    t.eq(fs.exists(state_file(home)), true)
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("take names the claimant from --as, then DEV_AGENT, else dev@host", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "take", "11111111-a", "--as", "project-alt/x" })
    t.eq(code, 0, out)
    t.ok(read(root, "calls"):find('"claimant":"project-alt/x"', 1, true), read(root, "calls"))
    dev(root, home, { "board", "release", "11111111-a" })
    out, code = dev(root, home, { "board", "take", "11111111-a" }, { agent = "env.agent" })
    t.eq(code, 0, out)
    t.ok(read(root, "calls"):find('"claimant":"env.agent"', 1, true), read(root, "calls"))
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("take refuses a name that is not one word of the allowed characters", function()
    local root, home = sandbox()
    for _, name in ipairs({ "two words", "semi;colon", "a:b" }) do
        local out, code = dev(root, home, { "board", "take", "11111111-a", "--as", name })
        t.eq(code, 2, out)
    end
    t.eq(commands.run("take", { "11111111-a", "--as", "" }, fake(sample())).code, 2)
    local _, code = dev(root, home, { "board", "take", "11111111-a" }, { agent = "bad name" })
    t.eq(code, 2)
    t.eq(read(root, "calls"):find("/claim", 1, true), nil)
end)

t.test("move into progress takes the claim of an unclaimed card under the agent name", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111-a", "progress" },
        { agent = "r/one" }
    )
    t.eq(code, 0, out)
    local calls = read(root, "calls")
    t.ok(calls:find('"claimant":"r/one"', 1, true), calls)
    t.ok(calls:find("If-Claim-Fence: 7", 1, true), calls)
    t.eq(fs.exists(state_file(home)), true)
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("epic_done_children_claim", function()
    local root, home = sandbox({
        export = PLANNED_EXPORT,
        task = EPIC_TASK:format(3),
    })
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111-a", "progress" },
        { agent = "r/one" }
    )
    t.eq(code, 0, out)
    local calls = read(root, "calls")
    t.ok(calls:find("/claim", 1, true), calls)
    t.ok(calls:find("If-Claim-Fence: 7", 1, true), calls)
    t.eq(fs.exists(state_file(home)), true)
    dev(root, home, { "board", "release", "11111111-a" })
end)

local function refusing_moves(root)
    local REFUSED_MOVE =
        '*/move) body=\'{"message":"no room"}\'; status=409 ;;\n*/claim/release) body= ;;'
    curl_with(root, REFUSED_MOVE)
end

t.test("a move into progress that Pomb refuses releases the claim it just took", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    refusing_moves(root)
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111-a", "progress" },
        { agent = "r/one" }
    )
    t.eq(code, 1)
    t.ok(out:find("no room", 1, true), out)
    local calls = read(root, "calls")
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/claim\n", 1, true), calls)
    local moved = calls:match("[^\n]*/move\n?")
    t.ok(moved:find("If-Claim-Fence: 7", 1, true), moved)
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/claim/release", 1, true), calls)
    t.ok(calls:find('{"fence":7}', 1, true), calls)
    t.eq(fs.exists(state_file(home)), false)
end)

t.test("a move into progress of a card claimed elsewhere takes no claim", function()
    local live = '"claim":{"claimant":"dev@box:42","expires_at":"2999-01-01T00:00:00Z"}'
    local export = PLANNED_EXPORT:gsub('"labels":%["docs"%]', '"labels":["docs"],' .. live, 1)
    local root, home = sandbox({ export = export })
    refusing_moves(root)
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111-a", "progress" },
        { agent = "r/one" }
    )
    t.eq(code, 1)
    t.ok(out:find("no room", 1, true), out)
    local calls = read(root, "calls")
    t.eq(calls:find("/claim", 1, true), nil)
    t.eq(fs.exists(state_file(home)), false)
end)

t.test("move to ready takes an epic like any card", function()
    local description =
        "## Problem\\nwhy\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone\\n\\n## Done when\\n- [ ] a"
    local export = EXPORT:gsub("Why it matters%.", description, 1)
    local root, home = sandbox({
        export = export,
        task = EPIC_TASK:format(3),
    })
    local out, code = dev(root, home, { "board", "move", "11111111-a", "ready" })
    t.eq(code, 0, out)
    t.ok(read(root, "calls"):find("/move", 1, true), read(root, "calls"))
end)

t.test("a queued change that hits the needs:human refusal is dropped with its reason", function()
    local export = EXPORT:gsub('"labels":%["docs"%]', '"labels":["needs:human"]', 1)
    local root, home = sandbox({ export = export })
    local queue = queue_file(home)
    assert(fs.mkdir(home .. "/state/dev/boards", { parents = true }))
    assert(
        fs.write(
            queue,
            '[{"sub":"move","args":["11111111-a","review"],"at":"2026-10-30T00:00:00Z"}]\n'
        )
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 0, out)
    t.ok(out:find("dropped move 11111111-a: 11111111 is labelled needs:human", 1, true), out)
    t.eq(fs.exists(queue), false)
    t.eq(read(root, "calls"):find("/move", 1, true), nil)
end)

t.test("a release the server refuses after a move warns and the move succeeds", function()
    local root, home = sandbox({ export = PLANNED_DONE_EXPORT })
    dev(root, home, { "board", "take", "11111111-a" })
    curl_with(root, "*/claim/release) body=; status=503 ;;")
    local out, code = dev(root, home, { "board", "move", "11111111-a", "done" })
    t.eq(code, 0)
    t.ok(out:find("moved 11111111 to Done", 1, true), out)
    t.ok(out:find("the claim was not released", 1, true), out)
    t.eq(fs.exists(state_file(home)), false)
end)

t.test("move into progress keeps the loop and the state", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    dev(root, home, { "board", "take", "11111111-a" })
    dev(root, home, { "board", "move", "11111111-a", "progress" })
    t.eq(fs.exists(state_file(home)), true)
    local seen = heartbeats(root)
    t.ok(wait_until(function()
        return heartbeats(root) > seen
    end))
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("the loop ends by itself after twice the card's size", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    t.ok(wait_until(function()
        return not fs.exists(state_file(home))
    end))
    t.eq(settle(root), 10)
end)

t.test("a renewal the server refuses ends the loop", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/hb_status", "409"))
    dev(root, home, { "board", "take", "11111111-a" })
    t.ok(wait_until(function()
        return not fs.exists(state_file(home))
    end))
    t.eq(settle(root), 1)
end)

t.test("a renewal that cannot reach the server keeps trying", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/hb_status", "503"))
    dev(root, home, { "board", "take", "11111111-a" })
    t.ok(wait_until(function()
        return heartbeats(root) >= 3
    end))
    t.eq(fs.exists(state_file(home)), true)
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("a second take renews with the stored fence", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    dev(root, home, { "board", "take", "11111111-a" })
    t.ok(
        read(root, "calls"):find('"fence":7,"ttl_seconds"', 1, true)
            or read(root, "calls"):find('"ttl_seconds":900,"fence":7', 1, true),
        read(root, "calls")
    )
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("take and release want exactly one card", function()
    local root, home = sandbox()
    for _, sub in ipairs({ "take", "release" }) do
        local _, code = dev(root, home, { "board", sub })
        t.eq(code, 2)
        _, code = dev(root, home, { "board", sub, "11111111-a", "extra" })
        t.eq(code, 2)
    end
end)

t.test("the token never reaches argv, the environment, the state or the output", function()
    local root, home = sandbox()
    executable(
        root .. "/bin/curl",
        (CURL:gsub('cat >"$ROOT/stdin"', 'env >>"$ROOT/env"\ncat >"$ROOT/stdin.$$"', 1))
    )
    local out = dev(root, home, { "-vv", "board", "take", "11111111-a" })
    t.ok(wait_until(function()
        return heartbeats(root) >= 2
    end))
    local ps = devos.capture({ "ps", "-ax", "-o", "command=" })
    out = out .. dev(root, home, { "-vv", "board", "release", "11111111-a" })
    t.eq(out:find(TOKEN, 1, true), nil)
    t.eq(ps:find(TOKEN, 1, true), nil)
    t.eq(read(root, "calls"):find(TOKEN, 1, true), nil)
    t.eq(read(root, "env"):find(TOKEN, 1, true), nil)
    t.eq(read(home, "state/dev/board/" .. ID_A):find(TOKEN, 1, true), nil)
    local header = 'header = "Authorization: Bearer ' .. TOKEN .. '"\n'
    local seen = devos.capture({ "sh", "-c", 'cat "$1"/stdin.*', "sh", root })
    t.ok(seen:find(header, 1, true), seen)
    t.eq((seen:gsub(header:gsub("%p", "%%%0"), "")), "")
    t.ok(read(root, "calls"):find("-K -", 1, true))
end)

t.test("ls shows who holds a live claim and ignores an expired one", function()
    local root, home = sandbox()
    local live = '"claim":{"claimant":"dev@box:42","expires_at":"2999-01-01T00:00:00Z"}'
    local dead = '"claim":{"claimant":"dev@old:1","expires_at":"2001-01-01T00:00:00Z"}'
    assert(
        fs.write(
            root .. "/export.json",
            '{"tasks":[{"id":"'
                .. ID_A
                .. '","name":"First","column_id":"col-ready","position":1,"color_id":null,"labels":[],'
                .. live
                .. '},{"id":"'
                .. ID_B
                .. '","name":"Second","column_id":"col-ready","position":2,"color_id":null,"labels":[],'
                .. dead
                .. "}]}"
        )
    )
    local out = dev(root, home, { "board", "ls" })
    t.eq(
        out,
        "11111111  Ready  unsized  -  dev@box:42  First\n"
            .. "11111111  Ready  unsized  -  -           Second\n"
    )
end)

t.test("ls adds no holder column while nobody holds a claim", function()
    local cards = sample()
    local result = commands.run("ls", {}, fake(cards))
    t.eq(result.output:find("dev@", 1, true), nil)
    cards[1].claimant = "dev@box:1"
    result = commands.run("ls", {}, fake(cards))
    t.eq(
        result.output,
        "11111111  Ready    1 Pomodoro  docs  dev@box:1  Write docs\n"
            .. "11111111  Backlog  unsized     -     -          Fix lint"
    )
end)

t.test("a release the server refuses keeps the state so it can be retried", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    curl_with(root, "*/claim/release) body=; status=503 ;;")
    local out, code = dev(root, home, { "board", "release", "11111111-a" })
    t.eq(code, 1)
    t.ok(out:find("pomb answered 503", 1, true), out)
    t.eq(fs.exists(state_file(home)), true)
    executable(root .. "/bin/curl", CURL)
    _, code = dev(root, home, { "board", "release", "11111111-a" })
    t.eq(code, 0)
end)

t.test("stale reads column_entered_at from every page of the tasks view", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "stale" })
    t.eq(code, 0)
    t.ok(
        out:find(
            "^11111111  Ready  %d+d  1 Pomodoro  First\n11111111  Ready  %d+d  unsized     Second\n\nnewest comment is the owner's:\n.-\n\nunsized outside Icebox:\n"
        ),
        out
    )
    t.ok(out:find("unsized outside Icebox:.*cccccccc  Backlog +Early.*could not date"), out)
    t.ok(out:find("unsized outside Icebox:.*11111111  Ready +Second.*could not date"), out)
    t.ok(out:find("could not date cccccccc%S+ Early\n$"), out)
    local calls = read(root, "calls")
    t.ok(
        calls:find("/tasks?limit=500 ", 1, true) or calls:find("/tasks?limit=500\n", 1, true),
        calls
    )
    t.ok(calls:find("/tasks?limit=500&cursor=c2", 1, true), calls)
    out, code = dev(root, home, { "board", "stale", "--days", "x" })
    t.eq(code, 2)
end)

local function answering(root, routes)
    executable(
        root .. "/bin/curl",
        "#!/bin/sh\ncat >/dev/null\nfor last; do :; done\n"
            .. 'case "$last" in\n'
            .. routes
            .. "esac\n"
    )
end

t.test("a permission_denied with no board says the token lacks it everywhere", function()
    local root, home = sandbox()
    answering(
        root,
        [[*) printf '{"code":"permission_denied","permission":"tasks.edit","message":"m","board_id":null}\n403' ;;
]]
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.eq(
        out,
        "dev: board unavailable: pomb answered 403: this token lacks the tasks.edit permission "
            .. "on every board; use a token that has it\n"
    )
end)

t.test("a permission_denied with a board says the board is not assigned", function()
    local root, home = sandbox()
    answering(
        root,
        [[*) printf '{"code":"permission_denied","permission":"tasks.edit","message":"m","board_id":"board-9"}\n403' ;;
]]
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.eq(
        out,
        "dev: board unavailable: this token has the tasks.edit permission but is not assigned "
            .. "to board board-9; add the board to the token\n"
    )
end)

local function refusing(root, who, status_line)
    answering(
        root,
        "*/api/v1/auth/whoami) printf '"
            .. who
            .. "\\n200' ;;\n*) printf '"
            .. status_line
            .. "' ;;\n"
    )
end

t.test("role-refusal-denied names the refused permission and the role", function()
    local root, home = sandbox()
    refusing(
        root,
        '{"role_name":"implementer","permissions":[]}',
        '{"code":"permission_denied","permission":"tasks.edit","message":"m","board_id":null}\\n403'
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.eq(
        out,
        "dev: board unavailable: pomb answered 403: this token (role implementer) lacks the "
            .. "tasks.edit permission on every board; use a token that has it\n"
    )
end)

t.test("role-refusal-exceeds-grant names the refused action and the role", function()
    local root, home = sandbox()
    refusing(
        root,
        '{"role_name":"implementer"}',
        '{"code":"exceeds_grant","action":"tasks.bin","message":"m"}\\n403'
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.eq(out, "dev: board unavailable: pomb answered 403: the implementer role cannot tasks.bin\n")
end)

t.test("role-refusal-norole keeps the refusal text with no role named", function()
    local root, home = sandbox()
    refusing(
        root,
        '{"role_name":null}',
        '{"code":"exceeds_grant","action":"tasks.bin","message":"too much"}\\n403'
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.eq(out, "dev: board unavailable: pomb answered 403: too much\n")
end)

t.test("role-refusal-expired says the role token expired and to mint it again", function()
    local root, home = sandbox()
    answering(
        root,
        [[*) printf '{"code":"token_expired","message":"whatever"}\n401' ;;
]]
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.eq(out, "dev: board unavailable: the role token expired; mint it again from its issuer\n")
end)

t.test("an insufficient_scope 403 still reports the server's message", function()
    local root, home = sandbox()
    answering(
        root,
        [[*) printf '{"code":"insufficient_scope","message":"insufficient token scope: needs admin"}\n403' ;;
]]
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.eq(out, "dev: board unavailable: pomb answered 403: insufficient token scope: needs admin\n")
end)

t.test("a board missing from a token's assigned boards gets its own message", function()
    local root, home = sandbox()
    answering(
        root,
        [[*/api/v1/auth/whoami) printf '{"permissions":["tasks.read"],"boards":[{"id":"b1","name":"Other"}]}\n200' ;;
*/api/boards) printf '[{"id":"b1","name":"Other"}]\n200' ;;
]]
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.eq(
        out,
        "dev: board unavailable: pomb lists no board named dotfiles for this token, which is "
            .. "assigned only to Other; if the board exists, add it to the token\n"
    )
end)

t.test("a missing board stays plain on a token that sees every board", function()
    for _, who in ipairs({ '{"scope":"work"}', '{"permissions":["tasks.read"],"boards":"all"}' }) do
        local root, home = sandbox()
        answering(root, "*/api/v1/auth/whoami) printf '" .. who .. [[\n200' ;;
*/api/boards) printf '[{"id":"b1","name":"Other"}]\n200' ;;
]])
        local out, code = dev(root, home, { "board", "ls" })
        t.eq(code, 1)
        t.eq(out, "dev: board unavailable: pomb has no board named dotfiles\n")
    end
end)

t.test(
    "add --checks on a Pomb board without the checks field is refused before any write",
    function()
        local root, home = sandbox({ fields = "[]" })
        local out, code = dev(root, home, {
            "board",
            "add",
            "New",
            "--problem",
            "x",
            "--size",
            "1",
            "--done-when",
            "a",
            "--checks",
            "dev test",
        })
        t.eq(code, 2)
        t.ok(out:find("no checks field", 1, true), out)
        t.eq(read(root, "calls"):find("-X POST", 1, true), nil)
    end
)

t.test("prose_warnings names each hex id, hash and path outside the Change section", function()
    t.eq(board.prose_warnings("fixed in 2af0e003 and 0ef0e008."), {
        "card prose holds a hex id or hash: 2af0e003",
        "card prose holds a hex id or hash: 0ef0e008",
    })
    t.eq(board.prose_warnings("see `dotfiles/bin/dev.lua`, ~/notes and ./run, /etc/hosts"), {
        "card prose holds a path: dotfiles/bin/dev.lua",
        "card prose holds a path: ~/notes",
        "card prose holds a path: ./run",
        "card prose holds a path: /etc/hosts",
    })
    t.eq(board.prose_warnings("## Problem\nsee a/b.lua\n\n## Change\n- a/b.lua 2af0e003\n"), {
        "card prose holds a path: a/b.lua",
    })
    t.eq(
        board.prose_warnings(
            "## Done when\n- [ ] x\n## Change\nsrc/a.lua\n## Out of scope\nsrc/a.lua"
        ),
        {
            "card prose holds a path: src/a.lua",
        }
    )
end)

t.test("prose_warnings leaves a lone slash command alone", function()
    t.eq(board.prose_warnings("type /exit or /quit to leave"), {})
    t.eq(board.prose_warnings("see /etc/hosts, ~/x and /a.lua"), {
        "card prose holds a path: /etc/hosts",
        "card prose holds a path: ~/x",
        "card prose holds a path: /a.lua",
    })
end)

t.test("prose_warnings leaves clean prose, plain words, numbers and URLs alone", function()
    t.eq(board.prose_warnings("a decade of facade 1234567 and 20261028, and/or I/O, v1.2"), {})
    t.eq(board.prose_warnings("https://example.com/a/b.html deadbeef12 is read"), {
        "card prose holds a hex id or hash: deadbeef12",
    })
    t.eq(board.prose_warnings(nil), {})
    t.eq(board.prose_warnings(""), {})
end)

t.test("add, note and edit report prose warnings and still write", function()
    local backend = fake(sample())
    local result =
        commands.run("note", { "cccccccc", "see", "2af0e003", "and", "0ef0e008" }, backend)
    t.eq(result.output, "noted cccccccc")
    t.eq(#result.warnings, 2)
    t.eq(#backend.calls, 1)
    result = commands.run("note", { "cccccccc", "all", "clear" }, backend)
    t.eq(#result.warnings, 0)
    result = commands.run(
        "add",
        { "X", "--description", "in src/a.lua", "--size", "1", "--done-when", "a" },
        backend
    )
    t.eq(result.warnings, { "card prose holds a path: src/a.lua" })
    result = commands.run("add", { "X", "--description", V1, "--size", "1" }, backend)
    t.eq(result.warnings, {})
    result = commands.run(
        "edit",
        { "cccccccc", "## Change\n- a/b.lua\n## Problem\nx/y.sh\n## Out of scope\nn" },
        backend
    )
    t.eq(result.warnings, { "card prose holds a path: x/y.sh" })
end)

t.test("split_checklist takes the Done when items and leaves the rest", function()
    local items, rest = board.split_checklist(
        "## Problem\nP\n\n\n## Done when\n* [X] one\n  - [ ] two\n\n## Out of scope\nN\n"
    )
    t.eq(items, { { name = "one", done = true }, { name = "two", done = false } })
    t.eq(rest, "## Problem\nP\n\n\n## Out of scope\nN")
    items, rest = board.split_checklist("## Done when\n- [ ] only\n")
    t.eq(#items, 1)
    t.eq(rest, "")
    t.eq(board.split_checklist("## Problem\n- [ ] not under the heading\n"), nil)
end)

local function waiting(root, home, call, status)
    local script = string.format(
        "package.path = %q; local pomb = require('dev.board.pomb'); local json = require('dev.json'); "
            .. "local b = assert(pomb.new({url = 'https://pomb.example', token = 'pass:secrets/worker/token/pomb', name = 'dotfiles'})); "
            .. "local got, message, oldest, refused = b:wait(%s); "
            .. "print(json.encode({got = got, message = message, oldest = oldest, refused = refused}))",
        support.absolute_path(),
        call
    )
    local out, code = devos.capture({ "luajit", "-e", script }, {
        env = {
            PATH = root .. "/bin:" .. os.getenv("PATH"),
            HOME = home,
            ROOT = root,
            WAIT_STATUS = status,
            DEV_PASS_LOCK = root .. "/pass.lock",
        },
        stderr = "stdout",
    })
    t.eq(code, 0, out)
    return assert(require("dev.json").decode(out), out)
end

local function wait_route(root, reply)
    executable(
        root .. "/bin/curl",
        CURL:gsub(
            "\n%*/api/boards%) body",
            "\n*/events/wait*) body='"
                .. reply:gsub("'", "'\\''")
                .. "'; status=${WAIT_STATUS:-200} ;;\n*/api/boards) body",
            1
        )
    )
end

t.test("wait returns the events oldest first with column names and the cursor", function()
    local root, home = sandbox()
    wait_route(
        root,
        '{"cursor":"9","events":['
            .. '{"cursor":"8","kind":"task_added","task_id":"t1","column_id":"col-ready","at":"x","actor_kind":"user","extra":1},'
            .. '{"cursor":"9","kind":"task_moved","task_id":"t2","column_id":"col-progress","from_column_id":"col-blocked","token_name":null}]}'
    )
    local result = waiting(root, home, "'7', {'task_added', 'task_moved'}, 20")
    t.eq(result.got, {
        cursor = "9",
        events = {
            { kind = "task_added", task_id = "t1", column = "Ready", actor = "human" },
            {
                kind = "task_moved",
                task_id = "t2",
                column = "In Progress",
                from_column = "Blocked",
            },
        },
    })
    local calls = read(root, "calls")
    t.ok(calls:find("/events/wait?timeout=20&after=7&kinds=task_added,task_moved", 1, true), calls)
end)

t.test("wait returns an empty list and the cursor to send again", function()
    local root, home = sandbox()
    wait_route(root, '{"cursor":"7","events":[]}')
    t.eq(waiting(root, home, "'7'").got, { cursor = "7", events = {} })
    local calls = read(root, "calls")
    t.ok(calls:find("/events/wait?timeout=50&after=7\n", 1, true), calls)
end)

t.test("wait with no cursor sends none", function()
    local root, home = sandbox()
    wait_route(root, '{"cursor":"3","events":[]}')
    t.eq(waiting(root, home, "nil, nil, 0").got.cursor, "3")
    local calls = read(root, "calls")
    t.ok(calls:find("/events/wait?timeout=0\n", 1, true), calls)
end)

t.test("wait returns the oldest cursor of a 410", function()
    local root, home = sandbox()
    wait_route(root, '{"code":"cursor_expired","message":"too old","oldest_cursor":"41"}')
    local result = waiting(root, home, "'1'", "410")
    t.eq(result.got, nil)
    t.eq(result.oldest, "41")
    t.ok(result.message:find("pomb answered 410: too old", 1, true), result.message)
end)

t.test("wait gives curl a max-time above the wait's timeout", function()
    local root, home = sandbox()
    wait_route(root, '{"cursor":"7","events":[]}')
    waiting(root, home, "'7', nil, 50")
    local calls = read(root, "calls")
    t.ok(calls:find("--max-time 60 ", 1, true), calls)
    t.ok(calls:find("--max-time 30 ", 1, true), calls)
end)

t.test("wait surfaces too_many_waits as a 429 and keeps no cursor", function()
    local root, home = sandbox()
    wait_route(root, '{"code":"too_many_waits","message":"end one"}')
    local result = waiting(root, home, "'7'", "429")
    t.eq(result.got, nil)
    t.eq(result.oldest, nil)
    t.ok(result.message:find("pomb answered 429: end one", 1, true), result.message)
    t.eq(result.refused, true)
end)

t.test("wait does not flag a 429 with another code or another status as too many waits", function()
    local root, home = sandbox()
    wait_route(root, '{"code":"rate_limited","message":"slow down"}')
    local result = waiting(root, home, "'7'", "429")
    t.eq(result.refused, nil)
    wait_route(root, '{"code":"too_many_waits","message":"end one"}')
    result = waiting(root, home, "'7'", "503")
    t.eq(result.refused, nil)
end)

local function waiter(replies)
    local seen = { afters = {}, kinds = {}, timeouts = {}, naps = {}, notices = {} }
    local backend = {}
    function backend:wait(after, kinds, timeout)
        seen.timeouts[#seen.timeouts + 1] = timeout or "default"
        seen.afters[#seen.afters + 1] = after or "none"
        seen.kinds[#seen.kinds + 1] = table.concat(kinds, ",")
        local reply = table.remove(replies, 1)
        return reply.got, reply.message, reply.oldest, reply.refused
    end
    function backend:columns()
        return backend.rows or {}
    end
    return backend, seen
end

local function waited(replies, args, opts)
    opts = opts or {}
    local backend, seen = waiter(replies)
    if opts.cards or opts.cards_error then
        function backend:cards()
            return opts.cards, opts.cards_error
        end
    end
    if opts.comments then
        function backend:comments(id)
            return opts.comments[id] or {}
        end
    end
    local path = opts.path or support.tempdir() .. "/wait"
    local result = commands.wait(backend, args, {
        stem = path,
        nap = function(seconds)
            seen.naps[#seen.naps + 1] = seconds
        end,
        random = function()
            return 0
        end,
        now = function()
            return opts.now or 0
        end,
        notice = function(line)
            seen.notices[#seen.notices + 1] = line
        end,
    })
    return result, seen, path
end

local function got(cursor, ...)
    return { got = { cursor = cursor, events = { ... } } }
end

t.test(
    "wait --for ready prints the card added to or moved into Ready and ignores the rest",
    function()
        local result, seen, path = waited({
            got("1"),
            got("2", { kind = "task_moved", task_id = ID_A, column = "In Progress" }),
            got(
                "3",
                { kind = "task_updated", task_id = ID_A, column = "Ready" },
                { kind = "task_added", task_id = ID_B, column = "Ready" },
                { kind = "task_moved", task_id = ID_C, column = "Ready", from_column = "Backlog" }
            ),
        }, { "--for", "ready" })
        t.eq(result.output, "added 11111111 to Ready\nmoved cccccccc to Ready")
        t.eq(seen.afters, { "none", "1", "2" })
        t.eq(seen.kinds[1], "task_added,task_moved")
        t.eq(fs.read(path .. ".ready.cursor"), "3\n")
    end
)

t.test(
    "wait --for human wakes on the owner's move out of Blocked, not an agent's move or comment",
    function()
        local result, seen = waited({
            got("1"),
            got("2", { kind = "comment_added", task_id = ID_A, column = "Blocked" }, {
                kind = "task_moved",
                task_id = ID_B,
                column = "In Progress",
                from_column = "Ready",
            }, {
                kind = "task_moved",
                task_id = ID_D,
                column = "Ready",
                from_column = "Blocked",
                actor = "agent",
            }),
            got("3", {
                kind = "task_moved",
                task_id = ID_C,
                column = "Ready",
                from_column = "Blocked",
                actor = "human",
            }),
            got("4"),
        }, { "--for", "human" }, {
            cards = { { id = ID_A, column = "Blocked", labels = {}, done = false } },
            comments = {
                [ID_A] = { { actor = "agent", at = "2026-11-02T10:00:00Z", body = "wait" } },
            },
        })
        t.eq(result.output, "moved cccccccc out of Blocked")
        t.eq(seen.kinds[1], "task_moved,comment_added")
    end
)

t.test("wait --for human wakes on the owner's comment newer than its start", function()
    local started = assert(box.parse_time("2026-11-02T09:00:00Z"))
    local cards = {
        { id = ID_A, column = "Ready", labels = {}, done = false },
        { id = ID_B, column = "Ready", labels = {}, done = false },
        { id = ID_C, column = "Review", labels = {}, done = false },
        { id = ID_D, column = "Done", labels = {}, done = true },
    }
    local replies = {
        [ID_A] = { { actor = "human", at = "2026-11-02T08:00:00Z", body = "old" } },
        [ID_B] = { { actor = "human", at = "2026-11-02T10:00:00Z", body = "1" } },
        [ID_C] = {
            { actor = "human", at = "2026-11-02T10:00:00Z", body = "1" },
            { actor = "agent", at = "2026-11-02T10:05:00Z", body = "ok" },
        },
        [ID_D] = { { actor = "human", at = "2026-11-02T10:00:00Z", body = "3" } },
    }
    local result, seen = waited({
        got("1"),
        got(
            "2",
            { kind = "comment_added", task_id = ID_A, column = "Ready" },
            { kind = "comment_added", task_id = ID_C, column = "Review" },
            { kind = "comment_added", task_id = ID_D, column = "Done" }
        ),
        got("3", { kind = "comment_added", task_id = ID_B, column = "Ready" }),
        got("4"),
    }, { "--for", "human" }, {
        cards = cards,
        comments = replies,
        now = started,
    })
    t.eq(result.output, "the owner commented on 11111111")
    t.eq(seen.kinds[1], "task_moved,comment_added")
    t.eq(seen.afters, { "none", "1", "2", "3" })
end)

t.test("wait --for human settles for 60 seconds and prints one line per card", function()
    local started = assert(box.parse_time("2026-11-02T09:00:00Z"))
    local at = "2026-11-02T10:00:00Z"
    local cards = {
        { id = ID_A, column = "Ready", labels = {}, done = false },
        { id = ID_B, column = "Blocked", labels = {}, done = false },
        { id = ID_C, column = "Blocked", labels = {}, done = false },
    }
    local replies = {
        [ID_A] = { { actor = "human", at = at, body = "1" } },
        [ID_C] = { { actor = "agent", at = at, body = "q" } },
    }
    local result, seen = waited({
        got("1"),
        got("2", { kind = "comment_added", task_id = ID_A, column = "Ready" }),
        got("3", { kind = "comment_added", task_id = ID_A, column = "Ready" }, {
            kind = "task_moved",
            task_id = ID_B,
            column = "Ready",
            from_column = "Blocked",
            actor = "human",
        }, { kind = "comment_added", task_id = ID_C, column = "Blocked" }),
        got("4"),
    }, { "--for", "human" }, { cards = cards, comments = replies, now = started })
    t.eq(result.output, "the owner commented on 11111111\nmoved 11111111 out of Blocked")
    t.eq(seen.afters, { "none", "1", "2", "3" })
    t.eq(seen.timeouts, { "default", "default", 60, 60 })
end)

t.test("wait --for human prints the lines it holds when the cursor is trimmed", function()
    local cards = { { id = ID_A, column = "Blocked", labels = {}, done = false } }
    local result = waited({
        got("1"),
        got("2", {
            kind = "task_moved",
            task_id = ID_A,
            column = "Ready",
            from_column = "Blocked",
            actor = "human",
        }),
        { oldest = "9" },
    }, { "--for", "human" }, { cards = cards })
    t.eq(result.output, "moved 11111111 out of Blocked")
end)

t.test("wait --for lead wakes once on a needs:lead card in Blocked", function()
    local cards = {
        { id = ID_A, column = "Blocked", labels = { "needs:lead" } },
        { id = ID_B, column = "Blocked", labels = { "needs:lead", "needs:human" } },
        { id = ID_C, column = "Ready", labels = { "needs:lead" } },
        { id = ID_D, column = "Blocked", labels = { "needs:lead" }, claimant = "x" },
    }
    local result, seen, path = waited({
        got("1"),
        got(
            "2",
            { kind = "task_moved", task_id = ID_C, column = "Ready" },
            { kind = "task_added", task_id = ID_B, column = "Blocked" },
            { kind = "task_updated", task_id = ID_D, column = "Blocked" }
        ),
        got(
            "3",
            { kind = "task_updated", task_id = ID_A, column = "Blocked" },
            { kind = "task_added", task_id = ID_A, column = "Blocked" }
        ),
    }, { "--for", "lead" }, { cards = cards })
    t.eq(result.output, "11111111 is labelled needs:lead in Blocked")
    t.eq(seen.kinds[1], "task_added,task_moved,task_updated")
    t.eq(fs.read(path .. ".lead.cursor"), "3\n")
end)

t.test("wait --for planner wakes once on a needs:planner card in Blocked", function()
    local cards = {
        { id = ID_A, column = "Blocked", labels = { "needs:planner" } },
        { id = ID_B, column = "Blocked", labels = { "needs:lead" } },
        { id = ID_C, column = "Blocked", labels = { "needs:planner", "needs:human" } },
    }
    local result, seen, path = waited({
        got("1"),
        got(
            "2",
            { kind = "task_added", task_id = ID_B, column = "Blocked" },
            { kind = "task_updated", task_id = ID_C, column = "Blocked" }
        ),
        got("3", { kind = "task_updated", task_id = ID_A, column = "Blocked" }),
    }, { "--for", "planner" }, { cards = cards })
    t.eq(result.output, "11111111 is labelled needs:planner in Blocked")
    t.eq(seen.kinds[1], "task_added,task_moved,task_updated")
    t.eq(fs.read(path .. ".planner.cursor"), "3\n")
end)

for _, stage in ipairs({ "Review", "Verify", "Release" }) do
    t.test(
        "wait --for " .. stage:lower() .. " prints the unclaimed card that reached " .. stage,
        function()
            local cards = {
                { id = ID_A, column = stage },
                { id = ID_B, column = stage, claimant = "x" },
                { id = ID_C, column = "Ready" },
            }
            local result, seen, path = waited({
                got("1"),
                got(
                    "2",
                    { kind = "task_moved", task_id = ID_B, column = stage },
                    { kind = "task_moved", task_id = ID_C, column = "Ready" }
                ),
                got("3", { kind = "task_moved", task_id = ID_A, column = stage }),
            }, { "--for", stage:lower() }, { cards = cards })
            t.eq(result.output, "moved 11111111 to " .. stage)
            t.eq(seen.kinds[1], "task_added,task_moved")
            t.eq(fs.read(path .. "." .. stage:lower() .. ".cursor"), "3\n")
        end
    )
end

t.test("wait refuses a --for that names no stage", function()
    local result = waited({}, { "--for", "verifier" })
    t.eq(result.code, 2)
end)

t.test("wait --for lead leaves the cursor alone when the board cannot be read", function()
    local result, _, path = waited({
        got("1"),
        got("2", { kind = "task_added", task_id = ID_A, column = "Blocked" }),
    }, { "--for", "lead" }, { cards_error = "pomb is down" })
    t.eq(result.code, 1)
    t.eq(fs.read(path .. ".lead.cursor"), "1\n")
end)

t.test("wait without --for matches every kind", function()
    local result, seen = waited({
        got("1", { kind = "comment_added", task_id = ID_A, column = "Ready" }),
    }, {})
    t.eq(result.output, "commented on 11111111")
    t.eq(seen.kinds[1], "task_added,task_moved,task_updated,comment_added")
end)

t.test("wait resumes from the stored cursor", function()
    local path = support.tempdir() .. "/wait"
    assert(fs.write(path .. ".ready.cursor", "41\n"))
    local result, seen = waited({
        got("42", { kind = "task_added", task_id = ID_A, column = "Ready" }),
    }, { "--for", "ready" }, { path = path })
    t.eq(result.output, "added 11111111 to Ready")
    t.eq(seen.afters, { "41" })
    t.eq(fs.read(path .. ".ready.cursor"), "42\n")
    local _, other = waited({
        got("9"),
        got("10", {
            kind = "task_moved",
            task_id = ID_A,
            column = "Ready",
            from_column = "Blocked",
            actor = "human",
        }),
        got("11"),
    }, { "--for", "human" }, { path = path })
    t.eq(other.afters, { "none", "9", "10" })
end)

t.test("wait stores the oldest cursor of an expired one and says events were trimmed", function()
    local result, _, path = waited({
        { message = "board unavailable: pomb answered 410: too old", oldest = "17" },
    }, { "--for", "ready" })
    t.eq(result.output, "events were trimmed, check the board")
    t.eq(result.message, nil)
    t.eq(fs.read(path .. ".ready.cursor"), "17\n")
end)

t.test("wait retries Pomb being unreachable, then gives up after ten in a row", function()
    local result, seen = waited({
        { message = "board unavailable: cannot reach https://p (curl exit 7)" },
        got("5", { kind = "task_added", task_id = ID_A, column = "Ready" }),
    }, { "--for", "ready" })
    t.eq(result.output, "added 11111111 to Ready")
    t.eq(seen.naps, { 30 })
    local down = {}
    for i = 1, 10 do
        down[i] = { message = "board unavailable: cannot reach https://p (curl exit 6)" }
    end
    result, seen = waited(down, {})
    t.ok(result.message:find("curl exit 6", 1, true), result.message)
    t.eq(#seen.naps, 9)
end)

local function limited()
    return { message = "board unavailable: pomb answered 429: end one", refused = true }
end

t.test(
    "wait keeps waiting through too many open waits, with a pause that grows to 5 minutes",
    function()
        local replies = {}
        for i = 1, 14 do
            replies[i] = limited()
        end
        replies[15] = got("5", { kind = "task_added", task_id = ID_A, column = "Ready" })
        local result, seen = waited(replies, { "--for", "ready" })
        t.eq(result.output, "added 11111111 to Ready")
        t.eq(seen.naps, { 30, 60, 120, 240, 300, 300, 300, 300, 300, 300, 300, 300, 300, 300 })
    end
)

t.test("wait spreads the pause with the random source and never passes the step", function()
    local backend =
        waiter({ limited(), limited(), got("5", { kind = "task_updated", task_id = ID_A }) })
    local naps = {}
    local fractions = { 0, 1 }
    commands.wait(backend, {}, {
        stem = support.tempdir() .. "/wait",
        nap = function(seconds)
            naps[#naps + 1] = seconds
        end,
        random = function()
            return table.remove(fractions, 1)
        end,
        notice = function() end,
    })
    t.eq(naps, { 30, 45 })
end)

t.test("wait reports too many open waits once", function()
    local result, seen = waited({
        limited(),
        limited(),
        got("5", { kind = "task_updated", task_id = ID_A }),
    }, {})
    t.eq(result.output, "updated 11111111")
    t.eq(#seen.notices, 1)
    t.ok(seen.notices[1]:find("too many open waits", 1, true), seen.notices[1])
    t.eq(seen.naps, { 30, 60 })
end)

t.test("wait does not count too many open waits toward the ten failures", function()
    local replies = {}
    for _ = 1, 9 do
        replies[#replies + 1] =
            { message = "board unavailable: cannot reach https://p (curl exit 6)" }
    end
    replies[#replies + 1] = limited()
    for _ = 1, 9 do
        replies[#replies + 1] =
            { message = "board unavailable: cannot reach https://p (curl exit 6)" }
    end
    replies[#replies + 1] = got("5", { kind = "task_updated", task_id = ID_A })
    local result = waited(replies, {})
    t.eq(result.output, "updated 11111111")
end)

t.test("wait treats a 429 without the too_many_waits flag as a plain refusal", function()
    local result, seen = waited({
        { message = "board unavailable: pomb answered 429: slow down" },
    }, {})
    t.eq(result.code, 1)
    t.eq(#seen.naps, 0)
end)

t.test("wait fails at once on a refusal", function()
    local result, seen = waited({
        { message = "board unavailable: pomb answered 401: bad token" },
    }, {})
    t.eq(result.code, 1)
    t.eq(#seen.naps, 0)
end)

t.test("wait rejects an unknown --for value and a card", function()
    local result = waited({}, { "--for", "everyone" })
    t.eq(result.code, 2)
    t.ok(result.message:find("release, human, lead and planner", 1, true), result.message)
    t.eq(waited({}, { "abc" }).code, 2)
end)

t.test("delete needs a card and a reason", function()
    local backend = fake(sample())
    for _, args in ipairs({
        {},
        { "cccccccc" },
        { "cccccccc", "--reason", " " },
        { "--reason", "x" },
    }) do
        local result = commands.run("delete", args, backend)
        t.eq(result.code, 2)
        t.eq(result.message, "needs a card and --reason TEXT")
    end
    t.eq(backend.calls, {})
end)

t.test("delete notes the reason, then moves the card to the bin with the lead token", function()
    local root, home = sandbox({ user = LEAD_USER })
    local out, code = dev(root, home, { "board", "delete", "11111111-a", "--reason", "duplicate" })
    t.eq(code, 0, out)
    t.eq(out, "moved 11111111 to the bin\n")
    local calls = read(root, "calls")
    local noted = calls:find("-X POST", 1, true)
    local binned = calls:find("-X DELETE", 1, true)
    t.ok(noted and binned and noted < binned, calls)
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/comments", 1, true), calls)
    t.ok(calls:find("/api/tasks/" .. ID_A .. "\n", 1, true), calls)
    t.ok(calls:find("pass show secrets/lead/token/pomb", 1, true), calls)
    t.eq(calls:find("pass show secrets/worker", 1, true), nil)
    t.ok(calls:find("the lead deletes this card, reason: duplicate", 1, true), calls)
end)

t.test("delete-lead-role deletes a card for a DEV_AGENT whose role segment is lead", function()
    local root, home = sandbox({ user = LEAD_USER })
    local out, code = dev(
        root,
        home,
        { "board", "delete", "11111111-a", "--reason", "duplicate" },
        { agent = "dotfiles/lead/82f0e002/1" }
    )
    t.eq(code, 0, out)
    t.eq(out, "moved 11111111 to the bin\n")
    t.ok(read(root, "calls"):find("-X DELETE", 1, true), read(root, "calls"))
end)

t.test("delete-runner-role refuses a runner name, with no call and no token read", function()
    for _, name in ipairs({
        "dotfiles/implementer/82f0e002/1",
        "dotfiles/leader/82f0e002/1",
        "lead/implementer/82f0e002/1",
        "project-run/pombbin",
    }) do
        local root, home = sandbox({ user = LEAD_USER })
        local out, code = dev(
            root,
            home,
            { "board", "delete", "11111111-a", "--reason", "duplicate" },
            { agent = name }
        )
        t.eq(code, 1, out)
        t.ok(out:find("only the lead deletes a card", 1, true), out)
        t.ok(out:find(name, 1, true), out)
        t.eq(read(root, "calls"), "")
    end
end)

t.test("lead-name-helper counts a name with no slash or a lead role as the lead", function()
    t.eq(commands.is_lead(""), true)
    t.eq(commands.is_lead("project-lead"), true)
    t.eq(commands.is_lead("dotfiles/lead/82f0e002/1"), true)
    t.eq(commands.is_lead("dotfiles/lead"), true)
    t.eq(commands.is_lead("dotfiles/implementer/82f0e002/1"), false)
    t.eq(commands.is_lead("dotfiles/leader/82f0e002/1"), false)
    t.eq(commands.is_lead("lead/implementer/82f0e002/1"), false)
    t.eq(commands.is_lead("project-run/pombbin"), false)
end)

t.test("delete without a lead token or on a local board does nothing", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "delete", "11111111-a", "--reason", "x" })
    t.eq(code, 1, out)
    t.ok(out:find("lead_token is not set", 1, true), out)
    t.eq(read(root, "calls"), "")
    root, home = sandbox({ project = '[board]\nbackend = "local"\nname = "scratch"\n' })
    out, code = dev(root, home, { "board", "delete", "11111111-a", "--reason", "x" })
    t.eq(code, 1, out)
    t.ok(out:find("keeps no recycle bin", 1, true), out)
end)

t.test("delete shows Pomb's permission_denied and card_locked as they come", function()
    local root, home = sandbox({ user = LEAD_USER })
    assert(
        fs.write(
            root .. "/delete_body",
            '{"code":"permission_denied","permission":"tasks.bin","message":"m","board_id":null}'
        )
    )
    local out, code = dev(root, home, { "board", "delete", "11111111-a", "--reason", "x" })
    t.eq(code, 1, out)
    t.ok(out:find("tasks.bin", 1, true), out)
    root, home = sandbox({ user = LEAD_USER })
    assert(fs.write(root .. "/locked", ""))
    out, code = dev(root, home, { "board", "delete", "11111111-a", "--reason", "x" })
    t.eq(code, 1, out)
    t.ok(out:find("labelled needs:human", 1, true), out)
    t.eq(read(root, "calls"):find("-X DELETE", 1, true), nil)
end)

local ISSUED = "pomb_ISSUEDrole0123456789"

local function issued_dev(root, home, token)
    return dev(root, home, { "board", "ls" }, { env = { DEV_BOARD_TOKEN = token } })
end

t.test(
    "DEV_BOARD_TOKEN is sent as the bearer token and pass and the Keychain are never read",
    function()
        local root, home = sandbox()
        with_security(root)
        local out, code = issued_dev(root, home, ISSUED)
        t.eq(code, 0, out)
        t.ok(read(root, "stdin"):find("Bearer " .. ISSUED, 1, true), read(root, "stdin"))
        t.eq(occurrences(read(root, "calls"), "pass show"), 0)
        t.eq(read(root, "seccalls"), "")
    end
)

t.test("DEV_BOARD_TOKEN unset or empty reads pass as before", function()
    local root, home = sandbox()
    local out, code = issued_dev(root, home, "")
    t.eq(code, 0, out)
    t.eq(occurrences(read(root, "calls"), "pass show"), 1)
    t.ok(read(root, "stdin"):find("Bearer " .. TOKEN, 1, true), read(root, "stdin"))
    root, home = sandbox()
    out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 0, out)
    t.eq(occurrences(read(root, "calls"), "pass show"), 1)
end)

t.test(
    "DEV_BOARD_TOKEN refused with 401 names the issued token and never falls back to pass",
    function()
        local root, home = sandbox()
        with_security(root)
        executable(
            root .. "/bin/curl",
            '#!/bin/sh\ncat >/dev/null\nprintf \'curl %s\\n\' "$*" >>"$ROOT/calls"\n'
                .. 'printf \'{"message":"bad"}\\n401\''
        )
        local out, code = issued_dev(root, home, ISSUED)
        t.eq(code, 1)
        t.ok(out:find("issued token", 1, true), out)
        t.eq(occurrences(read(root, "calls"), "pass show"), 0)
    end
)

t.test("DEV_BOARD_TOKEN never reaches the output, the arguments or the log", function()
    local root, home = sandbox()
    local out = issued_dev(root, home, ISSUED)
    t.eq(out:find(ISSUED, 1, true), nil, out)
    t.eq(read(root, "calls"):find(ISSUED, 1, true), nil)
    executable(root .. "/bin/curl", '#!/bin/sh\ncat >/dev/null\nprintf \'{"message":"bad"}\\n401\'')
    out = issued_dev(root, home, ISSUED)
    t.eq(out:find(ISSUED, 1, true), nil, out)
    t.eq(read(root, "calls"):find(ISSUED, 1, true), nil)
end)

t.test("the keep-alive loop under DEV_BOARD_TOKEN sends that token and never reads pass", function()
    local root = sandbox()
    assert(fs.write(root .. "/state", "fence=7\n"))
    shell(
        root,
        root .. "/pass.lock",
        "DEV_BOARD_TOKEN="
            .. ISSUED
            .. " bash "
            .. SHARE
            .. "keepalive.sh "
            .. root
            .. "/state card 7 1 https://pomb.example Agents/x 0",
        "600"
    )
    t.ok(read(root, "stdin"):find("Bearer " .. ISSUED, 1, true), read(root, "stdin"))
    t.eq(occurrences(read(root, "calls"), "pass show"), 0)
end)

t.test("move to review on a board with In Review and no Review names dev board init", function()
    local backend = fake({ planned() })
    backend.limited = { "In Review" }
    local result = commands.run("move", { "cccccccc", "review" }, backend)
    t.eq(result.code, 1)
    t.ok(
        result.message:find("run dev board init to move the board to the stage columns", 1, true),
        result.message
    )
    t.ok(result.message:find("no Review column", 1, true), result.message)
    result = commands.run("move", { "cccccccc", "In Review" }, backend)
    t.eq(result.code, 1)
    t.ok(result.message:find("run dev board init to move", 1, true), result.message)
end)

t.test("move to review keeps the plain refusal on a board without In Review", function()
    local backend = fake({ planned() })
    local result = commands.run("move", { "cccccccc", "In Review" }, backend)
    t.eq(result.code, 2)
    t.ok(result.message:find("unknown column In Review", 1, true), result.message)
end)

t.test("wait on a board with In Review and no Review names dev board init", function()
    local backend = waiter({})
    backend.rows = { { name = "In Review", is_done = false }, { name = "Done", is_done = true } }
    local result = commands.wait(backend, {}, { stem = support.tempdir() .. "/wait" })
    t.eq(result.code, 1)
    t.ok(
        result.message:find("run dev board init to move the board to the stage columns", 1, true),
        result.message
    )
end)
