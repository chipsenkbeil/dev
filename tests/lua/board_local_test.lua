local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local COLUMN = support.COLUMN

local TOKEN = "pomb_SECRETtoken0123456789"
local ID_A = "aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa"
local ID_B = "bbbbbbbb-1111-4bbb-8bbb-bbbbbbbbbbbb"
local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/dotfiles/bin/.local/share/dev/main.lua"

local V1 = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone\n\n## Done when\n- [ ] done"

local function setup(project)
    local root = support.sandbox({ [".dev/config.toml"] = project }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(
        fs.write(
            home .. "/.config/dev/config.toml",
            '[board.pomb]\nurl = "https://pomb.example"\ntoken = "pass:secrets/worker/token/pomb"\n'
        )
    )
    return root, home
end

local function env_of(home, extra)
    local env = {
        HOME = home,
        XDG_STATE_HOME = home .. "/state",
        CLAUDE_SESSION_ID = "one",
        DEV_PASS_LOCK = home .. "/pass.lock",
    }
    for name, value in pairs(extra or {}) do
        env[name] = value
    end
    return env
end

local function dev(root, home, args, extra)
    return support.dev(root, args, { env = env_of(home, extra) })
end

local function local_board(project)
    local root, home = setup(project or '[board]\nbackend = "local"\nname = "mine"\n')
    local out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)
    return root, home
end

local function file_of(home)
    return home .. "/state/dev/boards/mine.json"
end

local function document(path)
    return assert(json.decode(assert(fs.read(path))))
end

local function prefix_of(out)
    return assert(out:match("added (%x+)"), out)
end

local function tick_first(root, home, id)
    local out, code =
        dev(root, home, { "board", "outcome", id, "--tick", "1", "--as", "r/reviewer" })
    testing.eq(code, 0, out)
end

local function mode(path)
    return string.format("%o", bit.band(assert(fs.stat(path)).mode, 511))
end

testing.test("init lays out the nine columns and the palette and is idempotent", function()
    local root, home = setup('[board]\nbackend = "local"\nname = "mine"\n')
    local out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)
    testing.ok(out:find("created board mine with no template", 1, true), out)
    for _, column in ipairs({
        "Icebox",
        "Backlog",
        "Ready",
        "In Progress",
        "Review",
        "Verify",
        "Release",
        "Blocked",
        "Done",
    }) do
        testing.ok(out:find("added column " .. column, 1, true), out)
    end
    testing.ok(out:find('named yellow "1 Pomodoro"', 1, true), out)
    testing.ok(out:find('named white "Unsized"', 1, true), out)
    testing.ok(out:find("made white the default colour", 1, true), out)
    local doc = document(file_of(home))
    local names = {}
    for _, column in ipairs(doc.columns) do
        names[#names + 1] = column.name
    end
    testing.eq(names, {
        "Icebox",
        "Backlog",
        "Ready",
        "In Progress",
        "Review",
        "Verify",
        "Release",
        "Blocked",
        "Done",
    })
    testing.eq(doc.columns[9].is_done, true)
    local labels = {}
    for _, color in ipairs(doc.colors) do
        labels[#labels + 1] = color.value .. "=" .. color.label
    end
    testing.eq(labels, {
        "yellow=1 Pomodoro",
        "green=2 Pomodori",
        "blue=3 Pomodori",
        "red=>3 Pomodori",
        "white=Unsized",
    })
    out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(out, "board mine already follows the standard, nothing to change\n")
end)

testing.test("the board file is private and writes leave no temporary file", function()
    local root, home = local_board()
    dev(root, home, { "board", "add", "One", "--problem", "x", "--size", "1", "--done-when", "a" })
    testing.eq(mode(file_of(home)), "600")
    testing.eq(mode(home .. "/state/dev/boards"), "700")
    local names = fs.list(home .. "/state/dev/boards")
    testing.eq(names, { "mine.json", "mine.json.lock" })
end)

testing.test("show and note refuse a crossboard --board on a local board", function()
    local root, home = local_board()
    local out, code = dev(root, home, { "board", "show", "11111111", "--board", "other" })
    testing.eq(code, 1, out)
    testing.eq(out, "dev: a local board links only its own cards, so other is not reachable\n")
    out, code = dev(root, home, { "board", "note", "11111111", "--board", "other", "text" })
    testing.eq(code, 1, out)
    testing.eq(out, "dev: a local board links only its own cards, so other is not reachable\n")
end)

testing.test("edit --board reaches the dispatcher and a local board refuses it", function()
    local root, home = local_board()
    assert(fs.write(root .. "/plan.md", "## Problem\nfrom a file\n"))
    local out, code = dev(
        root,
        home,
        { "board", "edit", "11111111", "--board", "other", "--file", root .. "/plan.md" }
    )
    testing.eq(code, 1, out)
    testing.eq(out, "dev: a local board links only its own cards, so other is not reachable\n")
end)

testing.test("boards and columns answer for a local board's own name only", function()
    local root, home = local_board()
    local out, code = dev(root, home, { "board", "boards" })
    testing.eq(code, 0, out)
    testing.eq(out, "mine\n")
    local columns =
        "Icebox\nBacklog\nReady\nIn Progress\nReview\nVerify\nRelease\nBlocked\nDone (done)\n"
    out, code = dev(root, home, { "board", "columns" })
    testing.eq(code, 0, out)
    testing.eq(out, columns)
    out, code = dev(root, home, { "board", "columns", "mine" })
    testing.eq(code, 0, out)
    testing.eq(out, columns)
    out, code = dev(root, home, { "board", "columns", "other" })
    testing.eq(code, 1, out)
    testing.eq(out, "dev: a local board knows only its own columns, so other is not reachable\n")
    out, code = dev(root, home, { "board", "columns", "mine", "extra" })
    testing.eq(code, 2, out)
    out, code = dev(root, home, { "board", "boards", "extra" })
    testing.eq(code, 2, out)
end)

testing.test("add, ls, next, move, size and label work on a local board", function()
    local root, home = local_board()
    local out, code = dev(root, home, {
        "board",
        "add",
        "Write docs",
        "--column",
        COLUMN.READY,
        "--size",
        "2",
        "--label",
        "docs",
        "--label",
        "needs:lead",
        "--description",
        V1,
        "--checks",
        "dev test",
    })
    testing.eq(code, 0, out)
    local a = prefix_of(out)
    testing.ok(out:find("Ready", 1, true), out)
    out = dev(
        root,
        home,
        { "board", "add", "Second", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    local b = prefix_of(out)
    out = dev(root, home, { "board", "ls" })
    testing.eq(
        out,
        b
            .. "  Backlog  1 Pomodoro  -                0/1  Second\n"
            .. a
            .. "  Ready    2 Pomodori  docs,needs:lead  -    Write docs\n"
    )
    out = dev(root, home, { "board", "ls", "--size", "3+" })
    testing.eq(out, "no cards\n")
    out = dev(root, home, { "board", "ls", "--label", "docs" })
    testing.ok(out:find("Write docs", 1, true), out)
    out = dev(root, home, { "board", "next" })
    testing.eq(
        out,
        a .. "  Ready  2 Pomodori  docs,needs:lead  Write docs  0 comments, 0 the owner's\n"
    )
    out = dev(root, home, { "board", "move", a, COLUMN.REVIEW })
    testing.eq(out, "moved " .. a .. " to Review\n")
    out = dev(root, home, { "board", "next" })
    testing.eq(out, "no ready cards\n")
    out = dev(root, home, { "board", "size", b, "1" })
    testing.eq(out, "sized " .. b .. " 1\n")
    out = dev(root, home, { "board", "label", a, "+extra", "--remove", "docs" })
    testing.eq(out, "labelled " .. a .. " needs:lead,extra\n")
    out = dev(root, home, { "board", "move", a, COLUMN.DONE })
    out = dev(root, home, { "board", "ls" })
    testing.eq(out, b .. "  Backlog  1 Pomodoro  -  0/1  Second\n")
    out = dev(root, home, { "board", "ls", "--column", COLUMN.DONE })
    testing.ok(out:find("Done  2 Pomodori", 1, true), out)
end)

testing.test("edit replaces a local card's description from a file or standard input", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Card", "--column", COLUMN.ICEBOX, "--description", "old" }
            )
        )
    )
    assert(fs.write(root .. "/plan.md", "## Problem\nfrom a file\n\n"))
    local out, code = dev(root, home, { "board", "edit", a, "--file", root .. "/plan.md" })
    testing.eq(code, 0, out)
    testing.eq(out, "edited " .. a .. "\n")
    testing.eq(document(file_of(home)).cards[1].description, "## Problem\nfrom a file")
    out, code = support.dev(
        root,
        { "board", "edit", a },
        { env = env_of(home), input = "from standard input\n" }
    )
    testing.eq(code, 0, out)
    out = dev(root, home, { "board", "show", a })
    testing.eq(out, a .. "  Icebox  Unsized  -  Card\n\nfrom standard input\n\nno comments\n")
end)

testing.test(
    "stale does not mark a local needs:human card that only an agent has commented on",
    function()
        local root, home = local_board()
        local a =
            prefix_of((dev(root, home, { "board", "add", "First", "--column", COLUMN.ICEBOX })))
        local out, code = dev(root, home, { "board", "label", a, "needs:human" })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "note", a, "still open" })
        testing.eq(code, 0, out)
        out = dev(root, home, { "board", "stale" })
        testing.ok(out:find("for the owner (needs:human):", 1, true), out)
        testing.ok(not out:find("answered", 1, true), out)
    end
)

testing.test("answer posts the quote and frees a local needs:human card", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "First", "--column", COLUMN.ICEBOX })))
    local out, code = dev(root, home, { "board", "label", a, "needs:human" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "answer", a, "--choice", "2", "--quote", "go ahead" })
    testing.eq(code, 0, out)
    testing.eq(out, "answered " .. a .. " with choice 2\n")
    out = dev(root, home, { "board", "show", a })
    testing.ok(
        out:find("Owner's answer, typed in this session: choice 2, quote: go ahead", 1, true),
        out
    )
    testing.ok(not out:find("needs:human", 1, true), out)
    out, code = dev(root, home, { "board", "answer", a, "--choice", "2", "--quote", "again" })
    testing.eq(code, 1, out)
end)

testing.test("next --column backlog skips a needs:human card", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "First", "--column", COLUMN.ICEBOX })))
    local b = prefix_of((dev(root, home, { "board", "add", "Second", "--column", COLUMN.ICEBOX })))
    local out, code = dev(root, home, { "board", "label", a, "needs:human" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "next", "--column", COLUMN.ICEBOX })
    testing.eq(code, 0, out)
    testing.ok(out:find(b, 1, true) and not out:find(a, 1, true), out)
    out = dev(root, home, { "board", "next", "--column", COLUMN.BACKLOG })
    testing.eq(out, "no cards in Backlog\n")
end)

testing.test("next --column blocked returns the top unclaimed needs:lead card only", function()
    local root, home = local_board()
    local function blocked(name, label)
        local out, code = dev(root, home, {
            "board",
            "add",
            name,
            "--column",
            COLUMN.BLOCKED,
            "--size",
            "1",
            "--problem",
            "x",
            "--done-when",
            "a",
            "--label",
            label,
        })
        testing.eq(code, 0, out)
        return prefix_of(out)
    end
    blocked("Plain", "docs")
    blocked("Human", "needs:human")
    local claimed = blocked("Claimed", "needs:lead")
    local free = blocked("Free", "needs:lead")
    local out, code = dev(root, home, { "board", "take", claimed })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "next", "--column", COLUMN.BLOCKED })
    testing.eq(code, 0, out)
    testing.ok(out:find(free, 1, true) and out:find("Free", 1, true), out)
    out, code = dev(root, home, { "board", "label", free, "needs:human" })
    testing.eq(code, 0, out)
    out = dev(root, home, { "board", "next", "--column", COLUMN.BLOCKED })
    testing.eq(out, "no cards in Blocked\n")
end)

testing.test("rename sets a local card's title and refuses a blank one", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Card", "--problem", "x", "--size", "1", "--done-when", "a" }
            )
        )
    )
    local out, code = dev(root, home, { "board", "rename", a, "Better", "title" })
    testing.eq(code, 0, out)
    testing.eq(out, "renamed " .. a .. "\n")
    testing.eq(document(file_of(home)).cards[1].name, "Better title")
    out, code = dev(root, home, { "board", "rename", a, " " })
    testing.eq(code, 2, out)
    testing.eq(document(file_of(home)).cards[1].name, "Better title")
end)

testing.test("discard notes the reason, labels the card and moves it to Done", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Card", "--problem", "x", "--size", "1", "--done-when", "a" }
            )
        )
    )
    local out, code = dev(root, home, { "board", "discard", a, "--reason", "Not needed" })
    testing.eq(code, 0, out)
    testing.eq(out, "discarded " .. a .. "\n")
    local card = document(file_of(home)).cards[1]
    testing.eq(card.comments[1].kind, "decision")
    testing.eq(card.comments[1].body, "Not needed")
    testing.eq(card.labels[1], "discarded")
    out = dev(root, home, { "board", "ls", "--column", "Done" })
    testing.ok(out:find(a, 1, true), out)
end)

testing.test("discard refuses a needs:human card and writes nothing", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        COLUMN.BLOCKED,
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "a",
    })))
    local out, code = dev(root, home, { "board", "label", a, "needs:human" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "discard", a, "--reason", "Dropped" })
    testing.eq(code, 1, out)
    testing.ok(out:find("needs:human", 1, true), out)
    local card = document(file_of(home)).cards[1]
    testing.eq(#(card.comments or {}), 0)
    testing.eq(card.labels[1], "needs:human")
end)

testing.test("discard closes an unplanned Icebox card given a reason", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Card", "--column", COLUMN.ICEBOX, "--description", "keep" }
            )
        )
    )
    local out, code = dev(root, home, { "board", "discard", a, "--reason", "Answered" })
    testing.eq(code, 0, out)
    testing.eq(out, "discarded " .. a .. "\n")
    local card = document(file_of(home)).cards[1]
    testing.eq(card.comments[1].body, "Answered")
    testing.eq(card.labels[1], "discarded")
    out = dev(root, home, { "board", "ls", "--column", "Done" })
    testing.ok(out:find(a, 1, true), out)
end)

testing.test(
    "discard refuses an unplanned Icebox card without a reason and writes nothing",
    function()
        local root, home = local_board()
        local a = prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", "Card", "--column", COLUMN.ICEBOX, "--description", "keep" }
                )
            )
        )
        local out, code = dev(root, home, { "board", "discard", a })
        testing.eq(code, 1, out)
        testing.ok(out:find("is not planned and cannot be discarded", 1, true), out)
        local card = document(file_of(home)).cards[1]
        testing.eq(#(card.comments or {}), 0)
        testing.eq(#(card.labels or {}), 0)
        out = dev(root, home, { "board", "ls", "--column", COLUMN.ICEBOX })
        testing.ok(out:find(a, 1, true), out)
    end
)

testing.test("discard refuses an unplanned card outside Icebox even with a reason", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        COLUMN.BACKLOG,
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "a",
    })))
    local doc = document(file_of(home))
    doc.cards[1].description = "keep"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    local out, code = dev(root, home, { "board", "discard", a, "--reason", "Dropped" })
    testing.eq(code, 1, out)
    testing.ok(out:find("is not planned and cannot be discarded", 1, true), out)
    local card = document(file_of(home)).cards[1]
    testing.eq(#(card.comments or {}), 0)
    out = dev(root, home, { "board", "ls", "--column", COLUMN.BACKLOG })
    testing.ok(out:find(a, 1, true), out)
end)

testing.test(
    "move to Done waits for every outcome to be ticked, and discard drops an open card",
    function()
        local root, home = local_board()
        local a = prefix_of((dev(root, home, {
            "board",
            "add",
            "Card",
            "--problem",
            "x",
            "--size",
            "1",
            "--done-when",
            "First works",
        })))
        local out, code = dev(root, home, { "board", "move", a, COLUMN.DONE })
        testing.eq(code, 1, out)
        testing.ok(out:find("1 of 1 outcomes are unticked (1. First works)", 1, true), out)
        out, code = dev(root, home, { "board", "outcome", a, "--tick", "1", "--as", "r/reviewer" })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, COLUMN.DONE })
        testing.eq(code, 0, out)
        testing.eq(out, "moved " .. a .. " to Done\n")
        local b = prefix_of((dev(root, home, {
            "board",
            "add",
            "Dropped",
            "--problem",
            "x",
            "--size",
            "1",
            "--done-when",
            "Never works",
        })))
        out, code = dev(root, home, { "board", "discard", b, "--reason", "Not needed" })
        testing.eq(code, 0, out)
        testing.eq(out, "discarded " .. b .. "\n")
        out = dev(root, home, { "board", "ls", "--column", "Done" })
        testing.ok(out:find(b, 1, true), out)
    end
)

testing.test("edit refuses empty text, a missing file and an extra word", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Card", "--column", COLUMN.ICEBOX, "--description", "keep" }
            )
        )
    )
    local out, code = support.dev(
        root,
        { "board", "edit", a },
        { env = env_of(home), input = " \n\n" }
    )
    testing.eq(code, 2, out)
    out, code = dev(root, home, { "board", "edit", a, "--file", root .. "/missing.md" })
    testing.eq(code, 2, out)
    out, code = dev(root, home, { "board", "edit", a, "extra" })
    testing.eq(code, 2, out)
    testing.eq(document(file_of(home)).cards[1].description, "keep")
end)

testing.test("edit is refused under another process's claim fence", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Card", "--column", COLUMN.ICEBOX, "--description", "keep" }
            )
        )
    )
    dev(root, home, { "board", "take", a })
    local doc = document(file_of(home))
    doc.cards[1].claim.fence = 9
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    local out, code = support.dev(
        root,
        { "board", "edit", a },
        { env = env_of(home), input = "new\n" }
    )
    testing.eq(code, 1, out)
    testing.eq(document(file_of(home)).cards[1].description, "keep")
end)

testing.test("show prints a local card's description and notes", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        COLUMN.ICEBOX,
        "--description",
        "why it matters",
    })))
    local out = dev(root, home, { "board", "show", a })
    testing.eq(out, a .. "  Icebox  Unsized  -  Card\n\nwhy it matters\n\nno comments\n")
    dev(root, home, { "board", "note", a, "hello" })
    out = dev(root, home, { "board", "show", a })
    testing.ok(out:find("\n\nwhy it matters\n\n%x+  agent  .-  hello\n$"), out)
end)

testing.test("notes, edit and delete work on a local board and refuse another author's", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Card", "--problem", "x", "--size", "1", "--done-when", "a" }
            )
        )
    )
    local out = dev(root, home, { "board", "note", a, "first", "thought" })
    testing.eq(out, "noted " .. a .. "\n")
    dev(root, home, { "board", "note", a, "second" })
    out = dev(root, home, { "board", "notes", a })
    local first = assert(out:match("^(%x+)"))
    testing.ok(out:find("agent  ", 1, true) and out:find("first thought", 1, true), out)
    local second = assert(out:match("\n(%x+)"))
    out = dev(root, home, { "board", "note", a, "--edit", first, "better", "words" })
    testing.eq(out, "edited " .. a .. " " .. first .. "\n")
    out = dev(root, home, { "board", "note", a, "--delete", second })
    testing.eq(out, "deleted " .. a .. " " .. second .. "\n")
    out = dev(root, home, { "board", "notes", a })
    testing.ok(out:find("better words", 1, true) and not out:find("second", 1, true), out)
    local doc = document(file_of(home))
    doc.cards[1].comments[1].who = "human"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    out = dev(root, home, { "board", "note", a, "--edit", first, "x" })
    testing.eq(out, "dev: that comment is not yours to change\n")
end)

testing.test("note --kind and --as are stored on a local comment and notes prints them", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Card", "--problem", "x", "--size", "1", "--done-when", "a" }
            )
        )
    )
    dev(root, home, { "board", "note", a, "--kind", "decision", "--as", "reviewer", "ship", "it" })
    dev(root, home, { "board", "note", a, "plain" })
    local out = dev(root, home, { "board", "notes", a })
    testing.ok(
        out:find("agent  decision  reviewer  ", 1, true) and out:find("ship it", 1, true),
        out
    )
    testing.ok(out:find("agent  agent     -         ", 1, true), out)
    out = dev(root, home, { "board", "note", a, "--kind", "chatter", "x" })
    testing.ok(out:find("unknown kind chatter", 1, true), out)
    local first = assert(dev(root, home, { "board", "notes", a }):match("^(%x+)"))
    dev(root, home, { "board", "note", a, "--edit", first, "changed" })
    out = dev(root, home, { "board", "notes", a })
    testing.ok(out:find("decision  reviewer  ", 1, true) and out:find("changed", 1, true), out)
end)

testing.test("local escalate swaps the label in one write", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Card", "--problem", "x", "--size", "1", "--done-when", "a" }
            )
        )
    )
    dev(root, home, { "board", "label", a, "+docs", "+needs:planner" })
    local out, code = dev(root, home, { "board", "escalate", a, "pick", "one" })
    testing.eq(code, 0, out)
    testing.eq(out, "escalated " .. a .. " to needs:lead\n")
    local card = document(file_of(home)).cards[1]
    testing.eq(card.labels, { "docs", "needs:lead" })
    testing.eq(#card.comments, 1)
    testing.eq(card.comments[1].kind, "blocked")
    testing.eq(card.comments[1].body, "pick one")
end)

testing.test(
    "link stores blocked_by, blocks and related on a local board and keeps next honest",
    function()
        local root, home = local_board()
        local function add(name)
            return prefix_of((dev(root, home, {
                "board",
                "add",
                name,
                "--column",
                COLUMN.READY,
                "--size",
                "1",
                "--description",
                V1,
                "--checks",
                "dev test",
            })))
        end
        local first, second, third = add("First"), add("Second"), add("Third")
        local out, code = dev(root, home, { "board", "link", first, "blocked_by", second })
        testing.eq(out, "linked " .. first .. " blocked_by " .. second .. "\n")
        testing.eq(code, 0)
        testing.eq(dev(root, home, { "board", "link", first, "blocked_by", second }), out)
        out = dev(root, home, { "board", "link", third, "blocks", second })
        testing.eq(out, "linked " .. third .. " blocks " .. second .. "\n")
        out = dev(root, home, { "board", "link", first, "related", third })
        testing.eq(out, "linked " .. first .. " related " .. third .. "\n")
        local held = {}
        for _, card in ipairs(document(file_of(home)).cards) do
            held[card.id:sub(1, 8)] = card.links
        end
        testing.eq(#held[first], 2)
        testing.eq(held[first][1].kind, "blocked_by")
        testing.eq(held[first][1].target_id:sub(1, 8), second)
        testing.eq(held[first][2].kind, "related")
        testing.eq(#held[second], 1)
        testing.eq(held[second][1].kind, "blocked_by")
        testing.eq(held[second][1].target_id:sub(1, 8), third)
        testing.eq(held[third], nil)
        out = dev(root, home, { "board", "next" })
        testing.ok(out:find("^" .. third), out)
        dev(root, home, { "board", "move", third, COLUMN.DONE })
        out = dev(root, home, { "board", "next" })
        testing.ok(out:find("^" .. second), out)
        dev(root, home, { "board", "move", second, COLUMN.DONE })
        out = dev(root, home, { "board", "next" })
        testing.ok(out:find("^" .. first), out)
    end
)

testing.test(
    "links lists a card's own links and the reverse side of links other cards hold",
    function()
        local root, home = local_board()
        local a = prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", "A", "--problem", "x", "--size", "1", "--done-when", "a" }
                )
            )
        )
        local b = prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", "B", "--problem", "x", "--size", "1", "--done-when", "a" }
                )
            )
        )
        local c = prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", "C", "--problem", "x", "--size", "1", "--done-when", "a" }
                )
            )
        )
        dev(root, home, { "board", "link", a, "blocked_by", b })
        dev(root, home, { "board", "link", a, "related", c })
        local out, code = dev(root, home, { "board", "links", a })
        testing.eq(code, 0, out)
        testing.eq(out, "blocked_by  " .. b .. "  -\nrelated     " .. c .. "  -\n")
        out = dev(root, home, { "board", "links", b })
        testing.eq(out, "blocks  " .. a .. "  -\n")
        out = dev(root, home, { "board", "links", c })
        testing.eq(out, "related  " .. a .. "  -\n")
        dev(root, home, { "board", "link", c, "related", a })
        out = dev(root, home, { "board", "links", c })
        testing.eq(out, "related  " .. a .. "  -\n")
        local d = prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", "D", "--problem", "x", "--size", "1", "--done-when", "a" }
                )
            )
        )
        out = dev(root, home, { "board", "links", d })
        testing.eq(out, "no links\n")
        out, code = dev(root, home, { "board", "links", "deadbeef" })
        testing.eq(code, 1, out)
    end
)

testing.test(
    "unlink removes a link from the card that holds it, and refuses one it lacks",
    function()
        local root, home = local_board()
        local a = prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", "A", "--problem", "x", "--size", "1", "--done-when", "a" }
                )
            )
        )
        local b = prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", "B", "--problem", "x", "--size", "1", "--done-when", "a" }
                )
            )
        )
        local c = prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", "C", "--problem", "x", "--size", "1", "--done-when", "a" }
                )
            )
        )
        dev(root, home, { "board", "link", a, "blocked_by", b })
        dev(root, home, { "board", "link", a, "related", c })
        local out, code = dev(root, home, { "board", "unlink", a, "related", c })
        testing.eq(code, 0, out)
        testing.eq(out, "unlinked " .. a .. " related " .. c .. "\n")
        testing.eq(dev(root, home, { "board", "links", a }), "blocked_by  " .. b .. "  -\n")
        out, code = dev(root, home, { "board", "unlink", c, "related", a })
        testing.eq(code, 1, out)
        out, code = dev(root, home, { "board", "unlink", b, "blocks", a })
        testing.eq(code, 0, out)
        testing.eq(dev(root, home, { "board", "links", a }), "no links\n")
        out, code = dev(root, home, { "board", "unlink", a, "blocked_by", b })
        testing.eq(code, 1, out)
        testing.ok(out:find("the card holds no blocked_by link to " .. b, 1, true), out)
    end
)

testing.test(
    "link refuses itself, a cycle, another board and a bad kind on a local board",
    function()
        local root, home = local_board()
        local a = prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", "A", "--problem", "x", "--size", "1", "--done-when", "a" }
                )
            )
        )
        local b = prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", "B", "--problem", "x", "--size", "1", "--done-when", "a" }
                )
            )
        )
        local c = prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", "C", "--problem", "x", "--size", "1", "--done-when", "a" }
                )
            )
        )
        local out, code = dev(root, home, { "board", "link", a, "related", a })
        testing.eq(code, 1, out)
        testing.ok(out:find("itself", 1, true), out)
        dev(root, home, { "board", "link", a, "blocked_by", b })
        dev(root, home, { "board", "link", b, "blocked_by", c })
        out, code = dev(root, home, { "board", "link", c, "blocked_by", a })
        testing.eq(code, 1, out)
        testing.ok(out:find("wait on each other", 1, true), out)
        out, code = dev(root, home, { "board", "link", a, "blocks", c })
        testing.eq(code, 1, out)
        out, code = dev(root, home, { "board", "link", a, "related", "other:" .. b })
        testing.eq(code, 1, out)
        testing.ok(out:find("links only its own cards", 1, true), out)
        out, code = dev(root, home, { "board", "link", a, "needs", b })
        testing.eq(code, 2, out)
        local links = 0
        for _, card in ipairs(document(file_of(home)).cards) do
            links = links + #(card.links or {})
        end
        testing.eq(links, 2)
    end
)

testing.test("a local board refuses what the needs:human and epic rules forbid", function()
    local root, home = local_board()
    local function add(name)
        return prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", name, "--problem", "x", "--size", "1", "--done-when", "a" }
                )
            )
        )
    end
    local card, child = add("Card"), add("Child")
    local epic = prefix_of((dev(root, home, {
        "board",
        "add",
        "Epic",
        "--size",
        "2",
        "--description",
        V1,
        "--checks",
        "dev test",
    })))
    local out, code = dev(root, home, { "board", "label", card, "needs:human" })
    testing.eq(code, 1, out)
    testing.ok(out:find("Blocked or Icebox", 1, true), out)
    dev(root, home, { "board", "move", card, COLUMN.BLOCKED })
    out, code = dev(root, home, { "board", "label", card, "needs:human" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", card, COLUMN.BACKLOG })
    testing.eq(code, 1, out)
    testing.ok(out:find("needs:human", 1, true), out)
    assert(fs.write(root .. "/plan.md", "new text\n"))
    out, code = dev(root, home, { "board", "edit", card, "--file", root .. "/plan.md" })
    testing.eq(code, 1, out)
    testing.ok(out:find("needs:human", 1, true), out)
    out, code = dev(root, home, { "board", "note", card, "still allowed" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "label", card, "--remove", "needs:human" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", card, COLUMN.BACKLOG })
    testing.eq(code, 0, out)
    dev(root, home, { "board", "epic", epic })
    dev(root, home, { "board", "link", child, "parent", epic })
    out, code = dev(root, home, { "board", "move", epic, COLUMN.READY })
    testing.eq(code, 0, out)
end)

testing.test("link parent sets one epic and show and links report it", function()
    local root, home = local_board()
    local function add(name)
        return prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", name, "--problem", "x", "--size", "1", "--done-when", "a" }
                )
            )
        )
    end
    local epic, one, two, other = add("Epic"), add("One"), add("Two"), add("Other")
    dev(root, home, { "board", "epic", epic })
    dev(root, home, { "board", "epic", one })
    dev(root, home, { "board", "epic", other })
    local out, code = dev(root, home, { "board", "link", one, "parent", epic })
    testing.eq(out, "linked " .. one .. " parent " .. epic .. "\n")
    testing.eq(code, 0)
    testing.eq(dev(root, home, { "board", "link", one, "parent", epic }), out)
    dev(root, home, { "board", "link", two, "parent", epic })
    out, code = dev(root, home, { "board", "link", one, "parent", other })
    testing.eq(code, 1, out)
    testing.ok(out:find("already has an epic", 1, true), out)
    out, code = dev(root, home, { "board", "link", other, "parent", one })
    testing.eq(code, 0, out)
    out = dev(root, home, { "board", "show", one })
    testing.ok(out:find("\nchildren: 0 of 1 done\n", 1, true), out)
    out, code = dev(root, home, { "board", "link", epic, "parent", other })
    testing.eq(code, 1, out)
    testing.ok(out:find("cycle of epics", 1, true), out)
    testing.ok(out:find(epic, 1, true) and out:find(other, 1, true), out)
    out, code = dev(root, home, { "board", "link", epic, "parent", epic })
    testing.eq(code, 1, out)
    out = dev(root, home, { "board", "show", one })
    testing.ok(out:find("\nparent: " .. epic .. " Epic\n", 1, true), out)
    out = dev(root, home, { "board", "show", epic })
    testing.ok(out:find("\nchildren: 0 of 2 done\n", 1, true), out)
    tick_first(root, home, one)
    out, code = dev(root, home, { "board", "move", one, COLUMN.DONE })
    testing.eq(code, 1, out)
    testing.ok(out:find("1 of 1 children are open", 1, true), out)
    tick_first(root, home, other)
    dev(root, home, { "board", "move", other, COLUMN.DONE })
    out, code = dev(root, home, { "board", "move", one, COLUMN.DONE })
    testing.eq(code, 0, out)
    out = dev(root, home, { "board", "show", epic })
    testing.ok(out:find("\nchildren: 1 of 2 done\n", 1, true), out)
    out = dev(root, home, { "board", "links", one })
    testing.ok(out:find("parent", 1, true) and out:find(epic, 1, true), out)
    out = dev(root, home, { "board", "links", epic })
    testing.ok(out:find("child", 1, true) and out:find(one, 1, true), out)
end)

testing.test("stale counts the days a card sat in its column", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Old",
        "--column",
        COLUMN.READY,
        "--size",
        "1",
        "--description",
        V1,
        "--checks",
        "dev test",
    })))
    prefix_of((dev(root, home, {
        "board",
        "add",
        "New",
        "--column",
        COLUMN.READY,
        "--size",
        "1",
        "--description",
        V1,
        "--checks",
        "dev test",
    })))
    local doc = document(file_of(home))
    doc.cards[1].entered_at = "2020-01-01T00:00:00Z"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    local out = dev(root, home, { "board", "stale" })
    testing.ok(out:find(a .. "  Ready  ", 1, true) and out:find("Old", 1, true), out)
    testing.ok(not out:find("New", 1, true), out)
end)

testing.test("a local board keeps an unsized or red card out of Ready", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Loose",
        "--column",
        COLUMN.ICEBOX,
        "--description",
        V1,
        "--checks",
        "dev test",
    })))
    local out, code = dev(root, home, { "board", "move", a, COLUMN.READY })
    testing.eq(code, 1)
    testing.ok(out:find("dev board size", 1, true), out)
    out, code = dev(root, home, { "board", "move", a, COLUMN.BACKLOG })
    testing.eq(code, 1)
    testing.ok(out:find("a size", 1, true), out)
    out, code = dev(root, home, { "board", "add", "Direct", "--column", COLUMN.READY })
    testing.eq(code, 2)
    out, code = dev(root, home, { "board", "add", "Direct", "--problem", "x" })
    testing.eq(code, 2)
    testing.ok(out:find("a size", 1, true), out)
    dev(root, home, { "board", "size", a, "3+" })
    out, code = dev(root, home, { "board", "move", a, COLUMN.READY })
    testing.eq(code, 1)
    testing.ok(out:find("red", 1, true), out)
    dev(root, home, { "board", "size", a, "2" })
    out, code = dev(root, home, { "board", "move", a, COLUMN.READY })
    testing.eq(code, 0, out)
    testing.eq(dev(root, home, { "board", "stale" }), "no stale cards\n")
end)

testing.test(
    "a local board scaffolds the v2 headings and keeps a card without them out of Ready",
    function()
        local root, home = local_board()
        local a = prefix_of((dev(root, home, {
            "board",
            "add",
            "Plain",
            "--column",
            COLUMN.ICEBOX,
            "--problem",
            "x",
            "--size",
            "1",
            "--checks",
            "dev test",
        })))
        testing.eq(
            document(file_of(home)).cards[1].description,
            "## Problem\nx\n\n## Change\n\n## Out of scope\n"
        )
        local out, code = dev(root, home, { "board", "move", a, COLUMN.READY })
        testing.eq(code, 1)
        testing.ok(out:find("3 to 7 Done when outcomes", 1, true), out)
        out, code =
            dev(root, home, { "board", "add", "Direct", "--column", COLUMN.READY, "--size", "1" })
        testing.eq(code, 2)
        testing.ok(out:find("card format v2", 1, true), out)
        local ice =
            prefix_of((dev(root, home, { "board", "add", "Loose", "--column", COLUMN.ICEBOX })))
        out = dev(root, home, { "board", "show", ice })
        testing.ok(out:find("no description", 1, true), out)
        local file = root .. "/v1.md"
        assert(fs.write(file, V1))
        out, code = dev(root, home, { "board", "edit", a, "--file", file })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, COLUMN.READY })
        testing.eq(code, 0, out)
    end
)

testing.test("a local board keeps --done-when outcomes on the card and shows them", function()
    local root, home = local_board()
    local out, code = dev(root, home, {
        "board",
        "add",
        "Card",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "A works",
        "--done-when",
        "B works",
    })
    testing.eq(code, 0, out)
    local a = prefix_of(out)
    local outcomes = document(file_of(home)).cards[1].outcomes
    testing.eq(#outcomes, 2)
    testing.eq(outcomes[1].name, "A works")
    testing.eq(outcomes[1].done, false)
    out = dev(root, home, { "board", "show", a })
    testing.ok(out:find("done when:\n- [ ] A works\n- [ ] B works\n", 1, true), out)
    out = dev(root, home, { "board", "ls" })
    testing.ok(out:find("0/2", 1, true), out)
end)

testing.test("a local board appends, rewords, ticks and unticks outcomes by number", function()
    local root, home = local_board()
    local out, code = dev(root, home, {
        "board",
        "add",
        "Card",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "A works",
        "--done-when",
        "B works",
    })
    testing.eq(code, 0, out)
    local a = prefix_of(out)
    out, code = dev(root, home, { "board", "outcome", a, "C works" })
    testing.eq(out, "outcome " .. a .. " 3 added\n")
    out = dev(root, home, { "board", "outcome", a, "--tick", "2" })
    testing.eq(out, "outcome " .. a .. " 2 ticked\n")
    out = dev(
        root,
        home,
        { "board", "outcome", a, "--rename", "1", "A holds", "--reason", "clearer" }
    )
    testing.eq(out, "outcome " .. a .. " 1 reworded\n")
    out = dev(root, home, { "board", "show", a })
    testing.ok(out:find("done when:\n- [ ] A holds\n- [x] B works\n- [ ] C works\n", 1, true), out)
    out = dev(root, home, { "board", "outcome", a, "--untick", "2" })
    testing.eq(out, "outcome " .. a .. " 2 unticked\n")
    local rows = document(file_of(home)).cards[1].outcomes
    testing.eq(#rows, 3)
    testing.eq(rows[1].name, "A holds")
    testing.eq(rows[2].done, false)
    testing.eq(rows[2].name, "B works")
    out, code = dev(root, home, { "board", "outcome", a, "--tick", "4" })
    testing.eq(code, 1)
    testing.ok(out:find("the card has 3 outcomes, so there is no outcome 4", 1, true), out)
end)

testing.test(
    "a local board lets only the lead delete an outcome, renumbers and keeps its text in a note",
    function()
        local root, home = local_board()
        local out, code = dev(root, home, {
            "board",
            "add",
            "Card",
            "--problem",
            "x",
            "--size",
            "1",
            "--done-when",
            "A works",
            "--done-when",
            "B works",
            "--done-when",
            "C works",
        })
        testing.eq(code, 0, out)
        local a = prefix_of(out)
        local lead = { DEV_AGENT = "dotfiles/lead/1" }
        out, code = dev(root, home, { "board", "outcome", a, "--delete", "2" }, lead)
        testing.eq(code, 2, out)
        out, code = dev(
            root,
            home,
            { "board", "outcome", a, "--delete", "2", "--reason", "never possible" },
            { DEV_AGENT = "dotfiles/implementer/95f0e009/1" }
        )
        testing.eq(code, 1, out)
        testing.ok(out:find("only the lead deletes an outcome", 1, true), out)
        testing.eq(#document(file_of(home)).cards[1].outcomes, 3)
        out, code = dev(
            root,
            home,
            { "board", "outcome", a, "--delete", "2", "--reason", "never possible" },
            lead
        )
        testing.eq(code, 0, out)
        testing.eq(out, "outcome " .. a .. " 2 deleted\n")
        local card = document(file_of(home)).cards[1]
        testing.eq(#card.outcomes, 2)
        testing.eq(card.outcomes[1].name, "A works")
        testing.eq(card.outcomes[2].name, "C works")
        local note = card.comments[#card.comments]
        testing.eq(note.kind, "decision")
        testing.eq(note.body, "Deleted outcome 2: B works Reason: never possible")
    end
)

testing.test("outcome delete on a local board needs no lead token", function()
    local root, home = local_board()
    local out, code = dev(root, home, {
        "board",
        "add",
        "Card",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "A works",
        "--done-when",
        "B works",
    })
    testing.eq(code, 0, out)
    local a = prefix_of(out)
    testing.eq(fs.read(home .. "/.config/dev/config.toml"):find("lead_token", 1, true), nil)
    out, code = dev(
        root,
        home,
        { "board", "outcome", a, "--delete", "1", "--reason", "never possible" },
        { DEV_AGENT = "dotfiles/lead/1" }
    )
    testing.eq(code, 0, out)
    testing.eq(out, "outcome " .. a .. " 1 deleted\n")
    testing.eq(#document(file_of(home)).cards[1].outcomes, 1)
end)

testing.test("outcome delete refuses from Ready on on a local board", function()
    local root, home = local_board()
    local out, code = dev(root, home, {
        "board",
        "add",
        "Card",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "A works",
        "--done-when",
        "B works",
        "--done-when",
        "C works",
        "--change",
        "y",
        "--out-of-scope",
        "z",
        "--checks",
        "dev test",
    })
    testing.eq(code, 0, out)
    local a = prefix_of(out)
    local lead = { DEV_AGENT = "dotfiles/lead/1" }
    out, code = dev(root, home, { "board", "move", a, COLUMN.READY }, lead)
    testing.eq(code, 0, out)
    out, code = dev(
        root,
        home,
        { "board", "outcome", a, "--delete", "1", "--reason", "never possible" },
        lead
    )
    testing.eq(code, 1, out)
    testing.ok(out:find("Ready", 1, true) and out:find("fixed from Ready on", 1, true), out)
    testing.eq(#document(file_of(home)).cards[1].outcomes, 3)
end)

testing.test("a local board converts a v1 checklist into outcomes and ticks", function()
    local root, home = local_board()
    local v1 =
        "## Problem\nP\n\n## Change\nC\n\n## Done when\n- [ ] A works\n- [x] B works\n- [ ] C works\n\n## Out of scope\nNone\n"
    local out, code = dev(root, home, { "board", "add", "Old", "--description", v1, "--size", "1" })
    testing.eq(code, 0, out)
    local a = prefix_of(out)
    out, code = dev(root, home, { "board", "outcome", a, "--convert" })
    testing.eq(code, 0, out)
    testing.eq(out, "outcome " .. a .. " converted 3 outcomes\n")
    local card = document(file_of(home)).cards[1]
    testing.eq(#card.outcomes, 3)
    testing.eq(card.outcomes[1].name, "A works")
    testing.eq(card.outcomes[1].done, false)
    testing.eq(card.outcomes[2].done, true)
    testing.eq(card.outcomes[3].done, false)
    testing.ok(not card.description:find("Done when", 1, true), card.description)
    testing.ok(
        card.description:find("## Problem\nP\n\n## Change\nC\n\n## Out of scope\nNone", 1, true),
        card.description
    )
    out, code = dev(root, home, { "board", "outcome", a, "--convert" })
    testing.eq(code, 0, out)
    testing.eq(out, "outcome " .. a .. " left alone: it already has outcomes\n")
    testing.eq(#document(file_of(home)).cards[1].outcomes, 3)
end)

testing.test("outcome --convert leaves a card with no checklist alone", function()
    local root, home = local_board()
    local a = prefix_of(
        (dev(root, home, { "board", "add", "Plain", "--column", COLUMN.ICEBOX, "--problem", "x" }))
    )
    local out, code = dev(root, home, { "board", "outcome", a, "--convert" })
    testing.eq(code, 0, out)
    testing.eq(out, "outcome " .. a .. " left alone: it has no Done when checklist\n")
    out, code = dev(root, home, { "board", "outcome", a, "--convert", "extra" })
    testing.eq(code, 2)
end)

testing.test("a local board ticks an outcome while this machine holds the claim", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "A works",
    })))
    local out, code = dev(root, home, { "board", "take", a })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "outcome", a, "--tick", "1" })
    testing.eq(code, 2, out)
    testing.eq(document(file_of(home)).cards[1].outcomes[1].done, false)
    out, code = dev(root, home, { "board", "outcome", a, "--tick", "1", "--as", "r/reviewer" })
    testing.eq(code, 0, out)
    testing.eq(document(file_of(home)).cards[1].outcomes[1].done, true)
end)

local function card_named(doc, name)
    for _, card in ipairs(doc.cards) do
        if card.name == name then
            return card
        end
    end
end

testing.test(
    "take --as and move into progress name the holder, and an epic is claimed like any card",
    function()
        local root, home = local_board()
        local function ready(name)
            return prefix_of((dev(root, home, {
                "board",
                "add",
                name,
                "--column",
                COLUMN.READY,
                "--size",
                "1",
                "--description",
                V1,
                "--checks",
                "dev test",
            })))
        end
        local a, b, c = ready("Alpha"), ready("Beta"), ready("Gamma")
        local out, code = dev(root, home, { "board", "take", a, "--as", "r/one" })
        testing.eq(code, 0, out)
        testing.eq(card_named(document(file_of(home)), "Alpha").claim.claimant, "r/one")
        _, code = dev(root, home, { "board", "take", b, "--as", "bad name" })
        testing.eq(code, 2)
        out, code = dev(
            root,
            home,
            { "board", "move", b, COLUMN.PROGRESS },
            { DEV_AGENT = "r/two" }
        )
        testing.eq(code, 0, out)
        testing.eq(card_named(document(file_of(home)), "Beta").claim.claimant, "r/two")
        out = dev(root, home, { "board", "ls" })
        testing.ok(out:find("r/two", 1, true), out)
        dev(root, home, { "board", "epic", a })
        dev(root, home, { "board", "link", c, "parent", a })
        out, code = dev(
            root,
            home,
            { "board", "move", a, COLUMN.PROGRESS },
            { DEV_AGENT = "r/three" }
        )
        testing.eq(code, 0, out)
        testing.eq(card_named(document(file_of(home)), "Alpha").claim.claimant, "r/one")
        dev(root, home, { "board", "release", a })
        out, code = dev(
            root,
            home,
            { "board", "move", a, COLUMN.PROGRESS },
            { DEV_AGENT = "r/three" }
        )
        testing.eq(code, 0, out)
        testing.eq(card_named(document(file_of(home)), "Alpha").claim.claimant, "r/three")
    end
)

testing.test("move out of progress releases the claim and warns about nothing", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        COLUMN.READY,
        "--size",
        "1",
        "--description",
        V1,
        "--checks",
        "dev test",
    })))
    dev(root, home, { "board", "take", a })
    testing.ok(document(file_of(home)).cards[1].claim ~= nil, "claim held")
    dev(root, home, { "board", "note", a, "built it, tried it, learned it" })
    local out, code = dev(root, home, { "board", "move", a, COLUMN.REVIEW })
    testing.eq(code, 0, out)
    testing.eq(out, "moved " .. a .. " to Review\n")
    testing.eq(document(file_of(home)).cards[1].claim, nil)
end)

testing.test(
    "move out of progress waits for a note of what was built, tried and learned",
    function()
        local root, home = local_board()
        local a = prefix_of((dev(root, home, {
            "board",
            "add",
            "Card",
            "--column",
            COLUMN.READY,
            "--size",
            "1",
            "--description",
            V1,
            "--checks",
            "dev test",
        })))
        dev(root, home, { "board", "take", a })
        dev(root, home, { "board", "move", a, COLUMN.PROGRESS })
        for _, column in ipairs({ COLUMN.REVIEW, COLUMN.READY, COLUMN.BLOCKED }) do
            local out, code = dev(root, home, { "board", "move", a, column })
            testing.eq(code, 1, out)
            testing.ok(out:find("built, tried and learned", 1, true), out)
            testing.ok(document(file_of(home)).cards[1].claim ~= nil, "claim kept")
        end
        dev(root, home, { "board", "note", a, "--kind", "decision", "ruled" })
        local out, code = dev(root, home, { "board", "move", a, COLUMN.REVIEW })
        testing.eq(code, 1, out)
        out, code = dev(root, home, { "board", "note", a, "built, tried, learned" })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, COLUMN.REVIEW })
        testing.eq(code, 0, out)
        testing.eq(document(file_of(home)).cards[1].claim, nil)
    end
)

testing.test("a second claim needs a fresh note of what was built, tried and learned", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        COLUMN.READY,
        "--size",
        "1",
        "--description",
        V1,
        "--checks",
        "dev test",
    })))
    dev(root, home, { "board", "take", a })
    dev(root, home, { "board", "move", a, COLUMN.PROGRESS })
    dev(root, home, { "board", "note", a, "built, tried, learned" })
    local out, code = dev(root, home, { "board", "move", a, COLUMN.READY })
    testing.eq(code, 0, out)
    dev(root, home, { "board", "take", a })
    dev(root, home, { "board", "move", a, COLUMN.PROGRESS })
    out, code = dev(root, home, { "board", "move", a, COLUMN.REVIEW })
    testing.eq(code, 1, out)
    testing.ok(out:find("built, tried and learned", 1, true), out)
end)

testing.test("take holds a claim with an expiry and no loop, and release gives it up", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        COLUMN.READY,
        "--size",
        "1",
        "--description",
        V1,
        "--checks",
        "dev test",
    })))
    local out, code = dev(root, home, { "board", "take", a })
    testing.eq(code, 0, out)
    testing.eq(out:find("took " .. a .. ", fence 1, held for 50m\n\n", 1, true), 1, out)
    local doc = document(file_of(home))
    testing.eq(doc.cards[1].claim.fence, 1)
    testing.ok(
        doc.cards[1].claim.expires_at > os.date("!%Y-%m-%dT%H:%M:%SZ"),
        "expiry in the future"
    )
    out = dev(root, home, { "board", "ls" })
    testing.ok(out:find("dev@", 1, true), out)
    out = dev(root, home, { "board", "next" })
    testing.eq(out, "no ready cards\n")
    out, code = dev(root, home, { "board", "take", a }, { CLAUDE_SESSION_ID = "other" })
    testing.eq(code, 1)
    testing.ok(out:find("is claimed by dev@", 1, true), out)
    out = dev(root, home, { "board", "take", a })
    testing.eq(out:find("took " .. a .. ", fence 1, held for 50m\n\n", 1, true), 1, out)
    out = dev(root, home, { "board", "release", a })
    testing.eq(out, "released " .. a .. ", fence 1\n")
    out = dev(root, home, { "board", "next" })
    testing.ok(out:find("Card", 1, true), out)
    out = dev(root, home, { "board", "take", a }, { CLAUDE_SESSION_ID = "other" })
    testing.eq(out:find("took " .. a .. ", fence 2, held for 50m\n\n", 1, true), 1, out)
end)

testing.test("a stale fence is refused once another process holds the claim", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Card", "--problem", "x", "--size", "1", "--done-when", "a" }
            )
        )
    )
    dev(root, home, { "board", "take", a })
    local doc = document(file_of(home))
    doc.cards[1].claim.fence = 9
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    local out, code = dev(root, home, { "board", "note", a, "hello" })
    testing.eq(code, 1)
    testing.ok(out:find("is held by dev@", 1, true) and out:find("fence 9", 1, true), out)
end)

testing.test("an expired claim does not block the card", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        COLUMN.READY,
        "--size",
        "1",
        "--description",
        V1,
        "--checks",
        "dev test",
    })))
    dev(root, home, { "board", "take", a })
    local doc = document(file_of(home))
    doc.cards[1].claim.expires_at = "2020-01-01T00:00:00Z"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    local out = dev(root, home, { "board", "next" })
    testing.ok(out:find("Card", 1, true), out)
    out = dev(root, home, { "board", "note", a, "still works" })
    testing.eq(out, "noted " .. a .. "\n")
end)

testing.test("a tracked path keeps the board in the project, readable by everyone", function()
    local root, home = local_board('[board]\nbackend = "local"\npath = ".dev/board.json"\n')
    local out = dev(
        root,
        home,
        { "board", "add", "Tracked", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    prefix_of(out)
    testing.ok(fs.exists(root .. "/.dev/board.json"))
    testing.eq(fs.exists(home .. "/state/dev/boards/mine.json"), false)
    testing.eq(document(root .. "/.dev/board.json").cards[1].name, "Tracked")
    testing.ok(mode(root .. "/.dev/board.json") ~= "600", "not private")
    local text = assert(fs.read(root .. "/.dev/board.json"))
    testing.ok(select(2, text:gsub("\n", "")) > 4, "one line per card")
end)

testing.test("a path outside the project, or on a pomb board, is refused", function()
    for _, path in ipairs({ "../board.json", "/etc/board.json", "a//b.json", ".dev/../x.json" }) do
        local root, home = setup('[board]\nbackend = "local"\npath = "' .. path .. '"\n')
        local out, code = dev(root, home, { "board", "ls" })
        testing.eq(code, 1, path)
        testing.ok(out:find("[board] path must be a relative path", 1, true), out)
    end
    local root, home = setup('[board]\nbackend = "pomb"\npath = ".dev/board.json"\n')
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find('path only applies to backend = "local"', 1, true), out)
end)

testing.test("a local board's name has to make a file name unless a path is set", function()
    local root, home = setup('[board]\nbackend = "local"\nname = "a/b"\n')
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find("name must be letters, digits", 1, true), out)
end)

testing.test("init refuses --admin on a local board and a different --name", function()
    local root, home = setup('[board]\nbackend = "local"\nname = "mine"\n')
    local out, code = dev(root, home, { "board", "init", "--admin" })
    testing.eq(code, 2, out)
    out, code = dev(root, home, { "board", "init", "--name", "other" })
    testing.eq(code, 2, out)
end)

testing.test("sync on a local board says there is nothing to sync", function()
    local root, home = local_board()
    local out, code = dev(root, home, { "board", "sync" })
    testing.eq(code, 1)
    testing.eq(out, "dev: a local board has nothing to sync\n")
end)

testing.test("wait on a local board says there is nothing to wait on", function()
    local root, home = local_board()
    local out, code = dev(root, home, { "board", "wait", "--for", COLUMN.READY })
    testing.eq(code, 1)
    testing.eq(out, "dev: a local board has nothing to wait on\n")
end)

testing.test("six processes writing at once lose no card", function()
    local root, home = local_board()
    local script = string.format(
        'for i in 1 2 3 4 5 6; do luajit %s board add "card $i" --problem x --size 1 --done-when a & done; wait',
        dev_os.quote(MAIN)
    )
    local out, code = dev_os.capture({ "sh", "-c", script }, {
        cwd = root,
        stderr = "stdout",
        env = {
            HOME = home,
            XDG_STATE_HOME = home .. "/state",
            PATH = root .. "/bin:" .. os.getenv("PATH"),
            DEV_SELF = REPO .. "/dotfiles/bin/.local/bin/dev",
        },
    })
    testing.eq(code, 0, out)
    local doc = document(file_of(home))
    testing.eq(#doc.cards, 6)
    local ids = {}
    for _, card in ipairs(doc.cards) do
        ids[card.id] = true
    end
    local count = 0
    for _ in pairs(ids) do
        count = count + 1
    end
    testing.eq(count, 6)
    testing.eq(fs.list(home .. "/state/dev/boards"), { "mine.json", "mine.json.lock" })
end)

testing.test("six simultaneous run --orders calls leave one open run card", function()
    local root, home = local_board()
    local script = string.format(
        'for i in 1 2 3 4 5 6; do luajit %s board run --orders "go" 2>&1 || echo "exit $?" & done; wait',
        dev_os.quote(MAIN)
    )
    local out, code = dev_os.capture({ "sh", "-c", script }, {
        cwd = root,
        stderr = "stdout",
        env = {
            HOME = home,
            XDG_STATE_HOME = home .. "/state",
            DEV_AGENT = "dotfiles/one",
            PATH = root .. "/bin:" .. os.getenv("PATH"),
            DEV_SELF = REPO .. "/dotfiles/bin/.local/bin/dev",
        },
    })
    testing.eq(code, 0, out)
    local runs = 0
    for _, card in ipairs(document(file_of(home)).cards) do
        if #card.labels > 0 then
            runs = runs + 1
        end
    end
    testing.eq(runs, 1, out)
    local losers = select(2, out:gsub("already has the run card", ""))
    testing.eq(losers, 5, out)
    local failed = select(2, out:gsub("exit 1", ""))
    testing.eq(failed, 5, out)
end)

local BOARDS = '[{"id":"board-1","name":"dotfiles","archived":false}]'
local DETAIL = '{"id":"board-1","name":"dotfiles","columns":['
    .. '{"id":"col-backlog","name":"Backlog"},{"id":"col-ready","name":"Ready"},'
    .. '{"id":"col-review","name":"Review"},{"id":"col-done","name":"Done"}]}'
local COLORS = '[{"id":"yellow-id","value":"yellow","label":"1 Pomodoro"},'
    .. '{"id":"blue-id","value":"blue","label":"3 Pomodori"},'
    .. '{"id":"white-id","value":"white","label":"Unsized"}]'
local EXPORT = '{"tasks":[{"id":"'
    .. ID_A
    .. '","name":"First","column_id":"col-ready","position":1,"color_id":null,"labels":[]},'
    .. '{"id":"'
    .. ID_B
    .. '","name":"Second","column_id":"col-ready","position":2,"color_id":null,"labels":[]}]}'

local PLANNED_EXPORT = (
    EXPORT:gsub(
        '"position":1,"color_id":null,"labels":%[%]',
        '"position":1,"color_id":"yellow-id","labels":[],"description":"## Problem\\nx\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone\\n\\n## Done when\\n- [ ] a"',
        1
    )
)

local CURL = [[#!/bin/sh
cat >"$ROOT/stdin"
if [ -f "$ROOT/down" ]; then exit 7; fi
if [ -f "$ROOT/gateway" ]; then printf '<html>bad gateway</html>\n502'; exit 0; fi
method=GET
prev=
for arg; do
    if [ "$prev" = -X ]; then method=$arg; fi
    if [ "$prev" = --data-raw ]; then printf "%s\n" "$arg" >>"$ROOT/bodies"; fi
    prev=$arg
done
for last; do :; done
printf '%s %s\n' "$method" "$last" >>"$ROOT/calls"
if [ "$method" = PATCH ] && [ -f "$ROOT/held" ]; then printf '{"code":"claim_held","message":"the card holds a live claim"}\n409'; exit 0; fi
status=200
case "$last" in
*/api/boards) body=$(cat "$ROOT/boards.json") ;;
*/api/boards/board-1) body=$(cat "$ROOT/detail.json") ;;
*/colors) body=$(cat "$ROOT/colors.json") ;;
*/fields) body=$(cat "$ROOT/fields.json") ;;
*/export-data) body=$(cat "$ROOT/export.json") ;;
*/api/tasks/aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa) body='{"id":"aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa","parent":{"id":"bbbbbbbb-1111-4bbb-8bbb-bbbbbbbbbbbb","name":"Epic"},"children_done":1,"children_total":3}' ;;
*/tasks\?*) body=$(cat "$ROOT/page.json") ;;
*/api/tasks/cccccccc-2222-4ccc-8ccc-cccccccccccc) body=$(cat "$ROOT/big.json") ;;
*/api/tasks/dddddddd-2222-4ddd-8ddd-dddddddddddd) body=$(cat "$ROOT/small.json") ;;
*/api/tasks) body='{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","name":"x","column_id":"col-backlog"}' ;;
*) body='{"ok":true}' ;;
esac
printf '%s\n%s' "$body" "$status"
]]

local function pomb(opts)
    opts = opts or {}
    local root, home = setup('[board]\nbackend = "pomb"\nname = "dotfiles"\n')
    for name, body in pairs({
        ["boards.json"] = BOARDS,
        ["detail.json"] = DETAIL,
        ["colors.json"] = COLORS,
        ["export.json"] = EXPORT,
        ["fields.json"] = support.FIELDS,
    }) do
        assert(fs.write(root .. "/" .. name, body))
    end
    assert(fs.write(root .. "/bin/curl", CURL))
    assert(dev_os.run({ "chmod", "755", root .. "/bin/curl" }) == 0, "chmod failed")
    assert(
        fs.write(
            root .. "/bin/pass",
            "#!/bin/sh\n" .. (opts.locked and "exit 1\n" or ('echo "' .. TOKEN .. '"\n'))
        )
    )
    assert(dev_os.run({ "chmod", "755", root .. "/bin/pass" }) == 0, "chmod failed")
    return root, home
end

local function pomb_dev(root, home, args)
    return dev(root, home, args, { ROOT = root })
end

local function queue_path(home)
    return home .. "/state/dev/boards/dotfiles.queue"
end

local function calls(root)
    return fs.read(root .. "/calls") or ""
end

local QUEUED = "queued: Pomb unreachable, will sync\n"

testing.test("writes while Pomb is unreachable are queued and the queue is private", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), COLUMN.REVIEW })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
    out = pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "kept", "words" })
    testing.eq(out, QUEUED)
    out = pomb_dev(root, home, {
        "board",
        "add",
        "Later",
        "--problem",
        "x",
        "--size",
        "2",
        "--done-when",
        "a",
        "--label",
        "docs",
    })
    testing.eq(out, QUEUED)
    out = pomb_dev(root, home, { "board", "size", ID_B:sub(1, 8), "3" })
    testing.eq(out, QUEUED)
    out = pomb_dev(root, home, { "board", "label", ID_B:sub(1, 8), "+x" })
    testing.eq(out, QUEUED)
    local entries = document(queue_path(home))
    testing.eq(#entries, 5)
    testing.eq(entries[1].sub, "move")
    testing.eq(entries[1].args, { ID_A:sub(1, 8), COLUMN.REVIEW })
    testing.eq(entries[2].args, { ID_A:sub(1, 8), "kept", "words" })
    testing.eq(entries[3].sub, "add")
    testing.eq(mode(queue_path(home)), "600")
    testing.eq(mode(home .. "/state/dev/boards"), "700")
    testing.ok(not assert(fs.read(queue_path(home))):find(TOKEN, 1, true), "no token in the queue")
    testing.eq(calls(root), "")
end)

testing.test("a queued note keeps its kind and role", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local args = { ID_A:sub(1, 8), "--kind", "decision", "--as", "reviewer", "kept" }
    testing.eq(pomb_dev(root, home, { "board", "note", unpack(args) }), QUEUED)
    testing.eq(document(queue_path(home))[1].args, args)
end)

testing.test("a queued discard replays its move without the outcome check", function()
    local root, home = pomb()
    assert(
        fs.write(
            root .. "/export.json",
            '{"tasks":[{"id":"'
                .. ID_A
                .. '","name":"First","column_id":"col-ready","position":1,"color_id":"yellow-id","labels":[],"description":"## Problem\\nx\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone","subtasks":[{"id":"s1","name":"Never works","done":false}]}]}'
        )
    )
    assert(
        fs.write(
            root .. "/bin/curl",
            '#!/bin/sh\nfor last; do :; done\ncase "$last" in */api/tasks/*) cat >/dev/null; exit 7 ;; esac\n'
                .. CURL:gsub("^#!/bin/sh\n", "")
        )
    )
    assert(dev_os.run({ "chmod", "755", root .. "/bin/curl" }) == 0, "chmod failed")
    local out, code =
        pomb_dev(root, home, { "board", "discard", ID_A:sub(1, 8), "--reason", "Dropped" })
    testing.eq(code, 0, out)
    testing.eq(out, QUEUED)
    assert(fs.write(root .. "/bin/curl", CURL))
    assert(dev_os.run({ "chmod", "755", root .. "/bin/curl" }) == 0, "chmod failed")
    out, code = pomb_dev(root, home, { "board", "sync" })
    testing.eq(code, 0, out)
    testing.ok(out:find("synced discard_move aaaaaaaa", 1, true), out)
    testing.ok(calls(root):find("/move", 1, true), calls(root))
end)

testing.test("a move to Done is refused and not queued while Pomb is unreachable", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), COLUMN.DONE })
    testing.eq(code, 1, out)
    testing.ok(out:find("board unavailable", 1, true), out)
    testing.eq(fs.exists(queue_path(home)), false)
end)

testing.test("after a gateway error only a change that is safe to repeat is queued", function()
    local root, home = pomb()
    assert(fs.write(root .. "/gateway", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), COLUMN.REVIEW })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
    out, code = pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "once" })
    testing.eq(code, 1, out)
    out, code = pomb_dev(
        root,
        home,
        { "board", "add", "Once", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    testing.eq(code, 1, out)
    testing.eq(#document(queue_path(home)), 1)
end)

testing.test("a hand-edited board file keeps its other keys and gets its name back", function()
    local root, home = local_board()
    local doc = document(file_of(home))
    doc.name = nil
    doc.note = "kept"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    dev(root, home, { "board", "add", "One", "--problem", "x", "--size", "1", "--done-when", "a" })
    doc = document(file_of(home))
    testing.eq(doc.note, "kept")
    testing.eq(doc.name, "mine")
end)

testing.test("a tracked board leaves no lock file in the project", function()
    local root, home = local_board('[board]\nbackend = "local"\npath = ".dev/board.json"\n')
    dev(root, home, { "board", "add", "One", "--problem", "x", "--size", "1", "--done-when", "a" })
    testing.eq(fs.list(root .. "/.dev"), { "board.json", "config.toml" })
end)

testing.test("show reads the epic and the children of a card from the task view", function()
    local root, home = pomb()
    local out, code = pomb_dev(root, home, { "board", "show", ID_A:sub(1, 8) })
    testing.eq(code, 0, out)
    testing.ok(out:find("\nparent: bbbbbbbb Epic\nchildren: 1 of 3 done\n\n", 1, true), out)
end)

testing.test("a locked pass queues a write the same way", function()
    local root, home = pomb({ locked = true })
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), COLUMN.REVIEW })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
    testing.eq(#document(queue_path(home)), 1)
end)

testing.test("reads, usage errors and refusals are not queued", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find("cannot reach", 1, true), out)
    out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "nowhere" })
    testing.eq(code, 2, out)
    out, code = pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "--edit", "aaaaaaaa", "x" })
    testing.eq(code, 1, out)
    out, code = pomb_dev(root, home, { "board", "take", ID_A:sub(1, 8) })
    testing.eq(code, 1, out)
    testing.eq(fs.exists(queue_path(home)), false)
end)

testing.test("link posts to the task and queues while Pomb is unreachable", function()
    local root, home = pomb()
    local out, code =
        pomb_dev(root, home, { "board", "link", ID_A:sub(1, 8), "blocks", ID_B:sub(1, 8) })
    testing.eq(code, 0, out)
    testing.eq(out, "linked aaaaaaaa blocks bbbbbbbb\n")
    testing.ok(calls(root):find("/api/tasks/" .. ID_A .. "/links", 1, true), calls(root))
    testing.eq(fs.read(root .. "/bodies"), '{"kind":"blocks","target_id":"' .. ID_B .. '"}\n')
    assert(fs.write(root .. "/down", ""))
    out, code = pomb_dev(root, home, { "board", "link", ID_B:sub(1, 8), "related", ID_A:sub(1, 8) })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
    local entries = document(queue_path(home))
    testing.eq(#entries, 1)
    testing.eq(entries[1].sub, "link")
    testing.eq(entries[1].args, { ID_B:sub(1, 8), "related", ID_A:sub(1, 8) })
    assert(fs.remove(root .. "/down"))
    out = pomb_dev(root, home, { "board", "sync" })
    testing.eq(out, "synced link bbbbbbbb\nsynced\n")
    testing.ok(calls(root):find("/api/tasks/" .. ID_B .. "/links", 1, true), calls(root))
end)

local WAITING = "## Problem\nwaiting plan\n\n## Change\n- x\n\n## Out of scope\nnone"

testing.test("edit patches the task, and a queued edit replays with its text", function()
    local root, home = pomb()
    assert(
        fs.write(
            root .. "/plan.md",
            "## Problem\nnew plan\n\n## Change\n- x\n\n## Out of scope\nnone\n"
        )
    )
    local out, code =
        pomb_dev(root, home, { "board", "edit", ID_A:sub(1, 8), "--file", root .. "/plan.md" })
    testing.eq(code, 0, out)
    testing.eq(out, "edited aaaaaaaa\n")
    testing.ok(calls(root):find("/api/tasks/" .. ID_A .. "\n", 1, true), calls(root))
    testing.eq(
        fs.read(root .. "/bodies"),
        '{"description":"## Problem\\nnew plan\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone"}\n'
    )
    assert(fs.write(root .. "/down", ""))
    out, code = support.dev(root, { "board", "edit", ID_B:sub(1, 8) }, {
        env = env_of(home, { ROOT = root }),
        input = WAITING .. "\n",
    })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
    local entries = document(queue_path(home))
    testing.eq(#entries, 1)
    testing.eq(entries[1].sub, "edit")
    testing.eq(entries[1].args, { ID_B:sub(1, 8), WAITING })
    assert(fs.remove(root .. "/down"))
    out = pomb_dev(root, home, { "board", "sync" })
    testing.eq(out, "synced edit bbbbbbbb\nsynced\n")
    testing.ok(calls(root):find("/api/tasks/" .. ID_B .. "\n", 1, true), calls(root))
end)

testing.test("a local board replaces a card's checks and then lets it enter Ready", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Bare",
        "--column",
        COLUMN.ICEBOX,
        "--problem",
        "x",
        "--size",
        "1",
    })))
    local file = root .. "/v1.md"
    assert(fs.write(file, V1))
    assert(dev(root, home, { "board", "edit", a, "--file", file }))
    local out, code = dev(root, home, { "board", "move", a, COLUMN.READY })
    testing.eq(code, 1)
    out, code = dev(root, home, { "board", "checks", a, "dev lint", "dev test" })
    testing.eq(code, 0, out)
    testing.eq(out, "set checks " .. a .. ", 2 rows\n")
    testing.eq(document(file_of(home)).cards[1].checks, { "dev lint", "dev test" })
    out = dev(root, home, { "board", "show", a })
    testing.ok(out:find("\n\nchecks:\n- dev lint\n- dev test\n\n", 1, true), out)
    out, code = dev(root, home, { "board", "move", a, COLUMN.READY })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "checks", a, "dev fmt" })
    testing.eq(code, 0, out)
    testing.eq(document(file_of(home)).cards[1].checks, { "dev fmt" })
    out, code = dev(root, home, { "board", "checks", a })
    testing.eq(code, 2)
    testing.eq(document(file_of(home)).cards[1].checks, { "dev fmt" })
end)

testing.test("a queued checks replaces the rows when Pomb answers again", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, { "board", "checks", ID_A:sub(1, 8), "dev lint" })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
    local entries = document(queue_path(home))
    testing.eq(entries[1].sub, "checks")
    testing.eq(entries[1].args, { ID_A:sub(1, 8), "dev lint" })
    assert(fs.remove(root .. "/down"))
    out = pomb_dev(root, home, { "board", "sync" })
    testing.eq(out, "synced checks aaaaaaaa\nsynced\n")
    testing.ok(fs.read(root .. "/bodies"):find('"dev.checks":[{"run":"dev lint"}]', 1, true))
end)

testing.test("a local board stores a card's allow, tests and files and shows them", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Bare",
        "--column",
        COLUMN.ICEBOX,
        "--problem",
        "x",
        "--size",
        "1",
    })))
    local out, code = dev(root, home, { "board", "allow", a, "ci-edits", "test-edits" })
    testing.eq(code, 0, out)
    testing.eq(out, "set allow " .. a .. ", ci-edits test-edits\n")
    testing.eq(document(file_of(home)).cards[1].allow, { "ci-edits", "test-edits" })
    out, code = dev(root, home, { "board", "tests", a, "one", "tests::two" })
    testing.eq(code, 0, out)
    testing.eq(document(file_of(home)).cards[1].tests, "one\ntests::two")
    out, code = dev(root, home, { "board", "files", a, "src/a.rs" })
    testing.eq(code, 0, out)
    testing.eq(document(file_of(home)).cards[1].files, "src/a.rs")
    out = dev(root, home, { "board", "show", a })
    testing.ok(
        out:find(
            "allow:\n- ci-edits\n- test-edits\n\ntests:\n- one\n- tests::two\n\nfiles:\n- src/a.rs\n\n",
            1,
            true
        ),
        out
    )
    out, code = dev(root, home, { "board", "allow", a, "none" })
    testing.eq(code, 0, out)
    testing.eq(out, "cleared allow " .. a .. "\n")
    testing.eq(document(file_of(home)).cards[1].allow, nil)
    out, code = dev(root, home, { "board", "allow", a, "everything" })
    testing.eq(code, 2)
    testing.eq(document(file_of(home)).cards[1].allow, nil)
end)

testing.test("queued allow, tests and files replace the fields when Pomb answers again", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local id = ID_A:sub(1, 8)
    local out, code = pomb_dev(root, home, { "board", "allow", id, "test-edits" })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
    out = pomb_dev(root, home, { "board", "tests", id, "one" })
    testing.eq(out, QUEUED)
    out = pomb_dev(root, home, { "board", "files", id, "src/a.rs" })
    testing.eq(out, QUEUED)
    local entries = document(queue_path(home))
    testing.eq(#entries, 3)
    testing.eq(entries[1].sub, "allow")
    testing.eq(entries[1].args, { id, "test-edits" })
    assert(fs.remove(root .. "/down"))
    out = pomb_dev(root, home, { "board", "sync" })
    testing.eq(out, "synced allow aaaaaaaa\nsynced tests aaaaaaaa\nsynced files aaaaaaaa\nsynced\n")
    local bodies = fs.read(root .. "/bodies")
    testing.ok(bodies:find('"dev.allow":["test-edits"]', 1, true), bodies)
    testing.ok(bodies:find('"dev.tests":"one"', 1, true), bodies)
    testing.ok(bodies:find('"dev.files":"src/a.rs"', 1, true), bodies)
end)

testing.test("a gateway error still queues an edit, which is safe to repeat", function()
    local root, home = pomb()
    assert(fs.write(root .. "/plan.md", "again\n"))
    assert(fs.write(root .. "/gateway", ""))
    local out, code =
        pomb_dev(root, home, { "board", "edit", ID_A:sub(1, 8), "--file", root .. "/plan.md" })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
end)

testing.test("sync replays the queue in order and empties it", function()
    local root, home = pomb()
    assert(fs.write(root .. "/export.json", PLANNED_EXPORT))
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), COLUMN.REVIEW })
    pomb_dev(root, home, { "board", "note", ID_B:sub(1, 8), "hello" })
    pomb_dev(
        root,
        home,
        { "board", "add", "Later", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    assert(fs.remove(root .. "/down"))
    local out, code = pomb_dev(root, home, { "board", "sync" })
    testing.eq(code, 0, out)
    testing.eq(out, "synced move aaaaaaaa\nsynced note bbbbbbbb\nsynced add Later\nsynced\n")
    testing.eq(fs.exists(queue_path(home)), false)
    local log = calls(root)
    local move = assert(log:find("POST [^\n]*/move", 1))
    local note = assert(log:find("POST [^\n]*/comments", 1))
    local add = assert(log:find("POST [^\n]*/api/tasks\n", 1))
    testing.ok(move < note and note < add, log)
    out = pomb_dev(root, home, { "board", "sync" })
    testing.eq(out, "nothing queued\n")
end)

testing.test("a replay Pomb refuses is reported and dropped, the rest still go", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", "deadbeef", COLUMN.REVIEW })
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "still goes" })
    assert(fs.remove(root .. "/down"))
    local out, code = pomb_dev(root, home, { "board", "sync" })
    testing.eq(code, 0, out)
    testing.ok(out:find("dropped move deadbeef: no card starts with deadbeef", 1, true), out)
    testing.ok(out:find("synced note aaaaaaaa", 1, true), out)
    testing.eq(fs.exists(queue_path(home)), false)
end)

testing.test("a sync that finds Pomb still down keeps every change queued", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), COLUMN.REVIEW })
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "second" })
    local out, code = pomb_dev(root, home, { "board", "sync" })
    testing.eq(code, 1)
    testing.eq(out, "Pomb is still unreachable, move aaaaaaaa stays queued\nqueued: 2\n")
    testing.eq(#document(queue_path(home)), 2)
end)

testing.test("any pomb command syncs a waiting queue first", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "waiting" })
    assert(fs.remove(root .. "/down"))
    local out, code = pomb_dev(root, home, { "board", "ls" })
    testing.eq(code, 0, out)
    testing.ok(out:find("synced note aaaaaaaa", 1, true), out)
    testing.ok(out:find("First", 1, true), out)
    testing.eq(fs.exists(queue_path(home)), false)
    local log = calls(root)
    testing.ok(log:find("POST [^\n]*/comments\nGET [^\n]*/export%-data\n$"), log)
end)

testing.test("status syncs a waiting queue and reports what is left", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "waiting" })
    local out = pomb_dev(root, home, { "board", "status" })
    testing.eq(
        out,
        "backend: pomb\nboard: dotfiles\nPomb is still unreachable, note aaaaaaaa stays queued\nqueued: 1\n"
    )
end)

local function bad_queue(text)
    local root, home = pomb()
    assert(fs.mkdir(home .. "/state/dev/boards", { parents = true }))
    assert(fs.write(queue_path(home), text))
    return root, home
end

testing.test(
    "sync on a malformed queue is an error that names the line and keeps the file",
    function()
        local root, home =
            bad_queue('[{"sub":"move",\n"args":["aaaaaaaa" "' .. COLUMN.REVIEW .. '"]}]\n')
        local out, code = pomb_dev(root, home, { "board", "sync" })
        testing.eq(code, 1)
        testing.ok(out:find(queue_path(home) .. ":2: ", 1, true), out)
        testing.ok(out:find("left in place", 1, true), out)
        testing.ok(not out:find("nothing queued", 1, true), out)
        testing.ok(assert(fs.read(queue_path(home))):find('"' .. COLUMN.REVIEW .. '"]}]', 1, true))
        testing.eq(calls(root), "")
    end
)

testing.test("a queue that is not a list of commands is malformed", function()
    local root, home = bad_queue('{"sub":"move"}\n')
    local out, code = pomb_dev(root, home, { "board", "sync" })
    testing.eq(code, 1)
    testing.ok(out:find(":1: not a list of queued commands", 1, true), out)
    root, home = bad_queue('[{"sub":"move","args":["a"]},"oops"]\n')
    out, code = pomb_dev(root, home, { "board", "sync" })
    testing.eq(code, 1)
    testing.ok(out:find("entry 2 is not a queued command", 1, true), out)
end)

testing.test("another command warns about a malformed queue, runs and keeps the file", function()
    local root, home = bad_queue("not json")
    local out, code = pomb_dev(root, home, { "board", "ls" })
    testing.eq(code, 0, out)
    testing.ok(out:find(queue_path(home) .. ":1: ", 1, true), out)
    testing.ok(out:find("First", 1, true), out)
    testing.eq(assert(fs.read(queue_path(home))), "not json")
    out, code = pomb_dev(root, home, { "board", "status" })
    testing.eq(code, 0, out)
    testing.ok(out:find("left in place", 1, true), out)
    testing.eq(assert(fs.read(queue_path(home))), "not json")
end)

testing.test("a write that cannot reach Pomb does not overwrite a malformed queue", function()
    local root, home = bad_queue("not json")
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), COLUMN.REVIEW })
    testing.eq(code, 1, out)
    testing.ok(out:find("could not be queued", 1, true), out)
    testing.eq(assert(fs.read(queue_path(home))), "not json")
end)

testing.test("a local board never queues", function()
    local root, home = local_board()
    dev(root, home, { "board", "add", "One", "--problem", "x", "--size", "1", "--done-when", "a" })
    testing.eq(fs.exists(home .. "/state/dev/boards/mine.queue"), false)
end)

testing.test("a local board stores checks on the card and show lists them", function()
    local root, home = local_board()
    local out, code = dev(root, home, {
        "board",
        "add",
        "Card",
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
    })
    testing.eq(code, 0, out)
    local a = prefix_of(out)
    testing.eq(document(file_of(home)).cards[1].checks, { "dev lint", "dev test" })
    out = dev(root, home, { "board", "show", a })
    testing.ok(out:find("\n\nchecks:\n- dev lint\n- dev test\n\n", 1, true), out)
end)

testing.test("a local board keeps a card with no checks row out of Ready", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Bare",
        "--column",
        COLUMN.ICEBOX,
        "--problem",
        "x",
        "--size",
        "1",
    })))
    local file = root .. "/v1.md"
    assert(fs.write(file, V1))
    assert(dev(root, home, { "board", "edit", a, "--file", file }))
    local out, code = dev(root, home, { "board", "move", a, COLUMN.READY })
    testing.eq(code, 1)
    testing.ok(out:find("has no checks row", 1, true), out)
    out, code = dev(root, home, {
        "board",
        "add",
        "Direct",
        "--column",
        COLUMN.READY,
        "--size",
        "1",
        "--description",
        V1,
    })
    testing.eq(code, 2)
    testing.ok(out:find("--checks", 1, true), out)
    out = dev(root, home, { "board", "init" })
    testing.eq(out:find("checks field", 1, true), nil)
end)

testing.test("wait on a local board answers at once that there is nothing to wait on", function()
    local backend = require("dev.board.localboard").new({ name = "mine" })
    local got, message = backend:wait("1", { "task_added" }, 5)
    testing.eq(got, nil)
    testing.eq(message, "a local board has nothing to wait on")
end)

testing.test("a local board with renamed columns works through the project map", function()
    local root, home = local_board(
        '[board]\nbackend = "local"\nname = "mine"\n\n[board.columns]\nbacklog = "Inbox"\nready = "Next"\nprogress = "Doing"\ndone = "Shipped"\n'
    )
    local doc = document(file_of(home))
    local names = {}
    for _, column in ipairs(doc.columns) do
        names[#names + 1] = column.name
    end
    testing.eq(names, {
        "Icebox",
        "Inbox",
        "Next",
        "Doing",
        "Review",
        "Verify",
        "Release",
        "Blocked",
        "Shipped",
    })
    testing.eq(doc.columns[9].is_done, true)
    local out = dev(
        root,
        home,
        { "board", "add", "One", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    testing.ok(out:find(" Inbox\n", 1, true), out)
    local id = prefix_of(out)
    tick_first(root, home, id)
    out = dev(root, home, { "board", "move", id, COLUMN.DONE })
    testing.eq(out, "moved " .. id .. " to Shipped\n")
    testing.eq(dev(root, home, { "board", "ls" }), "no cards\n")
    out = dev(root, home, { "board", "ls", "--column", "shipped" })
    testing.ok(out:find("Shipped", 1, true), out)
    out = dev(root, home, { "board", "move", id, COLUMN.READY })
    testing.ok(
        out:find(" to Next\n", 1, true)
            or out:find("cannot enter Next", 1, true)
            or out:find("cannot enter Ready", 1, true),
        out
    )
end)

testing.test(
    "a local board with two finished columns hides both and discards into the first",
    function()
        local root, home = local_board()
        local doc = document(file_of(home))
        doc.columns[#doc.columns + 1] = { id = "col-archive", name = "Archive", is_done = true }
        assert(fs.write(file_of(home), json.encode(doc)))
        local first = prefix_of(
            dev(
                root,
                home,
                { "board", "add", "One", "--problem", "x", "--size", "1", "--done-when", "a" }
            )
        )
        local second = prefix_of(
            dev(
                root,
                home,
                { "board", "add", "Two", "--problem", "x", "--size", "1", "--done-when", "a" }
            )
        )
        tick_first(root, home, first)
        testing.eq(
            dev(root, home, { "board", "move", first, COLUMN.DONE }),
            "moved " .. first .. " to Done\n"
        )
        testing.eq(
            dev(root, home, { "board", "move", second, "archive" }),
            "moved " .. second .. " to Archive\n"
        )
        testing.eq(dev(root, home, { "board", "ls" }), "no cards\n")
        local third = prefix_of(
            dev(
                root,
                home,
                { "board", "add", "Three", "--problem", "x", "--size", "1", "--done-when", "a" }
            )
        )
        local out = dev(root, home, { "board", "discard", third })
        testing.eq(out, "discarded " .. third .. "\n")
        out = dev(root, home, { "board", "ls", "--column", COLUMN.DONE })
        testing.ok(out:find("Three", 1, true), out)
    end
)

testing.test(
    "a local board stores the sections --problem, --change and --out-of-scope compose",
    function()
        local root, home = local_board()
        local out, code = dev(root, home, {
            "board",
            "add",
            "Sectioned",
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
        })
        testing.eq(code, 0, out)
        testing.eq(
            document(file_of(home)).cards[1].description,
            "## Problem\nIt breaks.\n\n## Change\n- fix it\n\n## Out of scope\nnothing\n"
        )
    end
)

testing.test(
    "a local board refuses --description with a section flag and a Backlog add without Problem",
    function()
        local root, home = local_board()
        local out, code =
            dev(root, home, { "board", "add", "Both", "--description", "text", "--problem", "p" })
        testing.eq(code, 2)
        testing.ok(out:find("--description", 1, true), out)
        out, code = dev(root, home, { "board", "add", "Bare" })
        testing.eq(code, 2)
        testing.ok(out:find("text under ## Problem", 1, true), out)
        out, code = dev(root, home, { "board", "add", "OnlyChange", "--change", "- do" })
        testing.eq(code, 2)
        testing.eq(#document(file_of(home)).cards, 0)
    end
)

testing.test(
    "a free-form Icebox card cannot enter Backlog until edit gives it a Problem",
    function()
        local root, home = local_board()
        local a = prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", "Idea", "--column", COLUMN.ICEBOX, "--description", "loose" }
                )
            )
        )
        testing.eq(document(file_of(home)).cards[1].description, "loose")
        local out, code = dev(root, home, { "board", "move", a, COLUMN.BACKLOG })
        testing.eq(code, 1)
        testing.ok(out:find("cannot enter Backlog", 1, true), out)
        testing.ok(out:find("## Problem", 1, true), out)
        local file = root .. "/plan.md"
        assert(fs.write(file, "## Problem\nwhy\n\n## Change\n\n## Out of scope\n"))
        out, code = dev(root, home, { "board", "edit", a, "--file", file })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, COLUMN.BACKLOG })
        testing.eq(code, 1)
        testing.ok(out:find("a size", 1, true) and out:find("Done when outcomes", 1, true), out)
        out, code = dev(root, home, { "board", "size", a, "1" })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "outcome", a, "It works" })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, COLUMN.BACKLOG })
        testing.eq(code, 0, out)
        testing.eq(out, "moved " .. a .. " to Backlog\n")
    end
)

testing.test(
    "a local board refuses Ready for a card with an empty Change or Out of scope",
    function()
        local root, home = local_board()
        local a = prefix_of((dev(root, home, {
            "board",
            "add",
            "Thin",
            "--problem",
            "why",
            "--size",
            "1",
            "--checks",
            "dev test",
            "--done-when",
            "a",
            "--done-when",
            "b",
            "--done-when",
            "c",
        })))
        local out, code = dev(root, home, { "board", "move", a, COLUMN.READY })
        testing.eq(code, 1)
        testing.ok(out:find("text under ## Change", 1, true), out)
        testing.ok(out:find("text under ## Out of scope", 1, true), out)
        local file = root .. "/full.md"
        assert(fs.write(file, "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone\n"))
        out, code = dev(root, home, { "board", "edit", a, "--file", file })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, COLUMN.READY })
        testing.eq(code, 0, out)
    end
)

testing.test(
    "order puts the named cards first and keeps the rest below on a local board",
    function()
        local root, home = local_board()
        local ids = {}
        for _, name in ipairs({ "One", "Two", "Three", "Four" }) do
            local out, code = dev(
                root,
                home,
                { "board", "add", name, "--problem", "x", "--size", "1", "--done-when", "a" }
            )
            testing.eq(code, 0, out)
            table.insert(ids, 1, (prefix_of(out)))
        end
        local function names(out)
            local found = {}
            for name in out:gmatch("(%a+)\n") do
                found[#found + 1] = name
            end
            return found
        end
        local out = dev(root, home, { "board", "ls" })
        testing.eq(names(out), { "One", "Two", "Three", "Four" })
        local four, three, two, one = ids[1], ids[2], ids[3], ids[4]
        out = dev(root, home, { "board", "order", three, one })
        testing.eq(names(out), { "Three", "One", "Two", "Four" })
        out = dev(root, home, { "board", "ls" })
        testing.eq(names(out), { "Three", "One", "Two", "Four" })
        out = dev(root, home, { "board", "order", four })
        testing.eq(names(out), { "Four", "Three", "One", "Two" })
        local code
        out, code = dev(root, home, { "board", "order", one, two, one })
        testing.eq(code, 1, out)
        testing.ok(out:find("twice", 1, true), out)
        out = dev(root, home, { "board", "ls" })
        testing.eq(names(out), { "Four", "Three", "One", "Two" })
    end
)

testing.test(
    "order refuses cards of two columns before any move and frees a needs:human card",
    function()
        local root, home = local_board()
        local out = dev(
            root,
            home,
            { "board", "add", "One", "--problem", "x", "--size", "1", "--done-when", "a" }
        )
        local one = prefix_of(out)
        out = dev(
            root,
            home,
            { "board", "add", "Two", "--problem", "x", "--size", "1", "--done-when", "a" }
        )
        local two = prefix_of(out)
        dev(root, home, { "board", "move", two, COLUMN.ICEBOX })
        local before = dev(root, home, { "board", "ls" })
        local code
        out, code = dev(root, home, { "board", "order", one, two })
        testing.eq(code, 1, out)
        testing.ok(out:find("one column", 1, true), out)
        testing.eq(dev(root, home, { "board", "ls" }), before)
        dev(root, home, { "board", "label", two, "needs:human" })
        out, code = dev(root, home, { "board", "order", two })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", two, COLUMN.ICEBOX })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", two, COLUMN.BACKLOG })
        testing.eq(code, 1, out)
        testing.ok(out:find("needs:human", 1, true), out)
    end
)

testing.test("a move into an empty column leaves ls ordered by column", function()
    local root, home = local_board()
    dev(root, home, { "board", "add", "One", "--problem", "x", "--size", "1", "--done-when", "a" })
    local two = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Two", "--problem", "x", "--size", "1", "--done-when", "a" }
            )
        )
    )
    dev(root, home, { "board", "move", two, COLUMN.ICEBOX })
    local out = dev(root, home, { "board", "ls" })
    testing.ok(out:find("Two", 1, true) < out:find("One", 1, true), out)
end)

testing.test("run starts a lint-clean run card, resumes it and ends it", function()
    local root, home = local_board()
    local agent = { DEV_AGENT = "dotfiles/one" }
    local out, code = dev(root, home, { "board", "run" }, agent)
    testing.eq(code, 1, out)
    testing.ok(out:find("dev board run --orders TEXT", 1, true), out)
    out, code = dev(root, home, { "board", "run", "--orders", "Clear the board\nthen stop" }, agent)
    testing.eq(code, 0, out)
    testing.ok(out:find("started ", 1, true), out)
    testing.ok(out:find("run dotfiles/one", 1, true), out)
    testing.ok(out:find("> Clear the board", 1, true), out)
    out, code = dev(root, home, { "board", "run", "--orders", "again" }, agent)
    testing.eq(code, 1, out)
    testing.ok(out:find("already has the run card", 1, true), out)
    out, code = dev(root, home, { "board", "lint" })
    testing.eq(code, 0, out)
    testing.eq(out, "no findings\n")
    out, code = dev(root, home, { "board", "run" }, agent)
    testing.eq(code, 0, out)
    testing.ok(out:find("held by dotfiles/one:", 1, true), out)
    testing.ok(out:find("no ready cards", 1, true), out)
    out, code = dev(root, home, { "board", "run", "--end" }, agent)
    testing.eq(code, 0, out)
    testing.ok(out:find("ended ", 1, true), out)
    out, code = dev(root, home, { "board", "run" }, agent)
    testing.eq(code, 1, out)
    out, code = dev(root, home, { "board", "lint" })
    testing.eq(code, 0, out)
end)

testing.test("run gives each session its own card and next never returns one", function()
    local root, home = local_board()
    local one, two = { DEV_AGENT = "s/one" }, { DEV_AGENT = "s/two" }
    testing.eq(select(2, dev(root, home, { "board", "run", "--orders", "a" }, one)), 0)
    testing.eq(select(2, dev(root, home, { "board", "run", "--orders", "b" }, two)), 0)
    local out, code = dev(root, home, { "board", "ls" })
    testing.ok(out:find("run s/one", 1, true), out)
    testing.ok(out:find("run s/two", 1, true), out)
    out = dev(root, home, { "board", "run" }, one)
    testing.ok(not out:find("> b", 1, true), out)
    local id = assert(out:match("^(%x+)"), out)
    dev(root, home, { "board", "note", id, "built, tried, learned" }, one)
    out, code = dev(root, home, { "board", "move", id, COLUMN.READY }, one)
    testing.eq(code, 0, out)
    dev(
        root,
        home,
        { "board", "add", "Plain", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    out = dev(root, home, { "board", "next" })
    testing.ok(not out:find("run s/", 1, true), out)
    out, code = dev(root, home, { "board", "run", "--end" }, one)
    testing.eq(code, 0, out)
    out = dev(root, home, { "board", "next" })
    testing.ok(not out:find("run s/", 1, true), out)
end)

testing.test("run refuses orders over the word limit and a flag mix", function()
    local root, home = local_board()
    local long = string.rep("word ", 300)
    local out, code = dev(root, home, { "board", "run", "--orders", long })
    testing.eq(code, 2, out)
    out, code = dev(root, home, { "board", "run", "--orders", "x", "--end" })
    testing.eq(code, 2, out)
    out, code = dev(root, home, { "board", "run", "--orders", "a", "--orders", "b" })
    testing.eq(code, 2, out)
    testing.ok(out:find("takes one value", 1, true), out)
end)

testing.test("run on a private project with no board starts making one", function()
    local root, home = setup("")
    local out, code = dev(root, home, { "board", "run", "--orders", "x" })
    testing.eq(code, 1, out)
    testing.ok(out:find("private and has no board", 1, true), out)
    testing.ok(out:find("lead_token", 1, true), out)
end)

testing.test(
    "add --id-only prints the full id alone and sends warnings to standard error",
    function()
        local root, home = local_board()
        local out, code, errors = support.dev(root, {
            "board",
            "add",
            "Fresh",
            "--id-only",
            "--description",
            "look in src/a.lua",
            "--size",
            "1",
            "--done-when",
            "a",
        }, { env = env_of(home), split = true })
        testing.eq(code, 0, out)
        testing.ok(out:match("^%x+%-%x+%-%x+%-%x+%-%x+\n$"), out)
        testing.eq(errors, "Card prose holds a path: src/a.lua.\n")
        local plain = dev(root, home, {
            "board",
            "add",
            "Plain",
            "--size",
            "1",
            "--problem",
            "why",
            "--done-when",
            "a",
        })
        testing.ok(plain:find("^added %x+ Backlog\n$"), plain)
    end
)

testing.test(
    "a failed add --id-only prints nothing on standard output and exits non-zero",
    function()
        local root, home = local_board()
        local out, code, errors = support.dev(root, {
            "board",
            "add",
            "Bad",
            "--id-only",
            "--column",
            "nowhere",
        }, { env = env_of(home), split = true })
        testing.ok(code ~= 0, out)
        testing.eq(out, "")
        testing.ok(errors ~= "", errors)
    end
)

testing.test("add --id-only is refused while Pomb is unreachable and never queued", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, {
        "board",
        "add",
        "Later",
        "--id-only",
        "--problem",
        "x",
        "--size",
        "2",
        "--done-when",
        "a",
    })
    testing.ok(code ~= 0, out)
    testing.eq(out:find(QUEUED, 1, true), nil)
    testing.eq(fs.exists(queue_path(home)), false)
end)

testing.test("add takes --id-only as a value when a flag is waiting for one", function()
    local root, home = local_board()
    local out, code = dev(root, home, {
        "board",
        "add",
        "Odd",
        "--id-only",
        "--size",
        "1",
        "--problem",
        "--id-only",
        "--done-when",
        "a",
    })
    testing.eq(code, 0, out)
    testing.ok(out:find("^%x+%-%x+%-%x+%-%x+%-%x+\n$"), out)
end)

local function sized_board()
    local root, home = local_board()
    local function ready(name, size)
        return prefix_of((dev(root, home, {
            "board",
            "add",
            name,
            "--column",
            COLUMN.READY,
            "--size",
            size,
            "--description",
            V1,
            "--checks",
            "dev test",
        })))
    end
    local big, small = ready("Big", "3"), ready("Small", "1")
    return root, home, big, small
end

testing.test("next skips a card above the runner's size limit", function()
    local root, home, big, small = sized_board()
    local out = dev(root, home, { "board", "next" }, { DEV_MAX_SIZE = "" })
    testing.ok(out:find(big, 1, true), out)
    out = dev(root, home, { "board", "next", "--max-size", "1" })
    testing.ok(out:find(small, 1, true) and not out:find(big, 1, true), out)
    out = dev(root, home, { "board", "next" }, { DEV_MAX_SIZE = "2" })
    testing.ok(out:find(small, 1, true) and not out:find(big, 1, true), out)
    local code
    out, code = dev(root, home, { "board", "next", "--max-size", "9" })
    testing.eq(code, 2, out)
end)

testing.test("take and move into progress refuse a card above the runner's size limit", function()
    local root, home, big, small = sized_board()
    local env = { DEV_MAX_SIZE = "2", DEV_AGENT = "r/one" }
    local out, code = dev(root, home, { "board", "take", big }, env)
    testing.eq(code, 1, out)
    testing.ok(out:find("above this runner's limit of 2 Pomodori", 1, true), out)
    out, code = dev(root, home, { "board", "move", big, COLUMN.PROGRESS }, env)
    testing.eq(code, 1, out)
    testing.ok(out:find("above this runner's limit", 1, true), out)
    testing.eq(card_named(document(file_of(home)), "Big").claim, nil)
    out, code = dev(root, home, { "board", "take", small }, env)
    testing.eq(code, 0, out)
end)

testing.test("with no size limit set next, take and move change nothing", function()
    local root, home, big = sized_board()
    local out, code = dev(root, home, { "board", "next" }, { DEV_MAX_SIZE = "" })
    testing.eq(code, 0, out)
    testing.ok(out:find(big, 1, true), out)
    out, code = dev(
        root,
        home,
        { "board", "take", big },
        { DEV_AGENT = "r/one", DEV_MAX_SIZE = "" }
    )
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "note", big, "built it" }, { DEV_AGENT = "r/one" })
    testing.eq(code, 0, out)
    out, code = dev(
        root,
        home,
        { "board", "move", big, COLUMN.REVIEW },
        { DEV_AGENT = "r/one", DEV_MAX_SIZE = "" }
    )
    testing.eq(code, 0, out)
end)

testing.test("next refuses an empty --max-size", function()
    local root, home = sized_board()
    local out, code = dev(root, home, { "board", "next", "--max-size", "" })
    testing.eq(code, 2, out)
end)

testing.test("a --max-size flag on take and move wins over DEV_MAX_SIZE", function()
    local root, home, big, small = sized_board()
    local env = { DEV_MAX_SIZE = "3", DEV_AGENT = "r/one" }
    local out, code = dev(root, home, { "board", "take", big, "--max-size", "2" }, env)
    testing.eq(code, 1, out)
    testing.ok(out:find("above this runner's limit of 2 Pomodori", 1, true), out)
    out, code = dev(root, home, { "board", "move", big, COLUMN.PROGRESS, "--max-size", "1" }, env)
    testing.eq(code, 1, out)
    testing.ok(out:find("above this runner's limit of 1 Pomodori", 1, true), out)
    env.DEV_MAX_SIZE = "1"
    out, code = dev(root, home, { "board", "take", big, "--max-size", "3" }, env)
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "take", small, "--max-size", "1" }, env)
    testing.eq(code, 0, out)
end)

testing.test("take and move refuse a --max-size that is not 1, 2 or 3", function()
    local root, home, big = sized_board()
    local env = { DEV_MAX_SIZE = "", DEV_AGENT = "r/one" }
    for _, word in ipairs({ "9", "", "x" }) do
        local out, code = dev(root, home, { "board", "take", big, "--max-size", word }, env)
        testing.eq(code, 2, out)
        out, code =
            dev(root, home, { "board", "move", big, COLUMN.PROGRESS, "--max-size", word }, env)
        testing.eq(code, 2, out)
    end
end)

testing.test("move refuses a --max-size that is not 1, 2 or 3 into any column", function()
    local root, home, big = sized_board()
    local out, code = dev(root, home, { "board", "move", big, COLUMN.BACKLOG, "--max-size", "9" })
    testing.eq(code, 2, out)
end)

testing.test("run resumes with a DEV_MAX_SIZE that is not 1, 2 or 3", function()
    local root, home = sized_board()
    local agent = { DEV_AGENT = "dotfiles/one", DEV_MAX_SIZE = "" }
    dev(root, home, { "board", "run", "--orders", "Clear the board" }, agent)
    agent.DEV_MAX_SIZE = "9"
    local out, code = dev(root, home, { "board", "run" }, agent)
    testing.eq(code, 0, out)
end)

testing.test("run prints a next card within DEV_MAX_SIZE", function()
    local root, home, big, small = sized_board()
    local agent = { DEV_AGENT = "dotfiles/one", DEV_MAX_SIZE = "" }
    dev(root, home, { "board", "run", "--orders", "Clear the board" }, agent)
    local out = dev(root, home, { "board", "run" }, agent)
    testing.ok(out:find(big, 1, true), out)
    agent.DEV_MAX_SIZE = "1"
    out = dev(root, home, { "board", "run" }, agent)
    testing.ok(out:find(small, 1, true) and not out:find(big, 1, true), out)
end)

testing.test("take and move refuse a DEV_MAX_SIZE that is not 1, 2 or 3", function()
    local root, home, big = sized_board()
    local env = { DEV_MAX_SIZE = "9", DEV_AGENT = "r/one" }
    local out, code = dev(root, home, { "board", "take", big }, env)
    testing.eq(code, 2, out)
    out, code = dev(root, home, { "board", "move", big, COLUMN.PROGRESS }, env)
    testing.eq(code, 2, out)
end)

local function sized_pomb()
    local root, home = pomb()
    local big = "cccccccc-2222-4ccc-8ccc-cccccccccccc"
    local small = "dddddddd-2222-4ddd-8ddd-dddddddddddd"
    local function task(id, name, color_id)
        return '{"id":"'
            .. id
            .. '","name":"'
            .. name
            .. '","column_id":"col-ready","color_id":"'
            .. color_id
            .. '","labels":[]}'
    end
    assert(
        fs.write(
            root .. "/page.json",
            '{"items":[{"id":"' .. big .. '"},{"id":"' .. small .. '"}],"next_cursor":null}'
        )
    )
    assert(fs.write(root .. "/big.json", task(big, "Big", "blue-id")))
    assert(fs.write(root .. "/small.json", task(small, "Small", "yellow-id")))
    return root, home, big:sub(1, 8), small:sub(1, 8)
end

testing.test("next --max-size skips a size 3 card on a pomb board", function()
    local root, home, big, small = sized_pomb()
    local out = dev(root, home, { "board", "next" }, { ROOT = root, DEV_MAX_SIZE = "" })
    testing.ok(out:find(big, 1, true) and not out:find(small, 1, true), out)
    out = pomb_dev(root, home, { "board", "next", "--max-size", "1" })
    testing.ok(out:find(small, 1, true) and not out:find(big, 1, true), out)
    out = dev(root, home, { "board", "next" }, { ROOT = root, DEV_MAX_SIZE = "1" })
    testing.ok(out:find(small, 1, true) and not out:find(big, 1, true), out)
end)

testing.test("epic_local_move", function()
    local root, home = local_board()
    local function add(name)
        return prefix_of((dev(root, home, {
            "board",
            "add",
            name,
            "--problem",
            "x",
            "--size",
            "1",
            "--done-when",
            "a",
        })))
    end
    local epic, child = add("Epic"), add("Child")
    tick_first(root, home, epic)
    dev(root, home, { "board", "epic", epic })
    dev(root, home, { "board", "link", child, "parent", epic })
    local out, code = dev(root, home, { "board", "move", epic, COLUMN.DONE })
    testing.eq(code, 1, out)
    testing.ok(out:find("is an epic and cannot enter Done, a done column", 1, true), out)
    testing.ok(out:find("1 of 1 children are open", 1, true), out)
    out, code = dev(root, home, { "board", "move", epic, COLUMN.REVIEW })
    testing.eq(code, 0, out)
    tick_first(root, home, child)
    dev(root, home, { "board", "move", child, COLUMN.DONE })
    out, code = dev(root, home, { "board", "move", epic, COLUMN.DONE })
    testing.eq(code, 0, out)
    dev(root, home, { "board", "move", child, COLUMN.BACKLOG })
    out, code = dev(root, home, { "board", "move", epic, COLUMN.BACKLOG })
    testing.eq(code, 0, out)
    out = dev(root, home, { "board", "ls" })
    testing.ok(out:find("[epic 1 of 1 open] Epic", 1, true), out)
end)

testing.test("epic_local_next", function()
    local root, home = local_board()
    local function add(name)
        return prefix_of((dev(root, home, {
            "board",
            "add",
            name,
            "--column",
            COLUMN.READY,
            "--size",
            "1",
            "--description",
            V1,
            "--checks",
            "dev test",
        })))
    end
    local epic, child = add("Epic"), add("Child")
    dev(root, home, { "board", "epic", epic })
    dev(root, home, { "board", "link", child, "parent", epic })
    local out = dev(root, home, { "board", "ls" })
    testing.ok(out:find("[epic 1 of 1 open] Epic", 1, true), out)
    out = dev(root, home, { "board", "show", epic })
    testing.ok(out:find("\nkind: epic, 1 open\n", 1, true), out)
    out = dev(root, home, { "board", "next" })
    testing.ok(out:find(child .. "  Ready", 1, true), out)
    out = dev(root, home, { "board", "next", "--column", COLUMN.READY })
    testing.ok(out:find(child, 1, true) and not out:find(epic, 1, true), out)
    out = dev(root, home, { "board", "move", child, COLUMN.DONE })
    out = dev(root, home, { "board", "next" })
    testing.ok(out:find(epic .. "  Ready", 1, true), out)
    out = dev(root, home, { "board", "move", epic, COLUMN.PROGRESS }, { DEV_AGENT = "r/one" })
    testing.ok(out:find("r/one", 1, true), out)
    testing.eq(card_named(document(file_of(home)), "Epic").claim.claimant, "r/one")
end)

testing.test("a local board has no blocked setting", function()
    local root, home = setup('[board]\nbackend = "local"\nname = "mine"\n')
    local out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(out:find("marked Blocked", 1, true), nil)
    for _, column in ipairs(document(file_of(home)).columns) do
        testing.eq(column.is_blocked, nil)
    end
end)

testing.test("local board keeps the epic kind and refuses a parent that is not an epic", function()
    local root, home = local_board()
    local function add(name, ...)
        return prefix_of((dev(root, home, {
            "board",
            "add",
            name,
            "--problem",
            "x",
            "--size",
            "1",
            "--done-when",
            "a",
            ...,
        })))
    end
    local made, plain, child = add("Made", "--epic"), add("Plain"), add("Child")
    local doc = document(file_of(home))
    testing.eq(card_named(doc, "Made").kind, "epic")
    testing.eq(card_named(doc, "Plain").kind, "task")
    local out, code = dev(root, home, { "board", "link", child, "parent", plain })
    testing.eq(code, 1, out)
    testing.ok(out:find("make it one with dev board epic " .. plain, 1, true), out)
    out, code = dev(root, home, { "board", "epic", plain })
    testing.eq(out, "made " .. plain .. " an epic\n")
    testing.eq(code, 0)
    testing.eq(card_named(document(file_of(home)), "Plain").kind, "epic")
    out, code = dev(root, home, { "board", "epic", plain })
    testing.eq(code, 1, out)
    testing.ok(out:find("already an epic", 1, true), out)
    out, code = dev(root, home, { "board", "link", child, "parent", made })
    testing.eq(code, 0, out)
    out = dev(root, home, { "board", "ls" })
    testing.ok(out:find("[epic 1 of 1 open] Made", 1, true), out)
    testing.ok(out:find("[epic] Plain", 1, true), out)
end)

testing.test("add --epic creates an epic on Pomb with kind epic", function()
    local root, home = pomb()
    local out, code = pomb_dev(root, home, {
        "board",
        "add",
        "Big",
        "--epic",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "a",
    })
    testing.eq(code, 0, out)
    testing.ok(
        fs.read(root .. "/bodies"):find('"kind":"epic"', 1, true),
        fs.read(root .. "/bodies")
    )
end)

testing.test("epic turns a card into an epic on Pomb and prints Pomb's refusal", function()
    local root, home = pomb()
    local out, code = pomb_dev(root, home, { "board", "epic", ID_A:sub(1, 8) })
    testing.eq(code, 0, out)
    testing.eq(out, "made aaaaaaaa an epic\n")
    testing.ok(
        calls(root):find("PATCH ", 1, true) and calls(root):find("/api/tasks/" .. ID_A, 1, true),
        calls(root)
    )
    testing.eq(fs.read(root .. "/bodies"), '{"kind":"epic"}\n')
    assert(fs.write(root .. "/held", ""))
    out, code = pomb_dev(root, home, { "board", "epic", ID_A:sub(1, 8) })
    testing.eq(code, 1, out)
    testing.ok(out:find("409", 1, true) and out:find("the card holds a live claim", 1, true), out)
end)

testing.test("a childless epic enters Ready with 1 to 3 outcomes like any epic", function()
    local root, home = local_board()
    local out, code = dev(root, home, {
        "board",
        "add",
        "Big",
        "--epic",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "a",
        "--done-when",
        "b",
        "--done-when",
        "c",
        "--done-when",
        "d",
    })
    testing.eq(code, 2, out)
    testing.ok(out:find("1 to 3 Done when outcomes for an epic, not 4", 1, true), out)
    out, code = dev(root, home, {
        "board",
        "add",
        "Epic",
        "--epic",
        "--column",
        COLUMN.READY,
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "none",
        "--size",
        "1",
        "--done-when",
        "a",
        "--done-when",
        "b",
        "--checks",
        "dev test",
    })
    testing.eq(code, 0, out)
    local epic = prefix_of(out)
    out, code = dev(root, home, { "board", "move", epic, COLUMN.BACKLOG })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", epic, COLUMN.READY })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "lint" })
    testing.eq(code, 0, out)
    testing.eq(out:find("lacks 3 to 7", 1, true), nil, out)
end)

testing.test("attach, attachments and detach refuse plainly on a local board", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "A", "--problem", "x", "--size", "1", "--done-when", "a" }
            )
        )
    )
    local file = support.tempdir() .. "/shot.png"
    assert(fs.write(file, "x"))
    for _, args in ipairs({
        { "board", "attach", a, file },
        { "board", "attachments", a },
        { "board", "detach", a, "abcd" },
    }) do
        local out, code = dev(root, home, args)
        testing.eq(code, 1, out)
        testing.ok(out:find("a local board holds no attachments", 1, true), out)
    end
end)
