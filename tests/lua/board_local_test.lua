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
    local env = { HOME = home, XDG_STATE_HOME = home .. "/state", CLAUDE_SESSION_ID = "one" }
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

local function mode(path)
    return string.format("%o", bit.band(assert(fs.stat(path)).mode, 511))
end

t.test("init lays out the seven columns and the palette and is idempotent", function()
    local root, home = setup('[board]\nbackend = "local"\nname = "mine"\n')
    local out, code = dev(root, home, { "board", "init" })
    t.eq(code, 0, out)
    t.ok(out:find("created board mine with no template", 1, true), out)
    for _, column in ipairs({
        "Icebox",
        "Backlog",
        "Ready",
        "In Progress",
        "In Review",
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
    t.eq(names, { "Icebox", "Backlog", "Ready", "In Progress", "In Review", "Blocked", "Done" })
    t.eq(doc.columns[7].is_done, true)
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
    dev(root, home, { "board", "add", "One" })
    t.eq(mode(file_of(home)), "600")
    t.eq(mode(home .. "/state/dev/boards"), "700")
    local names = fs.list(home .. "/state/dev/boards")
    t.eq(names, { "mine.json", "mine.json.lock" })
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
    out = dev(root, home, { "board", "add", "Second" })
    local b = prefix_of(out)
    out = dev(root, home, { "board", "ls" })
    t.eq(
        out,
        b
            .. "  Backlog  Unsized     -                Second\n"
            .. a
            .. "  Ready    2 Pomodori  docs,needs:lead  Write docs\n"
    )
    out = dev(root, home, { "board", "ls", "--size", "3+" })
    t.eq(out, "no cards\n")
    out = dev(root, home, { "board", "ls", "--label", "docs" })
    t.ok(out:find("Write docs", 1, true), out)
    out = dev(root, home, { "board", "next" })
    t.eq(out, a .. "  Ready  2 Pomodori  docs,needs:lead  Write docs\n")
    out = dev(root, home, { "board", "move", a, "review" })
    t.eq(out, "moved " .. a .. " to In Review\n")
    out = dev(root, home, { "board", "next" })
    t.eq(out, "no ready cards\n")
    out = dev(root, home, { "board", "size", b, "1" })
    t.eq(out, "sized " .. b .. " 1\n")
    out = dev(root, home, { "board", "label", a, "+extra", "--remove", "docs" })
    t.eq(out, "labelled " .. a .. " needs:lead,extra\n")
    out = dev(root, home, { "board", "move", a, "done" })
    out = dev(root, home, { "board", "ls" })
    t.eq(out, b .. "  Backlog  1 Pomodoro  -  Second\n")
    out = dev(root, home, { "board", "ls", "--column", "done" })
    t.ok(out:find("Done  2 Pomodori", 1, true), out)
end)

t.test("edit replaces a local card's description from a file or standard input", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "Card", "--description", "old" })))
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
    t.eq(out, a .. "  Backlog  Unsized  -  Card\n\nfrom standard input\n\nno comments\n")
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

t.test("rename sets a local card's title and refuses a blank one", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "Card" })))
    local out, code = dev(root, home, { "board", "rename", a, "Better", "title" })
    t.eq(code, 0, out)
    t.eq(out, "renamed " .. a .. "\n")
    t.eq(document(file_of(home)).cards[1].name, "Better title")
    out, code = dev(root, home, { "board", "rename", a, " " })
    t.eq(code, 2, out)
    t.eq(document(file_of(home)).cards[1].name, "Better title")
end)

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
    local a = prefix_of((dev(root, home, { "board", "add", "Card" })))
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
    local a = prefix_of((dev(root, home, { "board", "add", "Card" })))
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
    local a = prefix_of((dev(root, home, { "board", "add", "A" })))
    local b = prefix_of((dev(root, home, { "board", "add", "B" })))
    local c = prefix_of((dev(root, home, { "board", "add", "C" })))
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
    local d = prefix_of((dev(root, home, { "board", "add", "D" })))
    out = dev(root, home, { "board", "links", d })
    t.eq(out, "no links\n")
    out, code = dev(root, home, { "board", "links", "deadbeef" })
    t.eq(code, 1, out)
end)

t.test("link refuses itself, a cycle, another board and a bad kind on a local board", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "A" })))
    local b = prefix_of((dev(root, home, { "board", "add", "B" })))
    local c = prefix_of((dev(root, home, { "board", "add", "C" })))
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

t.test("a local board refuses what the needs:human and umbrella rules forbid", function()
    local root, home = local_board()
    local function add(name)
        return prefix_of((dev(root, home, { "board", "add", name })))
    end
    local card, child = add("Card"), add("Child")
    local umbrella = prefix_of((dev(root, home, {
        "board",
        "add",
        "Umbrella",
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
    dev(root, home, { "board", "link", child, "parent", umbrella })
    out, code = dev(root, home, { "board", "move", umbrella, "ready" })
    t.eq(code, 1, out)
    t.ok(out:find("never enters Ready", 1, true), out)
end)

t.test("link parent sets one umbrella a level deep and show and links report it", function()
    local root, home = local_board()
    local function add(name)
        return prefix_of((dev(root, home, { "board", "add", name })))
    end
    local umbrella, one, two, other = add("Umbrella"), add("One"), add("Two"), add("Other")
    local out, code = dev(root, home, { "board", "link", one, "parent", umbrella })
    t.eq(out, "linked " .. one .. " parent " .. umbrella .. "\n")
    t.eq(code, 0)
    t.eq(dev(root, home, { "board", "link", one, "parent", umbrella }), out)
    dev(root, home, { "board", "link", two, "parent", umbrella })
    out, code = dev(root, home, { "board", "link", one, "parent", other })
    t.eq(code, 1, out)
    t.ok(out:find("already has an umbrella", 1, true), out)
    out, code = dev(root, home, { "board", "link", other, "parent", one })
    t.eq(code, 1, out)
    t.ok(out:find("nest one level", 1, true), out)
    out, code = dev(root, home, { "board", "link", umbrella, "parent", other })
    t.eq(code, 1, out)
    t.ok(out:find("nest one level", 1, true), out)
    out = dev(root, home, { "board", "show", one })
    t.ok(out:find("\nparent: " .. umbrella .. " Umbrella\n", 1, true), out)
    out = dev(root, home, { "board", "show", umbrella })
    t.ok(out:find("\nchildren: 0 of 2 done\n", 1, true), out)
    dev(root, home, { "board", "move", one, "done" })
    out = dev(root, home, { "board", "show", umbrella })
    t.ok(out:find("\nchildren: 1 of 2 done\n", 1, true), out)
    out = dev(root, home, { "board", "links", one })
    t.ok(out:find("parent", 1, true) and out:find(umbrella, 1, true), out)
    out = dev(root, home, { "board", "links", umbrella })
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

t.test(
    "a local board keeps an unsized or red card out of Ready and lists the unsized in stale",
    function()
        local root, home = local_board()
        local a = prefix_of(
            (
                dev(
                    root,
                    home,
                    { "board", "add", "Loose", "--description", V1, "--checks", "dev test" }
                )
            )
        )
        local out, code = dev(root, home, { "board", "move", a, "ready" })
        t.eq(code, 1)
        t.ok(out:find("dev board size", 1, true), out)
        out, code = dev(root, home, { "board", "add", "Direct", "--column", "ready" })
        t.eq(code, 2)
        out = dev(root, home, { "board", "stale" })
        t.eq(out, "no stale cards\n\nunsized in Backlog:\n" .. a .. "  Backlog  Loose\n")
        dev(root, home, { "board", "size", a, "3+" })
        out, code = dev(root, home, { "board", "move", a, "ready" })
        t.eq(code, 1)
        t.ok(out:find("red", 1, true), out)
        dev(root, home, { "board", "size", a, "2" })
        out, code = dev(root, home, { "board", "move", a, "ready" })
        t.eq(code, 0, out)
        t.eq(dev(root, home, { "board", "stale" }), "no stale cards\n")
    end
)

t.test(
    "a local board scaffolds the v2 headings and keeps a card without them out of Ready",
    function()
        local root, home = local_board()
        local a = prefix_of(
            (dev(root, home, { "board", "add", "Plain", "--size", "1", "--checks", "dev test" }))
        )
        t.eq(
            document(file_of(home)).cards[1].description,
            "## Problem\n\n## Change\n\n## Out of scope\n"
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
        out, code = dev(root, home, { "board", "move", a, "icebox" })
        t.eq(code, 0, out)
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
    out = dev(root, home, { "board", "outcome", a, "--rename", "1", "A holds" })
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

t.test("a local board converts a v1 checklist into outcomes and ticks", function()
    local root, home = local_board()
    local v1 =
        "## Problem\nP\n\n## Done when\n- [ ] A works\n- [x] B works\n- [ ] C works\n\n## Out of scope\nNone\n"
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
    t.ok(card.description:find("## Problem\nP\n\n## Out of scope\nNone", 1, true), card.description)
    out, code = dev(root, home, { "board", "outcome", a, "--convert" })
    t.eq(code, 0, out)
    t.eq(out, "outcome " .. a .. " left alone: it already has outcomes\n")
    t.eq(#document(file_of(home)).cards[1].outcomes, 3)
end)

t.test("outcome --convert leaves a card with no checklist alone", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "Plain" })))
    local out, code = dev(root, home, { "board", "outcome", a, "--convert" })
    t.eq(code, 0, out)
    t.eq(out, "outcome " .. a .. " left alone: it has no Done when checklist\n")
    out, code = dev(root, home, { "board", "outcome", a, "--convert", "extra" })
    t.eq(code, 2)
end)

t.test("a local board ticks an outcome while this machine holds the claim", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "Card", "--done-when", "A works" })))
    local out, code = dev(root, home, { "board", "take", a })
    t.eq(code, 0, out)
    out, code = dev(root, home, { "board", "outcome", a, "--tick", "1" })
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
    "take --as and move into progress name the holder, and an umbrella stays unclaimed",
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
        t.eq(document(file_of(home)).cards[1].claim.claimant, "r/one")
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
        t.eq(document(file_of(home)).cards[1].claim.claimant, "r/one")
        dev(root, home, { "board", "release", a })
        out, code = dev(root, home, { "board", "move", a, "progress" }, { DEV_AGENT = "r/three" })
        t.eq(code, 0, out)
        t.eq(document(file_of(home)).cards[1].claim, nil)
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
    local out, code = dev(root, home, { "board", "move", a, "review" })
    t.eq(code, 0, out)
    t.eq(out, "moved " .. a .. " to In Review\n")
    t.eq(document(file_of(home)).cards[1].claim, nil)
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
    t.eq(out, "took " .. a .. ", fence 1, held for 50m\n")
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
    t.eq(out, "took " .. a .. ", fence 1, held for 50m\n")
    out = dev(root, home, { "board", "release", a })
    t.eq(out, "released " .. a .. "\n")
    out = dev(root, home, { "board", "next" })
    t.ok(out:find("Card", 1, true), out)
    out = dev(root, home, { "board", "take", a }, { CLAUDE_SESSION_ID = "other" })
    t.eq(out, "took " .. a .. ", fence 2, held for 50m\n")
end)

t.test("a stale fence is refused once another process holds the claim", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "Card" })))
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
    local out = dev(root, home, { "board", "add", "Tracked" })
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
        'for i in 1 2 3 4 5 6; do luajit %s board add "card $i" & done; wait',
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
    .. '{"id":"col-review","name":"In Review"},{"id":"col-done","name":"Done"}]}'
local COLORS = '[{"id":"white-id","value":"white","label":"Unsized"}]'
local EXPORT = '{"tasks":[{"id":"'
    .. ID_A
    .. '","name":"First","column_id":"col-ready","position":1,"color_id":null,"labels":[]},'
    .. '{"id":"'
    .. ID_B
    .. '","name":"Second","column_id":"col-ready","position":2,"color_id":null,"labels":[]}]}'

local FIELDS =
    '[{"id":"f1","key":"dev.checks","label":"Checks","kind":"table","options":[],"columns":[],"required":true}]'

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
*/api/tasks/aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa) body='{"id":"aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa","parent":{"id":"bbbbbbbb-1111-4bbb-8bbb-bbbbbbbbbbbb","name":"Umbrella"},"children_done":1,"children_total":3}' ;;
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
        ["fields.json"] = FIELDS,
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
    out = pomb_dev(root, home, { "board", "add", "Later", "--size", "2", "--label", "docs" })
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

t.test("after a gateway error only a change that is safe to repeat is queued", function()
    local root, home = pomb()
    assert(fs.write(root .. "/gateway", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    t.eq(out, QUEUED)
    t.eq(code, 0)
    out, code = pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "once" })
    t.eq(code, 1, out)
    out, code = pomb_dev(root, home, { "board", "add", "Once" })
    t.eq(code, 1, out)
    t.eq(#document(queue_path(home)), 1)
end)

t.test("a hand-edited board file keeps its other keys and gets its name back", function()
    local root, home = local_board()
    local doc = document(file_of(home))
    doc.name = nil
    doc.note = "kept"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    dev(root, home, { "board", "add", "One" })
    doc = document(file_of(home))
    t.eq(doc.note, "kept")
    t.eq(doc.name, "mine")
end)

t.test("a tracked board leaves no lock file in the project", function()
    local root, home = local_board('[board]\nbackend = "local"\npath = ".dev/board.json"\n')
    dev(root, home, { "board", "add", "One" })
    t.eq(fs.list(root .. "/.dev"), { "board.json", "config.toml" })
end)

t.test("show reads the umbrella and the children of a card from the task view", function()
    local root, home = pomb()
    local out, code = pomb_dev(root, home, { "board", "show", ID_A:sub(1, 8) })
    t.eq(code, 0, out)
    t.ok(out:find("\nparent: bbbbbbbb Umbrella\nchildren: 1 of 3 done\n\n", 1, true), out)
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

t.test("edit patches the task, and a queued edit replays with its text", function()
    local root, home = pomb()
    assert(fs.write(root .. "/plan.md", "new plan\n"))
    local out, code =
        pomb_dev(root, home, { "board", "edit", ID_A:sub(1, 8), "--file", root .. "/plan.md" })
    t.eq(code, 0, out)
    t.eq(out, "edited aaaaaaaa\n")
    t.ok(calls(root):find("/api/tasks/" .. ID_A .. "\n", 1, true), calls(root))
    t.eq(fs.read(root .. "/bodies"), '{"description":"new plan"}\n')
    assert(fs.write(root .. "/down", ""))
    out, code = support.dev(root, { "board", "edit", ID_B:sub(1, 8) }, {
        env = env_of(home, { ROOT = root }),
        input = "waiting plan\n",
    })
    t.eq(out, QUEUED)
    t.eq(code, 0)
    local entries = document(queue_path(home))
    t.eq(#entries, 1)
    t.eq(entries[1].sub, "edit")
    t.eq(entries[1].args, { ID_B:sub(1, 8), "waiting plan" })
    assert(fs.remove(root .. "/down"))
    out = pomb_dev(root, home, { "board", "sync" })
    t.eq(out, "synced edit bbbbbbbb\nsynced\n")
    t.ok(calls(root):find("/api/tasks/" .. ID_B .. "\n", 1, true), calls(root))
end)

t.test("a local board replaces a card's checks and then lets it enter Ready", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "Bare", "--size", "1" })))
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
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    pomb_dev(root, home, { "board", "note", ID_B:sub(1, 8), "hello" })
    pomb_dev(root, home, { "board", "add", "Later" })
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
    dev(root, home, { "board", "add", "One" })
    t.eq(fs.exists(home .. "/state/dev/boards/mine.queue"), false)
end)

t.test("a local board stores checks on the card and show lists them", function()
    local root, home = local_board()
    local out, code =
        dev(root, home, { "board", "add", "Card", "--checks", "dev lint", "--checks", "dev test" })
    t.eq(code, 0, out)
    local a = prefix_of(out)
    t.eq(document(file_of(home)).cards[1].checks, { "dev lint", "dev test" })
    out = dev(root, home, { "board", "show", a })
    t.ok(out:find("\n\nchecks:\n- dev lint\n- dev test\n\n", 1, true), out)
end)

t.test("a local board keeps a card with no checks row out of Ready", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "Bare", "--size", "1" })))
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
    out, code = dev(root, home, { "board", "move", a, "icebox" })
    t.eq(code, 0, out)
    out = dev(root, home, { "board", "init" })
    t.eq(out:find("checks field", 1, true), nil)
end)

t.test("wait on a local board answers at once that there is nothing to wait on", function()
    local backend = require("dev.board.localboard").new({ name = "mine" })
    local got, message = backend:wait("1", { "task_added" }, 5)
    t.eq(got, nil)
    t.eq(message, "a local board has nothing to wait on")
end)
