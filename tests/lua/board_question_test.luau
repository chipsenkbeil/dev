local testing = require("dev.testing")
local board = require("dev.board")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local Column = support.Column

local PLANNED = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone"
local JUDGED = "done (reviewer judgement)"
local AGENT = board.ACTOR.AGENT
local Kind = board.NoteKind
local ASKED = { id = "qqqqqqqq-1", kind = Kind.QUESTION, actor = AGENT, body = "which one?" }
local DECIDED = { id = "dddddddd-1", kind = Kind.DECISION, actor = AGENT, body = "this one" }
local OWNER = { id = "hhhhhhhh-1", actor = board.ACTOR.HUMAN, body = "go" }
local STATUS = { id = "ssssssss-1", kind = Kind.STATUS, actor = AGENT, body = "working" }

testing.test("open_question finds the newest question nothing follows", function()
    testing.eq(board.open_question({ STATUS, ASKED, STATUS }), ASKED)
end)

testing.test("open_question is nil when a decision note follows the question", function()
    testing.eq(board.open_question({ ASKED, DECIDED }), nil)
end)

testing.test("open_question is nil when an owner comment follows the question", function()
    testing.eq(board.open_question({ ASKED, OWNER }), nil)
end)

testing.test("open_question is nil when the question carries an answer", function()
    local answered = { id = "qqqqqqqq-2", question = { text = "which?", answer = { choice = 1 } } }
    testing.eq(board.open_question({ answered }), nil)
end)

testing.test("open_question holds a structured question with no answer", function()
    local open = { id = "qqqqqqqq-3", question = { text = "which?" } }
    testing.eq(board.open_question({ open }), open)
end)

testing.test("open_question is nil with no comments", function()
    testing.eq(board.open_question({}), nil)
end)

local function setup()
    local root = support.sandbox(
        { [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "mine"\n' },
        {}
    )
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(
        fs.write(
            home .. "/.config/dev/config.toml",
            '[board.pomb]\nurl = "https://pomb.example"\ntoken = "pass:secrets/worker/token/pomb"\n'
        )
    )
    local function dev(args)
        return support.dev(root, args, {
            env = {
                HOME = home,
                XDG_STATE_HOME = home .. "/state",
                CLAUDE_SESSION_ID = "one",
                DEV_PASS_LOCK = home .. "/pass.lock",
            },
        })
    end
    local out, code = dev({ "board", "init" })
    testing.eq(code, 0, out)
    local tracked = root .. "/.dev/board.json"
    support.drop_turn_card(fs.exists(tracked) and tracked or support.board_file(home, "mine"))
    return dev, fs.exists(tracked) and tracked or support.board_file(home, "mine")
end

local function planned_card(dev, column)
    local out, code = dev({
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
    })
    testing.eq(code, 0, out)
    return assert(out:match("added (%x+)"), out)
end

local function comment_on(path, comments)
    local doc = assert(json.decode(assert(fs.read(path))))
    doc.cards[1].comments = comments
    assert(fs.write(path, assert(json.encode(doc))))
end

local function stored(comment, who)
    return {
        id = comment.id,
        who = who,
        at = "2026-11-19T00:00:00Z",
        body = comment.body,
        kind = comment.kind,
    }
end

testing.test("move to Ready refuses a card with an unanswered question and names it", function()
    local dev, path = setup()
    local id = planned_card(dev, Column.BACKLOG)
    comment_on(path, { stored(ASKED, AGENT) })
    local out, code = dev({ "board", "move", id, Column.READY })
    testing.eq(code, 1, out)
    testing.ok(out:find("unanswered question, comment qqqqqqqq", 1, true), out)
end)

testing.test("move to Ready passes once a decision note follows the question", function()
    local dev, path = setup()
    local id = planned_card(dev, Column.BACKLOG)
    comment_on(path, { stored(ASKED, AGENT), stored(DECIDED, AGENT) })
    local out, code = dev({ "board", "move", id, Column.READY })
    testing.eq(code, 0, out)
end)

testing.test("next skips a Ready card whose question is unanswered", function()
    local dev, path = setup()
    planned_card(dev, Column.READY)
    comment_on(path, { stored(ASKED, AGENT) })
    local out = dev({ "board", "next" })
    testing.eq(out, "No ready cards.\n")
    comment_on(path, { stored(ASKED, AGENT), stored(STATUS, AGENT), stored(DECIDED, AGENT) })
    out = dev({ "board", "next" })
    testing.ok(out:find("Card", 1, true), out)
end)
