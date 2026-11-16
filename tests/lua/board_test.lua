local ffi = require("ffi")

local testing = require("dev.testing")
local board = require("dev.board")
local box = require("dev.cmd.box")
local cmd_board = require("dev.cmd.board")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local guards = require("dev.board.guards")
local json = require("dev.json")
local pomb = require("dev.board.pomb")
local ui = require("dev.ui")
local support = require("support")

local TOKEN = "pomb_SECRETtoken0123456789"
local OLD_TOKEN = "pomb_OLDtoken9876543210"
local ID_A = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
local ID_B = "11111111-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
local ID_C = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
local ID_D = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
local LINK_A = "link: https://pomb.example/t/" .. ID_A
local LEAD = "dotfiles/lead/1"
local PROGRESS_COLUMN = support.column_id(support.COLUMN.PROGRESS)
local READY_COLUMN = support.column_id(support.COLUMN.READY)
local BACKLOG_COLUMN = support.column_id(support.COLUMN.BACKLOG)
local ICEBOX_COLUMN = support.column_id(support.COLUMN.ICEBOX)
local LIVE_LEASE = "2999-01-01T00:00:00Z"
local PROGRESS_NAME = support.COLUMN_NAME.PROGRESS
local V1 = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone\n\n## Done when\n- [ ] done"
local SCAFFOLD = "## Problem\nx\n\n## Change\n\n## Out of scope\n"
local COMPOSED = "## Problem\nx\n\n## Change\nx\n\n## Out of scope\ny\n"
local V2 = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone"
local LEAD_USER = '[board.pomb]\nurl = "https://pomb.example"\ntoken = "pass:secrets/worker/token/pomb"\n'
    .. 'lead_token = "pass:secrets/lead/token/pomb"\n'

local function executable(path, body)
    assert(fs.write(path, body))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function fake(cards, times, finished)
    finished = finished or { support.COLUMN_NAME.DONE }
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
    function backend:limits()
        return { columns = {}, groups = {} }
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
    function backend:blocked(id)
        if backend.blocked_error then
            return nil, backend.blocked_error
        end
        return (backend.blockers or {})[id] == true
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
    function backend:make_epic(id, fence)
        calls[#calls + 1] = { "make_epic", id, fence }
        return backend.refusal == nil, backend.refusal
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
            column = support.COLUMN_NAME.READY,
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
            column = support.COLUMN_NAME.BACKLOG,
            size = "unsized",
            labels = {},
            checks = {},
            outcomes = {},
        },
        {
            id = ID_C,
            name = "Old thing",
            column = support.COLUMN_NAME.DONE,
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
        column = support.COLUMN_NAME.BACKLOG,
        size = "2 Pomodori",
        color = "green",
        description = V2,
        labels = {},
        checks = { "dev test" },
        outcomes = {},
    }
end

testing.test("column takes the names and the short forms in any case", function()
    local roles = board.roles()
    testing.eq(roles:column(support.COLUMN.READY), support.COLUMN_NAME.READY)
    testing.eq(roles:column("PROGRESS"), support.COLUMN_NAME.PROGRESS)
    testing.eq(roles:column(support.COLUMN.REVIEW), support.COLUMN_NAME.REVIEW)
    for _, short in ipairs({
        support.COLUMN.BLOCKED,
        support.COLUMN.DONE,
        support.COLUMN.BACKLOG,
        support.COLUMN.ICEBOX,
    }) do
        testing.eq(roles:column(short):lower(), short)
    end
    testing.eq(roles:column("doing"), nil)
end)

testing.test("roles take the mapped names, the role words and the finished columns", function()
    local roles = board.roles(
        { ready = "Next", progress = "Doing", done = "Shipped" },
        { "Old", "Shipped" }
    )
    testing.eq(roles:column(support.COLUMN.READY), "Next")
    testing.eq(roles:column("PROGRESS"), "Doing")
    testing.eq(roles:column("in progress"), nil)
    testing.eq(roles:column(support.COLUMN.DONE), "Shipped")
    testing.eq(roles:column("old"), "Old")
    testing.eq(roles.list, {
        support.COLUMN_NAME.ICEBOX,
        support.COLUMN_NAME.BACKLOG,
        "Next",
        "Doing",
        support.COLUMN_NAME.REVIEW,
        support.COLUMN_NAME.VERIFY,
        support.COLUMN_NAME.RELEASE,
        support.COLUMN_NAME.BLOCKED,
        "Shipped",
    })
    testing.eq(board.roles(nil, { "Old", "Shipped" }):done_column(), "Old")
    testing.eq(board.roles():done_column(), support.COLUMN_NAME.DONE)
end)

testing.test("a renamed board runs through the column map", function()
    local backend = fake({
        { id = ID_A, name = "A", column = "Next", size = "1 Pomodoro", labels = {}, checks = {} },
        { id = ID_B, name = "B", column = "Inbox", size = "unsized", labels = {}, checks = {} },
    }, nil, { "Shipped" })
    backend.column_map = { backlog = "Inbox", ready = "Next", done = "Shipped" }
    testing.eq(
        cmd_board.run("ls", { "--column", support.COLUMN.READY }, backend).output,
        "11111111  Next  1 Pomodoro  -  A"
    )
    testing.eq(
        cmd_board.run("ls", { "--column", support.COLUMN.BACKLOG }, backend).output,
        "11111111  Inbox  unsized  -  B"
    )
    testing.eq(cmd_board.run("ls", { "--column", "doing" }, backend).code, 2)
    testing.eq(
        cmd_board.run("add", {
            "C",
            "--problem",
            "x",
            "--change",
            "x",
            "--out-of-scope",
            "y",
            "--size",
            "1",
            "--done-when",
            "a",
        }, backend).output,
        "added cccccccc Inbox"
    )
end)

testing.test(
    "ls hides every finished column and discard picks the mapped one, else the first",
    function()
        local cards = sample()
        cards[2].column = "Archive"
        local backend = fake(cards, nil, { support.COLUMN_NAME.DONE, "Archive" })
        testing.eq(
            cmd_board.run("ls", {}, backend).output,
            "11111111  Ready  1 Pomodoro  docs  Write docs"
        )
        testing.eq(cmd_board.run("ls", { "--column", "archive" }, backend).message, nil)
        cmd_board.run("discard", { "11111111-a" }, backend)
        testing.eq(backend.calls[#backend.calls], { "move", ID_A, support.COLUMN_NAME.DONE })
        backend = fake(sample(), nil, { "Archive", support.COLUMN_NAME.DONE })
        backend.column_map = { done = support.COLUMN_NAME.DONE }
        cmd_board.run("discard", { "11111111-a" }, backend)
        testing.eq(backend.calls[#backend.calls], { "move", ID_A, support.COLUMN_NAME.DONE })
        backend = fake(sample(), nil, { "Archive", support.COLUMN_NAME.DONE })
        cmd_board.run("discard", { "11111111-a" }, backend)
        testing.eq(backend.calls[#backend.calls], { "move", ID_A, "Archive" })
    end
)

testing.test("resolve takes a unique prefix of at least 8 characters", function()
    local cards = sample()
    testing.eq(board.resolve(cards, "11111111-a").id, ID_A)
    testing.eq(board.resolve(cards, ID_B).id, ID_B)
    testing.eq(board.resolve(cards, "CCCCCCCC").id, ID_C)
end)

testing.test("resolve refuses a short, unknown or ambiguous prefix", function()
    local cards = sample()
    local card, message = board.resolve(cards, "1111111")
    testing.eq(card, nil)
    testing.ok(message:find("at least 8", 1, true), message)
    card, message = board.resolve(cards, "11111111")
    testing.eq(card, nil)
    testing.eq(message, "More than one card starts with 11111111. Give more characters.")
    card, message = board.resolve(cards, "deadbeef")
    testing.eq(card, nil)
    testing.eq(message, "No card starts with deadbeef.")
    card, message = board.resolve(cards, "zzzzzzzz")
    testing.eq(card, nil)
    testing.ok(message:find("hex", 1, true), message)
end)

testing.test("ls hides Done and aligns the columns", function()
    local result = cmd_board.run("ls", {}, fake(sample()))
    testing.eq(
        result.output,
        "11111111  Ready    1 Pomodoro  docs  Write docs\n11111111  Backlog  unsized     -     Fix lint"
    )
end)

testing.test("ls filters by column and label", function()
    local result = cmd_board.run("ls", { "--column", support.COLUMN.DONE }, fake(sample()))
    testing.eq(result.output, "cccccccc  Done  unsized  -  Old thing")
    result = cmd_board.run("ls", { "--label", "docs" }, fake(sample()))
    testing.eq(result.output, "11111111  Ready  1 Pomodoro  docs  Write docs")
    result = cmd_board.run("ls", { "--label", "none" }, fake(sample()))
    testing.eq(result.output, "No cards.")
end)

local function coloured(cards, args)
    local screen = ui.context({ color = true, interactive = true, width = 100 })
    return cmd_board.run("ls", args or {}, fake(cards), nil, screen)
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
    cards[2].column = support.COLUMN_NAME.BLOCKED
    cards[2].claimant = nil
    return cards
end

testing.test("ls on a colour terminal draws the summary, legend, dots and meter", function()
    local result = coloured(progress_sample())
    testing.ok(result.page, "output goes through the pager")
    local lines = split(strip(result.output))
    testing.eq(lines[1], "2 cards · 1 ready · 1 blocked")
    testing.eq(lines[2], "size  ● 1  ●● 2  ●●● 3  ●●●● >3  ○○○ unsized")
    testing.eq(lines[3], "")
    testing.ok(lines[4]:find("^ID +COLUMN +SIZE +LABELS +DONE +NAME$"), lines[4])
    testing.ok(
        lines[5]:find("^11111111  Ready +● +docs +▰▰▱▱ 2/4 +Write docs$"),
        lines[5]
    )
    testing.ok(lines[6]:find("^11111111  Blocked +○○○ +%- +%- +Fix lint$"), lines[6])
    testing.ok(result.output:find("\27[33m", 1, true), "yellow is painted")
end)

testing.test("ls on a colour terminal paints no empty colour code in the meter", function()
    local empty_code = "\27%[[%d;]*m\27%[0m"
    local cards = progress_sample()
    cards[1].outcomes = { { done = false }, { done = false } }
    cards[2].outcomes = { { done = true }, { done = true } }
    local result = coloured(cards)
    testing.eq(result.output:find(empty_code), nil, result.output)
    testing.ok(strip(result.output):find("▱▱▱▱ 0/2", 1, true), result.output)
    testing.ok(strip(result.output):find("▰▰▰▰ 2/2", 1, true), result.output)
    testing.ok(result.output:find("\27[32m▰▰▰▰\27[0m", 1, true), result.output)
end)

testing.test("ls shows the held by column only when a listed card is claimed", function()
    local cards = progress_sample()
    cards[1].claimant = "dev@host:1"
    local result = coloured(cards)
    testing.ok(strip(result.output):find("HELD BY", 1, true), result.output)
    testing.ok(strip(result.output):find("dev@host:1", 1, true), result.output)
end)

testing.test("ls --group lists the cards under a heading and count per column", function()
    local result = coloured(progress_sample(), { "--group" })
    local lines = split(strip(result.output))
    testing.eq(lines[3], "")
    testing.eq(lines[4], "Ready  1 card")
    testing.ok(lines[5]:find("^  11111111 +● +docs +▰▰▱▱ 2/4 +Write docs$"), lines[5])
    testing.eq(lines[6], "")
    testing.eq(lines[7], "Blocked  1 card")
    testing.eq(lines[#lines], "Done is left out unless --column done")
    local filtered =
        strip(coloured(progress_sample(), { "--group", "--column", support.COLUMN.BLOCKED }).output)
    testing.ok(filtered:find("Done is left out unless --column done", 1, true), filtered)
    testing.eq(
        coloured(sample(), { "--group", "--column", support.COLUMN.DONE }).output:find(
            "left out",
            1,
            true
        ),
        nil
    )
end)

testing.test("ls filters by column, label and size in both layouts", function()
    for _, group in ipairs({ {}, { "--group" } }) do
        local function run(...)
            local args = { ... }
            for _, word in ipairs(group) do
                args[#args + 1] = word
            end
            return strip(coloured(progress_sample(), args).output)
        end
        testing.ok(run("--column", support.COLUMN.BLOCKED):find("Fix lint", 1, true))
        testing.eq(run("--column", support.COLUMN.BLOCKED):find("Write docs", 1, true), nil)
        testing.ok(run("--label", "docs"):find("Write docs", 1, true))
        testing.eq(run("--label", "docs"):find("Fix lint", 1, true), nil)
        testing.ok(run("--size", "1"):find("Write docs", 1, true))
        testing.eq(run("--size", "1"):find("Fix lint", 1, true), nil)
        testing.eq(coloured(progress_sample(), { "--label", "none" }).output, "No cards.")
    end
end)

testing.test("ls without colour is the plain lines, --group included", function()
    local plain = ui.context({ color = false, interactive = false, width = 100 })
    local expected =
        "11111111  Ready    1 Pomodoro  docs  Write docs\n11111111  Backlog  unsized     -     Fix lint"
    for _, args in ipairs({ {}, { "--group" } }) do
        local result = cmd_board.run("ls", args, fake(sample()), nil, plain)
        testing.eq(result.output, expected)
        testing.eq(result.page, nil)
    end
end)

testing.test("ls refuses an unknown column and an unknown flag with a usage error", function()
    local result = cmd_board.run("ls", { "--column", "doing" }, fake(sample()))
    testing.eq(result.code, 2)
    testing.ok(result.message:find("unknown column doing", 1, true), result.message)
    result = cmd_board.run("ls", { "--bogus" }, fake(sample()))
    testing.eq(result.code, 2)
    testing.ok(result.message:find("Unknown flag --bogus.", 1, true), result.message)
    result = cmd_board.run("ls", { "--column" }, fake(sample()))
    testing.eq(result.code, 2)
end)

testing.test("add defaults to Backlog and joins the words of the name", function()
    local backend = fake(sample())
    local result = cmd_board.run("add", {
        "A",
        "new",
        "card",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
    }, backend)
    testing.eq(result.output, "added cccccccc Backlog")
    testing.eq(
        backend.calls[1],
        { "add", "A new card", support.COLUMN_NAME.BACKLOG, COMPOSED, "yellow" }
    )
    result = cmd_board.run("add", {
        "X",
        "--column",
        support.COLUMN.READY,
        "--description",
        V1,
        "--size",
        "2",
        "--checks",
        "dev test",
    }, backend)
    testing.eq(backend.calls[2], { "add", "X", support.COLUMN_NAME.READY, V1, "green" })
    testing.eq(cmd_board.run("add", {}, backend).code, 2)
end)

testing.test("add --checks refuses the rows checks refuses and writes nothing", function()
    for _, row in ipairs({ "rg 'a' f", "rg a.*b f", "dev.--remote.lint" }) do
        local backend = fake(sample())
        local result = cmd_board.run(
            "add",
            { "X", "--problem", "x", "--checks", "dev test", "--checks", row },
            backend
        )
        testing.eq(result.code, 2)
        testing.ok(result.message:find(row, 1, true), result.message)
        testing.eq(#backend.calls, 0)
    end
end)

testing.test("add --board files on the named board and leaves this one alone", function()
    local backend = fake(sample())
    local sibling = fake(sample())
    backend.sibling = sibling
    local result = cmd_board.run("add", {
        "Far",
        "--board",
        "ci",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
    }, backend)
    testing.eq(result.output, "added cccccccc Backlog")
    testing.eq(backend.calls[1], { "other_board", "ci" })
    testing.eq(#backend.calls, 1)
    testing.eq(sibling.calls[1], { "add", "Far", support.COLUMN_NAME.BACKLOG, COMPOSED, "yellow" })
end)

testing.test("add --board refuses a board that is not there", function()
    local backend = fake(sample())
    local result = cmd_board.run("add", { "Far", "--board", "nope", "--size", "1" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("no board named nope", 1, true), result.message)
    local sibling = fake(sample())
    function sibling:find()
        return false
    end
    backend.sibling = sibling
    result = cmd_board.run("add", { "Far", "--board", "ci", "--size", "1" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("no board named ci", 1, true), result.message)
    testing.eq(#sibling.calls, 0)
end)

testing.test("add --blocked-by links the new card to each blocker", function()
    local backend = fake(sample())
    local result = cmd_board.run("add", {
        "X",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
        "--blocked-by",
        "11111111-a",
        "--blocked-by",
        "11111111-b",
    }, backend)
    testing.eq(result.output, "added cccccccc Backlog")
    testing.eq(backend.calls[2], { "link", ID_C, "blocked_by", ID_A })
    testing.eq(backend.calls[3], { "link", ID_C, "blocked_by", ID_B })
    testing.eq(#backend.calls, 3)
end)

testing.test("add --from links the new card as related to the card it came from", function()
    local backend = fake(sample())
    local result = cmd_board.run("add", {
        "X",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
        "--from",
        "11111111-a",
    }, backend)
    testing.eq(result.output, "added cccccccc Backlog")
    testing.eq(backend.calls[2], { "link", ID_C, "related", ID_A })
    testing.eq(#backend.calls, 2)
end)

testing.test("add --from refuses an unknown card before it adds", function()
    local backend = fake(sample())
    local result = cmd_board.run("add", {
        "X",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
        "--from",
        "deadbeef",
    }, backend)
    testing.eq(result.code, 1)
    testing.eq(#backend.calls, 0)
end)

testing.test("add --blocked-by refuses an unknown blocker before it adds", function()
    local backend = fake(sample())
    local result = cmd_board.run("add", {
        "X",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
        "--blocked-by",
        "deadbeef",
    }, backend)
    testing.eq(result.code, 1)
    testing.eq(#backend.calls, 0)
end)

testing.test("add --board with --blocked-by looks the blocker up on the named board", function()
    local backend = fake(sample())
    local sibling = fake(sample())
    backend.sibling = sibling
    cmd_board.run("add", {
        "X",
        "--board",
        "ci",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
        "--blocked-by",
        "11111111-a",
    }, backend)
    testing.eq(sibling.calls[2], { "link", ID_C, "blocked_by", ID_A })
    testing.eq(#backend.calls, 1)
end)

testing.test("add names the card when its blocked-by link fails", function()
    local backend = fake(sample())
    function backend:link()
        return nil, "pomb refused"
    end
    local result = cmd_board.run("add", {
        "X",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
        "--blocked-by",
        "11111111-a",
    }, backend)
    testing.eq(result.code, 1)
    testing.ok(
        result.message:find("cccccccc was added to Backlog but its blocked_by link", 1, true),
        result.message
    )
    testing.ok(result.unqueued)
end)

testing.test("add names the card when its from link fails", function()
    local backend = fake(sample())
    function backend:link()
        return nil, "pomb refused"
    end
    local result = cmd_board.run("add", {
        "X",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
        "--from",
        "11111111-a",
    }, backend)
    testing.eq(result.code, 1)
    testing.ok(
        result.message:find("cccccccc was added to Backlog but its related link", 1, true),
        result.message
    )
    testing.ok(result.unqueued)
end)

testing.test("add --board with --from looks the card up on the named board", function()
    local backend = fake(sample())
    local sibling = fake(sample())
    backend.sibling = sibling
    cmd_board.run("add", {
        "X",
        "--board",
        "ci",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
        "--from",
        "11111111-a",
    }, backend)
    testing.eq(sibling.calls[2], { "link", ID_C, "related", ID_A })
    testing.eq(#backend.calls, 1)
end)

testing.test("add --blocked-by drops a repeated blocker and reaches BOARD:CARD", function()
    local backend = fake(sample())
    local far = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    backend.sibling = {
        cards = function()
            return {
                {
                    id = far,
                    name = "Far",
                    column = support.COLUMN_NAME.READY,
                    labels = {},
                    checks = {},
                },
            }
        end,
    }
    cmd_board.run("add", {
        "X",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
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
    testing.eq(backend.calls[1], { "other_board", "ci" })
    testing.eq(backend.calls[2], { "add", "X", support.COLUMN_NAME.BACKLOG, COMPOSED, "yellow" })
    testing.eq(backend.calls[3], { "link", ID_C, "blocked_by", ID_A })
    testing.eq(backend.calls[4], { "link", ID_C, "blocked_by", far })
    testing.eq(#backend.calls, 4)
end)

testing.test("add --size passes the colour its size word names", function()
    local backend = fake(sample())
    for word, color in pairs({ ["1"] = "yellow", ["2"] = "green", ["3"] = "blue", ["3+"] = "red" }) do
        cmd_board.run("add", {
            "X",
            "--problem",
            "x",
            "--change",
            "x",
            "--out-of-scope",
            "y",
            "--size",
            word,
            "--done-when",
            "a",
        }, backend)
        testing.eq(
            backend.calls[#backend.calls],
            { "add", "X", support.COLUMN_NAME.BACKLOG, COMPOSED, color }
        )
    end
    local calls = #backend.calls
    local refused = cmd_board.run(
        "add",
        { "X", "--problem", "x", "--size", "UNSIZED", "--done-when", "a" },
        backend
    )
    testing.eq(refused.code, 2)
    testing.ok(refused.message:find("a size", 1, true), refused.message)
    testing.eq(#backend.calls, calls)
    cmd_board.run(
        "add",
        { "X", "--column", support.COLUMN.ICEBOX, "--size", "UNSIZED", "--description", "loose" },
        backend
    )
    testing.eq(
        backend.calls[#backend.calls],
        { "add", "X", support.COLUMN_NAME.ICEBOX, "loose", "white" }
    )
    local result = cmd_board.run("add", { "X", "--size", "4" }, backend)
    testing.eq(result.code, 2)
    testing.ok(result.message:find("unknown size 4", 1, true), result.message)
    testing.eq(cmd_board.run("add", { "X", "--size" }, backend).code, 2)
end)

testing.test("size sets the colour of each size word and resolves the card by prefix", function()
    local backend = fake(sample())
    local want = { ["1"] = "yellow", ["2"] = "green", ["3"] = "blue", ["3+"] = "red" }
    for word, color in pairs(want) do
        local result = cmd_board.run("size", { "cccccccc", word }, backend)
        testing.eq(result.output, "sized cccccccc " .. word)
        testing.eq(backend.calls[#backend.calls], { "set_size", ID_C, color, nil })
    end
end)

testing.test("size unsized is refused outside Icebox and works inside it", function()
    local backend = fake(sample())
    local result = cmd_board.run("size", { "cccccccc", "unsized" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("keeps a size", 1, true), result.message)
    testing.eq(#backend.calls, 0)
    local cards = sample()
    cards[3].column = support.COLUMN_NAME.ICEBOX
    backend = fake(cards)
    result = cmd_board.run("size", { "cccccccc", "unsized" }, backend)
    testing.eq(result.output, "sized cccccccc unsized")
    testing.eq(backend.calls[#backend.calls], { "set_size", ID_C, "white", nil })
end)

testing.test("size refuses a bad size, a missing argument and an unknown card", function()
    local backend = fake(sample())
    local result = cmd_board.run("size", { "cccccccc", "4" }, backend)
    testing.eq(result.code, 2)
    testing.ok(result.message:find("the sizes are 1, 2, 3, 3+, unsized", 1, true), result.message)
    testing.eq(cmd_board.run("size", { "cccccccc" }, backend).code, 2)
    testing.eq(cmd_board.run("size", { "cccccccc", "2", "3" }, backend).code, 2)
    result = cmd_board.run("size", { "deadbeef", "2" }, backend)
    testing.eq(result.code, 1)
    testing.eq(#backend.calls, 0)
end)

testing.test("ls --size keeps the cards of one colour and counts no colour as unsized", function()
    local cards = sample()
    cards[1].color = "yellow"
    cards[2].color = "white"
    cards[3].color = "blue"
    local result = cmd_board.run("ls", { "--size", "1" }, fake(cards))
    testing.eq(result.output, "11111111  Ready  1 Pomodoro  docs  Write docs")
    result = cmd_board.run("ls", { "--size", "unsized" }, fake(cards))
    testing.eq(result.output, "11111111  Backlog  unsized  -  Fix lint")
    cards[2].color = nil
    result = cmd_board.run("ls", { "--size", "unsized" }, fake(cards))
    testing.eq(result.output, "11111111  Backlog  unsized  -  Fix lint")
    result = cmd_board.run("ls", { "--size", "3", "--column", support.COLUMN.DONE }, fake(cards))
    testing.eq(result.output, "cccccccc  Done  unsized  -  Old thing")
    result = cmd_board.run("ls", { "--size", "2" }, fake(cards))
    testing.eq(result.output, "No cards.")
    testing.eq(cmd_board.run("ls", { "--size", "9" }, fake(cards)).code, 2)
end)

testing.test("add --label may repeat and drops a duplicate", function()
    local backend = fake(sample())
    cmd_board.run("add", {
        "X",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
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
    testing.eq(
        backend.calls[1],
        { "add", "X", support.COLUMN_NAME.BACKLOG, COMPOSED, "green", { "a", "needs:lead" } }
    )
    cmd_board.run("add", {
        "X",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "2",
        "--done-when",
        "a",
    }, backend)
    testing.eq(
        backend.calls[2],
        { "add", "X", support.COLUMN_NAME.BACKLOG, COMPOSED, "green", nil }
    )
end)

testing.test("label adds and removes labels and sends the whole list", function()
    local backend = fake(sample())
    local result = cmd_board.run("label", { "11111111-a", "+needs:lead", "+x" }, backend)
    testing.eq(result.output, "labelled 11111111 docs,needs:lead,x")
    testing.eq(backend.calls[1], { "set_labels", ID_A, { "docs", "needs:lead", "x" }, nil })
    result = cmd_board.run("label", { "11111111-a", "--remove", "docs" }, backend)
    testing.eq(result.output, "labelled 11111111 -")
    testing.eq(backend.calls[2], { "set_labels", ID_A, {}, nil })
    result = cmd_board.run("label", { "11111111-a", "new", "--remove", "new", "+docs" }, backend)
    testing.eq(result.output, "labelled 11111111 docs")
    testing.eq(#backend.calls, 2)
    result = cmd_board.run(
        "label",
        { "11111111-a", "x", "--remove", "docs", "--remove", "x", "y" },
        backend
    )
    testing.eq(result.output, "labelled 11111111 y")
    testing.eq(backend.calls[3], { "set_labels", ID_A, { "y" }, nil })
end)

testing.test("label still replays a queued leading-dash removal", function()
    local backend = fake(sample())
    local result =
        cmd_board.run("label", { "11111111-a", "-docs", "+new", "-new", "+docs" }, backend)
    testing.eq(result.output, "labelled 11111111 docs")
    result = cmd_board.run("label", { "11111111-a", "-docs" }, backend)
    testing.eq(result.output, "labelled 11111111 -")
    testing.eq(backend.calls[1], { "set_labels", ID_A, {}, nil })
end)

testing.test("adding a label the card has or removing one it lacks sends nothing", function()
    local backend = fake(sample())
    testing.eq(
        cmd_board.run("label", { "11111111-a", "+docs" }, backend).output,
        "labelled 11111111 docs"
    )
    testing.eq(
        cmd_board.run("label", { "11111111-a", "--remove", "nope" }, backend).output,
        "labelled 11111111 docs"
    )
    testing.eq(#backend.calls, 0)
end)

testing.test("label refuses a bad label, a bad --remove value and a missing card", function()
    local backend = fake(sample())
    for _, word in ipairs({ "+two words", "+--x", "+", "-", "+a\tb", "two words" }) do
        testing.eq(cmd_board.run("label", { "11111111-a", word }, backend).code, 2)
    end
    testing.eq(cmd_board.run("label", { "11111111-a", "--remove" }, backend).code, 2)
    testing.eq(cmd_board.run("label", { "11111111-a", "--remove", "a b" }, backend).code, 2)
    testing.eq(cmd_board.run("label", { "11111111-a", "--remove", "-a" }, backend).code, 2)
    testing.eq(cmd_board.run("label", { "11111111-a" }, backend).code, 2)
    testing.eq(cmd_board.run("add", { "X", "--label", "a b" }, backend).code, 2)
    testing.eq(cmd_board.run("add", { "X", "--label", "-a" }, backend).code, 2)
    testing.eq(cmd_board.run("label", { "deadbeef", "+x" }, backend).code, 1)
    testing.eq(#backend.calls, 0)
end)

testing.test("edit sends the whole new description and prints one line", function()
    local backend = fake(sample())
    local text = "## Problem\nnew plan\n\n## Change\n- x\n\n## Out of scope\nnone"
    local result = cmd_board.run("edit", { "11111111-a", text }, backend)
    testing.eq(result.output, "edited 11111111")
    testing.eq(backend.calls[1], { "set_description", ID_A, text, nil })
end)

testing.test("edit --board changes the description on the named board", function()
    local backend = fake(sample())
    local sibling = fake(sample())
    backend.sibling = sibling
    local text = "## Problem\nnew plan\n\n## Change\n- x\n\n## Out of scope\nnone"
    local result = cmd_board.run("edit", { "11111111-a", "--board", "ci", text }, backend)
    testing.eq(result.output, "edited 11111111")
    testing.eq(backend.calls, { { "other_board", "ci" } })
    testing.eq(sibling.calls[#sibling.calls], { "set_description", ID_A, text, nil })
end)

testing.test("edit --board refuses a board that is not there", function()
    local backend = fake(sample())
    local result = cmd_board.run("edit", { "11111111-a", "--board", "nope", "text" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("no board named nope", 1, true), result.message)
    result = cmd_board.run("edit", { "11111111-a", "--board" }, backend)
    testing.eq(result.code, 2)
    testing.eq(#backend.calls, 1)
end)

testing.test("edit outside Icebox refuses a text that drops a v3 section", function()
    local backend = fake(sample())
    local result = cmd_board.run("edit", { "11111111-a", "## Problem\nnew plan" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("## Change, ## Out of scope", 1, true), result.message)
    testing.eq(#backend.calls, 0)
    local cards = sample()
    cards[1].column = support.COLUMN_NAME.ICEBOX
    backend = fake(cards)
    testing.eq(cmd_board.run("edit", { "11111111-a", "loose" }, backend).code, nil)
    testing.eq(#backend.calls, 1)
end)

testing.test("rename sends the new title and prints renamed", function()
    local backend = fake(sample())
    local result = cmd_board.run("rename", { "11111111-a", "Better", "title" }, backend)
    testing.eq(result.output, "renamed 11111111")
    testing.eq(backend.calls[1], { "set_name", ID_A, "Better title", nil })
    testing.eq(cmd_board.run("rename", { "11111111-a" }, backend).code, 2)
    testing.eq(cmd_board.run("rename", { "11111111-a", "  " }, backend).code, 2)
    testing.eq(cmd_board.run("rename", { "11111111-a", "x", "--force" }, backend).code, 2)
    testing.eq(cmd_board.run("rename", { "11111111-a", 'say "hi"' }, backend).code, 2)
    testing.eq(cmd_board.run("rename", { "deadbeef", "x" }, backend).code, 2)
    testing.eq(#backend.calls, 1)
end)

testing.test("rename of a missing card is a usage error", function()
    local backend = fake(sample())
    local result = cmd_board.run("rename", { "deadbeef", "x" }, backend)
    testing.eq(result.code, 2)
    testing.eq(#backend.calls, 0)
end)

testing.test("rename of a card on an unreadable board still fails with exit 1", function()
    local backend = fake(sample())
    backend.cards = function()
        return nil, "board unavailable"
    end
    local result = cmd_board.run("rename", { "11111111-a", "x" }, backend)
    testing.eq(result.code, 1)
    testing.eq(result.message, "board unavailable")
end)

testing.test("discard posts the reason, labels the card and moves it to Done", function()
    local backend = fake(sample())
    local result = cmd_board.run("discard", { "11111111-a", "--reason", "Not needed" }, backend)
    testing.eq(result.output, "discarded 11111111")
    testing.eq(backend.calls[1], { "note", ID_A, "Not needed", { kind = "decision" } })
    testing.eq(backend.calls[2][1], "set_labels")
    testing.ok(table.concat(backend.calls[2][3], ","):find("discarded", 1, true) ~= nil)
    testing.eq(backend.calls[3], { "move", ID_A, support.COLUMN_NAME.DONE })
    testing.eq(#backend.calls, 3)
end)

testing.test("discard without a reason only labels and moves, and refuses a blank one", function()
    local backend = fake(sample())
    local result = cmd_board.run("discard", { "11111111-a" }, backend)
    testing.eq(result.output, "discarded 11111111")
    testing.eq(#backend.calls, 2)
    testing.eq(backend.calls[2], { "move", ID_A, support.COLUMN_NAME.DONE })
    testing.eq(cmd_board.run("discard", { "11111111-a", "--reason", " " }, backend).code, 2)
    testing.eq(cmd_board.run("discard", {}, backend).code, 2)
    testing.eq(cmd_board.run("discard", { "deadbeef" }, backend).code, 1)
    testing.eq(#backend.calls, 2)
end)

testing.test("discard refuses a needs:human card before anything is written", function()
    local cards = sample()
    cards[1].labels = { "needs:human" }
    local backend = fake(cards)
    local result = cmd_board.run("discard", { "11111111-a", "--reason", "Dropped" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("needs:human", 1, true), result.message)
    testing.eq(#backend.calls, 0)
end)

testing.test("discard --board discards the card on the named board", function()
    local backend = fake(sample())
    local sibling = fake(sample())
    backend.sibling = sibling
    local result = cmd_board.run(
        "discard",
        { "11111111-a", "--board", "ci", "--reason", "Duplicate" },
        backend
    )
    testing.eq(result.output, "discarded 11111111")
    testing.eq(backend.calls, { { "other_board", "ci" } })
    testing.eq(sibling.calls[#sibling.calls - 1][1], "set_labels")
    testing.eq(
        sibling.calls[#sibling.calls - 2],
        { "note", ID_A, "Duplicate", { kind = "decision" } }
    )
    testing.eq(sibling.calls[#sibling.calls], { "move", ID_A, support.COLUMN_NAME.DONE })
end)

testing.test("discard --board queues no step a failed write leaves", function()
    local backend = fake(sample())
    local sibling = fake(sample())
    backend.sibling = sibling
    function sibling:set_labels()
        return false, "boom"
    end
    local result = cmd_board.run("discard", { "11111111-a", "--board", "ci" }, backend)
    testing.eq(result.code, 1)
    testing.eq(result.unqueued, true)
    testing.eq(result.queue, nil)
    testing.eq(backend.calls, { { "other_board", "ci" } })
end)

testing.test("discard --board refuses a board that is not there", function()
    local backend = fake(sample())
    local result = cmd_board.run("discard", { "11111111-a", "--board", "nope" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("no board named nope", 1, true), result.message)
    result = cmd_board.run("discard", { "11111111-a", "--board" }, backend)
    testing.eq(result.code, 2)
    testing.eq(#backend.calls, 1)
end)

testing.test("move to Done refuses a card with unticked outcomes and names them", function()
    local cards = sample()
    cards[1].outcomes = {
        { id = "s1", name = "A works", done = true },
        { id = "s2", name = "B works", done = false },
        { id = "s3", name = "C works", done = false },
    }
    local backend = fake(cards)
    local result = cmd_board.run("move", { "11111111-a", support.COLUMN.DONE }, backend)
    testing.eq(result.code, 1)
    testing.eq(result.unqueued, true)
    testing.eq(
        result.message,
        "Card 11111111 cannot move to Done. 2 of 3 outcomes are unticked (2. B works, 3. C works). "
            .. "The reviewer ticks them with `dev board outcome CARD --tick N --as NAME`, "
            .. "or `dev board discard CARD` drops it."
    )
    testing.eq(#backend.calls, 0)
end)

testing.test("move to Done takes a planned card whose outcomes are all ticked", function()
    local cards = sample()
    cards[1].outcomes = { { id = "s1", name = "A works", done = true } }
    local backend = fake(cards)
    testing.eq(
        cmd_board.run("move", { "11111111-a", support.COLUMN.DONE }, backend).output,
        "moved 11111111 to Done"
    )
    testing.eq(backend.calls[#backend.calls], { "move", ID_A, support.COLUMN_NAME.DONE })
end)

testing.test("move refuses an unsized card into every column but Icebox", function()
    for _, column in ipairs({
        support.COLUMN.BACKLOG,
        support.COLUMN.READY,
        support.COLUMN.PROGRESS,
        support.COLUMN.REVIEW,
        support.COLUMN.BLOCKED,
        support.COLUMN.DONE,
    }) do
        local backend = fake(sample())
        local result = cmd_board.run("move", { "cccccccc", column }, backend)
        testing.eq(result.code, 1, column)
        testing.ok(result.message:find("size", 1, true), result.message)
        testing.eq(#backend.calls, 0, column)
    end
    local backend = fake(sample())
    testing.eq(cmd_board.run("move", { "cccccccc", support.COLUMN.ICEBOX }, backend).code, nil)
    testing.eq(backend.calls, { { "move", ID_C, support.COLUMN_NAME.ICEBOX } })
end)

testing.test("an unsized umbrella refusal names the size and not outcomes", function()
    local card = planned()
    card.color = nil
    card.size = "unsized"
    card.epic = { done = 0, total = 2 }
    local backend = fake({ card })
    backend.kin = { children = card.epic }
    local result = cmd_board.run("move", { "cccccccc", support.COLUMN.PROGRESS }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("It lacks a size.", 1, true), result.message)
    testing.ok(not result.message:find("outcomes", 1, true), result.message)
    for _, call in ipairs(backend.calls) do
        testing.ok(call[1] ~= "move", "the refused move was sent")
    end
end)

testing.test("an unsized card with no children still names size and outcomes", function()
    local card = planned()
    card.color = nil
    card.size = "unsized"
    local backend = fake({ card })
    local result = cmd_board.run("move", { "cccccccc", support.COLUMN.PROGRESS }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("It lacks a size, Done when outcomes.", 1, true), result.message)
    testing.eq(#backend.calls, 0)
end)

testing.test("move refuses a sized card that lacks a section or outcomes outside Icebox", function()
    for _, column in ipairs({
        support.COLUMN.BACKLOG,
        support.COLUMN.PROGRESS,
        support.COLUMN.REVIEW,
        support.COLUMN.BLOCKED,
        support.COLUMN.DONE,
    }) do
        local card = planned()
        card.description = "loose idea"
        local backend = fake({ card })
        local result = cmd_board.run("move", { "cccccccc", column }, backend)
        testing.eq(result.code, 1, column)
        testing.ok(result.message:find("## Change", 1, true), result.message)
        testing.eq(#backend.calls, 0, column)
        card = planned()
        card.description = V2
        backend = fake({ card })
        result = cmd_board.run("move", { "cccccccc", column }, backend)
        testing.eq(result.code, 1, column)
        testing.ok(result.message:find("Done when outcomes", 1, true), result.message)
        testing.eq(#backend.calls, 0, column)
    end
end)

testing.test("an epic moves to Done once every child is Done and its outcome is ticked", function()
    local card = planned()
    card.epic = { done = 3, total = 3 }
    card.outcomes = { { id = "s1", name = "a", done = true } }
    local backend = fake({ card })
    backend.kin = { children = card.epic }
    local result = cmd_board.run("move", { "cccccccc", support.COLUMN.DONE }, backend)
    testing.eq(result.output, "moved cccccccc to Done")
    testing.eq(backend.calls[#backend.calls], { "move", ID_C, support.COLUMN_NAME.DONE })
end)

testing.test("epic_move_refused", function()
    local card = planned()
    card.column = support.COLUMN_NAME.READY
    card.epic = { done = 1, total = 3 }
    card.outcomes = { { id = "s1", name = "a", done = true } }
    local backend = fake({ card })
    backend.kin = { children = card.epic }
    backend.limited = { support.COLUMN_NAME.REVIEW }
    local result = cmd_board.run("move", { "cccccccc", support.COLUMN.DONE }, backend)
    testing.eq(result.code, 1)
    testing.eq(result.unqueued, true)
    testing.eq(
        result.message,
        "Card cccccccc is an epic and cannot enter Done, a done column. 2 of 3 children are open."
    )
    result = cmd_board.run("move", { "cccccccc", support.COLUMN.REVIEW }, backend)
    testing.eq(result.code, 1)
    testing.eq(
        result.message,
        "Card cccccccc is an epic and cannot enter Review, a WIP-limited column. "
            .. "2 of 3 children are open."
    )
    for _, call in ipairs(backend.calls) do
        testing.ok(call[1] ~= "move", "the refused move was sent")
    end
    testing.eq(cmd_board.run("move", { "cccccccc", support.COLUMN.BACKLOG }, backend).code, nil)
end)

testing.test("an epic with every child Done closes without outcomes", function()
    local card = planned()
    card.epic = { done = 3, total = 3 }
    local backend = fake({ card })
    backend.kin = { children = card.epic }
    local result = cmd_board.run("move", { "cccccccc", support.COLUMN.DONE }, backend)
    testing.eq(result.output, "moved cccccccc to Done")
    testing.eq(backend.calls[#backend.calls], { "move", ID_C, support.COLUMN_NAME.DONE })
end)

testing.test("an epic with no outcomes and an open child is refused", function()
    local card = planned()
    card.column = support.COLUMN_NAME.READY
    card.epic = { done = 1, total = 3 }
    local backend = fake({ card })
    backend.kin = { children = card.epic }
    local result = cmd_board.run("move", { "cccccccc", support.COLUMN.DONE }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("Done when outcomes", 1, true), result.message)
    card.outcomes = { { id = "s1", name = "a", done = true } }
    result = cmd_board.run("move", { "cccccccc", support.COLUMN.DONE }, backend)
    testing.eq(result.code, 1)
    testing.eq(
        result.message,
        "Card cccccccc is an epic and cannot enter Done, a done column. 2 of 3 children are open."
    )
    for _, call in ipairs(backend.calls) do
        testing.ok(call[1] ~= "move", "the refused move was sent")
    end
end)

testing.test("an epic with no children needs outcomes to close", function()
    local card = planned()
    card.column = support.COLUMN_NAME.READY
    card.epic = { done = 0, total = 0 }
    local backend = fake({ card })
    backend.kin = { children = card.epic }
    local result = cmd_board.run("move", { "cccccccc", support.COLUMN.DONE }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("Done when outcomes", 1, true), result.message)
    for _, call in ipairs(backend.calls) do
        testing.ok(call[1] ~= "move", "the refused move was sent")
    end
end)

testing.test("an epic with every child Done still needs 3 or fewer outcomes to close", function()
    local card = planned()
    card.epic = { done = 3, total = 3 }
    card.outcomes = {
        { id = "s1", name = "a", done = true },
        { id = "s2", name = "b", done = true },
        { id = "s3", name = "c", done = true },
        { id = "s4", name = "d", done = true },
    }
    local backend = fake({ card })
    backend.kin = { children = card.epic }
    local result = cmd_board.run("move", { "cccccccc", support.COLUMN.DONE }, backend)
    testing.eq(result.code, 1)
    testing.ok(
        result.message:find("1 to 3 Done when outcomes for an epic, not 4", 1, true),
        result.message
    )
    for _, call in ipairs(backend.calls) do
        testing.ok(call[1] ~= "move", "the refused move was sent")
    end
end)

testing.test("discard closes an epic whose children are open", function()
    local backend = fake({ planned() })
    backend.kin = { children = { done = 0, total = 2 } }
    local result = cmd_board.run("discard", { "cccccccc", "--reason", "Dropped" }, backend)
    testing.eq(result.output, "discarded cccccccc")
    for _, call in ipairs(backend.calls) do
        testing.ok(call[1] ~= "family", "discard read the children")
    end
end)

testing.test(
    "an epic needs an outcome to enter a working column like a card without children",
    function()
        local card = planned()
        card.epic = { done = 0, total = 2 }
        local backend = fake({ card })
        backend.kin = { children = card.epic }
        testing.eq(cmd_board.run("move", { "cccccccc", support.COLUMN.BACKLOG }, backend).code, 1)
        card.outcomes = { { id = "s1", name = "a", done = false } }
        testing.eq(cmd_board.run("move", { "cccccccc", support.COLUMN.BACKLOG }, backend).code, nil)
        testing.eq(cmd_board.run("move", { "cccccccc", support.COLUMN.REVIEW }, backend).code, nil)
        backend = fake({ planned() })
        testing.eq(cmd_board.run("move", { "cccccccc", support.COLUMN.REVIEW }, backend).code, 1)
    end
)

testing.test("an unsized epic is refused and a red one is allowed", function()
    local card = planned()
    card.color = nil
    card.epic = { done = 0, total = 2 }
    card.outcomes = { { id = "s1", name = "a", done = false } }
    local backend = fake({ card })
    backend.kin = { children = card.epic }
    testing.eq(cmd_board.run("move", { "cccccccc", support.COLUMN.BACKLOG }, backend).code, 1)
    card.color = "red"
    backend = fake({ card })
    backend.kin = { children = card.epic }
    testing.eq(cmd_board.run("move", { "cccccccc", support.COLUMN.BACKLOG }, backend).code, nil)
end)

testing.test(
    "discard refuses an unsized card or one without sections, and takes one without outcomes",
    function()
        local card = planned()
        card.color = nil
        local backend = fake({ card })
        local result = cmd_board.run("discard", { "cccccccc", "--reason", "Dropped" }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("a size", 1, true), result.message)
        card.column = support.COLUMN_NAME.ICEBOX
        result = cmd_board.run("discard", { "cccccccc" }, fake({ card }))
        testing.eq(result.code, 1)
        card.color = "green"
        card.description = "loose"
        result = cmd_board.run("discard", { "cccccccc" }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("## Change", 1, true), result.message)
        testing.eq(#backend.calls, 0)
        card.description = V2
        testing.eq(cmd_board.run("discard", { "cccccccc" }, backend).output, "discarded cccccccc")
    end
)

testing.test("move to Done refuses outcomes dev cannot read", function()
    local cards = sample()
    cards[1].outcomes_unreadable = true
    local backend = fake(cards)
    local result = cmd_board.run("move", { "11111111-a", support.COLUMN.DONE }, backend)
    testing.eq(result.code, 1)
    testing.eq(result.unqueued, true)
    testing.eq(
        result.message,
        "Card 11111111 cannot move to Done. Its outcomes cannot be read from Pomb. They cannot be checked."
    )
    testing.eq(#backend.calls, 0)
end)

local SHIPPED = "Shipped"

local function shipped_backend(card)
    local backend = fake({ card }, nil, { SHIPPED })
    backend.column_map = { done = SHIPPED }
    return backend
end

testing.test("move to Done names a renamed Done column for unreadable outcomes", function()
    local card = sample()[1]
    card.outcomes_unreadable = true
    local backend = shipped_backend(card)
    local result = cmd_board.run("move", { "11111111-a", SHIPPED }, backend)
    testing.eq(result.code, 1)
    testing.eq(
        result.message,
        "Card 11111111 cannot move to "
            .. SHIPPED
            .. ". Its outcomes cannot be read from Pomb. They cannot be checked."
    )
    testing.eq(#backend.calls, 0)
end)

testing.test("move to Done names a renamed Done column for unticked outcomes", function()
    local card = sample()[1]
    card.outcomes = { { id = "s1", name = "A works", done = false } }
    local backend = shipped_backend(card)
    local result = cmd_board.run("move", { "11111111-a", SHIPPED }, backend)
    testing.eq(result.code, 1)
    testing.ok(
        result.message:find("cannot move to " .. SHIPPED .. ". 1 of 1 outcomes", 1, true),
        result.message
    )
    testing.eq(#backend.calls, 0)
end)

testing.test("move to Ready refuses outcomes dev cannot read", function()
    local cards = sample()
    cards[1].column = support.COLUMN_NAME.BACKLOG
    cards[1].outcomes_unreadable = true
    local result = cmd_board.run("move", { "11111111-a", support.COLUMN.READY }, fake(cards))
    testing.eq(result.code, 1)
    testing.eq(
        result.message,
        "Card 11111111 cannot move to Ready. Its outcomes cannot be read from Pomb. They cannot be checked."
    )
end)

testing.test("move to Ready with unreadable outcomes sends no move", function()
    local cards = sample()
    cards[1].column = support.COLUMN_NAME.BACKLOG
    cards[1].outcomes_unreadable = true
    local backend = fake(cards)
    cmd_board.run("move", { "11111111-a", support.COLUMN.READY }, backend)
    testing.eq(#backend.calls, 0)
end)

testing.test("move to Ready still counts outcomes dev can read", function()
    local cards = sample()
    cards[1].column = support.COLUMN_NAME.BACKLOG
    cards[1].outcomes = { { id = "s1", name = "a", done = false } }
    local result = cmd_board.run("move", { "11111111-a", support.COLUMN.READY }, fake(cards))
    testing.eq(result.code, 1)
    testing.ok(result.message:find("3 to 7 Done when outcomes, not 1", 1, true), result.message)
end)

testing.test("move to a working column does not demand outcomes dev cannot read", function()
    local cards = sample()
    cards[1].outcomes_unreadable = true
    local backend = fake(cards)
    local result = cmd_board.run("move", { "11111111-a", support.COLUMN.REVIEW }, backend)
    testing.eq(result.code, nil)
end)

testing.test("move to Done is never queued when the card cannot be read", function()
    local backend = fake(sample())
    local message = "board unavailable: cannot reach pomb.example (curl exit 7)"
    backend.cards = function()
        return nil, message
    end
    local result = cmd_board.run("move", { "11111111-a", support.COLUMN.DONE }, backend)
    testing.eq(result.message, message)
    testing.eq(result.unqueued, true)
    result = cmd_board.run("move", { "11111111-a", support.COLUMN.REVIEW }, backend)
    testing.eq(result.message, message)
    testing.eq(result.unqueued, nil)
end)

testing.test("discard closes a card with unticked outcomes", function()
    local cards = sample()
    cards[1].outcomes = { { id = "s1", name = "A works", done = false } }
    local backend = fake(cards)
    local result = cmd_board.run("discard", { "11111111-a", "--reason", "Dropped" }, backend)
    testing.eq(result.output, "discarded 11111111")
    testing.eq(backend.calls[#backend.calls], { "move", ID_A, support.COLUMN_NAME.DONE })
end)

testing.test("checks replaces the rows with one row per command", function()
    local backend = fake(sample())
    local result = cmd_board.run("checks", { "11111111-a", "dev lint", "dev test" }, backend)
    testing.eq(result.output, "set checks 11111111, 2 rows")
    testing.eq(backend.calls[1], { "set_checks", ID_A, { "dev lint", "dev test" }, nil })
    result = cmd_board.run("checks", { "11111111-a", "dev lint" }, fake(sample()))
    testing.eq(result.output, "set checks 11111111, 1 row")
end)

testing.test("checks refuses the rows add --checks refuses and writes nothing", function()
    for _, row in ipairs({ "rg 'a' f", "rg a.*b f", "dev.--remote.lint", "rg a|b" }) do
        local backend = fake(sample())
        local result = cmd_board.run("checks", { "11111111-a", "dev lint", row }, backend)
        testing.eq(result.code, 2)
        testing.ok(result.message:find(row, 1, true), result.message)
        testing.eq(#backend.calls, 0)
    end
    local backend = fake(sample())
    testing.eq(
        cmd_board.run("checks", { "11111111-a", "! rg -q a f" }, backend).output,
        "set checks 11111111, 1 row"
    )
end)

testing.test(
    "checks refuses no command, a blank command, an unknown card and a board without the field",
    function()
        local backend = fake(sample())
        testing.eq(cmd_board.run("checks", { "11111111-a" }, backend).code, 2)
        testing.eq(cmd_board.run("checks", {}, backend).code, 2)
        testing.eq(cmd_board.run("checks", { "11111111-a", "dev lint", " " }, backend).code, 2)
        testing.eq(cmd_board.run("checks", { "deadbeef", "dev lint" }, backend).code, 1)
        backend.nofield = true
        local result = cmd_board.run("checks", { "11111111-a", "dev lint" }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("no checks field", 1, true), result.message)
        testing.ok(result.message:find("dev board init", 1, true), result.message)
        testing.eq(#backend.calls, 0)
    end
)

testing.test("allow replaces the field with the words once each, and none sends null", function()
    local backend = fake(sample())
    local result =
        cmd_board.run("allow", { "11111111-a", "ci-edits", "test-edits", "ci-edits" }, backend)
    testing.eq(result.output, "set allow 11111111, ci-edits test-edits")
    testing.eq(
        backend.calls[1],
        { "set_field", ID_A, "dev.allow", { "ci-edits", "test-edits" }, nil }
    )
    result = cmd_board.run("allow", { "11111111-a", "none" }, backend)
    testing.eq(result.output, "cleared allow 11111111")
    testing.eq(backend.calls[2], { "set_field", ID_A, "dev.allow", json.null, nil })
end)

testing.test(
    "allow refuses no word, another word, none beside a word, an unknown card and a board without the field",
    function()
        local backend = fake(sample())
        testing.eq(cmd_board.run("allow", { "11111111-a" }, backend).code, 2)
        testing.eq(cmd_board.run("allow", {}, backend).code, 2)
        testing.eq(cmd_board.run("allow", { "11111111-a", "everything" }, backend).code, 2)
        testing.eq(cmd_board.run("allow", { "11111111-a", "test-edits", "none" }, backend).code, 2)
        testing.eq(cmd_board.run("allow", { "deadbeef", "none" }, backend).code, 1)
        backend.nofield = true
        local result = cmd_board.run("allow", { "11111111-a", "test-edits" }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("no dev.allow field", 1, true), result.message)
        testing.eq(#backend.calls, 0)
    end
)

testing.test("tests and files replace the field with one name per line", function()
    local backend = fake(sample())
    local result =
        cmd_board.run("tests", { "11111111-a", "one_should_be_one", "tests::two" }, backend)
    testing.eq(result.output, "set tests 11111111, 2 names")
    testing.eq(
        backend.calls[1],
        { "set_field", ID_A, "dev.tests", "one_should_be_one\ntests::two", nil }
    )
    result = cmd_board.run("files", { "11111111-a", "src/a.rs" }, backend)
    testing.eq(result.output, "set files 11111111, 1 name")
    testing.eq(backend.calls[2], { "set_field", ID_A, "dev.files", "src/a.rs", nil })
end)

testing.test(
    "tests and files refuse no name, a blank name, a line break, an unknown card and a board without the field",
    function()
        local backend = fake(sample())
        for _, sub in ipairs({ "tests", "files" }) do
            testing.eq(cmd_board.run(sub, { "11111111-a" }, backend).code, 2)
            testing.eq(cmd_board.run(sub, {}, backend).code, 2)
            testing.eq(cmd_board.run(sub, { "11111111-a", "a", " " }, backend).code, 2)
            testing.eq(cmd_board.run(sub, { "11111111-a", "a\nb" }, backend).code, 2)
            testing.eq(cmd_board.run(sub, { "deadbeef", "a" }, backend).code, 1)
        end
        backend.nofield = true
        local result = cmd_board.run("files", { "11111111-a", "a" }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("no dev.files field", 1, true), result.message)
        result = cmd_board.run("tests", { "11111111-a", "a" }, backend)
        testing.ok(result.message:find("no dev.tests field", 1, true), result.message)
        testing.eq(#backend.calls, 0)
    end
)

testing.test("edit refuses a missing text, an extra word and an unknown card", function()
    local backend = fake(sample())
    testing.eq(cmd_board.run("edit", { "11111111-a" }, backend).code, 2)
    testing.eq(cmd_board.run("edit", { "11111111-a", "x", "y" }, backend).code, 2)
    testing.eq(cmd_board.run("edit", { "deadbeef", "x" }, backend).code, 1)
    testing.eq(#backend.calls, 0)
end)

testing.test("link sends the full ids of the card and the other card", function()
    local backend = fake(sample())
    local result = cmd_board.run("link", { "11111111-a", "blocked_by", "cccccccc" }, backend)
    testing.eq(result.output, "linked 11111111 blocked_by cccccccc")
    testing.eq(backend.calls[1], { "link", ID_A, "blocked_by", ID_C })
    result = cmd_board.run("link", { "cccccccc", "blocks", "11111111-b" }, backend)
    testing.eq(result.output, "linked cccccccc blocks 11111111")
    testing.eq(backend.calls[2], { "link", ID_C, "blocks", ID_B })
    result = cmd_board.run("link", { "cccccccc", "related", "11111111-a" }, backend)
    testing.eq(backend.calls[3], { "link", ID_C, "related", ID_A })
end)

testing.test("link to BOARD:CARD resolves the card on the other board", function()
    local backend = fake(sample())
    local elsewhere = {
        cards = function()
            return {
                {
                    id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                    name = "Far",
                    column = support.COLUMN_NAME.READY,
                    size = "unsized",
                    labels = {},
                    checks = {},
                },
            }
        end,
    }
    backend.sibling = elsewhere
    local result = cmd_board.run("link", { "11111111-a", "blocked_by", "ci:dddddddd" }, backend)
    testing.eq(result.output, "linked 11111111 blocked_by ci:dddddddd")
    testing.eq(backend.calls[1], { "other_board", "ci" })
    testing.eq(
        backend.calls[2],
        { "link", ID_A, "blocked_by", "dddddddd-dddd-4ddd-8ddd-dddddddddddd" }
    )
    result = cmd_board.run("link", { "11111111-a", "parent", "ci:dddddddd" }, backend)
    testing.eq(result.code, 1)
    testing.eq(
        result.message,
        "Card ci:dddddddd is not an epic. Make it one with `dev board epic dddddddd` from the project that owns that board."
    )
    result = cmd_board.run("link", { "11111111-a", "related", "nope:dddddddd" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("no board named nope", 1, true), result.message)
    result = cmd_board.run("link", { "11111111-a", "related", "ci:eeeeeeee" }, backend)
    testing.eq(result.code, 1)
    testing.eq(result.message, "No card starts with eeeeeeee.")
    testing.eq(#backend.calls, 5)
end)

testing.test("link names the BOARD:PREFIX form when a bare prefix matches no card", function()
    local backend = fake(sample())
    local result = cmd_board.run("link", { "11111111-a", "blocked_by", "eeeeeeee" }, backend)
    testing.eq(result.code, 1)
    testing.eq(
        result.message,
        "No card starts with eeeeeeee. For a card on another board, give BOARD:PREFIX."
    )
end)

testing.test("links lists each link with the kind, the id prefix and the board", function()
    local backend = fake(sample())
    backend.held = {
        { kind = "blocked_by", id = ID_C },
        { kind = "blocks", id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd", board = "ci" },
        { kind = "related", id = ID_B },
    }
    local result = cmd_board.run("links", { "11111111-a" }, backend)
    testing.eq(
        result.output,
        "blocked_by  cccccccc  -\nblocks      dddddddd  ci\nrelated     11111111  -"
    )
    testing.eq(backend.calls[1], { "links", ID_A })
    testing.eq(cmd_board.run("links", { "11111111-b" }, fake(sample())).output, "No links.")
    testing.eq(cmd_board.run("links", {}, backend).code, 2)
    testing.eq(cmd_board.run("links", { "deadbeef" }, backend).code, 1)
end)

testing.test(
    "unlink removes the held link of that kind and target, and refuses one it lacks",
    function()
        local backend = fake(sample())
        backend.held = { { kind = "blocked_by", id = ID_C }, { kind = "related", id = ID_B } }
        local result = cmd_board.run("unlink", { "11111111-a", "blocked_by", "cccccccc" }, backend)
        testing.eq(result.output, "unlinked 11111111 blocked_by cccccccc")
        testing.eq(backend.calls[2], { "unlink", ID_A, "blocked_by", ID_C })
        result = cmd_board.run("unlink", { "11111111-a", "blocks", "cccccccc" }, backend)
        testing.eq(result.code, 1)
        testing.eq(
            result.message,
            "The card holds no blocks link to cccccccc. Its links are listed below.\n"
                .. "blocked_by  cccccccc  -\nrelated     11111111  -"
        )
        testing.eq(backend.calls[3], { "links", ID_A })
        backend.held = {}
        result = cmd_board.run("unlink", { "11111111-a", "related", "cccccccc" }, backend)
        testing.eq(result.message, "The card holds no related link to cccccccc. It holds no links.")
        testing.eq(cmd_board.run("unlink", { "11111111-a", "blocked_by" }, backend).code, 2)
        testing.eq(
            cmd_board.run("unlink", { "11111111-a", "depends", "cccccccc" }, backend).code,
            2
        )
        testing.eq(
            cmd_board.run("unlink", { "deadbeef", "blocked_by", "cccccccc" }, backend).code,
            1
        )
        testing.eq(
            cmd_board.run("unlink", { "11111111-a", "blocked_by", "deadbeef" }, backend).code,
            1
        )
    end
)

local function with_epic()
    local cards = sample()
    cards[1].kind = "epic"
    return fake(cards)
end

testing.test("link refuses a parent that is not an epic before any request", function()
    local backend = fake(sample())
    local result = cmd_board.run("link", { "cccccccc", "parent", "11111111-a" }, backend)
    testing.eq(result.code, 1)
    testing.eq(
        result.message,
        "Card 11111111 is not an epic. Make it one with `dev board epic 11111111`."
    )
    testing.eq(backend.calls[1], nil)
    result = cmd_board.run("link", { "cccccccc", "related", "11111111-a" }, backend)
    testing.eq(result.output, "linked cccccccc related 11111111")
end)

testing.test("epic turns a card into an epic and prints the refusal as given", function()
    local backend = fake(sample())
    local result = cmd_board.run("epic", { "11111111-b" }, backend)
    testing.eq(result.output, "made 11111111 an epic")
    testing.eq(backend.calls[1], { "make_epic", ID_B, nil })
    backend.refusal = "pomb answered 409: the card holds a live claim"
    result = cmd_board.run("epic", { "11111111-b" }, backend)
    testing.eq(result.code, 1)
    testing.eq(result.message, "pomb answered 409: the card holds a live claim")
    testing.eq(cmd_board.run("epic", {}, backend).code, 2)
    testing.eq(cmd_board.run("epic", { "deadbeef" }, backend).code, 1)
end)

testing.test("add --epic creates an epic through the backend", function()
    local backend = fake(sample())
    local result = cmd_board.run("add", {
        "Big",
        "--epic",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
    }, backend)
    testing.eq(result.code, nil, result.message)
    testing.eq(backend.opts.epic, true)
    cmd_board.run("add", {
        "Small",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
    }, backend)
    testing.eq(backend.opts.epic, nil)
end)

testing.test("link takes parent, and show prints the epic and the children", function()
    local backend = with_epic()
    local result = cmd_board.run("link", { "cccccccc", "parent", "11111111-a" }, backend)
    testing.eq(result.output, "linked cccccccc parent 11111111")
    testing.eq(backend.calls[1], { "link", ID_C, "parent", ID_A })
    backend.kin = { parent = { id = ID_A, name = "Epic" } }
    result = cmd_board.run("show", { "11111111-b" }, backend)
    testing.eq(
        result.output,
        "11111111  Backlog  unsized  -  Fix lint\nparent: 11111111 Epic\n\nno description\n\nno comments"
    )
    backend.kin = { children = { done = 1, total = 3 } }
    result = cmd_board.run("show", { "11111111-b" }, backend)
    testing.eq(
        result.output,
        "11111111  Backlog  unsized  -  Fix lint\nchildren: 1 of 3 done\n\nno description\n\nno comments"
    )
end)

testing.test("link refuses a bad kind, a missing word and an unknown card", function()
    local backend = fake(sample())
    testing.eq(cmd_board.run("link", { "11111111-a", "depends", "cccccccc" }, backend).code, 2)
    testing.eq(cmd_board.run("link", { "11111111-a", "blocks" }, backend).code, 2)
    testing.eq(cmd_board.run("link", { "11111111-a", "blocks", "cccccccc", "x" }, backend).code, 2)
    testing.eq(cmd_board.run("link", { "deadbeef", "blocks", "cccccccc" }, backend).code, 1)
    testing.eq(cmd_board.run("link", { "11111111-a", "blocks", "deadbeef" }, backend).code, 1)
    testing.eq(#backend.calls, 0)
end)

testing.test("note and move resolve the card by prefix", function()
    local cards = sample()
    cards[3].color = "green"
    cards[3].description = V2
    cards[3].outcomes = { { id = "s1", name = "a", done = false } }
    local backend = fake(cards)
    local result = cmd_board.run("note", { "cccccccc", "landed", "as", "abc" }, backend)
    testing.eq(result.output, "noted cccccccc")
    testing.eq(backend.calls[1], { "note", ID_C, "landed as abc", {} })
    result = cmd_board.run("move", { "cccccccc", support.COLUMN.BLOCKED }, backend)
    testing.eq(result.output, "moved cccccccc to Blocked")
    testing.eq(backend.calls[2], { "move", ID_C, support.COLUMN_NAME.BLOCKED })
    result = cmd_board.run("move", { "cccccccc", support.COLUMN.REVIEW }, backend)
    testing.eq(backend.calls[3], { "move", ID_C, support.COLUMN_NAME.REVIEW })
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

testing.test("notes lists each comment with its id prefix, writer, time and first line", function()
    local backend = with_comments()
    local result = cmd_board.run("notes", { "cccccccc" }, backend)
    testing.eq(
        result.output,
        "aaaaaaaa  worker  decision  reviewer  2026-10-27 09:30  first line\n"
            .. "bbbbbbbb  human   -         -         2026-10-27 10:00  ok"
    )
    testing.eq(cmd_board.run("notes", { "cccccccc" }, fake(sample())).output, "no comments")
    testing.eq(cmd_board.run("notes", {}, backend).code, 2)
    testing.eq(cmd_board.run("notes", { "deadbeef" }, backend).code, 1)
end)

testing.test(
    "show indents the rest of a multi-line body under its body, notes keeps one line",
    function()
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
        local result = cmd_board.run("show", { "cccccccc" }, backend)
        testing.eq(
            result.output,
            "cccccccc  Done  unsized  -  Old thing\n\nno description\n\n"
                .. "aaaaaaaa  worker  decision  reviewer  2026-10-27 09:30  1. first\n\n"
                .. (" "):rep(BODY_COLUMN)
                .. "2. second\n"
                .. "bbbbbbbb  human   -         -         2026-10-27 10:00  ok\n"
                .. (" "):rep(BODY_COLUMN)
                .. "more"
        )
        testing.eq(
            cmd_board.run("notes", { "cccccccc" }, backend).output,
            "aaaaaaaa  worker  decision  reviewer  2026-10-27 09:30  1. first\n"
                .. "bbbbbbbb  human   -         -         2026-10-27 10:00  ok"
        )
    end
)

testing.test("note --board files the note on the crossboard card's board", function()
    local backend = fake(sample())
    local sibling = fake(sample())
    backend.sibling = sibling
    local result = cmd_board.run(
        "note",
        { "11111111-a", "--board", "ci", "--kind", "decision", "ok" },
        backend
    )
    testing.eq(result.output, "noted 11111111")
    testing.eq(backend.calls, { { "other_board", "ci" } })
    testing.eq(sibling.calls[1], { "note", ID_A, "ok", { kind = "decision" } })
end)

testing.test("show --board prints the crossboard card from the named board", function()
    local backend = fake(sample())
    local far = sample()
    far[1].name = "Far card"
    local sibling = fake(far)
    backend.sibling = sibling
    local result = cmd_board.run("show", { "11111111-a", "--board", "ci" }, backend)
    testing.eq(result.code, nil)
    testing.ok(result.output:find("Far card", 1, true), result.output)
    testing.eq(backend.calls, { { "other_board", "ci" } })
    testing.eq(sibling.calls[1], { "comments", ID_A })
end)

testing.test("note and show --board refuse a crossboard board that is not there", function()
    local backend = fake(sample())
    local result = cmd_board.run("note", { "11111111-a", "--board", "nope", "ok" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("no board named nope", 1, true), result.message)
    result = cmd_board.run("show", { "11111111-a", "--board", "nope" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("no board named nope", 1, true), result.message)
    result = cmd_board.run("show", { "11111111-a", "--board" }, backend)
    testing.eq(result.code, 2)
    testing.eq(#backend.calls, 2)
end)

testing.test(
    "note --board refuses crossboard --edit and --delete before it looks anything up",
    function()
        local backend = fake(sample())
        for _, args in ipairs({
            { "11111111-a", "--board", "ci", "--edit", "aaaaaaaa", "x" },
            { "11111111-a", "--board", "ci", "--delete", "aaaaaaaa" },
        }) do
            local result = cmd_board.run("note", args, backend)
            testing.eq(result.code, 2)
        end
        testing.eq(#backend.calls, 0)
    end
)

testing.test("note --kind question names dev board ask", function()
    local backend = fake(sample())
    local count = #backend.calls
    for _, args in ipairs({
        { "cccccccc", "--kind", "question", "Which way?" },
        { "cccccccc", "--kind", "Question", "Which way?" },
    }) do
        local result = cmd_board.run("note", args, backend)
        testing.eq(result.code, 2)
        testing.ok(
            result.message:find(
                "dev board ask CARD --question TEXT --choice COLUMN=LABEL --recommend N --why TEXT",
                1,
                true
            ),
            result.message
        )
    end
    testing.eq(#backend.calls, count)
end)

testing.test("note sends a lowercase kind and a trimmed role, and refuses a bad one", function()
    local backend = fake(sample())
    local args = { "cccccccc", "--kind", "Decision", "--as", " reviewer ", "go", "ahead" }
    local result = cmd_board.run("note", args, backend)
    testing.eq(result.output, "noted cccccccc")
    testing.eq(
        backend.calls[1],
        { "note", ID_C, "go ahead", { kind = "decision", author = "reviewer" } }
    )
    result = cmd_board.run("note", { "cccccccc", "--as", "planner", "text" }, backend)
    testing.eq(backend.calls[2], { "note", ID_C, "text", { author = "planner" } })
    local count = #backend.calls
    for _, bad in ipairs({
        { "cccccccc", "--kind", "chatter", "text" },
        { "cccccccc", "--kind" },
        { "cccccccc", "--as", "   ", "text" },
        { "cccccccc", "--as", string.rep("x", 81), "text" },
        { "cccccccc", "--as", "a\nb", "text" },
    }) do
        testing.eq(cmd_board.run("note", bad, backend).code, 2)
    end
    testing.eq(#backend.calls, count)
    result = cmd_board.run("note", { "cccccccc", "see", "the", "--as", "flag" }, backend)
    testing.eq(backend.calls[count + 1], { "note", ID_C, "see the --as flag", {} })
    testing.eq(
        cmd_board.run("note", { "cccccccc", "--kind", "done", "--edit", "bbbbbbbb", "x" }, backend).code,
        2
    )
    testing.eq(
        #cmd_board.run("note", { "cccccccc", "--as", string.rep("x", 80), "t" }, backend).output > 0,
        true
    )
end)

testing.test("show prints the card line, its description and its comments", function()
    local cards = sample()
    cards[1].description = "Why it matters.\nSecond line."
    local backend = with_comments()
    backend.cards = function()
        return cards
    end
    local result = cmd_board.run("show", { "11111111-a" }, backend)
    testing.eq(
        result.output,
        "11111111  Ready  1 Pomodoro  docs  Write docs\n\nWhy it matters.\nSecond line.\n\n"
            .. "aaaaaaaa  worker  decision  reviewer  2026-10-27 09:30  first line\n"
            .. (" "):rep(BODY_COLUMN)
            .. "second\n"
            .. "bbbbbbbb  human   -         -         2026-10-27 10:00  ok"
    )
    testing.eq(backend.calls[#backend.calls], { "family", ID_A })
    result = cmd_board.run("show", { "bbbbbbbb-b" }, fake(sample()))
    testing.eq(result.code, 1)
    result = cmd_board.run("show", { "11111111-b" }, fake(sample()))
    testing.eq(
        result.output,
        "11111111  Backlog  unsized  -  Fix lint\n\nno description\n\nno comments"
    )
    testing.eq(cmd_board.run("show", {}, backend).code, 2)
    testing.eq(cmd_board.run("show", { "deadbeef" }, backend).code, 1)
end)

testing.test("show lists an open ask's choices and marks the recommended one", function()
    local backend = fake(sample())
    backend.listed = {
        {
            id = COMMENT_1,
            who = "worker",
            at = "2026-10-27T09:30:12Z",
            body = "Which way?",
            kind = "question",
            question = {
                text = "Which way?",
                recommended = 2,
                choices = {
                    { label = "left", column = support.COLUMN_NAME.READY },
                    { label = "right", column = support.COLUMN_NAME.BACKLOG },
                },
            },
        },
        {
            id = COMMENT_2,
            who = "worker",
            at = "2026-10-27T10:00:00Z",
            body = "Done?",
            kind = "question",
            question = {
                answer = "1",
                choices = { { label = "yes", column = support.COLUMN_NAME.DONE } },
            },
        },
    }
    local result = cmd_board.run("show", { "11111111-a" }, backend)
    local lines = {}
    for line in result.output:gmatch("[^\n]+") do
        lines[#lines + 1] = line:match("^%s*(.-)$")
    end
    local want = {
        "1. left (" .. support.COLUMN_NAME.READY .. ")",
        "2. right (" .. support.COLUMN_NAME.BACKLOG .. ") [recommended]",
    }
    local at = 0
    for index, line in ipairs(lines) do
        if line == want[1] then
            at = index
        end
    end
    testing.ok(at > 0, result.output)
    testing.eq({ lines[at], lines[at + 1] }, want)
    testing.ok(not result.output:find("1. yes", 1, true), result.output)
end)

testing.test("note --edit and --delete resolve the comment by prefix", function()
    local backend = with_comments()
    local result =
        cmd_board.run("note", { "cccccccc", "--edit", "bbbbbbbb", "fixed", "it" }, backend)
    testing.eq(result.output, "edited cccccccc bbbbbbbb")
    testing.eq(backend.calls[2], { "edit_note", ID_C, COMMENT_2, "fixed it" })
    result = cmd_board.run("note", { "cccccccc", "--delete", "aaaaaaaa-1" }, backend)
    testing.eq(result.output, "deleted cccccccc aaaaaaaa")
    testing.eq(backend.calls[4], { "delete_note", ID_C, COMMENT_1 })
end)

testing.test("note --edit and --delete refuse a bad comment prefix or a bad shape", function()
    local backend = with_comments()
    for _, args in ipairs({
        { "cccccccc", "--edit", "bbbb", "x" },
        { "cccccccc", "--delete", "zzzzzzzz" },
        { "cccccccc", "--delete", "cccccccc" },
    }) do
        local result = cmd_board.run("note", args, backend)
        testing.eq(result.code, 1)
    end
    testing.eq(
        cmd_board.run("note", { "cccccccc", "--delete", "bbbb" }, backend).message,
        "A comment id needs at least 8 hex characters: bbbb."
    )
    testing.eq(
        cmd_board.run("note", { "cccccccc", "--delete", "cccccccc" }, backend).message,
        "No comment starts with cccccccc."
    )
    for _, args in ipairs({
        { "cccccccc", "--edit", "bbbbbbbb" },
        { "cccccccc", "--edit" },
        { "cccccccc", "--delete" },
        { "cccccccc", "--delete", "bbbbbbbb", "extra" },
    }) do
        testing.eq(cmd_board.run("note", args, backend).code, 2)
    end
    for _, call in ipairs(backend.calls) do
        testing.ok(call[1] == "comments", call[1])
    end
end)

testing.test("move and note refuse before the backend is called", function()
    local backend = fake(sample())
    local result = cmd_board.run("move", { "cccccccc", "doing" }, backend)
    testing.eq(result.code, 2)
    result = cmd_board.run("move", { "deadbeef", support.COLUMN.READY }, backend)
    testing.eq(result.code, 1)
    result = cmd_board.run("note", { "cccccccc" }, backend)
    testing.eq(result.code, 2)
    testing.eq(#backend.calls, 0)
end)

testing.test(
    "add to Ready refuses a card with no size or a red one before the backend is called",
    function()
        local backend = fake(sample())
        for _, args in ipairs({
            { "X", "--column", support.COLUMN.READY },
            { "X", "--column", support.COLUMN.READY, "--size", "unsized" },
            { "X", "--column", support.COLUMN.READY, "--size", "3+" },
        }) do
            testing.eq(cmd_board.run("add", args, backend).code, 2)
        end
        testing.eq(#backend.calls, 0)
        testing.eq(
            cmd_board.run("add", {
                "X",
                "--column",
                support.COLUMN.BACKLOG,
                "--problem",
                "x",
                "--change",
                "x",
                "--out-of-scope",
                "y",
                "--size",
                "1",
                "--done-when",
                "a",
            }, backend).code,
            nil
        )
        local full = {
            "X",
            "--column",
            support.COLUMN.READY,
            "--size",
            "3",
            "--description",
            V1,
            "--checks",
            "dev test",
        }
        testing.eq(cmd_board.run("add", full, backend).code, nil)
    end
)

local function colored(color)
    local card = {
        id = ID_C,
        name = "Card",
        column = support.COLUMN_NAME.BACKLOG,
        size = "x",
        labels = {},
        description = V1,
        checks = { "dev test" },
    }
    card.color = color
    return card
end

testing.test(
    "move to Ready refuses a white, uncoloured or red card and names dev board size",
    function()
        for _, color in ipairs({ "white", "red" }) do
            local backend = fake({ colored(color) })
            local result = cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, backend)
            testing.eq(result.code, 1)
            testing.ok(result.message:find("dev board size", 1, true), result.message)
            testing.eq(#backend.calls, 0)
        end
        local backend = fake({ colored(nil) })
        local result = cmd_board.run("move", { "cccccccc", support.COLUMN_NAME.READY }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("has no size", 1, true), result.message)
        testing.eq(#backend.calls, 0)
    end
)

testing.test(
    "add scaffolds the v3 headings, fills Problem and keeps a text that has them",
    function()
        local backend = fake(sample())
        local result = cmd_board.run(
            "add",
            { "X", "--description", "It breaks.", "--size", "1", "--done-when", "a" },
            backend
        )
        testing.eq(result.code, 2)
        testing.ok(result.message:find("text under ## Change", 1, true), result.message)
        testing.eq(#backend.calls, 0)
        cmd_board.run("add", { "X", "--description", V1, "--size", "1" }, backend)
        testing.eq(backend.calls[1][4], V1)
        cmd_board.run(
            "add",
            { "X", "--column", support.COLUMN.ICEBOX, "--description", "loose" },
            backend
        )
        testing.eq(backend.calls[2], { "add", "X", support.COLUMN_NAME.ICEBOX, "loose", nil })
        cmd_board.run("add", { "X", "--column", support.COLUMN.ICEBOX }, backend)
        testing.eq(backend.calls[3], { "add", "X", support.COLUMN_NAME.ICEBOX, nil, nil })
    end
)

testing.test(
    "add composes the three sections from --problem, --change and --out-of-scope",
    function()
        local backend = fake(sample())
        local result = cmd_board.run("add", {
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
        testing.eq(result.output, "added cccccccc Backlog")
        testing.eq(
            backend.calls[1][4],
            "## Problem\nIt breaks.\n\n## Change\n- fix it\n\n## Out of scope\nnothing\n"
        )
        cmd_board.run("add", {
            "X",
            "--problem",
            "  only  ",
            "--change",
            " x ",
            "--out-of-scope",
            " y ",
            "--size",
            "1",
            "--done-when",
            "a",
        }, backend)
        testing.eq(backend.calls[2][4], "## Problem\nonly\n\n## Change\nx\n\n## Out of scope\ny\n")
    end
)

testing.test("add refuses --description together with a section flag", function()
    local backend = fake(sample())
    for _, flag in ipairs({ "--problem", "--change", "--out-of-scope" }) do
        local result = cmd_board.run("add", { "X", "--description", "text", flag, "y" }, backend)
        testing.eq(result.code, 2)
        testing.ok(result.message:find("--description", 1, true), result.message)
    end
    testing.eq(#backend.calls, 0)
end)

testing.test("add keeps each repeated --change as its own line, in order", function()
    local backend = fake(sample())
    local result = cmd_board.run("add", {
        "X",
        "--problem",
        "p",
        "--change",
        "- one",
        "--change",
        "- two",
        "--change",
        "- three",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
    }, backend)
    testing.eq(result.output, "added cccccccc Backlog")
    testing.eq(
        backend.calls[1][4],
        "## Problem\np\n\n## Change\n- one\n- two\n- three\n\n## Out of scope\ny\n"
    )
end)

testing.test("add refuses a repeated --problem or --out-of-scope by name", function()
    local backend = fake(sample())
    for _, flag in ipairs({ "--problem", "--out-of-scope" }) do
        local result = cmd_board.run("add", { "X", flag, "a", flag, "b" }, backend)
        testing.eq(result.code, 2)
        testing.ok(result.message:find(flag, 1, true), result.message)
    end
    testing.eq(#backend.calls, 0)
end)

testing.test(
    "add into Backlog without a Problem is refused before the backend is called",
    function()
        local backend = fake(sample())
        local result = cmd_board.run("add", { "X" }, backend)
        testing.eq(result.code, 2)
        testing.ok(result.message:find("text under ## Problem", 1, true), result.message)
        result = cmd_board.run("add", { "X", "--change", "- do" }, backend)
        testing.eq(result.code, 2)
        testing.ok(result.message:find("text under ## Problem", 1, true), result.message)
        result = cmd_board.run(
            "add",
            { "X", "--column", support.COLUMN.BACKLOG, "--out-of-scope", "n" },
            backend
        )
        testing.eq(result.code, 2)
        testing.eq(#backend.calls, 0)
    end
)

testing.test(
    "add outside Icebox refuses a missing size, section or outcome in every column",
    function()
        local backend = fake(sample())
        for _, column in ipairs({
            support.COLUMN.BACKLOG,
            support.COLUMN.PROGRESS,
            support.COLUMN.REVIEW,
            support.COLUMN.BLOCKED,
            support.COLUMN.DONE,
        }) do
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
                local result = cmd_board.run("add", args, backend)
                testing.eq(result.code, 2, column)
                testing.ok(result.message:find(case[2], 1, true), result.message)
            end
        end
        testing.eq(#backend.calls, 0)
    end
)

testing.test("add into Icebox stays free-form", function()
    local backend = fake(sample())
    testing.eq(cmd_board.run("add", { "X", "--column", support.COLUMN.ICEBOX }, backend).code, nil)
    testing.eq(backend.calls[1], { "add", "X", support.COLUMN_NAME.ICEBOX, nil, nil })
    testing.eq(
        cmd_board.run(
            "add",
            { "X", "--column", support.COLUMN.ICEBOX, "--description", "loose" },
            backend
        ).code,
        nil
    )
    testing.eq(backend.calls[2], { "add", "X", support.COLUMN_NAME.ICEBOX, "loose", nil })
end)

testing.test("missing and backlog_missing count a heading with text, not an empty one", function()
    testing.eq(board.backlog_missing(V2), {})
    testing.eq(board.backlog_missing(SCAFFOLD), {})
    testing.eq(board.backlog_missing("## Problem\n\n## Change\nc\n## Out of scope\no"), {
        "text under ## Problem",
    })
    testing.eq(board.backlog_missing("## Problem\nx"), { "## Change", "## Out of scope" })
    testing.eq(board.backlog_missing(nil), { "## Problem", "## Change", "## Out of scope" })
    testing.eq(board.missing(V1, 0, 0), {})
    testing.eq(board.missing("## Problem\nx\n\n## Change\n\n## Out of scope\nn", 3, 0), {
        "text under ## Change",
    })
    testing.eq(board.missing("## Problem\nx\n\n## Change\ny\n\n## Out of scope\n", 3, 0), {
        "text under ## Out of scope",
    })
    testing.eq(board.missing(V2, 3, 0), {})
end)

testing.test(
    "shapes flags an empty Change or Out of scope and a Change: or Out of scope: line",
    function()
        testing.eq(board.shapes(V2), {})
        testing.eq(board.shapes("## Problem\nx\n\n## Change\n\n## Out of scope\n"), {
            "text under ## Change",
            "text under ## Out of scope",
        })
        testing.eq(board.shapes("## Problem\nx\nChange: y\n\n## Change\nc\n\n## Out of scope\nn"), {
            "a Problem free of Change: and Out of scope: lines",
        })
        testing.eq(board.shapes("## Problem\nChanged: y\n\n## Change\nc\n\n## Out of scope\nn"), {})
    end
)

testing.test(
    "move to Ready refuses an empty Change or Out of scope and accepts all three",
    function()
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
            local result = cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, backend)
            testing.eq(result.code, 1)
            testing.ok(result.message:find(case[2], 1, true), result.message)
            testing.eq(#backend.calls, 0)
        end
        local card = colored("green")
        card.description = V2
        card.outcomes = {
            { id = "s1", name = "a " .. board.JUDGEMENT },
            { id = "s2", name = "b " .. board.JUDGEMENT },
            { id = "s3", name = "c " .. board.JUDGEMENT },
        }
        testing.eq(
            cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, fake({ card })).code,
            nil
        )
    end
)

---Card descriptions with an empty section or a misplaced line, each with the refusal text it draws
local SHAPE_CASES = {
    { "## Problem\nx\n\n## Change\n\n## Out of scope\nn", "text under ## Change" },
    { "## Problem\nx\nChange: y\n\n## Change\nc\n\n## Out of scope\nn", "a Problem free of" },
    { "## Problem\nx\nOut of scope: y\n\n## Change\nc\n\n## Out of scope\nn", "a Problem free of" },
}

testing.test("move into In Progress refuses an empty section or a misplaced line", function()
    for _, case in ipairs(SHAPE_CASES) do
        local card = colored("green")
        card.description = case[1]
        card.outcomes = { { id = "s1", name = "a " .. board.JUDGEMENT } }
        local backend = fake({ card })
        local result = cmd_board.run("move", { "cccccccc", support.COLUMN.PROGRESS }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find(case[2], 1, true), result.message)
        testing.eq(#backend.calls, 0)
    end
end)

testing.test("add to Backlog refuses an empty section or a misplaced line", function()
    for _, case in ipairs({
        { { "--problem", "x", "--change", "c" }, "text under ## Out of scope" },
        { { "--problem", "x", "--out-of-scope", "n" }, "text under ## Change" },
        { { "--description", SHAPE_CASES[2][1] }, "a Problem free of" },
    }) do
        local args = { "X", "--column", support.COLUMN.BACKLOG, "--size", "1", "--done-when", "a" }
        for _, word in ipairs(case[1]) do
            args[#args + 1] = word
        end
        local backend = fake(sample())
        local result = cmd_board.run("add", args, backend)
        testing.eq(result.code, 2)
        testing.ok(result.message:find(case[2], 1, true), result.message)
        testing.eq(#backend.calls, 0)
    end
end)

testing.test("discard drops a card with an empty section or a misplaced line", function()
    for _, case in ipairs(SHAPE_CASES) do
        local card = colored("green")
        card.description = case[1]
        local backend = fake({ card })
        local result = cmd_board.run("discard", { "cccccccc" }, backend)
        testing.eq(result.message, nil)
        testing.eq(result.output, "discarded cccccccc")
        testing.eq(backend.calls[#backend.calls], { "move", ID_C, support.COLUMN_NAME.DONE })
    end
end)

testing.test(
    "move to Backlog refuses a card without a Problem and names what is missing",
    function()
        local card = colored("green")
        card.description = "loose idea"
        local backend = fake({ card })
        local result = cmd_board.run("move", { "cccccccc", support.COLUMN.BACKLOG }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("cannot enter Backlog", 1, true), result.message)
        testing.ok(result.message:find("## Problem", 1, true), result.message)
        testing.eq(#backend.calls, 0)
        card.description = SCAFFOLD:gsub("x\n", "")
        result = cmd_board.run("move", { "cccccccc", support.COLUMN.BACKLOG }, fake({ card }))
        testing.eq(result.code, 1)
        testing.ok(result.message:find("text under ## Problem", 1, true), result.message)
        card.description = COMPOSED
        card.outcomes = { { id = "s1", name = "a", done = false } }
        testing.eq(
            cmd_board.run("move", { "cccccccc", support.COLUMN.BACKLOG }, fake({ card })).code,
            nil
        )
    end
)

testing.test(
    "add to Ready refuses a description without the headings or a Done when item",
    function()
        local backend = fake(sample())
        local result = cmd_board.run(
            "add",
            { "X", "--column", support.COLUMN.READY, "--size", "1", "--description", "why" },
            backend
        )
        testing.eq(result.code, 2)
        testing.ok(result.message:find("3 to 7 Done when outcomes", 1, true), result.message)
        result =
            cmd_board.run("add", { "X", "--column", support.COLUMN.READY, "--size", "1" }, backend)
        testing.eq(result.code, 2)
        testing.eq(#backend.calls, 0)
    end
)

testing.test("epic_add_ready_bare", function()
    local backend = fake(sample())
    local result = cmd_board.run("add", {
        "Big",
        "--epic",
        "--column",
        support.COLUMN.READY,
        "--size",
        "1",
        "--problem",
        "x",
        "--change",
        "y",
        "--out-of-scope",
        "z",
        "--done-when",
        "a bare outcome",
        "--checks",
        "dev test",
    }, backend)
    testing.eq(result.code, nil, result.message)
    testing.eq(backend.opts.epic, true)
    testing.eq(backend.calls[1][3], support.COLUMN_NAME.READY)
end)

testing.test("add --checks gives the card one row per command", function()
    local backend = fake(sample())
    local result = cmd_board.run("add", {
        "X",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
        "--checks",
        "dev lint",
        "--checks",
        "dev test",
    }, backend)
    testing.eq(result.output, "added cccccccc Backlog")
    testing.eq(backend.opts.checks, { "dev lint", "dev test" })
    result = cmd_board.run("add", { "X", "--problem", "x", "--checks", "  " }, backend)
    testing.eq(result.code, 2)
    testing.eq(cmd_board.run("add", { "X", "--checks" }, backend).code, 2)
end)

testing.test(
    "add to Ready without a checks row names the missing row, or the missing field",
    function()
        local backend = fake(sample())
        local args = { "X", "--column", support.COLUMN.READY, "--size", "1", "--description", V1 }
        local result = cmd_board.run("add", args, backend)
        testing.eq(result.code, 2)
        testing.ok(result.message:find("checks row", 1, true), result.message)
        testing.ok(result.message:find("--checks", 1, true), result.message)
        backend.nofield = true
        result = cmd_board.run("add", args, backend)
        testing.eq(result.code, 2)
        testing.ok(result.message:find("no checks field", 1, true), result.message)
        testing.ok(result.message:find("dev board init", 1, true), result.message)
        result = cmd_board.run("add", {
            "X",
            "--problem",
            "x",
            "--change",
            "x",
            "--out-of-scope",
            "y",
            "--size",
            "1",
            "--done-when",
            "a",
            "--checks",
            "dev test",
        }, backend)
        testing.eq(result.code, 2)
        testing.ok(result.message:find("no checks field", 1, true), result.message)
        testing.eq(#backend.calls, 0)
        testing.eq(
            cmd_board.run("add", { "X", "--column", support.COLUMN.ICEBOX }, backend).code,
            nil
        )
    end
)

testing.test("move to Ready counts a card with no checks row as missing them", function()
    local card = colored("green")
    card.checks = {}
    local backend = fake({ card })
    local result = cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("has no checks row", 1, true), result.message)
    backend.nofield = true
    result = cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("no checks field", 1, true), result.message)
    testing.ok(result.message:find("dev board init", 1, true), result.message)
    testing.eq(#backend.calls, 0)
    testing.eq(cmd_board.run("move", { "cccccccc", support.COLUMN.ICEBOX }, backend).code, nil)
end)

testing.test("move to Ready refuses an outcome that names no deciding check", function()
    local card = planned()
    card.checks = { "dev --remote test", "dev (x) y" }
    card.outcomes = {
        { id = "s1", name = "A is refused " .. board.CHECK_OPEN .. "remote test)", done = false },
        { id = "s2", name = "B reads well " .. board.JUDGEMENT, done = false },
        { id = "s3", name = "C works", done = false },
        { id = "s4", name = "D works " .. board.CHECK_OPEN .. "nothing)", done = false },
        { id = "s5", name = "E blank " .. board.CHECK_OPEN .. "  )", done = false },
        { id = "s6", name = "F parens " .. board.CHECK_OPEN .. "dev (x) y)", done = false },
    }
    local result = cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, fake({ card }))
    testing.eq(result.code, 1)
    testing.ok(result.message:find("names no deciding check", 1, true), result.message)
    testing.ok(result.message:find("C works, D works", 1, true), result.message)
    testing.ok(
        result.message:find("E blank " .. board.CHECK_OPEN .. "  )", 1, true),
        result.message
    )
    testing.eq(result.message:find("A is refused", 1, true), nil)
    testing.eq(result.message:find("F parens", 1, true), nil)
    card.outcomes = { card.outcomes[1], card.outcomes[2], card.outcomes[6] }
    result = cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, fake({ card }))
    testing.eq(result.code, nil)
end)

testing.test("move to Ready lets a card with children in without a checks row", function()
    local card = planned()
    card.checks = {}
    card.epic = { done = 0, total = 2 }
    card.outcomes = { { id = "s1", name = "a", done = false } }
    local backend = fake({ card })
    backend.kin = { children = card.epic }
    local result = cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, backend)
    testing.eq(result.output, "moved cccccccc to Ready")
    testing.eq(backend.calls[#backend.calls], { "move", ID_C, support.COLUMN_NAME.READY })
end)

testing.test("show prints the checks rows under the description", function()
    local card = colored("green")
    card.checks = { "dev lint", "dev test" }
    local result = cmd_board.run("show", { "cccccccc" }, fake({ card }))
    testing.ok(
        result.output:find("\n\nchecks:\n- dev lint\n- dev test\n\n", 1, true),
        result.output
    )
    card.checks = {}
    result = cmd_board.run("show", { "cccccccc" }, fake({ card }))
    testing.eq(result.output:find("checks:", 1, true), nil)
end)

testing.test("show prints the allow, tests and files blocks when set", function()
    local card = colored("green")
    card.checks = { "dev lint" }
    card.allow = { "test-edits" }
    card.tests = { "one", "two" }
    card.files = { "src/a.rs" }
    local result = cmd_board.run("show", { "cccccccc" }, fake({ card }))
    testing.ok(
        result.output:find(
            "\n\nchecks:\n- dev lint\n\nallow:\n- test-edits\n\ntests:\n- one\n- two\n\nfiles:\n- src/a.rs\n\n",
            1,
            true
        ),
        result.output
    )
    card.allow, card.tests, card.files = {}, {}, {}
    result = cmd_board.run("show", { "cccccccc" }, fake({ card }))
    testing.eq(result.output:find("allow:", 1, true), nil)
    testing.eq(result.output:find("tests:", 1, true), nil)
    testing.eq(result.output:find("files:", 1, true), nil)
end)

testing.test("move to Ready refuses a card missing a heading or a Done when item", function()
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
        local result = cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find(case[2], 1, true), result.message)
        testing.eq(#backend.calls, 0)
    end
    local card = colored("green")
    card.description = V1:gsub("%[ %]", "[x]")
    testing.eq(
        cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, fake({ card })).code,
        nil
    )
end)

local function outcomes(count, ticked, marker)
    local list = {}
    for i = 1, count do
        list[i] = {
            id = "s" .. i,
            name = "Outcome " .. i .. (marker or ""),
            done = i <= (ticked or 0),
        }
    end
    return list
end

testing.test(
    "move to Ready counts 3 to 7 outcomes, and a v1 checklist when there are none",
    function()
        for _, count in ipairs({ 3, 5, 7 }) do
            local card = colored("green")
            card.description = V2
            card.outcomes = outcomes(count, 0, " " .. board.JUDGEMENT)
            testing.eq(
                cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, fake({ card })).code,
                nil
            )
        end
        for _, count in ipairs({ 0, 2, 8 }) do
            local card = colored("green")
            card.description = V2
            card.outcomes = outcomes(count)
            local backend = fake({ card })
            local result = cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, backend)
            testing.eq(result.code, 1)
            testing.ok(result.message:find("card format v3", 1, true), result.message)
            testing.ok(result.message:find("3 to 7 Done when outcomes", 1, true), result.message)
            testing.eq(#backend.calls, 0)
        end
        local card = colored("green")
        card.outcomes = {}
        testing.eq(
            cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, fake({ card })).code,
            nil
        )
    end
)

testing.test("an epic with 1 to 3 outcomes enters Ready", function()
    for _, count in ipairs({ 1, 2, 3 }) do
        local card = colored("green")
        card.description = V2
        card.epic = { done = 2, total = 2 }
        card.outcomes = outcomes(count)
        local backend = fake({ card })
        testing.eq(
            cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, backend).code,
            nil,
            count
        )
        testing.eq(backend.calls[#backend.calls], { "move", ID_C, support.COLUMN_NAME.READY })
    end
end)

testing.test("an epic with no outcomes or more than 3 is refused with the epic rule", function()
    for _, count in ipairs({ 0, 4, 7 }) do
        local card = colored("green")
        card.description = V2
        card.epic = { done = 2, total = 2 }
        card.outcomes = outcomes(count)
        local backend = fake({ card })
        local result = cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, backend)
        testing.eq(result.code, 1)
        testing.ok(
            result.message:find("1 to 3 Done when outcomes for an epic", 1, true),
            result.message
        )
        if count > 0 then
            testing.ok(result.message:find("not " .. count, 1, true), result.message)
        end
        for _, call in ipairs(backend.calls) do
            testing.ok(call[1] ~= "move", "the refused move was sent")
        end
    end
end)

testing.test("a card without children is still held to 3 to 7 outcomes at Ready", function()
    for _, count in ipairs({ 1, 2, 8 }) do
        local card = colored("green")
        card.description = V2
        card.outcomes = outcomes(count)
        local backend = fake({ card })
        local result = cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("3 to 7 Done when outcomes", 1, true), result.message)
        testing.eq(result.message:find("epic", 1, true), nil, result.message)
        testing.eq(#backend.calls, 0)
    end
end)

testing.test("add --done-when hands the outcomes to the backend and checks them", function()
    local backend = fake(sample())
    local result = cmd_board.run("add", {
        "X",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "A works",
        "--done-when",
        "B works",
    }, backend)
    testing.eq(result.output, "added cccccccc Backlog")
    testing.eq(backend.opts.outcomes, { "A works", "B works" })
    testing.eq(cmd_board.run("add", { "X", "--problem", "x", "--done-when", " " }, backend).code, 2)
    testing.eq(cmd_board.run("add", { "X", "--done-when" }, backend).code, 2)
    local many = { "X", "--problem", "x" }
    for i = 1, 8 do
        many[#many + 1] = "--done-when"
        many[#many + 1] = "o" .. i
    end
    testing.eq(cmd_board.run("add", many, backend).code, 2)
    local ready = {
        "X",
        "--column",
        support.COLUMN.READY,
        "--size",
        "1",
        "--description",
        V2,
        "--checks",
        "dev test",
        "--done-when",
        "a " .. board.JUDGEMENT,
        "--done-when",
        "b " .. board.JUDGEMENT,
    }
    result = cmd_board.run("add", ready, backend)
    testing.eq(result.code, 2)
    testing.ok(result.message:find("3 to 7 Done when outcomes", 1, true), result.message)
    ready[#ready + 1] = "--done-when"
    ready[#ready + 1] = "c"
    result = cmd_board.run("add", ready, backend)
    testing.eq(result.code, 2)
    testing.ok(result.message:find("These outcomes lack one: c", 1, true), result.message)
    ready[#ready] = "c " .. board.CHECK_OPEN .. "dev test)"
    testing.eq(cmd_board.run("add", ready, backend).code, nil)
    result = cmd_board.run("add", {
        "X",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "see src/a.lua",
    }, backend)
    testing.eq(result.warnings, { "Card prose holds a path: src/a.lua." })
end)

testing.test("show lists the outcomes with their ticks, and ls adds a done column", function()
    local card = colored("green")
    card.outcomes = outcomes(3, 1)
    local result = cmd_board.run("show", { "cccccccc" }, fake({ card }))
    testing.ok(
        result.output:find(
            "\n\ndone when:\n- [x] Outcome 1\n- [ ] Outcome 2\n- [ ] Outcome 3\n\n",
            1,
            true
        ),
        result.output
    )
    result = cmd_board.run("ls", {}, fake({ card }))
    testing.eq(result.output, "cccccccc  Backlog  x  -  1/3  Card")
    local plain = colored("green")
    testing.eq(cmd_board.run("ls", {}, fake({ plain })).output, "cccccccc  Backlog  x  -  Card")
end)

testing.test("show prints the done when block once and only when a card has outcomes", function()
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
    local result = cmd_board.run("show", { "cccccccc" }, fake({ card }))
    testing.eq(count(result.output, "Outcome 1"), 1, result.output)
    testing.eq(count(result.output, "[Dd]one when"), 1, result.output)
    testing.ok(
        result.output:find("## Problem\nwhy\n\ndone when:\n- [x] Outcome 1", 1, true),
        result.output
    )
    card.description = "## Done when\n- [ ] Outcome 1\n- [ ] Outcome 2\n- [ ] Outcome 3"
    result = cmd_board.run("show", { "cccccccc" }, fake({ card }))
    testing.eq(count(result.output, "Outcome 1"), 1, result.output)
    testing.ok(result.output:find("\n\nno description\n\ndone when:\n", 1, true), result.output)
    card.description = checklist
    card.outcomes = {}
    result = cmd_board.run("show", { "cccccccc" }, fake({ card }))
    testing.eq(count(result.output, "done when:"), 0, result.output)
    testing.eq(count(result.output, "## Done when"), 1, result.output)
    testing.eq(count(result.output, "Outcome 1"), 1, result.output)
end)

testing.test("outcome appends, rewords, ticks and unticks by number", function()
    local card = colored("green")
    card.outcomes = outcomes(3, 1)
    local backend = fake({ card })
    local result = cmd_board.run("outcome", { "cccccccc", "Fourth", "works" }, backend)
    testing.eq(result.output, "outcome cccccccc 4 added")
    testing.eq(backend.calls[1], { "add_outcome", ID_C, "Fourth works", nil })
    result = cmd_board.run(
        "outcome",
        { "cccccccc", "--rename", "2", "New", "words", "--reason", "it was vague" },
        backend
    )
    testing.eq(result.output, "outcome cccccccc 2 reworded")
    testing.eq(backend.calls[2], { "set_outcome", ID_C, "s2", { name = "New words" }, nil })
    result = cmd_board.run("outcome", { "cccccccc", "--tick", "2" }, backend)
    testing.eq(result.output, "outcome cccccccc 2 ticked")
    testing.eq(backend.calls[4], { "set_outcome", ID_C, "s2", { done = true }, nil })
    result = cmd_board.run("outcome", { "cccccccc", "--untick", "1" }, backend)
    testing.eq(result.output, "outcome cccccccc 1 unticked")
    testing.eq(backend.calls[5], { "set_outcome", ID_C, "s1", { done = false }, nil })
end)

testing.test(
    "outcome refuses text that holds a flag or is only a number, and accepts a sentence",
    function()
        local card = colored("green")
        card.outcomes = outcomes(3)
        local backend = fake({ card })
        local result = cmd_board.run("outcome", { "cccccccc", "1", "--tick" }, backend)
        testing.eq(result.code, 2)
        testing.ok(result.message:find("dev board outcome CARD --tick 1", 1, true), result.message)
        testing.eq(cmd_board.run("outcome", { "cccccccc", "2", "--untick" }, backend).code, 2)
        testing.eq(cmd_board.run("outcome", { "cccccccc", "Fix", "--convert" }, backend).code, 2)
        result = cmd_board.run("outcome", { "cccccccc", "2" }, backend)
        testing.eq(result.code, 2)
        testing.ok(result.message:find("--tick 2", 1, true), result.message)
        testing.eq(#backend.calls, 0)
        result =
            cmd_board.run("outcome", { "cccccccc", "Use --tick 2 to mark an outcome." }, backend)
        testing.eq(result.output, "outcome cccccccc 4 added")
        testing.eq(
            backend.calls[1],
            { "add_outcome", ID_C, "Use --tick 2 to mark an outcome.", nil }
        )
    end
)

testing.test("outcome refuses an N past the last outcome and a bad N", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    local result = cmd_board.run("outcome", { "cccccccc", "--tick", "3" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("The card has 2 outcomes. There is no outcome 3.", 1, true))
    testing.eq(
        cmd_board.run("outcome", { "cccccccc", "--rename", "9", "x", "--reason", "y" }, backend).code,
        1
    )
    for _, word in ipairs({ "0", "-1", "x", "1.5" }) do
        testing.eq(cmd_board.run("outcome", { "cccccccc", "--tick", word }, backend).code, 2)
    end
    testing.eq(#backend.calls, 0)
end)

testing.test("outcome --rename without --reason is refused and changes nothing", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    local result = cmd_board.run("outcome", { "cccccccc", "--rename", "1", "New" }, backend)
    testing.eq(result.code, 2)
    testing.ok(result.message:find("--rename needs --reason TEXT", 1, true), result.message)
    testing.eq(
        cmd_board.run("outcome", { "cccccccc", "--rename", "1", "New", "--reason" }, backend).code,
        2
    )
    testing.eq(
        cmd_board.run("outcome", { "cccccccc", "--rename", "1", "--reason", "why" }, backend).code,
        2
    )
    testing.eq(#backend.calls, 0)
end)

testing.test("outcome --rename ends the new text at the first --reason", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    local result = cmd_board.run(
        "outcome",
        { "cccccccc", "--rename", "1", "New", "--reason", "use", "--reason", "flag" },
        backend
    )
    testing.eq(result.output, "outcome cccccccc 1 reworded")
    testing.eq(backend.calls[1], { "set_outcome", ID_C, "s1", { name = "New" }, nil })
    testing.ok(backend.calls[2][3]:find("Reason: use --reason flag", 1, true), backend.calls[2][3])
end)

testing.test("outcome --rename names the old text and the reason when the note fails", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local old = card.outcomes[2].name
    local backend = fake({ card })
    function backend:note()
        return nil, "board unavailable: cannot reach pomb"
    end
    local result =
        cmd_board.run("outcome", { "cccccccc", "--rename", "2", "New", "--reason", "why" }, backend)
    testing.eq(result.code, 1)
    testing.eq(result.unqueued, true)
    testing.ok(result.message:find("was renamed, but the note failed", 1, true), result.message)
    testing.ok(
        result.message:find(old, 1, true) and result.message:find("why", 1, true),
        result.message
    )
    result =
        cmd_board.run("outcome", { "cccccccc", "--rename", "1", "New", "--reason", " " }, backend)
    testing.eq(result.code, 2)
end)

testing.test(
    "outcome --rename posts one decision note with the old text, the new text and the reason",
    function()
        local card = colored("green")
        card.outcomes = outcomes(2)
        local old = card.outcomes[2].name
        local backend = fake({ card })
        local result = cmd_board.run(
            "outcome",
            { "cccccccc", "--rename", "2", "New", "words", "--reason", "it", "was", "vague" },
            backend
        )
        testing.eq(result.output, "outcome cccccccc 2 reworded")
        testing.eq(#backend.calls, 2)
        testing.eq(backend.calls[2], {
            "note",
            ID_C,
            "Renamed outcome 2 from: " .. old .. " to: New words Reason: it was vague",
            { kind = "decision" },
        })
    end
)

testing.test("outcome refuses missing arguments, blank text and a missing card", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    testing.eq(cmd_board.run("outcome", { "cccccccc" }, backend).code, 2)
    testing.eq(cmd_board.run("outcome", { "cccccccc", "--tick" }, backend).code, 2)
    testing.eq(cmd_board.run("outcome", { "cccccccc", "--tick", "1", "2" }, backend).code, 2)
    testing.eq(cmd_board.run("outcome", { "cccccccc", "--rename", "1" }, backend).code, 2)
    testing.eq(cmd_board.run("outcome", { "cccccccc", "   " }, backend).code, 2)
    testing.eq(cmd_board.run("outcome", { "deadbeef", "x" }, backend).code, 1)
    testing.eq(#backend.calls, 0)
end)

testing.test(
    "a claimant cannot tick its card's outcome, another name can, and untick stays open",
    function()
        local card = colored("green")
        card.outcomes = outcomes(2)
        card.claimant = "project-run/a"
        local backend = fake({ card })
        local result = cmd_board.run(
            "outcome",
            { "cccccccc", "--tick", "1", "--as", "project-run/a" },
            backend
        )
        testing.eq(result.code, 1)
        testing.ok(result.message:find("claimed by project-run/a", 1, true), result.message)
        testing.eq(#backend.calls, 0)
        result = cmd_board.run(
            "outcome",
            { "cccccccc", "--tick", "1", "--as", "project-run/b" },
            backend
        )
        testing.eq(result.output, "outcome cccccccc 1 ticked by project-run/b")
        testing.eq(backend.calls[1], { "set_outcome", ID_C, "s1", { done = true }, nil })
        result = cmd_board.run("outcome", { "cccccccc", "--untick", "1" }, backend)
        testing.eq(result.output, "outcome cccccccc 1 unticked")
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

testing.test("outcome delete refuses a name that is not a lead", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    for _, name in ipairs({ "dotfiles/implementer/95f0e009/1", "project-run/a" }) do
        as_agent(name, function()
            local result =
                cmd_board.run("outcome", { "cccccccc", "--delete", "1", "--reason", "x" }, backend)
            testing.eq(result.code, 1)
            testing.ok(
                result.message:find("Only the lead deletes an outcome", 1, true),
                result.message
            )
            testing.ok(result.message:find(name, 1, true), result.message)
        end)
    end
    testing.eq(#backend.calls, 0)
end)

testing.test("outcome delete by a lead notes the reason and the text", function()
    for _, column in ipairs({
        support.COLUMN_NAME.BACKLOG,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.ICEBOX,
    }) do
        local card = colored("green")
        card.column = column
        card.outcomes = outcomes(3)
        local backend = fake({ card })
        as_agent(LEAD, function()
            local result = cmd_board.run(
                "outcome",
                { "cccccccc", "--delete", "2", "--reason", "never", "achievable" },
                backend
            )
            testing.eq(result.output, "outcome cccccccc 2 deleted")
        end)
        local calls = writes(backend)
        testing.eq(calls[1], { "delete_outcome", ID_C, "s2", nil })
        testing.eq(
            calls[2][3],
            "Deleted outcome 2: " .. card.outcomes[2].name .. " Reason: never achievable"
        )
        testing.eq(calls[2][4], { kind = "decision" })
    end
end)

local function delete_in(backend, id)
    local result
    as_agent(LEAD, function()
        result = cmd_board.run(
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

testing.test("outcome delete refuses a card in a ready-role column", function()
    for _, column in ipairs({
        support.COLUMN_NAME.READY,
        support.COLUMN_NAME.PROGRESS,
        support.COLUMN_NAME.REVIEW,
        support.COLUMN_NAME.VERIFY,
        support.COLUMN_NAME.RELEASE,
    }) do
        local backend = fake({ card_in(column) })
        local result = delete_in(backend, "cccccccc")
        testing.eq(result.code, 1)
        testing.ok(result.message:find(column, 1, true), result.message)
        testing.ok(result.message:find("fixed from Ready on", 1, true), result.message)
        testing.eq(result.unqueued, true)
        testing.eq(#writes(backend), 0)
    end
end)

testing.test("outcome delete refuses a card in a finished column", function()
    for _, column in ipairs({ support.COLUMN_NAME.DONE, "Archive" }) do
        local backend = fake({ card_in(column) }, nil, { support.COLUMN_NAME.DONE, "Archive" })
        local result = delete_in(backend, "cccccccc")
        testing.eq(result.code, 1)
        testing.ok(result.message:find(column, 1, true), result.message)
        testing.eq(#writes(backend), 0)
    end
end)

testing.test("outcome delete reads the renamed role columns", function()
    local map = { ready = "Next", progress = "Doing", review = "Looking", done = "Shipped" }
    for _, column in ipairs({ "Next", "Doing", "Looking", "Shipped" }) do
        local backend = fake({ card_in(column) }, nil, { "Shipped" })
        backend.column_map = map
        local result = delete_in(backend, "cccccccc")
        testing.eq(result.code, 1, column)
        testing.ok(result.message:find(column, 1, true), result.message)
        testing.eq(#writes(backend), 0)
    end
    for _, column in ipairs({ support.COLUMN_NAME.READY, support.COLUMN_NAME.PROGRESS }) do
        local backend = fake({ card_in(column) }, nil, { "Shipped" })
        backend.column_map = map
        testing.eq(delete_in(backend, "cccccccc").code, 1, column)
        testing.eq(#writes(backend), 0)
    end
end)

testing.test("outcome delete refuses an unmapped column", function()
    local backend = fake({ card_in("QA") })
    local result = delete_in(backend, "cccccccc")
    testing.eq(result.code, 1)
    testing.ok(result.message:find("QA", 1, true), result.message)
    testing.ok(result.message:find("fixed from Ready on", 1, true), result.message)
    testing.eq(result.unqueued, true)
    testing.eq(#writes(backend), 0)
end)

testing.test("outcome delete allows renamed blocked and backlog columns", function()
    local map = { blocked = "Parked", backlog = "Someday" }
    for _, column in ipairs({ "Parked", "parked", "SOMEDAY" }) do
        local backend = fake({ card_in(column) })
        backend.column_map = map
        testing.eq(delete_in(backend, "cccccccc").output, "outcome cccccccc 1 deleted")
    end
    for _, column in ipairs({ support.COLUMN_NAME.BLOCKED, support.COLUMN_NAME.BACKLOG }) do
        local backend = fake({ card_in(column) })
        backend.column_map = map
        testing.eq(delete_in(backend, "cccccccc").code, 1, column)
        testing.eq(#writes(backend), 0)
    end
end)

testing.test("outcome delete is allowed in Blocked and Backlog", function()
    for _, column in ipairs({
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BACKLOG,
        support.COLUMN_NAME.ICEBOX,
    }) do
        local backend = fake({ card_in(column) })
        testing.eq(delete_in(backend, "cccccccc").output, "outcome cccccccc 1 deleted")
        local calls = writes(backend)
        testing.eq(calls[1], { "delete_outcome", ID_C, "s1", nil })
        testing.eq(calls[2][4], { kind = "decision" })
    end
end)

testing.test("outcome delete by a lead needs a reason", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    as_agent(LEAD, function()
        testing.eq(cmd_board.run("outcome", { "cccccccc", "--delete", "1" }, backend).code, 2)
        testing.eq(
            cmd_board.run("outcome", { "cccccccc", "--delete", "1", "--reason" }, backend).code,
            2
        )
        testing.eq(
            cmd_board.run("outcome", { "cccccccc", "--delete", "1", "--reason", "  " }, backend).code,
            2
        )
    end)
    as_agent("dotfiles/implementer/95f0e009/1", function()
        testing.eq(cmd_board.run("outcome", { "cccccccc", "--delete", "1" }, backend).code, 2)
    end)
    testing.eq(#backend.calls, 0)
end)

testing.test(
    "outcome --delete by a lead needs a number, and a bad number deletes nothing",
    function()
        local card = colored("green")
        card.outcomes = outcomes(2)
        local backend = fake({ card })
        as_agent(LEAD, function()
            testing.eq(cmd_board.run("outcome", { "cccccccc", "--delete" }, backend).code, 2)
            testing.eq(
                cmd_board.run("outcome", { "cccccccc", "--delete", "1", "why" }, backend).code,
                2
            )
            testing.eq(
                cmd_board.run("outcome", { "cccccccc", "--delete", "3", "--reason", "x" }, backend).code,
                1
            )
        end)
        testing.eq(#writes(backend), 0)
    end
)

testing.test("the claimant cannot delete an outcome under any name it is given", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    card.claimant = "project-run/a"
    local backend = fake({ card })
    as_agent(LEAD, function()
        local result = cmd_board.run(
            "outcome",
            { "cccccccc", "--delete", "1", "--reason", "x", "--as", "project-run/a" },
            backend
        )
        testing.eq(result.code, 1)
        testing.ok(result.message:find("claimed by project-run/a", 1, true), result.message)
        testing.ok(result.message:find("Pass the change back", 1, true), result.message)
        for _, call in ipairs(backend.calls) do
            testing.eq(call[1], "comments")
        end
        result = cmd_board.run(
            "outcome",
            { "cccccccc", "--delete", "1", "--reason", "x", "--as", "project-run/b" },
            backend
        )
        testing.eq(result.output, "outcome cccccccc 1 deleted")
    end)
end)

local function released_by(name, claimant)
    local card = colored("green")
    card.claimant = claimant
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    backend.listed = {
        { id = COMMENT_1, who = "human", body = board.claim_record(name) },
        { id = COMMENT_2, who = "human", body = "Built the change." },
    }
    return backend
end

testing.test("a claim released with no work does not make a past claimant", function()
    local backend = released_by("project-run/main")
    backend.listed[2] = nil
    as_agent("project-run/main", function()
        local result = cmd_board.run(
            "outcome",
            { "cccccccc", "--rename", "1", "New", "--reason", "x" },
            backend
        )
        testing.eq(result.code, nil)
        testing.eq(cmd_board.run("checks", { "cccccccc", "dev test" }, backend).code, nil)
    end)
end)

testing.test("a later claimant's note does not make an idle claim a past claimant", function()
    local backend = released_by("project-run/main")
    local other = board.claim_record("project-run/a")
    backend.listed[2] = { id = COMMENT_2, who = "human", body = other }
    backend.listed[3] = { id = COMMENT_1, who = "human", body = "Built the change." }
    as_agent("project-run/main", function()
        testing.eq(cmd_board.run("checks", { "cccccccc", "dev test" }, backend).code, nil)
    end)
end)

testing.test("a name that released the card cannot reclaim the finish line", function()
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
            local result = cmd_board.run(run[1], run[2], backend)
            testing.eq(result.code, 1, run[2][2])
            testing.ok(result.message:find("was claimed by " .. released, 1, true), result.message)
        end
    end)
    for _, call in ipairs(backend.calls) do
        testing.eq(call[1], "comments")
    end
end)

testing.test("an --as name of a former claimant cannot reclaim the finish line", function()
    local released = "project-run/a"
    local backend = released_by(released)
    as_agent("project-run/b", function()
        local result =
            cmd_board.run("outcome", { "cccccccc", "--convert", "--as", released }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("was claimed by " .. released, 1, true), result.message)
    end)
    for _, call in ipairs(backend.calls) do
        testing.eq(call[1], "comments")
    end
end)

testing.test("a failed comments read refuses the reclaim check with its message", function()
    local backend = released_by("project-run/a")
    backend.listed_error = "comments are unavailable"
    as_agent("project-run/b", function()
        local result = cmd_board.run("checks", { "cccccccc", "dev test" }, backend)
        testing.eq(result.code, 1)
        testing.eq(result.message, "comments are unavailable")
    end)
    for _, call in ipairs(backend.calls) do
        testing.eq(call[1], "comments")
    end
end)

testing.test("a name that never claimed the card and the lead can still change it", function()
    local backend = released_by("project-run/a")
    as_agent("project-run/b", function()
        testing.eq(cmd_board.run("checks", { "cccccccc", "dev test" }, backend).code, nil)
    end)
    as_agent("lead", function()
        local result = cmd_board.run(
            "outcome",
            { "cccccccc", "--rename", "1", "New", "--reason", "x" },
            backend
        )
        testing.eq(result.code, nil)
    end)
    backend = released_by("lead", "lead")
    as_agent("lead", function()
        local result = cmd_board.run(
            "outcome",
            { "cccccccc", "--rename", "1", "New", "--reason", "x" },
            backend
        )
        testing.eq(result.code, nil)
    end)
end)

testing.test(
    "review refuses the claimant for every kind and says a reviewer must record it",
    function()
        local card = colored("green")
        card.claimant = "project-run/a"
        local backend = fake({ card })
        for _, kind in ipairs({ "code", "style", "recheck" }) do
            local result = cmd_board.run("review", {
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
            testing.eq(result.code, 1)
            testing.ok(
                result.message:find(
                    "is claimed by project-run/a. project-run/a cannot review its own change",
                    1,
                    true
                ),
                result.message
            )
            testing.ok(
                result.message:find(" A reviewer other than project-run/a must record it", 1, true),
                result.message
            )
        end
        for _, call in ipairs(backend.calls) do
            testing.eq(call[1], "comments")
        end
    end
)

testing.test("--as is read only on a tick or convert, and names one word", function()
    local card = colored("green")
    card.outcomes = outcomes(2)
    local backend = fake({ card })
    testing.eq(
        cmd_board.run("outcome", { "cccccccc", "--untick", "1", "--as", "x" }, backend).code,
        2
    )
    testing.eq(
        cmd_board.run("outcome", { "cccccccc", "--tick", "1", "--as", "two words" }, backend).code,
        2
    )
    testing.eq(#backend.calls, 0)
    local result = cmd_board.run("outcome", { "cccccccc", "Text", "--as", "x" }, backend)
    testing.eq(result.output, "outcome cccccccc 3 added")
    testing.eq(backend.calls[1], { "add_outcome", ID_C, "Text --as x", nil })
end)

testing.test("convert refuses a claimant's ticks but moves an unticked checklist", function()
    local card = colored("green")
    card.description = V1:gsub("%[ %]", "[x]")
    card.claimant = "project-run/a"
    local backend = fake({ card })
    local result =
        cmd_board.run("outcome", { "cccccccc", "--convert", "--as", "project-run/a" }, backend)
    testing.eq(result.code, 1)
    for _, call in ipairs(backend.calls) do
        testing.eq(call[1], "comments")
    end
    card.description = V1
    result = cmd_board.run("outcome", { "cccccccc", "--convert" }, backend)
    testing.ok(not (result.message or ""):find("claimed", 1, true), result.message)
    testing.eq(backend.calls[#backend.calls][1], "add_outcome")
end)

testing.test("outcome warns about a path in the text and still writes", function()
    local card = colored("green")
    local backend = fake({ card })
    local result = cmd_board.run("outcome", { "cccccccc", "see src/a.lua" }, backend)
    testing.eq(result.warnings, { "Card prose holds a path: src/a.lua." })
    testing.eq(#backend.calls, 1)
end)

testing.test("move into Icebox never checks the description", function()
    local card = colored("white")
    card.description = nil
    local backend = fake({ card })
    testing.eq(cmd_board.run("move", { "cccccccc", support.COLUMN.ICEBOX }, backend).code, nil)
end)

testing.test("move to Ready takes a sized card, and other columns take a planned one", function()
    for _, color in ipairs({ "yellow", "green", "blue" }) do
        local backend = fake({ colored(color) })
        testing.eq(
            cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, backend).output,
            "moved cccccccc to Ready"
        )
    end
    for _, column in ipairs({
        support.COLUMN.BACKLOG,
        support.COLUMN.REVIEW,
        support.COLUMN.BLOCKED,
        support.COLUMN.DONE,
    }) do
        local backend = fake({ colored("green") })
        testing.eq(cmd_board.run("move", { "cccccccc", column }, backend).code, nil)
        testing.eq(#backend.calls, 1)
    end
    local backend = fake({ colored("white") })
    testing.eq(cmd_board.run("move", { "cccccccc", support.COLUMN.ICEBOX }, backend).code, nil)
    testing.eq(#backend.calls, 1)
end)

testing.test(
    "move and edit refuse a needs:human card, and label --remove still frees it",
    function()
        local cards = sample()
        cards[1].labels = { "needs:human" }
        local backend = fake(cards)
        local result = cmd_board.run("move", { "11111111-a", support.COLUMN.BACKLOG }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("needs:human", 1, true), result.message)
        result = cmd_board.run("edit", { "11111111-a", "text" }, backend)
        testing.eq(result.code, 1)
        result = cmd_board.run("rename", { "11111111-a", "text" }, backend)
        testing.eq(result.code, 1)
        testing.eq(#backend.calls, 0)
        testing.eq(
            cmd_board.run("note", { "11111111-a", "hello" }, backend).output,
            "noted 11111111"
        )
        result = cmd_board.run("label", { "11111111-a", "--remove", "needs:human" }, backend)
        testing.eq(result.output, "labelled 11111111 -")
    end
)

testing.test("label refuses to add standalone-ok for an agent and still removes it", function()
    local held = sample()
    held[1].labels = { "standalone-ok" }
    as_agent("dotfiles/implementer/x", function()
        local result =
            cmd_board.run("label", { "11111111-a", "--remove", "standalone-ok" }, fake(held))
        testing.eq(result.output, "labelled 11111111 -")
        result = cmd_board.run("label", { "11111111-a", "+standalone-ok" }, fake(sample()))
        testing.eq(result.code, 1)
        testing.ok(result.message:find("only by the owner", 1, true), result.message)
    end)
    as_agent("", function()
        local result = cmd_board.run("label", { "11111111-a", "+standalone-ok" }, fake(sample()))
        testing.eq(result.output, "labelled 11111111 docs,standalone-ok")
    end)
end)

testing.test("add refuses the standalone-ok label for an agent", function()
    as_agent("dotfiles/implementer/x", function()
        local backend = fake(sample())
        local result = cmd_board.run("add", {
            "C",
            "--problem",
            "x",
            "--change",
            "x",
            "--out-of-scope",
            "y",
            "--size",
            "1",
            "--done-when",
            "a",
            "--label",
            "standalone-ok",
        }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("only by the owner", 1, true), result.message)
        testing.eq(#backend.calls, 0)
    end)
end)

local function blocked_cards()
    local cards = sample()
    cards[1].labels = { "needs:human", "docs" }
    cards[1].column = support.COLUMN_NAME.BLOCKED
    return cards
end

testing.test(
    "answer sends the choice and the quote to the backend and touches nothing else",
    function()
        local backend = fake(blocked_cards())
        local result = cmd_board.run(
            "answer",
            { "11111111-a", "--choice", "2", "--quote", "go", "with", "two" },
            backend
        )
        testing.eq(result.output, "answered 11111111 with choice 2")
        testing.eq(backend.calls, { { "answer", ID_A, 2, "go with two", nil } })
    end
)

testing.test("answer prints the backend's refusal and exits 1", function()
    local backend = fake(blocked_cards())
    backend.refusal = "pomb answered 409: the question is answered already"
    local result =
        cmd_board.run("answer", { "11111111-a", "--choice", "1", "--quote", "yes" }, backend)
    testing.eq(result.code, 1)
    testing.eq(result.message, backend.refusal)
end)

testing.test(
    "ask sends the parts it was given and lets the backend refuse a missing one",
    function()
        local backend = fake(sample())
        local result = cmd_board.run("ask", {
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
        testing.eq(result.output, "asked 11111111")
        testing.eq(backend.calls[1], {
            "ask",
            ID_A,
            {
                text = "Which?",
                choices = {
                    { column = support.COLUMN_NAME.READY, label = "Ship it" },
                    { column = support.COLUMN_NAME.ICEBOX, label = "Park it" },
                },
                recommended = 1,
            },
            nil,
        })
    end
)

testing.test(
    "ask refuses a bad choice, a bad recommendation, an unknown flag and no card",
    function()
        local backend = fake(sample())
        for _, args in ipairs({
            { "11111111-a", "--choice", "no equals sign" },
            { "11111111-a", "--choice", "=label" },
            { "11111111-a", "--recommend", "x" },
            { "11111111-a", "--bogus", "x" },
            { "11111111-a", "--why" },
        }) do
            testing.eq(cmd_board.run("ask", args, backend).code, 2, table.concat(args, " "))
        end
        testing.eq(cmd_board.run("ask", {}, backend).code, 2)
        testing.eq(#backend.calls, 0)
    end
)

testing.test("ask refuses a card that already carries needs:human and posts nothing", function()
    local backend = fake(blocked_cards())
    local result = cmd_board.run("ask", {
        "11111111-a",
        "--question",
        "Which?",
        "--choice",
        "Ready=Ship it",
        "--recommend",
        "1",
        "--why",
        "w",
    }, backend)
    testing.eq(result.code, 1)
    testing.ok(
        result.message:find("dev board label 11111111 --remove needs:human", 1, true),
        result.message
    )
    testing.eq(#backend.calls, 0)
end)

testing.test("answer refuses a card without needs:human and writes nothing", function()
    local cards = sample()
    local backend = fake(cards)
    local result =
        cmd_board.run("answer", { "11111111-a", "--choice", "1", "--quote", "yes" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("is not needs:human", 1, true), result.message)
    testing.eq(#backend.calls, 0)
end)

testing.test("answer refuses an empty quote, a bad choice and missing flags", function()
    local backend = fake(blocked_cards())
    for _, args in ipairs({
        { "11111111-a", "--choice", "1", "--quote" },
        { "11111111-a", "--choice", "1", "--quote", "  " },
        { "11111111-a", "--choice", "0", "--quote", "yes" },
        { "11111111-a", "--choice", "x", "--quote", "yes" },
        { "11111111-a", "--quote", "yes" },
        { "11111111-a" },
    }) do
        testing.eq(cmd_board.run("answer", args, backend).code, 2, table.concat(args, " "))
    end
    testing.eq(#backend.calls, 0)
end)

testing.test("a needs:human card moves within its own column and not out of it", function()
    local cards = sample()
    cards[1].labels = { "needs:human" }
    cards[1].column = support.COLUMN_NAME.ICEBOX
    local backend = fake(cards)
    local result = cmd_board.run("move", { "11111111-a", support.COLUMN.ICEBOX }, backend)
    testing.eq(result.output, "moved 11111111 to Icebox")
    testing.eq(backend.calls, { { "move", ID_A, support.COLUMN_NAME.ICEBOX } })
    result = cmd_board.run("move", { "11111111-a", support.COLUMN.BACKLOG }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("needs:human", 1, true), result.message)
    testing.eq(#backend.calls, 1)
end)

local function column_of_three()
    local cards = sample()
    cards[2].column = support.COLUMN_NAME.READY
    cards[3].column = support.COLUMN_NAME.READY
    cards[3].labels = { "needs:human" }
    return cards
end

testing.test("order moves the named cards to positions 0, 1, 2 and prints the column", function()
    local backend = fake(column_of_three())
    local result = cmd_board.run("order", { "cccccccc", "11111111-a" }, backend)
    testing.eq(result.code, nil)
    testing.eq(backend.calls, {
        { "move", ID_C, support.COLUMN_NAME.READY, 0 },
        { "move", ID_A, support.COLUMN_NAME.READY, 1 },
    })
    testing.eq(
        result.output,
        table.concat({
            "cccccccc  Ready  unsized  needs:human  Old thing",
            "11111111  Ready  1 Pomodoro  docs  Write docs",
            "11111111  Ready  unsized  -  Fix lint",
        }, "\n")
    )
end)

testing.test(
    "order refuses cards of two columns, an unknown card and a card named twice",
    function()
        local cards = sample()
        local backend = fake(cards)
        local result = cmd_board.run("order", { "11111111-a", "11111111-b", "cccccccc" }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("one column", 1, true), result.message)
        result = cmd_board.run("order", { "11111111-a", "deadbeef" }, backend)
        testing.eq(result.code, 1)
        cards = column_of_three()
        backend = fake(cards)
        result = cmd_board.run("order", { "11111111-a", "11111111-a" }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("twice", 1, true), result.message)
        testing.eq(cmd_board.run("order", {}, backend).code, 2)
        testing.eq(cmd_board.run("order", { "--bogus" }, backend).code, 2)
        testing.eq(#backend.calls, 0)
    end
)

testing.test("label adds needs:human only to a card in Blocked or Icebox", function()
    local backend = fake(sample())
    local result = cmd_board.run("label", { "11111111-a", "+needs:human" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("Blocked or Icebox", 1, true), result.message)
    testing.eq(#backend.calls, 0)
    local added = cmd_board.run("add", { "Idea", "--label", "needs:human" }, backend)
    testing.eq(added.code, 2)
    testing.eq(#backend.calls, 0)
    for _, column in ipairs({ support.COLUMN_NAME.BLOCKED, support.COLUMN_NAME.ICEBOX }) do
        local cards = sample()
        cards[1].column = column
        backend = fake(cards)
        result = cmd_board.run("label", { "11111111-a", "needs:human" }, backend)
        testing.eq(result.output, "labelled 11111111 docs,needs:human")
    end
end)

testing.test("move to Ready allows an epic and a card without children", function()
    local backend = fake({ colored("green") })
    backend.kin = { children = { done = 0, total = 2 } }
    local result = cmd_board.run("move", { "cccccccc", support.COLUMN.READY }, backend)
    testing.eq(result.output, "moved cccccccc to Ready")
    result = cmd_board.run("move", { "cccccccc", support.COLUMN.BACKLOG }, backend)
    testing.eq(result.output, "moved cccccccc to Backlog")
end)

testing.test("next shows the top card or says none", function()
    local result = cmd_board.run("next", {}, fake(sample()))
    testing.eq(
        result.output,
        "11111111  Ready  1 Pomodoro  docs  Write docs  0 comments, 0 the owner's"
    )
    result = cmd_board.run("next", {}, fake({}))
    testing.eq(result.output, "No ready cards.")
end)

local function hosted(backend)
    function backend:card_url(id)
        return "https://pomb.example/t/" .. id
    end
    return backend
end

local function new_card_args()
    return {
        "A",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
    }
end

testing.test("next prints the card link on a board with a host", function()
    local result = cmd_board.run("next", {}, hosted(fake(sample())))
    testing.eq(
        result.output,
        "11111111  "
            .. support.COLUMN_NAME.READY
            .. "  1 Pomodoro  docs  Write docs  0 comments, 0 the owner's\n"
            .. "link: https://pomb.example/t/"
            .. ID_A
    )
end)

testing.test("show prints the card link under the card line", function()
    local result = cmd_board.run("show", { "11111111-b" }, hosted(fake(sample())))
    testing.eq(
        result.output,
        "11111111  "
            .. support.COLUMN_NAME.BACKLOG
            .. "  unsized  -  Fix lint\nlink: https://pomb.example/t/"
            .. ID_B
            .. "\n\nno description\n\nno comments"
    )
end)

testing.test("add prints the new card link and --id-only prints the id alone", function()
    local args = new_card_args()
    local result = cmd_board.run("add", args, hosted(fake(sample())))
    testing.eq(
        result.output,
        "added cccccccc "
            .. support.COLUMN_NAME.BACKLOG
            .. "\nlink: https://pomb.example/t/"
            .. ID_C
    )
    args[#args + 1] = "--id-only"
    result = cmd_board.run("add", args, hosted(fake(sample())))
    testing.eq(result.output, ID_C)
end)

testing.test("a board with no host prints no link", function()
    local backend = fake(sample())
    local added = "added cccccccc " .. support.COLUMN_NAME.BACKLOG
    testing.eq(cmd_board.run("add", new_card_args(), backend).output, added)
    testing.eq(cmd_board.run("next", {}, backend).output:find("link:", 1, true), nil)
end)

testing.test("pomb card url joins the host and the card id", function()
    local backend = assert(pomb.new({
        url = "https://pomb.example/",
        token = "pass:secrets/worker/token/pomb",
        name = "dotfiles",
    }))
    testing.eq(backend:card_url(ID_A), "https://pomb.example/t/" .. ID_A)
end)

testing.test("next counts the comments of the card and how many are the owner's", function()
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
    local result = cmd_board.run("next", {}, backend)
    testing.eq(
        result.output,
        "11111111  Ready  1 Pomodoro  docs  Write docs  2 comments, 1 the owner's"
    )
    backend.listed = { backend.listed[2] }
    result = cmd_board.run("next", {}, backend)
    testing.eq(
        result.output,
        "11111111  Ready  1 Pomodoro  docs  Write docs  1 comment, 1 the owner's"
    )
    function backend:comments()
        return nil, "no comments for you"
    end
    result = cmd_board.run("next", {}, backend)
    testing.eq(result.code, 1)
    testing.eq(result.message, "no comments for you")
end)

testing.test("next --column takes Backlog or Icebox and refuses other columns", function()
    local backend = fake(sample())
    testing.eq(cmd_board.run("next", { "--column", support.COLUMN.BACKLOG }, backend).message, nil)
    testing.eq(cmd_board.run("next", { "--column", support.COLUMN.DONE }, backend).code, 2)
    testing.eq(cmd_board.run("next", { "--column" }, backend).code, 2)
    testing.eq(cmd_board.run("next", { "extra" }, backend).code, 2)
    testing.eq(
        cmd_board.run("next", { "--column", support.COLUMN.BACKLOG }, fake({})).output,
        "No cards in Backlog."
    )
end)
testing.test("next --column takes the Review, Verify and Release stage columns", function()
    for _, column in ipairs({
        support.COLUMN_NAME.REVIEW,
        support.COLUMN_NAME.VERIFY,
        support.COLUMN_NAME.RELEASE,
    }) do
        local backend = fake({})
        local result = cmd_board.run("next", { "--column", column:lower() }, backend)
        testing.eq(result.output, "No cards in " .. column .. ".")
        testing.eq(backend.calls[#backend.calls], { "next", column, nil })
    end
    testing.eq(cmd_board.run("next", { "--column", support.COLUMN.PROGRESS }, fake({})).code, 2)
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

testing.test("stale counts whole days, so 6 days is fresh and 7 is stale", function()
    local cards, times = aged(
        { support.COLUMN_NAME.READY, support.COLUMN_NAME.READY, support.COLUMN_NAME.READY },
        { 6, 7, 30 }
    )
    cards[2].size = "2 Pomodori"
    local result = cmd_board.run("stale", {}, fake(cards, times), NOW)
    testing.eq(
        result.output,
        "00000003  Ready  30d  unsized     Card 3\n00000002  Ready  7d   2 Pomodori  Card 2"
    )
end)

testing.test("stale counts a card entered just under the limit as fresh", function()
    local cards, times = aged({ support.COLUMN_NAME.READY }, { 7 })
    times[cards[1].id] = os.date("!%Y-%m-%dT%H:%M:%SZ", NOW - 7 * box.SECONDS_PER_DAY + 1)
    testing.eq(cmd_board.run("stale", {}, fake(cards, times), NOW).output, "No stale cards.")
end)

testing.test("stale covers Backlog, Ready, In Progress, Review and Verify only", function()
    local columns = {
        support.COLUMN_NAME.ICEBOX,
        support.COLUMN_NAME.BACKLOG,
        support.COLUMN_NAME.READY,
        support.COLUMN_NAME.PROGRESS,
        support.COLUMN_NAME.REVIEW,
        support.COLUMN_NAME.VERIFY,
        support.COLUMN_NAME.RELEASE,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.DONE,
    }
    local cards, times = aged(columns, { 5, 40, 40, 40, 40, 40, 40, 40, 40 })
    local result = cmd_board.run("stale", {}, fake(cards, times), NOW)
    local lines = {}
    local first = result.output:match("^(.-)\n\n") or result.output
    for line in first:gmatch("[^\n]+") do
        lines[#lines + 1] = line:match("^%d+%s+(%a+[ %a]-)%s%s")
    end
    testing.eq(lines, {
        support.COLUMN_NAME.BACKLOG,
        support.COLUMN_NAME.READY,
        support.COLUMN_NAME.PROGRESS,
        support.COLUMN_NAME.REVIEW,
        support.COLUMN_NAME.VERIFY,
    })
end)

testing.test("stale skips release cards", function()
    local cards, times = aged(
        { support.COLUMN_NAME.RELEASE, support.COLUMN_NAME.VERIFY },
        { 40, 40 }
    )
    testing.eq(
        cmd_board.run("stale", {}, fake(cards, times), NOW).output,
        "00000002  Verify  40d  unsized  Card 2"
    )
end)

testing.test("stale still lists a Release card the owner labelled needs:human", function()
    local cards, times = aged({ support.COLUMN_NAME.RELEASE }, { 40 }, { { "needs:human" } })
    testing.eq(
        cmd_board.run("stale", {}, fake(cards, times), NOW).output,
        "No stale cards.\n\nmoved by the owner, remove needs:human:\n00000001  Release  40d  unsized  Card 1"
    )
end)

testing.test("stale marks a needs:human card whose newest comment is the owner's", function()
    local human = { "needs:human" }
    local cards, times = aged(
        { support.COLUMN_NAME.READY, support.COLUMN_NAME.BLOCKED, support.COLUMN_NAME.BLOCKED },
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
    local output = cmd_board.run("stale", {}, backend, NOW).output
    testing.ok(output:find(cards[2].name .. " (answered, waiting for your move)", 1, true), output)
    testing.ok(not output:find(cards[3].name .. " (answered", 1, true), output)
    function backend:comments()
        return nil, "pomb is down"
    end
    output = cmd_board.run("stale", {}, backend, NOW).output
    testing.ok(output:find("could not read the comments of " .. cards[2].id, 1, true), output)
end)

testing.test("stale lists every needs:human card apart at any age, and never as stale", function()
    local human = { "needs:human" }
    local cards, times = aged({
        support.COLUMN_NAME.READY,
        support.COLUMN_NAME.BACKLOG,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.DONE,
        support.COLUMN_NAME.READY,
    }, { 9, 20, 50, 60, 1 }, { {}, human, human, human, human })
    cards[2].color = nil
    local result = cmd_board.run("stale", {}, fake(cards, times), NOW)
    testing.eq(
        result.output,
        "00000001  Ready  9d  unsized  Card 1\n\nfor the owner (needs:human):\n"
            .. "00000003  Blocked  50d  unsized  Card 3\n\n"
            .. "moved by the owner, remove needs:human:\n"
            .. "00000004  Done     60d  unsized  Card 4\n"
            .. "00000002  Backlog  20d  unsized  Card 2\n"
            .. "00000005  Ready    1d   unsized  Card 5\n\nunsized outside Icebox:\n"
            .. "00000002  Backlog  Card 2"
    )
    cards, times = aged({ support.COLUMN_NAME.READY }, { 9 }, { human })
    result = cmd_board.run("stale", {}, fake(cards, times), NOW)
    testing.eq(
        result.output,
        "No stale cards.\n\nmoved by the owner, remove needs:human:\n00000001  Ready  9d  unsized  Card 1"
    )
end)

testing.test("stale lists a needs:human card the owner moved to Done", function()
    local cards, times = aged({ support.COLUMN_NAME.DONE }, { 60 }, { { "needs:human" } })
    testing.eq(
        cmd_board.run("stale", {}, fake(cards, times), NOW).output,
        "No stale cards.\n\nmoved by the owner, remove needs:human:\n00000001  Done  60d  unsized  Card 1"
    )
end)

testing.test("stale keeps a needs:human card in Blocked out of moved by the owner", function()
    local cards, times = aged({ support.COLUMN_NAME.BLOCKED }, { 50 }, { { "needs:human" } })
    testing.eq(
        cmd_board.run("stale", {}, fake(cards, times), NOW).output,
        "No stale cards.\n\nfor the owner (needs:human):\n00000001  Blocked  50d  unsized  Card 1"
    )
end)

testing.test("stale lists an unlabelled open card whose newest comment is the owner's", function()
    local cards, times = aged({
        support.COLUMN_NAME.READY,
        support.COLUMN_NAME.PROGRESS,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.DONE,
        support.COLUMN_NAME.READY,
    }, { 1, 2, 3, 4, 10 })
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
    local output = cmd_board.run("stale", {}, backend, NOW).output
    testing.eq(
        output,
        "00000005  Ready  10d  unsized  Card 5\n\nasks nobody, add a needs label:\n"
            .. "00000003  Blocked  3d  unsized  Card 3\n\nnewest comment is the owner's:\n"
            .. "00000003  Blocked  3d  unsized  Card 3\n"
            .. "00000001  Ready    1d  unsized  Card 1"
    )
end)

testing.test(
    "stale lists the unsized cards outside Icebox at any age and leaves sized ones out",
    function()
        local cards, times = aged({
            support.COLUMN_NAME.BACKLOG,
            support.COLUMN_NAME.BACKLOG,
            support.COLUMN_NAME.BACKLOG,
            support.COLUMN_NAME.READY,
            support.COLUMN_NAME.ICEBOX,
            support.COLUMN_NAME.DONE,
        }, { 0, 1, 2, 1, 1, 1 })
        cards[1].color = nil
        cards[3].color = "white"
        cards[4].color = nil
        cards[5].color = nil
        cards[6].color = nil
        testing.eq(
            cmd_board.run("stale", {}, fake(cards, times), NOW).output,
            "No stale cards.\n\nunsized outside Icebox:\n00000001  Backlog  Card 1\n00000003  Backlog  Card 3\n"
                .. "00000004  Ready    Card 4\n00000006  Done     Card 6"
        )
        cards[1].color = "red"
        cards[3].color = "blue"
        cards[4].color = "green"
        cards[6].color = "green"
        testing.eq(cmd_board.run("stale", {}, fake(cards, times), NOW).output, "No stale cards.")
    end
)

testing.test("stale lists a TODO file at the repo root", function()
    local root = support.sandbox({ ["TODO.md"] = "x\n", ["docs/TODO.md"] = "y\n" })
    local backend = fake({}, {})
    backend.root = root
    testing.eq(
        cmd_board.run("stale", {}, backend, NOW).output,
        "No stale cards.\n\ntodo files, move their items onto cards:\nTODO.md\ndocs/TODO.md"
    )
end)

testing.test("stale prints no todo heading without a TODO file", function()
    local backend = fake({}, {})
    backend.root = support.sandbox({})
    testing.eq(cmd_board.run("stale", {}, backend, NOW).output, "No stale cards.")
    backend.root = nil
    testing.eq(cmd_board.run("stale", {}, backend, NOW).output, "No stale cards.")
end)

testing.test("stale names a card it could not date instead of skipping it", function()
    local human = { "needs:human" }
    local cards, times = aged({
        support.COLUMN_NAME.READY,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.DONE,
        support.COLUMN_NAME.ICEBOX,
        support.COLUMN_NAME.READY,
    }, { 1, 1, 1, 1, 1 }, { {}, human, human, {}, {} })
    times[cards[1].id] = nil
    times[cards[2].id] = nil
    times[cards[3].id] = nil
    local result = cmd_board.run("stale", {}, fake(cards, times), NOW)
    testing.eq(
        result.output,
        "No stale cards.\n\ncould not date "
            .. cards[1].id
            .. " Card 1\ncould not date "
            .. cards[2].id
            .. " Card 2\ncould not date "
            .. cards[3].id
            .. " Card 3"
    )
end)

testing.test("stale --days moves the limit", function()
    local cards, times = aged({ support.COLUMN_NAME.READY, support.COLUMN_NAME.READY }, { 2, 3 })
    local result = cmd_board.run("stale", { "--days", "3" }, fake(cards, times), NOW)
    testing.eq(result.output, "00000002  Ready  3d  unsized  Card 2")
    result = cmd_board.run("stale", { "--days", "1" }, fake(cards, times), NOW)
    testing.eq(
        result.output,
        "00000002  Ready  3d  unsized  Card 2\n00000001  Ready  2d  unsized  Card 1"
    )
end)

local function lead_cards()
    local lead, human = { "needs:lead" }, { "needs:lead", "needs:human" }
    local cards, times = aged({
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.READY,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
    }, { 0, 0, 0, 0, 0, 0 }, { lead, lead, human, lead, lead, {} })
    for index, hours in ipairs({ 3, 0.5, 5, 5, 7, 9 }) do
        local at = NOW - hours * box.SECONDS_PER_HOUR
        times[cards[index].id] = os.date("!%Y-%m-%dT%H:%M:%S+00:00", at)
    end
    return cards, times
end

testing.test("stale lists a Blocked needs:lead card past an hour, oldest first", function()
    local cards, times = lead_cards()
    local result = cmd_board.run("stale", {}, fake(cards, times), NOW)
    testing.eq(
        result.output,
        "No stale cards.\n\nfor the owner (needs:human):\n00000003  Blocked  0d  unsized  Card 3\n\n"
            .. "for a lead (needs:lead):\n00000005  Blocked  7h  unsized  Card 5\n"
            .. "00000001  Blocked  3h  unsized  Card 1\n\n"
            .. "asks nobody, add a needs label:\n00000006  Blocked  0d  unsized  Card 6"
    )
end)

testing.test("stale --lead-hours moves the bound and refuses a bad value", function()
    local cards, times = lead_cards()
    local result = cmd_board.run("stale", { "--lead-hours", "4" }, fake(cards, times), NOW)
    testing.ok(
        result.output:find(
            "for a lead (needs:lead):\n00000005  Blocked  7h  unsized  Card 5",
            1,
            true
        )
    )
    testing.ok(not result.output:find("Card 1", 1, true), result.output)
    for _, word in ipairs({ "0", "x", "1.5", "" }) do
        testing.eq(cmd_board.run("stale", { "--lead-hours", word }, fake({}), NOW).code, 2, word)
    end
    testing.eq(cmd_board.run("stale", { "--lead-hours" }, fake({}), NOW).code, 2)
end)

local function held_leads()
    local lead = { board.NEEDS_LEAD }
    local cards, times = aged({
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
    }, { 0, 0, 0, 0 }, { lead, { board.NEEDS_LEAD, board.RUN }, lead, lead })
    for _, card in ipairs(cards) do
        times[card.id] = os.date("!%Y-%m-%dT%H:%M:%S+00:00", NOW - 5 * box.SECONDS_PER_HOUR)
    end
    cards[4].claimant = "someone"
    local backend = fake(cards, times)
    backend.blockers = { [cards[3].id] = true, [cards[4].id] = true }
    return backend
end

testing.test("stale lead rows leave out a run card", function()
    local result = cmd_board.run("stale", {}, held_leads(), NOW)
    testing.ok(not result.output:find("Card 2", 1, true), result.output)
    testing.ok(result.output:find("Card 1", 1, true), result.output)
end)

testing.test("stale lead rows leave out a card an open card blocks", function()
    local result = cmd_board.run("stale", {}, held_leads(), NOW)
    testing.ok(not result.output:find("Card 3", 1, true), result.output)
end)

testing.test("stale lead rows keep a claimed card that is blocked", function()
    local result = cmd_board.run("stale", {}, held_leads(), NOW)
    testing.ok(result.output:find("Card 4", 1, true), result.output)
end)

testing.test("stale lead rows leave out an epic with an open child", function()
    local backend = held_leads()
    local card = backend:cards()[1]
    card.epic = { done = 0, total = 1 }
    local result = cmd_board.run("stale", {}, backend, NOW)
    testing.ok(not result.output:find("Card 1", 1, true), result.output)
end)

testing.test("stale planner rows leave out a run card and keep a free one", function()
    local cards, times = aged({
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
    }, { 0, 0 }, { { board.NEEDS_PLANNER }, { board.NEEDS_PLANNER, board.RUN } })
    for _, card in ipairs(cards) do
        times[card.id] = os.date("!%Y-%m-%dT%H:%M:%S+00:00", NOW - 5 * box.SECONDS_PER_HOUR)
    end
    local result = cmd_board.run("stale", {}, fake(cards, times), NOW)
    testing.ok(result.output:find("Card 1", 1, true), result.output)
    testing.ok(not result.output:find("Card 2", 1, true), result.output)
end)

testing.test("stale refuses when the blockers of a lead card cannot be read", function()
    local backend = held_leads()
    backend.blocked_error = "pomb is down"
    local result = cmd_board.run("stale", {}, backend, NOW)
    testing.eq(result.code, 1)
end)

testing.test("next --column blocked asks the backend for a needs:lead card", function()
    local backend = fake(sample())
    cmd_board.run("next", { "--column", support.COLUMN.BLOCKED }, backend)
    testing.eq(backend.calls[1], { "next", support.COLUMN_NAME.BLOCKED, "needs:lead" })
    backend = fake(sample())
    cmd_board.run("next", {}, backend)
    testing.eq(backend.calls[1], { "next", support.COLUMN_NAME.READY, nil })
    testing.eq(cmd_board.run("next", { "--column", support.COLUMN.DONE }, fake(sample())).code, 2)
end)

testing.test("next --column blocked skips a needs:human card and a claimed one", function()
    local lead = { "needs:lead" }
    local cards = aged({
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.READY,
        support.COLUMN_NAME.BLOCKED,
    }, { 0, 0, 0, 0, 0 }, { { "needs:lead", "needs:human" }, lead, lead, lead, lead })
    cards[2].claimant = "someone"
    local result = cmd_board.run("next", { "--column", support.COLUMN.BLOCKED }, fake(cards))
    testing.ok(result.output:find("00000003", 1, true), result.output)
    cards[3].claimant = "someone"
    cards[5].labels = {}
    testing.eq(
        cmd_board.run("next", { "--column", support.COLUMN.BLOCKED }, fake(cards)).output,
        "No cards in Blocked."
    )
end)

testing.test("stale lists a needs:lead card with an owner comment once", function()
    -- Age a Blocked needs:lead card and let the owner comment last
    local cards, times = aged({ support.COLUMN_NAME.BLOCKED }, { 0 }, { { "needs:lead" } })
    times[cards[1].id] = os.date("!%Y-%m-%dT%H:%M:%S+00:00", NOW - 3 * box.SECONDS_PER_HOUR)
    local backend = fake(cards, times)
    function backend:comments()
        return { { actor = "human", at = "2026-01-01T00:00:00Z", body = "yes" } }
    end

    -- Expect the lead list alone and no owner-comment list
    testing.eq(
        cmd_board.run("stale", {}, backend, NOW).output,
        "No stale cards.\n\nfor a lead (needs:lead):\n00000001  Blocked  3h  unsized  Card 1"
    )
end)

testing.test("stale lists a Blocked needs:planner card apart from the lead ones", function()
    local planner = { "needs:planner" }
    local cards, times = aged({
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.READY,
    }, { 0, 0, 0, 0 }, {
        planner,
        { "needs:lead" },
        { "needs:planner", "needs:human" },
        planner,
    })
    for index, hours in ipairs({ 5, 3, 9, 9 }) do
        local at = NOW - hours * box.SECONDS_PER_HOUR
        times[cards[index].id] = os.date("!%Y-%m-%dT%H:%M:%S+00:00", at)
    end
    local result = cmd_board.run("stale", {}, fake(cards, times), NOW)
    testing.ok(
        result.output:find(
            "for a lead (needs:lead):\n00000002  Blocked  3h  unsized  Card 2",
            1,
            true
        ),
        result.output
    )
    testing.ok(
        result.output:find(
            "for a planner (needs:planner):\n00000001  Blocked  5h  unsized  Card 1",
            1,
            true
        ),
        result.output
    )
    testing.ok(not result.output:find("Card 4", 1, true), result.output)
    result = cmd_board.run("stale", { "--lead-hours", "6" }, fake(cards, times), NOW)
    testing.ok(not result.output:find("for a planner", 1, true), result.output)
end)

testing.test("stale lists a Blocked card that asks nobody", function()
    local cards, times = aged({
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.READY,
    }, { 2, 5, 1 }, { {}, {}, {} })
    local result = cmd_board.run("stale", {}, fake(cards, times), NOW)
    testing.eq(
        result.output,
        "No stale cards.\n\nasks nobody, add a needs label:\n"
            .. "00000002  Blocked  5d  unsized  Card 2\n"
            .. "00000001  Blocked  2d  unsized  Card 1"
    )
end)

testing.test("stale leaves a labelled Blocked card off the asks nobody list", function()
    local labels = { { "needs:human" }, { "needs:lead" }, { "needs:planner" } }
    local cards, times = aged({
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.BLOCKED,
    }, { 2, 2, 2 }, labels)
    local result = cmd_board.run("stale", {}, fake(cards, times), NOW)
    testing.ok(not result.output:find("asks nobody", 1, true), result.output)
end)

testing.test("next --column blocked --for planner asks for a needs:planner card", function()
    local backend = fake(sample())
    cmd_board.run("next", { "--column", support.COLUMN.BLOCKED, "--for", "planner" }, backend)
    testing.eq(backend.calls[1], { "next", support.COLUMN_NAME.BLOCKED, "needs:planner" })
    backend = fake(sample())
    cmd_board.run("next", { "--column", support.COLUMN.BLOCKED, "--for", "lead" }, backend)
    testing.eq(backend.calls[1], { "next", support.COLUMN_NAME.BLOCKED, "needs:lead" })
    testing.eq(cmd_board.run("next", { "--for", "planner" }, fake(sample())).code, 2)
    testing.eq(
        cmd_board.run("next", { "--column", support.COLUMN.BLOCKED, "--for", "x" }, fake(sample())).code,
        2
    )
end)

testing.test("escalate posts the tier and reason to the endpoint", function()
    local cards = blocked_cards()
    cards[1].labels = { "needs:planner", "docs" }
    local backend = fake(cards)
    local result =
        cmd_board.run("escalate", { "11111111-a", "outcome", "2", "is", "bogus" }, backend)
    testing.eq(result.output, "escalated 11111111 to needs:lead")
    testing.eq(backend.calls, { { "escalate", ID_A, "lead", "outcome 2 is bogus", nil } })
end)

testing.test("escalate refuses a card without needs:planner and an empty reason", function()
    local backend = fake(blocked_cards())
    local result = cmd_board.run("escalate", { "11111111-a", "why" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("is not needs:planner", 1, true), result.message)
    testing.eq(cmd_board.run("escalate", { "11111111-a" }, backend).code, 2)
    testing.eq(cmd_board.run("escalate", { "11111111-a", "  " }, backend).code, 2)
    testing.eq(#backend.calls, 0)
end)

testing.test("escalate refuses the ask flags and points to dev board ask", function()
    local cards = blocked_cards()
    cards[1].labels = { "needs:planner" }
    local backend = fake(cards)
    for _, flag in ipairs({ "--question", "--choice", "--recommend", "--why" }) do
        local result = cmd_board.run("escalate", { "11111111-a", flag, "x" }, backend)
        testing.eq(result.code, 2, flag)
        testing.ok(result.message:find(flag, 1, true), result.message)
        testing.ok(result.message:find("dev board ask", 1, true), result.message)
    end
    testing.eq(cmd_board.run("escalate", { "11111111-a", "--why=x" }, backend).code, 2)
    testing.eq(#backend.calls, 0)
end)

testing.test("escalate prints the refusal and writes nothing", function()
    local cards = blocked_cards()
    cards[1].labels = { "needs:planner" }
    local backend = fake(cards)
    backend.refusal = "pomb answered 403: card_locked"
    local result = cmd_board.run("escalate", { "11111111-a", "why" }, backend)
    testing.eq(result.code, 1)
    testing.eq(result.message, "pomb answered 403: card_locked")
    testing.eq(#backend.calls, 1)
    testing.eq(backend.calls[1][1], "escalate")
end)

testing.test("stale refuses a bad --days with a usage error", function()
    for _, word in ipairs({ "0", "-1", "x", "1.5", "" }) do
        local result = cmd_board.run("stale", { "--days", word }, fake({}), NOW)
        testing.eq(result.code, 2, word)
    end
    testing.eq(cmd_board.run("stale", { "--days" }, fake({}), NOW).code, 2)
    testing.eq(cmd_board.run("stale", { "extra" }, fake({}), NOW).code, 2)
end)

testing.test("stale lists untouched Icebox cards", function()
    local human = { "needs:human" }
    local cards, times = aged({
        support.COLUMN_NAME.ICEBOX,
        support.COLUMN_NAME.ICEBOX,
        support.COLUMN_NAME.ICEBOX,
        support.COLUMN_NAME.ICEBOX,
        support.COLUMN_NAME.ICEBOX,
        support.COLUMN_NAME.READY,
    }, { 45, 31, 29, 90, 60, 1 }, { {}, {}, {}, {}, human, {} })
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
    testing.eq(
        cmd_board.run("stale", {}, backend, NOW).output,
        "No stale cards.\n\nfor the owner (needs:human):\n"
            .. "00000005  Icebox  60d  unsized  Card 5\n\nicebox, untouched for 30 days:\n"
            .. "00000001  Icebox  45d  unsized  Card 1\n"
            .. "00000004  Icebox  40d  unsized  Card 4"
    )
    testing.eq(
        cmd_board.run("stale", { "--icebox-days", "10" }, backend, NOW).output,
        "No stale cards.\n\nfor the owner (needs:human):\n"
            .. "00000005  Icebox  60d  unsized  Card 5\n\nicebox, untouched for 10 days:\n"
            .. "00000001  Icebox  45d  unsized  Card 1\n"
            .. "00000004  Icebox  40d  unsized  Card 4\n"
            .. "00000003  Icebox  29d  unsized  Card 3"
    )
end)

testing.test(
    "stale keeps its output when an Icebox card cannot be dated or its comments read",
    function()
        local cards, times = aged({
            support.COLUMN_NAME.READY,
            support.COLUMN_NAME.ICEBOX,
            support.COLUMN_NAME.ICEBOX,
            support.COLUMN_NAME.ICEBOX,
        }, { 9, 50, 50, 50 })
        times[cards[2].id] = nil
        local backend = fake(cards, times)
        function backend:comments(id)
            if id == cards[3].id then
                return nil, "boom"
            end
            return { { at = "later" } }
        end
        testing.eq(
            cmd_board.run("stale", {}, backend, NOW).output,
            "00000001  Ready  9d  unsized  Card 1\n\ncould not date "
                .. cards[2].id
                .. " Card 2\ncould not read the comments of "
                .. cards[3].id
                .. " Card 3\ncould not read the comments of "
                .. cards[4].id
                .. " Card 4"
        )
    end
)

testing.test("stale never lists the landing turn card", function()
    local cards, times = aged(
        { support.COLUMN_NAME.ICEBOX, support.COLUMN_NAME.ICEBOX },
        { 60, 60 }
    )
    cards[1].name = "landing turn"
    testing.eq(
        cmd_board.run("stale", {}, fake(cards, times), NOW).output,
        "No stale cards.\n\nicebox, untouched for 30 days:\n00000002  Icebox  60d  unsized  Card 2"
    )
end)

testing.test("stale counts an Icebox card exactly at the limit as untouched", function()
    local cards, times = aged(
        { support.COLUMN_NAME.ICEBOX, support.COLUMN_NAME.ICEBOX },
        { 30, 29 }
    )
    testing.eq(
        cmd_board.run("stale", {}, fake(cards, times), NOW).output,
        "No stale cards.\n\nicebox, untouched for 30 days:\n00000001  Icebox  30d  unsized  Card 1"
    )
end)

testing.test("stale refuses a bad --icebox-days with a usage error", function()
    for _, word in ipairs({ "0", "-1", "x", "1.5", "" }) do
        testing.eq(cmd_board.run("stale", { "--icebox-days", word }, fake({}), NOW).code, 2, word)
    end
    testing.eq(cmd_board.run("stale", { "--icebox-days" }, fake({}), NOW).code, 2)
end)

testing.test("stale says so when nothing is stale", function()
    testing.eq(cmd_board.run("stale", {}, fake({}), NOW).output, "No stale cards.")
    local cards, times = aged({ support.COLUMN_NAME.READY }, { 1 })
    testing.eq(cmd_board.run("stale", {}, fake(cards, times), NOW).output, "No stale cards.")
end)

testing.test("stale fails on a column time it cannot read", function()
    local cards = aged({ support.COLUMN_NAME.READY }, { 9 })
    local result = cmd_board.run("stale", {}, fake(cards, { [cards[1].id] = "yesterday" }), NOW)
    testing.eq(result.code, 1)
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
local FIRST_CARD = {
    id = ID_A,
    name = "First",
    column_id = READY_COLUMN,
    color_id = "yellow-id",
    labels = { "docs" },
    description = "Why it matters.",
    fields = '{"dev.checks":[{"run":"dev test"},{"on":["local"],"run":"dev lint"}]}',
}
local function export_with_first_card(first)
    return '{"tasks":['
        .. support.pomb_export_task({
            id = ID_B,
            name = "Second",
            column_id = READY_COLUMN,
            position = 2,
            color_id = false,
        })
        .. ","
        .. support.pomb_export_task(setmetatable(first or {}, { __index = FIRST_CARD }))
        .. ","
        .. support.pomb_export_task({
            id = ID_C,
            name = "Early",
            column_id = BACKLOG_COLUMN,
            color_id = "white-id",
        })
        .. "]}"
end
local EXPORT = export_with_first_card()
local PLANNED_TEXT =
    "## Problem\\nwhy\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone\\n\\n## Done when\\n- [%s] a"
local PLANNED_EXPORT = export_with_first_card({ description = PLANNED_TEXT:format(" ") })
local PLANNED_DONE_EXPORT = export_with_first_card({ description = PLANNED_TEXT:format("x") })
local COMMENTS = '[{"id":"aaaaaaaa-1111-4111-8111-111111111111","author":"api-token","actor_kind":"api_token",'
    .. '"token_name":"worker","created_at":"2026-10-27T09:30:12Z","body":"first\\nline"},'
    .. '{"id":"dddddddd-4444-4444-8444-444444444444","author":"x","actor_kind":"user",'
    .. '"token_name":null,"created_at":"2026-10-27T10:00:00Z","body":"mine? no"}]'
local TASK = '{"id":"'
    .. ID_A
    .. '","name":"First","column_id":"'
    .. READY_COLUMN
    .. '","color_id":"yellow-id","labels":["docs"]}'

local CURL = support.pomb_curl(ID_A, ID_B, ID_C)

local function curl_with(root, replacement)
    executable(root .. "/bin/curl", (CURL:gsub("%*/owner/release%) body= ;;", replacement, 1)))
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
    executable(root .. "/bin/sleep", "#!/bin/sh\nexec " .. dev_os.which("sleep") .. " 0.2\n")
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

testing.test("every subcommand without a [board] section says so and exits 1", function()
    local root, home = sandbox({ project = "" })
    for _, args in ipairs({ { "board", "status" }, { "board", "ls" }, { "board", "next" } }) do
        local out, code = dev(root, home, args)
        testing.eq(out, "dev: This project has no board.\n")
        testing.eq(code, 1)
    end
    testing.eq(read(root, "calls"), "")
end)

testing.test("status prints the backend and the board without reaching out", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "status" })
    testing.eq(out, "backend: pomb\nboard: dotfiles\n")
    testing.eq(code, 0)
    testing.eq(read(root, "calls"), "")
end)

testing.test("boards lists every board the token sees and columns reads one by name", function()
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
    testing.eq(code, 0, out)
    testing.eq(out, "dotfiles\nGeneral\n")
    local columns = "Icebox\nBacklog\nReady\nIn Progress\nReview\nBlocked\nDone (done)\n"
    out, code = dev(root, home, { "board", "columns" })
    testing.eq(code, 0, out)
    testing.eq(out, columns)
    out, code = dev(root, home, { "board", "columns", "General" })
    testing.eq(code, 0, out)
    testing.eq(out, "Todo\nDoing\nFinished (done)\n")
    out, code = dev(root, home, { "board", "columns", "dotfiles" })
    testing.eq(code, 0, out)
    testing.eq(out, columns)
    out, code = dev(root, home, { "board", "columns", "nosuch" })
    testing.eq(code, 1, out)
    testing.ok(out:find("no board named nosuch", 1, true), out)
    out, code = dev(root, home, { "board", "columns", "dotfiles", "extra" })
    testing.eq(code, 2, out)
end)

testing.test("the board name defaults to the project directory", function()
    local root, home = sandbox({ project = '[board]\nbackend = "pomb"\n' })
    local out = dev(root, home, { "board", "status" })
    testing.eq(out, "backend: pomb\nboard: " .. fs.basename(root) .. "\n")
end)

testing.test("a local board that was never laid out says to run init", function()
    local root, home = sandbox({ project = '[board]\nbackend = "local"\n' })
    local out, code = dev(root, home, { "board", "ls" })
    testing.ok(out:find("Run `dev board init`.\n", 1, true), out)
    testing.eq(code, 1)
    out, code = dev(root, home, { "board", "status" })
    testing.eq(out, "backend: local\nboard: " .. fs.basename(root) .. "\n")
end)

testing.test("an unknown backend is refused", function()
    local root, home = sandbox({ project = '[board]\nbackend = "jira"\n' })
    local out, code = dev(root, home, { "board", "status" })
    testing.ok(out:find('must be "pomb" or "local"', 1, true), out)
    testing.eq(code, 1)
end)

testing.test("ls lists the cards in column order through pass and curl", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 0)
    testing.eq(
        out,
        "cccccccc  Backlog  Unsized     -     Early\n"
            .. "11111111  Ready    1 Pomodoro  docs  First\n"
            .. "11111111  Ready    unsized     -     Second\n"
    )
    local calls = read(root, "calls")
    testing.ok(
        calls:find(
            "pass show secrets/worker/token/pomb opts=--pinentry-mode error --batch",
            1,
            true
        ),
        calls
    )
    testing.ok(calls:find("https://pomb.example/api/boards/board-1/export-data", 1, true), calls)
end)

testing.test("the token reaches curl on stdin and nowhere else", function()
    local root, home = sandbox()
    local out = dev(root, home, { "-vv", "board", "ls" })
    testing.eq(read(root, "stdin"), 'header = "Authorization: Bearer ' .. TOKEN .. '"\n')
    testing.eq(out:find(TOKEN, 1, true), nil)
    testing.eq(read(root, "calls"):find(TOKEN, 1, true), nil)
    testing.ok(read(root, "calls"):find("-K -", 1, true), read(root, "calls"))
    out = dev(root, home, { "-v", "board", "move", "11111111-a", support.COLUMN.DONE })
    testing.eq(out:find(TOKEN, 1, true), nil)
end)

testing.test("the token is not in the environment curl or pass is started with", function()
    local root, home = sandbox()
    executable(root .. "/bin/curl", (CURL:gsub("cat >", 'env >"$ROOT/env"\ncat >', 1)))
    dev(root, home, { "board", "ls" })
    testing.eq(read(root, "env"):find(TOKEN, 1, true), nil)
end)

testing.test("a locked store fails at once and curl never runs", function()
    local root, home = sandbox({ locked = true })
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find("board unavailable: pass is locked", 1, true), out)
    testing.eq(read(root, "calls"):find("curl", 1, true), nil)
end)

local SHARE = dev_os.capture({ "pwd" }):gsub("\n$", "") .. "/dotfiles/bin/.local/share/dev/board/"

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
    return dev_os.capture({ "sh", "-c", script }, {
        env = {
            PATH = root .. "/bin:" .. os.getenv("PATH"),
            ROOT = root,
            DEV_PASS_LOCK = lock,
            DEV_PASS_LOCK_POLLS = polls or "600",
        },
        stderr = "stdout",
    })
end

testing.test("concurrent pass reads queue on one lock and none times out", function()
    local root = sandbox()
    local lock = root .. "/pass.lock"
    pass_stub(root, lock)
    local cmd = "bash " .. SHARE .. "passlock.sh Agents/x"
    local out = shell(root, lock, "(" .. cmd .. ") & (" .. cmd .. ") & (" .. cmd .. ") & wait")
    testing.eq(select(2, out:gsub(TOKEN, "")), 3, out)
    local order = {}
    for kind in read(root, "events"):gmatch("(%a+) %d+") do
        order[#order + 1] = kind
    end
    testing.eq(order, { "start", "end", "start", "end", "start", "end" })
    testing.eq(fs.read(lock .. "/pid"), nil)
end)

testing.test("a lock left by a killed process does not block a later read", function()
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
    testing.ok(out:find(TOKEN, 1, true), out)
    testing.ok(out:find("code=0", 1, true), out)
end)

testing.test("an old lock is taken over even when its pid is alive again", function()
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
    testing.ok(out:find(TOKEN, 1, true), out)
    testing.ok(out:find("code=0", 1, true), out)
end)

testing.test("a lock with no owner is taken over after a short wait", function()
    local root = sandbox()
    local lock = root .. "/pass.lock"
    pass_stub(root, lock)
    local out = shell(
        root,
        lock,
        "mkdir " .. lock .. "; bash " .. SHARE .. "passlock.sh Agents/x; echo code=$?",
        "100"
    )
    testing.ok(out:find(TOKEN, 1, true), out)
    testing.ok(out:find("code=0", 1, true), out)
end)

testing.test("a lock held by a live process times out with 124", function()
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
    testing.ok(out:find("code=124", 1, true), out)
    testing.eq(out:find(TOKEN, 1, true), nil)
end)

testing.test("a process reads each pass entry once", function()
    local root, home = sandbox()
    local script = string.format(
        "package.path = %q; local pomb = require('dev.board.pomb'); "
            .. "local a = pomb.token('pass:secrets/worker/token/pomb'); "
            .. "local b = pomb.token('pass:secrets/worker/token/pomb'); "
            .. "print(a == b and a ~= nil)",
        support.absolute_path()
    )
    local out, code = dev_os.capture({ "luajit", "-e", script }, {
        env = {
            PATH = root .. "/bin:" .. os.getenv("PATH"),
            HOME = home,
            ROOT = root,
            DEV_PASS_LOCK = root .. "/pass.lock",
        },
        stderr = "stdout",
    })
    testing.eq(code, 0, out)
    testing.eq(out, "true\n")
    testing.eq(select(2, read(root, "calls"):gsub("pass show", "")), 1)
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

testing.test("a pass read is stored in the Keychain and the next read skips pass", function()
    local root = sandbox()
    with_security(root)
    local out = passlock_once(root)
    testing.eq(out, TOKEN .. "\ncode=0\n")
    testing.eq(read(root, "kc"), TOKEN .. "\n")
    out = passlock_once(root)
    testing.eq(out, TOKEN .. "\nkeychain\ncode=0\n")
    testing.eq(occurrences(read(root, "calls"), "pass show"), 1)
end)

testing.test("the token is in no argument list handed to security", function()
    local root = sandbox()
    with_security(root)
    passlock_once(root)
    passlock_once(root)
    local seen = read(root, "seccalls")
    testing.ok(seen:find("security -i", 1, true), seen)
    testing.eq(seen:find(TOKEN, 1, true), nil)
end)

testing.test("each pass entry has its own Keychain item", function()
    local root = sandbox()
    with_security(root)
    passlock_once(root, "Agents/x")
    assert(os.remove(root .. "/kc"))
    passlock_once(root, "Agents/y")
    local seen = read(root, "seccalls")
    testing.ok(seen:find("put dev-pomb-token:Agents/x\n", 1, true), seen)
    testing.ok(seen:find("put dev-pomb-token:Agents/y\n", 1, true), seen)
    testing.ok(seen:find(" -s dev-pomb-token:Agents/y -w\n", 1, true), seen)
end)

testing.test("a failing Keychain falls back to pass and never fails the read", function()
    local root = sandbox()
    with_security(root, "#!/bin/sh\nexit 1\n")
    testing.eq(passlock_once(root), TOKEN .. "\ncode=0\n")
    testing.eq(passlock_once(root), TOKEN .. "\ncode=0\n")
    testing.eq(occurrences(read(root, "calls"), "pass show"), 2)
end)

testing.test("a Keychain item that is not plain text is ignored", function()
    local root = sandbox()
    with_security(root)
    assert(fs.write(root .. "/kc", "bad token; evil\n"))
    testing.eq(passlock_once(root), TOKEN .. "\ncode=0\n")
    testing.eq(occurrences(read(root, "calls"), "pass show"), 1)
end)

testing.test("a read that finds the Keychain filled after the lock releases the lock", function()
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
    testing.eq(passlock_once(root), TOKEN .. "\nkeychain\ncode=0\n")
    testing.eq(occurrences(read(root, "calls"), "pass show"), 0)
    testing.eq(fs.read(root .. "/pass.lock/pid"), nil)
    testing.eq(fs.exists(root .. "/pass.lock"), false)
end)

testing.test(
    "dropping an item that is already gone succeeds and a failing delete does not",
    function()
        local root = sandbox()
        local drop = "bash " .. SHARE .. "keychain.sh drop Agents/x; echo code=$?"
        with_security(root, "#!/bin/sh\nexit 44\n")
        testing.eq(shell(root, root .. "/pass.lock", drop), "code=0\n")
        with_security(root, "#!/bin/sh\nexit 1\n")
        testing.eq(shell(root, root .. "/pass.lock", drop), "code=1\n")
    end
)

testing.test("a refused pass read stores nothing", function()
    local root = sandbox({ locked = true })
    with_security(root)
    testing.ok(passlock_once(root):find("code=1", 1, true))
    testing.eq(fs.read(root .. "/kc"), nil)
end)

testing.test("a cached token Pomb refuses is dropped and read again from pass once", function()
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
    testing.eq(code, 0, out)
    testing.eq(occurrences(read(root, "calls"), "pass show"), 1)
    testing.ok(
        read(root, "seccalls"):find("delete-generic-password", 1, true),
        read(root, "seccalls")
    )
    testing.eq(read(root, "kc"), TOKEN .. "\n")
end)

testing.test("a cached token Pomb refuses stays reported when the delete fails", function()
    local root, home = sandbox()
    with_security(root, SECURITY:gsub('rm %-f "%$ROOT/kc"', "exit 1", 1))
    assert(fs.write(root .. "/kc", OLD_TOKEN .. "\n"))
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\ncat >/dev/null\nprintf \'{"message":"bad"}\\n401\'\n'
    )
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find("pomb answered 401", 1, true), out)
    testing.eq(occurrences(read(root, "calls"), "pass show"), 0)
end)

testing.test("a token read fresh from pass that Pomb refuses is not retried", function()
    local root, home = sandbox()
    with_security(root)
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\ncat >/dev/null\nprintf \'curl %s\\n\' "$*" >>"$ROOT/calls"\n'
            .. 'printf \'{"message":"bad"}\\n401\'\n'
    )
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find("pomb answered 401", 1, true), out)
    testing.eq(occurrences(read(root, "calls"), "pass show"), 1)
end)

testing.test("the keep-alive loop drops a refused cached token", function()
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
            .. "/state card 7 3 https://pomb.example Agents/x 0 dotfiles/x 900",
        "600"
    )
    testing.ok(
        read(root, "seccalls"):find("delete-generic-password", 1, true),
        read(root, "seccalls")
    )
    testing.eq(occurrences(read(root, "calls"), "pass show"), 1)
end)

testing.test("the keep-alive loop reads the token under the same lock", function()
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
            .. "/state card 7 1 https://pomb.example Agents/x 0 dotfiles/x 900",
        "600"
    )
    testing.ok(read(root, "events"):find("held=1", 1, true), out .. read(root, "events"))
end)

testing.test("a token that is not plain text is refused without echoing it", function()
    local root, home = sandbox()
    executable(root .. "/bin/pass", "#!/bin/sh\necho 'bad token\"; evil'\n")
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find("empty or not plain text", 1, true), out)
    testing.eq(out:find("evil", 1, true), nil)
end)

testing.test("a project config cannot choose the server or the token", function()
    local root, home = sandbox({
        project = '[board]\nbackend = "pomb"\nname = "dotfiles"\n'
            .. '[board.pomb]\nurl = "https://evil.example"\ntoken = "pass:Other/entry"\n',
    })
    dev(root, home, { "board", "ls" })
    local calls = read(root, "calls")
    testing.eq(calls:find("evil", 1, true), nil)
    testing.eq(calls:find("Other/entry", 1, true), nil)
    testing.ok(calls:find("pomb.example", 1, true), calls)
end)

testing.test("a missing user url or token reference is a plain error", function()
    local root, home = sandbox({ user = "" })
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find("[board.pomb] url", 1, true), out)
    root, home =
        sandbox({ user = '[board.pomb]\nurl = "https://pomb.example"\ntoken = "$(pass x)"\n' })
    out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find("pass:<entry>", 1, true), out)
    testing.eq(read(root, "calls"), "")
end)

testing.test("an http error reports the server's message", function()
    local root, home = sandbox()
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\ncat >/dev/null\nprintf \'{"code":"x","message":"nope"}\\n403\'\n'
    )
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find("board unavailable: pomb answered 403: nope", 1, true), out)
end)

testing.test("an unreachable server reports the curl exit", function()
    local root, home = sandbox()
    executable(root .. "/bin/curl", "#!/bin/sh\ncat >/dev/null\nexit 7\n")
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(
        out:find("board unavailable: cannot reach https://pomb.example (curl exit 7)", 1, true),
        out
    )
end)

local SUBTASKS_CARD = {
    id = ID_A,
    name = "First",
    column_id = READY_COLUMN,
    color_id = "yellow-id",
    labels = { "docs" },
    description = "## Problem\\nWhy.\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone",
    subtasks = '[{"id":"sub-a","name":"A works","done":false},'
        .. '{"id":"sub-b","name":"B works","done":true}]',
}
local function export_with_subtasks_card(card)
    return '{"tasks":['
        .. support.pomb_export_task(setmetatable(card or {}, { __index = SUBTASKS_CARD }))
        .. "]}"
end
local SUBTASKS_EXPORT = export_with_subtasks_card()

local BACKLOG_EXPORT = export_with_subtasks_card({ column_id = BACKLOG_COLUMN })

testing.test("outcome posts a subtask and patches the Nth by its id", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    local out, code = dev(root, home, { "board", "outcome", "11111111", "C works" })
    testing.eq(code, 0, out)
    testing.eq(out, "outcome 11111111 3 added\n")
    out, code = dev(root, home, { "board", "outcome", "11111111", "--tick", "1" })
    testing.eq(out, "outcome 11111111 1 ticked\n")
    out = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--rename", "2", "B holds", "--reason", "clearer" }
    )
    testing.eq(out, "outcome 11111111 2 reworded\n")
    out = dev(root, home, { "board", "outcome", "11111111", "--untick", "2" })
    testing.eq(out, "outcome 11111111 2 unticked\n")
    local calls = read(root, "calls")
    testing.ok(
        calls:find("-X POST", 1, true) and calls:find("/api/tasks/" .. ID_A .. "/subtasks", 1, true),
        calls
    )
    testing.ok(calls:find('--data-raw {"name":"C works"}', 1, true), calls)
    testing.ok(calls:find("-X PATCH", 1, true), calls)
    testing.ok(calls:find("/api/tasks/" .. ID_A .. "/subtasks/sub-a", 1, true), calls)
    testing.ok(calls:find('--data-raw {"done":true}', 1, true), calls)
    testing.ok(calls:find("/api/tasks/" .. ID_A .. "/subtasks/sub-b", 1, true), calls)
    testing.ok(calls:find('--data-raw {"name":"B holds"}', 1, true), calls)
    testing.ok(calls:find('--data-raw {"done":false}', 1, true), calls)
end)

testing.test("a claimed card's tick needs a name other than the claimant's", function()
    local claimed =
        export_with_subtasks_card({ holder = "project-run/a", lease_expires_at = LIVE_LEASE })
    local root, home = sandbox({ export = claimed })
    local out, code = dev(root, home, { "board", "outcome", "11111111", "--tick", "1" })
    testing.eq(code, 2, out)
    testing.ok(out:find("needs the ticker's name", 1, true), out)
    out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--tick", "1" },
        { agent = "project-run/a" }
    )
    testing.eq(code, 1, out)
    testing.ok(out:find("claimed by project-run/a", 1, true), out)
    testing.eq(read(root, "calls"):find('--data-raw {"done":true}', 1, true), nil)
    out, code = dev(root, home, { "board", "outcome", "11111111", "--untick", "2" })
    testing.eq(out, "outcome 11111111 2 unticked\n", out)
    testing.ok(read(root, "calls"):find('--data-raw {"done":false}', 1, true), out)
    out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--tick", "1" },
        { agent = "project-run/b" }
    )
    testing.eq(code, 0, out)
    testing.eq(out, "outcome 11111111 1 ticked by project-run/b\n", out)
    testing.ok(read(root, "calls"):find('--data-raw {"done":true}', 1, true), out)
end)

testing.test("the claimant named by DEV_AGENT cannot delete or reword its outcome", function()
    local claimed = export_with_subtasks_card({
        column_id = BACKLOG_COLUMN,
        holder = "project-run/a",
        lease_expires_at = LIVE_LEASE,
    })
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
    testing.eq(code, 1, out)
    testing.ok(out:find("claimed by project-run/a", 1, true), out)
    out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--rename", "1", "New", "--reason", "r" },
        own
    )
    testing.eq(code, 1, out)
    testing.ok(out:find("claimed by project-run/a", 1, true), out)
    testing.eq(read(root, "calls"):find("-X DELETE", 1, true), nil)
    testing.eq(read(root, "calls"):find("-X PATCH", 1, true), nil)
    out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--delete", "2", "--reason", "never possible" },
        { agent = LEAD }
    )
    testing.eq(code, 0, out)
    testing.eq(out, "outcome 11111111 2 deleted\n")
    local calls = read(root, "calls")
    testing.ok(calls:find("-X DELETE", 1, true), calls)
    testing.ok(calls:find("/api/tasks/" .. ID_A .. "/subtasks/sub-b", 1, true), calls)
    testing.ok(calls:find("Deleted outcome 2: B works Reason: never possible", 1, true), calls)
end)

testing.test(
    "a refused outcome delete prints Pomb's reason, writes no note and is not queued",
    function()
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
            testing.eq(code, 1, out)
            testing.ok(out:find(case.want, 1, true), out)
            testing.eq(read(root, "calls"):find("/comments", 1, true), nil)
            testing.eq(fs.exists(queue_file(home)), false)
        end
    end
)

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

testing.test("outcome delete on a pomb board sends the DELETE with the lead token", function()
    local root, home = sandbox({ export = BACKLOG_EXPORT, user = LEAD_USER })
    two_tokens(root)
    local out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--delete", "2", "--reason", "never possible" },
        { agent = LEAD, env = { DEV_BOARD_TOKEN = ISSUED_SECRET } }
    )
    testing.eq(code, 0, out)
    testing.eq(out, "outcome 11111111 2 deleted\n")
    local sent = read(root, "delete_stdin")
    testing.ok(
        sent:find("Bearer " .. LEAD_SECRET, 1, true),
        "the DELETE did not carry the lead token"
    )
    testing.eq(sent:find(WORK_SECRET, 1, true), nil)
    testing.eq(sent:find(ISSUED_SECRET, 1, true), nil)
end)

testing.test("outcome delete with no lead token exits 1 naming subtasks.delete", function()
    local root, home = sandbox({ export = BACKLOG_EXPORT })
    local out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--delete", "2", "--reason", "never possible" },
        { agent = LEAD }
    )
    testing.eq(code, 1, out)
    testing.ok(out:find("`lead_token` setting of `[board.pomb]` is not set", 1, true), out)
    testing.ok(out:find("subtasks.delete", 1, true), out)
    testing.eq(read(root, "calls"), "")
    testing.eq(fs.exists(queue_file(home)), false)
end)

testing.test("a 403 on outcome delete names subtasks.delete and the lead token", function()
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
    testing.eq(code, 1, out)
    testing.ok(out:find("subtasks.delete", 1, true), out)
    testing.ok(out:find("lead token", 1, true), out)
    testing.eq(read(root, "calls"):find("-X POST", 1, true), nil)
    testing.eq(fs.exists(queue_file(home)), false)
end)

testing.test(
    "outcome delete refuses a non-lead name before any request and a locked column before the DELETE",
    function()
        local root, home = sandbox({ export = SUBTASKS_EXPORT, user = LEAD_USER })
        local out, code = dev(
            root,
            home,
            { "board", "outcome", "11111111", "--delete", "1", "--reason", "x" },
            { agent = "dotfiles/implementer/82f0e002/1" }
        )
        testing.eq(code, 1, out)
        testing.ok(out:find("Only the lead deletes an outcome", 1, true), out)
        testing.eq(read(root, "calls"), "")
        out, code = dev(
            root,
            home,
            { "board", "outcome", "11111111", "--delete", "1", "--reason", "x" },
            { agent = LEAD }
        )
        testing.eq(code, 1, out)
        testing.eq(read(root, "calls"):find("-X DELETE", 1, true), nil)
    end
)

local function epic_sandbox(children_done, ticked)
    local export = SUBTASKS_EXPORT:gsub('"done":%a+', '"done":' .. tostring(ticked))
        :gsub('"labels":%["docs"%]', '"kind":"epic","labels":["docs"]')
    local task = '{"id":"'
        .. ID_A
        .. '","name":"First","column_id":"'
        .. READY_COLUMN
        .. '","color_id":"yellow-id","kind":"epic",'
        .. '"children_total":2,"children_done":'
        .. children_done
        .. ',"labels":[]}'
    local root, home = sandbox({ export = export, task = task, user = LEAD_USER })
    two_tokens(root)
    executable(
        root .. "/bin/curl",
        (
            CURL:gsub(
                'cat >"$ROOT/stdin"\n',
                'cat >"$ROOT/stdin"\ncase "$*" in *"/move"*) cp "$ROOT/stdin" "$ROOT/move_stdin" ;; esac\n',
                1
            )
        )
    )
    return root, home
end

testing.test("the lead closes an epic with the lead token", function()
    local root, home = epic_sandbox(2, true)
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111", support.COLUMN.DONE },
        { agent = LEAD }
    )
    testing.eq(code, 0, out)
    testing.eq(out, "moved 11111111 to Done\n")
    local sent = read(root, "move_stdin")
    testing.ok(
        sent:find("Bearer " .. LEAD_SECRET, 1, true),
        "the move did not carry the lead token"
    )
    testing.eq(sent:find(WORK_SECRET, 1, true), nil)
end)

testing.test("a worker's move of an epic into Done is refused before the move", function()
    local root, home = epic_sandbox(2, true)
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111", support.COLUMN.DONE },
        { agent = "dotfiles/implementer/82f0e002/1" }
    )
    testing.eq(code, 1, out)
    testing.ok(out:find("Only the lead closes an epic", 1, true), out)
    testing.eq(read(root, "move_stdin"), "")
    testing.eq(read(root, "calls"):find("/move", 1, true), nil)
end)

testing.test("the lead's close of an epic names the open children and unticked outcomes", function()
    local root, home = epic_sandbox(1, true)
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111", support.COLUMN.DONE },
        { agent = LEAD }
    )
    testing.eq(code, 1, out)
    testing.ok(out:find("1 of 2 children are open", 1, true), out)
    testing.eq(read(root, "move_stdin"), "")
    root, home = epic_sandbox(2, false)
    out, code = dev(
        root,
        home,
        { "board", "move", "11111111", support.COLUMN.DONE },
        { agent = LEAD }
    )
    testing.eq(code, 1, out)
    testing.ok(out:find("2 of 2 outcomes are unticked (1. A works, 2. B works)", 1, true), out)
    testing.eq(read(root, "move_stdin"), "")
end)

testing.test("the lead's close of an epic with no lead token set names epics.manage", function()
    local root, home = epic_sandbox(2, true)
    assert(
        fs.write(
            home .. "/.config/dev/config.toml",
            '[board.pomb]\nurl = "https://pomb.example"\ntoken = "pass:secrets/worker/token/pomb"\n'
        )
    )
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111", support.COLUMN.DONE },
        { agent = LEAD }
    )
    testing.eq(code, 1, out)
    testing.ok(out:find("epics.manage", 1, true), out)
    testing.eq(read(root, "move_stdin"), "")
end)

testing.test("the lead's close of an epic is not queued when Pomb is unreachable", function()
    local root, home = epic_sandbox(2, true)
    executable(
        root .. "/bin/curl",
        (
            CURL:gsub(
                'cat >"$ROOT/stdin"\n',
                'cat >"$ROOT/stdin"\ncase "$*" in *"/move"*) exit 7 ;; esac\n',
                1
            )
        )
    )
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111", support.COLUMN.DONE },
        { agent = LEAD }
    )
    testing.eq(code, 1, out)
    testing.eq(fs.exists(queue_file(home)), false)
end)

testing.test("outcome past the last subtask exits 1 and changes nothing", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    local out, code = dev(root, home, { "board", "outcome", "11111111", "--tick", "3" })
    testing.eq(code, 1)
    testing.ok(out:find("The card has 2 outcomes. There is no outcome 3.", 1, true), out)
    testing.eq(read(root, "calls"):find("-X PATCH", 1, true), nil)
end)

testing.test("outcome queues a tick but not an append when the write cannot reach Pomb", function()
    local root, home = sandbox({ export = BACKLOG_EXPORT, user = LEAD_USER })
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\nfor last; do :; done\ncase "$last" in */subtasks*) cat >/dev/null; exit 28 ;; esac\n'
            .. CURL:gsub("^#!/bin/sh\n", "")
    )
    local out, code = dev(root, home, { "board", "outcome", "11111111", "C works" })
    testing.eq(code, 1)
    testing.ok(out:find("curl exit 28", 1, true), out)
    testing.eq(fs.exists(queue_file(home)), false)
    out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--delete", "2", "--reason", "never possible" }
    )
    testing.eq(code, 1)
    testing.ok(out:find("curl exit 28", 1, true), out)
    testing.eq(fs.exists(queue_file(home)), false)
    out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--tick", "1" },
        { agent = "project-run/b" }
    )
    testing.eq(code, 0)
    testing.eq(out, "queued: Pomb unreachable, will sync\n")
    local queued = assert(fs.read(queue_file(home)))
    testing.ok(queued:find('"outcome"', 1, true) and queued:find('"--tick"', 1, true), queued)
    testing.ok(queued:find('"--as"', 1, true) and queued:find('"project-run/b"', 1, true), queued)
end)

testing.test("outcome --rename is never queued when the write cannot reach Pomb", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\nfor last; do :; done\ncase "$last" in */subtasks*) cat >/dev/null; exit 28 ;; esac\n'
            .. CURL:gsub("^#!/bin/sh\n", "")
    )
    local out, code =
        dev(root, home, { "board", "outcome", "11111111", "--rename", "1", "New", "--reason", "r" })
    testing.eq(code, 1, out)
    testing.ok(out:find("curl exit 28", 1, true), out)
    testing.eq(fs.exists(queue_file(home)), false)
end)

testing.test("an unclaimed card's tick ignores an invalid DEV_AGENT", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    local out, code = dev(
        root,
        home,
        { "board", "outcome", "11111111", "--tick", "1" },
        { agent = "bad name" }
    )
    testing.eq(code, 0, out)
    testing.eq(out, "outcome 11111111 1 ticked\n", out)
    testing.ok(read(root, "calls"):find('--data-raw {"done":true}', 1, true), out)
end)

testing.test("rename is queued while Pomb is unreachable", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\nfor last; do :; done\ncase "$last" in */api/tasks/*) cat >/dev/null; exit 28 ;; esac\n'
            .. CURL:gsub("^#!/bin/sh\n", "")
    )
    local out, code = dev(root, home, { "board", "rename", "11111111", "Better", "title" })
    testing.eq(code, 0)
    testing.eq(out, "queued: Pomb unreachable, will sync\n")
    local queued = assert(fs.read(queue_file(home)))
    testing.ok(queued:find('"rename"', 1, true) and queued:find('"Better"', 1, true), queued)
end)

testing.test("discard queues each step it could not take, in order, once", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\nfor last; do :; done\ncase "$last" in */api/tasks/*) cat >/dev/null; exit 7 ;; esac\n'
            .. CURL:gsub("^#!/bin/sh\n", "")
    )
    local out, code = dev(root, home, { "board", "discard", "11111111", "--reason", "Dropped" })
    testing.eq(code, 0)
    testing.eq(out, "queued: Pomb unreachable, will sync\n")
    local queued = assert(fs.read(queue_file(home)))
    local note = assert(queued:find('"note"', 1, true), queued)
    local label = assert(queued:find('"label"', note, true), queued)
    local move = assert(queued:find('"discard_move"', label, true), queued)
    testing.ok(queued:find('"Dropped"', 1, true) and move > label, queued)
end)

testing.test("discard does not queue the note again once it has been posted", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\nfor last; do :; done\ncase "$last" in */comments) ;; */api/tasks/*) cat >/dev/null; exit 7 ;; esac\n'
            .. CURL:gsub("^#!/bin/sh\n", "")
    )
    local out, code = dev(root, home, { "board", "discard", "11111111", "--reason", "Dropped" })
    testing.eq(code, 0)
    testing.eq(out, "queued: Pomb unreachable, will sync\n")
    local queued = assert(fs.read(queue_file(home)))
    testing.ok(not queued:find('"note"', 1, true), queued)
    testing.ok(queued:find('"label"', 1, true) < queued:find('"discard_move"', 1, true), queued)
end)

testing.test(
    "move to Done on a Pomb board names the open outcomes, and discard still closes it",
    function()
        local root, home = sandbox({ export = SUBTASKS_EXPORT })
        local out, code = dev(root, home, { "board", "move", "11111111", support.COLUMN.DONE })
        testing.eq(code, 1, out)
        testing.ok(out:find("1 of 2 outcomes are unticked (1. A works)", 1, true), out)
        testing.ok(not read(root, "calls"):find("/move", 1, true), read(root, "calls"))
        out, code = dev(root, home, { "board", "discard", "11111111" })
        testing.eq(code, 0, out)
        testing.eq(out, "discarded 11111111\n")
    end
)

testing.test("move to Done on a Pomb board refuses subtasks dev cannot read", function()
    local export = '{"tasks":['
        .. support.pomb_export_task({
            id = ID_A,
            name = "First",
            column_id = READY_COLUMN,
            color_id = "yellow-id",
            labels = { "docs" },
            description = "Why.",
            subtasks = '"oops"',
        })
        .. "]}"
    local root, home = sandbox({ export = export })
    local out, code = dev(root, home, { "board", "move", "11111111", support.COLUMN.DONE })
    testing.eq(code, 1, out)
    testing.ok(out:find("cannot be read from Pomb", 1, true), out)
    testing.ok(not read(root, "calls"):find("/move", 1, true), read(root, "calls"))
end)

testing.test("outcome sends the claim's fence on the subtask call", function()
    local root, home = sandbox({ export = SUBTASKS_EXPORT })
    local out, code = dev(root, home, { "board", "take", "11111111" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "outcome", "11111111", "--tick", "1" })
    testing.eq(code, 0, out)
    local calls = read(root, "calls")
    testing.ok(
        calls:find(
            'If-Owner-Fence: 7 --data-raw {"done":true} https://pomb.example/api/tasks/'
                .. ID_A
                .. "/subtasks/sub-a",
            1,
            true
        ),
        calls
    )
    dev(root, home, { "board", "release", "11111111" })
end)

testing.test("a renamed Pomb board is read through the column map and is_done", function()
    local detail = DETAIL:gsub('"Ready"', '"Next"'):gsub(
        '"Done","is_done":true}',
        '"Shipped","is_done":true},{"id":"col-old","name":"Old","is_done":true}'
    )
    local root, home = sandbox({
        detail = detail,
        project = '[board]\nbackend = "pomb"\nname = "dotfiles"\n\n[board.columns]\nready = "Next"\n',
    })
    local out, code = dev(root, home, { "board", "next" })
    testing.eq(code, 0, out)
    testing.eq(
        out,
        "11111111  Next  1 Pomodoro  docs  First  2 comments, 1 the owner's\n" .. LINK_A .. "\n"
    )
    testing.ok(
        read(root, "calls"):find("ready=true&column_id=col-ready", 1, true),
        read(root, "calls")
    )
    out, code = dev(root, home, { "board", "ls", "--column", support.COLUMN.READY })
    testing.eq(code, 0, out)
    testing.ok(out:find("Next", 1, true), out)
    out, code = dev(root, home, { "board", "ls", "--column", "old" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "ls", "--column", support.COLUMN_NAME.PROGRESS })
    testing.eq(code, 0, out)
end)

testing.test("next never offers the landing turn card on a pomb board", function()
    local root, home = sandbox({ task = TASK:gsub('"First"', '"landing turn"') })
    local out, code = dev(root, home, { "board", "next" })
    testing.eq(code, 0, out)
    testing.eq(out, "No ready cards.\n")
end)

testing.test("next asks for the unclaimed unblocked top of Ready", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "next" })
    testing.eq(code, 0)
    testing.eq(
        out,
        "11111111  "
            .. support.COLUMN_NAME.READY
            .. "  1 Pomodoro  docs  First  2 comments, 1 the owner's\n"
            .. LINK_A
            .. "\n"
    )
    testing.ok(
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
    .. '","name":"First","column_id":"'
    .. READY_COLUMN
    .. '","color_id":"yellow-id","labels":["docs"],"kind":"epic","children_total":3,"children_done":%d}'

testing.test("epic_next_skips_open_child", function()
    local root, home = sandbox({ task = EPIC_TASK:format(1) })
    for _, args in ipairs({
        { "board", "next" },
        { "board", "next", "--column", support.COLUMN.REVIEW },
    }) do
        local out, code = dev(root, home, args)
        testing.eq(code, 0, out)
        testing.ok(out:find("^No ", 1), out)
    end
    root, home = sandbox({ task = EPIC_TASK:format(3) })
    local out, code = dev(root, home, { "board", "next" })
    testing.eq(code, 0, out)
    testing.ok(out:find("First", 1, true), out)
end)

testing.test("epic_ls_marks", function()
    local export = EXPORT:gsub(
        '"name":"First"',
        '"name":"First","kind":"epic","children_total":3,"children_done":1',
        1
    )
    local root, home = sandbox({ export = export, task = EPIC_TASK:format(1) })
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 0, out)
    testing.ok(out:find("[epic 2 of 3 open] First", 1, true), out)
    testing.eq(out:find("[epic", out:find("Second", 1, true), true), nil)
    out, code = dev(root, home, { "board", "show", "11111111-a" })
    testing.eq(code, 0, out)
    testing.ok(out:find("kind: epic, 2 open\n", 1, true), out)
    testing.ok(out:find("children: 1 of 3 done\n", 1, true), out)
end)

testing.test("epic_move_refused_by_settings", function()
    local detail = DETAIL:gsub('"name":"Backlog"', '"name":"Backlog","wip_limit":2', 1)
    local export = PLANNED_EXPORT:gsub(
        '"name":"First"',
        '"name":"First","kind":"epic","children_total":3,"children_done":1',
        1
    )
    local root, home =
        sandbox({ export = export, task = EPIC_TASK:format(1), detail = detail, user = LEAD_USER })
    two_tokens(root)
    for _, column in ipairs({ support.COLUMN.BACKLOG, support.COLUMN.DONE }) do
        local out, code = dev(root, home, { "board", "move", "11111111-a", column })
        testing.eq(code, 1, out)
        testing.ok(out:find("is an epic and cannot enter", 1, true), out)
        testing.ok(out:find("2 of 3 children are open.", 1, true), out)
    end
    testing.eq(read(root, "calls"):find("/move", 1, true), nil)
    local out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.REVIEW })
    testing.eq(code, 0, out)
    testing.ok(read(root, "calls"):find("/move", 1, true), read(root, "calls"))
end)

testing.test("epic_move_pomb_refusal", function()
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
            .. "\"}'; status=409 ;;\n*/owner/release) body= ;;"
    )
    local out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.REVIEW })
    testing.eq(code, 1, out)
    testing.ok(out:find(text, 1, true), out)
end)

testing.test("an epic closes when the task read shows every child Done", function()
    local export = PLANNED_EXPORT:gsub('"name":"First"', '"name":"First","kind":"epic"', 1)
    local root, home = sandbox({ export = export, task = EPIC_TASK:format(3), user = LEAD_USER })
    two_tokens(root)
    local out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.DONE })
    testing.eq(code, 0, out)
    testing.ok(
        read(root, "calls"):find("/api/tasks/" .. ID_A .. "/move", 1, true),
        read(root, "calls")
    )
end)

testing.test("an epic with an open child in the task read is refused", function()
    local export = PLANNED_EXPORT:gsub('"name":"First"', '"name":"First","kind":"epic"', 1)
    local root, home = sandbox({ export = export, task = EPIC_TASK:format(1), user = LEAD_USER })
    two_tokens(root)
    local out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.DONE })
    testing.eq(code, 1, out)
    testing.ok(out:find("is an epic and cannot enter", 1, true), out)
    testing.ok(out:find("2 of 3 children are open.", 1, true), out)
    testing.eq(read(root, "calls"):find("/move", 1, true), nil)
end)

testing.test("epic_reopen_out_of_done", function()
    local export = PLANNED_EXPORT:gsub(
        '"name":"First","column_id":"col%-ready"',
        '"name":"First","kind":"epic","children_total":3,"children_done":1,"column_id":"col-done"',
        1
    )
    local task = EPIC_TASK:format(1):gsub("col%-ready", "col-done", 1)
    local root, home = sandbox({ export = export, task = task })
    local out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.BACKLOG })
    testing.eq(code, 0, out)
    local calls = read(root, "calls")
    testing.ok(calls:find("/api/tasks/" .. ID_A .. "/move", 1, true), calls)
    testing.ok(calls:find('"column_id":"col-backlog"', 1, true), calls)
end)

testing.test("next skips a card held by a blocker that is not in Done", function()
    local root, home = sandbox({
        links = '[{"kind":"blocked_by","target_id":"22222222-0000-0000-0000-000000000000"}]',
    })
    local out, code = dev(root, home, { "board", "next", "--column", support.COLUMN.BACKLOG })
    testing.ok(code == 0, out)
    testing.eq(out, "No cards in Backlog.\n")
    out, code = dev(root, home, { "board", "next" })
    testing.ok(code == 0, out)
    testing.eq(out, "No ready cards.\n")
end)

local function far_sandbox(column)
    local link = '[{"kind":"blocked_by",'
        .. '"target_id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","board_id":"board-2"}]'
    local root, home = sandbox({ links = link })
    assert(
        fs.write(
            root .. "/boards.json",
            '[{"id":"board-1","name":"dotfiles"},{"id":"board-2","name":"ci"}]'
        )
    )
    assert(
        fs.write(
            root .. "/general.json",
            '{"id":"board-2","name":"ci","swimlanes":[],"columns":['
                .. '{"id":"far-ready","name":"Ready"},'
                .. '{"id":"far-done","name":"Done","is_done":true}]}'
        )
    )
    assert(
        fs.write(
            root .. "/far.json",
            '{"id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","name":"Far","column_id":"'
                .. column
                .. '","labels":[]}'
        )
    )
    return root, home
end

testing.test("next offers a Ready card whose blocker on another board is Done", function()
    local root, home = far_sandbox("far-done")
    local out, code = dev(root, home, { "board", "next" })
    testing.ok(code == 0, out)
    testing.ok(out:find("First", 1, true), out)
    testing.ok(read(root, "calls"):find("&ready=true", 1, true), read(root, "calls"))
    out, code = dev(root, home, { "board", "next", "--column", support.COLUMN.BACKLOG })
    testing.ok(code == 0, out)
    testing.ok(out:find("First", 1, true), out)
end)

testing.test("next skips a backlog card whose blocker on another board cannot be read", function()
    local root, home = far_sandbox("far-done")
    assert(fs.write(root .. "/far.json", '{"message":"gone"}'))
    assert(fs.write(root .. "/far_gone", ""))
    local out, code = dev(root, home, { "board", "next", "--column", support.COLUMN.BACKLOG })
    testing.ok(code == 0, out)
    testing.eq(out, "No cards in Backlog.\n")
end)

testing.test("next skips a Ready card whose blocker on another board is open", function()
    local root, home = far_sandbox("far-ready")
    local out, code = dev(root, home, { "board", "next" })
    testing.ok(code == 0, out)
    testing.eq(out, "No ready cards.\n")
end)

testing.test("next skips a backlog card whose blocker on another board is open", function()
    local root, home = far_sandbox("far-ready")
    local out, code = dev(root, home, { "board", "next", "--column", support.COLUMN.BACKLOG })
    testing.ok(code == 0, out)
    testing.eq(out, "No cards in Backlog.\n")
end)

testing.test("add posts the card to the named column", function()
    local root, home = sandbox()
    local out, code = dev(root, home, {
        "board",
        "add",
        "New card",
        "--column",
        support.COLUMN.READY,
        "--description",
        V1,
        "--size",
        "1",
        "--checks",
        "dev test",
    })
    testing.eq(code, 0)
    testing.eq(out, "added 11111111 " .. support.COLUMN_NAME.READY .. "\n" .. LINK_A .. "\n")
    local calls = read(root, "calls")
    testing.ok(calls:find('"fields":{"dev.checks":[{"run":"dev test"}]}', 1, true), calls)
    testing.ok(calls:find("-X POST", 1, true), calls)
    testing.ok(
        calls:find(
            '--data-raw {"name":"New card","column_id":"col-ready","description":"why"}',
            1,
            true
        ) or calls:find('"column_id":"col-ready"', 1, true),
        calls
    )
end)

testing.test("add --done-when posts one subtask per outcome after the card", function()
    local root, home = sandbox()
    local out, code = dev(root, home, {
        "board",
        "add",
        "New",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "A works",
        "--done-when",
        "B works",
    })
    testing.eq(code, 0)
    testing.eq(out, "added 11111111 " .. support.COLUMN_NAME.READY .. "\n" .. LINK_A .. "\n")
    local calls = read(root, "calls")
    local first = calls:find("/api/tasks --", 1, true) or calls:find("-X POST", 1, true)
    testing.ok(first, calls)
    local count, at = 0, 1
    while true do
        local found, stop = calls:find("/api/tasks/" .. ID_A .. "/subtasks", at, true)
        if not found then
            break
        end
        count, at = count + 1, stop + 1
    end
    testing.eq(count, 2)
    testing.ok(calls:find('--data-raw {"name":"A works"}', 1, true), calls)
    testing.ok(calls:find('--data-raw {"name":"B works"}', 1, true), calls)
end)

testing.test(
    "a failed subtask names the card and what was not added, and is never queued",
    function()
        local root, home = sandbox()
        assert(fs.write(root .. "/sub_fail", "2"))
        local out, code = dev(root, home, {
            "board",
            "add",
            "New",
            "--problem",
            "x",
            "--change",
            "x",
            "--out-of-scope",
            "y",
            "--size",
            "1",
            "--done-when",
            "A",
            "--done-when",
            "B",
            "--done-when",
            "C",
        })
        testing.eq(code, 1)
        testing.ok(
            out:find("11111111 was added to Backlog but outcome 2 of 3 was not:", 1, true),
            out
        )
        testing.eq(out:find("queued", 1, true), nil)
    end
)

testing.test(
    "add to Ready with outcomes creates in Backlog and moves after the subtasks",
    function()
        local root, home = sandbox()
        local out, code = dev(root, home, {
            "board",
            "add",
            "New",
            "--column",
            support.COLUMN.READY,
            "--size",
            "1",
            "--description",
            V2,
            "--checks",
            "dev test",
            "--done-when",
            "a " .. board.JUDGEMENT,
            "--done-when",
            "b " .. board.JUDGEMENT,
            "--done-when",
            "c " .. board.JUDGEMENT,
        })
        testing.eq(code, 0, out)
        local calls = read(root, "calls")
        testing.ok(calls:find('"column_id":"col-backlog"', 1, true), calls)
        local sub = calls:find("/subtasks", 1, true)
        local move = calls:find("/move", 1, true)
        testing.ok(sub and move and sub < move, calls)
    end
)

testing.test("show and ls read the subtasks from the export", function()
    local export = EXPORT:gsub(
        '"description":"Why it matters.",',
        '"description":"Why it matters.","subtasks":[{"id":"s1","name":"Docs written","done":true},'
            .. '{"id":"s2","name":"Lint clean","done":false}],'
    )
    local root, home = sandbox({ export = export })
    local out = dev(root, home, { "board", "show", "11111111-a" })
    testing.ok(out:find("done when:\n- [x] Docs written\n- [ ] Lint clean\n", 1, true), out)
    out = dev(root, home, { "board", "ls" })
    testing.ok(out:find("1/2", 1, true), out)
end)

testing.test("add --label needs:human reaches pomb after the card and its outcomes", function()
    local root, home = sandbox()
    local out, code = dev(root, home, {
        "board",
        "add",
        "New",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "A",
        "--column",
        support.COLUMN.BLOCKED,
        "--label",
        "needs:human",
    })
    testing.eq(code, 0)
    testing.ok(out:find("added 11111111", 1, true), out)
    local calls = read(root, "calls")
    local created = calls:find("/api/tasks\n", 1, true)
    local outcome = calls:find("/subtasks", 1, true)
    local labelled = calls:find('--data-raw {"labels":["needs:human"]}', 1, true)
    testing.ok(created and outcome and labelled, calls)
    testing.ok(created < outcome and outcome < labelled, calls)
    local _, hits = calls:gsub("needs:human", "")
    testing.eq(hits, 1)
end)

testing.test("a failed subtask on add --label needs:human still labels the card", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/sub_fail", "1"))
    local out, code = dev(root, home, {
        "board",
        "add",
        "New",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "A",
        "--column",
        support.COLUMN.BLOCKED,
        "--label",
        "needs:human",
    })
    testing.eq(code, 1)
    testing.ok(out:find("outcome 1 of 1 was not", 1, true), out)
    testing.ok(read(root, "calls"):find('--data-raw {"labels":["needs:human"]}', 1, true))
end)

local function add_locked(root, home)
    return dev(root, home, {
        "board",
        "add",
        "New",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "A",
        "--column",
        support.COLUMN.BLOCKED,
        "--label",
        "needs:human",
    })
end

testing.test("add --label needs:human names the card when its label is refused", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/label_fail", ""))
    local out, code = add_locked(root, home)
    testing.eq(code, 1)
    testing.ok(out:find("but its labels were not set. Run `dev board label` on it.", 1, true), out)
end)

testing.test("a failed subtask and a refused label on add --label needs:human say both", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/sub_fail", "1"))
    assert(fs.write(root .. "/label_fail", ""))
    local out, code = add_locked(root, home)
    testing.eq(code, 1)
    testing.ok(out:find("outcome 1 of 1 was not", 1, true), out)
    testing.ok(out:find("Its labels were not set either.", 1, true), out)
end)

testing.test("add --size and size reach pomb with the id of the colour, not its label", function()
    local root, home = sandbox()
    local out, code = dev(root, home, {
        "board",
        "add",
        "New",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "3+",
        "--done-when",
        "a",
    })
    testing.eq(code, 0)
    testing.eq(out, "added 11111111 " .. support.COLUMN_NAME.READY .. "\n" .. LINK_A .. "\n")
    local calls = read(root, "calls")
    testing.ok(calls:find('"color_id":"red-id"', 1, true), calls)
    out, code = dev(root, home, { "board", "size", "11111111-a", "2" })
    testing.eq(code, 0)
    testing.eq(out, "sized 11111111 2\n")
    calls = read(root, "calls")
    testing.ok(calls:find("-X PATCH", 1, true), calls)
    testing.ok(calls:find("/api/tasks/" .. ID_A, 1, true), calls)
    testing.ok(calls:find('--data-raw {"color_id":"green-id"}', 1, true), calls)
    out, code = dev(root, home, { "board", "size", "11111111-a", "unsized" })
    testing.eq(code, 1)
    testing.ok(out:find("keeps a size", 1, true), out)
    testing.eq(read(root, "calls"):find('{"color_id":"white-id"}', 1, true), nil)
    local iced = EXPORT:gsub('"column_id":"col%-backlog"', '"column_id":"col-icebox"')
    root, home = sandbox({ export = iced })
    out, code = dev(root, home, { "board", "size", "cccccccc", "unsized" })
    testing.eq(code, 0, out)
    testing.ok(read(root, "calls"):find('{"color_id":"white-id"}', 1, true))
end)

testing.test("a board with no colour of the size asked for is reported", function()
    local root, home = sandbox()
    assert(
        fs.write(root .. "/colors.json", '[{"id":"white-id","value":"white","label":"Unsized"}]')
    )
    local out, code = dev(root, home, { "board", "size", "11111111-a", "1" })
    testing.eq(code, 1)
    testing.ok(out:find("board unavailable: the board has no yellow colour", 1, true), out)
    out, code = dev(root, home, { "board", "size", "11111111-a", "7" })
    testing.eq(code, 2)
end)

testing.test("ls --size reads the colour value from the palette whatever its label", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "ls", "--size", "1" })
    testing.eq(code, 0)
    testing.eq(out, "11111111  Ready  1 Pomodoro  docs  First\n")
    out = dev(root, home, { "board", "ls", "--size", "unsized" })
    testing.eq(out, "cccccccc  Backlog  Unsized  -  Early\n11111111  Ready    unsized  -  Second\n")
end)

testing.test("add --label and label reach pomb as the whole list", function()
    local root, home = sandbox()
    local out, code = dev(root, home, {
        "board",
        "add",
        "New",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
        "--label",
        "a",
        "--label",
        "b",
    })
    testing.eq(code, 0)
    testing.eq(out, "added 11111111 " .. support.COLUMN_NAME.READY .. "\n" .. LINK_A .. "\n")
    testing.ok(read(root, "calls"):find('"labels":["a","b"]', 1, true), read(root, "calls"))
    out, code = dev(root, home, { "board", "label", "11111111-a", "+needs:lead" })
    testing.eq(code, 0)
    testing.eq(out, "labelled 11111111 docs,needs:lead\n")
    local calls = read(root, "calls")
    testing.ok(calls:find("-X PATCH", 1, true), calls)
    testing.ok(calls:find('--data-raw {"labels":["docs","needs:lead"]}', 1, true), calls)
    out, code = dev(root, home, { "board", "label", "11111111-a", "--remove", "docs" })
    testing.eq(code, 0)
    testing.eq(out, "labelled 11111111 -\n")
    testing.ok(read(root, "calls"):find('--data-raw {"labels":[]}', 1, true))
    out, code = dev(root, home, { "board", "label", "11111111-a", "+two words" })
    testing.eq(code, 2)
end)

testing.test("label sends the fence of a claim this machine holds", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    local _, code = dev(root, home, { "board", "label", "11111111-a", "+x" })
    testing.eq(code, 0)
    local patched = read(root, "calls"):match("%-X PATCH.-/api/tasks/")
    testing.ok(patched and patched:find("If-Owner-Fence: 7", 1, true), patched)
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test("pomb escalate posts the tier and reason with the fence", function()
    local export = EXPORT:gsub('"labels":%["docs"%]', '"labels":["needs:planner"]', 1)
    local root, home = sandbox({ export = export })
    dev(root, home, { "board", "take", "11111111-a" })
    local out, code = dev(root, home, { "board", "escalate", "11111111-a", "pick", "one" })
    testing.eq(out, "escalated 11111111 to needs:lead\n")
    testing.eq(code, 0)
    local calls = read(root, "calls")
    local posted = calls:match("[^\n]*\n[^\n]*/api/tasks/" .. ID_A:gsub("%-", "%%-") .. "/escalate")
    testing.ok(posted and posted:find("If-Owner-Fence: 7", 1, true), calls)
    testing.ok(posted:find('"tier":"lead"', 1, true), calls)
    testing.ok(posted:find('"reason":"pick one"', 1, true), calls)
    testing.ok(not calls:find("-X PATCH", 1, true), calls)
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test("checks patches the task's checks field whole, with the claim's fence", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    local out, code = dev(root, home, { "board", "checks", "11111111-a", "dev lint", "dev test" })
    testing.eq(code, 0, out)
    testing.eq(out, "set checks 11111111, 2 rows\n")
    local calls = read(root, "calls")
    testing.ok(
        calls:find(
            '--data-raw {"fields":{"dev.checks":[{"run":"dev lint"},{"run":"dev test"}]}}',
            1,
            true
        ),
        calls
    )
    local patched = calls:match("%-X PATCH.-/api/tasks/")
    testing.ok(patched and patched:find("If-Owner-Fence: 7", 1, true), patched)
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test(
    "checks on a Pomb board without the checks field is refused before any write",
    function()
        local root, home = sandbox({ fields = "[]" })
        local out, code = dev(root, home, { "board", "checks", "11111111-a", "dev lint" })
        testing.eq(code, 1)
        testing.ok(out:find("no checks field", 1, true), out)
        testing.eq(read(root, "calls"):find("-X PATCH", 1, true), nil)
    end
)

testing.test(
    "allow, tests and files patch the task's fields whole, with the claim's fence",
    function()
        local root, home = sandbox()
        dev(root, home, { "board", "take", "11111111-a" })
        local out, code =
            dev(root, home, { "board", "allow", "11111111-a", "test-edits", "ci-edits" })
        testing.eq(code, 0, out)
        testing.eq(out, "set allow 11111111, test-edits ci-edits\n")
        out, code = dev(root, home, { "board", "tests", "11111111-a", "one", "tests::two" })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "files", "11111111-a", "src/a.rs", "src/b.rs" })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "allow", "11111111-a", "none" })
        testing.eq(code, 0, out)
        testing.eq(out, "cleared allow 11111111\n")
        local calls = read(root, "calls")
        for _, body in ipairs({
            '--data-raw {"fields":{"dev.allow":["test-edits","ci-edits"]}}',
            '--data-raw {"fields":{"dev.tests":"one\\ntests::two"}}',
            '--data-raw {"fields":{"dev.files":"src/a.rs\\nsrc/b.rs"}}',
            '--data-raw {"fields":{"dev.allow":null}}',
        }) do
            testing.ok(calls:find(body, 1, true), calls)
        end
        local patched = calls:match("%-X PATCH.-/api/tasks/")
        testing.ok(patched and patched:find("If-Owner-Fence: 7", 1, true), patched)
        dev(root, home, { "board", "release", "11111111-a" })
    end
)

testing.test(
    "allow, tests and files on a Pomb board without the field are refused before any write",
    function()
        local root, home = sandbox({ fields = "[]" })
        for _, case in ipairs({
            { "allow", "test-edits", "dev.allow" },
            { "tests", "one", "dev.tests" },
            { "files", "src/a.rs", "dev.files" },
        }) do
            local out, code = dev(root, home, { "board", case[1], "11111111-a", case[2] })
            testing.eq(code, 1)
            testing.ok(out:find("no " .. case[3] .. " field", 1, true), out)
        end
        testing.eq(read(root, "calls"):find("-X PATCH", 1, true), nil)
    end
)

testing.test("show prints the allow, tests and files fields a Pomb card holds", function()
    local root, home = sandbox({
        export = '{"tasks":[' .. support.pomb_export_task({
            id = ID_A,
            name = "First",
            column_id = READY_COLUMN,
            color_id = false,
            fields = '{"dev.allow":["ci-edits"],'
                .. '"dev.tests":"one\\ntwo","dev.files":"src/a.rs"}',
        }) .. "]}",
    })
    local out, code = dev(root, home, { "board", "show", "11111111-a" })
    testing.eq(code, 0, out)
    testing.ok(
        out:find("allow:\n- ci-edits\n\ntests:\n- one\n- two\n\nfiles:\n- src/a.rs\n", 1, true),
        out
    )
end)

testing.test("note posts a comment of kind agent and move goes to the top of the column", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    local out = dev(root, home, { "board", "note", "11111111-a", "landed", "it" })
    testing.eq(out, "noted 11111111\n")
    local calls = read(root, "calls")
    testing.ok(calls:find("/api/tasks/" .. ID_A .. "/comments", 1, true), calls)
    testing.ok(calls:find('"kind":"agent"', 1, true), calls)
    testing.ok(not calls:find('"author"', 1, true), calls)
    out = dev(
        root,
        home,
        { "board", "note", "11111111-a", "--kind", "decision", "--as", "reviewer", "ok" }
    )
    testing.eq(out, "noted 11111111\n")
    calls = read(root, "calls")
    testing.ok(calls:find('"kind":"decision"', 1, true), calls)
    testing.ok(calls:find('"author":"reviewer"', 1, true), calls)
    out = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.REVIEW })
    testing.eq(out, "moved 11111111 to Review\n")
    calls = read(root, "calls")
    testing.ok(calls:find("/api/tasks/" .. ID_A .. "/move", 1, true), calls)
    testing.ok(calls:find('"column_id":"col-review"', 1, true), calls)
    testing.ok(calls:find('"position":0', 1, true), calls)
end)

local function owner_card_sandbox()
    local export = EXPORT:gsub(
        '"labels":%["docs"%],"description":"Why it matters',
        '"labels":["docs","needs:human"],"description":"Why it matters',
        1
    )
    return sandbox({ export = export })
end

testing.test("ask posts a structured question", function()
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
    testing.eq(out, "asked 11111111\n")
    testing.eq(code, 0)
    local calls = read(root, "calls")
    testing.ok(calls:find("-X POST", 1, true), calls)
    testing.ok(calls:find("/api/tasks/" .. ID_A .. "/comments", 1, true), calls)
    testing.ok(calls:find('"kind":"question"', 1, true), calls)
    testing.ok(calls:find('"text":"Which way?"', 1, true), calls)
    testing.ok(calls:find('"label":"Ship it"', 1, true), calls)
    testing.ok(calls:find('"column_id":"col-ready"', 1, true), calls)
    testing.ok(calls:find('"column_id":"col-icebox"', 1, true), calls)
    testing.ok(calls:find('"recommended":2', 1, true), calls)
    testing.ok(calls:find('"why":"Only he can choose"', 1, true), calls)
end)

testing.test("ask prints the refusal as worded", function()
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
    testing.eq(code, 1)
    testing.ok(out:find("question.why is required", 1, true), out)
end)

testing.test("ask names a choice whose column the board lacks and posts nothing", function()
    local root, home = sandbox()
    local out, code = dev(root, home, {
        "board",
        "ask",
        "11111111-a",
        "--choice",
        "Nowhere=Lost",
    })
    testing.eq(code, 1)
    testing.ok(out:find("choice 1 names Nowhere, which is no column", 1, true), out)
    testing.ok(not read(root, "calls"):find("-X POST", 1, true), read(root, "calls"))
end)

local QUESTION_COMMENT = '[{"id":"qqqqqqqq-1111-4111-8111-111111111111","author":"api-token",'
    .. '"actor_kind":"api_token","token_name":"worker","created_at":"2026-10-27T09:30:12Z",'
    .. '"body":"Which way?","kind":"question","question":{"text":"Which way?","choices":['
    .. '{"label":"Ship it","column_id":"col-ready"},{"label":"Park it","column_id":"col-icebox"}],'
    .. '"recommended":1,"why":"w","answer":%s}}]'

testing.test("answer records the choice through Pomb", function()
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
    testing.eq(out, "answered 11111111 with choice 2\n")
    testing.eq(code, 0)
    local calls = read(root, "calls")
    testing.ok(
        calls:find(
            "/api/tasks/" .. ID_A .. "/comments/qqqqqqqq-1111-4111-8111-111111111111/answer",
            1,
            true
        ),
        calls
    )
    testing.ok(calls:find('"choice":2', 1, true), calls)
    testing.ok(calls:find('"quote":"go with two"', 1, true), calls)
end)

local SHIP_OR_PARK = '[{"label":"Ship it","column_id":"'
    .. READY_COLUMN
    .. '"},{"label":"Park it","column_id":"'
    .. ICEBOX_COLUMN
    .. '"}]'

local function open_question(id, text, choices)
    return '{"id":"'
        .. id
        .. '","author":"api-token","actor_kind":"api_token","token_name":"worker",'
        .. '"created_at":"2026-10-27T09:30:12Z","body":"'
        .. text
        .. '","kind":"question","question":{"text":"'
        .. text
        .. '","choices":'
        .. choices
        .. ',"recommended":1,"why":"w","answer":null}}'
end

testing.test("answer settles every open question on Pomb", function()
    local root, home = owner_card_sandbox()
    local second =
        open_question("rrrrrrrr-1111-4111-8111-111111111111", "Which order?", SHIP_OR_PARK)
    local first = QUESTION_COMMENT:format("null"):sub(2, -2)
    assert(fs.write(root .. "/comments.json", "[" .. first .. "," .. second .. "]"))
    local out, code = dev(
        root,
        home,
        { "board", "answer", "11111111-a", "--choice", "2", "--quote", "go with two" }
    )
    testing.eq(code, 0, out)
    testing.eq(out, "answered 11111111 with choice 2\n")
    local calls = read(root, "calls")
    local first_answer = calls:find(
        "/api/tasks/" .. ID_A .. "/comments/qqqqqqqq-1111-4111-8111-111111111111/answer",
        1,
        true
    )
    local second_answer = calls:find(
        "/api/tasks/" .. ID_A .. "/comments/rrrrrrrr-1111-4111-8111-111111111111/answer",
        1,
        true
    )
    testing.ok(first_answer and second_answer and first_answer < second_answer, calls)
    testing.ok(calls:find('"quote":"go with two"', 1, true), calls)
end)

testing.test("answer refuses open questions with different menus on Pomb", function()
    local root, home = owner_card_sandbox()
    local other = open_question(
        "rrrrrrrr-1111-4111-8111-111111111111",
        "Which order?",
        '[{"label":"Ship it","column_id":"'
            .. READY_COLUMN
            .. '"},{"label":"Park it","column_id":"'
            .. READY_COLUMN
            .. '"}]'
    )
    local first = QUESTION_COMMENT:format("null"):sub(2, -2)
    assert(fs.write(root .. "/comments.json", "[" .. first .. "," .. other .. "]"))
    local out, code = dev(
        root,
        home,
        { "board", "answer", "11111111-a", "--choice", "2", "--quote", "go with two" }
    )
    testing.eq(code, 1, out)
    testing.ok(out:find('"Which way?", "Which order?"', 1, true), out)
    testing.ok(not read(root, "calls"):find("/answer", 1, true), read(root, "calls"))
end)

testing.test("show on Pomb names each open choice's column and marks the recommended", function()
    local root, home = owner_card_sandbox()
    assert(fs.write(root .. "/comments.json", QUESTION_COMMENT:format("null")))
    local out, code = dev(root, home, { "board", "show", "11111111-a" })
    testing.eq(code, 0)
    testing.ok(
        out:find("1. Ship it (" .. support.COLUMN_NAME.READY .. ") [recommended]", 1, true),
        out
    )
    testing.ok(out:find("2. Park it (" .. support.COLUMN_NAME.ICEBOX .. ")", 1, true), out)
    assert(
        fs.write(
            root .. "/comments.json",
            QUESTION_COMMENT:format('{"choice":1,"answered_by":"o","answered_at":"x"}')
        )
    )
    out = dev(root, home, { "board", "show", "11111111-a" })
    testing.ok(not out:find("Ship it", 1, true), out)
end)

testing.test(
    "answer refuses a card whose question is answered already before calling Pomb",
    function()
        local root, home = owner_card_sandbox()
        assert(
            fs.write(
                root .. "/comments.json",
                QUESTION_COMMENT:format('{"choice":1,"answered_by":"o","answered_at":"x"}')
            )
        )
        local out, code =
            dev(root, home, { "board", "answer", "11111111-a", "--choice", "1", "--quote", "yes" })
        testing.eq(code, 1)
        testing.ok(out:find("no open question", 1, true), out)
        testing.ok(not read(root, "calls"):find("/answer", 1, true), read(root, "calls"))
    end
)

testing.test("answer refuses an empty quote before calling Pomb", function()
    local root, home = owner_card_sandbox()
    local _, code =
        dev(root, home, { "board", "answer", "11111111-a", "--choice", "1", "--quote", " " })
    testing.eq(code, 2)
    testing.ok(not read(root, "calls"):find("-X POST", 1, true), read(root, "calls"))
end)

testing.test("order sends each position to Pomb and refuses two columns first", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "order", "11111111-b", "11111111-a" })
    testing.eq(code, 0, out)
    local calls = read(root, "calls")
    local first = calls:find("/api/tasks/" .. ID_B .. "/move", 1, true)
    local second = calls:find("/api/tasks/" .. ID_A .. "/move", 1, true)
    testing.ok(first and second and first < second, calls)
    testing.ok(calls:find('"position":0', 1, true), calls)
    testing.ok(calls:find('"position":1', 1, true), calls)
    root, home = sandbox()
    out, code = dev(root, home, { "board", "order", "11111111-a", "cccccccc" })
    testing.eq(code, 1, out)
    testing.ok(out:find("one column", 1, true), out)
    testing.ok(not read(root, "calls"):find("/move", 1, true), read(root, "calls"))
end)

testing.test(
    "links reads the task's links and names the board of a link to another board",
    function()
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
        testing.eq(code, 0, out)
        testing.eq(
            out,
            "blocked_by  cccccccc  -\nblocks      dddddddd  ci\nrelated     11111111  -\n"
        )
        testing.ok(
            read(root, "calls"):find("/api/tasks/" .. ID_A .. "/links", 1, true),
            read(root, "calls")
        )
        root, home = sandbox()
        out, code = dev(root, home, { "board", "links", "11111111-a" })
        testing.eq(code, 0, out)
        testing.eq(out, "No links.\n")
    end
)

testing.test(
    "unlink deletes the link the token holds and reports a refused delete plainly",
    function()
        local links = '[{"id":"l1","kind":"blocked_by","target_id":"'
            .. ID_C
            .. '","board_id":"board-1"}]'
        local root, home = sandbox({ links = links })
        local out, code =
            dev(root, home, { "board", "unlink", "11111111-a", "blocked_by", "cccccccc" })
        testing.eq(code, 0, out)
        testing.eq(out, "unlinked 11111111 blocked_by cccccccc\n")
        local calls = read(root, "calls")
        testing.ok(calls:find("-X DELETE", 1, true), calls)
        testing.ok(calls:find("/api/tasks/" .. ID_A .. "/links/l1", 1, true), calls)
        local _, deletes_before = read(root, "calls"):gsub("%-X DELETE", "")
        out, code = dev(root, home, { "board", "unlink", "11111111-a", "related", "cccccccc" })
        testing.eq(code, 1, out)
        testing.ok(
            out:find(
                "The card holds no related link to cccccccc. Its links are listed below.",
                1,
                true
            ),
            out
        )
        local _, deletes_after = read(root, "calls"):gsub("%-X DELETE", "")
        testing.eq(deletes_after, deletes_before)
        root, home = sandbox({ links = links })
        curl_with(
            root,
            [[*/links/l1) body='{"code":"permission_denied","permission":"links.delete","message":"m","board_id":null}'; status=403 ;;
*/owner/release) body= ;;]]
        )
        out, code = dev(root, home, { "board", "unlink", "11111111-a", "blocked_by", "cccccccc" })
        testing.eq(code, 1, out)
        testing.eq(
            out,
            "dev: pomb kept the link: this token can delete only the links it created, and this one"
                .. " was made by another token or before Pomb 0.5.40\n"
        )
        testing.ok(
            read(root, "calls"):find("/api/tasks/" .. ID_A .. "/links/l1", 1, true),
            read(root, "calls")
        )
        root, home = sandbox({ links = links })
        curl_with(
            root,
            [[*/links/l1) body='{"code":"permission_denied","permission":"tasks.edit","message":"no write","board_id":"board-9"}'; status=403 ;;
*/owner/release) body= ;;]]
        )
        out, code = dev(root, home, { "board", "unlink", "11111111-a", "blocked_by", "cccccccc" })
        testing.eq(code, 1, out)
        testing.ok(not out:find("kept the link", 1, true), out)
    end
)

testing.test("unlink of a blocks view deletes the blocked_by link on the holder's task", function()
    local links = '[{"id":"l1","kind":"blocks","target_id":"' .. ID_C .. '","board_id":"board-1"}]'
    local holder = '[{"id":"l9","kind":"blocked_by","target_id":"'
        .. ID_A
        .. '","board_id":"board-1"}]'
    local root, home = sandbox({ links = links, holder_links = holder })
    local out, code = dev(root, home, { "board", "unlink", "11111111-a", "blocks", "cccccccc" })
    testing.eq(code, 0, out)
    testing.eq(out, "unlinked 11111111 blocks cccccccc\n")
    local calls = read(root, "calls")
    testing.ok(calls:find("/api/tasks/" .. ID_C .. "/links/l9", 1, true), calls)
    testing.ok(not calls:find("/api/tasks/" .. ID_A .. "/links/l1", 1, true), calls)
end)

testing.test("notes, note --edit and note --delete reach pomb's comment routes", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "notes", "11111111-a" })
    testing.eq(code, 0)
    testing.eq(
        out,
        "aaaaaaaa  worker  -  -  2026-10-27 09:30  first\ndddddddd  human   -  x  2026-10-27 10:00  mine? no\n"
    )
    out, code = dev(root, home, { "board", "show", "11111111-a" })
    testing.eq(code, 0)
    testing.eq(
        out,
        "11111111  "
            .. support.COLUMN_NAME.READY
            .. "  1 Pomodoro  docs  First\n"
            .. LINK_A
            .. "\n\nWhy it matters.\n\n"
            .. "checks:\n- dev test\n- dev lint\n\n"
            .. "aaaaaaaa  worker  -  -  2026-10-27 09:30  first\n"
            .. (" "):rep(42)
            .. "line\ndddddddd  human   -  x  2026-10-27 10:00  mine? no\n"
    )
    out, code = dev(root, home, { "board", "note", "11111111-a", "--edit", "aaaaaaaa", "better" })
    testing.eq(code, 0)
    testing.eq(out, "edited 11111111 aaaaaaaa\n")
    local calls = read(root, "calls")
    testing.ok(calls:find("-X PATCH", 1, true), calls)
    testing.ok(
        calls:find(
            "/api/tasks/" .. ID_A .. "/comments/aaaaaaaa-1111-4111-8111-111111111111",
            1,
            true
        ),
        calls
    )
    testing.ok(calls:find('--data-raw {"body":"better"}', 1, true), calls)
    out, code = dev(root, home, { "board", "note", "11111111-a", "--delete", "aaaaaaaa" })
    testing.eq(code, 0)
    testing.eq(out, "deleted 11111111 aaaaaaaa\n")
    testing.ok(read(root, "calls"):find("-X DELETE", 1, true), read(root, "calls"))
end)

testing.test("a 403 on a comment says it is not yours and exits 1", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "note", "11111111-a", "--edit", "dddddddd", "x" })
    testing.eq(code, 1)
    testing.eq(out, "dev: that comment is not yours to change\n")
    out, code = dev(root, home, { "board", "note", "11111111-a", "--delete", "dddddddd" })
    testing.eq(code, 1)
    testing.eq(out, "dev: that comment is not yours to change\n")
    out, code = dev(root, home, { "board", "note", "11111111-a", "--delete", "eeee" })
    testing.eq(code, 1)
    testing.eq(out, "dev: A comment id needs at least 8 hex characters: eeee.\n")
end)

testing.test("a card_locked 403 on a comment says the card is locked and exits 1", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/locked", ""))
    for _, args in ipairs({
        { "board", "note", "11111111-a", "--edit", "dddddddd", "x" },
        { "board", "note", "11111111-a", "--delete", "dddddddd" },
        { "board", "note", "11111111-a", "a new note" },
    }) do
        local out, code = dev(root, home, args)
        testing.eq(code, 1)
        testing.ok(out:find("labelled needs:human", 1, true), out)
        testing.ok(out:find("Reordering and resizing", 1, true), out)
        testing.eq(out:find("not yours", 1, true), nil)
    end
end)

testing.test("prose warnings reach standard error and the write still happens", function()
    local root, home = sandbox()
    local warning = "Card prose holds a path: src/a.lua.\n"
    local cases = {
        {
            args = {
                "board",
                "add",
                "Fresh",
                "--description",
                "## Problem\nlook in src/a.lua\n\n## Change\n- x\n\n## Out of scope\nnone\n",
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
        testing.eq(code, 0)
        testing.eq(errors, warning)
        testing.eq(out:find("warning", 1, true), nil)
        local calls = read(root, "calls"):sub(before + 1)
        testing.ok(calls:find("-X " .. case.verb, 1, true), calls)
        testing.ok(calls:find(case.marker, 1, true), calls)
    end
end)

testing.test("edit finds the board from a subdirectory and not from outside the project", function()
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
        testing.eq(code, 0, out)
        testing.eq(out, "edited 11111111\n")
    end
    for _, word in ipairs({ "edit", "show" }) do
        local out, code = dev(
            root,
            home,
            { "board", word, "11111111-a" },
            { input = text, cwd = home }
        )
        testing.eq(code, 1, out)
        testing.eq(out, "dev: This project has no board.\n")
    end
end)

testing.test("a nonexistent column on the board is reported", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/detail.json", '{"id":"board-1","name":"dotfiles","columns":[]}'))
    local out, code = dev(root, home, {
        "board",
        "add",
        "x",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
    })
    testing.eq(code, 1)
    testing.ok(out:find("the board has no Backlog column", 1, true), out)
end)

testing.test("board refuses --remote like the other machine-local nouns", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "--remote", "--", "board", "ls" })
    testing.eq(code, 2)
    testing.eq(out, "dev board ls: runs on this machine only, so --remote does not apply\n")
end)

testing.test("capture_input hands the input to stdin and keeps it out of argv", function()
    local out, code = dev_os.capture_input({ "sh", "-c", "cat; echo done" }, "secret\n")
    testing.eq(out, "secret\ndone\n")
    testing.eq(code, 0)
    out, code = dev_os.capture_input({ "sh", "-c", "cat >/dev/null; exit 5" }, "x")
    testing.eq(code, 5)
    testing.raises(function()
        dev_os.capture_input({ "cat" }, "x", { stdout = "null" })
    end, "standard output")
end)

testing.test("capture_input merges standard error into the output when asked", function()
    local out, code = dev_os.capture_input(
        { "sh", "-c", "cat >/dev/null; echo oops >&2" },
        "x",
        { stderr = "stdout" }
    )
    testing.eq(out, "oops\n")
    testing.eq(code, 0)
end)

testing.test("capture_input leaves no temporary file behind", function()
    local dir = support.tempdir()
    local script = string.format(
        "package.path = %q; local o = require('dev.os'); o.capture_input({'cat'}, 'x'); o.capture_input({'sh', '-c', 'cat >/dev/null; exit 3'}, 'x')",
        support.absolute_path()
    )
    local _, code = dev_os.capture({ "luajit", "-e", script }, { env = { TMPDIR = dir } })
    testing.eq(code, 0)
    testing.eq(fs.list(dir), {})
end)

testing.test("a non-JSON answer from the server is reported as unreadable", function()
    local root, home = sandbox()
    executable(
        root .. "/bin/curl",
        "#!/bin/sh\ncat >/dev/null\nprintf '<html>bad gateway</html>\\n502'\n"
    )
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find("board unavailable: pomb sent an answer dev cannot read", 1, true), out)
end)

testing.test("a note may begin with a dash", function()
    local backend = fake(sample())
    local result = cmd_board.run("note", { "cccccccc", "- fixed", "it" }, backend)
    testing.eq(backend.calls[1], { "note", ID_C, "- fixed it", {} })
    testing.eq(result.output, "noted cccccccc")
end)

local function heartbeats(root)
    local count = 0
    for _ in read(root, "calls"):gmatch("/owner/renew") do
        count = count + 1
    end
    return count
end

local function wait_until(test)
    for _ = 1, 100 do
        if test() then
            return true
        end
        dev_os.run({ "sleep", "0.1" })
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
        return dev_os
            .capture({ "ps", "-p", pid, "-o", "command=" }, { stderr = "null" })
            :find("keepalive", 1, true) == nil
    end)
end

local function settle(root)
    local before
    repeat
        before = heartbeats(root)
        dev_os.run({ "sleep", "0.6" })
    until heartbeats(root) == before
    return before
end

testing.test(
    "take grabs the owner with the agent name and renews the lease while the loop runs",
    function()
        local root, home = sandbox()
        local out, code = dev(root, home, { "board", "take", "11111111-a" })
        testing.eq(code, 0)
        testing.ok(
            out:find("took 11111111, fence 7, renewing every 5m for up to 50m", 1, true),
            out
        )
        local calls = read(root, "calls")
        testing.ok(calls:find("/api/tasks/" .. ID_A .. "/owner", 1, true), calls)
        testing.ok(calls:find('"ttl_seconds":900', 1, true), calls)
        testing.ok(calls:find('"name":"dev@', 1, true), calls)
        testing.ok(wait_until(function()
            return heartbeats(root) >= 3
        end))
        local renewed = read(root, "calls"):match("[^\n]*/owner/renew\n?")
        testing.ok(renewed:find("/api/tasks/" .. ID_A .. "/owner/renew", 1, true), renewed)
        testing.ok(renewed:find("If-Owner-Fence: 7", 1, true), renewed)
        testing.ok(renewed:find('"name":"dev@', 1, true), renewed)
        testing.ok(renewed:find('"ttl_seconds":900', 1, true), renewed)
        dev(root, home, { "board", "release", "11111111-a" })
    end
)

testing.test("take under DEV_AGENT sends the role part of the name with the grab", function()
    local root, home = sandbox()
    local out, code = dev(
        root,
        home,
        { "board", "take", "11111111-a" },
        { agent = "pomb/runner/abc" }
    )
    testing.eq(code, 0, out)
    local calls = read(root, "calls")
    testing.ok(calls:find('"name":"pomb/runner/abc"', 1, true), calls)
    testing.ok(calls:find('"role":"runner"', 1, true), calls)
    dev(root, home, { "board", "release", "11111111-a" }, { agent = "pomb/runner/abc" })
end)

testing.test("a claim renew sends the role part of the name under DEV_AGENT", function()
    local root, home = sandbox()
    local agent = { agent = "pomb/runner/abc" }
    dev(root, home, { "board", "take", "11111111-a" }, agent)
    local pid = loop_pid(home)
    dev_os.run({ "kill", pid })
    testing.ok(loop_gone(pid))
    local before = #read(root, "calls")
    local out, code = dev(root, home, { "board", "take", "11111111-a" }, agent)
    testing.eq(code, 0, out)
    local renewed = read(root, "calls"):sub(before):match("[^\n]*/owner/renew\n?")
    testing.ok(renewed:find("/api/tasks/" .. ID_A .. "/owner/renew", 1, true), renewed)
    testing.ok(renewed:find('"name":"pomb/runner/abc"', 1, true), renewed)
    testing.ok(renewed:find('"role":"runner"', 1, true), renewed)
    dev(root, home, { "board", "release", "11111111-a" }, agent)
end)

testing.test("take without DEV_AGENT sends no role with the grab", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "take", "11111111-a" })
    testing.eq(code, 0, out)
    local calls = read(root, "calls")
    testing.ok(calls:find('"ttl_seconds":900', 1, true), calls)
    testing.eq(calls:find('"role"', 1, true), nil)
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test("the state file holds the card, the fence and the pid at mode 600", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    local state = read(home, "state/dev/board/" .. ID_A)
    testing.ok(state:find("card=" .. ID_A .. "\nfence=7\npid=", 1, true), state)
    testing.ok(state:find("pid=%d+\n$"), state)
    testing.eq(state:find(TOKEN, 1, true), nil)
    local mode = dev_os.capture({ "ls", "-l", state_file(home) })
    testing.ok(mode:find("^%-rw%-%-%-%-%-%-%-"), mode)
    mode = dev_os.capture({ "ls", "-ld", home .. "/state/dev/board" })
    testing.ok(mode:find("^drwx%-%-%-%-%-%-"), mode)
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test("release ends the owner lease and stops the loop", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    testing.ok(wait_until(function()
        return heartbeats(root) >= 2
    end))
    local pid = loop_pid(home)
    local out, code = dev(root, home, { "board", "release", "11111111-a" })
    testing.eq(code, 0)
    testing.eq(out, "released 11111111, fence 7\n")
    local released = read(root, "calls"):match("[^\n]*/owner/release\n?")
    testing.ok(released:find("/api/tasks/" .. ID_A .. "/owner/release", 1, true), released)
    testing.ok(released:find("If-Owner-Fence: 7", 1, true), released)
    testing.ok(released:find('"name":"dev@', 1, true), released)
    testing.eq(fs.exists(state_file(home)), false)
    testing.ok(loop_gone(pid))
    local after = settle(root)
    testing.eq(heartbeats(root), after)
end)

testing.test("take loses to another live owner and leaves no loop running", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/owner_held", ""))
    local out, code = dev(root, home, { "board", "take", "11111111-a" })
    testing.eq(code, 1, out)
    testing.ok(out:find("task owned by dotfiles/other until 2999-01-01T00:00:00Z", 1, true), out)
    testing.eq(fs.exists(state_file(home)), false)
    testing.eq(read(root, "calls"):find("/owner/renew", 1, true), nil)
    testing.eq(read(root, "calls"):find("/owner/release", 1, true), nil)
end)

testing.test("take refuses an epic with an open child and grabs nothing", function()
    local export = EXPORT:gsub(
        '"name":"First"',
        '"name":"First","kind":"epic","children_total":3,"children_done":1',
        1
    )
    local root, home = sandbox({ export = export, task = EPIC_TASK:format(1) })
    local out, code = dev(root, home, { "board", "take", "11111111-a" })
    testing.eq(code, 1, out)
    testing.ok(out:find("cannot be taken: 2 of 3 children are open", 1, true), out)
    testing.eq(read(root, "calls"):find("/owner\n", 1, true), nil)
end)

testing.test("a retake renews its fence and grabs again when Pomb answers stale_fence", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    local pid = loop_pid(home)
    dev_os.run({ "kill", pid })
    testing.ok(loop_gone(pid))
    assert(fs.write(root .. "/hb_status", "409"))
    local before = #read(root, "calls")
    local out, code = dev(root, home, { "board", "take", "11111111-a" })
    testing.eq(code, 0, out)
    local calls = read(root, "calls"):sub(before)
    local renewed = calls:find("/api/tasks/" .. ID_A .. "/owner/renew", 1, true)
    testing.ok(renewed, calls)
    testing.ok(calls:find("/api/tasks/" .. ID_A .. "/owner\n", renewed, true), calls)
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test("a retake against another live owner shows the owner held message", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    assert(fs.write(root .. "/hb_status", "409"))
    assert(fs.write(root .. "/owner_held", ""))
    local out, code = dev(root, home, { "board", "take", "11111111-a" })
    testing.eq(code, 1, out)
    testing.ok(out:find("task owned by dotfiles/other until 2999-01-01T00:00:00Z", 1, true), out)
end)

testing.test("release without a taken claim is a plain error", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "release", "11111111-a" })
    testing.eq(code, 1)
    testing.ok(out:find("No claim was taken", 1, true), out)
    testing.eq(read(root, "calls"):find("/owner/release", 1, true), nil)
end)

testing.test("release refuses a card a person owns", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    local person = (
        TASK:gsub(
            '"labels":%["docs"%]',
            '"labels":["docs"],"owner":{"holder":{"kind":"human","id":7},'
                .. '"lease_expires_at":"2999-01-01T00:00:00Z","live":true,"fence":7}',
            1
        )
    )
    assert(fs.write(root .. "/task.json", person))
    local out, code = dev(root, home, { "board", "release", "11111111-a" })
    testing.eq(code, 1, out)
    testing.ok(out:find("The card is held by member 7.", 1, true), out)
    testing.eq(read(root, "calls"):find("/owner/release", 1, true), nil)
    assert(fs.write(root .. "/task.json", TASK))
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test("move out of progress stops the loop and sends the fence", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    dev(root, home, { "board", "take", "11111111-a" })
    testing.ok(wait_until(function()
        return heartbeats(root) >= 2
    end))
    local pid = loop_pid(home)
    local out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.REVIEW })
    testing.eq(code, 0)
    testing.eq(out, "moved 11111111 to Review\n")
    local moved = read(root, "calls"):match("[^\n]*/move\n?")
    testing.ok(moved:find("If-Owner-Fence: 7", 1, true), moved)
    testing.ok(
        read(root, "calls"):find("/api/tasks/" .. ID_A .. "/owner/release", 1, true),
        read(root, "calls")
    )
    testing.eq(fs.exists(state_file(home)), false)
    testing.ok(loop_gone(pid))
    local after = settle(root)
    testing.eq(heartbeats(root), after)
end)

testing.test("move into progress does not release the claim", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    dev(root, home, { "board", "take", "11111111-a" })
    dev(root, home, { "board", "move", "11111111-a", support.COLUMN.PROGRESS })
    testing.eq(read(root, "calls"):find("/owner/release", 1, true), nil)
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test("take prints the card with every comment in full after the claim", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "take", "11111111-a" })
    testing.eq(code, 0, out)
    testing.ok(out:find("^took 11111111, fence 7"), out)
    testing.ok(out:find("\n\n11111111  Ready  1 Pomodoro  docs  First\n", 1, true), out)
    testing.ok(out:find("first\n", 1, true) and out:find("line", 1, true), out)
    testing.ok(out:find("mine? no", 1, true), out)
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test(
    "a move into progress that takes the claim prints the card and its comments",
    function()
        local root, home = sandbox({ export = PLANNED_EXPORT })
        local out, code =
            dev(root, home, { "board", "move", "11111111-a", support.COLUMN.PROGRESS })
        testing.eq(code, 0, out)
        testing.ok(out:find("^moved 11111111 to In Progress\n\n11111111  In Progress  "), out)
        testing.ok(out:find("mine? no", 1, true), out)
        out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.PROGRESS })
        testing.eq(code, 0, out)
        testing.eq(out, "moved 11111111 to In Progress\n")
        dev(root, home, { "board", "release", "11111111-a" })
    end
)

testing.test("move into progress posts the claim then the move to In Progress", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111-a", support.COLUMN.PROGRESS },
        { agent = "r/one" }
    )
    testing.eq(code, 0, out)
    testing.ok(out:find("^moved 11111111 to " .. PROGRESS_NAME .. "\n"), out)
    local calls = read(root, "calls")
    local claim = calls:find("/api/tasks/" .. ID_A .. "/owner\n", 1, true)
    local moved = calls:find("/api/tasks/" .. ID_A .. "/move", 1, true)
    testing.ok(claim and moved and claim < moved, calls)
    local move_line = calls:match("[^\n]*/move\n?")
    testing.ok(move_line:find('"column_id":"' .. PROGRESS_COLUMN .. '"', 1, true), move_line)
    testing.ok(move_line:find("If-Owner-Fence: 7", 1, true), move_line)
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test("take keeps the claim and warns when the card cannot be read after it", function()
    local root, home = sandbox()
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\nfor last; do :; done\ncase "$last" in */api/tasks/'
            .. ID_A
            .. ") exit 7 ;; esac\n"
            .. CURL:gsub("^#!/bin/sh\n", "")
    )
    local out, code = dev(root, home, { "board", "take", "11111111-a" })
    testing.eq(code, 0, out)
    testing.ok(out:find("took 11111111, fence 7", 1, true), out)
    testing.ok(out:find("dev: Took card 11111111, but ", 1, true), out)
    testing.eq(fs.exists(state_file(home)), true)
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test("take names the claimant from --as, then DEV_AGENT, else dev@host", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "take", "11111111-a", "--as", "project-alt/x" })
    testing.eq(code, 0, out)
    testing.ok(read(root, "calls"):find('"name":"project-alt/x"', 1, true), read(root, "calls"))
    dev(root, home, { "board", "release", "11111111-a" })
    out, code = dev(root, home, { "board", "take", "11111111-a" }, { agent = "dotfiles/env" })
    testing.eq(code, 0, out)
    testing.ok(read(root, "calls"):find('"name":"dotfiles/env"', 1, true), read(root, "calls"))
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test("take refuses a name that is not one word of the allowed characters", function()
    local root, home = sandbox()
    for _, name in ipairs({ "two words", "semi;colon", "a:b" }) do
        local out, code = dev(root, home, { "board", "take", "11111111-a", "--as", name })
        testing.eq(code, 2, out)
    end
    testing.eq(cmd_board.run("take", { "11111111-a", "--as", "" }, fake(sample())).code, 2)
    local _, code = dev(root, home, { "board", "take", "11111111-a" }, { agent = "bad name" })
    testing.eq(code, 2)
    testing.eq(read(root, "calls"):find("/owner", 1, true), nil)
end)

testing.test("DEV_AGENT shape accepts repo/role and repo/role/card", function()
    for _, name in ipairs({ "dotfiles/lead", "infra/runner/39f0e015", "a.b_c/d-e/1" }) do
        local root, home = sandbox()
        local out, code = dev(root, home, { "board", "take", "11111111-a" }, { agent = name })
        testing.eq(code, 0, out)
        testing.ok(
            read(root, "calls"):find('"name":"' .. name .. '"', 1, true),
            read(root, "calls")
        )
        dev(root, home, { "board", "release", "11111111-a" })
    end
end)

testing.test(
    "DEV_AGENT shape refuses one part, four parts, a space and an empty segment",
    function()
        local names =
            { "lander", "dotfiles/implementer/38f0e013/1", "a b/c", "a//b", "/a", "a/b/", "a/b c" }
        for _, name in ipairs(names) do
            local root, home = sandbox()
            local out, code = dev(root, home, { "board", "take", "11111111-a" }, { agent = name })
            testing.eq(code, 2, out)
            if not name:find(" ", 1, true) then
                testing.ok(
                    out:find("an agent name is <repo>/<role>[/<card>], got " .. name, 1, true),
                    out
                )
            end
            testing.eq(read(root, "calls"):find("/owner", 1, true), nil)
            out, code = dev(root, home, { "board", "take", "11111111-a", "--as", name })
            testing.eq(code, 2, out)
        end
    end
)

testing.test("DEV_AGENT shape refuses move into progress of an unclaimed card", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111-a", support.COLUMN.PROGRESS },
        { agent = "builder" }
    )
    testing.eq(code, 2, out)
    testing.eq(read(root, "calls"):find("/owner", 1, true), nil)
end)

testing.test("an old-shape claimant still moves and lands its claimed card", function()
    local old = "dotfiles/implementer/95f0e009/1"
    local card = colored("green")
    card.column = support.COLUMN_NAME.READY
    card.claimant = old
    local backend = fake({ card })
    as_agent(old, function()
        local result = cmd_board.run("move", { "cccccccc", support.COLUMN.BACKLOG }, backend)
        testing.eq(result.code, nil, result.message)
        testing.eq(result.output, "moved cccccccc to Backlog")
    end)
end)

testing.test(
    "move into progress takes the claim of an unclaimed card under the agent name",
    function()
        local root, home = sandbox({ export = PLANNED_EXPORT })
        local out, code = dev(
            root,
            home,
            { "board", "move", "11111111-a", support.COLUMN.PROGRESS },
            { agent = "r/one" }
        )
        testing.eq(code, 0, out)
        local calls = read(root, "calls")
        testing.ok(calls:find('"name":"r/one"', 1, true), calls)
        testing.ok(calls:find("If-Owner-Fence: 7", 1, true), calls)
        testing.eq(fs.exists(state_file(home)), true)
        dev(root, home, { "board", "release", "11111111-a" })
    end
)

testing.test("epic_done_children_claim", function()
    local root, home = sandbox({
        export = PLANNED_EXPORT,
        task = EPIC_TASK:format(3),
    })
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111-a", support.COLUMN.PROGRESS },
        { agent = "r/one" }
    )
    testing.eq(code, 0, out)
    local calls = read(root, "calls")
    testing.ok(calls:find("/owner", 1, true), calls)
    testing.ok(calls:find("If-Owner-Fence: 7", 1, true), calls)
    testing.eq(fs.exists(state_file(home)), true)
    dev(root, home, { "board", "release", "11111111-a" })
end)

local function refusing_moves(root)
    local REFUSED_MOVE =
        '*/move) body=\'{"message":"no room"}\'; status=409 ;;\n*/owner/release) body= ;;'
    curl_with(root, REFUSED_MOVE)
end

testing.test("a move into progress that Pomb refuses releases the claim it just took", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    refusing_moves(root)
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111-a", support.COLUMN.PROGRESS },
        { agent = "r/one" }
    )
    testing.eq(code, 1)
    testing.ok(out:find("no room", 1, true), out)
    local calls = read(root, "calls")
    testing.ok(calls:find("/api/tasks/" .. ID_A .. "/owner\n", 1, true), calls)
    local moved = calls:match("[^\n]*/move\n?")
    testing.ok(moved:find("If-Owner-Fence: 7", 1, true), moved)
    local released = calls:match("[^\n]*/owner/release\n?")
    testing.ok(released:find("/api/tasks/" .. ID_A .. "/owner/release", 1, true), calls)
    testing.ok(released:find("If-Owner-Fence: 7", 1, true), released)
    testing.eq(fs.exists(state_file(home)), false)
end)

testing.test("a move into progress of a card claimed elsewhere takes no claim", function()
    local export = export_with_first_card({
        description = PLANNED_TEXT:format(" "),
        holder = "dev@box:42",
        lease_expires_at = LIVE_LEASE,
    })
    local root, home = sandbox({ export = export })
    refusing_moves(root)
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111-a", support.COLUMN.PROGRESS },
        { agent = "r/one" }
    )
    testing.eq(code, 1)
    testing.ok(out:find("no room", 1, true), out)
    local calls = read(root, "calls")
    testing.eq(calls:find("/owner", 1, true), nil)
    testing.eq(fs.exists(state_file(home)), false)
end)

testing.test("move into progress grabs the owner and leaving it ends the lease", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111-a", support.COLUMN.PROGRESS },
        { agent = "r/one" }
    )
    testing.eq(code, 0, out)
    local calls = read(root, "calls")
    testing.ok(calls:find("/api/tasks/" .. ID_A .. "/owner\n", 1, true), calls)
    local grabbed = calls:match("[^\n]*/owner\n")
    testing.ok(grabbed:find('"name":"r/one"', 1, true), grabbed)
    testing.ok(wait_until(function()
        return heartbeats(root) >= 2
    end))
    local pid = loop_pid(home)
    out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.REVIEW }, {
        agent = "r/one",
    })
    testing.eq(code, 0, out)
    local released = read(root, "calls"):match("[^\n]*/owner/release\n?")
    testing.ok(released:find("/api/tasks/" .. ID_A .. "/owner/release", 1, true), released)
    testing.ok(released:find("If-Owner-Fence: 7", 1, true), released)
    testing.eq(fs.exists(state_file(home)), false)
    testing.ok(loop_gone(pid))
end)

testing.test("a release with no claim file sends the owner fence pomb reports", function()
    local export = export_with_first_card({
        description = PLANNED_TEXT:format(" "),
        holder = "r/old",
        lease_expires_at = LIVE_LEASE,
    })
    local root, home = sandbox({ export = export })
    assert(fs.write(root .. "/owner_name", "r/old"))
    local out, code = dev(
        root,
        home,
        { "board", "take", "11111111-a", "--from", "r/old" },
        { agent = "r/one" }
    )
    testing.ok(code == 0, out)
    local released = read(root, "calls"):match("[^\n]*/owner/release\n?")
    testing.ok(released:find("/api/tasks/" .. ID_A .. "/owner/release", 1, true), released)
    testing.ok(released:find("If-Owner-Fence: 7", 1, true), released)
    dev(root, home, { "board", "release", "11111111-a" }, { agent = "r/one" })
end)

testing.test("a release of an owner with no claim sends the owner fence", function()
    local export = export_with_first_card({
        description = PLANNED_TEXT:format(" "),
        holder = "r/old",
        lease_expires_at = LIVE_LEASE,
    })
    local root, home = sandbox({ export = export })
    local task = (
        TASK:gsub(
            '"labels":%["docs"%]',
            '"labels":["docs"],"owner":{"holder":{"kind":"agent","name":"r/old"},'
                .. '"lease_expires_at":"2999-01-01T00:00:00Z","live":true,"fence":9}',
            1
        )
    )
    assert(fs.write(root .. "/task.json", task))
    local out, code = dev(
        root,
        home,
        { "board", "take", "11111111-a", "--from", "r/old" },
        { agent = "r/one" }
    )
    testing.ok(code == 0, out)
    local released = read(root, "calls"):match("[^\n]*/owner/release\n?")
    testing.ok(released:find("If-Owner-Fence: 9", 1, true), released)
    assert(fs.write(root .. "/task.json", TASK))
    dev(root, home, { "board", "release", "11111111-a" }, { agent = "r/one" })
end)

testing.test("a refused move into progress frees the owner", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    refusing_moves(root)
    local out, code = dev(
        root,
        home,
        { "board", "move", "11111111-a", support.COLUMN.PROGRESS },
        { agent = "r/one" }
    )
    testing.eq(code, 1, out)
    testing.ok(out:find("no room", 1, true), out)
    local calls = read(root, "calls")
    local grab = calls:find("/api/tasks/" .. ID_A .. "/owner\n", 1, true)
    local refused = calls:find("/api/tasks/" .. ID_A .. "/move", 1, true)
    local freed = calls:find("/api/tasks/" .. ID_A .. "/owner/release", 1, true)
    testing.ok(grab and refused and freed and grab < refused and refused < freed, calls)
    local released = calls:match("[^\n]*/owner/release\n?")
    testing.ok(released:find("If-Owner-Fence: 7", 1, true), released)
    testing.eq(fs.exists(state_file(home)), false)
    local stopped = heartbeats(root)
    dev_os.run({ "sleep", "0.6" })
    testing.eq(heartbeats(root), stopped)
end)

testing.test("ask ends the owner lease and a plain move to blocked keeps it", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    dev(root, home, { "board", "take", "11111111-a" })
    testing.ok(wait_until(function()
        return heartbeats(root) >= 1
    end))
    local pid = loop_pid(home)
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
        "--why",
        "Only he can choose",
    })
    testing.eq(code, 0, out)
    testing.eq(out, "asked 11111111\n")
    local calls = read(root, "calls")
    local asked = calls:find('"kind":"question"', 1, true)
    local freed = calls:find("/owner/release", 1, true)
    testing.ok(asked and freed and asked < freed, calls)
    local released = calls:match("[^\n]*/owner/release\n?")
    testing.ok(released:find("/api/tasks/" .. ID_A .. "/owner/release", 1, true), released)
    testing.ok(released:find("If-Owner-Fence: 7", 1, true), released)
    testing.eq(fs.exists(state_file(home)), false)
    testing.ok(loop_gone(pid))

    local kept_root, kept_home = sandbox({ export = PLANNED_EXPORT })
    dev(kept_root, kept_home, { "board", "take", "11111111-a" })
    testing.ok(wait_until(function()
        return heartbeats(kept_root) >= 1
    end))
    local before = heartbeats(kept_root)
    out, code = dev(kept_root, kept_home, { "board", "move", "11111111-a", support.COLUMN.BLOCKED })
    testing.eq(code, 0, out)
    testing.eq(read(kept_root, "calls"):find("/owner/release", 1, true), nil)
    testing.eq(fs.exists(state_file(kept_home)), true)
    testing.ok(wait_until(function()
        return heartbeats(kept_root) > before
    end))
    dev(kept_root, kept_home, { "board", "release", "11111111-a" })
end)

testing.test("a move out of blocked ends the owner lease", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    dev(root, home, { "board", "take", "11111111-a" })
    testing.ok(wait_until(function()
        return heartbeats(root) >= 1
    end))
    local pid = loop_pid(home)
    local out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.BLOCKED })
    testing.eq(code, 0, out)
    testing.eq(read(root, "calls"):find("/owner/release", 1, true), nil)
    testing.eq(fs.exists(state_file(home)), true)
    local before = heartbeats(root)
    testing.ok(wait_until(function()
        return heartbeats(root) > before
    end))
    out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.BACKLOG })
    testing.eq(code, 0, out)
    local released = read(root, "calls"):match("[^\n]*/owner/release\n?")
    testing.ok(released:find("/api/tasks/" .. ID_A .. "/owner/release", 1, true), released)
    testing.ok(released:find("If-Owner-Fence: 7", 1, true), released)
    testing.eq(fs.exists(state_file(home)), false)
    testing.ok(loop_gone(pid))
    local after = settle(root)
    testing.eq(heartbeats(root), after)
end)

testing.test("take of a card a live owner holds names the owner and the lease end", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    dev(root, home, { "board", "take", "11111111-a" })
    local out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.BLOCKED })
    testing.eq(out, "moved 11111111 to Blocked\n")
    testing.eq(code, 0)
    assert(fs.write(root .. "/hb_status", "409"))
    assert(fs.write(root .. "/owner_held", ""))
    out, code = dev(root, home, { "board", "take", "11111111-a" })
    testing.eq(code, 1, out)
    testing.ok(out:find("owned by dotfiles/other", 1, true), out)
    testing.ok(out:find("until 2999-01-01T00:00:00Z", 1, true), out)
end)

testing.test("move to ready takes an epic like any card", function()
    local description =
        "## Problem\\nwhy\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone\\n\\n## Done when\\n- [ ] a"
    local export = EXPORT:gsub("Why it matters%.", description, 1)
    local root, home = sandbox({
        export = export,
        task = EPIC_TASK:format(3),
    })
    local out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.READY })
    testing.eq(code, 0, out)
    testing.ok(read(root, "calls"):find("/move", 1, true), read(root, "calls"))
end)

testing.test(
    "a queued change that hits the needs:human refusal is dropped with its reason",
    function()
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
        testing.eq(code, 0, out)
        testing.ok(
            out:find("dropped move 11111111-a: 11111111 is labelled needs:human", 1, true),
            out
        )
        testing.eq(fs.exists(queue), false)
        testing.eq(read(root, "calls"):find("/move", 1, true), nil)
    end
)

testing.test("a release the server refuses after a move warns and the move succeeds", function()
    local root, home = sandbox({ export = PLANNED_DONE_EXPORT })
    dev(root, home, { "board", "take", "11111111-a" })
    curl_with(root, "*/owner/release) body=; status=503 ;;")
    local out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.DONE })
    testing.eq(code, 0)
    testing.ok(out:find("moved 11111111 to Done", 1, true), out)
    testing.ok(out:find("the claim was not released", 1, true), out)
    testing.eq(fs.exists(state_file(home)), false)
end)

testing.test("move into progress keeps the loop and the state", function()
    local root, home = sandbox({ export = PLANNED_EXPORT })
    dev(root, home, { "board", "take", "11111111-a" })
    dev(root, home, { "board", "move", "11111111-a", support.COLUMN.PROGRESS })
    testing.eq(fs.exists(state_file(home)), true)
    local seen = heartbeats(root)
    testing.ok(wait_until(function()
        return heartbeats(root) > seen
    end))
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test("the loop ends by itself after twice the card's size", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    testing.ok(wait_until(function()
        return not fs.exists(state_file(home))
    end))
    testing.eq(settle(root), 10)
end)

testing.test("a renewal the server refuses ends the loop", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/hb_status", "409"))
    dev(root, home, { "board", "take", "11111111-a" })
    testing.ok(wait_until(function()
        return not fs.exists(state_file(home))
    end))
    testing.eq(settle(root), 1)
end)

testing.test("a renewal that cannot reach the server keeps trying", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/hb_status", "503"))
    dev(root, home, { "board", "take", "11111111-a" })
    testing.ok(wait_until(function()
        return heartbeats(root) >= 3
    end))
    testing.eq(fs.exists(state_file(home)), true)
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test("a second take renews with the stored fence", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    dev(root, home, { "board", "take", "11111111-a" })
    testing.ok(
        read(root, "calls"):find(
            "If%-Owner%-Fence: 7 %-%-data%-raw {[^}]*} https://pomb.example/api/tasks/"
                .. ID_A:gsub("%-", "%%-")
                .. "/owner/renew\n"
        ),
        read(root, "calls")
    )
    dev(root, home, { "board", "release", "11111111-a" })
end)

testing.test("take and release want exactly one card", function()
    local root, home = sandbox()
    for _, sub in ipairs({ "take", "release" }) do
        local _, code = dev(root, home, { "board", sub })
        testing.eq(code, 2)
        _, code = dev(root, home, { "board", sub, "11111111-a", "extra" })
        testing.eq(code, 2)
    end
end)

testing.test("the token never reaches argv, the environment, the state or the output", function()
    local root, home = sandbox()
    executable(
        root .. "/bin/curl",
        (CURL:gsub('cat >"$ROOT/stdin"', 'env >>"$ROOT/env"\ncat >"$ROOT/stdin.$$"', 1))
    )
    local out = dev(root, home, { "-vv", "board", "take", "11111111-a" })
    testing.ok(wait_until(function()
        return heartbeats(root) >= 2
    end))
    local ps = dev_os.capture({ "ps", "-ax", "-o", "command=" })
    out = out .. dev(root, home, { "-vv", "board", "release", "11111111-a" })
    testing.eq(out:find(TOKEN, 1, true), nil)
    testing.eq(ps:find(TOKEN, 1, true), nil)
    testing.eq(read(root, "calls"):find(TOKEN, 1, true), nil)
    testing.eq(read(root, "env"):find(TOKEN, 1, true), nil)
    testing.eq(read(home, "state/dev/board/" .. ID_A):find(TOKEN, 1, true), nil)
    local header = 'header = "Authorization: Bearer ' .. TOKEN .. '"\n'
    local seen = dev_os.capture({ "sh", "-c", 'cat "$1"/stdin.*', "sh", root })
    testing.ok(seen:find(header, 1, true), seen)
    testing.eq((seen:gsub(header:gsub("%p", "%%%0"), "")), "")
    testing.ok(read(root, "calls"):find("-K -", 1, true))
end)

testing.test("a lapsed owner lease counts as unowned in ls", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/export.json", '{"tasks":[' .. support.pomb_export_task({
        id = ID_A,
        name = "First",
        column_id = READY_COLUMN,
        color_id = false,
        holder = "dev@box:42",
        lease_expires_at = LIVE_LEASE,
    }) .. "," .. support.pomb_export_task({
        id = ID_B,
        name = "Second",
        column_id = READY_COLUMN,
        position = 2,
        color_id = false,
        holder = "dev@old:1",
        lease_expires_at = "2001-01-01T00:00:00Z",
    }) .. "]}"))
    local out = dev(root, home, { "board", "ls" })
    testing.eq(
        out,
        "11111111  Ready  unsized  -  dev@box:42  First\n"
            .. "11111111  Ready  unsized  -  -           Second\n"
    )
end)

testing.test("next skips live owned cards and takes lapsed ones", function()
    local function owned(until_stamp)
        return (
            TASK:gsub(
                '"labels":%["docs"%]',
                '"labels":["docs"],"owner":{"holder":{"kind":"agent","name":"dev@box:42"},'
                    .. '"lease_expires_at":"'
                    .. until_stamp
                    .. '","live":true,"fence":3}',
                1
            )
        )
    end
    local root, home = sandbox({ task = owned("2999-01-01T00:00:00Z") })
    local out, code = dev(root, home, { "board", "next" })
    testing.eq(code, 0, out)
    testing.eq(out, "No ready cards.\n")
    root, home = sandbox({ task = owned("2001-01-01T00:00:00Z") })
    out, code = dev(root, home, { "board", "next" })
    testing.eq(code, 0, out)
    testing.ok(out:find("^11111111  Ready  1 Pomodoro  docs  First"), out)
end)

testing.test("a lapsed owner lease counts as unowned in lint", function()
    local function in_progress(lease)
        return export_with_first_card({
            column_id = PROGRESS_COLUMN,
            holder = "dev@box:42",
            lease_expires_at = lease,
        })
    end
    local live = LIVE_LEASE
    local dead = "2001-01-01T00:00:00Z"
    local root, home = sandbox({ export = in_progress(live) })
    local out = dev(root, home, { "board", "lint" })
    testing.eq(out:find("in progress with no claimant", 1, true), nil, out)
    root, home = sandbox({ export = in_progress(dead) })
    out = dev(root, home, { "board", "lint" })
    testing.ok(out:find("in progress with no claimant", 1, true), out)
end)

local function claimants_at(root, home, now)
    local script = string.format(
        "package.path = %q; local pomb = require('dev.board.pomb'); local json = require('dev.json'); "
            .. "require('dev.board.store').now = function() return %d end; "
            .. "local b = assert(pomb.new({url = 'https://pomb.example', token = 'pass:secrets/worker/token/pomb', name = 'dotfiles'})); "
            .. "local held = 'nobody'; "
            .. "for _, card in ipairs(assert(b:cards())) do held = card.claimant or held end; "
            .. "print(json.encode({claimant = held}))",
        support.absolute_path(),
        now
    )
    local out, code = dev_os.capture({ "luajit", "-e", script }, {
        env = {
            PATH = root .. "/bin:" .. os.getenv("PATH"),
            HOME = home,
            ROOT = root,
            DEV_PASS_LOCK = root .. "/pass.lock",
        },
        stderr = "stdout",
    })
    testing.eq(code, 0, out)
    return assert(json.decode(out), out).claimant
end

testing.test("a pomb claim holds until store.now passes its lease", function()
    local root, home = sandbox({
        export = export_with_first_card({
            column_id = PROGRESS_COLUMN,
            holder = "dev@box:42",
            lease_expires_at = "2026-01-01T00:00:00Z",
        }),
    })
    local lease = assert(box.parse_time("2026-01-01T00:00:00Z"))
    testing.eq(claimants_at(root, home, lease - 3600), "dev@box:42")
    testing.eq(claimants_at(root, home, lease + 3600), "nobody")
end)

testing.test("ls adds no holder column while nobody holds a claim", function()
    local cards = sample()
    local result = cmd_board.run("ls", {}, fake(cards))
    testing.eq(result.output:find("dev@", 1, true), nil)
    cards[1].claimant = "dev@box:1"
    result = cmd_board.run("ls", {}, fake(cards))
    testing.eq(
        result.output,
        "11111111  Ready    1 Pomodoro  docs  dev@box:1  Write docs\n"
            .. "11111111  Backlog  unsized     -     -          Fix lint"
    )
end)

testing.test("a release the server refuses keeps the state so it can be retried", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    curl_with(root, "*/owner/release) body=; status=503 ;;")
    local out, code = dev(root, home, { "board", "release", "11111111-a" })
    testing.eq(code, 1)
    testing.ok(out:find("pomb answered 503", 1, true), out)
    testing.eq(fs.exists(state_file(home)), true)
    executable(root .. "/bin/curl", CURL)
    _, code = dev(root, home, { "board", "release", "11111111-a" })
    testing.eq(code, 0)
end)

testing.test("stale reads column_entered_at from every page of the tasks view", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "stale" })
    testing.eq(code, 0)
    testing.ok(
        out:find(
            "^11111111  Ready  %d+d  1 Pomodoro  First\n11111111  Ready  %d+d  unsized     Second\n\nnewest comment is the owner's:\n.-\n\nunsized outside Icebox:\n"
        ),
        out
    )
    testing.ok(out:find("unsized outside Icebox:.*cccccccc  Backlog +Early.*could not date"), out)
    testing.ok(out:find("unsized outside Icebox:.*11111111  Ready +Second.*could not date"), out)
    testing.ok(out:find("could not date cccccccc%S+ Early\n$"), out)
    local calls = read(root, "calls")
    testing.ok(
        calls:find("/tasks?limit=500 ", 1, true) or calls:find("/tasks?limit=500\n", 1, true),
        calls
    )
    testing.ok(calls:find("/tasks?limit=500&cursor=c2", 1, true), calls)
    out, code = dev(root, home, { "board", "stale", "--days", "x" })
    testing.eq(code, 2)
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

testing.test("a permission_denied with no board says the token lacks it everywhere", function()
    local root, home = sandbox()
    answering(
        root,
        [[*) printf '{"code":"permission_denied","permission":"tasks.edit","message":"m","board_id":null}\n403' ;;
]]
    )
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.eq(
        out,
        "dev: board unavailable: pomb answered 403: this token lacks the tasks.edit permission "
            .. "on every board; use a token that has it\n"
    )
end)

testing.test("a permission_denied with a board says the board is not assigned", function()
    local root, home = sandbox()
    answering(
        root,
        [[*) printf '{"code":"permission_denied","permission":"tasks.edit","message":"m","board_id":"board-9"}\n403' ;;
]]
    )
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.eq(
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

testing.test("role-refusal-denied names the refused permission and the role", function()
    local root, home = sandbox()
    refusing(
        root,
        '{"role_name":"implementer","permissions":[]}',
        '{"code":"permission_denied","permission":"tasks.edit","message":"m","board_id":null}\\n403'
    )
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.eq(
        out,
        "dev: board unavailable: pomb answered 403: this token (role implementer) lacks the "
            .. "tasks.edit permission on every board; use a token that has it\n"
    )
end)

testing.test("role-refusal-exceeds-grant names the refused action and the role", function()
    local root, home = sandbox()
    refusing(
        root,
        '{"role_name":"implementer"}',
        '{"code":"exceeds_grant","action":"tasks.bin","message":"m"}\\n403'
    )
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.eq(
        out,
        "dev: board unavailable: pomb answered 403: the implementer role cannot tasks.bin\n"
    )
end)

testing.test("role-refusal-norole keeps the refusal text with no role named", function()
    local root, home = sandbox()
    refusing(
        root,
        '{"role_name":null}',
        '{"code":"exceeds_grant","action":"tasks.bin","message":"too much"}\\n403'
    )
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.eq(out, "dev: board unavailable: pomb answered 403: too much\n")
end)

testing.test("role-refusal-expired says the role token expired and to mint it again", function()
    local root, home = sandbox()
    answering(
        root,
        [[*) printf '{"code":"token_expired","message":"whatever"}\n401' ;;
]]
    )
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.eq(
        out,
        "dev: board unavailable: the role token expired; mint it again from its issuer\n"
    )
end)

testing.test("an insufficient_scope 403 still reports the server's message", function()
    local root, home = sandbox()
    answering(
        root,
        [[*) printf '{"code":"insufficient_scope","message":"insufficient token scope: needs admin"}\n403' ;;
]]
    )
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.eq(
        out,
        "dev: board unavailable: pomb answered 403: insufficient token scope: needs admin\n"
    )
end)

testing.test("a board missing from a token's assigned boards gets its own message", function()
    local root, home = sandbox()
    answering(
        root,
        [[*/api/v1/auth/whoami) printf '{"permissions":["tasks.read"],"boards":[{"id":"b1","name":"Other"}]}\n200' ;;
*/api/boards) printf '[{"id":"b1","name":"Other"}]\n200' ;;
]]
    )
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.eq(
        out,
        "dev: board unavailable: pomb lists no board named dotfiles for this token, which is "
            .. "assigned only to Other; if the board exists, add it to the token\n"
    )
end)

testing.test("a missing board stays plain on a token that sees every board", function()
    for _, who in ipairs({ '{"scope":"work"}', '{"permissions":["tasks.read"],"boards":"all"}' }) do
        local root, home = sandbox()
        answering(root, "*/api/v1/auth/whoami) printf '" .. who .. [[\n200' ;;
*/api/boards) printf '[{"id":"b1","name":"Other"}]\n200' ;;
]])
        local out, code = dev(root, home, { "board", "ls" })
        testing.eq(code, 1)
        testing.eq(out, "dev: board unavailable: pomb has no board named dotfiles\n")
    end
end)

testing.test(
    "add --checks on a Pomb board without the checks field is refused before any write",
    function()
        local root, home = sandbox({ fields = "[]" })
        local out, code = dev(root, home, {
            "board",
            "add",
            "New",
            "--problem",
            "x",
            "--change",
            "x",
            "--out-of-scope",
            "y",
            "--size",
            "1",
            "--done-when",
            "a",
            "--checks",
            "dev test",
        })
        testing.eq(code, 2)
        testing.ok(out:find("no checks field", 1, true), out)
        testing.eq(read(root, "calls"):find("-X POST", 1, true), nil)
    end
)

testing.test(
    "prose_warnings names each hex id, hash and path outside the Change section",
    function()
        testing.eq(board.prose_warnings("fixed in 2af0e003 and 0ef0e008."), {
            "Card prose holds a hex id or hash: 2af0e003.",
            "Card prose holds a hex id or hash: 0ef0e008.",
        })
        testing.eq(
            board.prose_warnings("see `dotfiles/bin/dev.lua`, ~/notes and ./run, /etc/hosts"),
            {
                "Card prose holds a path: dotfiles/bin/dev.lua.",
                "Card prose holds a path: ~/notes.",
                "Card prose holds a path: ./run.",
                "Card prose holds a path: /etc/hosts.",
            }
        )
        testing.eq(
            board.prose_warnings("## Problem\nsee a/b.lua\n\n## Change\n- a/b.lua 2af0e003\n"),
            {
                "Card prose holds a path: a/b.lua.",
            }
        )
        testing.eq(
            board.prose_warnings(
                "## Done when\n- [ ] x\n## Change\nsrc/a.lua\n## Out of scope\nsrc/a.lua"
            ),
            {
                "Card prose holds a path: src/a.lua.",
            }
        )
    end
)

testing.test("prose_warnings leaves a lone slash command alone", function()
    testing.eq(board.prose_warnings("type /exit or /quit to leave"), {})
    testing.eq(board.prose_warnings("see /etc/hosts, ~/x and /a.lua"), {
        "Card prose holds a path: /etc/hosts.",
        "Card prose holds a path: ~/x.",
        "Card prose holds a path: /a.lua.",
    })
end)

testing.test("prose_warnings leaves clean prose, plain words, numbers and URLs alone", function()
    testing.eq(
        board.prose_warnings("a decade of facade 1234567 and 20261028, and/or I/O, v1.2"),
        {}
    )
    testing.eq(board.prose_warnings("https://example.com/a/b.html deadbeef12 is read"), {
        "Card prose holds a hex id or hash: deadbeef12.",
    })
    testing.eq(board.prose_warnings(nil), {})
    testing.eq(board.prose_warnings(""), {})
end)

testing.test("add, note and edit report prose warnings and still write", function()
    local backend = fake(sample())
    local result =
        cmd_board.run("note", { "cccccccc", "see", "2af0e003", "and", "0ef0e008" }, backend)
    testing.eq(result.output, "noted cccccccc")
    testing.eq(#result.warnings, 2)
    testing.eq(#backend.calls, 1)
    result = cmd_board.run("note", { "cccccccc", "all", "clear" }, backend)
    testing.eq(#result.warnings, 0)
    result = cmd_board.run("add", {
        "X",
        "--description",
        "## Problem\nin src/a.lua\n\n## Change\n- x\n\n## Out of scope\nnone\n",
        "--size",
        "1",
        "--done-when",
        "a",
    }, backend)
    testing.eq(result.warnings, { "Card prose holds a path: src/a.lua." })
    result = cmd_board.run("add", { "X", "--description", V1, "--size", "1" }, backend)
    testing.eq(result.warnings, {})
    result = cmd_board.run(
        "edit",
        { "cccccccc", "## Change\n- a/b.lua\n## Problem\nx/y.sh\n## Out of scope\nn" },
        backend
    )
    testing.eq(result.warnings, { "Card prose holds a path: x/y.sh." })
end)

testing.test("split_checklist takes the Done when items and leaves the rest", function()
    local items, rest = board.split_checklist(
        "## Problem\nP\n\n\n## Done when\n* [X] one\n  - [ ] two\n\n## Out of scope\nN\n"
    )
    testing.eq(items, { { name = "one", done = true }, { name = "two", done = false } })
    testing.eq(rest, "## Problem\nP\n\n\n## Out of scope\nN")
    items, rest = board.split_checklist("## Done when\n- [ ] only\n")
    testing.eq(#items, 1)
    testing.eq(rest, "")
    testing.eq(board.split_checklist("## Problem\n- [ ] not under the heading\n"), nil)
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
    local out, code = dev_os.capture({ "luajit", "-e", script }, {
        env = {
            PATH = root .. "/bin:" .. os.getenv("PATH"),
            HOME = home,
            ROOT = root,
            WAIT_STATUS = status,
            DEV_PASS_LOCK = root .. "/pass.lock",
        },
        stderr = "stdout",
    })
    testing.eq(code, 0, out)
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

testing.test("wait returns the events oldest first with column names and the cursor", function()
    local root, home = sandbox()
    wait_route(
        root,
        '{"cursor":"9","events":['
            .. '{"cursor":"8","kind":"task_added","task_id":"t1","column_id":"col-ready","at":"x","actor_kind":"user","extra":1},'
            .. '{"cursor":"9","kind":"task_moved","task_id":"t2","column_id":"col-progress","from_column_id":"col-blocked","at":"2026-11-08T10:00:00Z","token_name":null}]}'
    )
    local result = waiting(root, home, "'7', {'task_added', 'task_moved'}, 20")
    testing.eq(result.got, {
        cursor = "9",
        events = {
            {
                kind = "task_added",
                task_id = "t1",
                column = support.COLUMN_NAME.READY,
                actor = "human",
            },
            {
                kind = "task_moved",
                task_id = "t2",
                column = support.COLUMN_NAME.PROGRESS,
                from_column = support.COLUMN_NAME.BLOCKED,
                at = assert(box.parse_time("2026-11-08T10:00:00Z")),
            },
        },
    })
    local calls = read(root, "calls")
    testing.ok(
        calls:find("/events/wait?timeout=20&after=7&kinds=task_added,task_moved", 1, true),
        calls
    )
end)

testing.test("wait returns an empty list and the cursor to send again", function()
    local root, home = sandbox()
    wait_route(root, '{"cursor":"7","events":[]}')
    testing.eq(waiting(root, home, "'7'").got, { cursor = "7", events = {} })
    local calls = read(root, "calls")
    testing.ok(calls:find("/events/wait?timeout=50&after=7\n", 1, true), calls)
end)

testing.test("wait with no cursor sends none", function()
    local root, home = sandbox()
    wait_route(root, '{"cursor":"3","events":[]}')
    testing.eq(waiting(root, home, "nil, nil, 0").got.cursor, "3")
    local calls = read(root, "calls")
    testing.ok(calls:find("/events/wait?timeout=0\n", 1, true), calls)
end)

testing.test("wait returns the oldest cursor of a 410", function()
    local root, home = sandbox()
    wait_route(root, '{"code":"cursor_expired","message":"too old","oldest_cursor":"41"}')
    local result = waiting(root, home, "'1'", "410")
    testing.eq(result.got, nil)
    testing.eq(result.oldest, "41")
    testing.ok(result.message:find("pomb answered 410: too old", 1, true), result.message)
end)

testing.test("wait gives curl a max-time above the wait's timeout", function()
    local root, home = sandbox()
    wait_route(root, '{"cursor":"7","events":[]}')
    waiting(root, home, "'7', nil, 50")
    local calls = read(root, "calls")
    testing.ok(calls:find("--max-time 60 ", 1, true), calls)
    testing.ok(calls:find("--max-time 30 ", 1, true), calls)
end)

testing.test("wait surfaces too_many_waits as a 429 and keeps no cursor", function()
    local root, home = sandbox()
    wait_route(root, '{"code":"too_many_waits","message":"end one"}')
    local result = waiting(root, home, "'7'", "429")
    testing.eq(result.got, nil)
    testing.eq(result.oldest, nil)
    testing.ok(result.message:find("pomb answered 429: end one", 1, true), result.message)
    testing.eq(result.refused, true)
end)

testing.test(
    "wait does not flag a 429 with another code or another status as too many waits",
    function()
        local root, home = sandbox()
        wait_route(root, '{"code":"rate_limited","message":"slow down"}')
        local result = waiting(root, home, "'7'", "429")
        testing.eq(result.refused, nil)
        wait_route(root, '{"code":"too_many_waits","message":"end one"}')
        result = waiting(root, home, "'7'", "503")
        testing.eq(result.refused, nil)
    end
)

local RATE_LIMITED_CURL = [[#!/bin/sh
printf 'curl\n' >>"$ROOT/calls"
cat >/dev/null
n=$(cat "$ROOT/count" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" >"$ROOT/count"
if [ "$n" -le "$LIMITED" ]; then
    printf '%s\nretry-after:%s\n429' "$BODY" "$HINT"
else
    printf '{"name":"x"}\n200'
fi
]]

local function rate_limited(limited, hint, body)
    local root, home = sandbox()
    executable(root .. "/bin/curl", RATE_LIMITED_CURL)
    local script = string.format(
        "package.path = %q; local dev_os = require('dev.os'); local naps = {}; "
            .. "dev_os.nap = function(seconds) naps[#naps + 1] = seconds end; "
            .. "local pomb = require('dev.board.pomb'); local json = require('dev.json'); "
            .. "local b = assert(pomb.new({url = 'https://pomb.example', token = 'pass:secrets/worker/token/pomb', name = 'dotfiles'})); "
            .. "local got, message = b:whoami(); "
            .. "print(json.encode({name = got and got.name, message = message, naps = naps}))",
        support.absolute_path()
    )
    local out, code = dev_os.capture({ "luajit", "-e", script }, {
        env = {
            PATH = root .. "/bin:" .. os.getenv("PATH"),
            HOME = home,
            ROOT = root,
            LIMITED = tostring(limited),
            HINT = hint,
            BODY = body or '{"code":"rate_limited","message":"slow down"}',
            DEV_PASS_LOCK = root .. "/pass.lock",
        },
        stderr = "stdout",
    })
    testing.eq(code, 0, out)
    local result = assert(require("dev.json").decode(out), out)
    result.calls = select(2, read(root, "calls"):gsub("curl\n", ""))
    return result
end

testing.test("a 429 followed by success completes the call after the hinted wait", function()
    local result = rate_limited(1, "2")
    testing.eq(result.name, "x")
    testing.eq(result.naps, { 2 })
    testing.eq(result.calls, 2)
end)

testing.test("a 429 past the retry cap fails with the rate limit message", function()
    local result = rate_limited(9, "1")
    testing.eq(result.name, nil)
    testing.eq(result.message, "board unavailable: pomb answered 429: slow down")
    testing.eq(result.naps, { 1, 1, 1 })
    testing.eq(result.calls, 4)
end)

testing.test(
    "a 429 wait follows the Retry-After hint, then the body hint, then one second",
    function()
        testing.eq(rate_limited(1, "3").naps, { 3 })
        testing.eq(rate_limited(1, "", '{"code":"rate_limited","retry_after":2}').naps, { 2 })
        testing.eq(rate_limited(1, "").naps, { 1 })
    end
)

testing.test("a 429 wait is capped for each try and in total", function()
    local result = rate_limited(9, "99")
    testing.eq(result.naps, { 5, 5 })
    testing.eq(result.calls, 3)
end)

testing.test("a 429 for too many waits is never retried", function()
    local result = rate_limited(9, "1", '{"code":"too_many_waits","message":"end one"}')
    testing.eq(result.naps, {})
    testing.eq(result.calls, 1)
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
    if opts.cards or opts.cards_error or opts.cards_errors then
        function backend:cards()
            local down = opts.cards_errors and table.remove(opts.cards_errors, 1)
            if down then
                return nil, down
            end
            return opts.cards, opts.cards_error
        end
    end
    if opts.comments then
        function backend:comments(id)
            return opts.comments[id] or {}
        end
    end
    function backend:blocked(id)
        if opts.blocked_error then
            return nil, opts.blocked_error
        end
        return (opts.blockers or {})[id] == true
    end
    local path = opts.path or support.tempdir() .. "/wait"
    local result = cmd_board.wait(backend, args, {
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

testing.test(
    "wait --for ready prints the card added to or moved into Ready and ignores the rest",
    function()
        local result, seen, path = waited({
            got("1"),
            got(
                "2",
                { kind = "task_moved", task_id = ID_A, column = support.COLUMN_NAME.PROGRESS }
            ),
            got(
                "3",
                { kind = "task_updated", task_id = ID_A, column = support.COLUMN_NAME.READY },
                { kind = "task_added", task_id = ID_B, column = support.COLUMN_NAME.READY },
                {
                    kind = "task_moved",
                    task_id = ID_C,
                    column = support.COLUMN_NAME.READY,
                    from_column = support.COLUMN_NAME.BACKLOG,
                }
            ),
        }, { "--for", "ready" })
        testing.eq(result.output, "added 11111111 to Ready\nmoved cccccccc to Ready")
        testing.eq(seen.afters, { "none", "1", "2" })
        testing.eq(seen.kinds[1], "task_added,task_moved")
        testing.eq(fs.read(path .. ".ready.cursor"), "3\n")
    end
)

testing.test(
    "wait --for human wakes on the owner's move out of Blocked, not an agent's move or comment",
    function()
        local result, seen = waited({
            got("1"),
            got(
                "2",
                { kind = "comment_added", task_id = ID_A, column = support.COLUMN_NAME.BLOCKED },
                {
                    kind = "task_moved",
                    task_id = ID_B,
                    column = support.COLUMN_NAME.PROGRESS,
                    from_column = support.COLUMN_NAME.READY,
                },
                {
                    kind = "task_moved",
                    task_id = ID_D,
                    column = support.COLUMN_NAME.READY,
                    from_column = support.COLUMN_NAME.BLOCKED,
                    actor = "agent",
                }
            ),
            got("3", {
                kind = "task_moved",
                task_id = ID_C,
                column = support.COLUMN_NAME.READY,
                from_column = support.COLUMN_NAME.BLOCKED,
                actor = "human",
                at = 100,
            }),
            got("4"),
        }, { "--for", "human" }, {
            cards = {
                { id = ID_A, column = support.COLUMN_NAME.BLOCKED, labels = {}, done = false },
            },
            comments = {
                [ID_A] = { { actor = "agent", at = "2026-11-02T10:00:00Z", body = "wait" } },
            },
        })
        testing.eq(result.output, "moved cccccccc out of Blocked")
        testing.eq(seen.kinds[1], "task_moved,comment_added")
    end
)

testing.test("wait --for human wakes on the owner's comment newer than its start", function()
    local started = assert(box.parse_time("2026-11-02T09:00:00Z"))
    local cards = {
        { id = ID_A, column = support.COLUMN_NAME.READY, labels = {}, done = false },
        { id = ID_B, column = support.COLUMN_NAME.READY, labels = {}, done = false },
        { id = ID_C, column = support.COLUMN_NAME.REVIEW, labels = {}, done = false },
        { id = ID_D, column = support.COLUMN_NAME.DONE, labels = {}, done = true },
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
            { kind = "comment_added", task_id = ID_A, column = support.COLUMN_NAME.READY },
            { kind = "comment_added", task_id = ID_C, column = support.COLUMN_NAME.REVIEW },
            { kind = "comment_added", task_id = ID_D, column = support.COLUMN_NAME.DONE }
        ),
        got("3", { kind = "comment_added", task_id = ID_B, column = support.COLUMN_NAME.READY }),
        got("4"),
    }, { "--for", "human" }, {
        cards = cards,
        comments = replies,
        now = started,
    })
    testing.eq(result.output, "the owner commented on 11111111")
    testing.eq(seen.kinds[1], "task_moved,comment_added")
    testing.eq(seen.afters, { "none", "1", "2", "3" })
end)

testing.test("wait --for human settles for 60 seconds and prints one line per card", function()
    local started = assert(box.parse_time("2026-11-02T09:00:00Z"))
    local at = "2026-11-02T10:00:00Z"
    local cards = {
        { id = ID_A, column = support.COLUMN_NAME.READY, labels = {}, done = false },
        { id = ID_B, column = support.COLUMN_NAME.BLOCKED, labels = {}, done = false },
        { id = ID_C, column = support.COLUMN_NAME.BLOCKED, labels = {}, done = false },
    }
    local replies = {
        [ID_A] = { { actor = "human", at = at, body = "1" } },
        [ID_C] = { { actor = "agent", at = at, body = "q" } },
    }
    local result, seen = waited({
        got("1"),
        got("2", { kind = "comment_added", task_id = ID_A, column = support.COLUMN_NAME.READY }),
        got("3", { kind = "comment_added", task_id = ID_A, column = support.COLUMN_NAME.READY }, {
            kind = "task_moved",
            task_id = ID_B,
            column = support.COLUMN_NAME.READY,
            from_column = support.COLUMN_NAME.BLOCKED,
            actor = "human",
            at = started + 7200,
        }, { kind = "comment_added", task_id = ID_C, column = support.COLUMN_NAME.BLOCKED }),
        got("4"),
    }, { "--for", "human" }, { cards = cards, comments = replies, now = started })
    testing.eq(result.output, "the owner commented on 11111111\nmoved 11111111 out of Blocked")
    testing.eq(seen.afters, { "none", "1", "2", "3" })
    testing.eq(seen.timeouts, { "default", "default", 60, 60 })
end)

testing.test("wait --for human prints the lines it holds when the cursor is trimmed", function()
    local cards = { { id = ID_A, column = support.COLUMN_NAME.BLOCKED, labels = {}, done = false } }
    local result = waited({
        got("1"),
        got("2", {
            kind = "task_moved",
            task_id = ID_A,
            column = support.COLUMN_NAME.READY,
            from_column = support.COLUMN_NAME.BLOCKED,
            actor = "human",
            at = 100,
        }),
        { oldest = "9" },
    }, { "--for", "human" }, { cards = cards })
    testing.eq(result.output, "moved 11111111 out of Blocked")
end)

testing.test("wait --for human ignores a human move older than the wait's start", function()
    local cards = { { id = ID_A, column = board.DEFAULT_NAMES.blocked, labels = {}, done = false } }
    local result = waited({
        got("1", {
            kind = "task_moved",
            task_id = ID_A,
            column = support.COLUMN_NAME.READY,
            from_column = board.DEFAULT_NAMES.blocked,
            actor = "human",
            at = 99,
        }),
        got("2", {
            kind = "task_moved",
            task_id = ID_C,
            column = support.COLUMN_NAME.READY,
            from_column = board.DEFAULT_NAMES.blocked,
            actor = "human",
            at = 101,
        }),
        got("3"),
    }, { "--for", "human" }, { cards = cards, now = 100 })
    testing.eq(result.output, "moved cccccccc out of " .. board.DEFAULT_NAMES.blocked)
end)

testing.test("wait --for human keeps waiting on a trimmed stream with no moved card", function()
    local cards = {
        { id = ID_A, column = board.DEFAULT_NAMES.blocked, labels = {}, done = false },
        { id = ID_B, column = board.DEFAULT_NAMES.icebox, labels = {}, done = false },
    }
    local result, seen, path = waited({
        { oldest = "9" },
        got("10", {
            kind = "task_moved",
            task_id = ID_C,
            column = support.COLUMN_NAME.READY,
            from_column = board.DEFAULT_NAMES.blocked,
        }),
        got("11"),
        { oldest = "20" },
        { message = "stop" },
    }, { "--for", "human" }, { cards = cards })
    testing.eq(result.message, "stop")
    testing.eq(seen.afters, { "none", "9", "10", "11", "20" })
    testing.eq(fs.read(path .. ".human.cursor"), "20\n")
end)

testing.test("wait --for human names the card that left Blocked on a trimmed stream", function()
    local before =
        { { id = ID_A, column = board.DEFAULT_NAMES.blocked, labels = {}, done = false } }
    local after = { { id = ID_A, column = support.COLUMN_NAME.READY, labels = {}, done = false } }
    local reads = 0
    local replies = { { oldest = "9" } }
    local backend, seen = waiter(replies)
    function backend:cards()
        reads = reads + 1
        return reads == 1 and before or after
    end
    local path = support.tempdir() .. "/wait"
    local result = cmd_board.wait(backend, { "--for", "human" }, {
        stem = path,
        nap = function() end,
        random = function()
            return 0
        end,
        now = function()
            return 0
        end,
        notice = function() end,
    })
    testing.eq(result.output, "moved 11111111 out of " .. board.DEFAULT_NAMES.blocked)
    testing.eq(seen.afters, { "none" })
    testing.eq(fs.read(path .. ".human.cursor"), "9\n")
end)

local function trimmed_wait(before, after)
    local reads = 0
    local backend = waiter({ { oldest = "9" } })
    function backend:cards()
        reads = reads + 1
        return reads == 1 and before or after
    end
    return cmd_board.wait(backend, { "--for", "human" }, {
        stem = support.tempdir() .. "/wait",
        nap = function() end,
        random = function()
            return 0
        end,
        now = function()
            return 0
        end,
        notice = function() end,
    })
end

testing.test("wait --for human counts a human move in the second the wait started", function()
    local cards = { { id = ID_A, column = board.DEFAULT_NAMES.blocked, labels = {}, done = false } }
    local result = waited({
        got("1", {
            kind = "task_moved",
            task_id = ID_A,
            column = support.COLUMN_NAME.READY,
            from_column = board.DEFAULT_NAMES.blocked,
            actor = "human",
            at = 100,
        }),
        got("2"),
    }, { "--for", "human" }, { cards = cards, now = 100 })
    testing.eq(result.output, "moved 11111111 out of " .. board.DEFAULT_NAMES.blocked)
end)

testing.test("wait --for human reports a Blocked card that vanished on a trimmed stream", function()
    local sat = { { id = ID_A, column = board.DEFAULT_NAMES.blocked, labels = {}, done = false } }
    local result = trimmed_wait(sat, {})
    testing.eq(result.output, "moved 11111111 out of " .. board.DEFAULT_NAMES.blocked)
end)

testing.test("wait --for human reports an Icebox card that left on a trimmed stream", function()
    local before = { { id = ID_B, column = board.DEFAULT_NAMES.icebox, labels = {}, done = false } }
    local after = { { id = ID_B, column = support.COLUMN_NAME.READY, labels = {}, done = false } }
    local result = trimmed_wait(before, after)
    testing.eq(result.output, "moved 11111111 out of " .. board.DEFAULT_NAMES.icebox)
end)

testing.test("wait --for lead wakes once on a needs:lead card in Blocked", function()
    local cards = {
        { id = ID_A, column = support.COLUMN_NAME.BLOCKED, labels = { "needs:lead" } },
        {
            id = ID_B,
            column = support.COLUMN_NAME.BLOCKED,
            labels = { "needs:lead", "needs:human" },
        },
        { id = ID_C, column = support.COLUMN_NAME.READY, labels = { "needs:lead" } },
        {
            id = ID_D,
            column = support.COLUMN_NAME.BLOCKED,
            labels = { "needs:lead" },
            claimant = "x",
        },
    }
    local result, seen, path = waited({
        got("1"),
        got(
            "2",
            { kind = "task_moved", task_id = ID_C, column = support.COLUMN_NAME.READY },
            { kind = "task_added", task_id = ID_B, column = support.COLUMN_NAME.BLOCKED },
            { kind = "task_updated", task_id = ID_D, column = support.COLUMN_NAME.BLOCKED }
        ),
        got(
            "3",
            { kind = "task_updated", task_id = ID_A, column = support.COLUMN_NAME.BLOCKED },
            { kind = "task_added", task_id = ID_A, column = support.COLUMN_NAME.BLOCKED }
        ),
    }, { "--for", "lead" }, { cards = cards })
    testing.eq(result.output, "11111111 is labelled needs:lead in Blocked")
    testing.eq(seen.kinds[1], "task_added,task_moved,task_updated")
    testing.eq(fs.read(path .. ".lead.cursor"), "3\n")
end)

testing.test("wait --for lead skips a run card and a card an open card blocks", function()
    local cards = {
        {
            id = ID_A,
            column = support.COLUMN_NAME.BLOCKED,
            labels = { board.NEEDS_LEAD, board.RUN },
        },
        { id = ID_B, column = support.COLUMN_NAME.BLOCKED, labels = { board.NEEDS_LEAD } },
        { id = ID_C, column = support.COLUMN_NAME.BLOCKED, labels = { board.NEEDS_LEAD } },
    }
    local result = waited({
        got("1"),
        got(
            "2",
            { kind = "task_added", task_id = ID_A, column = support.COLUMN_NAME.BLOCKED },
            { kind = "task_added", task_id = ID_B, column = support.COLUMN_NAME.BLOCKED }
        ),
        got("3", { kind = "task_added", task_id = ID_C, column = support.COLUMN_NAME.BLOCKED }),
    }, { "--for", "lead" }, { cards = cards, blockers = { [ID_B] = true } })
    testing.eq(result.output, "cccccccc is labelled needs:lead in Blocked")
end)

testing.test("wait --for lead fails and keeps the cursor on unreadable blockers", function()
    local cards = {
        { id = ID_A, column = support.COLUMN_NAME.BLOCKED, labels = { board.NEEDS_LEAD } },
    }
    local result, _, path = waited({
        got("1"),
        got("2", { kind = "task_added", task_id = ID_A, column = support.COLUMN_NAME.BLOCKED }),
    }, { "--for", "lead" }, { cards = cards, blocked_error = "bad links" })
    testing.eq(result.code, 1)
    testing.eq(fs.read(path .. ".lead.cursor"), "1\n")
end)

testing.test("wait --for planner wakes once on a needs:planner card in Blocked", function()
    local cards = {
        { id = ID_A, column = support.COLUMN_NAME.BLOCKED, labels = { "needs:planner" } },
        { id = ID_B, column = support.COLUMN_NAME.BLOCKED, labels = { "needs:lead" } },
        {
            id = ID_C,
            column = support.COLUMN_NAME.BLOCKED,
            labels = { "needs:planner", "needs:human" },
        },
    }
    local result, seen, path = waited({
        got("1"),
        got(
            "2",
            { kind = "task_added", task_id = ID_B, column = support.COLUMN_NAME.BLOCKED },
            { kind = "task_updated", task_id = ID_C, column = support.COLUMN_NAME.BLOCKED }
        ),
        got("3", { kind = "task_updated", task_id = ID_A, column = support.COLUMN_NAME.BLOCKED }),
    }, { "--for", "planner" }, { cards = cards })
    testing.eq(result.output, "11111111 is labelled needs:planner in Blocked")
    testing.eq(seen.kinds[1], "task_added,task_moved,task_updated")
    testing.eq(fs.read(path .. ".planner.cursor"), "3\n")
end)

for _, stage in ipairs({
    support.COLUMN_NAME.REVIEW,
    support.COLUMN_NAME.VERIFY,
    support.COLUMN_NAME.RELEASE,
}) do
    testing.test(
        "wait --for " .. stage:lower() .. " prints the unclaimed card that reached " .. stage,
        function()
            local cards = {
                { id = ID_A, column = stage },
                { id = ID_B, column = stage, claimant = "x" },
                { id = ID_C, column = support.COLUMN_NAME.READY },
            }
            local result, seen, path = waited({
                got("1"),
                got(
                    "2",
                    { kind = "task_moved", task_id = ID_B, column = stage },
                    { kind = "task_moved", task_id = ID_C, column = support.COLUMN_NAME.READY }
                ),
                got("3", { kind = "task_moved", task_id = ID_A, column = stage }),
            }, { "--for", stage:lower() }, { cards = cards })
            testing.eq(result.output, "moved 11111111 to " .. stage)
            testing.eq(seen.kinds[1], "task_added,task_moved")
            testing.eq(fs.read(path .. "." .. stage:lower() .. ".cursor"), "3\n")
        end
    )
end

testing.test("wait refuses a --for that names no stage", function()
    local result = waited({}, { "--for", "verifier" })
    testing.eq(result.code, 2)
end)

testing.test("wait --for lead leaves the cursor alone when the board cannot be read", function()
    local result, _, path = waited({
        got("1"),
        got("2", { kind = "task_added", task_id = ID_A, column = support.COLUMN_NAME.BLOCKED }),
    }, { "--for", "lead" }, { cards_error = "pomb is down" })
    testing.eq(result.code, 1)
    testing.eq(fs.read(path .. ".lead.cursor"), "1\n")
end)

local DOWN = "board unavailable: cannot reach https://p (curl exit 7)"

local function lead_added()
    return got("2", { kind = "task_added", task_id = ID_A, column = support.COLUMN_NAME.BLOCKED })
end

local function lead_board()
    return { { id = ID_A, column = support.COLUMN_NAME.BLOCKED, labels = { "needs:lead" } } }
end

testing.test("wait --for lead retries an unreachable board read", function()
    local result, seen = waited(
        { got("1"), lead_added(), lead_added() },
        { "--for", "lead" },
        { cards = lead_board(), cards_errors = { DOWN } }
    )
    testing.eq(result.output, "11111111 is labelled needs:lead in Blocked")
    testing.eq(seen.naps, { 30 })
end)

testing.test(
    "wait --for lead asks again from the same cursor after an unreachable board read",
    function()
        local result, seen, path = waited(
            { got("1"), lead_added(), lead_added() },
            { "--for", "lead" },
            { cards = lead_board(), cards_errors = { DOWN } }
        )
        testing.eq(result.code, nil)
        testing.eq(seen.afters, { "none", "1", "1" })
        testing.eq(fs.read(path .. ".lead.cursor"), "2\n")
    end
)

testing.test(
    "wait --for lead gives up after ten unreachable board reads and keeps the cursor",
    function()
        local replies = { got("1") }
        local errors = {}
        for i = 1, 10 do
            replies[#replies + 1] = lead_added()
            errors[i] = DOWN
        end
        local result, seen, path = waited(replies, { "--for", "lead" }, { cards_errors = errors })
        testing.eq(result.code, 1)
        testing.ok(result.message:find("curl exit 7", 1, true), result.message)
        testing.eq(#seen.naps, 9)
        testing.eq(fs.read(path .. ".lead.cursor"), "1\n")
    end
)

local function comment_added()
    return got("2", { kind = "comment_added", task_id = ID_A, column = support.COLUMN_NAME.READY })
end

local function human_board()
    return { { id = ID_A, column = support.COLUMN_NAME.READY, labels = {}, done = false } }
end

testing.test("wait --for human retries an unreachable comment read", function()
    local started = assert(box.parse_time("2026-11-02T09:00:00Z"))
    local result, seen = waited({
        got("1"),
        comment_added(),
        comment_added(),
        got("3"),
    }, { "--for", "human" }, {
        cards = human_board(),
        cards_errors = { false, DOWN },
        comments = { [ID_A] = { { actor = "human", at = "2026-11-02T10:00:00Z", body = "1" } } },
        now = started,
    })
    testing.eq(result.output, "the owner commented on 11111111")
    testing.eq(seen.naps, { 30 })
    testing.eq(seen.afters, { "none", "1", "1", "2" })
end)

testing.test(
    "wait --for human gives up after ten unreachable comment reads and keeps the cursor",
    function()
        local replies = { got("1") }
        local errors = { false }
        for _ = 1, 10 do
            replies[#replies + 1] = comment_added()
            errors[#errors + 1] = DOWN
        end
        local result, seen, path = waited(replies, { "--for", "human" }, {
            cards = human_board(),
            cards_errors = errors,
        })
        testing.eq(result.code, 1)
        testing.ok(result.message:find("curl exit 7", 1, true), result.message)
        testing.eq(#seen.naps, 9)
        testing.eq(fs.read(path .. ".human.cursor"), "1\n")
    end
)

testing.test("wait without --for matches every kind", function()
    local result, seen = waited({
        got("1", { kind = "comment_added", task_id = ID_A, column = support.COLUMN_NAME.READY }),
    }, {})
    testing.eq(result.output, "commented on 11111111")
    testing.eq(seen.kinds[1], "task_added,task_moved,task_updated,comment_added")
end)

testing.test("wait resumes from the stored cursor", function()
    local path = support.tempdir() .. "/wait"
    assert(fs.write(path .. ".ready.cursor", "41\n"))
    local result, seen = waited({
        got("42", { kind = "task_added", task_id = ID_A, column = support.COLUMN_NAME.READY }),
    }, { "--for", "ready" }, { path = path })
    testing.eq(result.output, "added 11111111 to Ready")
    testing.eq(seen.afters, { "41" })
    testing.eq(fs.read(path .. ".ready.cursor"), "42\n")
    local _, other = waited({
        got("9"),
        got("10", {
            kind = "task_moved",
            task_id = ID_A,
            column = support.COLUMN_NAME.READY,
            from_column = support.COLUMN_NAME.BLOCKED,
            actor = "human",
            at = 100,
        }),
        got("11"),
    }, { "--for", "human" }, { path = path, cards = {} })
    testing.eq(other.afters, { "none", "9", "10" })
end)

testing.test(
    "wait stores the oldest cursor of an expired one and says events were trimmed",
    function()
        local result, _, path = waited({
            { message = "board unavailable: pomb answered 410: too old", oldest = "17" },
        }, { "--for", "ready" })
        testing.eq(result.output, "events were trimmed, check the board")
        testing.eq(result.message, nil)
        testing.eq(fs.read(path .. ".ready.cursor"), "17\n")
    end
)

testing.test("wait retries Pomb being unreachable, then gives up after ten in a row", function()
    local result, seen = waited({
        { message = "board unavailable: cannot reach https://p (curl exit 7)" },
        got("5", { kind = "task_added", task_id = ID_A, column = support.COLUMN_NAME.READY }),
    }, { "--for", "ready" })
    testing.eq(result.output, "added 11111111 to Ready")
    testing.eq(seen.naps, { 30 })
    local down = {}
    for i = 1, 10 do
        down[i] = { message = "board unavailable: cannot reach https://p (curl exit 6)" }
    end
    result, seen = waited(down, {})
    testing.ok(result.message:find("curl exit 6", 1, true), result.message)
    testing.eq(#seen.naps, 9)
end)

local function limited()
    return { message = "board unavailable: pomb answered 429: end one", refused = true }
end

testing.test(
    "wait keeps waiting through too many open waits, with a pause that grows to 5 minutes",
    function()
        local replies = {}
        for i = 1, 14 do
            replies[i] = limited()
        end
        replies[15] =
            got("5", { kind = "task_added", task_id = ID_A, column = support.COLUMN_NAME.READY })
        local result, seen = waited(replies, { "--for", "ready" })
        testing.eq(result.output, "added 11111111 to Ready")
        testing.eq(
            seen.naps,
            { 30, 60, 120, 240, 300, 300, 300, 300, 300, 300, 300, 300, 300, 300 }
        )
    end
)

testing.test("wait spreads the pause with the random source and never passes the step", function()
    local backend =
        waiter({ limited(), limited(), got("5", { kind = "task_updated", task_id = ID_A }) })
    local naps = {}
    local fractions = { 0, 1 }
    cmd_board.wait(backend, {}, {
        stem = support.tempdir() .. "/wait",
        nap = function(seconds)
            naps[#naps + 1] = seconds
        end,
        random = function()
            return table.remove(fractions, 1)
        end,
        notice = function() end,
    })
    testing.eq(naps, { 30, 45 })
end)

testing.test("wait reports too many open waits once", function()
    local result, seen = waited({
        limited(),
        limited(),
        got("5", { kind = "task_updated", task_id = ID_A }),
    }, {})
    testing.eq(result.output, "updated 11111111")
    testing.eq(#seen.notices, 1)
    testing.ok(seen.notices[1]:find("too many open waits", 1, true), seen.notices[1])
    testing.eq(seen.naps, { 30, 60 })
end)

testing.test("wait does not count too many open waits toward the ten failures", function()
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
    testing.eq(result.output, "updated 11111111")
end)

testing.test("wait treats a 429 without the too_many_waits flag as a plain refusal", function()
    local result, seen = waited({
        { message = "board unavailable: pomb answered 429: slow down" },
    }, {})
    testing.eq(result.code, 1)
    testing.eq(#seen.naps, 0)
end)

testing.test("wait fails at once on a refusal", function()
    local result, seen = waited({
        { message = "board unavailable: pomb answered 401: bad token" },
    }, {})
    testing.eq(result.code, 1)
    testing.eq(#seen.naps, 0)
end)

testing.test("wait rejects an unknown --for value and a card", function()
    local result = waited({}, { "--for", "everyone" })
    testing.eq(result.code, 2)
    testing.ok(result.message:find("release, human, lead and planner", 1, true), result.message)
    testing.eq(waited({}, { "abc" }).code, 2)
end)

testing.test("delete needs a card and a reason", function()
    local backend = fake(sample())
    for _, args in ipairs({
        {},
        { "cccccccc" },
        { "cccccccc", "--reason", " " },
        { "--reason", "x" },
    }) do
        local result = cmd_board.run("delete", args, backend)
        testing.eq(result.code, 2)
        testing.eq(result.message, "needs a card and --reason TEXT")
    end
    testing.eq(backend.calls, {})
end)

testing.test(
    "delete notes the reason, then moves the card to the bin with the lead token",
    function()
        local root, home = sandbox({ user = LEAD_USER })
        local out, code =
            dev(root, home, { "board", "delete", "11111111-a", "--reason", "duplicate" })
        testing.eq(code, 0, out)
        testing.eq(out, "moved 11111111 to the bin\n")
        local calls = read(root, "calls")
        local noted = calls:find("-X POST", 1, true)
        local binned = calls:find("-X DELETE", 1, true)
        testing.ok(noted and binned and noted < binned, calls)
        testing.ok(calls:find("/api/tasks/" .. ID_A .. "/comments", 1, true), calls)
        testing.ok(calls:find("/api/tasks/" .. ID_A .. "\n", 1, true), calls)
        testing.ok(calls:find("pass show secrets/lead/token/pomb", 1, true), calls)
        testing.eq(calls:find("pass show secrets/worker", 1, true), nil)
        testing.ok(calls:find("the lead deletes this card, reason: duplicate", 1, true), calls)
    end
)

testing.test(
    "delete-lead-role deletes a card for a DEV_AGENT whose role segment is lead",
    function()
        local root, home = sandbox({ user = LEAD_USER })
        local out, code = dev(
            root,
            home,
            { "board", "delete", "11111111-a", "--reason", "duplicate" },
            { agent = "dotfiles/lead/82f0e002/1" }
        )
        testing.eq(code, 0, out)
        testing.eq(out, "moved 11111111 to the bin\n")
        testing.ok(read(root, "calls"):find("-X DELETE", 1, true), read(root, "calls"))
    end
)

testing.test("delete-runner-role refuses a runner name, with no call and no token read", function()
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
        testing.eq(code, 1, out)
        testing.ok(out:find("Only the lead deletes a card", 1, true), out)
        testing.ok(out:find(name, 1, true), out)
        testing.eq(read(root, "calls"), "")
    end
end)

testing.test("lead-name-helper counts a name with no slash or a lead role as the lead", function()
    testing.eq(guards.is_lead(""), true)
    testing.eq(guards.is_lead("project-lead"), true)
    testing.eq(guards.is_lead("dotfiles/lead/82f0e002/1"), true)
    testing.eq(guards.is_lead("dotfiles/lead"), true)
    testing.eq(guards.is_lead("dotfiles/implementer/82f0e002/1"), false)
    testing.eq(guards.is_lead("dotfiles/leader/82f0e002/1"), false)
    testing.eq(guards.is_lead("lead/implementer/82f0e002/1"), false)
    testing.eq(guards.is_lead("project-run/pombbin"), false)
end)

testing.test("delete without a lead token or on a local board does nothing", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "delete", "11111111-a", "--reason", "x" })
    testing.eq(code, 1, out)
    testing.ok(out:find("`lead_token` setting of `[board.pomb]` is not set", 1, true), out)
    testing.eq(read(root, "calls"), "")
    root, home = sandbox({ project = '[board]\nbackend = "local"\nname = "scratch"\n' })
    out, code = dev(root, home, { "board", "delete", "11111111-a", "--reason", "x" })
    testing.eq(code, 1, out)
    testing.ok(out:find("keeps no recycle bin", 1, true), out)
end)

testing.test("delete shows Pomb's permission_denied and card_locked as they come", function()
    local root, home = sandbox({ user = LEAD_USER })
    assert(
        fs.write(
            root .. "/delete_body",
            '{"code":"permission_denied","permission":"tasks.bin","message":"m","board_id":null}'
        )
    )
    local out, code = dev(root, home, { "board", "delete", "11111111-a", "--reason", "x" })
    testing.eq(code, 1, out)
    testing.ok(out:find("tasks.bin", 1, true), out)
    root, home = sandbox({ user = LEAD_USER })
    assert(fs.write(root .. "/locked", ""))
    out, code = dev(root, home, { "board", "delete", "11111111-a", "--reason", "x" })
    testing.eq(code, 1, out)
    testing.ok(out:find("labelled needs:human", 1, true), out)
    testing.eq(read(root, "calls"):find("-X DELETE", 1, true), nil)
end)

local ISSUED = "pomb_ISSUEDrole0123456789"

local function issued_dev(root, home, token)
    return dev(root, home, { "board", "ls" }, { env = { DEV_BOARD_TOKEN = token } })
end

testing.test(
    "DEV_BOARD_TOKEN is sent as the bearer token and pass and the Keychain are never read",
    function()
        local root, home = sandbox()
        with_security(root)
        local out, code = issued_dev(root, home, ISSUED)
        testing.eq(code, 0, out)
        testing.ok(read(root, "stdin"):find("Bearer " .. ISSUED, 1, true), read(root, "stdin"))
        testing.eq(occurrences(read(root, "calls"), "pass show"), 0)
        testing.eq(read(root, "seccalls"), "")
    end
)

testing.test("DEV_BOARD_TOKEN unset or empty reads pass as before", function()
    local root, home = sandbox()
    local out, code = issued_dev(root, home, "")
    testing.eq(code, 0, out)
    testing.eq(occurrences(read(root, "calls"), "pass show"), 1)
    testing.ok(read(root, "stdin"):find("Bearer " .. TOKEN, 1, true), read(root, "stdin"))
    root, home = sandbox()
    out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 0, out)
    testing.eq(occurrences(read(root, "calls"), "pass show"), 1)
end)

testing.test(
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
        testing.eq(code, 1)
        testing.ok(out:find("issued token", 1, true), out)
        testing.eq(occurrences(read(root, "calls"), "pass show"), 0)
    end
)

testing.test("DEV_BOARD_TOKEN never reaches the output, the arguments or the log", function()
    local root, home = sandbox()
    local out = issued_dev(root, home, ISSUED)
    testing.eq(out:find(ISSUED, 1, true), nil, out)
    testing.eq(read(root, "calls"):find(ISSUED, 1, true), nil)
    executable(root .. "/bin/curl", '#!/bin/sh\ncat >/dev/null\nprintf \'{"message":"bad"}\\n401\'')
    out = issued_dev(root, home, ISSUED)
    testing.eq(out:find(ISSUED, 1, true), nil, out)
    testing.eq(read(root, "calls"):find(ISSUED, 1, true), nil)
end)

testing.test(
    "the keep-alive loop under DEV_BOARD_TOKEN sends that token and never reads pass",
    function()
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
                .. "/state card 7 1 https://pomb.example Agents/x 0 dotfiles/x 900",
            "600"
        )
        testing.ok(read(root, "stdin"):find("Bearer " .. ISSUED, 1, true), read(root, "stdin"))
        testing.eq(occurrences(read(root, "calls"), "pass show"), 0)
    end
)

testing.test(
    "move to review on a board with In Review and no Review names dev board init",
    function()
        local backend = fake({ planned() })
        backend.limited = { "In Review" }
        local result = cmd_board.run("move", { "cccccccc", support.COLUMN.REVIEW }, backend)
        testing.eq(result.code, 1)
        testing.ok(
            result.message:find(
                "Run `dev board init` to move the board to the stage columns.",
                1,
                true
            ),
            result.message
        )
        testing.ok(result.message:find("no Review column", 1, true), result.message)
        result = cmd_board.run("move", { "cccccccc", "In Review" }, backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("Run `dev board init` to move", 1, true), result.message)
    end
)

testing.test("move to review keeps the plain refusal on a board without In Review", function()
    local backend = fake({ planned() })
    local result = cmd_board.run("move", { "cccccccc", "In Review" }, backend)
    testing.eq(result.code, 2)
    testing.ok(result.message:find("unknown column In Review", 1, true), result.message)
end)

testing.test("wait on a board with In Review and no Review names dev board init", function()
    local backend = waiter({})
    backend.rows = {
        { name = "In Review", is_done = false },
        { name = support.COLUMN_NAME.DONE, is_done = true },
    }
    local result = cmd_board.wait(backend, {}, { stem = support.tempdir() .. "/wait" })
    testing.eq(result.code, 1)
    testing.ok(
        result.message:find("Run `dev board init` to move the board to the stage columns.", 1, true),
        result.message
    )
end)

local ATTACHED = '[{"id":"abcdef12-0000-4000-8000-000000000001","name":"old.png","size":2048,'
    .. '"mime":"image/png","file_url":"/f"}]'

local function attach_files(root)
    local dir = support.tempdir()
    assert(fs.write(dir .. "/old.png", "x"))
    assert(fs.write(dir .. "/new.png", "y"))
    assert(fs.write(root .. "/attachments.json", ATTACHED))
    assert(
        fs.write(
            root .. "/upload.json",
            '{"results":[{"name":"new.png","attachment":{"id":"99887766-0000-4000-8000-000000000002",'
                .. '"name":"new.png","size":1}}]}'
        )
    )
    return dir
end

testing.test("attach uploads a new file once and skips a name the card already holds", function()
    local root, home = sandbox()
    local dir = attach_files(root)
    local out, code =
        dev(root, home, { "board", "attach", "11111111-a", dir .. "/new.png", dir .. "/old.png" })
    testing.eq(code, 0, out)
    testing.eq(out, "attached 99887766 new.png\nskipped old.png\n")
    local calls = read(root, "calls")
    testing.ok(calls:find("-X POST", 1, true), calls)
    testing.ok(calls:find("/api/tasks/" .. ID_A .. "/attachments", 1, true), calls)
    testing.ok(calls:find('-F file=@"' .. dir .. '/new.png"', 1, true), calls)
    testing.ok(not calls:find('old.png"', 1, true), calls)
    testing.ok(not calls:find("Content-Type: application/json -w", 1, true), calls)
    testing.ok(not read(root, "calls"):find(TOKEN, 1, true), "token in argv")
end)

testing.test("attach prints Pomb's refusal as Pomb words it and checks no size or type", function()
    local root, home = sandbox()
    local dir = attach_files(root)
    assert(
        fs.write(
            root .. "/upload.json",
            '{"results":[{"name":"new.png","error":{"code":"quota_exceeded","message":"the task holds its most attachments"}}]}'
        )
    )
    local out, code = dev(root, home, { "board", "attach", "11111111-a", dir .. "/new.png" })
    testing.eq(code, 1)
    testing.ok(out:find("new.png: the task holds its most attachments", 1, true), out)
end)

testing.test("attach keeps uploading the other files after Pomb refuses one", function()
    local root, home = sandbox()
    local dir = attach_files(root)
    assert(
        fs.write(
            root .. "/upload_1.json",
            '{"results":[{"name":"new.png","error":{"code":"duplicate_attachment","message":"same bytes"}}]}'
        )
    )
    assert(fs.write(dir .. "/third.png", "z"))
    assert(
        fs.write(
            root .. "/upload.json",
            '{"results":[{"name":"third.png","attachment":{"id":"55443322-0000-4000-8000-000000000003",'
                .. '"name":"third.png","size":1}}]}'
        )
    )
    local out, code =
        dev(root, home, { "board", "attach", "11111111-a", dir .. "/new.png", dir .. "/third.png" })
    testing.eq(code, 1)
    testing.ok(out:find("new.png: same bytes\nattached 55443322 third.png", 1, true), out)
    testing.eq(fs.read(root .. "/post_n"), "2\n")
end)

testing.test("attach retries a busy answer after a nap and then uploads", function()
    local root, home = sandbox()
    local dir = attach_files(root)
    assert(fs.write(root .. "/busy", "1"))
    local out, code = dev(root, home, { "board", "attach", "11111111-a", dir .. "/new.png" })
    testing.eq(code, 0, out)
    testing.eq(out, "attached 99887766 new.png\n")
    testing.eq(fs.read(root .. "/post_n"), "2\n")
end)

testing.test("attach gives up on a busy answer that stays", function()
    local root, home = sandbox()
    local dir = attach_files(root)
    assert(fs.write(root .. "/busy", "9"))
    local out, code = dev(root, home, { "board", "attach", "11111111-a", dir .. "/new.png" })
    testing.eq(code, 1)
    testing.ok(out:find("pomb answered 503", 1, true), out)
    testing.eq(fs.read(root .. "/post_n"), "3\n")
end)

testing.test("attachments lists id prefix, size and name, or says there are none", function()
    local root, home = sandbox()
    attach_files(root)
    local out, code = dev(root, home, { "board", "attachments", "11111111-a" })
    testing.eq(code, 0, out)
    testing.eq(out, "abcdef12  2048  old.png\n")
    assert(fs.write(root .. "/attachments.json", "[]"))
    out = dev(root, home, { "board", "attachments", "11111111-a" })
    testing.eq(out, "No attachments.\n")
end)

testing.test(
    "detach removes an attachment by id prefix and reports a missing permission",
    function()
        local root, home = sandbox()
        attach_files(root)
        local out, code = dev(root, home, { "board", "detach", "11111111-a", "abcd" })
        testing.eq(code, 0, out)
        testing.eq(out, "detached abcdef12 old.png\n")
        local calls = read(root, "calls")
        testing.ok(calls:find("-X DELETE", 1, true), calls)
        testing.ok(
            calls:find(
                "/api/tasks/" .. ID_A .. "/attachments/abcdef12-0000-4000-8000-000000000001",
                1,
                true
            ),
            calls
        )
        assert(
            fs.write(
                root .. "/detach_body",
                '{"code":"permission_denied","permission":"attachments.delete","message":"no"}'
            )
        )
        out, code = dev(root, home, { "board", "detach", "11111111-a", "abcd" })
        testing.eq(code, 1)
        testing.ok(out:find("lacks the attachments.delete permission", 1, true), out)
        out, code = dev(root, home, { "board", "detach", "11111111-a", "ffff" })
        testing.eq(code, 1)
        testing.ok(out:find("holds no attachment with the id ffff.", 1, true), out)
    end
)

local PLAIN_ADD =
    { "--problem", "x", "--change", "x", "--out-of-scope", "y", "--size", "1", "--done-when", "a" }

local function add_args(name, extra)
    local args = { "board", "add", name }
    for _, word in ipairs(PLAIN_ADD) do
        args[#args + 1] = word
    end
    for _, word in ipairs(extra or {}) do
        args[#args + 1] = word
    end
    return args
end

local function local_cards()
    local root, home = sandbox({ project = '[board]\nbackend = "local"\nname = "mine"\n' })
    local out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)
    local ids = {}
    for _, name in ipairs({ "One", "Two", "Three" }) do
        ids[name] = dev(root, home, add_args(name, { "--id-only" })):gsub("%s+$", "")
    end
    return root, home, ids
end

local function backlog_names(root, home)
    local names = {}
    for line in
        dev(root, home, { "board", "ls", "--column", support.COLUMN.BACKLOG }):gmatch("[^\n]+")
    do
        names[#names + 1] = line:match("(%S+)$")
    end
    return names
end

local function pomb_placed(extra)
    local root, home = sandbox()
    local args = {
        "board",
        "add",
        "New",
        "--column",
        support.COLUMN.READY,
        "--size",
        "1",
        "--description",
        V2,
        "--checks",
        "dev test",
        "--done-when",
        "a " .. board.JUDGEMENT,
        "--done-when",
        "b " .. board.JUDGEMENT,
        "--done-when",
        "c " .. board.JUDGEMENT,
    }
    for _, word in ipairs(extra) do
        args[#args + 1] = word
    end
    local out, code = dev(root, home, args)
    return out, code, read(root, "calls")
end

testing.test("add --top places the card first", function()
    local root, home = local_cards()
    local out, code = dev(root, home, add_args("Top", { "--top" }))
    testing.eq(code, 0, out)
    testing.eq(backlog_names(root, home), { "Top", "One", "Two", "Three" })
    local _, status, calls = pomb_placed({ "--top" })
    testing.eq(status, 0)
    testing.ok(calls:find('"position":0', 1, true), calls)
    testing.ok(calls:find("/api/tasks/" .. ID_A .. "/move", 1, true), calls)
end)

testing.test("add --before places the card directly above CARD", function()
    local root, home, ids = local_cards()
    local out, code = dev(root, home, add_args("Mid", { "--before", ids.Three }))
    testing.eq(code, 0, out)
    testing.eq(backlog_names(root, home), { "One", "Two", "Mid", "Three" })
    local _, status, calls = pomb_placed({ "--before", "11111111-b" })
    testing.eq(status, 0)
    testing.ok(calls:find('"position":1', 1, true), calls)
end)

testing.test("add --after places the card directly below CARD", function()
    local root, home, ids = local_cards()
    local out, code = dev(root, home, add_args("Mid", { "--after", ids.One }))
    testing.eq(code, 0, out)
    testing.eq(backlog_names(root, home), { "One", "Mid", "Two", "Three" })
    local _, status, calls = pomb_placed({ "--after", "11111111-a" })
    testing.eq(status, 0)
    testing.ok(calls:find('"position":1', 1, true), calls)
end)

testing.test("add refuses two placement flags and a CARD in another column", function()
    local root, home, ids = local_cards()
    local out, code = dev(root, home, add_args("Bad", { "--top", "--before", ids.One }))
    testing.eq(code, 2, out)
    out, code = dev(root, home, add_args("Bad", { "--before", ids.One, "--after", ids.Two }))
    testing.eq(code, 2, out)
    out, code =
        dev(root, home, add_args("Bad", { "--column", support.COLUMN.ICEBOX, "--after", ids.One }))
    testing.eq(code, 2, out)
    testing.ok(
        out:find(support.COLUMN_NAME.BACKLOG, 1, true)
            and out:find(support.COLUMN_NAME.ICEBOX, 1, true),
        out
    )
    testing.eq(backlog_names(root, home), { "One", "Two", "Three" })
    out, code = dev(root, home, add_args("Bad", { "--after", "zzzzzzzz" }))
    testing.eq(code, 1, out)
    testing.eq(backlog_names(root, home), { "One", "Two", "Three" })
    local pomb_out, status, calls = pomb_placed({ "--top", "--after", "11111111-a" })
    testing.eq(status, 2, pomb_out)
    testing.eq(calls:find("-X POST", 1, true), nil)
    pomb_out, status, calls = pomb_placed({ "--after", "cccccccc" })
    testing.eq(status, 2, pomb_out)
    testing.eq(calls:find("-X POST", 1, true), nil)
end)

testing.test("add --top --id-only prints the id alone", function()
    local root, home = local_cards()
    local out, code = dev(root, home, add_args("Top", { "--top", "--id-only" }))
    testing.eq(code, 0, out)
    testing.ok(out:match("^%x%x%x%x%x%x%x%x%-[%x%-]+\n?$"), out)
    local pomb_out, status = pomb_placed({ "--top", "--id-only" })
    testing.eq(status, 0, pomb_out)
    testing.ok(pomb_out:match("^%x%x%x%x%x%x%x%x%-[%x%-]+\n?$"), pomb_out)
end)

local function crowded(rooms)
    local mover = planned()
    mover.outcomes = { { id = "s1", name = "a", done = false } }
    local held = {
        id = ID_A,
        name = "Held",
        column = support.COLUMN_NAME.REVIEW,
        size = "1 Pomodoro",
        color = "yellow",
        description = V2,
        labels = {},
        checks = {},
        outcomes = {},
    }
    local backend = fake({ mover, held })
    local tries = 0
    function backend:limits()
        tries = tries + 1
        local at = tries <= rooms and 1 or 2
        return { columns = { [support.COLUMN_NAME.REVIEW] = at }, units = {}, groups = {} }
    end
    return backend
end

local function ticking(naps)
    local clock = 0
    return {
        nap = function(seconds)
            naps[#naps + 1] = seconds
            clock = clock + seconds
        end,
        now = function()
            return clock
        end,
    }
end

testing.test("move names the full column with its count and limit", function()
    local backend = crowded(1)
    local result = cmd_board.run("move", { "cccccccc", support.COLUMN.REVIEW }, backend)
    testing.eq(result.code, 3)
    testing.eq(
        result.message,
        support.COLUMN_NAME.REVIEW
            .. " holds 1 card ("
            .. ID_A:sub(1, board.MIN_PREFIX)
            .. "), at its limit of 1. Land one first."
    )
    for _, call in ipairs(backend.calls) do
        testing.ok(call[1] ~= "move", "the refused move was sent")
    end
    backend = crowded(0)
    function backend:move()
        return nil, "no room", "full"
    end
    result = cmd_board.run("move", { "cccccccc", support.COLUMN.REVIEW }, backend)
    testing.eq(result.code, 3)
    testing.eq(result.message, "Pomb refused the move: no room")
end)

testing.test("move wait retries a full column until room frees", function()
    local backend = crowded(2)
    local naps = {}
    local args = { "cccccccc", support.COLUMN.REVIEW, "--wait", "60" }
    local result = cmd_board.move(backend, args, ticking(naps))
    testing.eq(result.code, nil)
    testing.eq(result.output, "moved cccccccc to " .. support.COLUMN_NAME.REVIEW)
    testing.eq(naps, { 15, 15 })
    local moves = 0
    for _, call in ipairs(backend.calls) do
        moves = moves + (call[1] == "move" and 1 or 0)
    end
    testing.eq(moves, 1)
end)

testing.test("move wait gives up at its timeout with the full status", function()
    local backend = crowded(100)
    local naps = {}
    local args = { "cccccccc", support.COLUMN.REVIEW, "--wait", "40" }
    local result = cmd_board.move(backend, args, ticking(naps))
    testing.eq(result.code, 3)
    testing.eq(naps, { 15, 15, 10 })
    args[4] = "soon"
    result = cmd_board.move(backend, args)
    testing.eq(result.code, 2)
end)

local function local_card_state(home, id)
    local doc = assert(json.decode(assert(fs.read(home .. "/state/dev/boards/mine.json"))))
    for _, card in ipairs(doc.cards) do
        if card.id:sub(1, #id) == id then
            return card
        end
    end
end

testing.test("take --from moves the claim and notes both names", function()
    local root, home, ids = local_cards()
    local out, code = dev(root, home, { "board", "take", ids.One }, { agent = "r/runner" })
    testing.eq(code, 0, out)
    out, code = dev(
        root,
        home,
        { "board", "take", ids.One, "--from", "r/runner" },
        { agent = "r/lead" }
    )
    testing.eq(code, 0, out)
    local card = local_card_state(home, ids.One)
    testing.eq(card.claim.claimant, "r/lead")
    local bodies = {}
    for _, comment in ipairs(card.comments) do
        bodies[#bodies + 1] = comment.body
    end
    local text = table.concat(bodies, "\n")
    testing.ok(text:find("handoff: r/runner released the claim and r/lead took it", 1, true), text)
    dev(root, home, { "board", "release", ids.One }, { agent = "r/lead" })
end)

testing.test("take --from refuses a name that is not the claimant and changes nothing", function()
    local root, home, ids = local_cards()
    dev(root, home, { "board", "take", ids.One }, { agent = "r/runner" })
    local out, code = dev(
        root,
        home,
        { "board", "take", ids.One, "--from", "r/other" },
        { agent = "r/lead" }
    )
    testing.eq(code, 1, out)
    testing.ok(out:find("is claimed by r/runner, not by r/other", 1, true), out)
    testing.eq(local_card_state(home, ids.One).claim.claimant, "r/runner")
    out, code = dev(
        root,
        home,
        { "board", "take", ids.Two, "--from", "r/runner" },
        { agent = "r/lead" }
    )
    testing.eq(code, 1, out)
    testing.ok(out:find("has no claim", 1, true), out)
    testing.eq(local_card_state(home, ids.Two).claim, nil)
    dev(root, home, { "board", "release", ids.One }, { agent = "r/runner" })
end)

local LANES = '"swimlanes":[{"id":"lane-parity","name":"Parity"},'
    .. '{"id":"lane-fixes","name":"Fixes"}]'

local function laned(lane_fields)
    local tasks = {}
    for _, task in ipairs(lane_fields) do
        local column_id = task.column or READY_COLUMN
        tasks[#tasks + 1] = support.pomb_export_task({
            id = task.id,
            name = task.name,
            column_id = column_id,
            swimlane_id = task.lane,
            position = task.position,
            color_id = false,
        })
    end
    return sandbox({
        detail = (DETAIL:gsub('"swimlanes":%[%]', LANES, 1)),
        export = '{"tasks":[' .. table.concat(tasks, ",") .. "]}",
    })
end

local LANED_TASKS = {
    { id = ID_A, name = "Alpha", lane = "lane-fixes", position = 1 },
    { id = ID_B, name = "Bravo", lane = "lane-parity", position = 3 },
    { id = ID_C, name = "Charlie", lane = "lane-parity", position = 2 },
}

testing.test("pomb orders cards by lane then position", function()
    local root, home = laned(LANED_TASKS)
    local out, code = dev(root, home, { "board", "ls", "--column", support.COLUMN.READY })
    testing.eq(code, 0, out)
    local rows = {}
    local pattern = support.COLUMN_NAME.READY .. "%s+(%S+)%s+%S+%s+%S+%s+(%S+)"
    for lane, name in out:gmatch(pattern) do
        rows[#rows + 1] = lane .. " " .. name
    end
    testing.eq(rows, { "Parity Charlie", "Parity Bravo", "Fixes Alpha" })
end)

testing.test("pomb puts column order before lane order", function()
    local root, home = laned({
        { id = ID_A, name = "Alpha", lane = "lane-fixes", position = 1 },
        { id = ID_B, name = "Bravo", lane = "lane-parity", position = 3 },
        { id = ID_C, name = "Charlie", lane = "lane-fixes", position = 2, column = BACKLOG_COLUMN },
    })
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 0, out)
    local names = {}
    for line in out:gmatch("[^\n]+") do
        names[#names + 1] = line:match("(%S+)$")
    end
    testing.eq(names, { "Charlie", "Bravo", "Alpha" })
end)

testing.test("pomb sorts a card in an unknown lane last with no lane name", function()
    local tasks = { { id = ID_D, name = "Delta", lane = "lane-gone", position = 0 } }
    for _, task in ipairs(LANED_TASKS) do
        tasks[#tasks + 1] = task
    end
    local root, home = laned(tasks)
    local out = dev(root, home, { "board", "ls", "--column", support.COLUMN.READY })
    local rows = {}
    local pattern = support.COLUMN_NAME.READY .. "%s+(%S+)%s+%S+%s+%S+%s+(%S+)"
    for lane, name in out:gmatch(pattern) do
        rows[#rows + 1] = lane .. " " .. name
    end
    testing.eq(rows, { "Parity Charlie", "Parity Bravo", "Fixes Alpha", "- Delta" })
end)

testing.test("ls and show print the lane of a card", function()
    local root, home = laned(LANED_TASKS)
    local out = dev(root, home, { "board", "show", "11111111-a" })
    testing.ok(out:find(support.COLUMN_NAME.READY .. "  Fixes  ", 1, true), out)
    root, home = sandbox()
    out = dev(root, home, { "board", "ls", "--column", support.COLUMN.READY })
    testing.ok(not out:find("Fixes", 1, true), out)
    testing.ok(not out:find("Parity", 1, true), out)
end)

testing.test("add with a lane puts the card in that lane", function()
    local root, home = laned(LANED_TASKS)
    local args = {
        "board",
        "add",
        "New",
        "--size",
        "1",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--done-when",
        "a",
    }
    local out, code = dev(root, home, args)
    testing.eq(code, 0, out)
    testing.ok(not read(root, "calls"):find("swimlane_id", 1, true), read(root, "calls"))
    table.insert(args, "--lane")
    table.insert(args, "fixes")
    out, code = dev(root, home, args)
    testing.eq(code, 0, out)
    testing.ok(read(root, "calls"):find('"swimlane_id":"lane-fixes"', 1, true), read(root, "calls"))
end)

testing.test("move keeps the lane unless a lane is given", function()
    local root, home = laned(LANED_TASKS)
    local out, code = dev(root, home, { "board", "move", "11111111-a", support.COLUMN.ICEBOX })
    testing.eq(code, 0, out)
    testing.ok(read(root, "calls"):find("/api/tasks/" .. ID_A .. "/move", 1, true), out)
    testing.ok(not read(root, "calls"):find("swimlane_id", 1, true), read(root, "calls"))
    out, code = dev(
        root,
        home,
        { "board", "move", "11111111-a", support.COLUMN.ICEBOX, "--lane", "Parity" }
    )
    testing.eq(code, 0, out)
    testing.ok(
        read(root, "calls"):find('"swimlane_id":"lane-parity"', 1, true),
        read(root, "calls")
    )
end)

testing.test("ls and next with a lane list only that lane", function()
    local root, home = laned(LANED_TASKS)
    local out, code =
        dev(root, home, { "board", "ls", "--column", support.COLUMN.READY, "--lane", "parity" })
    testing.eq(code, 0, out)
    testing.ok(out:find("Charlie", 1, true) and out:find("Bravo", 1, true), out)
    testing.ok(not out:find("Alpha", 1, true), out)
    out, code = dev(root, home, { "board", "next", "--lane", "Fixes" })
    testing.eq(code, 0, out)
    testing.ok(read(root, "calls"):find("&swimlane_id=lane-fixes", 1, true), read(root, "calls"))
end)

testing.test("a lane the board lacks is refused", function()
    local root, home = laned(LANED_TASKS)
    for _, args in ipairs({
        { "board", "ls", "--lane", "Features" },
        { "board", "next", "--lane", "Features" },
        { "board", "move", "11111111-a", support.COLUMN.ICEBOX, "--lane", "Features" },
        { "board", "add", "New", "--lane", "Features" },
    }) do
        local out, code = dev(root, home, args)
        testing.eq(code, 2, out)
        testing.ok(out:find("unknown lane Features, the lanes are Parity, Fixes", 1, true), out)
    end
    root, home = sandbox()
    local out, code = dev(root, home, { "board", "ls", "--lane", "Parity" })
    testing.eq(code, 2, out)
    testing.ok(out:find("the board has no lanes", 1, true), out)
end)

testing.test("pomb next asks each lane in lane order", function()
    local root, home = laned(LANED_TASKS)
    local _, code = dev(root, home, { "board", "next" })
    testing.eq(code, 0)
    local calls = read(root, "calls")
    local parity = calls:find("&swimlane_id=lane-parity", 1, true)
    testing.ok(parity, calls)
    local fixes = calls:find("&swimlane_id=lane-fixes", 1, true)
    testing.ok(fixes == nil or parity < fixes, calls)
end)

testing.test("pomb next on a one lane board sends no lane filter", function()
    local root, home = sandbox()
    local _, code = dev(root, home, { "board", "next" })
    testing.eq(code, 0)
    testing.eq(read(root, "calls"):find("swimlane_id", 1, true), nil)
end)

testing.test("pomb next falls through to the next lane when one has no card", function()
    local root, home = laned(LANED_TASKS)
    testing.eq(dev_os.run({ "mv", root .. "/bin/curl", root .. "/bin/curl_real" }), 0)
    executable(
        root .. "/bin/curl",
        "#!/bin/sh\n"
            .. 'case " $* " in *swimlane_id=lane-parity*)\n'
            .. 'printf \'curl %s\\n\' "$*" >>"$ROOT/calls"\n'
            .. "printf '%s\\n%s' '{\"items\":[],\"next_cursor\":null}' 200 ;;\n"
            .. '*) exec "$ROOT/bin/curl_real" "$@" ;; esac\n'
    )
    local out, code = dev(root, home, { "board", "next" })
    testing.eq(code, 0, out)
    testing.ok(out:find(ID_A:sub(1, 8), 1, true), out)
    local calls = read(root, "calls")
    testing.ok(calls:find("&swimlane_id=lane-fixes", 1, true), calls)
end)
