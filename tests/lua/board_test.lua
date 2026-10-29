local t = require("testing")
local board = require("dev.board")
local box = require("dev.cmd.box")
local commands = require("dev.cmd.board")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local TOKEN = "pomb_SECRETtoken0123456789"
local ID_A = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
local ID_B = "11111111-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
local ID_C = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
local V1 = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone\n\n## Done when\n- [ ] done"
local SCAFFOLD = "## Problem\n\n## Change\n\n## Out of scope\n"
local V2 = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone"

local function executable(path, body)
    assert(fs.write(path, body))
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function fake(cards, times)
    for _, card in ipairs(cards) do
        card.outcomes = card.outcomes or {}
    end
    local calls = {}
    local backend = { calls = calls }
    function backend:entered()
        return times or {}
    end
    function backend:describe()
        return "fake"
    end
    function backend:cards()
        return cards
    end
    function backend:next()
        return cards[1]
    end
    function backend:checks_field()
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
    function backend:comments(id)
        calls[#calls + 1] = { "comments", id }
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
    function backend:set_description(id, text, fence)
        calls[#calls + 1] = { "set_description", id, text, fence }
        return true
    end
    function backend:set_checks(id, runs, fence)
        calls[#calls + 1] = { "set_checks", id, runs, fence }
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
    function backend:other_board(name)
        calls[#calls + 1] = { "other_board", name }
        if name == "ci" then
            return backend.sibling
        end
        return nil, "pomb has no board named " .. name
    end
    function backend:move(id, column)
        calls[#calls + 1] = { "move", id, column }
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

t.test("column takes the names and the short forms in any case", function()
    t.eq(board.column("ready"), "Ready")
    t.eq(board.column("PROGRESS"), "In Progress")
    t.eq(board.column("in  review"), "In Review")
    t.eq(board.column("review"), "In Review")
    for _, short in ipairs({ "blocked", "done", "backlog", "icebox" }) do
        t.eq(board.column(short):lower(), short)
    end
    t.eq(board.column("doing"), nil)
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
    local result = commands.run("add", { "A", "new", "card" }, backend)
    t.eq(result.output, "added cccccccc Backlog")
    t.eq(backend.calls[1], { "add", "A new card", "Backlog", SCAFFOLD, nil })
    result = commands.run(
        "add",
        { "X", "--column", "ready", "--description", V1, "--size", "2", "--checks", "dev test" },
        backend
    )
    t.eq(backend.calls[2], { "add", "X", "Ready", V1, "green" })
    t.eq(commands.run("add", {}, backend).code, 2)
end)

t.test("add --size passes the colour its size word names", function()
    local backend = fake(sample())
    for word, color in pairs({ ["1"] = "yellow", ["2"] = "green", ["3"] = "blue", ["3+"] = "red" }) do
        commands.run("add", { "X", "--size", word }, backend)
        t.eq(backend.calls[#backend.calls], { "add", "X", "Backlog", SCAFFOLD, color })
    end
    commands.run("add", { "X", "--size", "UNSIZED" }, backend)
    t.eq(backend.calls[#backend.calls], { "add", "X", "Backlog", SCAFFOLD, "white" })
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
    local result = commands.run("size", { "cccccccc", "unsized" }, backend)
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
    commands.run("add", { "X", "--label", "a", "--label", "needs:lead", "--label", "a" }, backend)
    t.eq(backend.calls[1], { "add", "X", "Backlog", SCAFFOLD, nil, { "a", "needs:lead" } })
    commands.run("add", { "X" }, backend)
    t.eq(backend.calls[2], { "add", "X", "Backlog", SCAFFOLD, nil, nil })
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
    local result = commands.run("edit", { "11111111-a", "## Problem\nnew plan" }, backend)
    t.eq(result.output, "edited 11111111")
    t.eq(backend.calls[1], { "set_description", ID_A, "## Problem\nnew plan", nil })
end)

t.test("checks replaces the rows with one row per command", function()
    local backend = fake(sample())
    local result = commands.run("checks", { "11111111-a", "dev lint", "dev test" }, backend)
    t.eq(result.output, "set checks 11111111, 2 rows")
    t.eq(backend.calls[1], { "set_checks", ID_A, { "dev lint", "dev test" }, nil })
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
    local backend = fake(sample())
    local result = commands.run("note", { "cccccccc", "landed", "as", "abc" }, backend)
    t.eq(result.output, "noted cccccccc")
    t.eq(backend.calls[1], { "note", ID_C, "landed as abc", {} })
    result = commands.run("move", { "cccccccc", "progress" }, backend)
    t.eq(result.output, "moved cccccccc to In Progress")
    t.eq(backend.calls[2], { "move", ID_C, "In Progress" })
    result = commands.run("move", { "cccccccc", "in", "review" }, backend)
    t.eq(backend.calls[3], { "move", ID_C, "In Review" })
end)

local COMMENT_1 = "aaaaaaaa-1111-4111-8111-111111111111"
local COMMENT_2 = "bbbbbbbb-2222-4222-8222-222222222222"

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
            .. "bbbbbbbb  human   -         -         2026-10-27 10:00  ok"
    )
    t.eq(backend.calls[#backend.calls], { "comments", ID_A })
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
        t.eq(commands.run("add", { "X", "--column", "backlog" }, backend).code, nil)
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
    commands.run("add", { "X", "--description", "It breaks." }, backend)
    t.eq(backend.calls[1][4], "## Problem\nIt breaks.\n\n## Change\n\n## Out of scope\n")
    commands.run("add", { "X", "--description", V1 }, backend)
    t.eq(backend.calls[2][4], V1)
    commands.run("add", { "X", "--column", "icebox", "--description", "loose" }, backend)
    t.eq(backend.calls[3], { "add", "X", "Icebox", "loose", nil })
    commands.run("add", { "X", "--column", "icebox" }, backend)
    t.eq(backend.calls[4], { "add", "X", "Icebox", nil, nil })
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
    local result =
        commands.run("add", { "X", "--checks", "dev lint", "--checks", "dev test" }, backend)
    t.eq(result.output, "added cccccccc Backlog")
    t.eq(backend.opts.checks, { "dev lint", "dev test" })
    result = commands.run("add", { "X", "--checks", "  " }, backend)
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
    result = commands.run("add", { "X", "--checks", "dev test" }, backend)
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

t.test("add --done-when hands the outcomes to the backend and checks them", function()
    local backend = fake(sample())
    local result =
        commands.run("add", { "X", "--done-when", "A works", "--done-when", "B works" }, backend)
    t.eq(result.output, "added cccccccc Backlog")
    t.eq(backend.opts.outcomes, { "A works", "B works" })
    t.eq(commands.run("add", { "X", "--done-when", " " }, backend).code, 2)
    t.eq(commands.run("add", { "X", "--done-when" }, backend).code, 2)
    local many = { "X" }
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
    result = commands.run("add", { "X", "--done-when", "see src/a.lua" }, backend)
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

t.test("move into Icebox never checks the description", function()
    local card = colored("white")
    card.description = nil
    local backend = fake({ card })
    t.eq(commands.run("move", { "cccccccc", "icebox" }, backend).code, nil)
end)

t.test("move to Ready takes a sized card, and other columns take any card", function()
    for _, color in ipairs({ "yellow", "green", "blue" }) do
        local backend = fake({ colored(color) })
        t.eq(
            commands.run("move", { "cccccccc", "ready" }, backend).output,
            "moved cccccccc to Ready"
        )
    end
    for _, column in ipairs({ "icebox", "backlog", "progress", "review", "blocked", "done" }) do
        local backend = fake({ colored("white") })
        t.eq(commands.run("move", { "cccccccc", column }, backend).code, nil)
        t.eq(#backend.calls, 1)
    end
end)

t.test("next shows the top card or says none", function()
    local result = commands.run("next", {}, fake(sample()))
    t.eq(result.output, "11111111  Ready  1 Pomodoro  docs  Write docs")
    result = commands.run("next", {}, fake({}))
    t.eq(result.output, "no ready cards")
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

t.test("stale covers Backlog, Ready, In Progress and In Review only", function()
    local columns = { "Icebox", "Backlog", "Ready", "In Progress", "In Review", "Blocked", "Done" }
    local cards, times = aged(columns, { 40, 40, 40, 40, 40, 40, 40 })
    local result = commands.run("stale", {}, fake(cards, times), NOW)
    local lines = {}
    for line in result.output:gmatch("[^\n]+") do
        lines[#lines + 1] = line:match("^%d+%s+(%a+[ %a]-)%s%s")
    end
    t.eq(lines, { "Backlog", "Ready", "In Progress", "In Review", "Backlog" })
end)

t.test("stale lists every needs:human card apart at any age, and never as stale", function()
    local human = { "needs:human" }
    local cards, times = aged(
        { "Ready", "Backlog", "Blocked", "Done", "Ready" },
        { 9, 20, 50, 60, 1 },
        { {}, human, human, human, human }
    )
    local result = commands.run("stale", {}, fake(cards, times), NOW)
    t.eq(
        result.output,
        "00000001  Ready  9d  unsized  Card 1\n\nfor the owner (needs:human):\n"
            .. "00000003  Blocked  50d  unsized  Card 3\n"
            .. "00000002  Backlog  20d  unsized  Card 2\n"
            .. "00000005  Ready    1d   unsized  Card 5\n\nunsized in Backlog:\n"
            .. "00000002  Backlog  Card 2"
    )
    cards, times = aged({ "Ready" }, { 9 }, { human })
    result = commands.run("stale", {}, fake(cards, times), NOW)
    t.eq(
        result.output,
        "no stale cards\n\nfor the owner (needs:human):\n00000001  Ready  9d  unsized  Card 1"
    )
end)

t.test("stale lists the unsized Backlog cards at any age and leaves sized ones out", function()
    local cards, times = aged(
        { "Backlog", "Backlog", "Backlog", "Ready", "Icebox" },
        { 0, 1, 2, 1, 1 }
    )
    cards[2].color = "green"
    cards[3].color = "white"
    t.eq(
        commands.run("stale", {}, fake(cards, times), NOW).output,
        "no stale cards\n\nunsized in Backlog:\n00000001  Backlog  Card 1\n00000003  Backlog  Card 3"
    )
    cards[1].color = "red"
    cards[3].color = "blue"
    t.eq(commands.run("stale", {}, fake(cards, times), NOW).output, "no stale cards")
end)

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

t.test("stale refuses a bad --days with a usage error", function()
    for _, word in ipairs({ "0", "-1", "x", "1.5", "" }) do
        local result = commands.run("stale", { "--days", word }, fake({}), NOW)
        t.eq(result.code, 2, word)
    end
    t.eq(commands.run("stale", { "--days" }, fake({}), NOW).code, 2)
    t.eq(commands.run("stale", { "extra" }, fake({}), NOW).code, 2)
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
    .. '{"id":"col-review","name":"In Review"},{"id":"col-blocked","name":"Blocked"},'
    .. '{"id":"col-done","name":"Done"}]}'
local COLORS = '[{"id":"yellow-id","value":"yellow","label":"1 Pomodoro"},'
    .. '{"id":"green-id","value":"green","label":"Two"},{"id":"blue-id","value":"blue","label":"Three"},'
    .. '{"id":"red-id","value":"red","label":"More"},{"id":"white-id","value":"white","label":"Unsized"}]'
local FIELDS =
    '[{"id":"f1","key":"dev.checks","label":"Checks","kind":"table","options":[],"columns":[],"required":true}]'
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
local COMMENTS = '[{"id":"aaaaaaaa-1111-4111-8111-111111111111","author":"api-token","actor_kind":"agent",'
    .. '"token_name":"worker","created_at":"2026-10-27T09:30:12Z","body":"first\\nline"},'
    .. '{"id":"dddddddd-4444-4444-8444-444444444444","author":"x","actor_kind":"human",'
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
*/colors) body=$(cat "$ROOT/colors.json") ;;
*/fields) body=$(cat "$ROOT/fields.json") ;;
*/export-data) body=$(cat "$ROOT/export.json") ;;
*/tasks\?limit=500\&cursor=c2) body='{"items":[{"id":"]] .. ID_B .. [[","column_entered_at":"2020-02-01T00:00:00Z"}],"next_cursor":null}' ;;
*/tasks\?limit=500) body='{"items":[{"id":"]] .. ID_A .. [[","column_entered_at":"2020-01-01T00:00:00.5+00:00"}],"next_cursor":"c2"}' ;;
*/tasks\?*) body='{"items":[{"id":"]] .. ID_A .. [["}],"next_cursor":null}' ;;
*/api/tasks/]] .. ID_A .. [[) body=$(cat "$ROOT/task.json") ;;
*/api/tasks) body=$(cat "$ROOT/task.json") ;;
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
*/comments/dddddddd*) body='{"message":"not yours"}'; status=403 ;;
*/comments/*) body='{"ok":true}' ;;
*/comments) body=$(cat "$ROOT/comments.json") ;;
*/claim) body='{"fence":7,"claimant":"x"}' ;;
*) body='{"ok":true}' ;;
esac
printf '%s\n%s' "$body" "$status"
]]

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
        ["detail.json"] = DETAIL,
        ["colors.json"] = COLORS,
        ["fields.json"] = opts.fields or FIELDS,
        ["export.json"] = opts.export or EXPORT,
        ["task.json"] = TASK,
        ["comments.json"] = COMMENTS,
    }) do
        assert(fs.write(root .. "/" .. name, body))
    end
    executable(root .. "/bin/curl", CURL)
    executable(root .. "/bin/sleep", "#!/bin/sh\nexec " .. devos.which("sleep") .. " 0.2\n")
    executable(
        root .. "/bin/pass",
        '#!/bin/sh\nprintf "pass %s opts=%s\\n" "$*" "$PASSWORD_STORE_GPG_OPTS" >>"$ROOT/calls"\n'
            .. (opts.locked and "exit 1\n" or ('echo "' .. TOKEN .. '"\n'))
    )
    return root, home
end

local function dev(root, home, args)
    return support.dev(
        root,
        args,
        { env = { HOME = home, ROOT = root, XDG_STATE_HOME = home .. "/state", CI = "" } }
    )
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

t.test("next asks for the unclaimed unblocked top of Ready", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "next" })
    t.eq(code, 0)
    t.eq(out, "11111111  Ready  1 Pomodoro  docs  First\n")
    t.ok(
        read(root, "calls"):find(
            "/api/boards/board-1/tasks?limit=1&ready=true&claimed=false&column_id=col-ready",
            1,
            true
        ),
        read(root, "calls")
    )
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

t.test("add --size and size reach pomb with the id of the colour, not its label", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "add", "New", "--size", "3+" })
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
    t.eq(code, 0)
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
    local out, code = dev(root, home, { "board", "add", "New", "--label", "a", "--label", "b" })
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

t.test("note posts a comment of kind agent and move goes to the top of the column", function()
    local root, home = sandbox()
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
    t.eq(out, "moved 11111111 to In Review\n")
    calls = read(root, "calls")
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/move", 1, true), calls)
    t.ok(calls:find('"column_id":"col-review"', 1, true), calls)
    t.ok(calls:find('"position":0', 1, true), calls)
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
            .. "aaaaaaaa  worker  -  -  2026-10-27 09:30  first\ndddddddd  human   -  x  2026-10-27 10:00  mine? no\n"
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

t.test("a nonexistent column on the board is reported", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/detail.json", '{"id":"board-1","name":"dotfiles","columns":[]}'))
    local out, code = dev(root, home, { "board", "add", "x" })
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
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    t.ok(wait_until(function()
        return heartbeats(root) >= 2
    end))
    local pid = loop_pid(home)
    local out, code = dev(root, home, { "board", "move", "11111111-a", "review" })
    t.eq(code, 0)
    t.eq(out, "moved 11111111 to In Review\n")
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
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    dev(root, home, { "board", "move", "11111111-a", "progress" })
    t.eq(read(root, "calls"):find("/claim/release", 1, true), nil)
    dev(root, home, { "board", "release", "11111111-a" })
end)

t.test("a release the server refuses after a move warns and the move succeeds", function()
    local root, home = sandbox()
    dev(root, home, { "board", "take", "11111111-a" })
    executable(
        root .. "/bin/curl",
        (CURL:gsub("%*/claim/release%) body= ;;", "*/claim/release) body=; status=503 ;;", 1))
    )
    local out, code = dev(root, home, { "board", "move", "11111111-a", "done" })
    t.eq(code, 0)
    t.ok(out:find("moved 11111111 to Done", 1, true), out)
    t.ok(out:find("the claim was not released", 1, true), out)
    t.eq(fs.exists(state_file(home)), false)
end)

t.test("move into progress keeps the loop and the state", function()
    local root, home = sandbox()
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
    executable(
        root .. "/bin/curl",
        (CURL:gsub("%*/claim/release%) body= ;;", "*/claim/release) body=; status=503 ;;", 1))
    )
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
            "^11111111  Ready  %d+d  1 Pomodoro  First\n11111111  Ready  %d+d  unsized     Second\n\nunsized in Backlog:\ncccccccc  Backlog  Early\n\ncould not date cccccccc%S+ Early\n$"
        ),
        out
    )
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
        [[*) printf '{"code":"permission_denied","permission":"tasks.write","message":"m","board_id":null}\n403' ;;
]]
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.eq(
        out,
        "dev: board unavailable: pomb answered 403: this token lacks the tasks.write permission "
            .. "on every board; use a token that has it\n"
    )
end)

t.test("a permission_denied with a board says the board is not assigned", function()
    local root, home = sandbox()
    answering(
        root,
        [[*) printf '{"code":"permission_denied","permission":"tasks.write","message":"m","board_id":"board-9"}\n403' ;;
]]
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.eq(
        out,
        "dev: board unavailable: this token has the tasks.write permission but is not assigned "
            .. "to board board-9; add the board to the token\n"
    )
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
        local out, code = dev(root, home, { "board", "add", "New", "--checks", "dev test" })
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
    result = commands.run("add", { "X", "--description", "in src/a.lua" }, backend)
    t.eq(result.warnings, { "card prose holds a path: src/a.lua" })
    result = commands.run("add", { "X", "--description", V1 }, backend)
    t.eq(result.warnings, {})
    result =
        commands.run("edit", { "cccccccc", "## Change\n- a/b.lua\n## Problem\nx/y.sh" }, backend)
    t.eq(result.warnings, { "card prose holds a path: x/y.sh" })
end)
