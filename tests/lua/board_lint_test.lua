local testing = require("dev.testing")
local board = require("dev.board")
local cmd_board = require("dev.cmd.board")
local fs = require("dev.fs")
local json = require("dev.json")
local review = require("dev.board.review")
local support = require("support")

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

testing.test("lint reports one line per rule a card breaks and exits 1", function()
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

testing.test(
    "lint flags an empty Change or Out of scope and a Change: line under Problem",
    function()
        local empty_change = "## Problem\nwhy\n\n## Change\n\n## Out of scope\nnone"
        local line_in_problem =
            "## Problem\nwhy\nChange: rewrite it\n\n## Change\nx\n\n## Out of scope\nn"
        local scope_in_problem =
            "## Problem\nwhy\nOut of scope: docs\n\n## Change\nx\n\n## Out of scope\nn"
        local cards = {
            card(1, "Backlog", { description = empty_change, outcomes = outcomes(0) }),
            card(2, "Ready", { description = line_in_problem, outcomes = outcomes(0) }),
            card(3, "Icebox", { description = empty_change, outcomes = {} }),
            card(4, "Backlog", { description = scope_in_problem, outcomes = outcomes(0) }),
            card(5, "Done", { description = empty_change }),
        }
        local result = cmd_board.run("lint", {}, backend(cards))
        testing.eq(result.code, 1)
        testing.eq(findings(result.output), {
            "00000001 Backlog lacks text under ## Change",
            "00000002 Ready lacks a Problem free of Change: and Out of scope: lines",
            "00000004 Backlog lacks a Problem free of Change: and Out of scope: lines",
        })
        result = cmd_board.run("lint", { "--strict" }, backend({ cards[5] }))
        testing.eq(findings(result.output), { "00000005 Done lacks text under ## Change" })
    end
)

testing.test("lint holds an epic to 1 to 3 outcomes and to its children", function()
    local cards = {
        card(1, "Backlog", { outcomes = {} }),
        card(2, "Done", { outcomes = {} }),
        card(3, "Done", { outcomes = {} }),
        card(4, "Backlog", { outcomes = {} }),
        card(5, "Backlog", {
            outcomes = {
                { id = "o1", name = "a" },
                { id = "o2", name = "b" },
                { id = "o3", name = "c" },
                { id = "o4", name = "d" },
            },
        }),
        card(6, "Backlog", { outcomes = outcomes(2) }),
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
        "00000001 Backlog lacks Done when outcomes",
        "00000002 Done lacks Done when outcomes",
        "00000002 Done 1 of 2 children open",
        "00000003 Done lacks Done when outcomes",
        "00000004 Backlog lacks Done when outcomes",
        "00000005 Backlog lacks 1 to 3 Done when outcomes for an epic, not 4",
    })
end)

testing.test("lint lets a Done epic with every child Done close without outcomes", function()
    local cards = { card(1, support.COLUMN_NAME.DONE, { outcomes = {} }) }
    local held = { children = { [cards[1].id] = 2 } }
    local fake = backend(cards, held)
    function fake:family(id)
        return { children = { done = 2, total = held.children[id] } }
    end
    local result = cmd_board.run("lint", {}, fake)
    testing.eq(result.output, "no findings")
end)

testing.test("lint gives an epic no claimant exemption", function()
    local cards = {
        card(1, "In Progress", { claimant = false, outcomes = outcomes(2) }),
        card(2, "In Progress", { claimant = false, outcomes = outcomes(3) }),
    }
    local fake = backend(cards, { children = { [cards[1].id] = 2 } })
    testing.eq(findings(cmd_board.run("lint", {}, fake).output), {
        "00000001 In Progress in progress with no claimant",
        "00000002 In Progress in progress with no claimant",
    })
end)

testing.test("lint asks a card without children for a checks row and an epic for none", function()
    local cards = {
        card(1, "In Progress", { outcomes = outcomes(2), checks = {} }),
        card(2, "In Progress", { outcomes = outcomes(3), checks = {} }),
    }
    local fake = backend(cards, { children = { [cards[1].id] = 2 } })
    testing.eq(
        findings(cmd_board.run("lint", {}, fake).output),
        { "00000002 In Progress no checks row" }
    )
end)

testing.test(
    "lint flags an outcome that names no deciding check in Ready and In Progress",
    function()
        local named = { { id = "o1", name = "x " .. board.CHECK_OPEN .. "test)", done = false } }
        local bare = { { id = "o1", name = "bare", done = false } }
        local cards = {
            card(1, support.COLUMN_NAME.READY, { outcomes = bare, claimant = false }),
            card(2, support.COLUMN_NAME.READY, { outcomes = named, claimant = false }),
            card(3, support.COLUMN_NAME.PROGRESS, { outcomes = bare }),
            card(4, support.COLUMN_NAME.BACKLOG, { outcomes = bare }),
        }
        testing.eq(findings(cmd_board.run("lint", {}, backend(cards)).output), {
            "00000001 " .. support.COLUMN_NAME.READY .. " outcome names no deciding check: bare",
            "00000003 " .. support.COLUMN_NAME.PROGRESS .. " outcome names no deciding check: bare",
        })
    end
)

testing.test("lint flags a Done card with outcomes and an open child", function()
    local fake = backend({ card(1, "Done") })
    function fake:family()
        return { children = { done = 1, total = 2 } }
    end
    testing.eq(
        findings(cmd_board.run("lint", {}, fake).output),
        { "00000001 Done 1 of 2 children open" }
    )
end)

testing.test("lint fails when the children of a card cannot be read", function()
    local fake = backend({ card(1, "Done") })
    function fake:family()
        return nil, "pomb is down"
    end
    local result = cmd_board.run("lint", {}, fake)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("pomb is down", 1, true), result.message)
end)

testing.test("lint passes a clean board with exit 0 and no code", function()
    local cards = {
        card(1, "Icebox", { description = false, color = false, outcomes = {} }),
        card(2, "Done", { description = V1, outcomes = {} }),
        card(3, "Done", { labels = { "discarded" }, outcomes = outcomes(0) }),
        card(4, "Done", { description = false, claimant = false }),
        card(5, "Blocked", { labels = { "needs:human" } }),
        card(6, "Blocked"),
        card(7, "In Progress"),
        card(8, "Ready", { checks = { "dev test" } }),
        card(9, "Icebox", { labels = { "needs:human" } }),
    }
    local held = {
        comments = { [cards[5].id] = { { kind = "question", body = "which?" } } },
        links = { [cards[6].id] = { { kind = "blocked_by", id = cards[8].id } } },
        children = { [cards[7].id] = 2 },
    }
    local result = cmd_board.run("lint", {}, backend(cards, held))
    testing.eq(result.output, "no findings")
    testing.eq(result.code, nil)
    testing.eq(result.message, nil)
end)

testing.test("lint reads comments only for a Blocked card and writes nothing", function()
    local cards = {
        card(1, "Ready"),
        card(2, "Blocked"),
        card(3, "In Progress", { claimant = false }),
        card(4, "In Progress"),
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
        card(1, support.COLUMN_NAME.READY, { checks = {} }),
        card(2, support.COLUMN_NAME.READY),
        card(3, support.COLUMN_NAME.READY, { checks = {} }),
    }
    local result = cmd_board.run("lint", { "00000002" }, backend(cards))
    testing.eq(result.output, "no findings")
    testing.eq(result.code, nil)
    result = cmd_board.run("lint", { "00000003", "--strict" }, backend(cards))
    testing.eq(result.code, 1)
    testing.eq(
        findings(result.output),
        { "00000003 " .. support.COLUMN_NAME.READY .. " no checks row" }
    )
end)

testing.test("lint with a card that matches none fails", function()
    local result =
        cmd_board.run("lint", { "00000009" }, backend({ card(1, support.COLUMN_NAME.READY) }))
    testing.eq(result.code, 1)
    testing.ok(result.message:find("No card starts with", 1, true), result.message)
end)

testing.test("lint fails when a card's comments cannot be read", function()
    local fake = backend({ card(1, "Blocked") })
    function fake:comments()
        return nil, "pomb is down"
    end
    local result = cmd_board.run("lint", {}, fake)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("pomb is down", 1, true), result.message)
end)

testing.test("lint fails when the comments of a Done card cannot be read", function()
    local fake = backend({ card(1, support.COLUMN_NAME.DONE) })
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
    testing.eq(out, "no findings\n")
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
    testing.ok(out:find("[board.lint] strict must be true or false", 1, true), out)
end)

testing.test(
    "strict adds the sections to a Done card and a discarded one, and nothing else",
    function()
        local cards = {
            card(1, "Done", { description = false }),
            card(2, "Done", { description = false, labels = { "discarded" }, outcomes = {} }),
            card(3, "Icebox", { description = false }),
        }
        testing.eq(cmd_board.run("lint", {}, backend(cards)).output, "no findings")
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
            card(1, "Blocked", { labels = { "needs:human" }, description = "## Problem\nwhy" }),
            card(2, "Icebox", { labels = { "needs:human" } }),
            card(3, "Backlog"),
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
        local sizeless = card(1, "Blocked", { labels = { "needs:human" }, color = false })
        local misplaced = card(2, "Ready", { labels = { "needs:human" } })
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

testing.test("lint exits 1 when an owner finding sits beside an agent finding", function()
    local cards = {
        card(1, "Blocked", { labels = { "needs:human" }, description = "## Problem\nwhy" }),
        card(2, "Ready", { checks = {} }),
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
    local merged = { column = support.COLUMN_NAME.DONE, labels = {}, records = {} }
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
    local rev = { commit = "abc123", change = "xyz" }
    target.comments = {
        { id = "c1", who = "agent", at = at, body = board.claim_record(builder) },
        {
            id = "c2",
            who = "agent",
            at = at,
            body = review.record(review.KIND.CODE, reviewer, rev, review.VERDICT.CLEAN),
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
    local rev = { commit = "abc123", change = "xyz" }
    local out, code = done_card_with("project-run/zzzz", "project-run/zzzz", {
        records = {
            board.claim_record("project-run/aaaa"),
            review.record(review.KIND.CODE, "project-run/aaaa", rev, review.VERDICT.CLEAN),
            review.record(review.KIND.CODE, "project-run/zzzz", rev, review.VERDICT.MINOR),
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

testing.test("lint leaves a card still in Review with the same builder and reviewer", function()
    local out, code = done_card_with(
        "project-run/aaaa",
        "project-run/aaaa",
        { column = support.COLUMN_NAME.REVIEW }
    )
    testing.eq(code, 0, out)
    testing.eq(out, "no findings\n")
end)

testing.test("lint leaves a discarded Done card with the same builder and reviewer", function()
    local out, code =
        done_card_with("project-run/aaaa", "project-run/aaaa", { labels = { board.DISCARDED } })
    testing.eq(code, 0, out)
    testing.eq(out, "no findings\n")
end)

testing.test("lint passes a Done card whose builder and reviewers differ", function()
    local out, code = done_card_with("project-run/aaaa", "dotfiles/code-examiner/aaaa")
    testing.eq(code, 0, out)
    testing.eq(out, "no findings\n")
end)
