local t = require("testing")
local commands = require("dev.cmd.board")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local V2 = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone"
local V1 = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone\n\n## Done when\n- [ ] done"

local function outcomes(ticked)
    local list = {}
    for i = 1, 3 do
        list[i] = { id = "o" .. i, name = "outcome " .. i, done = i <= ticked }
    end
    return list
end

local function card(n, column, fields)
    local made = {
        id = string.format("%08d-aaaa-4aaa-8aaa-aaaaaaaaaaaa", n),
        name = "Card " .. n,
        column = column,
        done = column == "Done",
        size = "2 Pomodori",
        color = "green",
        labels = {},
        description = V2,
        claimant = "someone",
        checks = { "dev test" },
        outcomes = outcomes(column == "Done" and 3 or 0),
    }
    for key, value in pairs(fields or {}) do
        made[key] = value or nil
    end
    return made
end

local function backend(cards, held)
    held = held or {}
    local calls = {}
    local fake = { calls = calls }
    function fake:done_columns()
        return { "Done" }
    end
    function fake:cards()
        return cards
    end
    function fake:comments(id)
        calls[#calls + 1] = "comments"
        return held.comments and held.comments[id] or {}
    end
    function fake:links(id)
        calls[#calls + 1] = "links"
        return held.links and held.links[id] or {}
    end
    function fake:family(id)
        calls[#calls + 1] = "family"
        local total = held.children and held.children[id]
        return { children = total and { done = 0, total = total } or nil }
    end
    return fake
end

local function findings(output)
    local lines = {}
    for line in output:gmatch("[^\n]+") do
        lines[#lines + 1] = (line:gsub("%s+", " "))
    end
    return lines
end

t.test("lint reports one line per rule a card breaks and exits 1", function()
    local words = string.rep(" word", 400)
    local cards = {
        card(1, "Backlog", { color = false }),
        card(2, "Backlog", { description = "## Problem\nwhy\n\n## Out of scope\nnone" }),
        card(3, "Backlog"),
        card(4, "Ready", { checks = {} }),
        card(5, "Ready", { color = "red" }),
        card(6, "Backlog", { description = V2 .. "\n" .. words }),
        card(7, "Ready", { labels = { "needs:human" } }),
        card(8, "Blocked"),
        card(9, "In Progress", { claimant = false }),
        card(10, "Done", { outcomes = outcomes(2) }),
        card(11, "Done", { outcomes_unreadable = true, outcomes = {} }),
        card(12, "Backlog", { labels = { "discarded" }, outcomes = {} }),
    }
    cards[3].outcomes = {}
    local result = commands.run("lint", {}, backend(cards))
    t.eq(result.code, 1)
    t.eq(findings(result.output), {
        "00000001 Backlog lacks a size",
        "00000002 Backlog lacks ## Change",
        "00000003 Backlog lacks Done when outcomes",
        "00000004 Ready no checks row",
        "00000005 Ready red card in Ready",
        "00000006 Backlog over 400 words (412)",
        "00000007 Ready needs:human outside Blocked and Icebox",
        "00000008 Blocked blocked with no question or blocked note and no blocker",
        "00000009 In Progress in progress with no claimant",
        "00000010 Done 1 of 3 outcomes unticked",
        "00000011 Done outcomes unreadable",
        "00000012 Backlog lacks Done when outcomes",
    })
end)

t.test("lint passes a clean board with exit 0 and no code", function()
    local cards = {
        card(1, "Icebox", { description = false, color = false, outcomes = {} }),
        card(2, "Done", { description = V1, outcomes = {} }),
        card(3, "Done", { labels = { "discarded" }, outcomes = outcomes(0) }),
        card(4, "Done", { description = false, claimant = false }),
        card(5, "Blocked", { labels = { "needs:human" } }),
        card(6, "Blocked"),
        card(7, "In Progress", { claimant = false }),
        card(8, "Ready", { checks = { "dev test" } }),
        card(9, "Icebox", { labels = { "needs:human" } }),
    }
    local held = {
        comments = { [cards[5].id] = { { kind = "question", body = "which?" } } },
        links = { [cards[6].id] = { { kind = "blocked_by", id = cards[8].id } } },
        children = { [cards[7].id] = 2 },
    }
    local result = commands.run("lint", {}, backend(cards, held))
    t.eq(result.output, "no findings")
    t.eq(result.code, nil)
    t.eq(result.message, nil)
end)

t.test("lint reads comments only for a Blocked card and writes nothing", function()
    local cards = {
        card(1, "Ready"),
        card(2, "Blocked"),
        card(3, "In Progress", { claimant = false }),
        card(4, "In Progress"),
    }
    local fake = backend(cards, { children = {} })
    commands.run("lint", {}, fake)
    t.eq(fake.calls, { "comments", "links", "family" })
end)

t.test("lint refuses an argument", function()
    t.eq(commands.run("lint", { "extra" }, backend({})).code, 2)
end)

t.test("lint fails when a card's comments cannot be read", function()
    local fake = backend({ card(1, "Blocked") })
    function fake:comments()
        return nil, "pomb is down"
    end
    local result = commands.run("lint", {}, fake)
    t.eq(result.code, 1)
    t.ok(result.message:find("pomb is down", 1, true), result.message)
end)

local function local_board(config)
    local root = support.sandbox({ [".dev/config.toml"] = config }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    local env = { HOME = home, XDG_STATE_HOME = home .. "/state", CLAUDE_SESSION_ID = "one" }
    local function dev(args)
        return support.dev(root, args, { env = env })
    end
    local out, code = dev({ "board", "init" })
    t.eq(code, 0, out)
    return dev, home .. "/state/dev/boards/mine.json"
end

local LOCAL = '[board]\nbackend = "local"\nname = "mine"\n'

local function bare_done_card(dev, path)
    local out, code = dev({
        "board",
        "add",
        "Card",
        "--size",
        "1",
        "--problem",
        "x",
        "--done-when",
        "a",
    })
    t.eq(code, 0, out)
    local id = assert(out:match("added (%x+)"), out)
    out, code = dev({ "board", "discard", id })
    t.eq(code, 0, out)
    local doc = assert(json.decode(assert(fs.read(path))))
    doc.cards[1].description = ""
    assert(fs.write(path, assert(json.encode(doc))))
end

t.test("dev board lint exits 1 on a bad local board and 0 on a clean one", function()
    local dev = local_board(LOCAL)
    local out, code = dev({ "board", "lint" })
    t.eq(code, 0, out)
    t.eq(out, "no findings\n")
    out, code = dev({
        "board",
        "add",
        "Long",
        "--column",
        "backlog",
        "--size",
        "1",
        "--problem",
        string.rep("word ", 401),
        "--done-when",
        "ok",
    })
    t.eq(code, 0, out)
    out, code = dev({ "board", "lint" })
    t.eq(code, 1, out)
    t.ok(out:find("Backlog +over 400 words"), out)
end)

t.test("strict holds a Done card to the v2 sections, by flag and by the config", function()
    local dev, path = local_board(LOCAL)
    bare_done_card(dev, path)
    local out, code = dev({ "board", "lint" })
    t.eq(code, 0, out)
    out, code = dev({ "board", "lint", "--strict" })
    t.eq(code, 1, out)
    t.ok(out:find("Done +lacks ## Problem"), out)
    dev, path = local_board(LOCAL .. "\n[board.lint]\nstrict = true\n")
    bare_done_card(dev, path)
    out, code = dev({ "board", "lint" })
    t.eq(code, 1, out)
    t.ok(out:find("Done +lacks ## Change"), out)
end)

t.test("a strict setting that is not a boolean is refused", function()
    local dev = local_board(LOCAL .. '\n[board.lint]\nstrict = "yes"\n')
    local out, code = dev({ "board", "lint" })
    t.eq(code, 1, out)
    t.ok(out:find("[board.lint] strict must be true or false", 1, true), out)
end)

t.test("strict adds the sections to a Done card and a discarded one, and nothing else", function()
    local cards = {
        card(1, "Done", { description = false }),
        card(2, "Done", { description = false, labels = { "discarded" }, outcomes = {} }),
        card(3, "Icebox", { description = false }),
    }
    t.eq(commands.run("lint", {}, backend(cards)).output, "no findings")
    local result = commands.run("lint", { "--strict" }, backend(cards))
    t.eq(result.code, 1)
    t.eq(findings(result.output), {
        "00000001 Done lacks ## Problem",
        "00000001 Done lacks ## Change",
        "00000001 Done lacks ## Out of scope",
        "00000002 Done lacks ## Problem",
        "00000002 Done lacks ## Change",
        "00000002 Done lacks ## Out of scope",
    })
end)
