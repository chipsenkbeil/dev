local testing = require("dev.testing")
local fs = require("dev.fs")
local json = require("dev.json")
local pomb = require("dev.board.pomb")
local support = require("support")

local ID = "aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa"

local function local_board()
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
    local dev, card = local_board()
    local out, code = dev({ "board", "due", card, "2027-01-21" })
    testing.eq(code, 0, out)
    testing.eq(out, "set " .. card .. " due 2027-01-21\n")
    out = dev({ "board", "show", card })
    testing.ok(out:find("\ndue: 2027-01-21\n", 1, true), out)
    out, code = dev({ "board", "due", card, "--clear" })
    testing.eq(code, 0, out)
    testing.eq(out, "cleared " .. card .. " due\n")
    out = dev({ "board", "show", card })
    testing.ok(not out:find("due:", 1, true), out)
end)

testing.test("due refuses a date that does not exist and a call with no date", function()
    local dev, card = local_board()
    for _, bad in ipairs({ "2027-02-30", "2027-1-5", "soon", "2027-13-01" }) do
        local out, code = dev({ "board", "due", card, bad })
        testing.eq(code, 2, out)
    end
    local out, code = dev({ "board", "due", card })
    testing.eq(code, 2, out)
    out, code = dev({ "board", "due", card, "2027-01-21", "--clear" })
    testing.eq(code, 2, out)
end)

testing.test("a Pomb card sends its due date as a bare date and null to clear it", function()
    local sent = {}
    local backend = pomb_backend(sent)
    testing.eq(backend:set_due(ID, "2027-01-21", 4), true)
    testing.eq(sent[1], { "PATCH", "/api/tasks/" .. ID, { due_at = "2027-01-21" }, 4 })
    testing.eq(backend:set_due(ID, nil), true)
    testing.eq(sent[2][3].due_at, json.null)
end)

testing.test("a Pomb card reads its due date as the day of due_at", function()
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
    local card = backend:__card({ id = ID, name = "x", due_at = "2027-01-21T00:00:00Z" })
    testing.eq(card.due, "2027-01-21")
    card = backend:__card({ id = ID, name = "x", due_at = json.null })
    testing.eq(card.due, nil)
end)
