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

local function executable(path, body)
    assert(fs.write(path, body))
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function fake(cards, times)
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
    function backend:add(name, column, opts)
        calls[#calls + 1] = { "add", name, column, opts.description, opts.color, opts.labels }
        return { id = ID_C, name = name, column = column, size = "unsized", labels = {} }
    end
    function backend:note(id, text)
        calls[#calls + 1] = { "note", id, text }
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
    function backend:set_size(id, color, fence)
        calls[#calls + 1] = { "set_size", id, color, fence }
        return true
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
        },
        { id = ID_B, name = "Fix lint", column = "Backlog", size = "unsized", labels = {} },
        { id = ID_C, name = "Old thing", column = "Done", size = "unsized", labels = {} },
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
    t.eq(backend.calls[1], { "add", "A new card", "Backlog", nil, nil })
    result = commands.run("add", { "X", "--column", "ready", "--description", "why" }, backend)
    t.eq(backend.calls[2], { "add", "X", "Ready", "why", nil })
    t.eq(commands.run("add", {}, backend).code, 2)
end)

t.test("add --size passes the colour its size word names", function()
    local backend = fake(sample())
    for word, color in pairs({ ["1"] = "yellow", ["2"] = "green", ["3"] = "blue", ["3+"] = "red" }) do
        commands.run("add", { "X", "--size", word }, backend)
        t.eq(backend.calls[#backend.calls], { "add", "X", "Backlog", nil, color })
    end
    commands.run("add", { "X", "--size", "UNSIZED" }, backend)
    t.eq(backend.calls[#backend.calls], { "add", "X", "Backlog", nil, "white" })
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
    t.eq(backend.calls[1], { "add", "X", "Backlog", nil, nil, { "a", "needs:lead" } })
    commands.run("add", { "X" }, backend)
    t.eq(backend.calls[2], { "add", "X", "Backlog", nil, nil, nil })
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

t.test("note and move resolve the card by prefix", function()
    local backend = fake(sample())
    local result = commands.run("note", { "cccccccc", "landed", "as", "abc" }, backend)
    t.eq(result.output, "noted cccccccc")
    t.eq(backend.calls[1], { "note", ID_C, "landed as abc" })
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
        "aaaaaaaa  worker  2026-10-27 09:30  first line\nbbbbbbbb  human   2026-10-27 10:00  ok"
    )
    t.eq(commands.run("notes", { "cccccccc" }, fake(sample())).output, "no comments")
    t.eq(commands.run("notes", {}, backend).code, 2)
    t.eq(commands.run("notes", { "deadbeef" }, backend).code, 1)
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
        cards[i] = { id = id, name = "Card " .. i, column = column, size = "unsized", labels = {} }
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
    t.eq(lines, { "Backlog", "Ready", "In Progress", "In Review" })
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
            .. "00000005  Ready    1d   unsized  Card 5"
    )
    cards, times = aged({ "Ready" }, { 9 }, { human })
    result = commands.run("stale", {}, fake(cards, times), NOW)
    t.eq(
        result.output,
        "no stale cards\n\nfor the owner (needs:human):\n00000001  Ready  9d  unsized  Card 1"
    )
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
local EXPORT = '{"tasks":['
    .. '{"id":"'
    .. ID_B
    .. '","name":"Second","column_id":"col-ready","position":2,"color_id":null,"labels":[]},'
    .. '{"id":"'
    .. ID_A
    .. '","name":"First","column_id":"col-ready","position":1,"color_id":"yellow-id","labels":["docs"]},'
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
*/export-data) body=$(cat "$ROOT/export.json") ;;
*/tasks\?limit=500\&cursor=c2) body='{"items":[{"id":"]] .. ID_B .. [[","column_entered_at":"2020-02-01T00:00:00Z"}],"next_cursor":null}' ;;
*/tasks\?limit=500) body='{"items":[{"id":"]] .. ID_A .. [[","column_entered_at":"2020-01-01T00:00:00.5+00:00"}],"next_cursor":"c2"}' ;;
*/tasks\?*) body='{"items":[{"id":"]] .. ID_A .. [["}],"next_cursor":null}' ;;
*/api/tasks/]] .. ID_A .. [[) body=$(cat "$ROOT/task.json") ;;
*/api/tasks) body=$(cat "$ROOT/task.json") ;;
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
        ["export.json"] = EXPORT,
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
        { env = { HOME = home, ROOT = root, XDG_STATE_HOME = home .. "/state" } }
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
    local out, code =
        dev(root, home, { "board", "add", "New card", "--column", "ready", "--description", "why" })
    t.eq(code, 0)
    t.eq(out, "added 11111111 Ready\n")
    local calls = read(root, "calls")
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

t.test("note posts a comment of kind agent and move goes to the top of the column", function()
    local root, home = sandbox()
    local out = dev(root, home, { "board", "note", "11111111-a", "landed", "it" })
    t.eq(out, "noted 11111111\n")
    local calls = read(root, "calls")
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/comments", 1, true), calls)
    t.ok(calls:find('"kind":"agent"', 1, true), calls)
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
        "aaaaaaaa  worker  2026-10-27 09:30  first\ndddddddd  human   2026-10-27 10:00  mine? no\n"
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
    t.eq(backend.calls[1], { "note", ID_C, "- fixed it" })
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
    t.eq(fs.exists(state_file(home)), false)
    t.ok(loop_gone(pid))
    local after = settle(root)
    t.eq(heartbeats(root), after)
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
            "^11111111  Ready  %d+d  1 Pomodoro  First\n11111111  Ready  %d+d  unsized     Second\n\ncould not date cccccccc%S+ Early\n$"
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
