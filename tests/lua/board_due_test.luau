local testing = require("@dev/testing")
local fs = require("@dev/fs")
local json = require("@dev/json")
local pomb = require("@dev/board/pomb")
local support = require("./support")

local ID = "aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa"

local function local_board()
    -- Make a project on a local board and a home with a Pomb config
    local root = support.sandbox({
        [".dev/config.toml"] = table.concat({
            "[board]",
            'backend = "local"',
            'name = "mine"',
            "",
        }, "\n"),
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(fs.write(
        home .. "/.config/dev/config.toml",
        table.concat({
            "[board.pomb]",
            'url = "https://pomb.example"',
            'token = "pass:secrets/worker/token/pomb"',
            "",
        }, "\n")
    ))

    -- Run dev in that project as one session
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

    -- Start the board with no turn card
    local out, code = dev({ "board", "init" })
    testing.eq(code, 0, out)
    local tracked = root .. "/.dev/board.json"
    support.drop_turn_card(fs.exists(tracked) and tracked or support.board_file(home, "mine"))

    -- Add the card the tests give a due date
    out = dev({
        "board",
        "add",
        "Reminder",
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
    return dev, assert(out:match("added (%x+)"), out)
end

local function pomb_backend(sent)
    local backend = assert(pomb.new({ url = "https://pomb.example", name = "mine", token = "t" }))
    function backend:__request(method, path, body, fence)
        sent[#sent + 1] = { method, path, body, fence }
        return {}
    end
    return backend
end

testing.test("a local card stores its due date and show prints it only while set", function()
    -- Make a board with one card
    local dev, card = local_board()

    -- Set the due date
    local out, code = dev({ "board", "due", card, "2027-01-21" })
    testing.eq(code, 0, out)
    testing.eq(out, "set " .. card .. " due 2027-01-21\n")

    -- Show the due date while it is set
    out = dev({ "board", "show", card })
    testing.ok(out:find("\ndue: 2027-01-21\n", 1, true), out)

    -- Clear the due date and show nothing of it
    out, code = dev({ "board", "due", card, "--clear" })
    testing.eq(code, 0, out)
    testing.eq(out, "cleared " .. card .. " due\n")
    out = dev({ "board", "show", card })
    testing.ok(not out:find("due:", 1, true), out)
end)

testing.test("due with no date shows the due date or says the card has none", function()
    -- Make a board with one card
    local dev, card = local_board()

    -- Say that a card with no date has none
    local out, code = dev({ "board", "due", card })
    testing.eq(code, 0, out)
    testing.eq(out, card .. " has no due date\n")

    -- Give the card a date
    dev({ "board", "due", card, "2027-01-21" })

    -- Show the date of a card that has one
    out, code = dev({ "board", "due", card })
    testing.eq(code, 0, out)
    testing.eq(out, card .. " due 2027-01-21\n")
end)

testing.test("due refuses a date that does not exist and a date with --clear", function()
    local dev, card = local_board()
    for _, bad in ipairs({ "2027-02-30", "2027-1-5", "soon", "2027-13-01" }) do
        local out, code = dev({ "board", "due", card, bad })
        testing.eq(code, 2, out)
    end
    local out, code = dev({ "board", "due", card, "2027-01-21", "--clear" })
    testing.eq(code, 2, out)
end)

testing.test("a Pomb card sends its due date as a bare date and null to clear it", function()
    -- Record the requests of a Pomb backend
    local sent = {}
    local backend = pomb_backend(sent)

    -- Send a date as a bare date under the fence
    testing.eq(backend:set_due(ID, "2027-01-21", 4), true)
    testing.eq(sent[1], { "PATCH", "/api/tasks/" .. ID, { due_at = "2027-01-21" }, 4 })

    -- Send null to clear it
    testing.eq(backend:set_due(ID, nil), true)
    testing.eq(sent[2][3].due_at, json.null)
end)

testing.test("a Pomb card reads its due date as the day of due_at", function()
    -- Stub the lookups a card read makes
    local backend = pomb_backend({})
    backend.__colors = {}
    backend.__values = {}
    function backend:__column_name()
        return support.COLUMN_NAME.READY
    end
    function backend:__lane_name()
        return nil
    end
    function backend:__column_done()
        return false
    end

    -- Read the day of a due timestamp
    local card = backend:__card({ id = ID, name = "x", due_at = "2027-01-21T00:00:00Z" })
    testing.eq(card.due, "2027-01-21")

    -- Read no due date from a null
    card = backend:__card({ id = ID, name = "x", due_at = json.null })
    testing.eq(card.due, nil)
end)
