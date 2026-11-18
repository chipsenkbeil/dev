local testing = require("dev.testing")
local dev_os = require("dev.os")
local board = require("dev.board")
local localboard = require("dev.board.localboard")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local Column = support.Column
local READY_COLUMN = support.column_id(Column.READY)

local TOKEN = "pomb_SECRETtoken0123456789"
local ID_A = "aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa"
local ID_B = "bbbbbbbb-1111-4bbb-8bbb-bbbbbbbbbbbb"
local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/dotfiles/bin/.local/share/dev/main.lua"

local PLANNED = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone"
local JUDGED = "done (reviewer judgement)"

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
    local tracked = root .. "/.dev/board.json"
    support.drop_turn_card(fs.exists(tracked) and tracked or support.board_file(home, "mine"))
    return root, home
end

local function file_of(home)
    return support.board_file(home, "mine")
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
    testing.ok(code == 0, out)
end

local function add_outcomes(root, home, id)
    for _ = 1, 3 do
        local out, code = dev(root, home, { "board", "outcome", id, JUDGED })
        testing.ok(code == 0, out)
    end
end

local function tick_all(root, home, id)
    for number = 1, 3 do
        local out, code = dev(
            root,
            home,
            { "board", "outcome", id, "--tick", tostring(number), "--as", "r/reviewer" }
        )
        testing.ok(code == 0, out)
    end
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
    testing.eq(out, "Board mine already follows the standard. Nothing changed.\n")
end)

testing.test("a local init makes one landing turn card and a second init adds none", function()
    -- Run init on a new local board
    local root, home = setup('[board]\nbackend = "local"\nname = "mine"\n')
    local out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)

    -- Count the landing turn cards in the board file
    local function turn_cards()
        local found = 0
        for _, card in ipairs(document(file_of(home)).cards) do
            found = found + (card.name == board.TURN_NAME and 1 or 0)
        end
        return found
    end
    testing.eq(turn_cards(), 1)

    -- Run init again and expect still one turn card
    out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(turn_cards(), 1)
end)

testing.test("the board file is private and writes leave no temporary file", function()
    local root, home = local_board()
    dev(root, home, {
        "board",
        "add",
        "One",
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
    testing.eq(mode(file_of(home)), "600")
    testing.eq(mode(home .. "/state/dev/boards"), "700")
    local names = fs.list(home .. "/state/dev/boards")
    testing.eq(names, { "mine.json", "mine.json.lock" })
end)

testing.test("show and note refuse a crossboard --board on a local board", function()
    local root, home = local_board()
    local out, code = dev(root, home, { "board", "show", "11111111", "--board", "other" })
    testing.eq(code, 1, out)
    testing.eq(out, "a local board links only its own cards, so other is not reachable\n")
    out, code = dev(root, home, { "board", "note", "11111111", "--board", "other", "text" })
    testing.eq(code, 1, out)
    testing.eq(out, "a local board links only its own cards, so other is not reachable\n")
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
    testing.eq(out, "a local board links only its own cards, so other is not reachable\n")
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
    testing.eq(out, "a local board knows only its own columns, so other is not reachable\n")
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
        Column.READY,
        "--size",
        "2",
        "--label",
        "docs",
        "--label",
        "needs:lead",
        "--description",
        PLANNED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--checks",
        "dev test",
    })
    testing.eq(code, 0, out)
    local a = prefix_of(out)
    testing.ok(out:find("Ready", 1, true), out)
    out = dev(root, home, {
        "board",
        "add",
        "Second",
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
    local b = prefix_of(out)
    out = dev(root, home, { "board", "ls" })
    testing.eq(
        out,
        b
            .. "  Backlog  1 Pomodoro  -                0/1  Second\n"
            .. a
            .. "  Ready    2 Pomodori  docs,needs:lead  0/3  Write docs\n"
    )
    out = dev(root, home, { "board", "ls", "--size", "3+" })
    testing.eq(out, "No cards.\n")
    out = dev(root, home, { "board", "ls", "--label", "docs" })
    testing.ok(out:find("Write docs", 1, true), out)
    out = dev(root, home, { "board", "next" })
    testing.eq(
        out,
        a .. "  Ready  2 Pomodori  docs,needs:lead  Write docs  0 comments, 0 the owner's\n"
    )
    out = support.to_review(function(args)
        return dev(root, home, args)
    end, a)
    testing.eq(out, "moved " .. a .. " to Review\n")
    out = dev(root, home, { "board", "next" })
    testing.eq(out, "No ready cards.\n")
    out = dev(root, home, { "board", "size", b, "1" })
    testing.eq(out, "sized " .. b .. " 1\n")
    out = dev(root, home, { "board", "label", a, "+extra", "--remove", "docs" })
    testing.eq(out, "labelled " .. a .. " needs:lead,extra\n")
    tick_all(root, home, a)
    out = dev(root, home, { "board", "move", a, Column.DONE })
    out = dev(root, home, { "board", "ls" })
    testing.eq(out, b .. "  Backlog  1 Pomodoro  -  0/1  Second\n")
    out = dev(root, home, { "board", "ls", "--column", Column.DONE })
    testing.ok(out:find("Done  2 Pomodori", 1, true), out)
end)

testing.test("edit replaces a local card's description from a file or standard input", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Card", "--column", Column.ICEBOX, "--description", "old" }
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
            prefix_of((dev(root, home, { "board", "add", "First", "--column", Column.ICEBOX })))
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
    local a = prefix_of((dev(root, home, { "board", "add", "First", "--column", Column.ICEBOX })))
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
    local a = prefix_of((dev(root, home, { "board", "add", "First", "--column", Column.ICEBOX })))
    local b = prefix_of((dev(root, home, { "board", "add", "Second", "--column", Column.ICEBOX })))
    local out, code = dev(root, home, { "board", "label", a, "needs:human" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "next", "--column", Column.ICEBOX })
    testing.eq(code, 0, out)
    testing.ok(out:find(b, 1, true) and not out:find(a, 1, true), out)
    out = dev(root, home, { "board", "next", "--column", Column.BACKLOG })
    testing.eq(out, "No cards in Backlog.\n")
end)

testing.test("next --column icebox never offers the landing turn card", function()
    local root, home = local_board()
    dev(root, home, { "board", "add", "landing turn", "--column", Column.ICEBOX })
    local out = dev(root, home, { "board", "next", "--column", Column.ICEBOX })
    testing.eq(out, "No cards in Icebox.\n")
    local other =
        prefix_of((dev(root, home, { "board", "add", "Other", "--column", Column.ICEBOX })))
    out = dev(root, home, { "board", "next", "--column", Column.ICEBOX })
    testing.ok(out:find(other, 1, true) and not out:find("landing turn", 1, true), out)
end)

testing.test("next --column blocked returns the top unclaimed needs:lead card only", function()
    local root, home = local_board()
    local function blocked(name, label)
        local out, code = dev(root, home, {
            "board",
            "add",
            name,
            "--column",
            Column.BLOCKED,
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
    out, code = dev(root, home, { "board", "next", "--column", Column.BLOCKED })
    testing.eq(code, 0, out)
    testing.ok(out:find(free, 1, true) and out:find("Free", 1, true), out)
    out, code = dev(root, home, { "board", "label", free, "needs:human" })
    testing.eq(code, 0, out)
    out = dev(root, home, { "board", "next", "--column", Column.BLOCKED })
    testing.eq(out, "No cards in Blocked.\n")
end)

testing.test("next --column verify and review skip a claimed card", function()
    local root, home = local_board()
    for _, column in ipairs({ Column.VERIFY, Column.REVIEW }) do
        -- Put a claimed and an unclaimed card in the stage column
        local function staged(name)
            local out, code = dev(root, home, {
                "board",
                "add",
                name,
                "--column",
                column,
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
                "--checks",
                "dev test",
            })
            testing.eq(code, 0, out)
            return prefix_of(out)
        end
        local claimed = staged("Claimed " .. column)
        local free = staged("Free " .. column)
        local out, code = dev(root, home, { "board", "take", claimed })
        testing.eq(code, 0, out)

        -- Expect next to name only the unclaimed card
        out, code = dev(root, home, { "board", "next", "--column", column })
        testing.eq(code, 0, out)
        testing.ok(out:find(free, 1, true) and out:find("Free " .. column, 1, true), out)
        testing.eq(out:find(claimed, 1, true), nil)

        -- Claim the last one and expect the column to read as empty
        out, code = dev(root, home, { "board", "take", free })
        testing.eq(code, 0, out)
        out = dev(root, home, { "board", "next", "--column", column })
        testing.eq(out, "No cards in " .. support.COLUMN_NAME[column:upper()] .. ".\n")
    end
end)

testing.test("rename sets a local card's title and refuses a blank one", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
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
    })))
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
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
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
    })))
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
        Column.BLOCKED,
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
                { "board", "add", "Card", "--column", Column.ICEBOX, "--description", "keep" }
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
                    { "board", "add", "Card", "--column", Column.ICEBOX, "--description", "keep" }
                )
            )
        )
        local out, code = dev(root, home, { "board", "discard", a })
        testing.eq(code, 1, out)
        testing.ok(out:find("is not planned and cannot be discarded", 1, true), out)
        local card = document(file_of(home)).cards[1]
        testing.eq(#(card.comments or {}), 0)
        testing.eq(#(card.labels or {}), 0)
        out = dev(root, home, { "board", "ls", "--column", Column.ICEBOX })
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
        Column.BACKLOG,
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
    })))
    local doc = document(file_of(home))
    doc.cards[1].description = "keep"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    local out, code = dev(root, home, { "board", "discard", a, "--reason", "Dropped" })
    testing.eq(code, 1, out)
    testing.ok(out:find("is not planned and cannot be discarded", 1, true), out)
    local card = document(file_of(home)).cards[1]
    testing.eq(#(card.comments or {}), 0)
    out = dev(root, home, { "board", "ls", "--column", Column.BACKLOG })
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
            "--change",
            "x",
            "--out-of-scope",
            "y",
            "--size",
            "1",
            "--done-when",
            "First works",
        })))
        local out, code = dev(root, home, { "board", "move", a, Column.DONE })
        testing.eq(code, 1, out)
        testing.ok(out:find("1 of 1 outcomes are unticked (1. First works)", 1, true), out)
        out, code = dev(root, home, { "board", "outcome", a, "--tick", "1", "--as", "r/reviewer" })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, Column.DONE })
        testing.eq(code, 0, out)
        testing.eq(out, "moved " .. a .. " to Done\n")
        local b = prefix_of((dev(root, home, {
            "board",
            "add",
            "Dropped",
            "--problem",
            "x",
            "--change",
            "x",
            "--out-of-scope",
            "y",
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
                { "board", "add", "Card", "--column", Column.ICEBOX, "--description", "keep" }
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
                { "board", "add", "Card", "--column", Column.ICEBOX, "--description", "keep" }
            )
        )
    )
    dev(root, home, { "board", "checks", a, "dev test" })
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
        Column.ICEBOX,
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
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
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
    })))
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
    testing.eq(out, "that comment is not yours to change\n")
end)

testing.test("note --kind and --as are stored on a local comment and notes prints them", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
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
    })))
    dev(root, home, { "board", "note", a, "--kind", "decision", "--as", "reviewer", "ship", "it" })
    dev(root, home, { "board", "note", a, "plain" })
    local out = dev(root, home, { "board", "notes", a })
    testing.ok(
        out:find("agent  decision  reviewer  ", 1, true) and out:find("ship it", 1, true),
        out
    )
    testing.ok(out:find("agent  agent     -         ", 1, true), out)
    out = dev(root, home, { "board", "note", a, "--kind", "chatter", "x" })
    testing.ok(out:find("Unknown kind chatter", 1, true), out)
    local first = assert(dev(root, home, { "board", "notes", a }):match("^(%x+)"))
    dev(root, home, { "board", "note", a, "--edit", first, "changed" })
    out = dev(root, home, { "board", "notes", a })
    testing.ok(out:find("decision  reviewer  ", 1, true) and out:find("changed", 1, true), out)
end)

testing.test("local escalate swaps the label in one write", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
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
    })))
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
                Column.READY,
                "--size",
                "1",
                "--description",
                PLANNED,
                "--done-when",
                JUDGED,
                "--done-when",
                JUDGED,
                "--done-when",
                JUDGED,
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
        tick_all(root, home, third)
        dev(root, home, { "board", "move", third, Column.DONE })
        out = dev(root, home, { "board", "next" })
        testing.ok(out:find("^" .. second), out)
        tick_all(root, home, second)
        dev(root, home, { "board", "move", second, Column.DONE })
        out = dev(root, home, { "board", "next" })
        testing.ok(out:find("^" .. first), out)
    end
)

testing.test(
    "links lists a card's own links and the reverse side of links other cards hold",
    function()
        local root, home = local_board()
        local a = prefix_of((dev(root, home, {
            "board",
            "add",
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
        })))
        local b = prefix_of((dev(root, home, {
            "board",
            "add",
            "B",
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
        })))
        local c = prefix_of((dev(root, home, {
            "board",
            "add",
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
        })))
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
        local d = prefix_of((dev(root, home, {
            "board",
            "add",
            "D",
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
        })))
        out = dev(root, home, { "board", "links", d })
        testing.eq(out, "No links.\n")
        out, code = dev(root, home, { "board", "links", "deadbeef" })
        testing.eq(code, 1, out)
    end
)

testing.test(
    "unlink removes a link from the card that holds it, and refuses one it lacks",
    function()
        local root, home = local_board()
        local a = prefix_of((dev(root, home, {
            "board",
            "add",
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
        })))
        local b = prefix_of((dev(root, home, {
            "board",
            "add",
            "B",
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
        })))
        local c = prefix_of((dev(root, home, {
            "board",
            "add",
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
        })))
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
        testing.eq(dev(root, home, { "board", "links", a }), "No links.\n")
        out, code = dev(root, home, { "board", "unlink", a, "blocked_by", b })
        testing.eq(code, 1, out)
        testing.ok(out:find("The card holds no blocked_by link to " .. b, 1, true), out)
    end
)

testing.test(
    "link refuses itself, a cycle, another board and a bad kind on a local board",
    function()
        local root, home = local_board()
        local a = prefix_of((dev(root, home, {
            "board",
            "add",
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
        })))
        local b = prefix_of((dev(root, home, {
            "board",
            "add",
            "B",
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
        })))
        local c = prefix_of((dev(root, home, {
            "board",
            "add",
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
        })))
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
        return prefix_of((dev(root, home, {
            "board",
            "add",
            name,
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
        })))
    end
    local card, child = add("Card"), add("Child")
    local epic = prefix_of((dev(root, home, {
        "board",
        "add",
        "Epic",
        "--size",
        "2",
        "--description",
        PLANNED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--checks",
        "dev test",
    })))
    local out, code = dev(root, home, { "board", "label", card, "needs:human" })
    testing.eq(code, 1, out)
    testing.ok(out:find("Blocked or Icebox", 1, true), out)
    dev(root, home, { "board", "move", card, Column.BLOCKED })
    out, code = dev(root, home, { "board", "label", card, "needs:human" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", card, Column.BACKLOG })
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
    out, code = dev(root, home, { "board", "move", card, Column.BACKLOG })
    testing.eq(code, 0, out)
    dev(root, home, { "board", "epic", epic })
    dev(root, home, { "board", "link", child, "parent", epic })
    out, code = dev(root, home, { "board", "move", epic, Column.READY })
    testing.eq(code, 0, out)
end)

testing.test("responsible is stored on a local card and show prints it only while set", function()
    local root, home = local_board()
    local card = prefix_of((dev(root, home, {
        "board",
        "add",
        "Coordinated",
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
    })))
    local out, code = dev(root, home, { "board", "responsible", card })
    testing.eq(code, 0, out)
    testing.eq(out, card .. " none\n")
    out, code = dev(root, home, { "board", "responsible", card, "dotfiles/lead" })
    testing.eq(code, 0, out)
    testing.eq(out, "set " .. card .. " responsible dotfiles/lead\n")
    testing.eq(dev(root, home, { "board", "responsible", card }), card .. " dotfiles/lead\n")
    out = dev(root, home, { "board", "show", card })
    testing.ok(out:find("\nresponsible: dotfiles/lead\n", 1, true), out)
    out, code = dev(root, home, { "board", "responsible", card, "--clear" })
    testing.eq(code, 0, out)
    testing.eq(out, "cleared " .. card .. " responsible\n")
    out = dev(root, home, { "board", "show", card })
    testing.ok(not out:find("responsible:", 1, true), out)
end)

testing.test("link parent sets one epic and show and links report it", function()
    local root, home = local_board()
    local function add(name)
        return prefix_of((dev(root, home, {
            "board",
            "add",
            name,
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
        })))
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
    out, code = dev(root, home, { "board", "move", one, Column.DONE })
    testing.eq(code, 1, out)
    testing.ok(out:find("1 of 1 children are open", 1, true), out)
    tick_first(root, home, other)
    dev(root, home, { "board", "move", other, Column.DONE })
    out, code = dev(root, home, { "board", "move", one, Column.DONE })
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
        Column.READY,
        "--size",
        "1",
        "--description",
        PLANNED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--checks",
        "dev test",
    })))
    prefix_of((dev(root, home, {
        "board",
        "add",
        "New",
        "--column",
        Column.READY,
        "--size",
        "1",
        "--description",
        PLANNED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
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
        Column.ICEBOX,
        "--description",
        PLANNED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--checks",
        "dev test",
    })))
    local out, code = dev(root, home, { "board", "move", a, Column.READY })
    testing.eq(code, 1)
    testing.ok(out:find("dev board size", 1, true), out)
    out, code = dev(root, home, { "board", "move", a, Column.BACKLOG })
    testing.eq(code, 1)
    testing.ok(out:find("a size", 1, true), out)
    out, code = dev(root, home, { "board", "add", "Direct", "--column", Column.READY })
    testing.eq(code, 2)
    out, code = dev(root, home, { "board", "add", "Direct", "--problem", "x" })
    testing.eq(code, 2)
    testing.ok(out:find("a size", 1, true), out)
    dev(root, home, { "board", "size", a, "3+" })
    out, code = dev(root, home, { "board", "move", a, Column.READY })
    testing.eq(code, 1)
    testing.ok(out:find("red", 1, true), out)
    dev(root, home, { "board", "size", a, "2" })
    out, code = dev(root, home, { "board", "move", a, Column.READY })
    testing.eq(code, 0, out)
    testing.eq(dev(root, home, { "board", "stale" }), "No stale cards.\n")
end)

testing.test(
    "a local board scaffolds the v3 headings and keeps a card without them out of Ready",
    function()
        local root, home = local_board()
        local a = prefix_of((dev(root, home, {
            "board",
            "add",
            "Plain",
            "--column",
            Column.ICEBOX,
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
        local out, code = dev(root, home, { "board", "move", a, Column.READY })
        testing.eq(code, 1)
        testing.ok(out:find("3 to 7 Done when outcomes", 1, true), out)
        out, code =
            dev(root, home, { "board", "add", "Direct", "--column", Column.READY, "--size", "1" })
        testing.eq(code, 2)
        testing.ok(out:find("card format v3", 1, true), out)
        local ice =
            prefix_of((dev(root, home, { "board", "add", "Loose", "--column", Column.ICEBOX })))
        out = dev(root, home, { "board", "show", ice })
        testing.ok(out:find("no description", 1, true), out)
        local file = root .. "/v1.md"
        assert(fs.write(file, PLANNED))
        out, code = dev(root, home, { "board", "edit", a, "--file", file })
        testing.eq(code, 0, out)
        add_outcomes(root, home, a)
        out, code = dev(root, home, { "board", "move", a, Column.READY })
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
    testing.ok(out:find("The card has 3 outcomes. There is no outcome 4.", 1, true), out)
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
        testing.ok(out:find("Only the lead deletes an outcome", 1, true), out)
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

testing.test("outcome delete works in any column on a local board, which has no lock", function()
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
        "A works " .. board.CHECK_OPEN .. "dev test)",
        "--done-when",
        "B works " .. board.CHECK_OPEN .. "dev test)",
        "--done-when",
        "C works " .. board.CHECK_OPEN .. "dev test)",
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
    out, code = dev(root, home, { "board", "move", a, Column.READY }, lead)
    testing.eq(code, 0, out)
    out, code = dev(
        root,
        home,
        { "board", "outcome", a, "--delete", "1", "--reason", "never possible" },
        lead
    )
    testing.eq(code, 0, out)
    testing.eq(out, "outcome " .. a .. " 1 deleted\n")
    testing.eq(#document(file_of(home)).cards[1].outcomes, 2)
end)

testing.test("a local board converts a v1 checklist into outcomes and ticks", function()
    local root, home = local_board()
    local v1 =
        "## Problem\nP\n\n## Change\nC\n\n## Done when\n- [ ] A works\n- [x] B works\n- [ ] C works\n\n## Out of scope\nNone\n"
    local out, code = dev(root, home, {
        "board",
        "add",
        "Old",
        "--column",
        Column.ICEBOX,
        "--description",
        v1,
        "--size",
        "1",
    })
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
    testing.eq(out, "Outcomes of card " .. a .. " are left alone. It already has outcomes.\n")
    testing.eq(#document(file_of(home)).cards[1].outcomes, 3)
end)

testing.test(
    "a local board refuses a v1 checklist in place of outcomes on a move to Ready",
    function()
        local root, home = local_board()
        local v1 =
            "## Problem\nP\n\n## Change\nC\n\n## Out of scope\nNone\n\n## Done when\n- [ ] A\n- [ ] B\n- [ ] C\n"
        local out, code = dev(root, home, {
            "board",
            "add",
            "Old",
            "--column",
            Column.ICEBOX,
            "--description",
            v1,
            "--size",
            "1",
            "--checks",
            "dev test",
        })
        testing.eq(code, 0, out)
        local a = prefix_of(out)
        out, code = dev(root, home, { "board", "move", a, Column.READY })
        testing.eq(code, 1, out)
        testing.ok(out:find("3 to 7 Done when outcomes", 1, true), out)
    end
)

testing.test("outcome --convert leaves a card with no checklist alone", function()
    local root, home = local_board()
    local a = prefix_of(
        (dev(root, home, { "board", "add", "Plain", "--column", Column.ICEBOX, "--problem", "x" }))
    )
    local out, code = dev(root, home, { "board", "outcome", a, "--convert" })
    testing.eq(code, 0, out)
    testing.eq(out, "Outcomes of card " .. a .. " are left alone. It has no Done when checklist.\n")
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
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "A works",
        "--checks",
        "dev test",
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
                Column.READY,
                "--size",
                "1",
                "--description",
                PLANNED,
                "--done-when",
                JUDGED,
                "--done-when",
                JUDGED,
                "--done-when",
                JUDGED,
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
            { "board", "move", b, Column.PROGRESS },
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
            { "board", "move", a, Column.PROGRESS },
            { DEV_AGENT = "r/three" }
        )
        testing.eq(code, 0, out)
        testing.eq(card_named(document(file_of(home)), "Alpha").claim.claimant, "r/one")
        dev(root, home, { "board", "release", a })
        out, code = dev(
            root,
            home,
            { "board", "move", a, Column.PROGRESS },
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
        Column.READY,
        "--size",
        "1",
        "--description",
        PLANNED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--checks",
        "dev test",
    })))
    dev(root, home, { "board", "take", a })
    testing.ok(document(file_of(home)).cards[1].claim ~= nil, "claim held")
    local out, code = support.to_review(function(args)
        return dev(root, home, args)
    end, a)
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
            Column.READY,
            "--size",
            "1",
            "--description",
            PLANNED,
            "--done-when",
            JUDGED,
            "--done-when",
            JUDGED,
            "--done-when",
            JUDGED,
            "--checks",
            "dev test",
        })))
        dev(root, home, { "board", "take", a })
        dev(root, home, { "board", "move", a, Column.PROGRESS })
        for _, column in ipairs({ Column.REVIEW, Column.READY, Column.BLOCKED }) do
            local out, code = dev(root, home, { "board", "move", a, column })
            testing.eq(code, 1, out)
            testing.ok(out:find("built, tried and learned", 1, true), out)
            testing.ok(document(file_of(home)).cards[1].claim ~= nil, "claim kept")
        end
        dev(root, home, { "board", "note", a, "--kind", "decision", "ruled" })
        local out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
        testing.eq(code, 1, out)
        out, code = dev(root, home, { "board", "note", a, "built, tried, learned" })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
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
        Column.READY,
        "--size",
        "1",
        "--description",
        PLANNED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--checks",
        "dev test",
    })))
    dev(root, home, { "board", "take", a })
    dev(root, home, { "board", "move", a, Column.PROGRESS })
    dev(root, home, { "board", "note", a, "built, tried, learned" })
    local out, code = dev(root, home, { "board", "move", a, Column.READY })
    testing.eq(code, 0, out)
    dev(root, home, { "board", "take", a })
    dev(root, home, { "board", "move", a, Column.PROGRESS })
    out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
    testing.eq(code, 1, out)
    testing.ok(out:find("built, tried and learned", 1, true), out)
end)

local function card_in(root, home, column)
    return prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        column,
        "--size",
        "1",
        "--description",
        PLANNED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--checks",
        "dev test",
    })))
end

testing.test("move to Review refuses a card that is not in progress under a claim", function()
    local root, home = local_board()
    for _, column in ipairs({ Column.BACKLOG, Column.READY }) do
        local a = card_in(root, home, column)
        local out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
        testing.eq(code, 1, out)
        testing.ok(out:find("cannot move to Review from", 1, true), out)
        testing.ok(out:find("It must pass In Progress under a claim first.", 1, true), out)
        out = dev(root, home, { "board", "ls", "--column", Column.REVIEW })
        testing.eq(out, "No cards.\n")
    end
end)

local function lapsed_in_progress(root, home)
    local a = card_in(root, home, Column.READY)
    dev(root, home, { "board", "outcome", a, "First", "works" })
    local steps = {
        { "board", "take", a },
        { "board", "move", a, Column.PROGRESS },
        { "board", "note", a, "built, tried, learned" },
    }
    for _, args in ipairs(steps) do
        local out, code = dev(root, home, args)
        testing.eq(code, 0, out)
    end
    local doc = document(file_of(home))
    doc.cards[1].claim.expires_at = "2020-01-01T00:00:00Z"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    return a
end

testing.test("a move by the last claimant after the lease lapsed takes the claim again", function()
    local root, home = local_board()
    local a = lapsed_in_progress(root, home)
    local out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
    testing.eq(code, 0, out)
    testing.eq(out, "moved " .. a .. " to Review\n")
end)

testing.test("a move by another name after the lease lapsed is refused", function()
    local root, home = local_board()
    local a = lapsed_in_progress(root, home)
    local out, code = dev(root, home, { "board", "move", a, Column.REVIEW }, {
        CLAUDE_SESSION_ID = "other",
    })
    testing.eq(code, 1, out)
    testing.ok(out:find("It must pass In Progress under a claim first.", 1, true), out)
end)

local function without_claim_state(home)
    local dir = home .. "/state/dev/board"
    for _, name in ipairs(fs.list(dir) or {}) do
        assert(fs.remove(dir .. "/" .. name))
    end
end

testing.test(
    "a move by the claimant with no claim state on this machine releases the claim",
    function()
        local root, home = local_board()
        local a = lapsed_in_progress(root, home)
        local doc = document(file_of(home))
        doc.cards[1].claim.expires_at = "2999-01-01T00:00:00Z"
        assert(fs.write(file_of(home), assert(json.encode(doc))))
        without_claim_state(home)
        local out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
        testing.eq(code, 0, out)
        testing.eq(out, "moved " .. a .. " to Review\n")
        testing.eq(document(file_of(home)).cards[1].claim, nil)
    end
)

testing.test("a move by another name with no claim state leaves the claim held", function()
    local root, home = local_board()
    local a = lapsed_in_progress(root, home)
    local doc = document(file_of(home))
    doc.cards[1].claim.expires_at = "2999-01-01T00:00:00Z"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    without_claim_state(home)
    dev(root, home, { "board", "move", a, Column.REVIEW }, {
        CLAUDE_SESSION_ID = "other",
    })
    testing.ok(document(file_of(home)).cards[1].claim ~= nil, "claim kept")
end)

testing.test("a move while another claimant holds the card is refused", function()
    local root, home = local_board()
    local a = lapsed_in_progress(root, home)

    -- Another claimant takes the lapsed card
    local out, code = dev(root, home, { "board", "take", a }, { CLAUDE_SESSION_ID = "other" })
    testing.eq(code, 0, out)

    -- The first claimant's move is refused
    out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
    testing.ok(code ~= 0, out)

    -- Review stays empty
    out = dev(root, home, { "board", "ls", "--column", Column.REVIEW })
    testing.eq(out, "No cards.\n")
end)

testing.test("move to Verify refuses a card that is not in Review", function()
    local root, home = local_board()
    local backlog = card_in(root, home, Column.BACKLOG)
    local ready = card_in(root, home, Column.READY)
    local working = card_in(root, home, Column.READY)
    dev(root, home, { "board", "move", working, Column.PROGRESS })
    for _, id in ipairs({ backlog, ready, working }) do
        local out, code = dev(root, home, { "board", "move", id, Column.VERIFY })
        testing.eq(code, 1, out)
        testing.ok(out:find("cannot move to Verify from", 1, true), out)
        testing.ok(out:find("It must pass Review first.", 1, true), out)
    end
    local out = dev(root, home, { "board", "ls", "--column", Column.VERIFY })
    testing.eq(out, "No cards.\n")
end)

testing.test("a claimed card with a note moves to Review and a Verify card moves back", function()
    local root, home = local_board()
    local a = card_in(root, home, Column.READY)
    dev(root, home, { "board", "outcome", a, "First", "works" })
    dev(root, home, { "board", "take", a })
    local out, code = support.to_review(function(args)
        return dev(root, home, args)
    end, a)
    testing.eq(code, 0, out)
    testing.eq(out, "moved " .. a .. " to Review\n")
    tick_first(root, home, a)
    out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
    testing.eq(code, 0, out)
    testing.eq(out, "moved " .. a .. " to Review\n")
    local staged = card_in(root, home, Column.VERIFY)
    out, code = dev(root, home, { "board", "move", staged, Column.REVIEW })
    testing.eq(code, 0, out)
    testing.eq(out, "moved " .. staged .. " to Review\n")
end)

local function in_review(root, home)
    local a = card_in(root, home, Column.READY)
    dev(root, home, { "board", "take", a })
    local out, code = support.to_review(function(args)
        return dev(root, home, args)
    end, a)
    testing.eq(code, 0, out)
    return a
end

testing.test("on a local board a plain move from Review to Verify is refused", function()
    local root, home = local_board()
    local a = in_review(root, home)
    local out, code = dev(root, home, { "board", "move", a, Column.VERIFY })
    testing.eq(code, 1, out)
    testing.ok(out:find("cannot move to Verify from Review", 1, true), out)
    testing.ok(out:find("verifier's tick of its last open outcome", 1, true), out)
    out = dev(root, home, { "board", "ls", "--column", Column.VERIFY })
    testing.eq(out, "No cards.\n")
end)

testing.test("on a local board the last tick moves a Review card to Verify", function()
    local root, home = local_board()
    local a = in_review(root, home)
    for number = 1, 2 do
        dev(root, home, { "board", "outcome", a, "--tick", tostring(number), "--as", "r/verifier" })
    end
    local out, code =
        dev(root, home, { "board", "outcome", a, "--tick", "3", "--as", "r/verifier" })
    testing.eq(code, 0, out)
    testing.eq(out, "outcome " .. a .. " 3 ticked by r/verifier\nmoved " .. a .. " to Verify\n")
    out = dev(root, home, { "board", "ls", "--column", Column.VERIFY })
    testing.ok(out:find(a, 1, true), out)
end)

testing.test("on a local board an early tick keeps a Review card in Review", function()
    local root, home = local_board()
    local a = in_review(root, home)
    local out, code = dev(root, home, { "board", "outcome", a, "Second", "works" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "outcome", a, "--tick", "1", "--as", "r/verifier" })
    testing.eq(code, 0, out)
    testing.eq(out, "outcome " .. a .. " 1 ticked by r/verifier\n")
    out = dev(root, home, { "board", "ls", "--column", Column.REVIEW })
    testing.ok(out:find(a, 1, true), out)
end)

testing.test("take holds a claim with an expiry and no loop, and release gives it up", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        Column.READY,
        "--size",
        "1",
        "--description",
        PLANNED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
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
    testing.eq(out, "No ready cards.\n")
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

local function unnamed_card(tty)
    local root, home = local_board()
    assert(fs.write(root .. "/bin/ps", "#!/bin/sh\necho '" .. tty .. "'\n"))
    assert(dev_os.run({ "chmod", "755", root .. "/bin/ps" }) == 0, "chmod failed")
    local out = dev(root, home, {
        "board",
        "add",
        "Card",
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
    return root, home, prefix_of(out)
end

testing.test("two runs from one terminal share a claimant", function()
    local root, home, a = unnamed_card("ttys042")
    local out, code = dev(root, home, { "board", "take", a }, { CLAUDE_SESSION_ID = "" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "take", a }, { CLAUDE_SESSION_ID = "" })
    testing.eq(code, 0, out)
    out = dev(root, home, { "board", "ls" }, { CLAUDE_SESSION_ID = "" })
    testing.ok(out:find("-ttys042", 1, true), out)
end)

testing.test("a caller with no terminal keeps the pid in its claimant", function()
    local root, home, a = unnamed_card("??")
    local out, code = dev(root, home, { "board", "take", a }, { CLAUDE_SESSION_ID = "" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "take", a }, { CLAUDE_SESSION_ID = "" })
    testing.eq(code, 1)
    testing.ok(out:find("is claimed by dev@", 1, true), out)
end)

testing.test("a stale fence is refused once another process holds the claim", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
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
    })))
    dev(root, home, { "board", "checks", a, "dev test" })
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
        Column.READY,
        "--size",
        "1",
        "--description",
        PLANNED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
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
    local out = dev(root, home, {
        "board",
        "add",
        "Tracked",
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
    prefix_of(out)
    testing.ok(fs.exists(root .. "/.dev/board.json"))
    testing.eq(fs.exists(support.board_file(home, "mine")), false)
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
        testing.ok(
            out:find("The `path` setting of `[board]` must be a relative path", 1, true),
            out
        )
    end
    local root, home = setup('[board]\nbackend = "pomb"\npath = ".dev/board.json"\n')
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find('only applies to `backend = "local"`.', 1, true), out)
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
    testing.eq(out, "A local board has nothing to sync.\n")
end)

testing.test("wait on a local board says there is nothing to wait on", function()
    local root, home = local_board()
    local out, code = dev(root, home, { "board", "wait", "--for", Column.READY })
    testing.eq(code, 1)
    testing.eq(out, "A local board has nothing to wait on.\n")
end)

testing.test("six processes writing at once lose no card", function()
    local root, home = local_board()
    local script = string.format(
        'for i in 1 2 3 4 5 6; do luajit %s board add "card $i" --problem x --change x --out-of-scope y --size 1 --done-when a & done; wait',
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
    .. '{"id":"col-progress","name":"In Progress"},'
    .. '{"id":"col-review","name":"Review"},{"id":"col-done","name":"Done"}]}'
local COLORS = '[{"id":"yellow-id","value":"yellow","label":"1 Pomodoro"},'
    .. '{"id":"blue-id","value":"blue","label":"3 Pomodori"},'
    .. '{"id":"white-id","value":"white","label":"Unsized"}]'
local EXPORT = '{"tasks":['
    .. support.pomb_export_task({
        id = ID_A,
        name = "First",
        column_id = READY_COLUMN,
        color_id = false,
    })
    .. ","
    .. support.pomb_export_task({
        id = ID_B,
        name = "Second",
        column_id = READY_COLUMN,
        position = 2,
        color_id = false,
    })
    .. "]}"

local WORKING_EXPORT = '{"tasks":['
    .. support.pomb_export_task({
        id = ID_A,
        name = "First",
        column_id = support.column_id(Column.PROGRESS),
        color_id = "yellow-id",
        description = "## Problem\\nx\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone",
        subtasks = '[{"id":"s1","name":"a (reviewer judgement)","done":false},'
            .. '{"id":"s2","name":"b (reviewer judgement)","done":false},'
            .. '{"id":"s3","name":"c (reviewer judgement)","done":false}]',
        holder = "dotfiles/one",
    })
    .. ","
    .. support.pomb_export_task({
        id = ID_B,
        name = "Second",
        column_id = READY_COLUMN,
        position = 2,
        color_id = false,
    })
    .. "]}"

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
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), Column.REVIEW })
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
        "--change",
        "x",
        "--out-of-scope",
        "y",
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
    testing.eq(entries[1].args, { ID_A:sub(1, 8), Column.REVIEW })
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
    assert(fs.write(root .. "/export.json", '{"tasks":[' .. support.pomb_export_task({
        id = ID_A,
        name = "First",
        column_id = READY_COLUMN,
        color_id = "yellow-id",
        description = "## Problem\\nx\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone",
        subtasks = '[{"id":"s1","name":"Never works","done":false}]',
    }) .. "]}"))
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
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), Column.DONE })
    testing.eq(code, 1, out)
    testing.ok(out:find("board unavailable", 1, true), out)
    testing.eq(fs.exists(queue_path(home)), false)
end)

testing.test("after a gateway error only a change that is safe to repeat is queued", function()
    local root, home = pomb()
    assert(fs.write(root .. "/gateway", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), Column.REVIEW })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
    out, code = pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "once" })
    testing.eq(code, 1, out)
    out, code = pomb_dev(root, home, {
        "board",
        "add",
        "Once",
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
    testing.eq(code, 1, out)
    testing.eq(#document(queue_path(home)), 1)
end)

testing.test("a hand-edited board file keeps its other keys and gets its name back", function()
    local root, home = local_board()
    local doc = document(file_of(home))
    doc.name = nil
    doc.note = "kept"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    dev(root, home, {
        "board",
        "add",
        "One",
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
    doc = document(file_of(home))
    testing.eq(doc.note, "kept")
    testing.eq(doc.name, "mine")
end)

testing.test("a tracked board leaves no lock file in the project", function()
    local root, home = local_board('[board]\nbackend = "local"\npath = ".dev/board.json"\n')
    dev(root, home, {
        "board",
        "add",
        "One",
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
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), Column.REVIEW })
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
        Column.ICEBOX,
        "--problem",
        "x",
        "--size",
        "1",
    })))
    local file = root .. "/v1.md"
    assert(fs.write(file, PLANNED))
    assert(dev(root, home, { "board", "edit", a, "--file", file }))
    add_outcomes(root, home, a)
    local out, code = dev(root, home, { "board", "move", a, Column.READY })
    testing.eq(code, 1)
    out, code = dev(root, home, { "board", "checks", a, "dev lint", "dev test" })
    testing.eq(code, 0, out)
    testing.eq(out, "set checks " .. a .. ", 2 rows\n")
    testing.eq(document(file_of(home)).cards[1].checks, { "dev lint", "dev test" })
    out = dev(root, home, { "board", "show", a })
    testing.ok(out:find("\n\nchecks:\n- dev lint\n- dev test\n\n", 1, true), out)
    out, code = dev(root, home, { "board", "move", a, Column.READY })
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
        Column.ICEBOX,
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
    assert(fs.write(root .. "/export.json", WORKING_EXPORT))
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), Column.REVIEW })
    pomb_dev(root, home, { "board", "note", ID_B:sub(1, 8), "hello" })
    pomb_dev(root, home, {
        "board",
        "add",
        "Later",
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
    testing.eq(out, "Nothing is queued.\n")
end)

testing.test("a replay Pomb refuses is reported and dropped, the rest still go", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", "deadbeef", Column.REVIEW })
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "still goes" })
    assert(fs.remove(root .. "/down"))
    local out, code = pomb_dev(root, home, { "board", "sync" })
    testing.eq(code, 0, out)
    testing.ok(out:find("dropped move deadbeef: No card starts with deadbeef.", 1, true), out)
    testing.ok(out:find("synced note aaaaaaaa", 1, true), out)
    testing.eq(fs.exists(queue_path(home)), false)
end)

testing.test("a sync that finds Pomb still down keeps every change queued", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), Column.REVIEW })
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
            bad_queue('[{"sub":"move",\n"args":["aaaaaaaa" "' .. Column.REVIEW .. '"]}]\n')
        local out, code = pomb_dev(root, home, { "board", "sync" })
        testing.eq(code, 1)
        testing.ok(out:find(queue_path(home) .. ":2: ", 1, true), out)
        testing.ok(out:find("left in place", 1, true), out)
        testing.ok(not out:find("Nothing is queued", 1, true), out)
        testing.ok(assert(fs.read(queue_path(home))):find('"' .. Column.REVIEW .. '"]}]', 1, true))
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
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), Column.REVIEW })
    testing.eq(code, 1, out)
    testing.ok(out:find("could not be queued", 1, true), out)
    testing.eq(assert(fs.read(queue_path(home))), "not json")
end)

testing.test("a local board never queues", function()
    local root, home = local_board()
    dev(root, home, {
        "board",
        "add",
        "One",
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
        Column.ICEBOX,
        "--problem",
        "x",
        "--size",
        "1",
    })))
    local file = root .. "/v1.md"
    assert(fs.write(file, PLANNED))
    assert(dev(root, home, { "board", "edit", a, "--file", file }))
    add_outcomes(root, home, a)
    local out, code = dev(root, home, { "board", "move", a, Column.READY })
    testing.eq(code, 1)
    testing.ok(out:find("has no checks row", 1, true), out)
    out, code = dev(root, home, {
        "board",
        "add",
        "Direct",
        "--column",
        Column.READY,
        "--size",
        "1",
        "--description",
        PLANNED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
    })
    testing.eq(code, 2)
    testing.ok(out:find("--checks", 1, true), out)
    out = dev(root, home, { "board", "init" })
    testing.eq(out:find("checks field", 1, true), nil)
end)

testing.test("an add with once returns the open card of that name and adds none", function()
    -- Open the board file as a backend
    local _, home = local_board()
    local icebox = support.COLUMN_NAME.ICEBOX
    local backend = localboard.new({
        name = "mine",
        path = file_of(home),
        private = true,
    })

    -- Add with once twice, which adds one card and then finds it
    local first, _, existed = assert(backend:add(board.TURN_NAME, icebox, { once = true }))
    testing.eq(existed, nil)
    local again
    again, _, existed = assert(backend:add(board.TURN_NAME, icebox, { once = true }))
    testing.eq(again.id, first.id)
    testing.eq(existed, true)
    local function count()
        local found = 0
        for _, card in ipairs(document(file_of(home)).cards) do
            found = found + (card.name == board.TURN_NAME and 1 or 0)
        end
        return found
    end
    testing.eq(count(), 1)

    -- A plain add still makes a second card
    local plain = assert(backend:add(board.TURN_NAME, icebox, {}))
    testing.ok(plain.id ~= first.id)
    testing.eq(count(), 2)
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
    local out = dev(root, home, {
        "board",
        "add",
        "One",
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
    testing.ok(out:find(" Inbox\n", 1, true), out)
    local id = prefix_of(out)
    tick_first(root, home, id)
    out = dev(root, home, { "board", "move", id, Column.DONE })
    testing.eq(out, "moved " .. id .. " to Shipped\n")
    testing.eq(dev(root, home, { "board", "ls" }), "No cards.\n")
    out = dev(root, home, { "board", "ls", "--column", "shipped" })
    testing.ok(out:find("Shipped", 1, true), out)
    out = dev(root, home, { "board", "move", id, Column.READY })
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
        local first = prefix_of(dev(root, home, {
            "board",
            "add",
            "One",
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
        }))
        local second = prefix_of(dev(root, home, {
            "board",
            "add",
            "Two",
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
        }))
        tick_first(root, home, first)
        testing.eq(
            dev(root, home, { "board", "move", first, Column.DONE }),
            "moved " .. first .. " to Done\n"
        )
        testing.eq(
            dev(root, home, { "board", "move", second, "archive" }),
            "moved " .. second .. " to Archive\n"
        )
        testing.eq(dev(root, home, { "board", "ls" }), "No cards.\n")
        local third = prefix_of(dev(root, home, {
            "board",
            "add",
            "Three",
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
        }))
        local out = dev(root, home, { "board", "discard", third })
        testing.eq(out, "discarded " .. third .. "\n")
        out = dev(root, home, { "board", "ls", "--column", Column.DONE })
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
                    { "board", "add", "Idea", "--column", Column.ICEBOX, "--description", "loose" }
                )
            )
        )
        testing.eq(document(file_of(home)).cards[1].description, "loose")
        local out, code = dev(root, home, { "board", "move", a, Column.BACKLOG })
        testing.eq(code, 1)
        testing.ok(out:find("cannot enter Backlog", 1, true), out)
        testing.ok(out:find("## Problem", 1, true), out)
        local file = root .. "/plan.md"
        assert(fs.write(file, "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone\n"))
        out, code = dev(root, home, { "board", "edit", a, "--file", file })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, Column.BACKLOG })
        testing.eq(code, 1)
        testing.ok(out:find("a size", 1, true) and out:find("Done when outcomes", 1, true), out)
        out, code = dev(root, home, { "board", "size", a, "1" })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "outcome", a, "It works" })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, Column.BACKLOG })
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
            "--column",
            Column.ICEBOX,
            "--problem",
            "why",
            "--size",
            "1",
            "--checks",
            "dev test",
            "--done-when",
            "a " .. board.JUDGEMENT,
            "--done-when",
            "b " .. board.JUDGEMENT,
            "--done-when",
            "c " .. board.JUDGEMENT,
        })))
        local out, code = dev(root, home, { "board", "move", a, Column.READY })
        testing.eq(code, 1)
        testing.ok(out:find("text under ## Change", 1, true), out)
        testing.ok(out:find("text under ## Out of scope", 1, true), out)
        local file = root .. "/full.md"
        assert(fs.write(file, "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone\n"))
        out, code = dev(root, home, { "board", "edit", a, "--file", file })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, Column.READY })
        testing.eq(code, 0, out)
    end
)

testing.test(
    "order puts the named cards first and keeps the rest below on a local board",
    function()
        local root, home = local_board()
        local ids = {}
        for _, name in ipairs({ "One", "Two", "Three", "Four" }) do
            local out, code = dev(root, home, {
                "board",
                "add",
                name,
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
        local out = dev(root, home, {
            "board",
            "add",
            "One",
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
        local one = prefix_of(out)
        out = dev(root, home, {
            "board",
            "add",
            "Two",
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
        local two = prefix_of(out)
        dev(root, home, { "board", "move", two, Column.ICEBOX })
        local before = dev(root, home, { "board", "ls" })
        local code
        out, code = dev(root, home, { "board", "order", one, two })
        testing.eq(code, 1, out)
        testing.ok(out:find("one column", 1, true), out)
        testing.eq(dev(root, home, { "board", "ls" }), before)
        dev(root, home, { "board", "label", two, "needs:human" })
        out, code = dev(root, home, { "board", "order", two })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", two, Column.ICEBOX })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", two, Column.BACKLOG })
        testing.eq(code, 1, out)
        testing.ok(out:find("needs:human", 1, true), out)
    end
)

testing.test("a move into an empty column leaves ls ordered by column", function()
    local root, home = local_board()
    dev(root, home, {
        "board",
        "add",
        "One",
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
    local two = prefix_of((dev(root, home, {
        "board",
        "add",
        "Two",
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
    })))
    dev(root, home, { "board", "move", two, Column.ICEBOX })
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
    testing.eq(out, "No findings.\n")
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
    out, code = dev(root, home, { "board", "move", id, Column.READY }, one)
    testing.eq(code, 0, out)
    dev(root, home, {
        "board",
        "add",
        "Plain",
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
    testing.ok(out:find("This project is private and has no board.", 1, true), out)
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
            "## Problem\nlook in src/a.lua\n\n## Change\nx\n\n## Out of scope\ny\n",
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
            "--change",
            "x",
            "--out-of-scope",
            "y",
            "--done-when",
            "a",
        })
        testing.ok(plain:find("^added %x+ Backlog\n$"), plain)
    end
)

testing.test(
    "add links a card once when --blocked-by and --from name it and relates it for --from alone",
    function()
        -- Add a base card and two cards that name it by its prefix
        local root, home = local_board()
        local base = prefix_of((dev(root, home, {
            "board",
            "add",
            "Base",
            "--size",
            "1",
            "--problem",
            "why",
            "--change",
            "x",
            "--out-of-scope",
            "y",
            "--done-when",
            "a",
        })))
        local both, code = dev(root, home, {
            "board",
            "add",
            "Both",
            "--size",
            "1",
            "--problem",
            "why",
            "--change",
            "x",
            "--out-of-scope",
            "y",
            "--done-when",
            "a",
            "--blocked-by",
            base,
            "--from",
            base,
        })
        testing.eq(code, 0, both)
        local plain
        plain, code = dev(root, home, {
            "board",
            "add",
            "Plain",
            "--size",
            "1",
            "--problem",
            "why",
            "--change",
            "x",
            "--out-of-scope",
            "y",
            "--done-when",
            "a",
            "--from",
            base,
        })
        testing.eq(code, 0, plain)

        -- Expect one blocked_by link on the first and one related link on the second
        local kinds = {}
        for _, card in ipairs(document(file_of(home)).cards) do
            kinds[card.name] = card.links
        end
        testing.eq(#kinds.Both, 1)
        testing.eq(kinds.Both[1].kind, "blocked_by")
        testing.eq(#kinds.Plain, 1)
        testing.eq(kinds.Plain[1].kind, "related")
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
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "2",
        "--done-when",
        "a",
    })
    testing.ok(code ~= 0, out)
    testing.eq(out:find(QUEUED, 1, true), nil)
    testing.eq(fs.exists(queue_path(home)), false)
    out, code = pomb_dev(root, home, {
        "board",
        "add",
        "Later",
        "--id-only",
        "--blocked-by",
        "deadbeef",
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
    out, code = pomb_dev(root, home, {
        "board",
        "add",
        "Later",
        "--id-only",
        "--lane",
        "side",
        "--checks",
        "dev test",
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

testing.test("an add whose problem is --id-only is queued while Pomb is down", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, {
        "board",
        "add",
        "Later",
        "--problem",
        "--id-only",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "2",
        "--done-when",
        "a",
    })
    testing.eq(code, 0, out)
    testing.ok(out:find(QUEUED, 1, true), out)
    testing.eq(fs.exists(queue_path(home)), true)
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
        "--change",
        "x",
        "--out-of-scope",
        "y",
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
            Column.READY,
            "--size",
            size,
            "--description",
            PLANNED,
            "--done-when",
            JUDGED,
            "--done-when",
            JUDGED,
            "--done-when",
            JUDGED,
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
    out, code = dev(root, home, { "board", "move", big, Column.PROGRESS }, env)
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
    out, code = dev(
        root,
        home,
        { "board", "move", big, Column.PROGRESS },
        { DEV_AGENT = "r/one", DEV_MAX_SIZE = "" }
    )
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "note", big, "built it" }, { DEV_AGENT = "r/one" })
    testing.eq(code, 0, out)
    out, code = dev(
        root,
        home,
        { "board", "move", big, Column.REVIEW },
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
    out, code = dev(root, home, { "board", "move", big, Column.PROGRESS, "--max-size", "1" }, env)
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
            dev(root, home, { "board", "move", big, Column.PROGRESS, "--max-size", word }, env)
        testing.eq(code, 2, out)
    end
end)

testing.test("move refuses a --max-size that is not 1, 2 or 3 into any column", function()
    local root, home, big = sized_board()
    local out, code = dev(root, home, { "board", "move", big, Column.BACKLOG, "--max-size", "9" })
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
    out, code = dev(root, home, { "board", "move", big, Column.PROGRESS }, env)
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
            .. '","column_id":"'
            .. READY_COLUMN
            .. '","color_id":"'
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
            "--change",
            "x",
            "--out-of-scope",
            "y",
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
    local out, code = dev(root, home, { "board", "move", epic, Column.DONE })
    testing.eq(code, 1, out)
    testing.ok(out:find("is an epic and cannot enter Done, a done column", 1, true), out)
    testing.ok(out:find("1 of 1 children are open", 1, true), out)
    out, code = support.to_review(function(args)
        return dev(root, home, args)
    end, epic)
    testing.eq(code, 0, out)
    tick_first(root, home, child)
    dev(root, home, { "board", "move", child, Column.DONE })
    out, code = dev(root, home, { "board", "move", epic, Column.DONE })
    testing.eq(code, 0, out)
    dev(root, home, { "board", "move", child, Column.BACKLOG })
    out, code = dev(root, home, { "board", "move", epic, Column.BACKLOG })
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
            Column.READY,
            "--size",
            "1",
            "--description",
            PLANNED,
            "--done-when",
            JUDGED,
            "--done-when",
            JUDGED,
            "--done-when",
            JUDGED,
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
    out = dev(root, home, { "board", "next", "--column", Column.READY })
    testing.ok(out:find(child, 1, true) and not out:find(epic, 1, true), out)
    tick_all(root, home, child)
    out = dev(root, home, { "board", "move", child, Column.DONE })
    out = dev(root, home, { "board", "next" })
    testing.ok(out:find(epic .. "  Ready", 1, true), out)
    out = dev(root, home, { "board", "move", epic, Column.PROGRESS }, { DEV_AGENT = "r/one" })
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
            "--change",
            "x",
            "--out-of-scope",
            "y",
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
    testing.ok(out:find("Make it one with `dev board epic " .. plain, 1, true), out)
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
        "--change",
        "x",
        "--out-of-scope",
        "y",
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
        "--change",
        "x",
        "--out-of-scope",
        "y",
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
        Column.READY,
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
    out, code = dev(root, home, { "board", "move", epic, Column.BACKLOG })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", epic, Column.READY })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "lint" })
    testing.eq(code, 0, out)
    testing.eq(out:find("lacks 3 to 7", 1, true), nil, out)
end)

testing.test("attach, attachments and detach refuse plainly on a local board", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
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
    })))
    local file = support.tempdir() .. "/shot.png"
    assert(fs.write(file, "x"))
    for _, args in ipairs({
        { "board", "attach", a, file },
        { "board", "attachments", a },
        { "board", "detach", a, "abcd" },
        { "board", "download", a, "abcd" },
    }) do
        local out, code = dev(root, home, args)
        testing.eq(code, 1, out)
        testing.ok(out:find("a local board holds no attachments", 1, true), out)
    end
end)

local function laned_board()
    local root, home = local_board()
    local ids = {}
    for _, name in ipairs({ "Alpha", "Bravo", "Charlie" }) do
        local out = dev(root, home, {
            "board",
            "add",
            name,
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
        ids[name] = prefix_of(out)
    end
    local doc = document(file_of(home))
    doc.swimlanes = {
        { id = "lane-parity", name = "Parity" },
        { id = "lane-fixes", name = "Fixes" },
    }
    doc.cards[1].swimlane_id = "lane-fixes"
    doc.cards[2].swimlane_id = "lane-parity"
    doc.cards[3].swimlane_id = "lane-parity"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    return root, home, ids
end

testing.test("local orders cards by lane then position", function()
    local root, home, ids = laned_board()
    local out = dev(root, home, { "board", "ls", "--column", Column.BACKLOG })
    local rows = {}
    local pattern = support.COLUMN_NAME.BACKLOG .. "%s+(%S+)%s+%S+%s+%S+%s+%S+%s+%S+%s+(%S+)"
    for lane, name in out:gmatch(pattern) do
        rows[#rows + 1] = lane .. " " .. name
    end
    testing.eq(rows, { "Parity Bravo", "Parity Charlie", "Fixes Alpha" })
    out = dev(root, home, { "board", "next", "--column", Column.BACKLOG })
    local want = ids.Bravo .. "  " .. support.COLUMN_NAME.BACKLOG .. "  Parity  "
    testing.ok(out:find(want, 1, true), out)
end)

testing.test("local puts column order before lane order", function()
    local root, home, ids = laned_board()
    local out, code = dev(root, home, { "board", "move", ids.Alpha, Column.ICEBOX })
    testing.eq(code, 0, out)
    out = dev(root, home, { "board", "ls" })
    local names = {}
    for line in out:gmatch("[^\n]+") do
        names[#names + 1] = line:match("(%S+)$")
    end
    testing.eq(names, { "Alpha", "Bravo", "Charlie" })
end)

testing.test("local sorts a card with no lane last with no lane name", function()
    local root, home = laned_board()
    local doc = document(file_of(home))
    doc.cards[2].swimlane_id = nil
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    local out = dev(root, home, { "board", "ls", "--column", Column.BACKLOG })
    local rows = {}
    local pattern = support.COLUMN_NAME.BACKLOG .. "%s+(%S+)%s+%S+%s+%S+%s+%S+%s+%S+%s+(%S+)"
    for lane, name in out:gmatch(pattern) do
        rows[#rows + 1] = lane .. " " .. name
    end
    testing.eq(rows, { "Parity Charlie", "Fixes Alpha", "- Bravo" })
end)

testing.test("local add with a lane puts the card in that lane", function()
    local root, home = laned_board()
    local args = {
        "board",
        "add",
        "Delta",
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
    local out, code = dev(root, home, args)
    testing.eq(code, 0, out)
    table.insert(args, "--lane")
    table.insert(args, "fixes")
    args[3] = "Echo"
    out, code = dev(root, home, args)
    testing.eq(code, 0, out)
    local cards = document(file_of(home)).cards
    testing.eq(cards[4].swimlane_id, nil)
    testing.eq(cards[5].swimlane_id, "lane-fixes")
end)

testing.test("local move keeps the lane unless a lane is given", function()
    local root, home, ids = laned_board()
    local function lane_of(name)
        for _, card in ipairs(document(file_of(home)).cards) do
            if card.name == name then
                return card.swimlane_id
            end
        end
    end
    local out, code = dev(root, home, { "board", "move", ids.Alpha, Column.ICEBOX })
    testing.eq(code, 0, out)
    testing.eq(lane_of("Alpha"), "lane-fixes")
    out, code = dev(root, home, { "board", "move", ids.Alpha, Column.ICEBOX, "--lane", "Parity" })
    testing.eq(code, 0, out)
    testing.eq(lane_of("Alpha"), "lane-parity")
end)

testing.test("local ls and next with a lane list only that lane", function()
    local root, home, ids = laned_board()
    local out = dev(root, home, { "board", "ls", "--lane", "fixes" })
    testing.ok(out:find("Alpha", 1, true), out)
    testing.ok(not out:find("Bravo", 1, true) and not out:find("Charlie", 1, true), out)
    out = dev(root, home, { "board", "next", "--column", Column.BACKLOG, "--lane", "Fixes" })
    testing.ok(out:find(ids.Alpha, 1, true), out)
end)

testing.test("local a lane the board lacks is refused", function()
    local root, home, ids = laned_board()
    for _, args in ipairs({
        { "board", "ls", "--lane", "Features" },
        { "board", "next", "--lane", "Features" },
        { "board", "move", ids.Alpha, Column.ICEBOX, "--lane", "Features" },
        { "board", "add", "New", "--lane", "Features" },
    }) do
        local out, code = dev(root, home, args)
        testing.eq(code, 2, out)
        testing.ok(out:find("Unknown lane Features. The lanes are Parity, Fixes.", 1, true), out)
    end
end)

testing.test("a local board with one lane prints no lane", function()
    local root, home, ids = laned_board()
    local doc = document(file_of(home))
    doc.swimlanes = { { id = "lane-parity", name = "Parity" } }
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    local out = dev(root, home, { "board", "show", ids.Alpha })
    testing.ok(not out:find("Parity", 1, true), out)
    out = dev(root, home, { "board", "ls", "--column", Column.BACKLOG })
    testing.ok(not out:find("Parity", 1, true), out)
end)

testing.test("local init creates the lanes the board config lists once", function()
    local root, home =
        setup('[board]\nbackend = "local"\nname = "mine"\nlanes = ["Parity", "Fixes"]\n')
    local out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)
    testing.ok(out:find('created lane "Parity"\ncreated lane "Fixes"\n', 1, true), out)
    local doc = document(file_of(home))
    testing.eq(#doc.swimlanes, 2)
    testing.eq(doc.swimlanes[1].name, "Parity")
    testing.eq(doc.swimlanes[2].name, "Fixes")
    out = dev(root, home, { "board", "init" })
    testing.ok(out:find("already follows the standard", 1, true), out)
    testing.eq(#document(file_of(home)).swimlanes, 2)
end)

testing.test("local init says nothing about an unlisted first lane", function()
    -- Create the lanes the config lists
    local root, home =
        setup('[board]\nbackend = "local"\nname = "mine"\nlanes = ["Parity", "Fixes"]\n')
    local out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)

    -- Give the board a first lane the config does not list
    local doc = document(file_of(home))
    doc.swimlanes = { { id = "lane-default", name = "Default" } }
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- Run init again over the unlisted first lane
    out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)

    -- Expect the new lane and no warning
    testing.ok(out:find('created lane "Parity"', 1, true), out)
    testing.ok(not out:find("first lane", 1, true), out)
end)
