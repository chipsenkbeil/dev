local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local runtime = require("@dev/runtime")
local board = require("@dev/board")
local localboard = require("@dev/board/localboard")
local store = require("@dev/board/store")
local fs = require("@dev/fs")
local json = require("@dev/json")
local support = require("./support")

local Column = support.Column
local READY_COLUMN = support.column_id(Column.READY)

local TOKEN = "pomb_SECRETtoken0123456789"
local ID_A = "aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa"
local ID_B = "bbbbbbbb-1111-4bbb-8bbb-bbbbbbbbbbbb"
local ID_C = "cccccccc-1111-4ccc-8ccc-cccccccccccc"

local PLANNED = support.READY_DESCRIPTION
local JUDGED = "done (reviewer judgement)"
local YELLOW_ID = "yellow-id"
local BLUE_ID = "blue-id"

local LOCAL_PROJECT = table.concat({
    "[board]",
    'backend = "local"',
    'name = "mine"',
    "",
}, "\n")

local function setup(project)
    local root = support.sandbox({ [".dev/config.toml"] = project }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(fs.write(
        home .. "/.config/dev/config.toml",
        table.concat({
            "[board.pomb]",
            'url = "https://pomb.example"',
            'field_prefix = "runner"',
            'token = "pass:secrets/worker/token/pomb"',
            "",
        }, "\n")
    ))
    return root, home
end

local function env_of(home, extra)
    local env = {
        HOME = home,
        XDG_STATE_HOME = home .. "/state",
        CLAUDE_SESSION_ID = "one",
        DEV_AGENT = "dotfiles/one",
        DEV_PASS_LOCK = home .. "/pass.lock",
    }
    for name, value in pairs(extra or {}) do
        env[name] = value
    end
    return env
end

local SERVERS = {}
local sync

local function dev(root, home, args, extra)
    if SERVERS[root] then
        sync(root, home)
    end
    return support.dev(root, args, { env = env_of(home, extra) })
end

local function local_board(project)
    local root, home = setup(project or LOCAL_PROJECT)
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

local function hold_for_owner(home, id)
    local doc = document(file_of(home))
    for _, card in ipairs(doc.cards) do
        if card.id:sub(1, #id) == id then
            card.labels = { board.NEEDS_HUMAN }
            assert(fs.write(file_of(home), assert(json.encode(doc))))
            return
        end
    end
    error("no card " .. id)
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
    return string.format("%o", bit32.band(assert(fs.stat(path)).mode, 511))
end

testing.test("init lays out the nine columns and the palette and is idempotent", function()
    -- Init a fresh local board and expect every column added
    local root, home = setup(LOCAL_PROJECT)
    local out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)
    testing.ok(out:find("created board mine with no template", 1, true), out)
    for _, column in ipairs({
        support.COLUMN_NAME.ICEBOX,
        support.COLUMN_NAME.BACKLOG,
        support.COLUMN_NAME.READY,
        support.COLUMN_NAME.PROGRESS,
        support.COLUMN_NAME.REVIEW,
        support.COLUMN_NAME.VERIFY,
        support.COLUMN_NAME.RELEASE,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.DONE,
    }) do
        testing.ok(out:find("added column " .. column, 1, true), out)
    end
    testing.ok(out:find('named yellow "1 Pomodoro"', 1, true), out)
    testing.ok(out:find('named white "Unsized"', 1, true), out)
    testing.ok(out:find("made white the default colour", 1, true), out)

    -- Read the stored columns back in order
    local doc = document(file_of(home))
    local names = {}
    for _, column in ipairs(doc.columns) do
        names[#names + 1] = column.name
    end
    testing.eq(names, {
        support.COLUMN_NAME.ICEBOX,
        support.COLUMN_NAME.BACKLOG,
        support.COLUMN_NAME.READY,
        support.COLUMN_NAME.PROGRESS,
        support.COLUMN_NAME.REVIEW,
        support.COLUMN_NAME.VERIFY,
        support.COLUMN_NAME.RELEASE,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.DONE,
    })
    testing.eq(doc.columns[9].is_done, true)

    -- Read the stored palette back in order
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

    -- Init again and expect nothing changed
    out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(out, "Board mine already follows the standard. Nothing changed.\n")
end)

testing.test("init renames a local In Review column to Review and keeps its card", function()
    -- Park a card in a column named In Review
    local root, home = local_board()
    local out, code = dev(root, home, { "board", "add", "Held", "--column", Column.ICEBOX })
    testing.eq(code, 0, out)
    local doc = document(file_of(home))
    local review
    for _, column in ipairs(doc.columns) do
        if column.name == support.COLUMN_NAME.REVIEW then
            review = column
        end
    end
    local id = review.id
    review.name = support.COLUMN_NAME.IN_REVIEW
    doc.cards[1].column_id = id
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- Run init to rename the column
    out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)

    -- Check the column keeps its id and the card stays in it
    doc = document(file_of(home))
    local renamed
    for _, column in ipairs(doc.columns) do
        if column.id == id then
            renamed = column
        end
    end
    testing.eq(renamed.name, support.COLUMN_NAME.REVIEW)
    testing.eq(doc.cards[1].column_id, id)

    -- Run init again and expect no change
    local first = assert(fs.read(file_of(home)))
    out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(out, "Board mine already follows the standard. Nothing changed.\n")
    testing.eq(assert(fs.read(file_of(home))), first)
end)

testing.test("a local init makes one landing turn card and a second init adds none", function()
    -- Run init on a new local board
    local root, home = setup(LOCAL_PROJECT)
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
    testing.eq(out, "A local board links only its own cards, so other is not reachable.\n")
    out, code = dev(root, home, { "board", "note", "11111111", "--board", "other", "text" })
    testing.eq(code, 1, out)
    testing.eq(out, "A local board links only its own cards, so other is not reachable.\n")
end)

testing.test("edit --board reaches the dispatcher and a local board refuses it", function()
    local root, home = local_board()
    assert(fs.write(root .. "/plan.md", table.concat({ "## Problem", "from a file", "" }, "\n")))
    local out, code = dev(
        root,
        home,
        { "board", "edit", "11111111", "--board", "other", "--file", root .. "/plan.md" }
    )
    testing.eq(code, 1, out)
    testing.eq(out, "A local board links only its own cards, so other is not reachable.\n")
end)

testing.test("move to board on a local board names Pomb and refuses", function()
    local root, home = local_board()
    local out, code = dev(root, home, {
        "board",
        "add",
        "Write docs",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        JUDGED,
        "--checks",
        "dev test",
    })
    testing.eq(code, 0, out)
    local id = prefix_of(out)
    out, code = dev(root, home, { "board", "move", id, Column.READY, "--to-board", "other" })
    testing.eq(code, 1, out)
    testing.eq(
        out,
        "A local board cannot move a card to other. Moving between boards needs Pomb.\n"
    )
end)

testing.test("boards and columns answer for a local board's own name only", function()
    -- List the boards and expect only this one
    local root, home = local_board()
    local out, code = dev(root, home, { "board", "boards" })
    testing.eq(code, 0, out)
    testing.eq(out, "mine\n")

    -- List the columns by default and by the board's own name
    local columns = table.concat({
        "Icebox",
        "Backlog",
        "Ready",
        "In Progress",
        "Review",
        "Verify",
        "Release",
        "Blocked",
        "Done (done)",
        "",
    }, "\n")
    out, code = dev(root, home, { "board", "columns" })
    testing.eq(code, 0, out)
    testing.eq(out, columns)
    out, code = dev(root, home, { "board", "columns", "mine" })
    testing.eq(code, 0, out)
    testing.eq(out, columns)

    -- Refuse another board and a stray argument
    out, code = dev(root, home, { "board", "columns", "other" })
    testing.eq(code, 1, out)
    testing.eq(out, "A local board knows only its own columns, so other is not reachable.\n")
    out, code = dev(root, home, { "board", "columns", "mine", "extra" })
    testing.eq(code, 2, out)
    out, code = dev(root, home, { "board", "boards", "extra" })
    testing.eq(code, 2, out)
end)

testing.test("add, ls, next, move, size and label work on a local board", function()
    -- Add a ready card with a size and labels
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
    testing.ok(out:find(support.COLUMN_NAME.READY, 1, true), out)

    -- Add a second card to the backlog
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

    -- List the cards, then filter by size and label
    out = dev(root, home, { "board", "ls" })
    testing.eq(
        out,
        table.concat({
            b .. "  Backlog  1 Pomodoro  -                0/1  Second",
            a .. "  Ready    2 Pomodori  docs,needs:lead  0/3  Write docs",
            "",
        }, "\n")
    )
    out = dev(root, home, { "board", "ls", "--size", "3+" })
    testing.eq(out, "No cards.\n")
    out = dev(root, home, { "board", "ls", "--label", "docs" })
    testing.ok(out:find("Write docs", 1, true), out)

    -- Offer the next ready card, then move it out of Ready
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

    -- Resize one card and relabel the other
    out = dev(root, home, { "board", "size", b, "1" })
    testing.eq(out, "sized " .. b .. " 1\n")
    out = dev(root, home, { "board", "label", a, "+extra", "--remove", "docs" })
    testing.eq(out, "labelled " .. a .. " needs:lead,extra\n")

    -- Finish the first card and expect it in Done
    tick_all(root, home, a)
    out = dev(root, home, { "board", "move", a, Column.DONE })
    out = dev(root, home, { "board", "ls" })
    testing.eq(out, b .. "  Backlog  1 Pomodoro  -  0/1  Second\n")
    out = dev(root, home, { "board", "ls", "--column", Column.DONE })
    testing.ok(out:find("Done  2 Pomodori", 1, true), out)
end)

testing.test("edit replaces a local card's description from a file or standard input", function()
    -- Add a card with an old description
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

    -- Replace the description from a file
    assert(
        fs.write(root .. "/plan.md", table.concat({ "## Problem", "from a file", "", "" }, "\n"))
    )
    local out, code = dev(root, home, { "board", "edit", a, "--file", root .. "/plan.md" })
    testing.eq(code, 0, out)
    testing.eq(out, "edited " .. a .. "\n")
    testing.eq(document(file_of(home)).cards[1].description, "## Problem\nfrom a file")

    -- Replace it again from standard input
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
        -- Hold a card for the owner
        local root, home = local_board()
        local a =
            prefix_of((dev(root, home, { "board", "add", "First", "--column", Column.ICEBOX })))
        hold_for_owner(home, a)

        -- Comment on it as an agent
        local out, code = dev(root, home, { "board", "note", a, "still open" })
        testing.eq(code, 0, out)

        -- Expect the stale report to leave it unanswered
        out = dev(root, home, { "board", "stale" })
        testing.ok(out:find("for the owner (needs:human):", 1, true), out)
        testing.ok(not out:find("answered", 1, true), out)
    end
)

testing.test("stale marks a local needs:human card whose newest comment is the owner's", function()
    -- Hold a card for the owner
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "First", "--column", Column.ICEBOX })))
    hold_for_owner(home, a)

    -- Comment on it as an agent
    local out, code = dev(root, home, { "board", "note", a, "which way" })
    testing.eq(code, 0, out)

    -- Rewrite that comment as the owner's
    local doc = document(file_of(home))
    doc.cards[1].comments[1].who = "human"
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- Expect the stale report to list the card as answered
    out = dev(root, home, { "board", "stale" })
    testing.ok(out:find("(answered, waiting for your move)", 1, true), out)
end)

testing.test("stale lists a local card the owner moved out of Blocked", function()
    -- Add a ready card
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Moved",
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

    -- Leave the owner's label on it from long ago
    local doc = document(file_of(home))
    doc.cards[1].labels = { board.NEEDS_HUMAN }
    doc.cards[1].entered_at = "2020-01-01T00:00:00Z"
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- Expect the stale report to list it as moved by the owner
    local out = dev(root, home, { "board", "stale" })
    testing.ok(out:find("moved by the owner, remove needs:human:", 1, true), out)
    testing.ok(out:find(a .. "  Ready  ", 1, true), out)
end)

testing.test("answer posts the quote and frees a local needs:human card", function()
    -- Hold a card for the owner
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "First", "--column", Column.ICEBOX })))
    hold_for_owner(home, a)

    -- Answer it with a choice and a quote
    local out, code =
        dev(root, home, { "board", "answer", a, "--choice", "2", "--quote", "go ahead" })
    testing.eq(code, 0, out)
    testing.eq(out, "answered " .. a .. " with choice 2\n")

    -- Expect the answer recorded and the hold freed
    out = dev(root, home, { "board", "show", a })
    testing.ok(
        out:find("Owner's answer, typed in this session: choice 2, quote: go ahead", 1, true),
        out
    )
    testing.ok(not out:find("needs:human", 1, true), out)

    -- Refuse a second answer
    out, code = dev(root, home, { "board", "answer", a, "--choice", "2", "--quote", "again" })
    testing.eq(code, 1, out)
end)

testing.test("next --column backlog skips a needs:human card", function()
    -- Add two cards and hold the first for the owner
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "First", "--column", Column.ICEBOX })))
    local b = prefix_of((dev(root, home, { "board", "add", "Second", "--column", Column.ICEBOX })))
    hold_for_owner(home, a)

    -- Expect next to skip the held card
    local out, code = dev(root, home, { "board", "next", "--column", Column.ICEBOX })
    testing.eq(code, 0, out)
    testing.ok(out:find(b, 1, true) and not out:find(a, 1, true), out)

    -- Expect nothing offered from Backlog
    out = dev(root, home, { "board", "next", "--column", Column.BACKLOG })
    testing.eq(out, "No cards in Backlog.\n")
end)

testing.test("next --column icebox never offers the landing turn card", function()
    -- Add a card named like the landing turn card
    local root, home = local_board()
    dev(root, home, { "board", "add", "landing turn", "--column", Column.ICEBOX })

    -- Expect next to offer nothing
    local out = dev(root, home, { "board", "next", "--column", Column.ICEBOX })
    testing.eq(out, "No cards in Icebox.\n")

    -- Add a real card and expect it alone is offered
    local other =
        prefix_of((dev(root, home, { "board", "add", "Other", "--column", Column.ICEBOX })))
    out = dev(root, home, { "board", "next", "--column", Column.ICEBOX })
    testing.ok(out:find(other, 1, true) and not out:find("landing turn", 1, true), out)
end)

testing.test("next --column blocked returns the top unclaimed needs:lead card only", function()
    -- Define a helper that adds a card to Blocked
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

    -- Add one card per label
    blocked("Plain", "docs")
    blocked("Human", "needs:human")
    local claimed = blocked("Claimed", "needs:lead")
    local free = blocked("Free", "needs:lead")

    -- Claim one needs:lead card
    local out, code = dev(root, home, { "board", "take", claimed })
    testing.eq(code, 0, out)

    -- Expect next to name the free needs:lead card
    out, code = dev(root, home, { "board", "next", "--column", Column.BLOCKED })
    testing.eq(code, 0, out)
    testing.ok(out:find(free, 1, true) and out:find("Free", 1, true), out)

    -- Hold the free card and expect nothing offered
    hold_for_owner(home, free)
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
    -- Add a card
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

    -- Rename it
    local out, code = dev(root, home, { "board", "rename", a, "Better", "title" })
    testing.eq(code, 0, out)
    testing.eq(out, "renamed " .. a .. "\n")
    testing.eq(document(file_of(home)).cards[1].name, "Better title")

    -- Refuse a blank title
    out, code = dev(root, home, { "board", "rename", a, " " })
    testing.eq(code, 2, out)
    testing.eq(document(file_of(home)).cards[1].name, "Better title")
end)

testing.test("next --column backlog and icebox skip a claimed card", function()
    local root, home = local_board()
    for _, column in ipairs({ Column.BACKLOG, Column.ICEBOX }) do
        -- Define a helper that adds a planned card to the column
        local function planned(name)
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
                JUDGED,
                "--done-when",
                JUDGED,
                "--done-when",
                JUDGED,
                "--checks",
                "dev test",
            })
            testing.eq(code, 0, out)
            return prefix_of(out)
        end

        -- Add a claimed and an unclaimed card
        local claimed = planned("Claimed " .. column)
        local free = planned("Free " .. column)
        local out, code = dev(root, home, { "board", "take", claimed })
        testing.eq(code, 0, out)

        -- Expect next to name only the unclaimed card
        out, code = dev(root, home, { "board", "next", "--column", column })
        testing.eq(code, 0, out)
        testing.ok(out:find(free, 1, true) and out:find("Free " .. column, 1, true), out)
        testing.eq(out:find(claimed, 1, true), nil)
    end
end)

testing.test("discard notes the reason, labels the card and moves it to Done", function()
    -- Add a card
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

    -- Discard it with a reason
    local out, code = dev(root, home, { "board", "discard", a, "--reason", "Not needed" })
    testing.eq(code, 0, out)
    testing.eq(out, "discarded " .. a .. "\n")

    -- Expect the reason noted and the card labelled
    local card = document(file_of(home)).cards[1]
    testing.eq(card.comments[1].kind, board.NoteKind.DECISION)
    testing.eq(card.comments[1].body, "Not needed")
    testing.eq(card.labels[1], "discarded")

    -- Expect the card in Done
    out = dev(root, home, { "board", "ls", "--column", Column.DONE })
    testing.ok(out:find(a, 1, true), out)
end)

testing.test("discard refuses a needs:human card and writes nothing", function()
    -- Add a card in Blocked
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

    -- Hold it for the owner
    hold_for_owner(home, a)

    -- Refuse to discard it
    local out, code = dev(root, home, { "board", "discard", a, "--reason", "Dropped" })
    testing.eq(code, 1, out)
    testing.ok(out:find("needs:human", 1, true), out)

    -- Expect nothing written to the card
    local card = document(file_of(home)).cards[1]
    testing.eq(#(card.comments or {}), 0)
    testing.eq(card.labels[1], "needs:human")
end)

testing.test("discard closes an unplanned Icebox card given a reason", function()
    -- Add an unplanned card
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

    -- Discard it with a reason
    local out, code = dev(root, home, { "board", "discard", a, "--reason", "Answered" })
    testing.eq(code, 0, out)
    testing.eq(out, "discarded " .. a .. "\n")

    -- Expect the reason noted and the card labelled
    local card = document(file_of(home)).cards[1]
    testing.eq(card.comments[1].body, "Answered")
    testing.eq(card.labels[1], "discarded")

    -- Expect the card in Done
    out = dev(root, home, { "board", "ls", "--column", Column.DONE })
    testing.ok(out:find(a, 1, true), out)
end)

testing.test(
    "discard refuses an unplanned Icebox card without a reason and writes nothing",
    function()
        -- Add an unplanned card
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

        -- Refuse to discard it without a reason
        local out, code = dev(root, home, { "board", "discard", a })
        testing.eq(code, 1, out)
        testing.ok(out:find("is not planned and cannot be discarded", 1, true), out)

        -- Expect nothing written to the card
        local card = document(file_of(home)).cards[1]
        testing.eq(#(card.comments or {}), 0)
        testing.eq(#(card.labels or {}), 0)

        -- Expect the card to stay in Icebox
        out = dev(root, home, { "board", "ls", "--column", Column.ICEBOX })
        testing.ok(out:find(a, 1, true), out)
    end
)

testing.test("discard refuses an unplanned card outside Icebox even with a reason", function()
    -- Add a card in Backlog
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

    -- Give it a description that is no plan
    local doc = document(file_of(home))
    doc.cards[1].description = "keep"
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- Refuse to discard it even with a reason
    local out, code = dev(root, home, { "board", "discard", a, "--reason", "Dropped" })
    testing.eq(code, 1, out)
    testing.ok(out:find("is not planned and cannot be discarded", 1, true), out)

    -- Expect nothing written and the card to stay in Backlog
    local card = document(file_of(home)).cards[1]
    testing.eq(#(card.comments or {}), 0)
    out = dev(root, home, { "board", "ls", "--column", Column.BACKLOG })
    testing.ok(out:find(a, 1, true), out)
end)

testing.test(
    "move to Done waits for every outcome to be ticked, and discard drops an open card",
    function()
        -- Add a card with one outcome
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

        -- Expect the move to Done refused while the outcome is unticked
        local out, code = dev(root, home, { "board", "move", a, Column.DONE })
        testing.eq(code, 1, out)
        testing.ok(out:find("1 of 1 outcomes are unticked (1. First works)", 1, true), out)

        -- Tick the outcome and expect the move to go through
        out, code = dev(root, home, { "board", "outcome", a, "--tick", "1", "--as", "r/reviewer" })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, Column.DONE })
        testing.eq(code, 0, out)
        testing.eq(out, "moved " .. a .. " to Done\n")

        -- Add a second card and discard it
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

        -- Expect the discarded card in Done
        out = dev(root, home, { "board", "ls", "--column", Column.DONE })
        testing.ok(out:find(b, 1, true), out)
    end
)

testing.test("edit refuses empty text, a missing file and an extra word", function()
    -- Add a card with a description
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

    -- Refuse blank standard input
    local out, code = support.dev(
        root,
        { "board", "edit", a },
        { env = env_of(home), input = table.concat({ " ", "", "" }, "\n") }
    )
    testing.eq(code, 2, out)

    -- Refuse a missing file and an extra word
    out, code = dev(root, home, { "board", "edit", a, "--file", root .. "/missing.md" })
    testing.eq(code, 2, out)
    out, code = dev(root, home, { "board", "edit", a, "extra" })
    testing.eq(code, 2, out)

    -- Expect the description unchanged
    testing.eq(document(file_of(home)).cards[1].description, "keep")
end)

testing.test("edit is refused under another process's claim fence", function()
    -- Add a card and take it
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        Column.ICEBOX,
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

    -- Move the claim fence on as another process would
    local doc = document(file_of(home))
    doc.cards[1].claim.fence = 9
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- Expect the edit refused and the description kept
    local out, code = support.dev(
        root,
        { "board", "edit", a },
        { env = env_of(home), input = "new\n" }
    )
    testing.eq(code, 1, out)
    testing.eq(document(file_of(home)).cards[1].description, PLANNED)
end)

testing.test("show prints a local card's description and notes", function()
    -- Add a card with a description
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

    -- Show the card with no comments
    local out = dev(root, home, { "board", "show", a })
    testing.eq(out, a .. "  Icebox  Unsized  -  Card\n\nwhy it matters\n\nno comments\n")

    -- Show it again after a note
    dev(root, home, { "board", "note", a, "hello" })
    out = dev(root, home, { "board", "show", a })
    testing.ok(out:find("\n\nwhy it matters\n\n%x+  agent  .-  hello\n$"), out)
end)

testing.test("notes, edit and delete work on a local board and refuse another author's", function()
    -- Add a card
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

    -- Add two notes and read their ids
    local out = dev(root, home, { "board", "note", a, "first", "thought" })
    testing.eq(out, "noted " .. a .. "\n")
    dev(root, home, { "board", "note", a, "second" })
    out = dev(root, home, { "board", "notes", a })
    local first = assert(out:match("^(%x+)"))
    testing.ok(out:find("agent  ", 1, true) and out:find("first thought", 1, true), out)
    local second = assert(out:match("\n(%x+)"))

    -- Edit the first note and delete the second
    out = dev(root, home, { "board", "note", a, "--edit", first, "better", "words" })
    testing.eq(out, "edited " .. a .. " " .. first .. "\n")
    out = dev(root, home, { "board", "note", a, "--delete", second })
    testing.eq(out, "deleted " .. a .. " " .. second .. "\n")
    out = dev(root, home, { "board", "notes", a })
    testing.ok(out:find("better words", 1, true) and not out:find("second", 1, true), out)

    -- Refuse an edit of a comment the owner wrote
    local doc = document(file_of(home))
    doc.cards[1].comments[1].who = "human"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    out = dev(root, home, { "board", "note", a, "--edit", first, "x" })
    testing.eq(out, "That comment is not yours to change.\n")
end)

testing.test("note --kind and --as are stored on a local comment and notes prints them", function()
    -- Add a card
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

    -- Add a decision note by a role and a plain note
    dev(root, home, { "board", "note", a, "--kind", "decision", "--as", "reviewer", "ship", "it" })
    dev(root, home, { "board", "note", a, "plain" })

    -- Expect notes to print the kind and the role
    local out = dev(root, home, { "board", "notes", a })
    testing.ok(
        out:find("agent  decision  reviewer  ", 1, true) and out:find("ship it", 1, true),
        out
    )
    testing.ok(out:find("agent  agent     -         ", 1, true), out)

    -- Refuse an unknown kind
    out = dev(root, home, { "board", "note", a, "--kind", "chatter", "x" })
    testing.ok(out:find("Unknown kind chatter", 1, true), out)

    -- Edit a note and expect its kind and role kept
    local first = assert(dev(root, home, { "board", "notes", a }):match("^(%x+)"))
    dev(root, home, { "board", "note", a, "--edit", first, "changed" })
    out = dev(root, home, { "board", "notes", a })
    testing.ok(out:find("decision  reviewer  ", 1, true) and out:find("changed", 1, true), out)
end)

testing.test("local time refuses with a message and writes nothing", function()
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
    local out, code = dev(root, home, { "board", "time", a, "5", "--as", "planner" })
    testing.eq(code, 1, out)
    testing.ok(out:find("A local board holds no time entries.", 1, true), out)
    testing.eq(#document(file_of(home)).cards[1].comments, 0)
end)

testing.test("local escalate swaps the label in one write", function()
    -- Add a card
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

    -- Park it in Blocked under another needs label
    dev(root, home, { "board", "move", a, Column.BLOCKED })
    dev(root, home, { "board", "label", a, "+docs", "+needs:planner" })

    -- Escalate it with a reason
    local out, code = dev(root, home, { "board", "escalate", a, "pick", "one" })
    testing.eq(code, 0, out)
    testing.eq(out, "escalated " .. a .. " to needs:lead\n")

    -- Expect the label swapped and the reason noted
    local card = document(file_of(home)).cards[1]
    testing.eq(card.labels, { "docs", "needs:lead" })
    testing.eq(#card.comments, 1)
    testing.eq(card.comments[1].kind, board.NoteKind.BLOCKED)
    testing.eq(card.comments[1].body, "pick one")
end)

testing.test(
    "link stores blocked_by, blocks and related on a local board and keeps next honest",
    function()
        -- Define a helper that adds a ready card
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

        -- Add three cards and link them in the three kinds
        local first, second, third = add("First"), add("Second"), add("Third")
        local out, code = dev(root, home, { "board", "link", first, "blocked_by", second })
        testing.eq(out, "linked " .. first .. " blocked_by " .. second .. "\n")
        testing.eq(code, 0)
        testing.eq(dev(root, home, { "board", "link", first, "blocked_by", second }), out)
        out = dev(root, home, { "board", "link", third, "blocks", second })
        testing.eq(out, "linked " .. third .. " blocks " .. second .. "\n")
        out = dev(root, home, { "board", "link", first, "related", third })
        testing.eq(out, "linked " .. first .. " related " .. third .. "\n")

        -- Read the stored links back from each card
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

        -- Finish each blocker in turn and expect next to follow the chain
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

testing.test("a blocker in Release does not hold a card on a local board", function()
    -- Define a helper that adds a ready card
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

    -- Add a card and link it behind a blocker
    local blocked, blocker = add("Blocked"), add("Blocker")
    dev(root, home, { "board", "link", blocked, "blocked_by", blocker })

    -- Define a helper that moves the blocker to a column
    local function place(name)
        local doc = document(file_of(home))
        local column_id
        for _, column in ipairs(doc.columns) do
            if column.name == name then
                column_id = column.id
            end
        end
        for _, card in ipairs(doc.cards) do
            if card.id:sub(1, #blocker) == blocker then
                card.column_id = column_id
            end
        end
        assert(fs.write(file_of(home), assert(json.encode(doc))))
    end

    -- Expect a blocker in Verify to hold the card
    place(support.COLUMN_NAME.VERIFY)
    testing.eq(dev(root, home, { "board", "next" }), "No ready cards.\n")

    -- Expect a blocker in Release to let it through
    place(support.COLUMN_NAME.RELEASE)
    local out = dev(root, home, { "board", "next" })
    testing.ok(out:find("^" .. blocked), out)
end)

testing.test("next returns a card whose blocker the board no longer holds", function()
    -- Define a helper that adds a ready card
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

    -- Add a card, link it behind a blocker and expect next to offer the blocker
    local blocked, blocker = add("Blocked"), add("Blocker")
    dev(root, home, { "board", "link", blocked, "blocked_by", blocker })
    local out = dev(root, home, { "board", "next" })
    testing.ok(out:find("^" .. blocker), out)

    -- Drop the blocker from the board file
    local doc = document(file_of(home))
    local kept = {}
    for _, card in ipairs(doc.cards) do
        if card.id:sub(1, 8) ~= blocker then
            kept[#kept + 1] = card
        end
    end
    doc.cards = kept
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- Expect next to offer the blocked card
    out = dev(root, home, { "board", "next" })
    testing.ok(out:find("^" .. blocked), out)
end)

testing.test(
    "links lists a card's own links and the reverse side of links other cards hold",
    function()
        -- Add three cards
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

        -- Link the first card behind one and beside the other
        dev(root, home, { "board", "link", a, "blocked_by", b })
        dev(root, home, { "board", "link", a, "related", c })

        -- Expect each card to list its own links and the reverse side of the rest
        local out, code = dev(root, home, { "board", "links", a })
        testing.eq(code, 0, out)
        testing.eq(
            out,
            "blocked_by  " .. b .. "  -  Backlog\nrelated     " .. c .. "  -  Backlog\n"
        )
        out = dev(root, home, { "board", "links", b })
        testing.eq(out, "blocks  " .. a .. "  -  Backlog\n")
        out = dev(root, home, { "board", "links", c })
        testing.eq(out, "related  " .. a .. "  -  Backlog\n")

        -- Link the reverse of a related link and expect no second entry
        dev(root, home, { "board", "link", c, "related", a })
        out = dev(root, home, { "board", "links", c })
        testing.eq(out, "related  " .. a .. "  -  Backlog\n")

        -- Read a card with no links and an unknown card
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
        -- Add three cards
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

        -- Link the first card behind one and beside the other
        dev(root, home, { "board", "link", a, "blocked_by", b })
        dev(root, home, { "board", "link", a, "related", c })

        -- Unlink the related card and expect the blocked_by link left
        local out, code = dev(root, home, { "board", "unlink", a, "related", c })
        testing.eq(code, 0, out)
        testing.eq(out, "unlinked " .. a .. " related " .. c .. "\n")
        testing.eq(
            dev(root, home, { "board", "links", a }),
            "blocked_by  " .. b .. "  -  Backlog\n"
        )

        -- Refuse an unlink from a card that holds no such link
        out, code = dev(root, home, { "board", "unlink", c, "related", a })
        testing.eq(code, 1, out)

        -- Unlink the blocked_by link from its reverse side
        out, code = dev(root, home, { "board", "unlink", b, "blocks", a })
        testing.eq(code, 0, out)
        testing.eq(dev(root, home, { "board", "links", a }), "No links.\n")

        -- Refuse to unlink a link that is already gone
        out, code = dev(root, home, { "board", "unlink", a, "blocked_by", b })
        testing.eq(code, 1, out)
        testing.ok(out:find("The card holds no blocked_by link to " .. b, 1, true), out)
    end
)

testing.test(
    "link refuses itself, a cycle, another board and a bad kind on a local board",
    function()
        -- Add three cards
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

        -- Refuse a link from a card to itself
        local out, code = dev(root, home, { "board", "link", a, "related", a })
        testing.eq(code, 1, out)
        testing.ok(out:find("itself", 1, true), out)

        -- Chain two links and refuse the ones that close a cycle
        dev(root, home, { "board", "link", a, "blocked_by", b })
        dev(root, home, { "board", "link", b, "blocked_by", c })
        out, code = dev(root, home, { "board", "link", c, "blocked_by", a })
        testing.eq(code, 1, out)
        testing.ok(out:find("wait on each other", 1, true), out)
        out, code = dev(root, home, { "board", "link", a, "blocks", c })
        testing.eq(code, 1, out)

        -- Refuse another board and an unknown kind
        out, code = dev(root, home, { "board", "link", a, "related", "other:" .. b })
        testing.eq(code, 1, out)
        testing.ok(out:find("links only its own cards", 1, true), out)
        out, code = dev(root, home, { "board", "link", a, "needs", b })
        testing.eq(code, 2, out)

        -- Expect only the two valid links stored
        local links = 0
        for _, card in ipairs(document(file_of(home)).cards) do
            links = links + #(card.links or {})
        end
        testing.eq(links, 2)
    end
)

testing.test("a local board refuses what the needs:human and epic rules forbid", function()
    -- Define a helper that adds a plain card
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

    -- Add two cards and an epic
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

    -- Refuse the owner's label on a card
    local out, code = dev(root, home, { "board", "label", card, "needs:human" })
    testing.eq(code, 1, out)
    testing.ok(out:find("dev board ask", 1, true), out)

    -- Hold the card in Blocked and expect its moves and edits refused
    dev(root, home, { "board", "move", card, Column.BLOCKED })
    hold_for_owner(home, card)
    out, code = dev(root, home, { "board", "move", card, Column.BACKLOG })
    testing.eq(code, 1, out)
    testing.ok(out:find("needs:human", 1, true), out)
    assert(fs.write(root .. "/plan.md", "new text\n"))
    out, code = dev(root, home, { "board", "edit", card, "--file", root .. "/plan.md" })
    testing.eq(code, 1, out)
    testing.ok(out:find("needs:human", 1, true), out)

    -- Expect a note allowed and the card movable once released
    out, code = dev(root, home, { "board", "note", card, "still allowed" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "label", card, "--remove", "needs:human" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", card, Column.BACKLOG })
    testing.eq(code, 0, out)

    -- Make the epic and refuse its move to Ready while a child is open
    dev(root, home, { "board", "epic", epic })
    dev(root, home, { "board", "link", child, "parent", epic })
    out, code = dev(root, home, { "board", "move", epic, Column.READY })
    testing.eq(code, 1, out)
    testing.ok(out:find("cannot enter Ready. 1 of 1 children are open.", 1, true), out)

    -- Finish the child and expect the epic to move
    tick_first(root, home, child)
    dev(root, home, { "board", "move", child, Column.DONE })
    out, code = dev(root, home, { "board", "move", epic, Column.READY })
    testing.eq(code, 0, out)
end)

testing.test("responsible is stored on a local card and show prints it only while set", function()
    -- Add a card
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

    -- Expect no one responsible by default
    local out, code = dev(root, home, { "board", "responsible", card })
    testing.eq(code, 0, out)
    testing.eq(out, card .. " none\n")

    -- Set someone responsible and read it back
    out, code = dev(root, home, { "board", "responsible", card, "dotfiles/lead" })
    testing.eq(code, 0, out)
    testing.eq(out, "set " .. card .. " responsible dotfiles/lead\n")
    testing.eq(dev(root, home, { "board", "responsible", card }), card .. " dotfiles/lead\n")
    out = dev(root, home, { "board", "show", card })
    testing.ok(out:find("\nresponsible: dotfiles/lead\n", 1, true), out)

    -- Clear it and expect show to drop the line
    out, code = dev(root, home, { "board", "responsible", card, "--clear" })
    testing.eq(code, 0, out)
    testing.eq(out, "cleared " .. card .. " responsible\n")
    out = dev(root, home, { "board", "show", card })
    testing.ok(not out:find("responsible:", 1, true), out)
end)

testing.test("links prints the column of each linked card", function()
    -- Define a helper that adds a card to a column
    local root, home = local_board()
    local function plain(name, column)
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
            "--column",
            column,
        })))
    end

    -- Add three cards and link the first to the others
    local a = plain("A", Column.BACKLOG)
    local b = plain("B", Column.ICEBOX)
    local c = plain("C", Column.BACKLOG)
    dev(root, home, { "board", "link", a, "blocked_by", b })
    dev(root, home, { "board", "link", a, "related", c })

    -- Expect links to name the column of each linked card
    local out, code = dev(root, home, { "board", "links", a })
    testing.eq(code, 0, out)
    testing.eq(out, "blocked_by  " .. b .. "  -  Icebox\nrelated     " .. c .. "  -  Backlog\n")

    -- Move a linked card and expect links to follow it
    out, code = dev(root, home, { "board", "move", b, Column.BACKLOG })
    testing.eq(code, 0, out)
    out = dev(root, home, { "board", "links", a })
    testing.eq(out, "blocked_by  " .. b .. "  -  Backlog\nrelated     " .. c .. "  -  Backlog\n")
end)

testing.test("link parent sets one epic and show and links report it", function()
    -- Define a helper that adds a plain card
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

    -- Add four cards and make three of them epics
    local epic, one, two, other = add("Epic"), add("One"), add("Two"), add("Other")
    dev(root, home, { "board", "epic", epic })
    dev(root, home, { "board", "epic", one })
    dev(root, home, { "board", "epic", other })

    -- Link a child to the epic and expect a repeat to change nothing
    local out, code = dev(root, home, { "board", "link", one, "parent", epic })
    testing.eq(out, "linked " .. one .. " parent " .. epic .. "\n")
    testing.eq(code, 0)
    testing.eq(dev(root, home, { "board", "link", one, "parent", epic }), out)
    dev(root, home, { "board", "link", two, "parent", epic })

    -- Refuse a second parent and a cycle of epics
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

    -- Expect show to report the parent and the child count
    out = dev(root, home, { "board", "show", one })
    testing.ok(out:find("\nparent: " .. epic .. " Epic\n", 1, true), out)
    out = dev(root, home, { "board", "show", epic })
    testing.ok(out:find("\nchildren: 0 of 2 done\n", 1, true), out)

    -- Refuse to finish a child that still has open children, then finish both
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

    -- Expect links to name the parent and the child
    out = dev(root, home, { "board", "links", one })
    testing.ok(out:find("parent", 1, true) and out:find(epic, 1, true), out)
    out = dev(root, home, { "board", "links", epic })
    testing.ok(out:find("child", 1, true) and out:find(one, 1, true), out)
end)

testing.test("stale counts the days a card sat in its column", function()
    -- Add a ready card
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

    -- Add a second ready card
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

    -- Age the first card by years
    local doc = document(file_of(home))
    doc.cards[1].entered_at = "2020-01-01T00:00:00Z"
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- Expect only the aged card listed as stale
    local out = dev(root, home, { "board", "stale" })
    testing.ok(out:find(a .. "  Ready  ", 1, true) and out:find("Old", 1, true), out)
    testing.ok(not out:find("New", 1, true), out)
end)

testing.test("a local board keeps an unsized or red card out of Ready", function()
    -- Add an unsized card
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

    -- Refuse its move to Ready or Backlog without a size
    local out, code = dev(root, home, { "board", "move", a, Column.READY })
    testing.eq(code, 1)
    testing.ok(out:find("dev board size", 1, true), out)
    out, code = dev(root, home, { "board", "move", a, Column.BACKLOG })
    testing.eq(code, 1)
    testing.ok(out:find("a size", 1, true), out)

    -- Refuse a direct add without a size
    out, code = dev(root, home, { "board", "add", "Direct", "--column", Column.READY })
    testing.eq(code, 2)
    out, code = dev(root, home, { "board", "add", "Direct", "--problem", "x" })
    testing.eq(code, 2)
    testing.ok(out:find("a size", 1, true), out)

    -- Size it red and expect Ready to refuse it
    dev(root, home, { "board", "size", a, "3+" })
    out, code = dev(root, home, { "board", "move", a, Column.READY })
    testing.eq(code, 1)
    testing.ok(out:find("red", 1, true), out)

    -- Size it right and expect Ready to take it
    dev(root, home, { "board", "size", a, "2" })
    out, code = dev(root, home, { "board", "move", a, Column.READY })
    testing.eq(code, 0, out)
    testing.eq(dev(root, home, { "board", "stale" }), "No stale cards.\n")
end)

testing.test(
    "a local board scaffolds the v3 headings and keeps a card without them out of Ready",
    function()
        -- Add a card with only a problem and expect the headings scaffolded
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

        -- Refuse its move to Ready without outcomes
        local out, code = dev(root, home, { "board", "move", a, Column.READY })
        testing.eq(code, 1)
        testing.ok(out:find("3 to 7 Done when outcomes", 1, true), out)

        -- Refuse a direct add to Ready
        out, code =
            dev(root, home, { "board", "add", "Direct", "--column", Column.READY, "--size", "1" })
        testing.eq(code, 2)
        testing.ok(out:find("card format v4", 1, true), out)

        -- Show an Icebox card that has no description
        local ice =
            prefix_of((dev(root, home, { "board", "add", "Loose", "--column", Column.ICEBOX })))
        out = dev(root, home, { "board", "show", ice })
        testing.ok(out:find("no description", 1, true), out)

        -- Give the card a plan and outcomes and expect Ready to accept it
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
    -- Add a card with two outcomes
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

    -- Expect the outcomes stored unticked
    local outcomes = document(file_of(home)).cards[1].outcomes
    testing.eq(#outcomes, 2)
    testing.eq(outcomes[1].name, "A works")
    testing.eq(outcomes[1].done, false)

    -- Expect show and ls to report them
    out = dev(root, home, { "board", "show", a })
    testing.ok(out:find("done when:\n- [ ] A works\n- [ ] B works\n", 1, true), out)
    out = dev(root, home, { "board", "ls" })
    testing.ok(out:find("0/2", 1, true), out)
end)

testing.test("a local board appends, rewords, ticks and unticks outcomes by number", function()
    -- Add a card with two outcomes
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

    -- Append an outcome, tick one and reword another
    out, code = dev(root, home, { "board", "outcome", a, "C works" })
    testing.eq(out, "outcome " .. a .. " 3 added\n")
    out = dev(root, home, { "board", "outcome", a, "--tick", "2" })
    testing.eq(out, "outcome " .. a .. " 2 ticked by dotfiles/one\n")
    out = dev(
        root,
        home,
        { "board", "outcome", a, "--rename", "1", "A holds", "--reason", "clearer" }
    )
    testing.eq(out, "outcome " .. a .. " 1 reworded\n")

    -- Expect show to list the new text and the tick
    out = dev(root, home, { "board", "show", a })
    testing.ok(out:find("done when:\n- [ ] A holds\n- [x] B works\n- [ ] C works\n", 1, true), out)

    -- Untick one and expect the stored rows to follow
    out = dev(root, home, { "board", "outcome", a, "--untick", "2" })
    testing.eq(out, "outcome " .. a .. " 2 unticked\n")
    local rows = document(file_of(home)).cards[1].outcomes
    testing.eq(#rows, 3)
    testing.eq(rows[1].name, "A holds")
    testing.eq(rows[2].done, false)
    testing.eq(rows[2].name, "B works")

    -- Refuse a number past the last outcome
    out, code = dev(root, home, { "board", "outcome", a, "--tick", "4" })
    testing.eq(code, 1)
    testing.ok(out:find("The card has 3 outcomes. There is no outcome 4.", 1, true), out)
end)

testing.test(
    "a local board lets only the lead delete an outcome, renumbers and keeps its text in a note",
    function()
        -- Add a card with three outcomes
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

        -- Refuse a delete that gives no reason
        local lead = { DEV_AGENT = "dotfiles/lead/1" }
        out, code = dev(root, home, { "board", "outcome", a, "--delete", "2" }, lead)
        testing.eq(code, 2, out)

        -- Refuse a delete from a role other than the lead
        out, code = dev(
            root,
            home,
            { "board", "outcome", a, "--delete", "2", "--reason", "never possible" },
            { DEV_AGENT = "dotfiles/implementer/95f0e009/1" }
        )
        testing.eq(code, 1, out)
        testing.ok(out:find("Only the lead deletes an outcome", 1, true), out)
        testing.eq(#document(file_of(home)).cards[1].outcomes, 3)

        -- Delete as the lead with a reason
        out, code = dev(
            root,
            home,
            { "board", "outcome", a, "--delete", "2", "--reason", "never possible" },
            lead
        )
        testing.eq(code, 0, out)
        testing.eq(out, "outcome " .. a .. " 2 deleted\n")

        -- Expect the rest renumbered and the deleted text kept in a note
        local card = document(file_of(home)).cards[1]
        testing.eq(#card.outcomes, 2)
        testing.eq(card.outcomes[1].name, "A works")
        testing.eq(card.outcomes[2].name, "C works")
        local note = card.comments[#card.comments]
        testing.eq(note.kind, board.NoteKind.DECISION)
        testing.eq(note.body, "Deleted outcome 2: B works Reason: never possible")
    end
)

testing.test("outcome delete on a local board needs no lead token", function()
    -- Add a card with two outcomes
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

    -- Expect the user config to hold no lead token
    testing.eq(fs.read(home .. "/.config/dev/config.toml"):find("lead_token", 1, true), nil)

    -- Delete an outcome as the lead anyway
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
    -- Add a card whose outcomes carry checks
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

    -- Move it to Ready as the lead
    local lead = { DEV_AGENT = "dotfiles/lead/1" }
    out, code = dev(root, home, { "board", "move", a, Column.READY }, lead)
    testing.eq(code, 0, out)

    -- Delete an outcome there as the lead
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
    -- Add a card whose description holds a v1 checklist
    local root, home = local_board()
    local v1 = table.concat({
        "## Problem",
        "P",
        "",
        "## Change",
        "C",
        "",
        "## Done when",
        "- [ ] A works",
        "- [x] B works",
        "- [ ] C works",
        "",
        "## Out of scope",
        "None",
        "",
    }, "\n")
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

    -- Convert the checklist into outcomes
    out, code = dev(root, home, { "board", "outcome", a, "--convert" })
    testing.eq(code, 0, out)
    testing.eq(out, "outcome " .. a .. " converted 3 outcomes\n")

    -- Expect the ticks kept and the checklist dropped from the description
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

    -- Convert again and expect it left alone
    out, code = dev(root, home, { "board", "outcome", a, "--convert" })
    testing.eq(code, 0, out)
    testing.eq(out, "Outcomes of card " .. a .. " are left alone. It already has outcomes.\n")
    testing.eq(#document(file_of(home)).cards[1].outcomes, 3)
end)

testing.test(
    "a local board refuses a v1 checklist in place of outcomes on a move to Ready",
    function()
        local root, home = local_board()
        local v1 = table.concat({
            "## Problem",
            "P",
            "",
            "## Change",
            "C",
            "",
            "## Out of scope",
            "None",
            "",
            "## Done when",
            "- [ ] A",
            "- [ ] B",
            "- [ ] C",
            "",
        }, "\n")
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
    -- Add a card with no checklist
    local root, home = local_board()
    local a = prefix_of(
        (dev(root, home, { "board", "add", "Plain", "--column", Column.ICEBOX, "--problem", "x" }))
    )

    -- Convert it and expect it left alone
    local out, code = dev(root, home, { "board", "outcome", a, "--convert" })
    testing.eq(code, 0, out)
    testing.eq(out, "Outcomes of card " .. a .. " are left alone. It has no Done when checklist.\n")

    -- Refuse a stray argument
    out, code = dev(root, home, { "board", "outcome", a, "--convert", "extra" })
    testing.eq(code, 2)
end)

testing.test("a local board ticks an outcome while this machine holds the claim", function()
    -- Add a card whose first outcome is a judgement
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
        "A works " .. board.JUDGEMENT,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--checks",
        "dev test",
    })))

    -- Take the card
    local out, code = dev(root, home, { "board", "take", a })
    testing.eq(code, 0, out)

    -- Refuse a tick from the holder
    out, code = dev(root, home, { "board", "outcome", a, "--tick", "1" })
    testing.eq(code, 1, out)
    testing.eq(document(file_of(home)).cards[1].outcomes[1].done, false)

    -- Tick it as a reviewer
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
        -- Define a helper that adds a ready card
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

        -- Add three cards and take one under a name
        local a, b, c = ready("Alpha"), ready("Beta"), ready("Gamma")
        local out, code = dev(root, home, { "board", "take", a, "--as", "r/one" })
        testing.eq(code, 0, out)
        testing.eq(card_named(document(file_of(home)), "Alpha").claim.claimant, "r/one")

        -- Refuse a claim name with a space
        _, code = dev(root, home, { "board", "take", b, "--as", "bad name" })
        testing.eq(code, 2)

        -- Move a card into progress as another agent and expect it named
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

        -- Make the claimed card an epic and expect a move to keep its claim
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

        -- Release it and expect the next mover to claim it
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

local function planned_in(root, home, name, column)
    local out, code = dev(root, home, {
        "board",
        "add",
        name,
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
    })
    testing.eq(code, 0, out)
    return prefix_of(out)
end

local function column_of(doc, card)
    for _, column in ipairs(doc.columns) do
        if column.id == card.column_id then
            return column.name
        end
    end
end

testing.test("take of a Ready card leaves it In Progress under the named claim", function()
    -- Add a ready card
    local root, home = local_board()
    local a = planned_in(root, home, "Alpha", Column.READY)

    -- Take it under a name
    local out, code = dev(root, home, { "board", "take", a, "--as", "r/one" })
    testing.eq(code, 0, out)

    -- Expect it In Progress under that claim
    local doc = document(file_of(home))
    local card = card_named(doc, "Alpha")
    testing.eq(column_of(doc, card), support.COLUMN_NAME.PROGRESS)
    testing.eq(card.claim.claimant, "r/one")
end)

testing.test("take of a card in Review renews the claim and leaves the column", function()
    -- Add a card in Review
    local root, home = local_board()
    local a = planned_in(root, home, "Alpha", Column.REVIEW)

    -- Take it twice under the same name
    local out, code = dev(root, home, { "board", "take", a, "--as", "r/one" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "take", a, "--as", "r/one" })
    testing.eq(code, 0, out)

    -- Expect it still in Review under that claim
    local doc = document(file_of(home))
    local card = card_named(doc, "Alpha")
    testing.eq(column_of(doc, card), support.COLUMN_NAME.REVIEW)
    testing.eq(card.claim.claimant, "r/one")
end)

testing.test("take of a Backlog card leaves it in Backlog", function()
    -- Add a card in Backlog
    local root, home = local_board()
    local a = planned_in(root, home, "Alpha", Column.BACKLOG)

    -- Take it under a name
    local out, code = dev(root, home, { "board", "take", a, "--as", "r/one" })
    testing.eq(code, 0, out)

    -- Expect it still in Backlog under that claim
    local doc = document(file_of(home))
    local card = card_named(doc, "Alpha")
    testing.eq(column_of(doc, card), support.COLUMN_NAME.BACKLOG)
    testing.eq(card.claim.claimant, "r/one")
end)

testing.test("move out of progress releases the claim and warns about nothing", function()
    -- Add a ready card
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

    -- Take it and expect the claim held
    dev(root, home, { "board", "take", a })
    testing.ok(document(file_of(home)).cards[1].claim ~= nil, "claim held")

    -- Move it to Review and expect the claim released
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
        -- Add a ready card
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

        -- Take it and move it into progress
        dev(root, home, { "board", "take", a })
        dev(root, home, { "board", "move", a, Column.PROGRESS })

        -- Refuse every move out of progress while no note says what was built
        for _, column in ipairs({ Column.REVIEW, Column.READY, Column.BLOCKED }) do
            local out, code = dev(root, home, { "board", "move", a, column })
            testing.eq(code, 1, out)
            testing.ok(out:find("built, tried and learned", 1, true), out)
            testing.ok(document(file_of(home)).cards[1].claim ~= nil, "claim kept")
        end

        -- Refuse a move after a note of the wrong kind
        dev(root, home, { "board", "note", a, "--kind", "decision", "ruled" })
        local out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
        testing.eq(code, 1, out)

        -- Move on after the built, tried and learned note and expect the claim released
        out, code = dev(root, home, { "board", "note", a, "built, tried, learned" })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
        testing.eq(code, 0, out)
        testing.eq(document(file_of(home)).cards[1].claim, nil)
    end
)

testing.test("a second claim needs a fresh note of what was built, tried and learned", function()
    -- Add a ready card
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

    -- Work it once with a note and send it back to Ready
    dev(root, home, { "board", "take", a })
    dev(root, home, { "board", "move", a, Column.PROGRESS })
    dev(root, home, { "board", "note", a, "built, tried, learned" })
    local out, code = dev(root, home, { "board", "move", a, Column.READY })
    testing.eq(code, 0, out)

    -- Claim it again and refuse a move to Review without a fresh note
    dev(root, home, { "board", "take", a })
    dev(root, home, { "board", "move", a, Column.PROGRESS })
    out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
    testing.eq(code, 1, out)
    testing.ok(out:find("built, tried and learned", 1, true), out)
end)

local function card_in(root, home, column)
    local args = {
        "board",
        "add",
        "Card",
        "--column",
        column,
        "--size",
        "1",
        "--description",
        support.READY_DESCRIPTION,
        "--checks",
        support.READY_CHECKS[1],
    }
    for _, outcome in ipairs(support.READY_OUTCOMES) do
        args[#args + 1] = "--done-when"
        args[#args + 1] = outcome.name
    end
    return prefix_of((dev(root, home, args)))
end

testing.test("move to Review refuses a card that is not in progress under a claim", function()
    local root, home = local_board()
    for _, column in ipairs({ Column.BACKLOG, Column.READY }) do
        -- Add a card in the column
        local a = card_in(root, home, column)

        -- Refuse its move to Review
        local out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
        testing.eq(code, 1, out)
        testing.ok(
            out:find("cannot move to " .. support.COLUMN_NAME.REVIEW .. " from", 1, true),
            out
        )
        testing.ok(out:find("It must pass In Progress under a claim first.", 1, true), out)

        -- Expect Review to stay empty
        out = dev(root, home, { "board", "ls", "--column", Column.REVIEW })
        testing.eq(out, "No cards.\n")
    end
end)

local function lapsed_in_progress(root, home)
    -- Add a ready card with a judgement outcome
    local a = card_in(root, home, Column.READY)
    dev(root, home, { "board", "outcome", a, "First works " .. board.JUDGEMENT })

    -- Take it, move it into progress and note the work
    local steps = {
        { "board", "take", a },
        { "board", "move", a, Column.PROGRESS },
        { "board", "note", a, "built, tried, learned" },
    }
    for _, args in ipairs(steps) do
        local out, code = dev(root, home, args)
        testing.eq(code, 0, out)
    end

    -- Let its lease lapse
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
        DEV_AGENT = "dotfiles/other",
    })
    testing.eq(code, 1, out)
    testing.ok(out:find("The claim of ", 1, true), out)
    testing.ok(out:find(" lapsed. Take card ", 1, true), out)
    testing.ok(out:find("`dev board take " .. a:sub(1, 8), 1, true), out)
end)

local function without_claim_state(home)
    local dir = home .. "/state/dev/board"
    for _, name in ipairs(fs.list(dir) or {}) do
        assert(fs.remove(dir .. "/" .. name))
    end
end

testing.test("a move out of Blocked by another name keeps the last claimant", function()
    -- Work a card whose lease has lapsed
    local root, home = local_board()
    local a = lapsed_in_progress(root, home)

    -- Park it in Blocked behind a note
    local out, code =
        dev(root, home, { "board", "note", a, "--kind", "blocked", "waiting on an answer" })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", a, Column.BLOCKED })
    testing.eq(code, 0, out)

    -- Lapse the lease again and drop the claim state
    local doc = document(file_of(home))
    doc.cards[1].claim.expires_at = "2020-01-01T00:00:00Z"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    without_claim_state(home)

    -- Move it out of Blocked as another name and expect a warning
    local errors
    out, code, errors = support.dev(root, { "board", "move", a, Column.PROGRESS }, {
        env = env_of(home, { DEV_AGENT = "dotfiles/other" }),
        split = true,
    })
    testing.eq(code, 0, out)
    testing.ok(errors:find("Moved without a claim: the last claimant of " .. a, 1, true), errors)

    -- Expect the last claimant kept and the card In Progress
    testing.eq(document(file_of(home)).cards[1].claim.expires_at, "2020-01-01T00:00:00Z")
    out = dev(root, home, { "board", "ls", "--column", Column.PROGRESS })
    testing.ok(out:find(a, 1, true), out)
end)

testing.test(
    "a move by the claimant with no claim state on this machine releases the claim",
    function()
        -- Work a card whose lease has lapsed
        local root, home = local_board()
        local a = lapsed_in_progress(root, home)

        -- Extend its lease and drop the claim state
        local doc = document(file_of(home))
        doc.cards[1].claim.expires_at = "2999-01-01T00:00:00Z"
        assert(fs.write(file_of(home), assert(json.encode(doc))))
        without_claim_state(home)

        -- Move it as the claimant and expect the claim released
        local out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
        testing.eq(code, 0, out)
        testing.eq(out, "moved " .. a .. " to Review\n")
        testing.eq(document(file_of(home)).cards[1].claim, nil)
    end
)

testing.test("a move by another name with no claim state leaves the claim held", function()
    -- Work a card whose lease has lapsed
    local root, home = local_board()
    local a = lapsed_in_progress(root, home)

    -- Extend its lease and drop the claim state
    local doc = document(file_of(home))
    doc.cards[1].claim.expires_at = "2999-01-01T00:00:00Z"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    without_claim_state(home)

    -- Move it as another name and expect the claim kept
    dev(root, home, { "board", "move", a, Column.REVIEW }, {
        DEV_AGENT = "dotfiles/other",
    })
    testing.ok(document(file_of(home)).cards[1].claim ~= nil, "claim kept")
end)

testing.test("a move while another claimant holds the card is refused", function()
    -- Lapse a claimed card
    local root, home = local_board()
    local a = lapsed_in_progress(root, home)

    -- Another claimant takes the lapsed card
    local out, code = dev(root, home, { "board", "take", a }, { DEV_AGENT = "dotfiles/other" })
    testing.eq(code, 0, out)

    -- The first claimant's move is refused
    out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
    testing.ok(code ~= 0, out)

    -- Review stays empty
    out = dev(root, home, { "board", "ls", "--column", Column.REVIEW })
    testing.eq(out, "No cards.\n")
end)

testing.test("move to Verify refuses a card that is not in Review", function()
    -- Add cards in Backlog, Ready and In Progress
    local root, home = local_board()
    local backlog = card_in(root, home, Column.BACKLOG)
    local ready = card_in(root, home, Column.READY)
    local working = card_in(root, home, Column.READY)
    dev(root, home, { "board", "move", working, Column.PROGRESS })

    -- Refuse each move to Verify
    for _, id in ipairs({ backlog, ready, working }) do
        local out, code = dev(root, home, { "board", "move", id, Column.VERIFY })
        testing.eq(code, 1, out)
        testing.ok(
            out:find("cannot move to " .. support.COLUMN_NAME.VERIFY .. " from", 1, true),
            out
        )
        testing.ok(out:find("It must pass Review first.", 1, true), out)
    end

    -- Expect Verify to stay empty
    local out = dev(root, home, { "board", "ls", "--column", Column.VERIFY })
    testing.eq(out, "No cards.\n")
end)

testing.test("a claimed card with a note moves to Review and a Verify card moves back", function()
    -- Add a ready card with a judgement outcome and take it
    local root, home = local_board()
    local a = card_in(root, home, Column.READY)
    dev(root, home, { "board", "outcome", a, "First works " .. board.JUDGEMENT })
    dev(root, home, { "board", "take", a })

    -- Move it to Review with a note
    local out, code = support.to_review(function(args)
        return dev(root, home, args)
    end, a)
    testing.eq(code, 0, out)
    testing.eq(out, "moved " .. a .. " to Review\n")

    -- Tick the outcome and move the card back to Review
    tick_first(root, home, a)
    out, code = dev(root, home, { "board", "move", a, Column.REVIEW })
    testing.eq(code, 0, out)
    testing.eq(out, "moved " .. a .. " to Review\n")

    -- Move a staged Verify card to Review
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
    -- Take a card to Review
    local root, home = local_board()
    local a = in_review(root, home)

    -- Refuse a plain move to Verify
    local out, code = dev(root, home, { "board", "move", a, Column.VERIFY })
    testing.eq(code, 1, out)
    testing.ok(
        out:find(
            "cannot move to "
                .. support.COLUMN_NAME.VERIFY
                .. " from "
                .. support.COLUMN_NAME.REVIEW,
            1,
            true
        ),
        out
    )
    testing.ok(out:find("verifier's tick of its last open outcome", 1, true), out)

    -- Expect Verify to stay empty
    out = dev(root, home, { "board", "ls", "--column", Column.VERIFY })
    testing.eq(out, "No cards.\n")
end)

testing.test("on a local board the last tick moves a Review card to Verify", function()
    -- Take a card to Review
    local root, home = local_board()
    local a = in_review(root, home)

    -- Tick every outcome but the last
    for number = 1, 2 do
        dev(root, home, { "board", "outcome", a, "--tick", tostring(number), "--as", "r/verifier" })
    end

    -- Tick the last outcome and expect the card moved
    local out, code =
        dev(root, home, { "board", "outcome", a, "--tick", "3", "--as", "r/verifier" })
    testing.eq(code, 0, out)
    testing.eq(out, "outcome " .. a .. " 3 ticked by r/verifier\nmoved " .. a .. " to Verify\n")

    -- Expect it listed in Verify
    out = dev(root, home, { "board", "ls", "--column", Column.VERIFY })
    testing.ok(out:find(a, 1, true), out)
end)

testing.test("on a local board an early tick keeps a Review card in Review", function()
    -- Take a card to Review
    local root, home = local_board()
    local a = in_review(root, home)

    -- Add an outcome as the planner
    local out, code = dev(
        root,
        home,
        { "board", "outcome", a, "Second works" },
        { DEV_AGENT = "dotfiles/planner" }
    )
    testing.eq(code, 0, out)

    -- Tick the first outcome and expect the card to stay in Review
    out, code = dev(root, home, { "board", "outcome", a, "--tick", "1", "--as", "r/verifier" })
    testing.eq(code, 0, out)
    testing.eq(out, "outcome " .. a .. " 1 ticked by r/verifier\n")
    out = dev(root, home, { "board", "ls", "--column", Column.REVIEW })
    testing.ok(out:find(a, 1, true), out)
end)

testing.test("take holds a claim with an expiry and no loop, and release gives it up", function()
    -- Add a ready card
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

    -- Take it and expect fence 1 and a lease in the future
    local out, code = dev(root, home, { "board", "take", a })
    testing.eq(code, 0, out)
    testing.eq(out:find("took " .. a .. ", fence 1, held for 50m\n\n", 1, true), 1, out)
    local doc = document(file_of(home))
    testing.eq(doc.cards[1].claim.fence, 1)
    testing.ok(
        doc.cards[1].claim.expires_at > os.date("!%Y-%m-%dT%H:%M:%SZ"),
        "expiry in the future"
    )

    -- Expect the holder shown, next empty and another name refused
    out = dev(root, home, { "board", "ls" })
    testing.ok(out:find("dotfiles/one", 1, true), out)
    out = dev(root, home, { "board", "next" })
    testing.eq(out, "No ready cards.\n")
    out, code = dev(root, home, { "board", "take", a }, { DEV_AGENT = "dotfiles/other" })
    testing.eq(code, 1)
    testing.ok(out:find("is claimed by dotfiles/one", 1, true), out)

    -- Take it again as the holder, then release it and expect it still In Progress
    out = dev(root, home, { "board", "take", a })
    testing.eq(out:find("took " .. a .. ", fence 1, held for 50m\n\n", 1, true), 1, out)
    out = dev(root, home, { "board", "release", a })
    testing.eq(out, "released " .. a .. ", fence 1\n")
    out = dev(root, home, { "board", "ls", "--column", Column.PROGRESS })
    testing.ok(out:find("Card", 1, true), out)

    -- Take it as another name and expect the next fence
    out = dev(root, home, { "board", "take", a }, { DEV_AGENT = "dotfiles/other" })
    testing.eq(out:find("took " .. a .. ", fence 2, held for 50m\n\n", 1, true), 1, out)
end)

local function unnamed_card()
    local root, home = local_board()
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
        JUDGED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--checks",
        "dev test",
    })
    return root, home, prefix_of(out)
end

testing.test("a caller with no DEV_AGENT claims nothing on a local board", function()
    local root, home, a = unnamed_card()
    local out, code = dev(root, home, { "board", "take", a }, { DEV_AGENT = "" })
    testing.eq(code, 2, out)
    testing.ok(out:find("Set DEV_AGENT to <repo>/<role>[/<card>]", 1, true), out)
    testing.eq(document(file_of(home)).cards[1].claim, nil)
end)

testing.test("take --from with no DEV_AGENT keeps the old claim", function()
    local root, home, a = unnamed_card()
    local out, code = dev(root, home, { "board", "take", a })
    testing.eq(code, 0, out)
    out, code = dev(
        root,
        home,
        { "board", "take", a, "--from", "dotfiles/one" },
        { DEV_AGENT = "" }
    )
    testing.eq(code, 2, out)
    testing.ok(out:find("Set DEV_AGENT to <repo>/<role>[/<card>]", 1, true), out)
    testing.eq(document(file_of(home)).cards[1].claim.claimant, "dotfiles/one")
end)

testing.test("a stale fence is refused once another process holds the claim", function()
    -- Add a card
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
        JUDGED,
        "--done-when",
        JUDGED,
        "--done-when",
        JUDGED,
        "--checks",
        "dev test",
    })))

    -- Take it and move the fence on as another process would
    dev(root, home, { "board", "take", a })
    local doc = document(file_of(home))
    doc.cards[1].claim.fence = 9
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- Expect a write under the old fence refused
    local out, code = dev(root, home, { "board", "note", a, "hello" })
    testing.eq(code, 1)
    testing.ok(out:find("is held by dotfiles/one", 1, true) and out:find("fence 9", 1, true), out)
end)

testing.test("an expired claim does not block the card", function()
    -- Add a ready card
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

    -- Take it and let the lease lapse
    dev(root, home, { "board", "take", a })
    local doc = document(file_of(home))
    doc.cards[1].claim.expires_at = "2020-01-01T00:00:00Z"
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- Expect the card listed and open to writes
    local out = dev(root, home, { "board", "ls", "--column", Column.PROGRESS })
    testing.ok(out:find("Card", 1, true), out)
    out = dev(root, home, { "board", "note", a, "still works" })
    testing.eq(out, "noted " .. a .. "\n")
end)

testing.test("a tracked path keeps the board in the project, readable by everyone", function()
    -- Add a card to a board kept in the project
    local root, home = local_board(table.concat({
        "[board]",
        'backend = "local"',
        'path = ".dev/board.json"',
        "",
    }, "\n"))
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

    -- Expect the board file in the project and not in the state directory
    testing.ok(fs.exists(root .. "/.dev/board.json"))
    testing.eq(fs.exists(support.board_file(home, "mine")), false)
    testing.eq(document(root .. "/.dev/board.json").cards[1].name, "Tracked")

    -- Expect it readable by everyone and one line per card
    testing.ok(mode(root .. "/.dev/board.json") ~= "600", "not private")
    local text = assert(fs.read(root .. "/.dev/board.json"))
    testing.ok(select(2, text:gsub("\n", "")) > 4, "one line per card")
end)

testing.test("a path outside the project, or on a pomb board, is refused", function()
    for _, path in ipairs({ "../board.json", "/etc/board.json", "a//b.json", ".dev/../x.json" }) do
        local root, home = setup(table.concat({
            "[board]",
            'backend = "local"',
            'path = "' .. path .. '"',
            "",
        }, "\n"))
        local out, code = dev(root, home, { "board", "ls" })
        testing.eq(code, 1, path)
        testing.ok(
            out:find("The `path` setting of `[board]` must be a relative path", 1, true),
            out
        )
    end
    local root, home = setup(table.concat({
        "[board]",
        'backend = "pomb"',
        'path = ".dev/board.json"',
        "",
    }, "\n"))
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find('only applies to `backend = "local"`.', 1, true), out)
end)

testing.test("a local board's name has to make a file name unless a path is set", function()
    local root, home = setup(table.concat({
        "[board]",
        'backend = "local"',
        'name = "a/b"',
        "",
    }, "\n"))
    local out, code = dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find("name must be letters, digits", 1, true), out)
end)

testing.test("init refuses --admin on a local board and a different --name", function()
    local root, home = setup(LOCAL_PROJECT)
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
    -- Add six cards from six processes at once
    local root, home = local_board()
    local script = string.format(
        'for i in 1 2 3 4 5 6; do %s board add "card $i" --problem x --change x --out-of-scope y --size 1 --done-when a & done; wait',
        dev_os.quote(runtime.exe)
    )
    local out, code = dev_os.capture({ "sh", "-c", script }, {
        cwd = root,
        stderr = "stdout",
        env = {
            HOME = home,
            XDG_STATE_HOME = home .. "/state",
            PATH = root .. "/bin:" .. dev_os.getenv("PATH"),
            DEV_SELF = runtime.exe,
        },
    })
    testing.eq(code, 0, out)

    -- Expect six cards with six distinct ids
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

    -- Expect only the board file and its lock left behind
    testing.eq(fs.list(home .. "/state/dev/boards"), { "mine.json", "mine.json.lock" })
end)

testing.test("six simultaneous run --orders calls leave one open run card", function()
    -- Run six run --orders calls at once
    local root, home = local_board()
    local script = string.format(
        'for i in 1 2 3 4 5 6; do %s board run --orders "go" 2>&1 || echo "exit $?" & done; wait',
        dev_os.quote(runtime.exe)
    )
    local out, code = dev_os.capture({ "sh", "-c", script }, {
        cwd = root,
        stderr = "stdout",
        env = {
            HOME = home,
            XDG_STATE_HOME = home .. "/state",
            DEV_AGENT = "dotfiles/one",
            PATH = root .. "/bin:" .. dev_os.getenv("PATH"),
            DEV_SELF = runtime.exe,
        },
    })
    testing.eq(code, 0, out)

    -- Expect exactly one open run card
    local runs = 0
    for _, card in ipairs(document(file_of(home)).cards) do
        if #card.labels > 0 then
            runs = runs + 1
        end
    end
    testing.eq(runs, 1, out)

    -- Expect the five other calls to lose and fail
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
local COLORS = '[{"id":"'
    .. YELLOW_ID
    .. '","value":"yellow","label":"1 Pomodoro"},'
    .. '{"id":"'
    .. BLUE_ID
    .. '","value":"blue","label":"3 Pomodori"},'
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
        color_id = YELLOW_ID,
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

local CLOSED_URL = "http://127.0.0.1:1"
local GATEWAY = "<html>bad gateway</html>"

---Make the server answer the way the old curl stub answered, from the control files in `root`.
---A `down` file points the config at a closed port, and a `gateway` file makes every answer a 502.
function sync(root, home)
    -- Point the user config at the server, or at a closed port when down
    local function control(name)
        return fs.read(root .. "/" .. name)
    end
    local server = SERVERS[root]
    local url = fs.exists(root .. "/down") and CLOSED_URL or server.url
    assert(fs.write(
        home .. "/.config/dev/config.toml",
        table.concat({
            "[board.pomb]",
            'url = "' .. url .. '"',
            'field_prefix = "runner"',
            'token = "pass:secrets/worker/token/pomb"',
            "",
        }, "\n")
    ))

    -- Define the routes the server answers with
    local function routes_for(export, with_dead)
        -- Answer every request with a gateway error when asked
        local routes = {}
        if fs.exists(root .. "/gateway") then
            routes[#routes + 1] = { path = "*", status = 502, body = GATEWAY }
            return routes
        end

        -- Refuse writes with a held claim when asked
        if fs.exists(root .. "/held") then
            routes[#routes + 1] = {
                method = "PATCH",
                path = "*",
                status = 409,
                body = '{"code":"claim_held","message":"the card holds a live claim"}',
            }
        end

        -- Serve the second card's links and the first card with its parent
        local links_b = control("links_b.json")
        if links_b then
            routes[#routes + 1] = { path = "/api/tasks/" .. ID_B .. "/links", body = links_b }
        end
        local parent = ',"parent":{"id":"'
            .. ID_B
            .. '","name":"Epic"},"children_done":1,'
            .. '"children_total":3}'
        local first
        for _, line in ipairs(support.export_lines(export)) do
            if line:find(ID_A, 1, true) == 8 then
                first = line:gsub("}$", function()
                    return parent
                end)
            end
        end
        first = first or ('{"id":"' .. ID_A .. '"' .. parent)

        -- Stage a dead copy of the card routes when asked
        local dead
        if with_dead and fs.exists(root .. "/detail_once") then
            local plain = routes_for(export)
            table.insert(plain, 1, { path = "/api/tasks/*", status = -1 })
            dead = server:stage_copy("dead", plain)
        end

        -- Serve the card routes and the board routes
        routes[#routes + 1] = { path = "/api/tasks/" .. ID_A, body = first, copy = dead }
        routes[#routes + 1] = { path = "/api/tasks/" .. ID_A:sub(1, 8), body = first, copy = dead }
        routes[#routes + 1] = {
            path = "/api/tasks/cccccccc-2222-4ccc-8ccc-cccccccccccc",
            body = control("big.json"),
        }
        routes[#routes + 1] = {
            path = "/api/tasks/dddddddd-2222-4ddd-8ddd-dddddddddddd",
            body = control("small.json"),
        }
        for _, board in ipairs({ "board-1", "board-3" }) do
            routes[#routes + 1] =
                { path = "/api/boards/" .. board .. "/colors", body = control("colors.json") }
            routes[#routes + 1] =
                { path = "/api/boards/" .. board .. "/fields", body = control("fields.json") }
        end
        routes[#routes + 1] = { path = "/api/boards", body = control("boards.json") }
        routes[#routes + 1] = { path = "/api/boards/board-1", body = control("detail.json") }
        routes[#routes + 1] = { path = "/api/boards/board-3", body = control("ci.json") }
        routes[#routes + 1] = { path = "/api/boards/board-3/export-data", body = export }
        routes[#routes + 1] = {
            path = "/api/boards/board-3/tasks",
            body = export and support.export_page(export) or '{"items":[],"next_cursor":null}',
        }
        local page = control("page.json")
        if page then
            routes[#routes + 1] = { path = "/api/boards/board-1/tasks", body = page }
        end

        -- Serve the cards' own routes, the create route and the fallbacks
        local after = control("after_post.json")
        local owner_body = after and '{"holder":{"kind":"agent","name":"dotfiles/one"},"fence":1}'
            or nil
        local own = support.pomb_task_routes({ export = export, owner_body = owner_body })
        for _, route in ipairs(own) do
            routes[#routes + 1] = route
        end
        routes[#routes + 1] = {
            method = "POST",
            path = "/api/tasks",
            body = '{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","name":"x","column_id":"col-backlog"}',
        }
        routes[#routes + 1] = { method = "GET", path = "/api/tasks/*/links", body = "[]" }
        routes[#routes + 1] = { method = "GET", path = "/api/tasks/*/comments", body = "[]" }
        routes[#routes + 1] = {
            method = "GET",
            path = "/api/tasks/*",
            status = 404,
            body = '{"code":"not_found","message":"task not found"}',
        }
        routes[#routes + 1] = { path = "*", body = '{"ok":true}' }
        return routes
    end

    -- Install the routes and stage the copy served after a create
    local export = control("export.json")
    local routes = routes_for(export, true)
    local after = control("after_post.json")
    if after then
        local staged = server:stage_copy("after_post", routes_for(after))
        for _, route in ipairs(routes) do
            if route.method == "POST" and route.path == "/api/tasks" then
                route.copy = staged
            end
        end
    end
    server:set(routes)
end

---Read what Pomb was sent, one `METHOD TARGET body=BODY` line per request.
local function requests(root)
    return SERVERS[root]:requests()
end

---Read the bodies Pomb was sent, one per line.
local function sent_bodies(root)
    local lines = {}
    for body in requests(root):gmatch("\n?%u+ %S+ body=([^\n]+)") do
        lines[#lines + 1] = body
    end
    return table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
end

local function pomb(opts)
    -- Set up a Pomb project and write the answers the server serves
    opts = opts or {}
    local root, home = setup(table.concat({
        "[board]",
        'backend = "pomb"',
        'name = "dotfiles"',
        "",
    }, "\n"))
    for name, body in pairs({
        ["boards.json"] = BOARDS,
        ["detail.json"] = DETAIL,
        ["colors.json"] = COLORS,
        ["export.json"] = EXPORT,
        ["fields.json"] = support.FIELDS,
    }) do
        assert(fs.write(root .. "/" .. name, body))
    end

    -- Start a fake Pomb server for the project
    SERVERS[root] = support.fake_http({})

    -- Stub the pass command so it hands out the token or stays locked
    assert(fs.write(
        root .. "/bin/pass",
        table.concat({
            "#!/bin/sh",
            opts.locked and "exit 1" or ('echo "' .. TOKEN .. '"'),
            "",
        }, "\n")
    ))
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
    local lines = {}
    for method, target in requests(root):gmatch("\n?(%u+) (%S+) body=") do
        lines[#lines + 1] = method .. " " .. target .. "\n"
    end
    return table.concat(lines)
end

local QUEUED = "queued: Pomb unreachable, will sync\n"

testing.test("writes while Pomb is unreachable are queued and the queue is private", function()
    -- Take Pomb down
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))

    -- Write a move, a note, an add, a size and a label while it is down
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

    -- Read back the queue, its modes and Pomb's call log
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
    testing.eq(pomb_dev(root, home, { "board", "note", table.unpack(args) }), QUEUED)
    testing.eq(document(queue_path(home))[1].args, args)
end)

testing.test("a queued discard replays its move without the outcome check", function()
    -- Serve a card whose detail read fails once
    local root, home = pomb()
    assert(fs.write(root .. "/export.json", '{"tasks":[' .. support.pomb_export_task({
        id = ID_A,
        name = "First",
        column_id = READY_COLUMN,
        color_id = YELLOW_ID,
        description = "## Problem\\nx\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone",
        subtasks = '[{"id":"s1","name":"Never works","done":false}]',
    }) .. "]}"))
    assert(fs.write(root .. "/detail_once", ""))

    -- Discard the card and see the write queue
    local out, code =
        pomb_dev(root, home, { "board", "discard", ID_A:sub(1, 8), "--reason", "Dropped" })
    testing.eq(code, 0, out)
    testing.eq(out, QUEUED)

    -- Sync once Pomb answers and see the move replayed
    assert(fs.remove(root .. "/detail_once"))
    SERVERS[root] = support.fake_http({})
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
    testing.ok(out:find("Board unavailable", 1, true), out)
    testing.eq(fs.exists(queue_path(home)), false)
end)

testing.test("after a gateway error only a change that is safe to repeat is queued", function()
    -- Make Pomb answer with a gateway error and queue a repeatable move
    local root, home = pomb()
    assert(fs.write(root .. "/gateway", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), Column.REVIEW })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)

    -- Refuse a note and an add that a repeat would duplicate
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

    -- Keep only the move in the queue
    testing.eq(#document(queue_path(home)), 1)
end)

testing.test("a hand-edited board file keeps its other keys and gets its name back", function()
    -- Hand-edit the board file to drop its name and add a key
    local root, home = local_board()
    local doc = document(file_of(home))
    doc.name = nil
    doc.note = "kept"
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- Add a card through the CLI
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

    -- Check the extra key survived and the name came back
    doc = document(file_of(home))
    testing.eq(doc.note, "kept")
    testing.eq(doc.name, "mine")
end)

testing.test("a tracked board leaves no lock file in the project", function()
    local root, home = local_board(table.concat({
        "[board]",
        'backend = "local"',
        'path = ".dev/board.json"',
        "",
    }, "\n"))
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
    -- Take Pomb down
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))

    -- Fail a read instead of queueing it
    local out, code = pomb_dev(root, home, { "board", "ls" })
    testing.eq(code, 1)
    testing.ok(out:find("Cannot reach", 1, true), out)

    -- Fail a bad move, a bad note and a take without queueing them
    out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "nowhere" })
    testing.eq(code, 2, out)
    out, code = pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "--edit", "aaaaaaaa", "x" })
    testing.eq(code, 1, out)
    out, code = pomb_dev(root, home, { "board", "take", ID_A:sub(1, 8) })
    testing.eq(code, 1, out)
    testing.eq(fs.exists(queue_path(home)), false)
end)

testing.test("queued add --board replays on the named board with its flags as typed", function()
    -- Serve a second board and take Pomb down
    local root, home = pomb()
    assert(
        fs.write(
            root .. "/boards.json",
            '[{"id":"board-1","name":"dotfiles","archived":false},'
                .. '{"id":"board-3","name":"ci","archived":false}]'
        )
    )
    assert(
        fs.write(
            root .. "/ci.json",
            '{"id":"board-3","name":"ci","columns":[{"id":"col-ci-backlog","name":"Backlog"}]}'
        )
    )
    assert(fs.write(root .. "/down", ""))

    -- Queue an add aimed at the second board
    local args = {
        "Later",
        "--board",
        "ci",
        "--blocked-by",
        ID_B:sub(1, 8),
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
    local words = { "board", "add" }
    for _, word in ipairs(args) do
        words[#words + 1] = word
    end
    local out, code = pomb_dev(root, home, words)
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
    local entries = document(queue_path(home))
    testing.eq(#entries, 1)
    testing.eq(entries[1].sub, "add")
    testing.eq(entries[1].args, args)

    -- Bring Pomb back and replay the add on that board
    assert(fs.remove(root .. "/down"))
    out, code = pomb_dev(root, home, { "board", "sync" })
    testing.eq(code, 0, out)
    testing.ok(out:find("synced add", 1, true), out)
    local bodies = sent_bodies(root)
    testing.ok(bodies:find("col-ci-backlog", 1, true), bodies)
    testing.ok(calls(root):find("/api/boards/board-3", 1, true), calls(root))
end)

testing.test("a crossboard note replays on the named board once Pomb is back", function()
    -- Serve a second board and take Pomb down
    local root, home = pomb()
    assert(
        fs.write(
            root .. "/boards.json",
            '[{"id":"board-1","name":"dotfiles","archived":false},'
                .. '{"id":"board-3","name":"ci","archived":false}]'
        )
    )
    assert(
        fs.write(
            root .. "/ci.json",
            '{"id":"board-3","name":"ci","columns":[{"id":"col-ci-backlog","name":"Backlog"}]}'
        )
    )
    assert(fs.write(root .. "/down", ""))

    -- Queue a note aimed at the second board
    local args = { ID_A:sub(1, 8), "--board", "ci", "kept", "words" }
    local out, code = pomb_dev(root, home, { "board", "note", table.unpack(args) })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
    local entries = document(queue_path(home))
    testing.eq(#entries, 1)
    testing.eq(entries[1].sub, "note")
    testing.eq(entries[1].args, args)

    -- Bring Pomb back and replay the note on that board
    assert(fs.remove(root .. "/down"))
    out, code = pomb_dev(root, home, { "board", "sync" })
    testing.eq(code, 0, out)
    testing.ok(out:find("synced note aaaaaaaa", 1, true), out)
    testing.ok(calls(root):find("/api/boards/board-3", 1, true), calls(root))
    local note_call = "POST /api/tasks/" .. ID_A .. "/comments"
    testing.ok(calls(root):find(note_call, 1, true), calls(root))
    testing.ok(sent_bodies(root):find("kept words", 1, true), "note body was not sent")
    local left = fs.exists(queue_path(home)) and document(queue_path(home)) or {}
    testing.eq(#left, 0)
end)

testing.test("link posts to the task and queues while Pomb is unreachable", function()
    -- Link two cards while Pomb answers
    local root, home = pomb()
    local out, code =
        pomb_dev(root, home, { "board", "link", ID_A:sub(1, 8), "blocks", ID_B:sub(1, 8) })
    testing.eq(code, 0, out)
    testing.eq(out, "linked aaaaaaaa blocks bbbbbbbb\n")
    testing.ok(calls(root):find("/api/tasks/" .. ID_A .. "/links", 1, true), calls(root))
    testing.eq(sent_bodies(root), '{"kind":"blocks","target_id":"' .. ID_B .. '"}\n')

    -- Link again while Pomb is down and see the write queue
    assert(fs.write(root .. "/down", ""))
    out, code = pomb_dev(root, home, { "board", "link", ID_B:sub(1, 8), "related", ID_A:sub(1, 8) })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
    local entries = document(queue_path(home))
    testing.eq(#entries, 1)
    testing.eq(entries[1].sub, "link")
    testing.eq(entries[1].args, { ID_B:sub(1, 8), "related", ID_A:sub(1, 8) })

    -- Bring Pomb back and replay the link
    assert(fs.remove(root .. "/down"))
    out = pomb_dev(root, home, { "board", "sync" })
    testing.eq(out, "synced link bbbbbbbb\nsynced\n")
    testing.ok(calls(root):find("/api/tasks/" .. ID_B .. "/links", 1, true), calls(root))
end)

local WAITING = table.concat({
    "## Problem",
    "waiting plan",
    "",
    "## Change",
    "- x",
    "",
    "## Out of scope",
    "none",
}, "\n")

testing.test("edit patches the task, and a queued edit replays with its text", function()
    -- Edit a card from a file while Pomb answers
    local root, home = pomb()
    assert(fs.write(
        root .. "/plan.md",
        table.concat({
            "## Problem",
            "new plan",
            "",
            "## Change",
            "- x",
            "",
            "## Out of scope",
            "none",
            "",
        }, "\n")
    ))
    local out, code =
        pomb_dev(root, home, { "board", "edit", ID_A:sub(1, 8), "--file", root .. "/plan.md" })
    testing.eq(code, 0, out)
    testing.eq(out, "edited aaaaaaaa\n")
    testing.ok(calls(root):find("/api/tasks/" .. ID_A .. "\n", 1, true), calls(root))
    testing.eq(
        sent_bodies(root),
        '{"description":"## Problem\\nnew plan\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone"}\n'
    )

    -- Edit another card from stdin while Pomb is down and see the text queue
    assert(fs.write(root .. "/down", ""))
    sync(root, home)
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

    -- Bring Pomb back and replay the edit
    assert(fs.remove(root .. "/down"))
    out = pomb_dev(root, home, { "board", "sync" })
    testing.eq(out, "synced edit bbbbbbbb\nsynced\n")
    testing.ok(calls(root):find("/api/tasks/" .. ID_B .. "\n", 1, true), calls(root))
end)

testing.test("a local board replaces a card's checks and then lets it enter Ready", function()
    -- Plan a card that has no checks row yet
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

    -- Refuse the move into Ready
    local out, code = dev(root, home, { "board", "move", a, Column.READY })
    testing.eq(code, 1)

    -- Set the checks and read them back
    out, code = dev(root, home, { "board", "checks", a, "dev lint", "dev test" })
    testing.eq(code, 0, out)
    testing.eq(out, "set checks " .. a .. ", 2 rows\n")
    testing.eq(document(file_of(home)).cards[1].checks, { "dev lint", "dev test" })
    out = dev(root, home, { "board", "show", a })
    testing.ok(out:find("\n\nchecks:\n- dev lint\n- dev test\n\n", 1, true), out)

    -- Enter Ready, then replace the rows
    out, code = dev(root, home, { "board", "move", a, Column.READY })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "checks", a, "dev fmt" })
    testing.eq(code, 0, out)
    testing.eq(document(file_of(home)).cards[1].checks, { "dev fmt" })

    -- Reject an empty list and keep the rows
    out, code = dev(root, home, { "board", "checks", a })
    testing.eq(code, 2)
    testing.eq(document(file_of(home)).cards[1].checks, { "dev fmt" })
end)

testing.test("a queued checks replaces the rows when Pomb answers again", function()
    -- Take Pomb down
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))

    -- Queue a checks write
    local out, code = pomb_dev(root, home, { "board", "checks", ID_A:sub(1, 8), "dev lint" })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
    local entries = document(queue_path(home))
    testing.eq(entries[1].sub, "checks")
    testing.eq(entries[1].args, { ID_A:sub(1, 8), "dev lint" })

    -- Bring Pomb back and replay the rows
    assert(fs.remove(root .. "/down"))
    out = pomb_dev(root, home, { "board", "sync" })
    testing.eq(out, "synced checks aaaaaaaa\nsynced\n")
    testing.ok(sent_bodies(root):find('"runner.checks":[{"run":"dev lint"}]', 1, true))
end)

testing.test("a local board stores a card's allow, tests and files and shows them", function()
    -- Add a bare card
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

    -- Store its allow list, tests and files
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

    -- Show them on the card
    out = dev(root, home, { "board", "show", a })
    testing.ok(
        out:find(
            "allow:\n- ci-edits\n- test-edits\n\ntests:\n- one\n- tests::two\n\nfiles:\n- src/a.rs\n\n",
            1,
            true
        ),
        out
    )

    -- Clear the allow list and refuse a bad value
    out, code = dev(root, home, { "board", "allow", a, "none" })
    testing.eq(code, 0, out)
    testing.eq(out, "cleared allow " .. a .. "\n")
    testing.eq(document(file_of(home)).cards[1].allow, nil)
    out, code = dev(root, home, { "board", "allow", a, "everything" })
    testing.eq(code, 2)
    testing.eq(document(file_of(home)).cards[1].allow, nil)
end)

testing.test("queued allow, tests and files replace the fields when Pomb answers again", function()
    -- Take Pomb down
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))

    -- Queue an allow, a tests and a files write
    local id = ID_A:sub(1, 8)
    local out, code = pomb_dev(root, home, { "board", "allow", id, "test-edits" })
    testing.eq(out, QUEUED)
    testing.eq(code, 0)
    out = pomb_dev(root, home, { "board", "tests", id, "one" })
    testing.eq(out, QUEUED)
    out = pomb_dev(root, home, { "board", "files", id, "src/a.rs" })
    testing.eq(out, QUEUED)

    -- Read back the queue
    local entries = document(queue_path(home))
    testing.eq(#entries, 3)
    testing.eq(entries[1].sub, "allow")
    testing.eq(entries[1].args, { id, "test-edits" })

    -- Bring Pomb back and replay the fields
    assert(fs.remove(root .. "/down"))
    out = pomb_dev(root, home, { "board", "sync" })
    testing.eq(out, "synced allow aaaaaaaa\nsynced tests aaaaaaaa\nsynced files aaaaaaaa\nsynced\n")
    local bodies = sent_bodies(root)
    testing.ok(bodies:find('"runner.allow":["test-edits"]', 1, true), bodies)
    testing.ok(bodies:find('"runner.tests":"one"', 1, true), bodies)
    testing.ok(bodies:find('"runner.files":"src/a.rs"', 1, true), bodies)
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
    -- Queue a move, a note and an add while Pomb is down
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

    -- Bring Pomb back and sync the queue empty
    assert(fs.remove(root .. "/down"))
    local out, code = pomb_dev(root, home, { "board", "sync" })
    testing.eq(code, 0, out)
    testing.eq(out, "synced move aaaaaaaa\nsynced note bbbbbbbb\nsynced add Later\nsynced\n")
    testing.eq(fs.exists(queue_path(home)), false)

    -- Check the calls went out in queue order
    local log = calls(root)
    local move = assert(log:find("POST [^\n]*/move", 1))
    local note = assert(log:find("POST [^\n]*/comments", 1))
    local add = assert(log:find("POST [^\n]*/api/tasks\n", 1))
    testing.ok(move < note and note < add, log)

    -- Sync again with nothing queued
    out = pomb_dev(root, home, { "board", "sync" })
    testing.eq(out, "Nothing is queued.\n")
end)

testing.test("a replay Pomb refuses is reported and dropped, the rest still go", function()
    -- Queue a move to a missing card and a good note
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", "deadbeef", Column.REVIEW })
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "still goes" })

    -- Bring Pomb back and sync
    assert(fs.remove(root .. "/down"))
    local out, code = pomb_dev(root, home, { "board", "sync" })

    -- Report the dropped move and replay the note
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
    -- Queue a note while Pomb is down
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "waiting" })

    -- Bring Pomb back and list the board
    assert(fs.remove(root .. "/down"))
    local out, code = pomb_dev(root, home, { "board", "ls" })
    testing.eq(code, 0, out)
    testing.ok(out:find("synced note aaaaaaaa", 1, true), out)
    testing.ok(out:find("First", 1, true), out)
    testing.eq(fs.exists(queue_path(home)), false)

    -- Check the replay went out before the read
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
        local root, home = bad_queue(table.concat({
            '[{"sub":"move",',
            '"args":["aaaaaaaa" "' .. Column.REVIEW .. '"]}]',
            "",
        }, "\n"))
        local out, code = pomb_dev(root, home, { "board", "sync" })
        testing.eq(code, 1)
        testing.ok(out:find(queue_path(home) .. ":2: ", 1, true), out)
        testing.ok(out:find("left in place", 1, true), out)
        testing.ok(not out:find("Nothing is queued", 1, true), out)
        testing.ok(assert(fs.read(queue_path(home))):find('"' .. Column.REVIEW .. '"]}]', 1, true))
        testing.eq(calls(root), "")
    end
)

testing.test("sync on an unreadable queue names the file and the system's reason", function()
    local root, home = pomb()
    assert(fs.mkdir(queue_path(home), { parents = true }))
    local out, code = pomb_dev(root, home, { "board", "sync" })
    testing.eq(code, 1)
    testing.ok(out:find("Cannot read the queue at " .. queue_path(home) .. ". ", 1, true), out)
    testing.ok(out:find("The queue is left in place.", 1, true), out)
end)

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
    -- Start with a queue that is not JSON
    local root, home = bad_queue("not json")

    -- List the board and see the warning
    local out, code = pomb_dev(root, home, { "board", "ls" })
    testing.eq(code, 0, out)
    testing.ok(out:find(queue_path(home) .. ":1: ", 1, true), out)
    testing.ok(out:find("First", 1, true), out)
    testing.eq(assert(fs.read(queue_path(home))), "not json")

    -- Read the status and see the file left in place
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

testing.test("a change that cannot be queued prints both sentences once", function()
    -- Take Pomb down over a malformed queue and write
    local root, home = bad_queue("not json")
    assert(fs.write(root .. "/down", ""))
    local out = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), Column.REVIEW })

    -- Count each sentence once
    local _, queued = out:gsub("The change could not be queued%. ", "")
    testing.eq(queued, 1, out)
    local _, backend = out:gsub("%(curl exit 7%)%. The change", "")
    testing.eq(backend, 1, out)

    -- Check the file is named and the message ends cleanly
    testing.ok(out:find(queue_path(home) .. ":1: ", 1, true), out)
    testing.ok(not out:find(".. ", 1, true), out)
    testing.ok(out:find("%.%s*$"), out)
end)

testing.test("a malformed queue file hands drain and push the malformed reason", function()
    -- Write a queue file that is not JSON
    local queue = require("@dev/board/queue")
    local pending = queue.new("unit")
    pending.path = support.tempdir() .. "/unit.queue"
    assert(fs.write(pending.path, "not json"))

    -- Drain it and get the reason
    local drained, message, reason = pending:drain(function()
        return queue.Replay.DONE
    end)
    testing.eq(drained, nil)
    testing.ok(message:find(pending.path .. ":1: ", 1, true), message)
    testing.eq(reason, queue.Reason.MALFORMED)

    -- Push onto it and get the same reason
    local ok
    ok, message, reason = pending:push("move", { "aaaaaaaa" })
    testing.eq(ok, nil)
    testing.eq(reason, queue.Reason.MALFORMED)
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
    -- Add a card with two checks
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

    -- Read the checks off the stored card
    local a = prefix_of(out)
    testing.eq(document(file_of(home)).cards[1].checks, { "dev lint", "dev test" })

    -- Show the card and see them listed
    out = dev(root, home, { "board", "show", a })
    testing.ok(out:find("\n\nchecks:\n- dev lint\n- dev test\n\n", 1, true), out)
end)

testing.test("a local board keeps a card with no checks row out of Ready", function()
    -- Plan a card that has no checks row
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

    -- Refuse the move into Ready
    local out, code = dev(root, home, { "board", "move", a, Column.READY })
    testing.eq(code, 1)
    testing.ok(out:find("has no checks row", 1, true), out)

    -- Refuse an add straight into Ready without checks
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

    -- Keep the checks field out of the board's init text
    out = dev(root, home, { "board", "init" })
    testing.eq(out:find("checks field", 1, true), nil)
end)

testing.test("a board file that is not JSON returns the not_json reason", function()
    -- Write a board file that is not JSON
    local path = support.tempdir() .. "/board.json"
    assert(fs.write(path, "not json"))

    -- Read it through the store
    testing.eq({ store.read(path) }, { nil, nil, board.FileReason.NOT_JSON, path })

    -- Add through a backend and get the sentence
    local backend = localboard.new({ name = "mine", path = path, private = true })
    testing.eq(
        { backend:add("held", support.COLUMN_NAME.ICEBOX, {}) },
        { nil, path .. " is not valid JSON." }
    )
end)

testing.test("a lock failure names the file in a sentence", function()
    -- Block the lock with a directory
    local path = support.tempdir() .. "/board.json"
    assert(fs.mkdir(path .. ".lock", { parents = true }))

    -- Take the lock through the store
    local ok, _, reason, detail = store.locked(path, { private = true }, function() end)
    testing.eq({ ok, reason, detail }, { nil, board.FileReason.LOCK, path })

    -- Add through a backend and get the sentence
    local backend = localboard.new({ name = "mine", path = path, private = true })
    local card, message = backend:add("held", support.COLUMN_NAME.ICEBOX, {})
    testing.eq(card, nil)
    testing.eq(message:sub(1, #path + 14), "Cannot lock " .. path .. ": ")
end)

testing.test("a release names the reason a missing card or an unheld claim is refused", function()
    -- Add a card that nobody holds
    local _, home = local_board()
    local backend = localboard.new({ name = "mine", path = file_of(home), private = true })
    local card = assert(backend:add("held", support.COLUMN_NAME.ICEBOX, {}))

    -- Release a card that does not exist
    local ok, _, reason, detail = backend:release("no-such-card", 1)
    testing.eq({ ok, reason, detail }, { nil, board.ReleaseReason.NO_CARD, "no-such-card" })

    -- Release a card nobody holds
    ok, _, reason, detail = backend:release(card.id, 1)
    testing.eq({ ok, reason, detail }, { nil, board.ReleaseReason.NOT_HELD, card.id })
end)

testing.test("a release with an expected holder refuses another holder's claim", function()
    -- Add a card and claim it
    local _, home = local_board()
    local backend = localboard.new({ name = "mine", path = file_of(home), private = true })
    local card = assert(backend:add("held", support.COLUMN_NAME.ICEBOX, {}))
    local fence = assert(backend:claim(card.id, "r/third", {}))

    -- Release it as a holder that does not hold it
    local ok, message = backend:release(card.id, fence, "r/old")
    testing.eq(ok, nil)
    testing.ok(message:find("is held by r/third now, not by r/old", 1, true), message)

    -- Release it as the holder that does
    testing.eq(backend:release(card.id, fence, "r/third"), true)
end)

testing.test("release returns a reason and no message", function()
    -- Add a card that nobody holds
    local _, home = local_board()
    local backend = localboard.new({ name = "mine", path = file_of(home), private = true })
    local card = assert(backend:add("held", support.COLUMN_NAME.ICEBOX, {}))

    -- Refuse releases with a reason
    testing.eq(
        { backend:release("no-such-card", 1) },
        { nil, nil, board.ReleaseReason.NO_CARD, "no-such-card" }
    )
    testing.eq({ backend:release(card.id, 1) }, { nil, nil, board.ReleaseReason.NOT_HELD, card.id })

    -- Refuse moves with a reason
    testing.eq(
        { backend:move(card.id, "No such column") },
        { nil, nil, board.MoveReason.NO_COLUMN }
    )
    testing.eq(
        { backend:move(card.id, support.COLUMN_NAME.ICEBOX, { lane = "No such lane" }) },
        { nil, nil, board.MoveReason.NO_LANE }
    )
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

testing.test("the local add refuses a second run card of the same name", function()
    -- Open the board file as a backend
    local _, home = local_board()
    local icebox = support.COLUMN_NAME.ICEBOX
    local backend = localboard.new({
        name = "mine",
        path = file_of(home),
        private = true,
    })

    -- A second run card of the same name is refused
    local first = assert(backend:add("run session", icebox, { labels = { board.RUN } }))
    local second, message = backend:add("run session", icebox, { labels = { board.RUN } })
    testing.eq(second, nil)
    testing.ok(message:find("already has the run card", 1, true), message)
    testing.ok(message:find(first.id:sub(1, board.MIN_PREFIX), 1, true), message)
    testing.ok(message:find("run --end", 1, true), message)

    -- A run card of another name is accepted
    assert(backend:add("run other", icebox, { labels = { board.RUN } }))

    -- The name is free again once the first card is Done
    assert(backend:move(first.id, support.COLUMN_NAME.DONE))
    assert(backend:add("run session", icebox, { labels = { board.RUN } }))
end)

testing.test(
    "the local add takes two hand-labelled run cards with a name outside the prefix",
    function()
        local _, home = local_board()
        local icebox = support.COLUMN_NAME.ICEBOX
        local backend = localboard.new({
            name = "mine",
            path = file_of(home),
            private = true,
        })

        assert(backend:add("session", icebox, { labels = { board.RUN } }))
        assert(backend:add("session", icebox, { labels = { board.RUN } }))
    end
)

testing.test("blocked leaves out the blocker it is told to except", function()
    -- Add a card and two cards that could block it
    local _, home = local_board()
    local ready = support.COLUMN_NAME.READY
    local backend = localboard.new({ name = "mine", path = file_of(home), private = true })
    local blocked = assert(backend:add("blocked", ready, {}))
    local first = assert(backend:add("first", ready, {}))
    local second = assert(backend:add("second", ready, {}))

    -- Block it on the first and except that blocker
    assert(backend:link(blocked.id, "blocked_by", first.id))
    testing.eq({ backend:blocked(blocked.id) }, { true, first.id })
    testing.eq({ backend:blocked(blocked.id, first.id) }, { false })

    -- Block it on the second and see that one reported
    assert(backend:link(blocked.id, "blocked_by", second.id))
    testing.eq({ backend:blocked(blocked.id, first.id) }, { true, second.id })
end)

testing.test("wait on a local board answers at once that there is nothing to wait on", function()
    local backend = require("@dev/board/localboard").new({ name = "mine" })
    local got, message = backend:wait("1", { "task_added" }, 5)
    testing.eq(got, nil)
    testing.eq(message, "A local board has nothing to wait on.")
end)

testing.test("a local board with renamed columns works through the project map", function()
    -- Create a board whose project map renames the columns
    local root, home = local_board(table.concat({
        "[board]",
        'backend = "local"',
        'name = "mine"',
        "",
        "[board.columns]",
        'backlog = "Inbox"',
        'ready = "Next"',
        'progress = "Doing"',
        'done = "Shipped"',
        "",
    }, "\n"))
    local doc = document(file_of(home))
    local names = {}
    for _, column in ipairs(doc.columns) do
        names[#names + 1] = column.name
    end
    testing.eq(names, {
        support.COLUMN_NAME.ICEBOX,
        "Inbox",
        "Next",
        "Doing",
        support.COLUMN_NAME.REVIEW,
        support.COLUMN_NAME.VERIFY,
        support.COLUMN_NAME.RELEASE,
        support.COLUMN_NAME.BLOCKED,
        "Shipped",
    })
    testing.eq(doc.columns[9].is_done, true)

    -- Add a card and see it land in the renamed Backlog
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

    -- Finish it into the renamed done column and see it hidden
    tick_first(root, home, id)
    out = dev(root, home, { "board", "move", id, Column.DONE })
    testing.eq(out, "moved " .. id .. " to Shipped\n")
    testing.eq(dev(root, home, { "board", "ls" }), "No cards.\n")
    out = dev(root, home, { "board", "ls", "--column", "shipped" })
    testing.ok(out:find("Shipped", 1, true), out)

    -- Move it back toward the renamed Ready
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
        -- Add an Archive column that counts as finished
        local root, home = local_board()
        local doc = document(file_of(home))
        doc.columns[#doc.columns + 1] = { id = "col-archive", name = "Archive", is_done = true }
        assert(fs.write(file_of(home), json.encode(doc)))

        -- Add two cards
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

        -- Finish one into each finished column and see both hidden
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

        -- Discard a third card into the first finished column
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
        -- Refuse a description beside a section flag
        local root, home = local_board()
        local out, code =
            dev(root, home, { "board", "add", "Both", "--description", "text", "--problem", "p" })
        testing.eq(code, 2)
        testing.ok(out:find("--description", 1, true), out)

        -- Refuse a Backlog add with no Problem
        out, code = dev(root, home, { "board", "add", "Bare" })
        testing.eq(code, 2)
        testing.ok(out:find("text under ## Problem", 1, true), out)

        -- Refuse an add with only a Change and leave the board empty
        out, code = dev(root, home, { "board", "add", "OnlyChange", "--change", "- do" })
        testing.eq(code, 2)
        testing.eq(#document(file_of(home)).cards, 0)
    end
)

testing.test(
    "a free-form Icebox card cannot enter Backlog until edit gives it a Problem",
    function()
        -- Add a free-form Icebox card
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

        -- Refuse the move into Backlog for want of a Problem
        local out, code = dev(root, home, { "board", "move", a, Column.BACKLOG })
        testing.eq(code, 1)
        testing.ok(out:find("cannot enter Backlog", 1, true), out)
        testing.ok(out:find("## Problem", 1, true), out)

        -- Give it a Problem through edit and see the next gaps named
        local file = root .. "/plan.md"
        assert(fs.write(
            file,
            table.concat({
                "## Problem",
                "why",
                "",
                "## Change",
                "- x",
                "",
                "## Out of scope",
                "none",
                "",
            }, "\n")
        ))
        out, code = dev(root, home, { "board", "edit", a, "--file", file })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, Column.BACKLOG })
        testing.eq(code, 1)
        testing.ok(out:find("a size", 1, true) and out:find("Done when outcomes", 1, true), out)

        -- Fill the gaps and enter Backlog
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
        -- Add a card whose Change and Out of scope are empty
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

        -- Refuse the move into Ready
        local out, code = dev(root, home, { "board", "move", a, Column.READY })
        testing.eq(code, 1)
        testing.ok(out:find("text under ## Change", 1, true), out)
        testing.ok(out:find("text under ## Out of scope", 1, true), out)

        -- Fill both sections through edit
        local file = root .. "/full.md"
        assert(fs.write(
            file,
            table.concat({
                "## Problem",
                "why",
                "",
                "## Change",
                "- x",
                "",
                "## Out of scope",
                "none",
                "",
            }, "\n")
        ))
        out, code = dev(root, home, { "board", "edit", a, "--file", file })
        testing.eq(code, 0, out)

        -- Enter Ready
        out, code = dev(root, home, { "board", "move", a, Column.READY })
        testing.eq(code, 0, out)
    end
)

testing.test(
    "order puts the named cards first and keeps the rest below on a local board",
    function()
        -- Add four cards and keep their ids newest first
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

        -- Read the card names out of a listing
        local function names(out)
            local found = {}
            for name in out:gmatch("(%a+)\n") do
                found[#found + 1] = name
            end
            return found
        end
        local out = dev(root, home, { "board", "ls" })
        testing.eq(names(out), { "One", "Two", "Three", "Four" })

        -- Put the named cards first and see the rest keep their order
        local four, three, two, one = ids[1], ids[2], ids[3], ids[4]
        out = dev(root, home, { "board", "order", three, one })
        testing.eq(names(out), { "Three", "One", "Two", "Four" })
        out = dev(root, home, { "board", "ls" })
        testing.eq(names(out), { "Three", "One", "Two", "Four" })
        out = dev(root, home, { "board", "order", four })
        testing.eq(names(out), { "Four", "Three", "One", "Two" })

        -- Refuse a card named twice and leave the order alone
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
        -- Add two cards and move the second to another column
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

        -- Refuse an order across two columns and leave the listing as it was
        local before = dev(root, home, { "board", "ls" })
        local code
        out, code = dev(root, home, { "board", "order", one, two })
        testing.eq(code, 1, out)
        testing.ok(out:find("one column", 1, true), out)
        testing.eq(dev(root, home, { "board", "ls" }), before)

        -- Hold the second card for the owner and see its ordering freed
        hold_for_owner(home, two)
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
    -- Add two cards
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

    -- Move the second card into the empty Icebox
    dev(root, home, { "board", "move", two, Column.ICEBOX })

    -- See the Icebox card listed first
    local out = dev(root, home, { "board", "ls" })
    testing.ok(out:find("Two", 1, true) < out:find("One", 1, true), out)
end)

testing.test("run starts a lint-clean run card, resumes it and ends it", function()
    -- Refuse a run with no orders
    local root, home = local_board()
    local agent = { DEV_AGENT = "dotfiles/one" }
    local out, code = dev(root, home, { "board", "run" }, agent)
    testing.eq(code, 1, out)
    testing.ok(out:find("dev board run --orders TEXT", 1, true), out)

    -- Start a run card from two lines of orders
    out, code = dev(root, home, {
        "board",
        "run",
        "--orders",
        table.concat({ "Clear the board", "then stop" }, "\n"),
    }, agent)
    testing.eq(code, 0, out)
    testing.ok(out:find("started ", 1, true), out)
    testing.ok(out:find("run dotfiles/one", 1, true), out)
    testing.ok(out:find("> Clear the board", 1, true), out)

    -- Refuse a second run card and see the board lint clean
    out, code = dev(root, home, { "board", "run", "--orders", "again" }, agent)
    testing.eq(code, 1, out)
    testing.ok(out:find("already has the run card", 1, true), out)
    out, code = dev(root, home, { "board", "lint" })
    testing.eq(code, 0, out)
    testing.eq(out, "No findings.\n")

    -- Resume the run and see nothing ready
    out, code = dev(root, home, { "board", "run" }, agent)
    testing.eq(code, 0, out)
    testing.ok(out:find("held by dotfiles/one:", 1, true), out)
    testing.ok(out:find("no ready cards", 1, true), out)

    -- End the run and see it gone
    out, code = dev(root, home, { "board", "run", "--end" }, agent)
    testing.eq(code, 0, out)
    testing.ok(out:find("ended ", 1, true), out)
    out, code = dev(root, home, { "board", "run" }, agent)
    testing.eq(code, 1, out)
    out, code = dev(root, home, { "board", "lint" })
    testing.eq(code, 0, out)
end)

testing.test("run gives each session its own card and next never returns one", function()
    -- Start a run card for each of two sessions
    local root, home = local_board()
    local one, two = { DEV_AGENT = "s/one" }, { DEV_AGENT = "s/two" }
    testing.eq(select(2, dev(root, home, { "board", "run", "--orders", "a" }, one)), 0)
    testing.eq(select(2, dev(root, home, { "board", "run", "--orders", "b" }, two)), 0)

    -- See both run cards listed
    local out, code = dev(root, home, { "board", "ls" })
    testing.ok(out:find("run s/one", 1, true), out)
    testing.ok(out:find("run s/two", 1, true), out)

    -- Resume the first session and see only its own card
    out = dev(root, home, { "board", "run" }, one)
    testing.ok(not out:find("> b", 1, true), out)
    local id = assert(out:match("^(%x+)"), out)
    dev(root, home, { "board", "note", id, "built, tried, learned" }, one)
    out, code = dev(root, home, { "board", "move", id, Column.READY }, one)
    testing.eq(code, 0, out)

    -- Add a plain card and see next skip the run cards
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

    -- End one run and see next still skip them
    out, code = dev(root, home, { "board", "run", "--end" }, one)
    testing.eq(code, 0, out)
    out = dev(root, home, { "board", "next" })
    testing.ok(not out:find("run s/", 1, true), out)
end)

testing.test("run refuses orders over the word limit and a flag mix", function()
    -- Refuse orders over the word limit
    local root, home = local_board()
    local long = string.rep("word ", 300)
    local out, code = dev(root, home, { "board", "run", "--orders", long })
    testing.eq(code, 2, out)

    -- Refuse orders beside --end
    out, code = dev(root, home, { "board", "run", "--orders", "x", "--end" })
    testing.eq(code, 2, out)

    -- Refuse orders given twice
    out, code = dev(root, home, { "board", "run", "--orders", "a", "--orders", "b" })
    testing.eq(code, 2, out)
    testing.ok(out:find("takes one value", 1, true), out)
end)

testing.test("run on a private project with no board starts making one", function()
    local root, home = setup("")
    local out, code = dev(
        root,
        home,
        { "board", "run", "--orders", "x" },
        { DEV_AGENT = "dotfiles/lead" }
    )
    testing.eq(code, 1, out)
    testing.ok(out:find("This project is private and has no board.", 1, true), out)
    testing.ok(out:find("lead_token", 1, true), out)
end)

testing.test("run with orders over the limit makes no board", function()
    -- Refuse each bad orders flag without making a board
    local root, home = setup("")
    local agent = { DEV_AGENT = "dotfiles/one" }
    local long = string.rep("word ", 300)
    local refused = {
        { "--orders", long },
        { "--orders", "a", "--orders", "b" },
        { "--orders", "" },
    }
    for _, flags in ipairs(refused) do
        local args = { "board", "run", table.unpack(flags) }
        local out, code = dev(root, home, args, agent)
        testing.eq(code, 2, out)
        testing.ok(not out:find("Making", 1, true), out)
    end

    -- Refuse a holder name that is too long
    local out, code = dev(
        root,
        home,
        { "board", "run", "--orders", "x" },
        { DEV_AGENT = "dotfiles/" .. string.rep("x", 100) }
    )
    testing.eq(code, 2, out)
    testing.ok(out:find("too long", 1, true), out)
    testing.ok(not out:find("Making", 1, true), out)

    -- Leave no board or backend setting behind
    testing.eq(fs.exists(root .. "/.dev/board.json"), false)
    testing.eq(fs.read(root .. "/.dev/config.toml"):find("backend", 1, true), nil)
end)

local function unboarded(origin, private)
    -- Make a project with no board
    local root, home = setup("")

    -- Point its origin at the given remote
    if origin then
        assert(dev_os.run({ "git", "-C", root, "init", "-q" }) == 0, "git init failed")
        assert(
            dev_os.run({ "git", "-C", root, "remote", "add", "origin", origin }) == 0,
            "git remote failed"
        )
    end

    -- Stub gh to answer whether the project is private
    assert(fs.write(
        root .. "/bin/gh",
        table.concat({
            "#!/bin/sh",
            "echo " .. tostring(private),
            "",
        }, "\n")
    ))
    assert(dev_os.run({ "chmod", "755", root .. "/bin/gh" }) == 0, "chmod failed")
    return root, home
end

testing.test(
    "run makes a board for a private project and refuses a public or non-GitHub one",
    function()
        -- Offer to make a board for a private GitHub project
        local agent = { DEV_AGENT = "dotfiles/one" }
        local root, home = unboarded("https://github.com/o/r.git", true)
        local out, code = dev(root, home, { "board", "run", "--orders", "x" }, agent)
        testing.eq(code, 1, out)
        testing.ok(out:find("This project is private and has no board.", 1, true), out)

        -- Refuse a project that is not on GitHub
        root, home = unboarded("https://gitlab.example.com/o/r.git", true)
        out, code = dev(root, home, { "board", "run", "--orders", "x" }, agent)
        testing.eq(code, 1, out)
        testing.ok(out:find("public or not known to be private", 1, true), out)
        testing.ok(not out:find("Making", 1, true), out)

        -- Refuse a public GitHub project
        root, home = unboarded("https://github.com/o/r.git", false)
        out, code = dev(root, home, { "board", "run", "--orders", "x" }, agent)
        testing.eq(code, 1, out)
        testing.ok(out:find("public or not known to be private", 1, true), out)
        testing.ok(not out:find("Making", 1, true), out)
    end
)

testing.test("run prints the cards the session holds and the ready card that is next", function()
    -- Define a helper that adds a Ready card
    local root, home = local_board()
    local agent = { DEV_AGENT = "dotfiles/one" }
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

    -- Add two Ready cards and take the first
    local held = add("Held card")
    add("Next card")
    local out, code = dev(root, home, { "board", "take", held }, agent)
    testing.eq(code, 0, out)

    -- Start a run and print it
    out, code = dev(root, home, { "board", "run", "--orders", "Clear the board" }, agent)
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "run" }, agent)
    testing.eq(code, 0, out)

    -- Split the print into the held part and the next part
    local from_held = out:find("held by dotfiles/one:", 1, true)
    local from_next = out:find("\nnext:\n", 1, true)
    testing.ok(from_held and from_next and from_held < from_next, out)
    local holding = out:sub(from_held, from_next)
    testing.ok(holding:find("Held card", 1, true) and not holding:find("Next card", 1, true), out)
    testing.ok(out:sub(from_next):find("Next card", 1, true), out)
end)

local RUN_ID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
local RUN_AGENT = { DEV_AGENT = "dotfiles/one" }
local RUN_JUDGED = '[{"id":"r1","name":"a (reviewer judgement)","done":false},'
    .. '{"id":"r2","name":"b (reviewer judgement)","done":false},'
    .. '{"id":"r3","name":"c (reviewer judgement)","done":false}]'

---Build an export that holds a run card in front of the board's two Ready cards.
local function export_with_run(task)
    local run = support.pomb_export_task({
        id = RUN_ID,
        name = "run dotfiles/one",
        color_id = BLUE_ID,
        labels = { board.RUN },
        description = "## Problem\\nx\\n\\n## Change\\n- > orders\\n\\n## Out of scope\\nnone",
        subtasks = RUN_JUDGED,
        column_id = task.column_id,
        holder = task.holder,
        claim_fence = task.holder and 1 or 0,
        position = 0,
    })
    return (EXPORT:gsub('^{"tasks":%[', function(head)
        return head .. run .. ","
    end))
end

testing.test("run on a Pomb board starts, resumes and ends a run card", function()
    -- Serve the export a run card produces once it is posted
    local root, home = pomb()
    assert(fs.write(
        root .. "/after_post.json",
        export_with_run({
            column_id = support.column_id(Column.PROGRESS),
            holder = "dotfiles/one",
        })
    ))

    -- Start the run and see its card posted with the orders
    local env = { ROOT = root, DEV_AGENT = RUN_AGENT.DEV_AGENT }
    local out, code = dev(root, home, { "board", "run", "--orders", "Clear the board" }, env)
    testing.eq(code, 0, out)
    testing.ok(out:find("started cccccccc", 1, true), out)
    testing.ok(out:find("run dotfiles/one", 1, true), out)
    testing.ok(calls(root):find("/api/tasks/" .. RUN_ID .. "/owner", 1, true), calls(root))
    testing.ok(sent_bodies(root):find("Clear the board", 1, true), "orders were not sent")

    -- Resume the run once the export holds its card
    assert(fs.write(root .. "/export.json", assert(fs.read(root .. "/after_post.json"))))
    out, code = dev(root, home, { "board", "run" }, env)
    testing.eq(code, 0, out)
    testing.ok(out:find("run dotfiles/one", 1, true), out)
    testing.ok(out:find("held by dotfiles/one:\nnothing\nnext:\n", 1, true), out)
    testing.ok(out:find("\nnext:\n%x+  Ready"), out)

    -- End the run and see its claim released
    out, code = dev(root, home, { "board", "run", "--end" }, env)
    testing.eq(code, 0, out)
    testing.ok(out:find("ended cccccccc", 1, true), out)
    testing.ok(calls(root):find("/api/tasks/" .. RUN_ID .. "/owner/release", 1, true), calls(root))
end)

testing.test("next on a Pomb board skips a run card", function()
    local root, home = pomb()
    assert(fs.write(root .. "/export.json", export_with_run({ column_id = READY_COLUMN })))
    local out, code = dev(root, home, { "board", "next" }, { ROOT = root, DEV_MAX_SIZE = "" })
    testing.eq(code, 0, out)
    testing.ok(out:find("bbbbbbbb", 1, true), out)
    testing.ok(not out:find("cccccccc", 1, true) and not out:find("run dotfiles", 1, true), out)
end)

local function blocked_by(target)
    return '[{"id":"link-1","kind":"blocked_by","target_id":"' .. target .. '"}]'
end

local function blocked_export(blocker_column)
    return '{"tasks":['
        .. support.pomb_export_task({
            id = ID_B,
            name = "Second",
            column_id = READY_COLUMN,
            color_id = false,
        })
        .. ","
        .. support.pomb_export_task({
            id = ID_C,
            name = "Third",
            column_id = blocker_column,
            position = 2,
            color_id = false,
        })
        .. "]}"
end

testing.test(
    "next on a Pomb board skips an open blocker and returns a card whose blocker is done",
    function()
        -- Block the second card on an open third card
        local root, home = pomb()
        local env = { ROOT = root, DEV_MAX_SIZE = "" }
        assert(fs.write(root .. "/links_b.json", blocked_by(ID_C)))
        assert(fs.write(root .. "/export.json", blocked_export(READY_COLUMN)))

        -- See next skip the blocked card
        local out, code = dev(root, home, { "board", "next" }, env)
        testing.eq(code, 0, out)
        testing.ok(out:find("cccccccc", 1, true), out)
        testing.ok(not out:find("bbbbbbbb", 1, true), out)

        -- Finish the blocker and see next return the blocked card
        assert(
            fs.write(
                root .. "/detail.json",
                (
                    DETAIL:gsub(
                        '{"id":"col%-done","name":"Done"}',
                        '{"id":"col-done","name":"Done","is_done":true}'
                    )
                )
            )
        )
        assert(fs.write(root .. "/export.json", blocked_export(support.column_id(Column.DONE))))
        out, code = dev(root, home, { "board", "next" }, env)
        testing.eq(code, 0, out)
        testing.ok(out:find("bbbbbbbb", 1, true), out)
    end
)

testing.test("next on a Pomb board skips a card whose blocker cannot be read", function()
    local root, home = pomb()
    local env = { ROOT = root, DEV_MAX_SIZE = "" }
    assert(fs.write(root .. "/links_b.json", blocked_by("dddddddd-1111-4ddd-8ddd-dddddddddddd")))
    assert(fs.write(root .. "/export.json", blocked_export(READY_COLUMN)))
    local out, code = dev(root, home, { "board", "next" }, env)
    testing.eq(code, 0, out)
    testing.ok(out:find("cccccccc", 1, true), out)
    testing.ok(not out:find("bbbbbbbb", 1, true), out)
end)

testing.test("blocked returns the open blocker id on a Pomb board", function()
    local root, home = pomb()
    local env = { ROOT = root, DEV_MAX_SIZE = "" }
    assert(fs.write(root .. "/links_b.json", blocked_by(ID_C)))
    assert(fs.write(root .. "/export.json", blocked_export(READY_COLUMN)))
    local out, code = dev(root, home, { "board", "move", "bbbbbbbb", Column.PROGRESS }, env)
    testing.eq(code, 1, out)
    testing.ok(out:find("is blocked by open card " .. ID_C, 1, true), out)
end)

testing.test("blocked returns the open blocker id on a local board", function()
    -- Define a helper that adds a Ready card
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

    -- Add a card and a blocker for it
    local blocked, blocker = add("Blocked"), add("Blocker")
    dev(root, home, { "board", "link", blocked, "blocked_by", blocker })

    -- Refuse to start the blocked card
    local out, code = dev(root, home, { "board", "move", blocked, Column.PROGRESS })
    testing.eq(code, 1, out)
    testing.ok(out:find("is blocked by open card " .. blocker, 1, true), out)
end)

testing.test(
    "add --id-only prints the full id alone and sends warnings to standard error",
    function()
        -- Add a card whose prose names a path
        local root, home = local_board()
        local out, code, errors = support.dev(root, {
            "board",
            "add",
            "Fresh",
            "--id-only",
            "--description",
            table.concat({
                "## Problem",
                "look in src/a.lua",
                "",
                "## Change",
                "x",
                "",
                "## Out of scope",
                "y",
                "",
            }, "\n"),
            "--size",
            "1",
            "--done-when",
            "a",
        }, { env = env_of(home), split = true })

        -- See the id alone on standard output and the warning on standard error
        testing.eq(code, 0, out)
        testing.ok(out:match("^%x+%-%x+%-%x+%-%x+%-%x+\n$"), out)
        testing.eq(errors, "Card prose holds a path: src/a.lua. The write still went through.\n")

        -- Add a plain card and see the usual line
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
    -- Take Pomb down
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))

    -- Refuse a plain add
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

    -- Refuse an add that names a blocker
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

    -- Refuse an add that names a lane and checks
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
    -- See the big card first when no limit is set
    local root, home, big, small = sized_board()
    local out = dev(root, home, { "board", "next" }, { DEV_MAX_SIZE = "" })
    testing.ok(out:find(big, 1, true), out)

    -- See the small card once a flag or the environment sets a limit
    out = dev(root, home, { "board", "next", "--max-size", "1" })
    testing.ok(out:find(small, 1, true) and not out:find(big, 1, true), out)
    out = dev(root, home, { "board", "next" }, { DEV_MAX_SIZE = "2" })
    testing.ok(out:find(small, 1, true) and not out:find(big, 1, true), out)

    -- Refuse a limit outside the sizes
    local code
    out, code = dev(root, home, { "board", "next", "--max-size", "9" })
    testing.eq(code, 2, out)
end)

testing.test("take and move into progress refuse a card above the runner's size limit", function()
    -- Refuse to take the big card
    local root, home, big, small = sized_board()
    local env = { DEV_MAX_SIZE = "2", DEV_AGENT = "r/one" }
    local out, code = dev(root, home, { "board", "take", big }, env)
    testing.eq(code, 1, out)
    testing.ok(out:find("above this runner's limit of 2 Pomodori", 1, true), out)

    -- Refuse to move it into progress and leave it unclaimed
    out, code = dev(root, home, { "board", "move", big, Column.PROGRESS }, env)
    testing.eq(code, 1, out)
    testing.ok(out:find("above this runner's limit", 1, true), out)
    testing.eq(card_named(document(file_of(home)), "Big").claim, nil)

    -- Take the small card
    out, code = dev(root, home, { "board", "take", small }, env)
    testing.eq(code, 0, out)
end)

testing.test("with no size limit set next, take and move change nothing", function()
    -- See next return the big card
    local root, home, big = sized_board()
    local out, code = dev(root, home, { "board", "next" }, { DEV_MAX_SIZE = "" })
    testing.eq(code, 0, out)
    testing.ok(out:find(big, 1, true), out)

    -- Take it and move it into progress
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

    -- Note it and move it into review
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
    -- Refuse to take the big card under a lower flag
    local root, home, big, small = sized_board()
    local env = { DEV_MAX_SIZE = "3", DEV_AGENT = "r/one" }
    local out, code = dev(root, home, { "board", "take", big, "--max-size", "2" }, env)
    testing.eq(code, 1, out)
    testing.ok(out:find("above this runner's limit of 2 Pomodori", 1, true), out)

    -- Refuse to move it under a lower flag still
    out, code = dev(root, home, { "board", "move", big, Column.PROGRESS, "--max-size", "1" }, env)
    testing.eq(code, 1, out)
    testing.ok(out:find("above this runner's limit of 1 Pomodori", 1, true), out)

    -- Take both cards when the flag raises a low environment limit
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
    -- Start a run with no limit
    local root, home = sized_board()
    local agent = { DEV_AGENT = "dotfiles/one", DEV_MAX_SIZE = "" }
    dev(root, home, { "board", "run", "--orders", "Clear the board" }, agent)

    -- Set a limit outside the sizes
    agent.DEV_MAX_SIZE = "9"

    -- Resume the run anyway
    local out, code = dev(root, home, { "board", "run" }, agent)
    testing.eq(code, 0, out)
end)

testing.test("run prints a next card within DEV_MAX_SIZE", function()
    -- Start a run with no limit
    local root, home, big, small = sized_board()
    local agent = { DEV_AGENT = "dotfiles/one", DEV_MAX_SIZE = "" }
    dev(root, home, { "board", "run", "--orders", "Clear the board" }, agent)

    -- See the big card printed as next
    local out = dev(root, home, { "board", "run" }, agent)
    testing.ok(out:find(big, 1, true), out)

    -- Set a limit of one and see the small card printed instead
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
    -- Name a big and a small Ready card
    local root, home = pomb()
    local big = "cccccccc-2222-4ccc-8ccc-cccccccccccc"
    local small = "dddddddd-2222-4ddd-8ddd-dddddddddddd"

    -- Build a card's export body
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

    -- Serve both cards
    assert(
        fs.write(
            root .. "/page.json",
            '{"items":[{"id":"' .. big .. '"},{"id":"' .. small .. '"}],"next_cursor":null}'
        )
    )
    assert(fs.write(root .. "/big.json", task(big, "Big", BLUE_ID)))
    assert(fs.write(root .. "/small.json", task(small, "Small", YELLOW_ID)))

    -- Hand back the board and the two prefixes
    return root, home, big:sub(1, 8), small:sub(1, 8)
end

testing.test("next --max-size skips a size 3 card on a pomb board", function()
    -- See the big card first when no limit is set
    local root, home, big, small = sized_pomb()
    local out = dev(root, home, { "board", "next" }, { ROOT = root, DEV_MAX_SIZE = "" })
    testing.ok(out:find(big, 1, true) and not out:find(small, 1, true), out)

    -- See the small card under the flag
    out = pomb_dev(root, home, { "board", "next", "--max-size", "1" })
    testing.ok(out:find(small, 1, true) and not out:find(big, 1, true), out)

    -- See the small card under the environment
    out = dev(root, home, { "board", "next" }, { ROOT = root, DEV_MAX_SIZE = "1" })
    testing.ok(out:find(small, 1, true) and not out:find(big, 1, true), out)
end)

testing.test("next --for lead on a pomb board skips the planner and owner cards", function()
    -- Name the cards and the helpers that build and read them
    local root, home = pomb()
    local both = "eeeeeeee-3333-4eee-8eee-eeeeeeeeeeee"
    local planner = "ffffffff-3333-4fff-8fff-ffffffffffff"
    local lead = "99999999-3333-4999-8999-999999999999"
    local plain = "88888888-3333-4888-8888-888888888888"
    local blocked_id = support.column_id(Column.BLOCKED)
    local function task(id, name, position, labels)
        return support.pomb_export_task({
            id = id,
            name = name,
            column_id = blocked_id,
            position = position,
            color_id = false,
            labels = labels,
        })
    end
    local function only(out, id)
        for _, other in ipairs({ both, plain, planner, lead }) do
            if (other == id) ~= (out:find(other:sub(1, 8), 1, true) ~= nil) then
                return false
            end
        end
        return true
    end

    -- Seed a Blocked column whose first eligible card holds neither label
    assert(
        fs.write(
            root .. "/detail.json",
            (DETAIL:gsub('{"id":"col%-done"', '{"id":"' .. blocked_id .. '","name":"Blocked"},%0'))
        )
    )
    assert(
        fs.write(
            root .. "/export.json",
            '{"tasks":['
                .. task(both, "Both", 1, { "needs:lead", "needs:human" })
                .. ","
                .. task(plain, "Plain", 2, { "docs" })
                .. ","
                .. task(planner, "Planner", 3, { "needs:planner" })
                .. ","
                .. task(lead, "Lead", 4, { "needs:lead" })
                .. "]}"
        )
    )
    local env = { ROOT = root, DEV_MAX_SIZE = "" }

    -- Return only the needs:planner card for the planner
    local out, code =
        dev(root, home, { "board", "next", "--column", Column.BLOCKED, "--for", "planner" }, env)
    testing.eq(code, 0, out)
    testing.ok(only(out, planner), out)

    -- Return only the needs:lead card without needs:human for the lead
    out, code =
        dev(root, home, { "board", "next", "--column", Column.BLOCKED, "--for", "lead" }, env)
    testing.eq(code, 0, out)
    testing.ok(only(out, lead), out)
end)

testing.test("a local epic moves through the columns", function()
    -- Define a helper that adds a card
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

    -- Make an epic with one child
    local epic, child = add("Epic"), add("Child")
    tick_first(root, home, epic)
    dev(root, home, { "board", "epic", epic })
    dev(root, home, { "board", "link", child, "parent", epic })

    -- Refuse the epic's move to Done while the child is open
    local out, code = dev(root, home, { "board", "move", epic, Column.DONE })
    testing.eq(code, 1, out)
    testing.ok(
        out:find(
            "is an epic and cannot enter " .. support.COLUMN_NAME.DONE .. ", a done column",
            1,
            true
        ),
        out
    )
    testing.ok(out:find("1 of 1 children are open", 1, true), out)

    -- Finish the child and then the epic
    out, code = support.to_review(function(args)
        return dev(root, home, args)
    end, epic)
    testing.eq(code, 0, out)
    tick_first(root, home, child)
    dev(root, home, { "board", "move", child, Column.DONE })
    out, code = dev(root, home, { "board", "move", epic, Column.DONE })
    testing.eq(code, 0, out)

    -- Reopen both and see the epic count its child
    dev(root, home, { "board", "move", child, Column.BACKLOG })
    out, code = dev(root, home, { "board", "move", epic, Column.BACKLOG })
    testing.eq(code, 0, out)
    out = dev(root, home, { "board", "ls" })
    testing.ok(out:find("[epic 1 of 1 open] Epic", 1, true), out)
end)

testing.test("next on a local board skips an epic with an open child", function()
    -- Define a helper that adds a Ready card
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

    -- Make an epic with one open child
    local epic, child = add("Epic"), add("Child")
    dev(root, home, { "board", "epic", epic })
    dev(root, home, { "board", "link", child, "parent", epic })

    -- See the board count the open child
    local out = dev(root, home, { "board", "ls" })
    testing.ok(out:find("[epic 1 of 1 open] Epic", 1, true), out)
    out = dev(root, home, { "board", "show", epic })
    testing.ok(out:find("\nkind: epic, 1 open\n", 1, true), out)

    -- See next return the child and skip the epic
    out = dev(root, home, { "board", "next" })
    testing.ok(out:find(child .. "  Ready", 1, true), out)
    out = dev(root, home, { "board", "next", "--column", Column.READY })
    testing.ok(out:find(child, 1, true) and not out:find(epic, 1, true), out)

    -- Finish the child and see the epic become next
    tick_all(root, home, child)
    out = dev(root, home, { "board", "move", child, Column.DONE })
    out = dev(root, home, { "board", "next" })
    testing.ok(out:find(epic .. "  Ready", 1, true), out)

    -- Take the epic as a runner
    out = dev(root, home, { "board", "move", epic, Column.PROGRESS }, { DEV_AGENT = "r/one" })
    testing.ok(out:find("r/one", 1, true), out)
    testing.eq(card_named(document(file_of(home)), "Epic").claim.claimant, "r/one")
end)

testing.test("next skips an epic whose child is in progress", function()
    -- Define a helper that adds a Ready card
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

    -- Make an epic with one child
    local epic, child = add("Epic"), add("Child")
    dev(root, home, { "board", "epic", epic })
    dev(root, home, { "board", "link", child, "parent", epic })

    -- Start the child as a runner
    local out, code = dev(
        root,
        home,
        { "board", "move", child, Column.PROGRESS },
        { DEV_AGENT = "r/one" }
    )
    testing.eq(code, 0, out)

    -- See next skip both cards
    out, code = dev(root, home, { "board", "next" })
    testing.eq(code, 0, out)
    testing.ok(not out:find(epic, 1, true) and not out:find(child, 1, true), out)
end)

testing.test("a local board has no blocked setting", function()
    local root, home =
        setup(table.concat({ "[board]", 'backend = "local"', 'name = "mine"', "" }, "\n"))
    local out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(out:find("marked Blocked", 1, true), nil)
    for _, column in ipairs(document(file_of(home)).columns) do
        testing.eq(column.is_blocked, nil)
    end
end)

testing.test("local board keeps the epic kind and refuses a parent that is not an epic", function()
    -- Define a helper that adds a card with extra flags
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

    -- Add an epic, a plain card and a child, and read their kinds
    local made, plain, child = add("Made", "--epic"), add("Plain"), add("Child")
    local doc = document(file_of(home))
    testing.eq(card_named(doc, "Made").kind, "epic")
    testing.eq(card_named(doc, "Plain").kind, "task")

    -- Refuse the plain card as a parent
    local out, code = dev(root, home, { "board", "link", child, "parent", plain })
    testing.eq(code, 1, out)
    testing.ok(out:find("Make it one with `dev board epic " .. plain, 1, true), out)

    -- Make the plain card an epic and refuse to do it twice
    out, code = dev(root, home, { "board", "epic", plain })
    testing.eq(out, "made " .. plain .. " an epic\n")
    testing.eq(code, 0)
    testing.eq(card_named(document(file_of(home)), "Plain").kind, "epic")
    out, code = dev(root, home, { "board", "epic", plain })
    testing.eq(code, 1, out)
    testing.ok(out:find("already an epic", 1, true), out)

    -- Link the child to the epic and see both listed
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
    testing.ok(sent_bodies(root):find('"kind":"epic"', 1, true), sent_bodies(root))
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
    testing.eq(sent_bodies(root), '{"kind":"epic"}\n')
    assert(fs.write(root .. "/held", ""))
    out, code = pomb_dev(root, home, { "board", "epic", ID_A:sub(1, 8) })
    testing.eq(code, 1, out)
    testing.ok(out:find("409", 1, true) and out:find("the card holds a live claim", 1, true), out)
end)

testing.test("a childless epic enters Ready with 1 to 3 outcomes like any epic", function()
    -- Refuse an epic with four outcomes
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

    -- Add an epic with two outcomes
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

    -- Move it through Backlog into Ready
    local epic = prefix_of(out)
    out, code = dev(root, home, { "board", "move", epic, Column.BACKLOG })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", epic, Column.READY })
    testing.eq(code, 0, out)

    -- See the board lint clean
    out, code = dev(root, home, { "board", "lint" })
    testing.eq(code, 0, out)
    testing.eq(out:find("lacks 3 to 7", 1, true), nil, out)
end)

testing.test("a childless epic with 4 outcomes is refused entering Ready", function()
    -- Add a card with four outcomes
    local root, home = local_board()
    local out, code = dev(root, home, {
        "board",
        "add",
        "Big",
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
        "--checks",
        "dev test",
    })
    testing.eq(code, 0, out)

    -- Make it an epic
    local epic = prefix_of(out)
    out, code = dev(root, home, { "board", "epic", epic })
    testing.eq(code, 0, out)

    -- Refuse its move into Ready
    out, code = dev(root, home, { "board", "move", epic, Column.READY })
    testing.eq(code, 1, out)
    testing.ok(out:find("lacks 1 to 3 Done when outcomes for an epic, not 4", 1, true), out)
end)

testing.test("attach, attachments and detach refuse plainly on a local board", function()
    -- Add a card
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

    -- Write a file to attach
    local file = support.tempdir() .. "/shot.png"
    assert(fs.write(file, "x"))

    -- Refuse each attachment verb
    for _, args in ipairs({
        { "board", "attach", a, file },
        { "board", "attachments", a },
        { "board", "detach", a, "abcd" },
        { "board", "download", a, "abcd" },
    }) do
        local out, code = dev(root, home, args)
        testing.eq(code, 1, out)
        testing.ok(out:find("A local board holds no attachments.", 1, true), out)
    end
end)

local function laned_board()
    -- Add three cards
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

    -- File the cards under two lanes
    local doc = document(file_of(home))
    doc.swimlanes = {
        { id = "lane-parity", name = "Parity" },
        { id = "lane-fixes", name = "Fixes" },
    }
    doc.cards[1].swimlane_id = "lane-fixes"
    doc.cards[2].swimlane_id = "lane-parity"
    doc.cards[3].swimlane_id = "lane-parity"
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- Hand back the board and the card ids
    return root, home, ids
end

testing.test("local orders cards by lane then position", function()
    -- List the Backlog of a two-lane board
    local root, home, ids = laned_board()
    local out = dev(root, home, { "board", "ls", "--column", Column.BACKLOG })

    -- Read each row's lane and name
    local rows = {}
    local pattern = support.COLUMN_NAME.BACKLOG .. "%s+(%S+)%s+%S+%s+%S+%s+%S+%s+%S+%s+(%S+)"
    for lane, name in out:gmatch(pattern) do
        rows[#rows + 1] = lane .. " " .. name
    end
    testing.eq(rows, { "Parity Bravo", "Parity Charlie", "Fixes Alpha" })

    -- See next return the first card of the first lane
    out = dev(root, home, { "board", "next", "--column", Column.BACKLOG })
    local want = ids.Bravo .. "  " .. support.COLUMN_NAME.BACKLOG .. "  Parity  "
    testing.ok(out:find(want, 1, true), out)
end)

testing.test("local puts column order before lane order", function()
    -- Move the first card to the Icebox
    local root, home, ids = laned_board()
    local out, code = dev(root, home, { "board", "move", ids.Alpha, Column.ICEBOX })
    testing.eq(code, 0, out)

    -- List the board
    out = dev(root, home, { "board", "ls" })

    -- Read the names in listing order
    local names = {}
    for line in out:gmatch("[^\n]+") do
        names[#names + 1] = line:match("(%S+)$")
    end
    testing.eq(names, { "Alpha", "Bravo", "Charlie" })
end)

testing.test("local sorts a card with no lane last with no lane name", function()
    -- Strip one card of its lane
    local root, home = laned_board()
    local doc = document(file_of(home))
    doc.cards[2].swimlane_id = nil
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- List the Backlog
    local out = dev(root, home, { "board", "ls", "--column", Column.BACKLOG })

    -- Read each row's lane and name
    local rows = {}
    local pattern = support.COLUMN_NAME.BACKLOG .. "%s+(%S+)%s+%S+%s+%S+%s+%S+%s+%S+%s+(%S+)"
    for lane, name in out:gmatch(pattern) do
        rows[#rows + 1] = lane .. " " .. name
    end
    testing.eq(rows, { "Parity Charlie", "Fixes Alpha", "- Bravo" })
end)

testing.test("local add with a lane puts the card in that lane", function()
    -- Build the arguments of an add
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

    -- Add a card without a lane
    local out, code = dev(root, home, args)
    testing.eq(code, 0, out)

    -- Add another into the Fixes lane
    table.insert(args, "--lane")
    table.insert(args, "fixes")
    args[3] = "Echo"
    out, code = dev(root, home, args)
    testing.eq(code, 0, out)

    -- Read both cards' lanes
    local cards = document(file_of(home)).cards
    testing.eq(cards[4].swimlane_id, nil)
    testing.eq(cards[5].swimlane_id, "lane-fixes")
end)

testing.test("local move keeps the lane unless a lane is given", function()
    -- Define a reader of a card's lane
    local root, home, ids = laned_board()
    local function lane_of(name)
        for _, card in ipairs(document(file_of(home)).cards) do
            if card.name == name then
                return card.swimlane_id
            end
        end
    end

    -- Move a card and see its lane kept
    local out, code = dev(root, home, { "board", "move", ids.Alpha, Column.ICEBOX })
    testing.eq(code, 0, out)
    testing.eq(lane_of("Alpha"), "lane-fixes")

    -- Move it with a lane and see the lane change
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
    -- Cut the board down to one lane
    local root, home, ids = laned_board()
    local doc = document(file_of(home))
    doc.swimlanes = { { id = "lane-parity", name = "Parity" } }
    assert(fs.write(file_of(home), assert(json.encode(doc))))

    -- Show a card without a lane
    local out = dev(root, home, { "board", "show", ids.Alpha })
    testing.ok(not out:find("Parity", 1, true), out)

    -- List the Backlog without a lane
    out = dev(root, home, { "board", "ls", "--column", Column.BACKLOG })
    testing.ok(not out:find("Parity", 1, true), out)
end)

testing.test("local init creates the lanes the board config lists once", function()
    -- Set up a project whose config lists two lanes
    local root, home = setup(table.concat({
        "[board]",
        'backend = "local"',
        'name = "mine"',
        'lanes = ["Parity", "Fixes"]',
        "",
    }, "\n"))

    -- Run init and see both lanes created
    local out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)
    testing.ok(out:find('created lane "Parity"\ncreated lane "Fixes"\n', 1, true), out)

    -- Read the lanes off the board file
    local doc = document(file_of(home))
    testing.eq(#doc.swimlanes, 2)
    testing.eq(doc.swimlanes[1].name, "Parity")
    testing.eq(doc.swimlanes[2].name, "Fixes")

    -- Run init again and see nothing new
    out = dev(root, home, { "board", "init" })
    testing.ok(out:find("already follows the standard", 1, true), out)
    testing.eq(#document(file_of(home)).swimlanes, 2)
end)

testing.test("local init says nothing about an unlisted first lane", function()
    -- Create the lanes the config lists
    local root, home = setup(table.concat({
        "[board]",
        'backend = "local"',
        'name = "mine"',
        'lanes = ["Parity", "Fixes"]',
        "",
    }, "\n"))
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

local function epic_with_child(root, home)
    -- Add a child card
    local child = prefix_of((dev(root, home, {
        "board",
        "add",
        "Child",
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

    -- Add the epic
    local epic = prefix_of((dev(root, home, {
        "board",
        "add",
        "Epic",
        "--column",
        Column.ICEBOX,
        "--size",
        "2",
        "--description",
        PLANNED,
    })))

    -- Make it an epic over the child
    dev(root, home, { "board", "epic", epic })
    dev(root, home, { "board", "link", child, "parent", epic })

    -- Hand back both ids
    return epic, child
end

testing.test("an epic with children needs no outcomes to reach Ready", function()
    -- Move an epic with a child into Backlog
    local root, home = local_board()
    local epic, child = epic_with_child(root, home)
    local out, code = dev(root, home, { "board", "move", epic, Column.BACKLOG })
    testing.eq(code, 0, out)

    -- Finish the child
    tick_first(root, home, child)
    dev(root, home, { "board", "move", child, Column.DONE })

    -- Move the epic into Ready
    out, code = dev(root, home, { "board", "move", epic, Column.READY })
    testing.eq(code, 0, out)
end)

testing.test("an epic closes while its outcomes are open", function()
    -- Give an epic with a child an open outcome and move it into Backlog
    local root, home = local_board()
    local epic, child = epic_with_child(root, home)
    dev(root, home, { "board", "outcome", epic, JUDGED })
    local out, code = dev(root, home, { "board", "move", epic, Column.BACKLOG })
    testing.eq(code, 0, out)

    -- Finish the child and see the epic offered for closing
    tick_first(root, home, child)
    out, code = dev(root, home, { "board", "move", child, Column.DONE })
    testing.eq(code, 0, out)
    testing.ok(
        out:find("Epic " .. epic .. " has every child Done and can close now.", 1, true),
        out
    )

    -- Walk the epic through Ready and review into Done
    out, code = dev(root, home, { "board", "move", epic, Column.READY })
    testing.eq(code, 0, out)
    out, code = support.to_review(function(args)
        return dev(root, home, args)
    end, epic)
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", epic, Column.DONE })
    testing.eq(code, 0, out)
end)
