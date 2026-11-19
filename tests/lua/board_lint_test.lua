local testing = require("dev.testing")
local board = require("dev.board")
local cmd_board = require("dev.cmd.board")
local fs = require("dev.fs")
local json = require("dev.json")
local review = require("dev.board.review")
local support = require("support")

---Board column names the lint tests use
local NAME = support.COLUMN_NAME
---Review record revision the lint tests share
local REV = { commit = "abc123", change = "xyz" }
local V2 = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone"
local V1 = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone\n\n## Done when\n- [ ] done"

local function outcomes(ticked)
    local list = {}
    for i = 1, 3 do
        list[i] =
            { id = "o" .. i, name = "outcome " .. i .. " " .. board.JUDGEMENT, done = i <= ticked }
    end
    return list
end

local function card(n, column, fields)
    local made = {
        id = string.format("%08d-aaaa-4aaa-8aaa-aaaaaaaaaaaa", n),
        name = "Card " .. n,
        column = column,
        done = column == NAME.DONE,
        size = "2 Pomodori",
        color = "green",
        labels = {},
        description = V2,
        claimant = "someone",
        checks = { "dev test" },
        outcomes = outcomes(column == NAME.DONE and 3 or 0),
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
        return { NAME.DONE }
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

testing.test("lint reports one line per rule a card breaks and exits 1", function()
    local words = string.rep(" word", 400)
    local cards = {
        card(1, NAME.BACKLOG, { color = false }),
        card(2, NAME.BACKLOG, { description = "## Problem\nwhy\n\n## Out of scope\nnone" }),
        card(3, NAME.BACKLOG),
        card(4, NAME.READY, { checks = {} }),
        card(5, NAME.READY, { color = "red" }),
        card(6, NAME.BACKLOG, { description = V2 .. "\n" .. words }),
        card(7, NAME.READY, { labels = { "needs:human" } }),
        card(8, NAME.BLOCKED),
        card(9, NAME.PROGRESS, { claimant = false }),
        card(10, NAME.DONE, { outcomes = outcomes(2) }),
        card(11, NAME.DONE, { outcomes_unreadable = true, outcomes = {} }),
        card(12, NAME.BACKLOG, { labels = { "discarded" }, outcomes = {} }),
    }
    cards[3].outcomes = {}
    local result = cmd_board.run("lint", {}, backend(cards))
    testing.eq(result.code, 1)
    testing.eq(findings(result.output), {
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

testing.test("lint open skips done cards and a named card", function()
    local cards = {
        card(1, NAME.BACKLOG, { color = false }),
        card(2, NAME.DONE, { outcomes = outcomes(2) }),
    }
    testing.eq(findings(cmd_board.run("lint", { "--open" }, backend(cards)).output), {
        "00000001 Backlog lacks a size",
    })
    testing.eq(findings(cmd_board.run("lint", {}, backend(cards)).output), {
        "00000001 Backlog lacks a size",
        "00000002 Done 1 of 3 outcomes unticked",
    })
    testing.eq(findings(cmd_board.run("lint", { "--open", "00000002" }, backend(cards)).output), {
        "00000002 Done 1 of 3 outcomes unticked",
    })
end)

testing.test(
    "lint flags an empty Change or Out of scope and a Change: line under Problem",
    function()
        local empty_change = "## Problem\nwhy\n\n## Change\n\n## Out of scope\nnone"
        local line_in_problem =
            "## Problem\nwhy\nChange: rewrite it\n\n## Change\nx\n\n## Out of scope\nn"
        local scope_in_problem =
            "## Problem\nwhy\nOut of scope: docs\n\n## Change\nx\n\n## Out of scope\nn"
        local cards = {
            card(1, NAME.BACKLOG, { description = empty_change, outcomes = outcomes(0) }),
            card(2, NAME.READY, { description = line_in_problem, outcomes = outcomes(0) }),
            card(3, NAME.ICEBOX, { description = empty_change, outcomes = {} }),
            card(4, NAME.BACKLOG, { description = scope_in_problem, outcomes = outcomes(0) }),
            card(5, NAME.DONE, { description = empty_change }),
        }
        local result = cmd_board.run("lint", {}, backend(cards))
        testing.eq(result.code, 1)
        testing.eq(findings(result.output), {
            "00000001 Backlog lacks " .. board.TEXT_UNDER .. "Change",
            "00000002 Ready lacks " .. board.MISPLACED,
            "00000004 Backlog lacks " .. board.MISPLACED,
        })
        result = cmd_board.run("lint", { "--strict" }, backend({ cards[5] }))
        testing.eq(
            findings(result.output),
            { "00000005 Done lacks " .. board.TEXT_UNDER .. "Change" }
        )
    end
)

testing.test("lint holds an epic to 1 to 3 outcomes and to its children", function()
    local cards = {
        card(1, NAME.BACKLOG, { outcomes = {} }),
        card(2, NAME.DONE, { outcomes = {} }),
        card(3, NAME.DONE, { outcomes = {} }),
        card(4, NAME.BACKLOG, { outcomes = {} }),
        card(5, NAME.BACKLOG, {
            outcomes = {
                { id = "o1", name = "a" },
                { id = "o2", name = "b" },
                { id = "o3", name = "c" },
                { id = "o4", name = "d" },
            },
        }),
        card(6, NAME.BACKLOG, { outcomes = outcomes(2) }),
    }
    local held = {
        children = {
            [cards[1].id] = 2,
            [cards[2].id] = 2,
            [cards[3].id] = 0,
            [cards[5].id] = 2,
            [cards[6].id] = 2,
        },
    }
    local fake = backend(cards, held)
    function fake:family(id)
        local total = held.children[id]
        if id == cards[2].id then
            return { children = { done = 1, total = total } }
        end
        return { children = total and total > 0 and { done = total, total = total } or nil }
    end
    local result = cmd_board.run("lint", {}, fake)
    testing.eq(findings(result.output), {
        "00000002 Done 1 of 2 children open",
        "00000003 Done lacks Done when outcomes",
        "00000004 Backlog lacks Done when outcomes",
        "00000005 Backlog lacks 1 to 3 Done when outcomes for an epic, not 4",
    })
end)

testing.test("lint lets a Done epic with every child Done close without outcomes", function()
    local cards = { card(1, NAME.DONE, { outcomes = {} }) }
    local held = { children = { [cards[1].id] = 2 } }
    local fake = backend(cards, held)
    function fake:family(id)
        return { children = { done = 2, total = held.children[id] } }
    end
    local result = cmd_board.run("lint", {}, fake)
    testing.eq(result.output, "No findings.")
end)

testing.test("lint leaves a Done epic with every child Done and four outcomes alone", function()
    local cards = {
        card(1, NAME.DONE, {
            outcomes = {
                { id = "o1", name = "a", done = true },
                { id = "o2", name = "b", done = true },
                { id = "o3", name = "c", done = true },
                { id = "o4", name = "d", done = true },
            },
        }),
    }
    local held = { children = { [cards[1].id] = 2 } }
    local fake = backend(cards, held)
    function fake:family(id)
        return { children = { done = 2, total = held.children[id] } }
    end
    local result = cmd_board.run("lint", {}, fake)
    testing.eq(findings(result.output), { "No findings." })
end)

testing.test("lint gives an epic no claimant exemption", function()
    local cards = {
        card(1, NAME.PROGRESS, { claimant = false, outcomes = outcomes(2) }),
        card(2, NAME.PROGRESS, { claimant = false, outcomes = outcomes(3) }),
    }
    local fake = backend(cards, { children = { [cards[1].id] = 2 } })
    testing.eq(findings(cmd_board.run("lint", {}, fake).output), {
        "00000001 In Progress in progress with no claimant",
        "00000002 In Progress in progress with no claimant",
    })
end)

testing.test("lint asks a card without children for a checks row and an epic for none", function()
    local cards = {
        card(1, NAME.PROGRESS, { outcomes = outcomes(2), checks = {} }),
        card(2, NAME.PROGRESS, { outcomes = outcomes(3), checks = {} }),
    }
    local fake = backend(cards, { children = { [cards[1].id] = 2 } })
    testing.eq(
        findings(cmd_board.run("lint", {}, fake).output),
        { "00000002 In Progress no checks row" }
    )
end)

local REQUIRED_CONFIG = '[board.lint]\nrequired = ["dev --remote lint", "dev --remote test"]\n'

local function required_board(cards, config)
    local fake = backend(cards, { children = { [cards[3].id] = 2 } })
    fake.root = support.sandbox({ [".dev/config.toml"] = config }, {})
    return fake
end

local function required_cards()
    return {
        card(1, NAME.READY, { outcomes = outcomes(3), checks = { "dev --remote lint" } }),
        card(2, NAME.PROGRESS, {
            outcomes = outcomes(3),
            checks = { "dev --remote lint", "dev --remote test -- tests/lua/board_test.lua" },
        }),
        card(3, NAME.REVIEW, { outcomes = outcomes(3), checks = { "dev --remote lint" } }),
        card(4, NAME.BACKLOG, { outcomes = outcomes(3), checks = { "dev test" } }),
        card(5, NAME.REVIEW, { outcomes = outcomes(3), checks = { "dev test" } }),
    }
end

testing.test("lint reports an open card missing a required row", function()
    local result = cmd_board.run("lint", {}, required_board(required_cards(), REQUIRED_CONFIG))
    testing.eq(findings(result.output), {
        "00000001 Ready checks lack the required row: dev --remote test",
        "00000005 Review checks lack the required row: dev --remote lint",
        "00000005 Review checks lack the required row: dev --remote test",
    })
    testing.eq(result.code, 1)
end)

testing.test("lint without a required list keeps today's findings", function()
    local result = cmd_board.run("lint", {}, required_board(required_cards(), ""))
    testing.eq(result.output, "No findings.")
    testing.eq(result.code, nil)
end)

testing.test("lint refuses a required setting that is not a list of commands", function()
    local fake = required_board(required_cards(), '[board.lint]\nrequired = "dev test"\n')
    local result = cmd_board.run("lint", {}, fake)
    testing.eq(result.code, 1)
    testing.eq(
        result.message,
        "The `required` setting of `[board.lint]` must be a list of commands."
    )
end)

testing.test(
    "lint flags an outcome that names no deciding check in Ready and In Progress",
    function()
        local named = { { id = "o1", name = "x " .. board.CHECK_OPEN .. "test)", done = false } }
        local bare = { { id = "o1", name = "bare", done = false } }
        local cards = {
            card(1, NAME.READY, { outcomes = bare, claimant = false }),
            card(2, NAME.READY, { outcomes = named, claimant = false }),
            card(3, NAME.PROGRESS, { outcomes = bare }),
            card(4, NAME.BACKLOG, { outcomes = bare }),
        }
        testing.eq(findings(cmd_board.run("lint", {}, backend(cards)).output), {
            "00000001 " .. NAME.READY .. " outcome names no deciding check: bare",
            "00000003 " .. NAME.PROGRESS .. " outcome names no deciding check: bare",
        })
    end
)

testing.test("lint flags a Done card with outcomes and an open child", function()
    local fake = backend({ card(1, NAME.DONE) })
    function fake:family()
        return { children = { done = 1, total = 2 } }
    end
    testing.eq(
        findings(cmd_board.run("lint", {}, fake).output),
        { "00000001 Done 1 of 2 children open" }
    )
end)

testing.test("lint fails when the children of a card cannot be read", function()
    local fake = backend({ card(1, NAME.DONE) })
    function fake:family()
        return nil, "pomb is down"
    end
    local result = cmd_board.run("lint", {}, fake)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("pomb is down", 1, true), result.message)
end)

testing.test("lint reports a card with a v1 checklist and no outcomes as lacking them", function()
    local cards = { card(1, NAME.BACKLOG, { description = V1, outcomes = {} }) }
    local result = cmd_board.run("lint", {}, backend(cards))
    testing.eq(result.code, 1)
    testing.eq(findings(result.output), { "00000001 Backlog lacks Done when outcomes" })
end)

testing.test("lint passes a clean board with exit 0 and no code", function()
    local cards = {
        card(1, NAME.ICEBOX, { description = false, color = false, outcomes = {} }),
        card(2, NAME.DONE),
        card(3, NAME.DONE, { labels = { "discarded" }, outcomes = outcomes(0) }),
        card(4, NAME.DONE, { description = false, claimant = false }),
        card(5, NAME.BLOCKED, { labels = { "needs:human" } }),
        card(6, NAME.BLOCKED),
        card(7, NAME.PROGRESS),
        card(8, NAME.READY, { checks = { "dev test" } }),
        card(9, NAME.ICEBOX, { labels = { "needs:human" } }),
    }
    local held = {
        comments = { [cards[5].id] = { { kind = "question", body = "which?" } } },
        links = { [cards[6].id] = { { kind = "blocked_by", id = cards[8].id } } },
        children = { [cards[7].id] = 2 },
    }
    local result = cmd_board.run("lint", {}, backend(cards, held))
    testing.eq(result.output, "No findings.")
    testing.eq(result.code, nil)
    testing.eq(result.message, nil)
end)

testing.test("lint reads comments only for a Blocked card and writes nothing", function()
    local cards = {
        card(1, NAME.READY),
        card(2, NAME.BLOCKED),
        card(3, NAME.PROGRESS, { claimant = false }),
        card(4, NAME.PROGRESS),
    }
    local fake = backend(cards, { children = {} })
    cmd_board.run("lint", {}, fake)
    testing.eq(fake.calls, { "family", "family", "comments", "links", "family", "family" })
end)

testing.test("lint refuses a second card and an unknown flag", function()
    testing.eq(cmd_board.run("lint", { "00000001", "00000002" }, backend({})).code, 2)
    testing.eq(cmd_board.run("lint", { "--loud" }, backend({})).code, 2)
end)

testing.test("lint with a card reports only that card", function()
    local cards = {
        card(1, NAME.READY, { checks = {} }),
        card(2, NAME.READY),
        card(3, NAME.READY, { checks = {} }),
    }
    local result = cmd_board.run("lint", { "00000002" }, backend(cards))
    testing.eq(result.output, "No findings.")
    testing.eq(result.code, nil)
    result = cmd_board.run("lint", { "00000003", "--strict" }, backend(cards))
    testing.eq(result.code, 1)
    testing.eq(findings(result.output), { "00000003 " .. NAME.READY .. " no checks row" })
end)

testing.test("lint with a card that matches none fails", function()
    local result = cmd_board.run("lint", { "00000009" }, backend({ card(1, NAME.READY) }))
    testing.eq(result.code, 1)
    testing.ok(result.message:find("No card starts with", 1, true), result.message)
end)

testing.test("lint fails when a card's comments cannot be read", function()
    local fake = backend({ card(1, NAME.BLOCKED) })
    function fake:comments()
        return nil, "pomb is down"
    end
    local result = cmd_board.run("lint", {}, fake)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("pomb is down", 1, true), result.message)
end)

testing.test("lint fails when the comments of a Done card cannot be read", function()
    local fake = backend({ card(1, NAME.DONE) })
    function fake:comments()
        return nil, "pomb is down"
    end
    local result = cmd_board.run("lint", {}, fake)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("pomb is down", 1, true), result.message)
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
    testing.eq(code, 0, out)
    support.drop_turn_card(support.board_file(home, "mine"))
    return dev, support.board_file(home, "mine")
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
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--done-when",
        "a",
    })
    testing.eq(code, 0, out)
    local id = assert(out:match("added (%x+)"), out)
    out, code = dev({ "board", "discard", id })
    testing.eq(code, 0, out)
    local doc = assert(json.decode(assert(fs.read(path))))
    doc.cards[1].description = ""
    assert(fs.write(path, assert(json.encode(doc))))
end

testing.test("dev board lint exits 1 on a bad local board and 0 on a clean one", function()
    local dev = local_board(LOCAL)
    local out, code = dev({ "board", "lint" })
    testing.eq(code, 0, out)
    testing.eq(out, "No findings.\n")
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
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--done-when",
        "ok",
    })
    testing.eq(code, 0, out)
    out, code = dev({ "board", "lint" })
    testing.eq(code, 1, out)
    testing.ok(out:find("Backlog +over 400 words"), out)
end)

testing.test("strict holds a Done card to the v3 sections, by flag and by the config", function()
    local dev, path = local_board(LOCAL)
    bare_done_card(dev, path)
    local out, code = dev({ "board", "lint" })
    testing.eq(code, 0, out)
    out, code = dev({ "board", "lint", "--strict" })
    testing.eq(code, 1, out)
    testing.ok(out:find("Done +lacks ## Problem"), out)
    dev, path = local_board(LOCAL .. "\n[board.lint]\nstrict = true\n")
    bare_done_card(dev, path)
    out, code = dev({ "board", "lint" })
    testing.eq(code, 1, out)
    testing.ok(out:find("Done +lacks ## Change"), out)
end)

testing.test("a strict setting that is not a boolean is refused", function()
    local dev = local_board(LOCAL .. '\n[board.lint]\nstrict = "yes"\n')
    local out, code = dev({ "board", "lint" })
    testing.eq(code, 1, out)
    testing.ok(
        out:find("The `strict` setting of `[board.lint]` must be true or false.", 1, true),
        out
    )
end)

testing.test(
    "strict adds the sections to a Done card and a discarded one, and nothing else",
    function()
        local cards = {
            card(1, NAME.DONE, { description = false }),
            card(2, NAME.DONE, { description = false, labels = { "discarded" }, outcomes = {} }),
            card(3, NAME.ICEBOX, { description = false }),
        }
        testing.eq(cmd_board.run("lint", {}, backend(cards)).output, "No findings.")
        local result = cmd_board.run("lint", { "--strict" }, backend(cards))
        testing.eq(result.code, 1)
        testing.eq(findings(result.output), {
            "00000001 Done lacks ## Problem",
            "00000001 Done lacks ## Change",
            "00000001 Done lacks ## Out of scope",
            "00000002 Done lacks ## Problem",
            "00000002 Done lacks ## Change",
            "00000002 Done lacks ## Out of scope",
        })
    end
)

testing.test(
    "lint marks a finding only the owner can fix and exits 0 when only those are left",
    function()
        local cards = {
            card(1, NAME.BLOCKED, { labels = { "needs:human" }, description = "## Problem\nwhy" }),
            card(2, NAME.ICEBOX, { labels = { "needs:human" } }),
            card(3, NAME.BACKLOG),
        }
        local held = { comments = { [cards[1].id] = { { kind = "question", body = "which?" } } } }
        local result = cmd_board.run("lint", {}, backend(cards, held))
        testing.eq(result.code, nil)
        testing.eq(findings(result.output), {
            "00000001 Blocked lacks ## Change (owner)",
            "00000001 Blocked lacks ## Out of scope (owner)",
        })
        result = cmd_board.run("lint", { "--strict" }, backend(cards, held))
        testing.eq(result.code, nil)
    end
)

testing.test(
    "lint exits 1 for a missing size or a misplaced label on a needs:human card",
    function()
        local sizeless = card(1, NAME.BLOCKED, { labels = { "needs:human" }, color = false })
        local misplaced = card(2, NAME.READY, { labels = { "needs:human" } })
        local held = { comments = { [sizeless.id] = { { kind = "question", body = "which?" } } } }
        local result = cmd_board.run("lint", {}, backend({ sizeless }, held))
        testing.eq(result.code, 1)
        testing.eq(findings(result.output), { "00000001 Blocked lacks a size" })
        result = cmd_board.run("lint", {}, backend({ misplaced }))
        testing.eq(result.code, 1)
        testing.eq(
            findings(result.output),
            { "00000002 Ready needs:human outside Blocked and Icebox" }
        )
    end
)

testing.test(
    "lint lists an agent-asked needs:human card that is unsized or outside Blocked",
    function()
        local asked = { kind = "question", actor = "agent", question = { text = "which?" } }
        local sizeless = card(1, NAME.BLOCKED, { labels = { "needs:human" }, color = false })
        local misplaced = card(2, NAME.READY, { labels = { "needs:human" } })
        local both = card(3, NAME.ICEBOX, { labels = { "needs:human" }, color = false })
        local held = {
            comments = {
                [sizeless.id] = { asked },
                [misplaced.id] = { asked },
                [both.id] = { asked },
            },
        }
        local result = cmd_board.run("lint", {}, backend({ sizeless, misplaced, both }, held))
        testing.eq(result.code, 1)
        testing.eq(findings(result.output), {
            "00000001 Blocked lacks a size",
            "00000001 Blocked agent question on an unsized card",
            "00000002 Ready needs:human outside Blocked and Icebox",
            "00000002 Ready agent question outside Blocked",
            "00000003 Icebox agent question on an unsized card",
            "00000003 Icebox agent question outside Blocked",
        })
    end
)

testing.test("lint leaves an owner idea, an answered question and a planned ask alone", function()
    local owner = { actor = "human", question = { text = "which?" } }
    local answered = { actor = "agent", question = { text = "which?", answer = { choice = 1 } } }
    local asked = { kind = "question", actor = "agent", question = { text = "which?" } }
    local cards = {
        card(1, NAME.ICEBOX, { labels = { "needs:human" }, color = false, description = false }),
        card(2, NAME.ICEBOX, { labels = { "needs:human" }, color = false }),
        card(3, NAME.BLOCKED, { labels = { "needs:human" } }),
    }
    local held = {
        comments = {
            [cards[1].id] = {},
            [cards[2].id] = { owner, answered },
            [cards[3].id] = { asked },
        },
    }
    local result = cmd_board.run("lint", {}, backend(cards, held))
    testing.eq(result.output, "No findings.")
end)

testing.test("lint exits 1 when an owner finding sits beside an agent finding", function()
    local cards = {
        card(1, NAME.BLOCKED, { labels = { "needs:human" }, description = "## Problem\nwhy" }),
        card(2, NAME.READY, { checks = {} }),
    }
    local held = { comments = { [cards[1].id] = { { kind = "question", body = "which?" } } } }
    local result = cmd_board.run("lint", {}, backend(cards, held))
    testing.eq(result.code, 1)
    testing.eq(findings(result.output), {
        "00000001 Blocked lacks ## Change (owner)",
        "00000001 Blocked lacks ## Out of scope (owner)",
        "00000002 Ready no checks row",
    })
end)

local function done_card_with(builder, reviewer, opts)
    -- Default the optional fields
    local merged = { column = NAME.DONE, labels = {}, records = {} }
    for key, value in pairs(opts or {}) do
        merged[key] = value
    end
    opts = merged

    -- Add a card with one outcome
    local dev, path = local_board(LOCAL)
    local out, code = dev({
        "board",
        "add",
        "Card",
        "--size",
        "1",
        "--problem",
        "x",
        "--change",
        "y",
        "--out-of-scope",
        "z",
        "--done-when",
        "a " .. board.JUDGEMENT,
    })
    testing.eq(code, 0, out)

    -- Move the card to its column and tick its outcome when that column is Done
    local doc = assert(json.decode(assert(fs.read(path))))
    local target = doc.cards[1]
    for _, column in ipairs(doc.columns) do
        if column.name == opts.column then
            target.column_id = column.id
            target.outcomes[1].done = column.is_done
        end
    end
    target.checks = { "dev test" }
    target.labels = opts.labels

    -- Write the claim and review records, then lint
    local at = "2026-11-14T00:00:00Z"
    target.comments = {
        { id = "c1", who = "agent", at = at, body = board.claim_record(builder) },
        {
            id = "c2",
            who = "agent",
            at = at,
            body = review.record(review.Kind.CODE, reviewer, REV, review.Verdict.CLEAN),
        },
    }
    for _, body in ipairs(opts.records) do
        target.comments[#target.comments + 1] =
            { id = "c" .. (#target.comments + 1), who = "agent", at = at, body = body }
    end
    assert(fs.write(path, assert(json.encode(doc))))
    return dev({ "board", "lint" })
end

testing.test("lint lists each name that built and reviewed a Done card once, sorted", function()
    local out, code = done_card_with("project-run/zzzz", "project-run/zzzz", {
        records = {
            board.claim_record("project-run/aaaa"),
            review.record(review.Kind.CODE, "project-run/aaaa", REV, review.Verdict.CLEAN),
            review.record(review.Kind.CODE, "project-run/zzzz", REV, review.Verdict.MINOR),
        },
    })
    testing.eq(code, 1, out)
    testing.ok(out:find("same name: project%-run/aaaa, project%-run/zzzz\n"), out)
end)

testing.test("lint flags a Done card whose builder also reviewed it", function()
    local out, code = done_card_with("project-run/aaaa", "project-run/aaaa")
    testing.eq(code, 1, out)
    testing.ok(out:find("Done +built and reviewed by the same name: project%-run/aaaa"), out)
end)

testing.test("lint flags a Done card whose builder also ticked an outcome", function()
    local out, code = done_card_with("project-run/aaaa", "project-run/rrrr", {
        records = { board.tick_record("project-run/aaaa", 1) },
    })
    testing.eq(code, 1, out)
    testing.ok(out:find("built and verified by the same name: project%-run/aaaa"), out)
end)

testing.test("lint stays clean for a verifier who never built the Done card", function()
    local out, code = done_card_with("project-run/aaaa", "project-run/rrrr", {
        records = { board.tick_record("project-run/vvvv", 1) },
    })
    testing.eq(code, 0, out)
    testing.eq(out, "No findings.\n")
end)

testing.test("lint leaves a card still in Review with the same builder and reviewer", function()
    local out, code =
        done_card_with("project-run/aaaa", "project-run/aaaa", { column = NAME.REVIEW })
    testing.eq(code, 0, out)
    testing.eq(out, "No findings.\n")
end)

testing.test("lint leaves a discarded Done card with the same builder and reviewer", function()
    local out, code =
        done_card_with("project-run/aaaa", "project-run/aaaa", { labels = { board.DISCARDED } })
    testing.eq(code, 0, out)
    testing.eq(out, "No findings.\n")
end)

testing.test("lint passes a Done card whose builder and reviewers differ", function()
    local out, code = done_card_with("project-run/aaaa", "dotfiles/code-examiner/aaaa")
    testing.eq(code, 0, out)
    testing.eq(out, "No findings.\n")
end)

testing.test("lint leaves the landing turn card with no findings", function()
    local cards = {
        card(1, NAME.DONE, {
            name = board.TURN_NAME,
            color = false,
            description = false,
            claimant = false,
            outcomes = {},
        }),
    }
    local result = cmd_board.run("lint", {}, backend(cards))
    testing.eq(result.output, "No findings.")
    testing.eq(result.code, nil)
end)

testing.test("lint skips the size of a discarded Done card and keeps it for another", function()
    local discarded = {
        card(1, NAME.DONE, { labels = { board.DISCARDED }, color = false, outcomes = {} }),
    }
    local result = cmd_board.run("lint", {}, backend(discarded))
    testing.eq(result.output, "No findings.")
    testing.eq(result.code, nil)
    local kept = { card(2, NAME.DONE, { color = false }) }
    result = cmd_board.run("lint", {}, backend(kept))
    testing.eq(result.code, 1)
    testing.eq(findings(result.output), { "00000002 Done lacks a size" })
end)
