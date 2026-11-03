local ffi = require("ffi")

local t = require("testing")
local board = require("dev.board")
local commands = require("dev.cmd.board")
local devos = require("dev.os")
local fs = require("dev.fs")
local localboard = require("dev.board.localboard")
local store = require("dev.board.store")
local support = require("support")
local turn = require("dev.board.turn")

local LEASE_SECONDS = 3
local PAST_LEASE_SECONDS = 4
local PAST_HOLD_SECONDS = 2

local clock

local function advance(seconds)
    clock = clock + seconds
end

local function board_home()
    local root = support.sandbox({
        [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "mine"\n',
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    assert(fs.write(home .. "/.config/dev/config.toml", ""), "write failed")
    local out, code = support.dev(root, { "board", "init" }, {
        env = { HOME = home, XDG_STATE_HOME = home .. "/state" },
    })
    assert(code == 0, out)
    return home
end

local function backend_at(home)
    ffi.C.setenv("XDG_STATE_HOME", home .. "/state", 1)
    clock = os.time()
    store.now = function()
        return clock
    end
    local backend = localboard.new({
        name = "mine",
        path = home .. "/state/dev/boards/mine.json",
        private = true,
    })
    backend.roles = { icebox = "Icebox" }
    return backend
end

local function lease(seconds)
    local previous = turn.LEASE_SECONDS
    turn.LEASE_SECONDS = seconds
    return function()
        turn.LEASE_SECONDS = previous
    end
end

t.test("the turn goes to one asker and names its holder and the time to the next", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    t.eq(first.holder, "alpha")
    local second, message = turn.take(backend, "beta", "bbbb2222")
    t.eq(second, nil)
    t.ok(message:find("held by alpha since 20", 1, true), message)
    local holder = assert(turn.holder(backend))
    t.eq(holder.name, "alpha")
    t.ok(holder.since:find("^20%d%d%-"), holder.since)
end)

t.test("a released turn goes to the next asker", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    turn.release(backend, first)
    t.eq(turn.holder(backend), nil)
    local second = assert(turn.take(backend, "beta", "bbbb2222"))
    t.eq(second.holder, "beta")
end)

t.test("a holder that stops renewing loses the turn to the next asker", function()
    local backend = backend_at(board_home())
    local restore = lease(LEASE_SECONDS)
    assert(turn.take(backend, "alpha", "aaaa1111"))
    local early = turn.take(backend, "beta", "bbbb2222")
    t.eq(early, nil)
    advance(PAST_LEASE_SECONDS)
    local second = assert(turn.take(backend, "beta", "bbbb2222"))
    restore()
    t.eq(second.holder, "beta")
    t.eq(assert(turn.holder(backend)).name, "beta")
end)

t.test("a holder that returns after another took the turn is refused", function()
    local backend = backend_at(board_home())
    local restore = lease(LEASE_SECONDS)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    advance(PAST_LEASE_SECONDS)
    assert(turn.take(backend, "beta", "bbbb2222"))
    local renewed, message = turn.renew(backend, first)
    restore()
    t.eq(renewed, nil)
    t.ok(message:find("the landing turn was lost", 1, true), message)
    t.eq(assert(turn.holder(backend)).name, "beta")
end)

t.test("a holder that returns after its lease ran out must ask again", function()
    local backend = backend_at(board_home())
    local restore = lease(LEASE_SECONDS)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    advance(PAST_LEASE_SECONDS)
    local renewed, message = turn.renew(backend, first)
    restore()
    t.eq(renewed, nil)
    t.ok(message:find("ran out", 1, true), message)
    t.eq(turn.holder(backend), nil)
end)

t.test("a holder that renews in time keeps the turn past its first lease", function()
    local backend = backend_at(board_home())
    local LONG_LEASE_SECONDS = 4
    local HALF_LEASE_SECONDS = 2
    local restore = lease(LONG_LEASE_SECONDS)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    advance(HALF_LEASE_SECONDS)
    t.eq(turn.renew(backend, first), true)
    advance(HALF_LEASE_SECONDS)
    restore()
    t.eq(turn.take(backend, "beta", "bbbb2222"), nil)
    t.eq(assert(turn.holder(backend)).name, "alpha")
end)

t.test("two turn cards made by a race leave one turn on the lowest id", function()
    local backend = backend_at(board_home())
    local first = assert(backend:add(turn.NAME, backend.roles.icebox, {}))
    local second = assert(backend:add(turn.NAME, backend.roles.icebox, {}))
    local lowest = first.id < second.id and first.id or second.id
    local held = assert(turn.take(backend, "alpha", "aaaa1111"))
    t.eq(held.card, lowest)
    t.eq(turn.take(backend, "beta", "bbbb2222"), nil)
end)

t.test("waiting cards get the turn in the order they asked", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    assert(turn.ask(backend, { name = "beta", card = "bbbb2222", seconds = 60 }))
    assert(turn.ask(backend, { name = "gamma", card = "cccc3333", seconds = 60 }))
    turn.release(backend, first)
    local late, message = turn.take(backend, "gamma", "cccc3333")
    t.eq(late, nil)
    t.ok(message:find("next for beta", 1, true), message)
    local fresh = turn.take(backend, "delta", "dddd4444")
    t.eq(fresh, nil)
    local second = assert(turn.take(backend, "beta", "bbbb2222"))
    turn.release(backend, second)
    t.eq(assert(turn.take(backend, "gamma", "cccc3333")).holder, "gamma")
end)

t.test("a card that leaves the line passes the turn to the next one", function()
    local backend = backend_at(board_home())
    assert(turn.ask(backend, { name = "beta", card = "bbbb2222", seconds = 60 }))
    assert(turn.ask(backend, { name = "gamma", card = "cccc3333", seconds = 60 }))
    t.eq(turn.take(backend, "gamma", "cccc3333"), nil)
    turn.leave(backend, "beta", "bbbb2222")
    t.eq(assert(turn.take(backend, "gamma", "cccc3333")).holder, "gamma")
end)

t.test("a waiter that died stops holding the line after its wait", function()
    local backend = backend_at(board_home())
    local WAIT_SECONDS = 3
    local grace = turn.ASK_GRACE_SECONDS
    turn.ASK_GRACE_SECONDS = 0
    assert(turn.ask(backend, { name = "beta", card = "bbbb2222", seconds = WAIT_SECONDS }))
    local early = turn.take(backend, "gamma", "cccc3333")
    advance(PAST_LEASE_SECONDS)
    turn.ASK_GRACE_SECONDS = grace
    t.eq(early, nil)
    t.eq(assert(turn.take(backend, "gamma", "cccc3333")).holder, "gamma")
end)

t.test("only the holder's fence releases the turn", function()
    local backend = backend_at(board_home())
    local restore = lease(LEASE_SECONDS)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    advance(PAST_LEASE_SECONDS)
    assert(turn.take(backend, "beta", "bbbb2222"))
    restore()
    turn.release(backend, first)
    t.eq(assert(turn.holder(backend)).name, "beta")
    turn.release(backend, { card = first.card, fence = first.fence + 100, holder = "gamma" })
    t.eq(assert(turn.holder(backend)).name, "beta")
end)

t.test("a note cannot forge a turn record", function()
    t.ok(require("dev.board").reserved("dev-turn: ask holder=x card=y until=2099-01-01T00:00:00Z"))
end)

t.test(
    "a hold is found from the board, renews with its lease and ends when it is given back",
    function()
        local backend = backend_at(board_home())
        t.eq(turn.held(backend, "alpha", "aaaa1111"), nil)
        local first =
            assert(turn.take(backend, "alpha", "aaaa1111", { hold = true, seconds = 600 }))
        t.eq(first.lease, 600)
        local found = assert(turn.held(backend, "alpha", "aaaa1111"))
        t.eq(found.fence, first.fence)
        t.eq(found.lease, 600)
        t.eq(turn.renew(backend, found), true)
        t.eq(turn.held(backend, "alpha", "bbbb2222"), nil)
        turn.release(backend, found)
        t.eq(turn.held(backend, "alpha", "aaaa1111"), nil)
        t.eq(turn.holder(backend), nil)
    end
)

t.test("a hold that ran out is reported as lost, and a landing's own turn is no hold", function()
    local backend = backend_at(board_home())
    local restore = lease(LEASE_SECONDS)
    assert(turn.take(backend, "alpha", "aaaa1111", { hold = true, seconds = LEASE_SECONDS }))
    advance(PAST_LEASE_SECONDS)
    local found, message = turn.held(backend, "alpha", "aaaa1111")
    restore()
    t.eq(found, nil)
    t.ok(message:find("ran out or was taken", 1, true), message)
    local plain = assert(turn.take(backend, "beta", "bbbb2222"))
    t.eq(plain.hold, false)
    t.eq(turn.held(backend, "beta", "bbbb2222"), nil)
end)

t.test("renewing a hold keeps the lease it was taken with", function()
    local backend = backend_at(board_home())
    local restore = lease(1)
    local HOLD_LEASE_SECONDS = 6
    local first = assert(
        turn.take(backend, "alpha", "aaaa1111", { hold = true, seconds = HOLD_LEASE_SECONDS })
    )
    advance(HOLD_LEASE_SECONDS - 2)
    t.eq(turn.renew(backend, first), true)
    advance(HOLD_LEASE_SECONDS - 2)
    local second = turn.take(backend, "beta", "bbbb2222")
    restore()
    t.eq(second, nil)
    t.eq(assert(turn.holder(backend)).name, "alpha")
end)

t.test("a hold cannot be extended past the most it may be kept", function()
    local backend = backend_at(board_home())
    local previous = turn.MAX_HOLD_SECONDS
    turn.MAX_HOLD_SECONDS = 1
    local first = assert(turn.take(backend, "alpha", "aaaa1111", { hold = true, seconds = 600 }))
    advance(PAST_HOLD_SECONDS)
    local renewed, message, capped = turn.extend(backend, first, 600)
    local landing, landing_message, landing_capped = turn.renew(backend, first)
    turn.MAX_HOLD_SECONDS = previous
    t.eq(renewed, nil)
    t.eq(capped, true)
    t.ok(message:find("the most it may be kept", 1, true), message)
    t.eq(landing, nil)
    t.eq(landing_capped, true)
    t.ok(landing_message:find("the most it may be kept", 1, true), landing_message)
end)

t.test("extending a hold records the new lease for the next command", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111", { hold = true, seconds = 600 }))
    advance(PAST_LEASE_SECONDS)
    t.eq(turn.extend(backend, first, 1800), true)
    local found = assert(turn.held(backend, "alpha", "aaaa1111"))
    t.eq(found.lease, 1800)
    t.eq(found.taken, first.taken)
    t.eq(assert(turn.holder(backend)).since, first.taken)
end)

t.test("a waiting poll reads the turn card and its comments and never the card list", function()
    local backend = backend_at(board_home())
    assert(turn.take(backend, "alpha", "aaaa1111"))
    local _, _, first = turn.take(backend, "beta", "bbbb2222")
    local listed, single = 0, 0
    local cards, card = backend.cards, backend.card
    function backend:cards()
        listed = listed + 1
        return cards(self)
    end
    function backend:card(id)
        single = single + 1
        return card(self, id)
    end
    for _ = 1, 3 do
        local taken, message, place = turn.take(backend, "beta", "bbbb2222")
        t.eq(taken, nil)
        t.ok(message:find("held by alpha", 1, true), message)
        t.eq(place, first)
    end
    t.eq(listed, 0)
    t.eq(single, 6)
end)

t.test(
    "the poll backs off while the place in line is unchanged and starts over when it moves",
    function()
        local poll = turn.poller({
            random = function()
                return 0
            end,
        })
        local slept = {}
        for _ = 1, 8 do
            slept[#slept + 1] = poll:pace("2:alpha")
        end
        t.eq(slept[1], turn.POLL_SECONDS)
        t.eq(slept[2], turn.POLL_SECONDS * turn.POLL_BACKOFF)
        t.ok(slept[3] > slept[2], "the third sleep did not grow")
        t.eq(slept[8], turn.POLL_MAX_SECONDS)
        t.eq(poll:pace("1:alpha"), turn.POLL_SECONDS)
        t.eq(poll:pace("1:alpha"), turn.POLL_SECONDS * turn.POLL_BACKOFF)
    end
)

t.test("jitter only shortens a sleep and never below its share", function()
    local MIN_JITTERED_SECONDS = 4
    local poll = turn.poller({
        random = function()
            return 0.999
        end,
    })
    local seconds = poll:pace("1:alpha")
    t.ok(seconds < turn.POLL_SECONDS, seconds)
    t.ok(seconds >= MIN_JITTERED_SECONDS, seconds)
end)

t.test("a poll falls back to the card list when the cached turn card cannot be read", function()
    local backend = backend_at(board_home())
    assert(turn.take(backend, "alpha", "aaaa1111"))
    local card = backend.card
    function backend:card()
        return nil, "board unavailable: card timed out"
    end
    local taken, message = turn.take(backend, "beta", "bbbb2222")
    backend.card = card
    t.eq(taken, nil)
    t.ok(message:find("held by alpha", 1, true), message)
end)

t.test("a poll finds a new turn card once the cached one is done", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    turn.release(backend, first)
    assert(backend:move(first.card, board.DEFAULT_NAMES.done))
    local second = assert(turn.take(backend, "beta", "bbbb2222"))
    t.ok(second.card ~= first.card, "the done turn card was reused")
end)

t.test("a claim lost after the turn card was read still names the holder", function()
    local backend = backend_at(board_home())
    assert(turn.take(backend, "alpha", "aaaa1111"))
    local card = backend.card
    local reads = 0
    function backend:card(id)
        reads = reads + 1
        local read, message = card(self, id)
        if read and reads == 1 then
            read.claimant = nil
        end
        return read, message
    end
    local taken, message = turn.take(backend, "beta", "bbbb2222")
    backend.card = card
    t.eq(taken, nil)
    t.ok(message:find("held by alpha", 1, true), message)
end)

local function as_agent(name, run)
    local previous = os.getenv("DEV_AGENT") or ""
    ffi.C.setenv("DEV_AGENT", name, 1)
    local ok, err = pcall(run)
    ffi.C.setenv("DEV_AGENT", previous, 1)
    assert(ok, err)
end

local function landing_card(backend)
    local id = assert(backend:add("work", board.DEFAULT_NAMES.review, {})).id
    return id, id:sub(1, board.MIN_PREFIX)
end

t.test("a waiter whose card moves to Done leaves the queue within one retry", function()
    local backend = backend_at(board_home())
    local id, short = landing_card(backend)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    local naps = 0
    local result
    local nap = devos.nap
    devos.nap = function(seconds)
        naps = naps + 1
        assert(naps == 1, "the waiter kept polling after its card was done")
        advance(seconds)
        assert(backend:move(id, board.DEFAULT_NAMES.done))
    end
    local ok, err = pcall(as_agent, "beta", function()
        result = commands.run("turn", { short, "--wait", "600" }, backend)
    end)
    devos.nap = nap
    assert(ok, err)
    t.eq(naps, 1)
    t.eq(result.code, 1)
    t.ok(result.message:find(short .. " is done", 1, true), result.message)
    turn.release(backend, first)
    t.ok(turn.take(backend, "gamma", "cccc3333"), "the done card's ask kept the line")
end)

t.test("a waiter whose card is done is not handed a turn that frees meanwhile", function()
    local backend = backend_at(board_home())
    local id, short = landing_card(backend)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    local nap = devos.nap
    devos.nap = function(seconds)
        advance(seconds)
        turn.release(backend, first)
        assert(backend:move(id, board.DEFAULT_NAMES.done))
    end
    local result
    local ok, err = pcall(as_agent, "beta", function()
        result = commands.run("turn", { short, "--wait", "600" }, backend)
    end)
    devos.nap = nap
    assert(ok, err)
    t.eq(result.code, 1)
    t.ok(result.message:find(short .. " is done", 1, true), result.message)
    t.eq(turn.holder(backend), nil)
end)

t.test("release drops the queued ask of a caller that holds no turn", function()
    local backend = backend_at(board_home())
    local _, short = landing_card(backend)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    assert(turn.ask(backend, { name = "beta", card = short, seconds = 600 }))
    local result
    as_agent("beta", function()
        result = commands.run("turn", { short, "--release" }, backend)
    end)
    t.eq(result.code, 1)
    turn.release(backend, first)
    t.ok(turn.take(backend, "gamma", "cccc3333"), "the released ask kept the line")
end)
