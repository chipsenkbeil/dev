local ffi = require("ffi")

local testing = require("dev.testing")
local board = require("dev.board")
local claims = require("dev.board.claims")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local localboard = require("dev.board.localboard")
local runner = require("dev.board.runner")
local store = require("dev.board.store")
local support = require("support")
local turn = require("dev.board.turn")
local wiring = require("dev.board.wiring")

local WAIT_SECONDS = 20
local HOLD_SECONDS = 1000
local TOLERANCE_SECONDS = 0.001

local clock

local function board_home()
    -- A project whose board is local and named mine
    local root = support.sandbox({
        [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "mine"\n',
    }, {})

    -- A private home with an empty user config
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    assert(fs.write(home .. "/.config/dev/config.toml", ""), "write failed")

    -- A board with no turn card, so the first asker makes its own
    local out, code = support.dev(root, { "board", "init" }, {
        env = { HOME = home, XDG_STATE_HOME = home .. "/state" },
    })
    assert(code == 0, out)
    support.drop_turn_card(support.board_file(home, "mine"))
    return home
end

local function backend_at(home)
    -- The state directory the board and the turn read
    ffi.C.setenv("XDG_STATE_HOME", home .. "/state", 1)

    -- A clock that only the naps move
    clock = os.time()
    store.now = function()
        return clock
    end

    -- The local board with the default stages
    local backend = localboard.new({
        name = "mine",
        path = support.board_file(home, "mine"),
        private = true,
    })
    backend.stages = board.stages(nil, {})
    return backend
end

local function waiting(run)
    -- A lease long enough that the holder never loses the turn to the fake clock
    local lease = turn.LEASE_SECONDS
    local nap = dev_os.nap
    local naps = {}
    turn.LEASE_SECONDS = HOLD_SECONDS

    -- A nap that records its length and moves the clock instead of sleeping
    dev_os.nap = function(seconds)
        naps[#naps + 1] = seconds
        clock = clock + seconds
    end

    -- The run, with both patches undone before a failure surfaces
    local ok, err = pcall(run)
    dev_os.nap = nap
    turn.LEASE_SECONDS = lease
    assert(ok, err)
    return naps
end

local function total(naps)
    local sum = 0
    for _, seconds in ipairs(naps) do
        sum = sum + seconds
    end
    return sum
end

local function waiter(backend, seconds)
    local id = assert(backend:add("work", board.DEFAULT_NAMES.review, {})).id
    return {
        backend = backend,
        name = "beta",
        id = id,
        short = id:sub(1, board.MIN_PREFIX),
        wait = seconds,
    }
end

testing.test("await_turn sleeps no longer than its wait and looks once at the deadline", function()
    -- A waiter whose card reads are counted
    local backend = backend_at(board_home())
    local opts = waiter(backend, WAIT_SECONDS)
    local looks = 0
    local card = backend.card
    function backend:card(id)
        if id == opts.id then
            looks = looks + 1
        end
        return card(self, id)
    end

    -- A wait on a turn that another agent holds the whole time
    local hold, message
    local naps = waiting(function()
        assert(turn.take(backend, "alpha", "aaaa1111"))
        hold, message = wiring.await_turn(opts)
    end)

    -- The naps fill the wait and no more, with one look per nap and one at the deadline
    testing.eq(hold, nil)
    testing.ok(message:find("held by alpha", 1, true), message)
    testing.ok(math.abs(total(naps) - WAIT_SECONDS) < TOLERANCE_SECONDS, total(naps))
    testing.eq(looks, #naps + 1)
end)

testing.test("await_turn leaves the queue when its wait ends", function()
    -- A waiter that gives up on a held turn
    local backend = backend_at(board_home())
    local opts = waiter(backend, WAIT_SECONDS)
    local first
    waiting(function()
        first = assert(turn.take(backend, "alpha", "aaaa1111"))
        wiring.await_turn(opts)
    end)

    -- The next asker takes the freed turn, so the waiter left the line
    turn.release(backend, first)
    local third = turn.take(backend, "gamma", "cccc3333")
    testing.ok(third, "the waiter that gave up kept its place in the line")
end)

testing.test("await_turn with a wait of 0 asks once and never sleeps", function()
    -- A waiter that asks for no wait on a held turn
    local backend = backend_at(board_home())
    local opts = waiter(backend, 0)
    local hold, message
    local first
    local naps = waiting(function()
        first = assert(turn.take(backend, "alpha", "aaaa1111"))
        hold, message = wiring.await_turn(opts)
    end)

    -- It is refused at once and sleeps never
    testing.eq(hold, nil)
    testing.ok(message:find("held by alpha", 1, true), message)
    testing.eq(naps, {})

    -- It joined no line, so the next asker takes the freed turn
    turn.release(backend, first)
    testing.ok(turn.take(backend, "gamma", "cccc3333"), "a wait of 0 joined the line")
end)

testing.test("a renewal keeps the loop for the longer of the cap and the row's seconds", function()
    local home = board_home()
    backend_at(home)
    local card = { id = "cccc3333", size = "2 Pomodori", claimant = "dotfiles/a" }
    local ticks
    local stub = {
        claim = function(_, _, _, opts)
            return opts.fence
        end,
        keepalive = function(_, _, _, count)
            ticks = count
            return 0
        end,
    }
    local cases = {
        { seconds = nil, ticks = 20 },
        { seconds = 600, ticks = 20 },
        { seconds = 7200, ticks = 24 },
        { seconds = 7201, ticks = 25 },
    }
    for _, case in ipairs(cases) do
        assert(claims.write({ card = card.id, fence = 3 }))
        testing.eq(runner.renew_claim(stub, card, "dotfiles/a", case.seconds), nil)
        testing.eq(ticks, case.ticks, tostring(case.seconds))
    end
end)

local function claim_stub(fails)
    local stub = { released = 0 }
    function stub:claim(_, _, opts)
        return (opts.fence or 0) + 1
    end
    function stub:comments()
        if fails == "comments" then
            return nil, "pomb is down"
        end
        return {}
    end
    function stub:note()
        if fails == "note" then
            return nil, "note refused"
        end
        return true
    end
    function stub:release()
        self.released = self.released + 1
        return true
    end
    function stub:keepalive()
        return 0
    end
    return stub
end

testing.test("take keeps a renewed claim when the comments cannot be read", function()
    backend_at(board_home())
    local card = { id = "cccc3333", size = "1 Pomodoro", claimant = "dotfiles/a" }
    assert(claims.write({ card = card.id, fence = 3 }))
    local stub = claim_stub("comments")
    local result, fence = runner.claim_card(stub, card, "dotfiles/a")
    testing.eq(result.code, nil)
    testing.eq(fence, 4)
    testing.eq(stub.released, 0)
    testing.ok(result.output:find("pomb is down", 1, true), result.output)
end)

testing.test("take releases a first claim when the note or the comments fail", function()
    backend_at(board_home())
    for _, fails in ipairs({ "note", "comments" }) do
        local card = { id = "cccc3333", size = "1 Pomodoro" }
        local stub = claim_stub(fails)
        local result, fence = runner.claim_card(stub, card, "dotfiles/a")
        testing.eq(result.code, 1)
        testing.eq(fence, nil)
        testing.eq(stub.released, 1)
        testing.ok(result.message:find("was dropped", 1, true), result.message)
    end
end)
