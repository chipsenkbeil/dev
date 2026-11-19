local testing = require("dev.testing")
local fs = require("dev.fs")
local support = require("support")

local Column = support.Column

local PLANNED = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone"

local function dev(root, home, args)
    return support.dev(root, args, {
        env = {
            HOME = home,
            XDG_STATE_HOME = home .. "/state",
            CLAUDE_SESSION_ID = "one",
            DEV_PASS_LOCK = home .. "/pass.lock",
        },
    })
end

local function local_board()
    local root = support.sandbox(
        { [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "mine"\n' },
        {}
    )
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    local out, code = dev(root, home, { "board", "init" })
    testing.eq(code, 0, out)
    local tracked = root .. "/.dev/board.json"
    support.drop_turn_card(fs.exists(tracked) and tracked or support.board_file(home, "mine"))
    return root, home
end

local function added(out)
    return assert(out:match("added (%x+)"), out)
end

testing.test("stale_lists_epic_with_every_child_done", function()
    local root, home = local_board()
    local child = added((dev(root, home, {
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
    local epic = added((dev(root, home, {
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
    dev(root, home, { "board", "epic", epic })
    dev(root, home, { "board", "link", child, "parent", epic })
    local out = dev(root, home, { "board", "stale" })
    testing.ok(not out:find("ready to close", 1, true), out)
    dev(root, home, { "board", "outcome", child, "--tick", "1", "--as", "r/reviewer" })
    dev(root, home, { "board", "move", child, Column.DONE })
    out = dev(root, home, { "board", "stale" })
    testing.ok(out:find("epic with every child Done, ready to close:\n", 1, true), out)
    testing.ok(out:find(epic, 1, true), out)
end)
