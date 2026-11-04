local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local TOKEN = "pomb_SECRETtoken0123456789"
local ID_A = "aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa"
local ID_B = "bbbbbbbb-1111-4bbb-8bbb-bbbbbbbbbbbb"
local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
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
    t.eq(code, 0, out)
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
    t.eq(code, 0, out)
end

local function mode(path)
    return string.format("%o", bit.band(assert(fs.stat(path)).mode, 511))
end

t.test("init lays out the nine columns and the palette and is idempotent", function()
    local root, home = setup('[board]\nbackend = "local"\nname = "mine"\n')
    local out, code = dev(root, home, { "board", "init" })
    t.eq(code, 0, out)
    t.ok(out:find("created board mine with no template", 1, true), out)
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
        t.ok(out:find("added column " .. column, 1, true), out)
    end
    t.ok(out:find('named yellow "1 Pomodoro"', 1, true), out)
    t.ok(out:find('named white "Unsized"', 1, true), out)
    t.ok(out:find("made white the default colour", 1, true), out)
    local doc = document(file_of(home))
    local names = {}
    for _, column in ipairs(doc.columns) do
        names[#names + 1] = column.name
    end
    t.eq(names, {
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
    t.eq(doc.columns[9].is_done, true)
    local labels = {}
    for _, color in ipairs(doc.colors) do
        labels[#labels + 1] = color.value .. "=" .. color.label
    end
    t.eq(labels, {
        "yellow=1 Pomodoro",
        "green=2 Pomodori",
        "blue=3 Pomodori",
        "red=>3 Pomodori",
        "white=Unsized",
    })
    out, code = dev(root, home, { "board", "init" })
    t.eq(code, 0, out)
    t.eq(out, "board mine already follows the standard, nothing to change\n")
end)

t.test("the board file is private and writes leave no temporary file", function()
    local root, home = local_board()
    dev(root, home, { "board", "add", "One", "--problem", "x", "--size", "1", "--done-when", "a" })
    t.eq(mode(file_of(home)), "600")
    t.eq(mode(home .. "/state/dev/boards"), "700")
    local names = fs.list(home .. "/state/dev/boards")
    t.eq(names, { "mine.json", "mine.json.lock" })
end)

t.test("boards and columns answer for a local board's own name only", function()
    local root, home = local_board()
    local out, code = dev(root, home, { "board", "boards" })
    t.eq(code, 0, out)
    t.eq(out, "mine\n")
    local columns =
        "Icebox\nBacklog\nReady\nIn Progress\nReview\nVerify\nRelease\nBlocked\nDone (done)\n"
    out, code = dev(root, home, { "board", "columns" })
    t.eq(code, 0, out)
    t.eq(out, columns)
    out, code = dev(root, home, { "board", "columns", "mine" })
    t.eq(code, 0, out)
    t.eq(out, columns)
    out, code = dev(root, home, { "board", "columns", "other" })
    t.eq(code, 1, out)
    t.eq(out, "dev: a local board knows only its own columns, so other is not reachable\n")
    out, code = dev(root, home, { "board", "columns", "mine", "extra" })
    t.eq(code, 2, out)
    out, code = dev(root, home, { "board", "boards", "extra" })
    t.eq(code, 2, out)
end)

t.test("add, ls, next, move, size and label work on a local board", function()
    local root, home = local_board()
    local out, code = dev(root, home, {
        "board",
        "add",
        "Write docs",
        "--column",
        "ready",
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
    t.eq(code, 0, out)
    local a = prefix_of(out)
    t.ok(out:find("Ready", 1, true), out)
    out = dev(
        root,
        home,
        { "board", "add", "Second", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    local b = prefix_of(out)
    out = dev(root, home, { "board", "ls" })
    t.eq(
        out,
        b
            .. "  Backlog  1 Pomodoro  -                0/1  Second\n"
            .. a
            .. "  Ready    2 Pomodori  docs,needs:lead  -    Write docs\n"
    )
    out = dev(root, home, { "board", "ls", "--size", "3+" })
    t.eq(out, "no cards\n")
    out = dev(root, home, { "board", "ls", "--label", "docs" })
    t.ok(out:find("Write docs", 1, true), out)
    out = dev(root, home, { "board", "next" })
    t.eq(out, a .. "  Ready  2 Pomodori  docs,needs:lead  Write docs  0 comments, 0 the owner's\n")
    out = dev(root, home, { "board", "move", a, "review" })
    t.eq(out, "moved " .. a .. " to Review\n")
    out = dev(root, home, { "board", "next" })
    t.eq(out, "no ready cards\n")
    out = dev(root, home, { "board", "size", b, "1" })
    t.eq(out, "sized " .. b .. " 1\n")
    out = dev(root, home, { "board", "label", a, "+extra", "--remove", "docs" })
    t.eq(out, "labelled " .. a .. " needs:lead,extra\n")
    out = dev(root, home, { "board", "move", a, "done" })
    out = dev(root, home, { "board", "ls" })
    t.eq(out, b .. "  Backlog  1 Pomodoro  -  0/1  Second\n")
    out = dev(root, home, { "board", "ls", "--column", "done" })
    t.ok(out:find("Done  2 Pomodori", 1, true), out)
end)

t.test("edit replaces a local card's description from a file or standard input", function()
    local root, home = local_board()
    local a = prefix_of(
        (dev(root, home, { "board", "add", "Card", "--column", "icebox", "--description", "old" }))
    )
    assert(fs.write(root .. "/plan.md", "## Problem\nfrom a file\n\n"))
    local out, code = dev(root, home, { "board", "edit", a, "--file", root .. "/plan.md" })
    t.eq(code, 0, out)
    t.eq(out, "edited " .. a .. "\n")
    t.eq(document(file_of(home)).cards[1].description, "## Problem\nfrom a file")
    out, code = support.dev(
        root,
        { "board", "edit", a },
        { env = env_of(home), input = "from standard input\n" }
    )
    t.eq(code, 0, out)
    out = dev(root, home, { "board", "show", a })
    t.eq(out, a .. "  Icebox  Unsized  -  Card\n\nfrom standard input\n\nno comments\n")
end)

t.test(
    "stale does not mark a local needs:human card that only an agent has commented on",
    function()
        local root, home = local_board()
        local a = prefix_of((dev(root, home, { "board", "add", "First", "--column", "icebox" })))
        local out, code = dev(root, home, { "board", "label", a, "needs:human" })
        t.eq(code, 0, out)
        out, code = dev(root, home, { "board", "note", a, "still open" })
        t.eq(code, 0, out)
        out = dev(root, home, { "board", "stale" })
        t.ok(out:find("for the owner (needs:human):", 1, true), out)
        t.ok(not out:find("answered", 1, true), out)
    end
)

t.test("answer posts the quote and frees a local needs:human card", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "First", "--column", "icebox" })))
    local out, code = dev(root, home, { "board", "label", a, "needs:human" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "answer", a, "--choice", "2", "--quote", "go ahead" })
    t.eq(code, 0, out)
    t.eq(out, "answered " .. a .. " with choice 2\n")
    out = dev(root, home, { "board", "show", a })
    t.ok(out:find("Owner's answer, typed in this session: choice 2, quote: go ahead", 1, true), out)
    t.ok(not out:find("needs:human", 1, true), out)
    out, code = dev(root, home, { "board", "answer", a, "--choice", "2", "--quote", "again" })
    t.eq(code, 1, out)
end)

t.test("next --column backlog skips a needs:human card", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "First", "--column", "icebox" })))
    local b = prefix_of((dev(root, home, { "board", "add", "Second", "--column", "icebox" })))
    local out, code = dev(root, home, { "board", "label", a, "needs:human" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "next", "--column", "icebox" })
    t.eq(code, 0, out)
    t.ok(out:find(b, 1, true) and not out:find(a, 1, true), out)
    out = dev(root, home, { "board", "next", "--column", "backlog" })
    t.eq(out, "no cards in Backlog\n")
end)

t.test("next --column blocked returns the top unclaimed needs:lead card only", function()
    local root, home = local_board()
    local function blocked(name, label)
        local out, code = dev(root, home, {
            "board",
            "add",
            name,
            "--column",
            "blocked",
            "--size",
            "1",
            "--problem",
            "x",
            "--done-when",
            "a",
            "--label",
            label,
        })
        t.eq(code, 0, out)
        return prefix_of(out)
    end
    blocked("Plain", "docs")
    blocked("Human", "needs:human")
    local claimed = blocked("Claimed", "needs:lead")
    local free = blocked("Free", "needs:lead")
    local out, code = dev(root, home, { "board", "take", claimed })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "next", "--column", "blocked" })
    t.eq(code, 0, out)
    t.ok(out:find(free, 1, true) and out:find("Free", 1, true), out)
    out, code = dev(root, home, { "board", "label", free, "needs:human" })
    t.eq(code, 0, out)
    out = dev(root, home, { "board", "next", "--column", "blocked" })
    t.eq(out, "no cards in Blocked\n")
end)

t.test("rename sets a local card's title and refuses a blank one", function()
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
    t.eq(code, 0, out)
    t.eq(out, "renamed " .. a .. "\n")
    t.eq(document(file_of(home)).cards[1].name, "Better title")
    out, code = dev(root, home, { "board", "rename", a, " " })
    t.eq(code, 2, out)
    t.eq(document(file_of(home)).cards[1].name, "Better title")
end)

t.test("discard notes the reason, labels the card and moves it to Done", function()
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
    t.eq(code, 0, out)
    t.eq(out, "discarded " .. a .. "\n")
    local card = document(file_of(home)).cards[1]
    t.eq(card.comments[1].kind, "decision")
    t.eq(card.comments[1].body, "Not needed")
    t.eq(card.labels[1], "discarded")
    out = dev(root, home, { "board", "ls", "--column", "Done" })
    t.ok(out:find(a, 1, true), out)
end)

t.test("discard refuses a needs:human card and writes nothing", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        "blocked",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "a",
    })))
    local out, code = dev(root, home, { "board", "label", a, "needs:human" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "discard", a, "--reason", "Dropped" })
    t.eq(code, 1, out)
    t.ok(out:find("needs:human", 1, true), out)
    local card = document(file_of(home)).cards[1]
    t.eq(#(card.comments or {}), 0)
    t.eq(card.labels[1], "needs:human")
end)

t.test(
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
        local out, code = dev(root, home, { "board", "move", a, "done" })
        t.eq(code, 1, out)
        t.ok(out:find("1 of 1 outcomes are unticked (1. First works)", 1, true), out)
        out, code = dev(root, home, { "board", "outcome", a, "--tick", "1", "--as", "r/reviewer" })
        t.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, "done" })
        t.eq(code, 0, out)
        t.eq(out, "moved " .. a .. " to Done\n")
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
        t.eq(code, 0, out)
        t.eq(out, "discarded " .. b .. "\n")
        out = dev(root, home, { "board", "ls", "--column", "Done" })
        t.ok(out:find(b, 1, true), out)
    end
)

t.test("edit refuses empty text, a missing file and an extra word", function()
    local root, home = local_board()
    local a = prefix_of(
        (dev(root, home, { "board", "add", "Card", "--column", "icebox", "--description", "keep" }))
    )
    local out, code = support.dev(
        root,
        { "board", "edit", a },
        { env = env_of(home), input = " \n\n" }
    )
    t.eq(code, 2, out)
    out, code = dev(root, home, { "board", "edit", a, "--file", root .. "/missing.md" })
    t.eq(code, 2, out)
    out, code = dev(root, home, { "board", "edit", a, "extra" })
    t.eq(code, 2, out)
    t.eq(document(file_of(home)).cards[1].description, "keep")
end)

t.test("edit is refused under another process's claim fence", function()
    local root, home = local_board()
    local a = prefix_of(
        (dev(root, home, { "board", "add", "Card", "--column", "icebox", "--description", "keep" }))
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
    t.eq(code, 1, out)
    t.eq(document(file_of(home)).cards[1].description, "keep")
end)

t.test("show prints a local card's description and notes", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        "icebox",
        "--description",
        "why it matters",
    })))
    local out = dev(root, home, { "board", "show", a })
    t.eq(out, a .. "  Icebox  Unsized  -  Card\n\nwhy it matters\n\nno comments\n")
    dev(root, home, { "board", "note", a, "hello" })
    out = dev(root, home, { "board", "show", a })
    t.ok(out:find("\n\nwhy it matters\n\n%x+  agent  .-  hello\n$"), out)
end)

t.test("notes, edit and delete work on a local board and refuse another author's", function()
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
    t.eq(out, "noted " .. a .. "\n")
    dev(root, home, { "board", "note", a, "second" })
    out = dev(root, home, { "board", "notes", a })
    local first = assert(out:match("^(%x+)"))
    t.ok(out:find("agent  ", 1, true) and out:find("first thought", 1, true), out)
    local second = assert(out:match("\n(%x+)"))
    out = dev(root, home, { "board", "note", a, "--edit", first, "better", "words" })
    t.eq(out, "edited " .. a .. " " .. first .. "\n")
    out = dev(root, home, { "board", "note", a, "--delete", second })
    t.eq(out, "deleted " .. a .. " " .. second .. "\n")
    out = dev(root, home, { "board", "notes", a })
    t.ok(out:find("better words", 1, true) and not out:find("second", 1, true), out)
    local doc = document(file_of(home))
    doc.cards[1].comments[1].who = "human"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    out = dev(root, home, { "board", "note", a, "--edit", first, "x" })
    t.eq(out, "dev: that comment is not yours to change\n")
end)

t.test("note --kind and --as are stored on a local comment and notes prints them", function()
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
    t.ok(out:find("agent  decision  reviewer  ", 1, true) and out:find("ship it", 1, true), out)
    t.ok(out:find("agent  agent     -         ", 1, true), out)
    out = dev(root, home, { "board", "note", a, "--kind", "chatter", "x" })
    t.ok(out:find("unknown kind chatter", 1, true), out)
    local first = assert(dev(root, home, { "board", "notes", a }):match("^(%x+)"))
    dev(root, home, { "board", "note", a, "--edit", first, "changed" })
    out = dev(root, home, { "board", "notes", a })
    t.ok(out:find("decision  reviewer  ", 1, true) and out:find("changed", 1, true), out)
end)

t.test(
    "link stores blocked_by, blocks and related on a local board and keeps next honest",
    function()
        local root, home = local_board()
        local function add(name)
            return prefix_of((dev(root, home, {
                "board",
                "add",
                name,
                "--column",
                "ready",
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
        t.eq(out, "linked " .. first .. " blocked_by " .. second .. "\n")
        t.eq(code, 0)
        t.eq(dev(root, home, { "board", "link", first, "blocked_by", second }), out)
        out = dev(root, home, { "board", "link", third, "blocks", second })
        t.eq(out, "linked " .. third .. " blocks " .. second .. "\n")
        out = dev(root, home, { "board", "link", first, "related", third })
        t.eq(out, "linked " .. first .. " related " .. third .. "\n")
        local held = {}
        for _, card in ipairs(document(file_of(home)).cards) do
            held[card.id:sub(1, 8)] = card.links
        end
        t.eq(#held[first], 2)
        t.eq(held[first][1].kind, "blocked_by")
        t.eq(held[first][1].target_id:sub(1, 8), second)
        t.eq(held[first][2].kind, "related")
        t.eq(#held[second], 1)
        t.eq(held[second][1].kind, "blocked_by")
        t.eq(held[second][1].target_id:sub(1, 8), third)
        t.eq(held[third], nil)
        out = dev(root, home, { "board", "next" })
        t.ok(out:find("^" .. third), out)
        dev(root, home, { "board", "move", third, "done" })
        out = dev(root, home, { "board", "next" })
        t.ok(out:find("^" .. second), out)
        dev(root, home, { "board", "move", second, "done" })
        out = dev(root, home, { "board", "next" })
        t.ok(out:find("^" .. first), out)
    end
)

t.test("links lists a card's own links and the reverse side of links other cards hold", function()
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
    t.eq(code, 0, out)
    t.eq(out, "blocked_by  " .. b .. "  -\nrelated     " .. c .. "  -\n")
    out = dev(root, home, { "board", "links", b })
    t.eq(out, "blocks  " .. a .. "  -\n")
    out = dev(root, home, { "board", "links", c })
    t.eq(out, "related  " .. a .. "  -\n")
    dev(root, home, { "board", "link", c, "related", a })
    out = dev(root, home, { "board", "links", c })
    t.eq(out, "related  " .. a .. "  -\n")
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
    t.eq(out, "no links\n")
    out, code = dev(root, home, { "board", "links", "deadbeef" })
    t.eq(code, 1, out)
end)

t.test("unlink removes a link from the card that holds it, and refuses one it lacks", function()
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
    t.eq(code, 0, out)
    t.eq(out, "unlinked " .. a .. " related " .. c .. "\n")
    t.eq(dev(root, home, { "board", "links", a }), "blocked_by  " .. b .. "  -\n")
    out, code = dev(root, home, { "board", "unlink", c, "related", a })
    t.eq(code, 1, out)
    out, code = dev(root, home, { "board", "unlink", b, "blocks", a })
    t.eq(code, 0, out)
    t.eq(dev(root, home, { "board", "links", a }), "no links\n")
    out, code = dev(root, home, { "board", "unlink", a, "blocked_by", b })
    t.eq(code, 1, out)
    t.ok(out:find("the card holds no blocked_by link to " .. b, 1, true), out)
end)

t.test("link refuses itself, a cycle, another board and a bad kind on a local board", function()
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
    t.eq(code, 1, out)
    t.ok(out:find("itself", 1, true), out)
    dev(root, home, { "board", "link", a, "blocked_by", b })
    dev(root, home, { "board", "link", b, "blocked_by", c })
    out, code = dev(root, home, { "board", "link", c, "blocked_by", a })
    t.eq(code, 1, out)
    t.ok(out:find("wait on each other", 1, true), out)
    out, code = dev(root, home, { "board", "link", a, "blocks", c })
    t.eq(code, 1, out)
    out, code = dev(root, home, { "board", "link", a, "related", "other:" .. b })
    t.eq(code, 1, out)
    t.ok(out:find("links only its own cards", 1, true), out)
    out, code = dev(root, home, { "board", "link", a, "needs", b })
    t.eq(code, 2, out)
    local links = 0
    for _, card in ipairs(document(file_of(home)).cards) do
        links = links + #(card.links or {})
    end
    t.eq(links, 2)
end)

t.test("a local board refuses what the needs:human and epic rules forbid", function()
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
    t.eq(code, 1, out)
    t.ok(out:find("Blocked or Icebox", 1, true), out)
    dev(root, home, { "board", "move", card, "blocked" })
    out, code = dev(root, home, { "board", "label", card, "needs:human" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", card, "backlog" })
    t.eq(code, 1, out)
    t.ok(out:find("needs:human", 1, true), out)
    assert(fs.write(root .. "/plan.md", "new text\n"))
    out, code = dev(root, home, { "board", "edit", card, "--file", root .. "/plan.md" })
    t.eq(code, 1, out)
    t.ok(out:find("needs:human", 1, true), out)
    out, code = dev(root, home, { "board", "note", card, "still allowed" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "label", card, "--remove", "needs:human" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", card, "backlog" })
    t.eq(code, 0, out)
    dev(root, home, { "board", "link", child, "parent", epic })
    out, code = dev(root, home, { "board", "move", epic, "ready" })
    t.eq(code, 0, out)
end)

t.test("link parent sets one epic and show and links report it", function()
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
    local out, code = dev(root, home, { "board", "link", one, "parent", epic })
    t.eq(out, "linked " .. one .. " parent " .. epic .. "\n")
    t.eq(code, 0)
    t.eq(dev(root, home, { "board", "link", one, "parent", epic }), out)
    dev(root, home, { "board", "link", two, "parent", epic })
    out, code = dev(root, home, { "board", "link", one, "parent", other })
    t.eq(code, 1, out)
    t.ok(out:find("already has an epic", 1, true), out)
    out, code = dev(root, home, { "board", "link", other, "parent", one })
    t.eq(code, 0, out)
    out = dev(root, home, { "board", "show", one })
    t.ok(out:find("\nchildren: 0 of 1 done\n", 1, true), out)
    out, code = dev(root, home, { "board", "link", epic, "parent", other })
    t.eq(code, 1, out)
    t.ok(out:find("cycle of epics", 1, true), out)
    t.ok(out:find(epic, 1, true) and out:find(other, 1, true), out)
    out, code = dev(root, home, { "board", "link", epic, "parent", epic })
    t.eq(code, 1, out)
    out = dev(root, home, { "board", "show", one })
    t.ok(out:find("\nparent: " .. epic .. " Epic\n", 1, true), out)
    out = dev(root, home, { "board", "show", epic })
    t.ok(out:find("\nchildren: 0 of 2 done\n", 1, true), out)
    tick_first(root, home, one)
    out, code = dev(root, home, { "board", "move", one, "done" })
    t.eq(code, 1, out)
    t.ok(out:find("1 of 1 children are open", 1, true), out)
    tick_first(root, home, other)
    dev(root, home, { "board", "move", other, "done" })
    out, code = dev(root, home, { "board", "move", one, "done" })
    t.eq(code, 0, out)
    out = dev(root, home, { "board", "show", epic })
    t.ok(out:find("\nchildren: 1 of 2 done\n", 1, true), out)
    out = dev(root, home, { "board", "links", one })
    t.ok(out:find("parent", 1, true) and out:find(epic, 1, true), out)
    out = dev(root, home, { "board", "links", epic })
    t.ok(out:find("child", 1, true) and out:find(one, 1, true), out)
end)

t.test("stale counts the days a card sat in its column", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Old",
        "--column",
        "ready",
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
        "ready",
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
    t.ok(out:find(a .. "  Ready  ", 1, true) and out:find("Old", 1, true), out)
    t.ok(not out:find("New", 1, true), out)
end)

t.test("a local board keeps an unsized or red card out of Ready", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Loose",
        "--column",
        "icebox",
        "--description",
        V1,
        "--checks",
        "dev test",
    })))
    local out, code = dev(root, home, { "board", "move", a, "ready" })
    t.eq(code, 1)
    t.ok(out:find("dev board size", 1, true), out)
    out, code = dev(root, home, { "board", "move", a, "backlog" })
    t.eq(code, 1)
    t.ok(out:find("a size", 1, true), out)
    out, code = dev(root, home, { "board", "add", "Direct", "--column", "ready" })
    t.eq(code, 2)
    out, code = dev(root, home, { "board", "add", "Direct", "--problem", "x" })
    t.eq(code, 2)
    t.ok(out:find("a size", 1, true), out)
    dev(root, home, { "board", "size", a, "3+" })
    out, code = dev(root, home, { "board", "move", a, "ready" })
    t.eq(code, 1)
    t.ok(out:find("red", 1, true), out)
    dev(root, home, { "board", "size", a, "2" })
    out, code = dev(root, home, { "board", "move", a, "ready" })
    t.eq(code, 0, out)
    t.eq(dev(root, home, { "board", "stale" }), "no stale cards\n")
end)

t.test(
    "a local board scaffolds the v2 headings and keeps a card without them out of Ready",
    function()
        local root, home = local_board()
        local a = prefix_of((dev(root, home, {
            "board",
            "add",
            "Plain",
            "--column",
            "icebox",
            "--problem",
            "x",
            "--size",
            "1",
            "--checks",
            "dev test",
        })))
        t.eq(
            document(file_of(home)).cards[1].description,
            "## Problem\nx\n\n## Change\n\n## Out of scope\n"
        )
        local out, code = dev(root, home, { "board", "move", a, "ready" })
        t.eq(code, 1)
        t.ok(out:find("3 to 7 Done when outcomes", 1, true), out)
        out, code =
            dev(root, home, { "board", "add", "Direct", "--column", "ready", "--size", "1" })
        t.eq(code, 2)
        t.ok(out:find("card format v2", 1, true), out)
        local ice = prefix_of((dev(root, home, { "board", "add", "Loose", "--column", "icebox" })))
        out = dev(root, home, { "board", "show", ice })
        t.ok(out:find("no description", 1, true), out)
        local file = root .. "/v1.md"
        assert(fs.write(file, V1))
        out, code = dev(root, home, { "board", "edit", a, "--file", file })
        t.eq(code, 0, out)
        out, code = dev(root, home, { "board", "move", a, "ready" })
        t.eq(code, 0, out)
    end
)

t.test("a local board keeps --done-when outcomes on the card and shows them", function()
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
    t.eq(code, 0, out)
    local a = prefix_of(out)
    local outcomes = document(file_of(home)).cards[1].outcomes
    t.eq(#outcomes, 2)
    t.eq(outcomes[1].name, "A works")
    t.eq(outcomes[1].done, false)
    out = dev(root, home, { "board", "show", a })
    t.ok(out:find("done when:\n- [ ] A works\n- [ ] B works\n", 1, true), out)
    out = dev(root, home, { "board", "ls" })
    t.ok(out:find("0/2", 1, true), out)
end)

t.test("a local board appends, rewords, ticks and unticks outcomes by number", function()
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
    t.eq(code, 0, out)
    local a = prefix_of(out)
    out, code = dev(root, home, { "board", "outcome", a, "C works" })
    t.eq(out, "outcome " .. a .. " 3 added\n")
    out = dev(root, home, { "board", "outcome", a, "--tick", "2" })
    t.eq(out, "outcome " .. a .. " 2 ticked\n")
    out = dev(
        root,
        home,
        { "board", "outcome", a, "--rename", "1", "A holds", "--reason", "clearer" }
    )
    t.eq(out, "outcome " .. a .. " 1 reworded\n")
    out = dev(root, home, { "board", "show", a })
    t.ok(out:find("done when:\n- [ ] A holds\n- [x] B works\n- [ ] C works\n", 1, true), out)
    out = dev(root, home, { "board", "outcome", a, "--untick", "2" })
    t.eq(out, "outcome " .. a .. " 2 unticked\n")
    local rows = document(file_of(home)).cards[1].outcomes
    t.eq(#rows, 3)
    t.eq(rows[1].name, "A holds")
    t.eq(rows[2].done, false)
    t.eq(rows[2].name, "B works")
    out, code = dev(root, home, { "board", "outcome", a, "--tick", "4" })
    t.eq(code, 1)
    t.ok(out:find("the card has 3 outcomes, so there is no outcome 4", 1, true), out)
end)

t.test("a local board deletes an outcome, renumbers and keeps its text in a note", function()
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
    t.eq(code, 0, out)
    local a = prefix_of(out)
    out, code = dev(root, home, { "board", "outcome", a, "--delete", "2" })
    t.eq(code, 2, out)
    out, code =
        dev(root, home, { "board", "outcome", a, "--delete", "2", "--reason", "never possible" })
    t.eq(code, 0, out)
    t.eq(out, "outcome " .. a .. " 2 deleted\n")
    local card = document(file_of(home)).cards[1]
    t.eq(#card.outcomes, 2)
    t.eq(card.outcomes[1].name, "A works")
    t.eq(card.outcomes[2].name, "C works")
    local note = card.comments[#card.comments]
    t.eq(note.kind, "decision")
    t.eq(note.body, "Deleted outcome 2: B works Reason: never possible")
end)

t.test("a local board converts a v1 checklist into outcomes and ticks", function()
    local root, home = local_board()
    local v1 =
        "## Problem\nP\n\n## Change\nC\n\n## Done when\n- [ ] A works\n- [x] B works\n- [ ] C works\n\n## Out of scope\nNone\n"
    local out, code = dev(root, home, { "board", "add", "Old", "--description", v1, "--size", "1" })
    t.eq(code, 0, out)
    local a = prefix_of(out)
    out, code = dev(root, home, { "board", "outcome", a, "--convert" })
    t.eq(code, 0, out)
    t.eq(out, "outcome " .. a .. " converted 3 outcomes\n")
    local card = document(file_of(home)).cards[1]
    t.eq(#card.outcomes, 3)
    t.eq(card.outcomes[1].name, "A works")
    t.eq(card.outcomes[1].done, false)
    t.eq(card.outcomes[2].done, true)
    t.eq(card.outcomes[3].done, false)
    t.ok(not card.description:find("Done when", 1, true), card.description)
    t.ok(
        card.description:find("## Problem\nP\n\n## Change\nC\n\n## Out of scope\nNone", 1, true),
        card.description
    )
    out, code = dev(root, home, { "board", "outcome", a, "--convert" })
    t.eq(code, 0, out)
    t.eq(out, "outcome " .. a .. " left alone: it already has outcomes\n")
    t.eq(#document(file_of(home)).cards[1].outcomes, 3)
end)

t.test("outcome --convert leaves a card with no checklist alone", function()
    local root, home = local_board()
    local a = prefix_of(
        (dev(root, home, { "board", "add", "Plain", "--column", "icebox", "--problem", "x" }))
    )
    local out, code = dev(root, home, { "board", "outcome", a, "--convert" })
    t.eq(code, 0, out)
    t.eq(out, "outcome " .. a .. " left alone: it has no Done when checklist\n")
    out, code = dev(root, home, { "board", "outcome", a, "--convert", "extra" })
    t.eq(code, 2)
end)

t.test("a local board ticks an outcome while this machine holds the claim", function()
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
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "outcome", a, "--tick", "1" })
    t.eq(code, 2, out)
    t.eq(document(file_of(home)).cards[1].outcomes[1].done, false)
    out, code = dev(root, home, { "board", "outcome", a, "--tick", "1", "--as", "r/reviewer" })
    t.eq(code, 0, out)
    t.eq(document(file_of(home)).cards[1].outcomes[1].done, true)
end)

local function card_named(doc, name)
    for _, card in ipairs(doc.cards) do
        if card.name == name then
            return card
        end
    end
end

t.test(
    "take --as and move into progress name the holder, and an epic is claimed like any card",
    function()
        local root, home = local_board()
        local function ready(name)
            return prefix_of((dev(root, home, {
                "board",
                "add",
                name,
                "--column",
                "ready",
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
        t.eq(code, 0, out)
        t.eq(card_named(document(file_of(home)), "Alpha").claim.claimant, "r/one")
        _, code = dev(root, home, { "board", "take", b, "--as", "bad name" })
        t.eq(code, 2)
        out, code = dev(root, home, { "board", "move", b, "progress" }, { DEV_AGENT = "r/two" })
        t.eq(code, 0, out)
        t.eq(card_named(document(file_of(home)), "Beta").claim.claimant, "r/two")
        out = dev(root, home, { "board", "ls" })
        t.ok(out:find("r/two", 1, true), out)
        dev(root, home, { "board", "link", c, "parent", a })
        out, code = dev(root, home, { "board", "move", a, "progress" }, { DEV_AGENT = "r/three" })
        t.eq(code, 0, out)
        t.eq(card_named(document(file_of(home)), "Alpha").claim.claimant, "r/one")
        dev(root, home, { "board", "release", a })
        out, code = dev(root, home, { "board", "move", a, "progress" }, { DEV_AGENT = "r/three" })
        t.eq(code, 0, out)
        t.eq(card_named(document(file_of(home)), "Alpha").claim.claimant, "r/three")
    end
)

t.test("move out of progress releases the claim and warns about nothing", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        "ready",
        "--size",
        "1",
        "--description",
        V1,
        "--checks",
        "dev test",
    })))
    dev(root, home, { "board", "take", a })
    t.ok(document(file_of(home)).cards[1].claim ~= nil, "claim held")
    dev(root, home, { "board", "note", a, "built it, tried it, learned it" })
    local out, code = dev(root, home, { "board", "move", a, "review" })
    t.eq(code, 0, out)
    t.eq(out, "moved " .. a .. " to Review\n")
    t.eq(document(file_of(home)).cards[1].claim, nil)
end)

t.test("move out of progress waits for a note of what was built, tried and learned", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        "ready",
        "--size",
        "1",
        "--description",
        V1,
        "--checks",
        "dev test",
    })))
    dev(root, home, { "board", "take", a })
    dev(root, home, { "board", "move", a, "progress" })
    for _, column in ipairs({ "review", "ready", "blocked" }) do
        local out, code = dev(root, home, { "board", "move", a, column })
        t.eq(code, 1, out)
        t.ok(out:find("built, tried and learned", 1, true), out)
        t.ok(document(file_of(home)).cards[1].claim ~= nil, "claim kept")
    end
    dev(root, home, { "board", "note", a, "--kind", "decision", "ruled" })
    local out, code = dev(root, home, { "board", "move", a, "review" })
    t.eq(code, 1, out)
    out, code = dev(root, home, { "board", "note", a, "built, tried, learned" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", a, "review" })
    t.eq(code, 0, out)
    t.eq(document(file_of(home)).cards[1].claim, nil)
end)

t.test("a second claim needs a fresh note of what was built, tried and learned", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        "ready",
        "--size",
        "1",
        "--description",
        V1,
        "--checks",
        "dev test",
    })))
    dev(root, home, { "board", "take", a })
    dev(root, home, { "board", "move", a, "progress" })
    dev(root, home, { "board", "note", a, "built, tried, learned" })
    local out, code = dev(root, home, { "board", "move", a, "ready" })
    t.eq(code, 0, out)
    dev(root, home, { "board", "take", a })
    dev(root, home, { "board", "move", a, "progress" })
    out, code = dev(root, home, { "board", "move", a, "review" })
    t.eq(code, 1, out)
    t.ok(out:find("built, tried and learned", 1, true), out)
end)

t.test("take holds a claim with an expiry and no loop, and release gives it up", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        "ready",
        "--size",
        "1",
        "--description",
        V1,
        "--checks",
        "dev test",
    })))
    local out, code = dev(root, home, { "board", "take", a })
    t.eq(code, 0, out)
    t.eq(out:find("took " .. a .. ", fence 1, held for 50m\n\n", 1, true), 1, out)
    local doc = document(file_of(home))
    t.eq(doc.cards[1].claim.fence, 1)
    t.ok(doc.cards[1].claim.expires_at > os.date("!%Y-%m-%dT%H:%M:%SZ"), "expiry in the future")
    out = dev(root, home, { "board", "ls" })
    t.ok(out:find("dev@", 1, true), out)
    out = dev(root, home, { "board", "next" })
    t.eq(out, "no ready cards\n")
    out, code = dev(root, home, { "board", "take", a }, { CLAUDE_SESSION_ID = "other" })
    t.eq(code, 1)
    t.ok(out:find("is claimed by dev@", 1, true), out)
    out = dev(root, home, { "board", "take", a })
    t.eq(out:find("took " .. a .. ", fence 1, held for 50m\n\n", 1, true), 1, out)
    out = dev(root, home, { "board", "release", a })
    t.eq(out, "released " .. a .. "\n")
    out = dev(root, home, { "board", "next" })
    t.ok(out:find("Card", 1, true), out)
    out = dev(root, home, { "board", "take", a }, { CLAUDE_SESSION_ID = "other" })
    t.eq(out:find("took " .. a .. ", fence 2, held for 50m\n\n", 1, true), 1, out)
end)

t.test("a stale fence is refused once another process holds the claim", function()
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
    t.eq(code, 1)
    t.ok(out:find("is held by dev@", 1, true) and out:find("fence 9", 1, true), out)
end)

t.test("an expired claim does not block the card", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, {
        "board",
        "add",
        "Card",
        "--column",
        "ready",
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
    t.ok(out:find("Card", 1, true), out)
    out = dev(root, home, { "board", "note", a, "still works" })
    t.eq(out, "noted " .. a .. "\n")
end)

t.test("a tracked path keeps the board in the project, readable by everyone", function()
    local root, home = local_board('[board]\nbackend = "local"\npath = ".dev/board.json"\n')
    local out = dev(
        root,
        home,
        { "board", "add", "Tracked", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    prefix_of(out)
    t.ok(fs.exists(root .. "/.dev/board.json"))
    t.eq(fs.exists(home .. "/state/dev/boards/mine.json"), false)
    t.eq(document(root .. "/.dev/board.json").cards[1].name, "Tracked")
    t.ok(mode(root .. "/.dev/board.json") ~= "600", "not private")
    local text = assert(fs.read(root .. "/.dev/board.json"))
    t.ok(select(2, text:gsub("\n", "")) > 4, "one line per card")
end)

t.test("a path outside the project, or on a pomb board, is refused", function()
    for _, path in ipairs({ "../board.json", "/etc/board.json", "a//b.json", ".dev/../x.json" }) do
        local root, home = setup('[board]\nbackend = "local"\npath = "' .. path .. '"\n')
        local out, code = dev(root, home, { "board", "ls" })
        t.eq(code, 1, path)
        t.ok(out:find("[board] path must be a relative path", 1, true), out)
    end
    local root, home = setup('[board]\nbackend = "pomb"\npath = ".dev/board.json"\n')
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find('path only applies to backend = "local"', 1, true), out)
end)

t.test("a local board's name has to make a file name unless a path is set", function()
    local root, home = setup('[board]\nbackend = "local"\nname = "a/b"\n')
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("name must be letters, digits", 1, true), out)
end)

t.test("init refuses --admin on a local board and a different --name", function()
    local root, home = setup('[board]\nbackend = "local"\nname = "mine"\n')
    local out, code = dev(root, home, { "board", "init", "--admin" })
    t.eq(code, 2, out)
    out, code = dev(root, home, { "board", "init", "--name", "other" })
    t.eq(code, 2, out)
end)

t.test("sync on a local board says there is nothing to sync", function()
    local root, home = local_board()
    local out, code = dev(root, home, { "board", "sync" })
    t.eq(code, 1)
    t.eq(out, "dev: a local board has nothing to sync\n")
end)

t.test("wait on a local board says there is nothing to wait on", function()
    local root, home = local_board()
    local out, code = dev(root, home, { "board", "wait", "--for", "ready" })
    t.eq(code, 1)
    t.eq(out, "dev: a local board has nothing to wait on\n")
end)

t.test("six processes writing at once lose no card", function()
    local root, home = local_board()
    local script = string.format(
        'for i in 1 2 3 4 5 6; do luajit %s board add "card $i" --problem x --size 1 --done-when a & done; wait',
        devos.quote(MAIN)
    )
    local out, code = devos.capture({ "sh", "-c", script }, {
        cwd = root,
        stderr = "stdout",
        env = {
            HOME = home,
            XDG_STATE_HOME = home .. "/state",
            PATH = root .. "/bin:" .. os.getenv("PATH"),
            DEV_SELF = REPO .. "/dotfiles/bin/.local/bin/dev",
        },
    })
    t.eq(code, 0, out)
    local doc = document(file_of(home))
    t.eq(#doc.cards, 6)
    local ids = {}
    for _, card in ipairs(doc.cards) do
        ids[card.id] = true
    end
    local count = 0
    for _ in pairs(ids) do
        count = count + 1
    end
    t.eq(count, 6)
    t.eq(fs.list(home .. "/state/dev/boards"), { "mine.json", "mine.json.lock" })
end)

local BOARDS = '[{"id":"board-1","name":"dotfiles","archived":false}]'
local DETAIL = '{"id":"board-1","name":"dotfiles","columns":['
    .. '{"id":"col-backlog","name":"Backlog"},{"id":"col-ready","name":"Ready"},'
    .. '{"id":"col-review","name":"Review"},{"id":"col-done","name":"Done"}]}'
local COLORS = '[{"id":"yellow-id","value":"yellow","label":"1 Pomodoro"},'
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
status=200
case "$last" in
*/api/boards) body=$(cat "$ROOT/boards.json") ;;
*/api/boards/board-1) body=$(cat "$ROOT/detail.json") ;;
*/colors) body=$(cat "$ROOT/colors.json") ;;
*/fields) body=$(cat "$ROOT/fields.json") ;;
*/export-data) body=$(cat "$ROOT/export.json") ;;
*/api/tasks/aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa) body='{"id":"aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa","parent":{"id":"bbbbbbbb-1111-4bbb-8bbb-bbbbbbbbbbbb","name":"Epic"},"children_done":1,"children_total":3}' ;;
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
    assert(devos.run({ "chmod", "755", root .. "/bin/curl" }) == 0, "chmod failed")
    assert(
        fs.write(
            root .. "/bin/pass",
            "#!/bin/sh\n" .. (opts.locked and "exit 1\n" or ('echo "' .. TOKEN .. '"\n'))
        )
    )
    assert(devos.run({ "chmod", "755", root .. "/bin/pass" }) == 0, "chmod failed")
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

t.test("writes while Pomb is unreachable are queued and the queue is private", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    t.eq(out, QUEUED)
    t.eq(code, 0)
    out = pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "kept", "words" })
    t.eq(out, QUEUED)
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
    t.eq(out, QUEUED)
    out = pomb_dev(root, home, { "board", "size", ID_B:sub(1, 8), "3" })
    t.eq(out, QUEUED)
    out = pomb_dev(root, home, { "board", "label", ID_B:sub(1, 8), "+x" })
    t.eq(out, QUEUED)
    local entries = document(queue_path(home))
    t.eq(#entries, 5)
    t.eq(entries[1].sub, "move")
    t.eq(entries[1].args, { ID_A:sub(1, 8), "review" })
    t.eq(entries[2].args, { ID_A:sub(1, 8), "kept", "words" })
    t.eq(entries[3].sub, "add")
    t.eq(mode(queue_path(home)), "600")
    t.eq(mode(home .. "/state/dev/boards"), "700")
    t.ok(not assert(fs.read(queue_path(home))):find(TOKEN, 1, true), "no token in the queue")
    t.eq(calls(root), "")
end)

t.test("a queued note keeps its kind and role", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local args = { ID_A:sub(1, 8), "--kind", "decision", "--as", "reviewer", "kept" }
    t.eq(pomb_dev(root, home, { "board", "note", unpack(args) }), QUEUED)
    t.eq(document(queue_path(home))[1].args, args)
end)

t.test("a queued discard replays its move without the outcome check", function()
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
    assert(devos.run({ "chmod", "755", root .. "/bin/curl" }) == 0, "chmod failed")
    local out, code =
        pomb_dev(root, home, { "board", "discard", ID_A:sub(1, 8), "--reason", "Dropped" })
    t.eq(code, 0, out)
    t.eq(out, QUEUED)
    assert(fs.write(root .. "/bin/curl", CURL))
    assert(devos.run({ "chmod", "755", root .. "/bin/curl" }) == 0, "chmod failed")
    out, code = pomb_dev(root, home, { "board", "sync" })
    t.eq(code, 0, out)
    t.ok(out:find("synced discard_move aaaaaaaa", 1, true), out)
    t.ok(calls(root):find("/move", 1, true), calls(root))
end)

t.test("a move to Done is refused and not queued while Pomb is unreachable", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "done" })
    t.eq(code, 1, out)
    t.ok(out:find("board unavailable", 1, true), out)
    t.eq(fs.exists(queue_path(home)), false)
end)

t.test("after a gateway error only a change that is safe to repeat is queued", function()
    local root, home = pomb()
    assert(fs.write(root .. "/gateway", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    t.eq(out, QUEUED)
    t.eq(code, 0)
    out, code = pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "once" })
    t.eq(code, 1, out)
    out, code = pomb_dev(
        root,
        home,
        { "board", "add", "Once", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    t.eq(code, 1, out)
    t.eq(#document(queue_path(home)), 1)
end)

t.test("a hand-edited board file keeps its other keys and gets its name back", function()
    local root, home = local_board()
    local doc = document(file_of(home))
    doc.name = nil
    doc.note = "kept"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    dev(root, home, { "board", "add", "One", "--problem", "x", "--size", "1", "--done-when", "a" })
    doc = document(file_of(home))
    t.eq(doc.note, "kept")
    t.eq(doc.name, "mine")
end)

t.test("a tracked board leaves no lock file in the project", function()
    local root, home = local_board('[board]\nbackend = "local"\npath = ".dev/board.json"\n')
    dev(root, home, { "board", "add", "One", "--problem", "x", "--size", "1", "--done-when", "a" })
    t.eq(fs.list(root .. "/.dev"), { "board.json", "config.toml" })
end)

t.test("show reads the epic and the children of a card from the task view", function()
    local root, home = pomb()
    local out, code = pomb_dev(root, home, { "board", "show", ID_A:sub(1, 8) })
    t.eq(code, 0, out)
    t.ok(out:find("\nparent: bbbbbbbb Epic\nchildren: 1 of 3 done\n\n", 1, true), out)
end)

t.test("a locked pass queues a write the same way", function()
    local root, home = pomb({ locked = true })
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    t.eq(out, QUEUED)
    t.eq(code, 0)
    t.eq(#document(queue_path(home)), 1)
end)

t.test("reads, usage errors and refusals are not queued", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("cannot reach", 1, true), out)
    out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "nowhere" })
    t.eq(code, 2, out)
    out, code = pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "--edit", "aaaaaaaa", "x" })
    t.eq(code, 1, out)
    out, code = pomb_dev(root, home, { "board", "take", ID_A:sub(1, 8) })
    t.eq(code, 1, out)
    t.eq(fs.exists(queue_path(home)), false)
end)

t.test("link posts to the task and queues while Pomb is unreachable", function()
    local root, home = pomb()
    local out, code =
        pomb_dev(root, home, { "board", "link", ID_A:sub(1, 8), "blocks", ID_B:sub(1, 8) })
    t.eq(code, 0, out)
    t.eq(out, "linked aaaaaaaa blocks bbbbbbbb\n")
    t.ok(calls(root):find("/api/tasks/" .. ID_A .. "/links", 1, true), calls(root))
    t.eq(fs.read(root .. "/bodies"), '{"kind":"blocks","target_id":"' .. ID_B .. '"}\n')
    assert(fs.write(root .. "/down", ""))
    out, code = pomb_dev(root, home, { "board", "link", ID_B:sub(1, 8), "related", ID_A:sub(1, 8) })
    t.eq(out, QUEUED)
    t.eq(code, 0)
    local entries = document(queue_path(home))
    t.eq(#entries, 1)
    t.eq(entries[1].sub, "link")
    t.eq(entries[1].args, { ID_B:sub(1, 8), "related", ID_A:sub(1, 8) })
    assert(fs.remove(root .. "/down"))
    out = pomb_dev(root, home, { "board", "sync" })
    t.eq(out, "synced link bbbbbbbb\nsynced\n")
    t.ok(calls(root):find("/api/tasks/" .. ID_B .. "/links", 1, true), calls(root))
end)

local WAITING = "## Problem\nwaiting plan\n\n## Change\n- x\n\n## Out of scope\nnone"

t.test("edit patches the task, and a queued edit replays with its text", function()
    local root, home = pomb()
    assert(
        fs.write(
            root .. "/plan.md",
            "## Problem\nnew plan\n\n## Change\n- x\n\n## Out of scope\nnone\n"
        )
    )
    local out, code =
        pomb_dev(root, home, { "board", "edit", ID_A:sub(1, 8), "--file", root .. "/plan.md" })
    t.eq(code, 0, out)
    t.eq(out, "edited aaaaaaaa\n")
    t.ok(calls(root):find("/api/tasks/" .. ID_A .. "\n", 1, true), calls(root))
    t.eq(
        fs.read(root .. "/bodies"),
        '{"description":"## Problem\\nnew plan\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone"}\n'
    )
    assert(fs.write(root .. "/down", ""))
    out, code = support.dev(root, { "board", "edit", ID_B:sub(1, 8) }, {
        env = env_of(home, { ROOT = root }),
        input = WAITING .. "\n",
    })
    t.eq(out, QUEUED)
    t.eq(code, 0)
    local entries = document(queue_path(home))
    t.eq(#entries, 1)
    t.eq(entries[1].sub, "edit")
    t.eq(entries[1].args, { ID_B:sub(1, 8), WAITING })
    assert(fs.remove(root .. "/down"))
    out = pomb_dev(root, home, { "board", "sync" })
    t.eq(out, "synced edit bbbbbbbb\nsynced\n")
    t.ok(calls(root):find("/api/tasks/" .. ID_B .. "\n", 1, true), calls(root))
end)

t.test("a local board replaces a card's checks and then lets it enter Ready", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Bare", "--column", "icebox", "--problem", "x", "--size", "1" }
            )
        )
    )
    local file = root .. "/v1.md"
    assert(fs.write(file, V1))
    assert(dev(root, home, { "board", "edit", a, "--file", file }))
    local out, code = dev(root, home, { "board", "move", a, "ready" })
    t.eq(code, 1)
    out, code = dev(root, home, { "board", "checks", a, "dev lint", "dev test" })
    t.eq(code, 0, out)
    t.eq(out, "set checks " .. a .. ", 2 rows\n")
    t.eq(document(file_of(home)).cards[1].checks, { "dev lint", "dev test" })
    out = dev(root, home, { "board", "show", a })
    t.ok(out:find("\n\nchecks:\n- dev lint\n- dev test\n\n", 1, true), out)
    out, code = dev(root, home, { "board", "move", a, "ready" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "checks", a, "dev fmt" })
    t.eq(code, 0, out)
    t.eq(document(file_of(home)).cards[1].checks, { "dev fmt" })
    out, code = dev(root, home, { "board", "checks", a })
    t.eq(code, 2)
    t.eq(document(file_of(home)).cards[1].checks, { "dev fmt" })
end)

t.test("a queued checks replaces the rows when Pomb answers again", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, { "board", "checks", ID_A:sub(1, 8), "dev lint" })
    t.eq(out, QUEUED)
    t.eq(code, 0)
    local entries = document(queue_path(home))
    t.eq(entries[1].sub, "checks")
    t.eq(entries[1].args, { ID_A:sub(1, 8), "dev lint" })
    assert(fs.remove(root .. "/down"))
    out = pomb_dev(root, home, { "board", "sync" })
    t.eq(out, "synced checks aaaaaaaa\nsynced\n")
    t.ok(fs.read(root .. "/bodies"):find('"dev.checks":[{"run":"dev lint"}]', 1, true))
end)

t.test("a local board stores a card's allow, tests and files and shows them", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Bare", "--column", "icebox", "--problem", "x", "--size", "1" }
            )
        )
    )
    local out, code = dev(root, home, { "board", "allow", a, "ci-edits", "test-edits" })
    t.eq(code, 0, out)
    t.eq(out, "set allow " .. a .. ", ci-edits test-edits\n")
    t.eq(document(file_of(home)).cards[1].allow, { "ci-edits", "test-edits" })
    out, code = dev(root, home, { "board", "tests", a, "one", "tests::two" })
    t.eq(code, 0, out)
    t.eq(document(file_of(home)).cards[1].tests, "one\ntests::two")
    out, code = dev(root, home, { "board", "files", a, "src/a.rs" })
    t.eq(code, 0, out)
    t.eq(document(file_of(home)).cards[1].files, "src/a.rs")
    out = dev(root, home, { "board", "show", a })
    t.ok(
        out:find(
            "allow:\n- ci-edits\n- test-edits\n\ntests:\n- one\n- tests::two\n\nfiles:\n- src/a.rs\n\n",
            1,
            true
        ),
        out
    )
    out, code = dev(root, home, { "board", "allow", a, "none" })
    t.eq(code, 0, out)
    t.eq(out, "cleared allow " .. a .. "\n")
    t.eq(document(file_of(home)).cards[1].allow, nil)
    out, code = dev(root, home, { "board", "allow", a, "everything" })
    t.eq(code, 2)
    t.eq(document(file_of(home)).cards[1].allow, nil)
end)

t.test("queued allow, tests and files replace the fields when Pomb answers again", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local id = ID_A:sub(1, 8)
    local out, code = pomb_dev(root, home, { "board", "allow", id, "test-edits" })
    t.eq(out, QUEUED)
    t.eq(code, 0)
    out = pomb_dev(root, home, { "board", "tests", id, "one" })
    t.eq(out, QUEUED)
    out = pomb_dev(root, home, { "board", "files", id, "src/a.rs" })
    t.eq(out, QUEUED)
    local entries = document(queue_path(home))
    t.eq(#entries, 3)
    t.eq(entries[1].sub, "allow")
    t.eq(entries[1].args, { id, "test-edits" })
    assert(fs.remove(root .. "/down"))
    out = pomb_dev(root, home, { "board", "sync" })
    t.eq(out, "synced allow aaaaaaaa\nsynced tests aaaaaaaa\nsynced files aaaaaaaa\nsynced\n")
    local bodies = fs.read(root .. "/bodies")
    t.ok(bodies:find('"dev.allow":["test-edits"]', 1, true), bodies)
    t.ok(bodies:find('"dev.tests":"one"', 1, true), bodies)
    t.ok(bodies:find('"dev.files":"src/a.rs"', 1, true), bodies)
end)

t.test("a gateway error still queues an edit, which is safe to repeat", function()
    local root, home = pomb()
    assert(fs.write(root .. "/plan.md", "again\n"))
    assert(fs.write(root .. "/gateway", ""))
    local out, code =
        pomb_dev(root, home, { "board", "edit", ID_A:sub(1, 8), "--file", root .. "/plan.md" })
    t.eq(out, QUEUED)
    t.eq(code, 0)
end)

t.test("sync replays the queue in order and empties it", function()
    local root, home = pomb()
    assert(fs.write(root .. "/export.json", PLANNED_EXPORT))
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    pomb_dev(root, home, { "board", "note", ID_B:sub(1, 8), "hello" })
    pomb_dev(
        root,
        home,
        { "board", "add", "Later", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    assert(fs.remove(root .. "/down"))
    local out, code = pomb_dev(root, home, { "board", "sync" })
    t.eq(code, 0, out)
    t.eq(out, "synced move aaaaaaaa\nsynced note bbbbbbbb\nsynced add Later\nsynced\n")
    t.eq(fs.exists(queue_path(home)), false)
    local log = calls(root)
    local move = assert(log:find("POST [^\n]*/move", 1))
    local note = assert(log:find("POST [^\n]*/comments", 1))
    local add = assert(log:find("POST [^\n]*/api/tasks\n", 1))
    t.ok(move < note and note < add, log)
    out = pomb_dev(root, home, { "board", "sync" })
    t.eq(out, "nothing queued\n")
end)

t.test("a replay Pomb refuses is reported and dropped, the rest still go", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", "deadbeef", "review" })
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "still goes" })
    assert(fs.remove(root .. "/down"))
    local out, code = pomb_dev(root, home, { "board", "sync" })
    t.eq(code, 0, out)
    t.ok(out:find("dropped move deadbeef: no card starts with deadbeef", 1, true), out)
    t.ok(out:find("synced note aaaaaaaa", 1, true), out)
    t.eq(fs.exists(queue_path(home)), false)
end)

t.test("a sync that finds Pomb still down keeps every change queued", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "second" })
    local out, code = pomb_dev(root, home, { "board", "sync" })
    t.eq(code, 1)
    t.eq(out, "Pomb is still unreachable, move aaaaaaaa stays queued\nqueued: 2\n")
    t.eq(#document(queue_path(home)), 2)
end)

t.test("any pomb command syncs a waiting queue first", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "waiting" })
    assert(fs.remove(root .. "/down"))
    local out, code = pomb_dev(root, home, { "board", "ls" })
    t.eq(code, 0, out)
    t.ok(out:find("synced note aaaaaaaa", 1, true), out)
    t.ok(out:find("First", 1, true), out)
    t.eq(fs.exists(queue_path(home)), false)
    local log = calls(root)
    t.ok(log:find("POST [^\n]*/comments\nGET [^\n]*/export%-data\n$"), log)
end)

t.test("status syncs a waiting queue and reports what is left", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "waiting" })
    local out = pomb_dev(root, home, { "board", "status" })
    t.eq(
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

t.test("sync on a malformed queue is an error that names the line and keeps the file", function()
    local root, home = bad_queue('[{"sub":"move",\n"args":["aaaaaaaa" "review"]}]\n')
    local out, code = pomb_dev(root, home, { "board", "sync" })
    t.eq(code, 1)
    t.ok(out:find(queue_path(home) .. ":2: ", 1, true), out)
    t.ok(out:find("left in place", 1, true), out)
    t.ok(not out:find("nothing queued", 1, true), out)
    t.ok(assert(fs.read(queue_path(home))):find('"review"]}]', 1, true))
    t.eq(calls(root), "")
end)

t.test("a queue that is not a list of commands is malformed", function()
    local root, home = bad_queue('{"sub":"move"}\n')
    local out, code = pomb_dev(root, home, { "board", "sync" })
    t.eq(code, 1)
    t.ok(out:find(":1: not a list of queued commands", 1, true), out)
    root, home = bad_queue('[{"sub":"move","args":["a"]},"oops"]\n')
    out, code = pomb_dev(root, home, { "board", "sync" })
    t.eq(code, 1)
    t.ok(out:find("entry 2 is not a queued command", 1, true), out)
end)

t.test("another command warns about a malformed queue, runs and keeps the file", function()
    local root, home = bad_queue("not json")
    local out, code = pomb_dev(root, home, { "board", "ls" })
    t.eq(code, 0, out)
    t.ok(out:find(queue_path(home) .. ":1: ", 1, true), out)
    t.ok(out:find("First", 1, true), out)
    t.eq(assert(fs.read(queue_path(home))), "not json")
    out, code = pomb_dev(root, home, { "board", "status" })
    t.eq(code, 0, out)
    t.ok(out:find("left in place", 1, true), out)
    t.eq(assert(fs.read(queue_path(home))), "not json")
end)

t.test("a write that cannot reach Pomb does not overwrite a malformed queue", function()
    local root, home = bad_queue("not json")
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    t.eq(code, 1, out)
    t.ok(out:find("could not be queued", 1, true), out)
    t.eq(assert(fs.read(queue_path(home))), "not json")
end)

t.test("a local board never queues", function()
    local root, home = local_board()
    dev(root, home, { "board", "add", "One", "--problem", "x", "--size", "1", "--done-when", "a" })
    t.eq(fs.exists(home .. "/state/dev/boards/mine.queue"), false)
end)

t.test("a local board stores checks on the card and show lists them", function()
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
    t.eq(code, 0, out)
    local a = prefix_of(out)
    t.eq(document(file_of(home)).cards[1].checks, { "dev lint", "dev test" })
    out = dev(root, home, { "board", "show", a })
    t.ok(out:find("\n\nchecks:\n- dev lint\n- dev test\n\n", 1, true), out)
end)

t.test("a local board keeps a card with no checks row out of Ready", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Bare", "--column", "icebox", "--problem", "x", "--size", "1" }
            )
        )
    )
    local file = root .. "/v1.md"
    assert(fs.write(file, V1))
    assert(dev(root, home, { "board", "edit", a, "--file", file }))
    local out, code = dev(root, home, { "board", "move", a, "ready" })
    t.eq(code, 1)
    t.ok(out:find("has no checks row", 1, true), out)
    out, code = dev(root, home, {
        "board",
        "add",
        "Direct",
        "--column",
        "ready",
        "--size",
        "1",
        "--description",
        V1,
    })
    t.eq(code, 2)
    t.ok(out:find("--checks", 1, true), out)
    out = dev(root, home, { "board", "init" })
    t.eq(out:find("checks field", 1, true), nil)
end)

t.test("wait on a local board answers at once that there is nothing to wait on", function()
    local backend = require("dev.board.localboard").new({ name = "mine" })
    local got, message = backend:wait("1", { "task_added" }, 5)
    t.eq(got, nil)
    t.eq(message, "a local board has nothing to wait on")
end)

t.test("a local board with renamed columns works through the project map", function()
    local root, home = local_board(
        '[board]\nbackend = "local"\nname = "mine"\n\n[board.columns]\nbacklog = "Inbox"\nready = "Next"\nprogress = "Doing"\ndone = "Shipped"\n'
    )
    local doc = document(file_of(home))
    local names = {}
    for _, column in ipairs(doc.columns) do
        names[#names + 1] = column.name
    end
    t.eq(names, {
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
    t.eq(doc.columns[9].is_done, true)
    local out = dev(
        root,
        home,
        { "board", "add", "One", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    t.ok(out:find(" Inbox\n", 1, true), out)
    local id = prefix_of(out)
    tick_first(root, home, id)
    out = dev(root, home, { "board", "move", id, "done" })
    t.eq(out, "moved " .. id .. " to Shipped\n")
    t.eq(dev(root, home, { "board", "ls" }), "no cards\n")
    out = dev(root, home, { "board", "ls", "--column", "shipped" })
    t.ok(out:find("Shipped", 1, true), out)
    out = dev(root, home, { "board", "move", id, "ready" })
    t.ok(
        out:find(" to Next\n", 1, true)
            or out:find("cannot enter Next", 1, true)
            or out:find("cannot enter Ready", 1, true),
        out
    )
end)

t.test("a local board with two finished columns hides both and discards into the first", function()
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
    t.eq(dev(root, home, { "board", "move", first, "done" }), "moved " .. first .. " to Done\n")
    t.eq(
        dev(root, home, { "board", "move", second, "archive" }),
        "moved " .. second .. " to Archive\n"
    )
    t.eq(dev(root, home, { "board", "ls" }), "no cards\n")
    local third = prefix_of(
        dev(
            root,
            home,
            { "board", "add", "Three", "--problem", "x", "--size", "1", "--done-when", "a" }
        )
    )
    local out = dev(root, home, { "board", "discard", third })
    t.eq(out, "discarded " .. third .. "\n")
    out = dev(root, home, { "board", "ls", "--column", "done" })
    t.ok(out:find("Three", 1, true), out)
end)

t.test(
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
        t.eq(code, 0, out)
        t.eq(
            document(file_of(home)).cards[1].description,
            "## Problem\nIt breaks.\n\n## Change\n- fix it\n\n## Out of scope\nnothing\n"
        )
    end
)

t.test(
    "a local board refuses --description with a section flag and a Backlog add without Problem",
    function()
        local root, home = local_board()
        local out, code =
            dev(root, home, { "board", "add", "Both", "--description", "text", "--problem", "p" })
        t.eq(code, 2)
        t.ok(out:find("--description", 1, true), out)
        out, code = dev(root, home, { "board", "add", "Bare" })
        t.eq(code, 2)
        t.ok(out:find("text under ## Problem", 1, true), out)
        out, code = dev(root, home, { "board", "add", "OnlyChange", "--change", "- do" })
        t.eq(code, 2)
        t.eq(#document(file_of(home)).cards, 0)
    end
)

t.test("a free-form Icebox card cannot enter Backlog until edit gives it a Problem", function()
    local root, home = local_board()
    local a = prefix_of(
        (
            dev(
                root,
                home,
                { "board", "add", "Idea", "--column", "icebox", "--description", "loose" }
            )
        )
    )
    t.eq(document(file_of(home)).cards[1].description, "loose")
    local out, code = dev(root, home, { "board", "move", a, "backlog" })
    t.eq(code, 1)
    t.ok(out:find("cannot enter Backlog", 1, true), out)
    t.ok(out:find("## Problem", 1, true), out)
    local file = root .. "/plan.md"
    assert(fs.write(file, "## Problem\nwhy\n\n## Change\n\n## Out of scope\n"))
    out, code = dev(root, home, { "board", "edit", a, "--file", file })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", a, "backlog" })
    t.eq(code, 1)
    t.ok(out:find("a size", 1, true) and out:find("Done when outcomes", 1, true), out)
    out, code = dev(root, home, { "board", "size", a, "1" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "outcome", a, "It works" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", a, "backlog" })
    t.eq(code, 0, out)
    t.eq(out, "moved " .. a .. " to Backlog\n")
end)

t.test("a local board refuses Ready for a card with an empty Change or Out of scope", function()
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
    local out, code = dev(root, home, { "board", "move", a, "ready" })
    t.eq(code, 1)
    t.ok(out:find("text under ## Change", 1, true), out)
    t.ok(out:find("text under ## Out of scope", 1, true), out)
    local file = root .. "/full.md"
    assert(fs.write(file, "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone\n"))
    out, code = dev(root, home, { "board", "edit", a, "--file", file })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", a, "ready" })
    t.eq(code, 0, out)
end)

t.test("order puts the named cards first and keeps the rest below on a local board", function()
    local root, home = local_board()
    local ids = {}
    for _, name in ipairs({ "One", "Two", "Three", "Four" }) do
        local out, code = dev(
            root,
            home,
            { "board", "add", name, "--problem", "x", "--size", "1", "--done-when", "a" }
        )
        t.eq(code, 0, out)
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
    t.eq(names(out), { "One", "Two", "Three", "Four" })
    local four, three, two, one = ids[1], ids[2], ids[3], ids[4]
    out = dev(root, home, { "board", "order", three, one })
    t.eq(names(out), { "Three", "One", "Two", "Four" })
    out = dev(root, home, { "board", "ls" })
    t.eq(names(out), { "Three", "One", "Two", "Four" })
    out = dev(root, home, { "board", "order", four })
    t.eq(names(out), { "Four", "Three", "One", "Two" })
    local code
    out, code = dev(root, home, { "board", "order", one, two, one })
    t.eq(code, 1, out)
    t.ok(out:find("twice", 1, true), out)
    out = dev(root, home, { "board", "ls" })
    t.eq(names(out), { "Four", "Three", "One", "Two" })
end)

t.test("order refuses cards of two columns before any move and frees a needs:human card", function()
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
    dev(root, home, { "board", "move", two, "icebox" })
    local before = dev(root, home, { "board", "ls" })
    local code
    out, code = dev(root, home, { "board", "order", one, two })
    t.eq(code, 1, out)
    t.ok(out:find("one column", 1, true), out)
    t.eq(dev(root, home, { "board", "ls" }), before)
    dev(root, home, { "board", "label", two, "needs:human" })
    out, code = dev(root, home, { "board", "order", two })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", two, "icebox" })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "move", two, "backlog" })
    t.eq(code, 1, out)
    t.ok(out:find("needs:human", 1, true), out)
end)

t.test("a move into an empty column leaves ls ordered by column", function()
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
    dev(root, home, { "board", "move", two, "icebox" })
    local out = dev(root, home, { "board", "ls" })
    t.ok(out:find("Two", 1, true) < out:find("One", 1, true), out)
end)

t.test("run starts a lint-clean run card, resumes it and ends it", function()
    local root, home = local_board()
    local agent = { DEV_AGENT = "dotfiles/one" }
    local out, code = dev(root, home, { "board", "run" }, agent)
    t.eq(code, 1, out)
    t.ok(out:find("dev board run --orders TEXT", 1, true), out)
    out, code = dev(root, home, { "board", "run", "--orders", "Clear the board\nthen stop" }, agent)
    t.eq(code, 0, out)
    t.ok(out:find("started ", 1, true), out)
    t.ok(out:find("run dotfiles/one", 1, true), out)
    t.ok(out:find("> Clear the board", 1, true), out)
    out, code = dev(root, home, { "board", "run", "--orders", "again" }, agent)
    t.eq(code, 1, out)
    t.ok(out:find("already has the run card", 1, true), out)
    out, code = dev(root, home, { "board", "lint" })
    t.eq(code, 0, out)
    t.eq(out, "no findings\n")
    out, code = dev(root, home, { "board", "run" }, agent)
    t.eq(code, 0, out)
    t.ok(out:find("held by dotfiles/one:", 1, true), out)
    t.ok(out:find("no ready cards", 1, true), out)
    out, code = dev(root, home, { "board", "run", "--end" }, agent)
    t.eq(code, 0, out)
    t.ok(out:find("ended ", 1, true), out)
    out, code = dev(root, home, { "board", "run" }, agent)
    t.eq(code, 1, out)
    out, code = dev(root, home, { "board", "lint" })
    t.eq(code, 0, out)
end)

t.test("run gives each session its own card and next never returns one", function()
    local root, home = local_board()
    local one, two = { DEV_AGENT = "s/one" }, { DEV_AGENT = "s/two" }
    t.eq(select(2, dev(root, home, { "board", "run", "--orders", "a" }, one)), 0)
    t.eq(select(2, dev(root, home, { "board", "run", "--orders", "b" }, two)), 0)
    local out, code = dev(root, home, { "board", "ls" })
    t.ok(out:find("run s/one", 1, true), out)
    t.ok(out:find("run s/two", 1, true), out)
    out = dev(root, home, { "board", "run" }, one)
    t.ok(not out:find("> b", 1, true), out)
    local id = assert(out:match("^(%x+)"), out)
    dev(root, home, { "board", "note", id, "built, tried, learned" }, one)
    out, code = dev(root, home, { "board", "move", id, "ready" }, one)
    t.eq(code, 0, out)
    dev(
        root,
        home,
        { "board", "add", "Plain", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    out = dev(root, home, { "board", "next" })
    t.ok(not out:find("run s/", 1, true), out)
    out, code = dev(root, home, { "board", "run", "--end" }, one)
    t.eq(code, 0, out)
    out = dev(root, home, { "board", "next" })
    t.ok(not out:find("run s/", 1, true), out)
end)

t.test("run refuses orders over the word limit and a flag mix", function()
    local root, home = local_board()
    local long = string.rep("word ", 300)
    local out, code = dev(root, home, { "board", "run", "--orders", long })
    t.eq(code, 2, out)
    out, code = dev(root, home, { "board", "run", "--orders", "x", "--end" })
    t.eq(code, 2, out)
    out, code = dev(root, home, { "board", "run", "--orders", "a", "--orders", "b" })
    t.eq(code, 2, out)
    t.ok(out:find("takes one value", 1, true), out)
end)

t.test("run on a private project with no board starts making one", function()
    local root, home = setup("")
    local out, code = dev(root, home, { "board", "run", "--orders", "x" })
    t.eq(code, 1, out)
    t.ok(out:find("private and has no board", 1, true), out)
    t.ok(out:find("lead_token", 1, true), out)
end)

t.test("add --id-only prints the full id alone and sends warnings to standard error", function()
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
    t.eq(code, 0, out)
    t.ok(out:match("^%x+%-%x+%-%x+%-%x+%-%x+\n$"), out)
    t.eq(errors, "warning: card prose holds a path: src/a.lua\n")
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
    t.ok(plain:find("^added %x+ Backlog\n$"), plain)
end)

t.test("a failed add --id-only prints nothing on standard output and exits non-zero", function()
    local root, home = local_board()
    local out, code, errors = support.dev(root, {
        "board",
        "add",
        "Bad",
        "--id-only",
        "--column",
        "nowhere",
    }, { env = env_of(home), split = true })
    t.ok(code ~= 0, out)
    t.eq(out, "")
    t.ok(errors ~= "", errors)
end)

t.test("add --id-only is refused while Pomb is unreachable and never queued", function()
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
    t.ok(code ~= 0, out)
    t.eq(out:find(QUEUED, 1, true), nil)
    t.eq(fs.exists(queue_path(home)), false)
end)

t.test("add takes --id-only as a value when a flag is waiting for one", function()
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
    t.eq(code, 0, out)
    t.ok(out:find("^%x+%-%x+%-%x+%-%x+%-%x+\n$"), out)
end)

local function sized_board()
    local root, home = local_board()
    local function ready(name, size)
        return prefix_of((dev(root, home, {
            "board",
            "add",
            name,
            "--column",
            "ready",
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

t.test("next skips a card above the runner's size limit", function()
    local root, home, big, small = sized_board()
    local out = dev(root, home, { "board", "next" }, { DEV_MAX_SIZE = "" })
    t.ok(out:find(big, 1, true), out)
    out = dev(root, home, { "board", "next", "--max-size", "1" })
    t.ok(out:find(small, 1, true) and not out:find(big, 1, true), out)
    out = dev(root, home, { "board", "next" }, { DEV_MAX_SIZE = "2" })
    t.ok(out:find(small, 1, true) and not out:find(big, 1, true), out)
    local code
    out, code = dev(root, home, { "board", "next", "--max-size", "9" })
    t.eq(code, 2, out)
end)

t.test("take and move into progress refuse a card above the runner's size limit", function()
    local root, home, big, small = sized_board()
    local env = { DEV_MAX_SIZE = "2", DEV_AGENT = "r/one" }
    local out, code = dev(root, home, { "board", "take", big }, env)
    t.eq(code, 1, out)
    t.ok(out:find("above this runner's limit of 2 Pomodori", 1, true), out)
    out, code = dev(root, home, { "board", "move", big, "progress" }, env)
    t.eq(code, 1, out)
    t.ok(out:find("above this runner's limit", 1, true), out)
    t.eq(card_named(document(file_of(home)), "Big").claim, nil)
    out, code = dev(root, home, { "board", "take", small }, env)
    t.eq(code, 0, out)
end)

t.test("with no size limit set next, take and move change nothing", function()
    local root, home, big = sized_board()
    local out, code = dev(root, home, { "board", "next" }, { DEV_MAX_SIZE = "" })
    t.eq(code, 0, out)
    t.ok(out:find(big, 1, true), out)
    out, code = dev(
        root,
        home,
        { "board", "take", big },
        { DEV_AGENT = "r/one", DEV_MAX_SIZE = "" }
    )
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "note", big, "built it" }, { DEV_AGENT = "r/one" })
    t.eq(code, 0, out)
    out, code = dev(
        root,
        home,
        { "board", "move", big, "review" },
        { DEV_AGENT = "r/one", DEV_MAX_SIZE = "" }
    )
    t.eq(code, 0, out)
end)

t.test("next refuses an empty --max-size", function()
    local root, home = sized_board()
    local out, code = dev(root, home, { "board", "next", "--max-size", "" })
    t.eq(code, 2, out)
end)

t.test("take and move refuse a DEV_MAX_SIZE that is not 1, 2 or 3", function()
    local root, home, big = sized_board()
    local env = { DEV_MAX_SIZE = "9", DEV_AGENT = "r/one" }
    local out, code = dev(root, home, { "board", "take", big }, env)
    t.eq(code, 2, out)
    out, code = dev(root, home, { "board", "move", big, "progress" }, env)
    t.eq(code, 2, out)
end)

t.test("epic_local_move", function()
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
    dev(root, home, { "board", "link", child, "parent", epic })
    local out, code = dev(root, home, { "board", "move", epic, "done" })
    t.eq(code, 1, out)
    t.ok(out:find("is an epic and cannot enter Done, a done column", 1, true), out)
    t.ok(out:find("1 of 1 children are open", 1, true), out)
    out, code = dev(root, home, { "board", "move", epic, "review" })
    t.eq(code, 0, out)
    tick_first(root, home, child)
    dev(root, home, { "board", "move", child, "done" })
    out, code = dev(root, home, { "board", "move", epic, "done" })
    t.eq(code, 0, out)
    dev(root, home, { "board", "move", child, "backlog" })
    out, code = dev(root, home, { "board", "move", epic, "backlog" })
    t.eq(code, 0, out)
    out = dev(root, home, { "board", "ls" })
    t.ok(out:find("[epic 1 of 1 open] Epic", 1, true), out)
end)

t.test("epic_local_next", function()
    local root, home = local_board()
    local function add(name)
        return prefix_of((dev(root, home, {
            "board",
            "add",
            name,
            "--column",
            "ready",
            "--size",
            "1",
            "--description",
            V1,
            "--checks",
            "dev test",
        })))
    end
    local epic, child = add("Epic"), add("Child")
    dev(root, home, { "board", "link", child, "parent", epic })
    local out = dev(root, home, { "board", "ls" })
    t.ok(out:find("[epic 1 of 1 open] Epic", 1, true), out)
    out = dev(root, home, { "board", "show", epic })
    t.ok(out:find("\nkind: epic, 1 open\n", 1, true), out)
    out = dev(root, home, { "board", "next" })
    t.ok(out:find(child .. "  Ready", 1, true), out)
    out = dev(root, home, { "board", "next", "--column", "ready" })
    t.ok(out:find(child, 1, true) and not out:find(epic, 1, true), out)
    out = dev(root, home, { "board", "move", child, "done" })
    out = dev(root, home, { "board", "next" })
    t.ok(out:find(epic .. "  Ready", 1, true), out)
    out = dev(root, home, { "board", "move", epic, "progress" }, { DEV_AGENT = "r/one" })
    t.ok(out:find("r/one", 1, true), out)
    t.eq(card_named(document(file_of(home)), "Epic").claim.claimant, "r/one")
end)
