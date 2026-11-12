local ffi = require("ffi")

local testing = require("dev.testing")
local board = require("dev.board")
local cmd_board = require("dev.cmd.board")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local localboard = require("dev.board.localboard")
local pomb = require("dev.board.pomb")
local store = require("dev.board.store")
local support = require("support")
local turn = require("dev.board.turn")

local LEASE_SECONDS = 3
local PAST_LEASE_SECONDS = 4
local PAST_HOLD_SECONDS = 2
local TURN_HOLD_SECONDS = 600
local ID_A = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

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
    backend.roles = board.roles(nil, {})
    return backend
end

local function lease(seconds)
    local previous = turn.LEASE_SECONDS
    turn.LEASE_SECONDS = seconds
    return function()
        turn.LEASE_SECONDS = previous
    end
end

testing.test("the turn goes to one asker and names its holder and the time to the next", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    testing.eq(first.holder, "alpha")
    local second, message = turn.take(backend, "beta", "bbbb2222")
    testing.eq(second, nil)
    testing.ok(message:find("held by alpha since 20", 1, true), message)
    local holder = assert(turn.holder(backend))
    testing.eq(holder.name, "alpha")
    testing.ok(holder.since:find("^20%d%d%-"), holder.since)
end)

testing.test("a released turn goes to the next asker", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    turn.release(backend, first)
    testing.eq(turn.holder(backend), nil)
    local second = assert(turn.take(backend, "beta", "bbbb2222"))
    testing.eq(second.holder, "beta")
end)

testing.test("a holder that stops renewing loses the turn to the next asker", function()
    local backend = backend_at(board_home())
    local restore = lease(LEASE_SECONDS)
    assert(turn.take(backend, "alpha", "aaaa1111"))
    local early = turn.take(backend, "beta", "bbbb2222")
    testing.eq(early, nil)
    advance(PAST_LEASE_SECONDS)
    local second = assert(turn.take(backend, "beta", "bbbb2222"))
    restore()
    testing.eq(second.holder, "beta")
    testing.eq(assert(turn.holder(backend)).name, "beta")
end)

testing.test("a holder that returns after another took the turn is refused", function()
    local backend = backend_at(board_home())
    local restore = lease(LEASE_SECONDS)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    advance(PAST_LEASE_SECONDS)
    assert(turn.take(backend, "beta", "bbbb2222"))
    local renewed, message = turn.renew(backend, first)
    restore()
    testing.eq(renewed, nil)
    testing.ok(message:find("the landing turn was lost", 1, true), message)
    testing.eq(assert(turn.holder(backend)).name, "beta")
end)

testing.test("a holder that returns after its lease ran out must ask again", function()
    local backend = backend_at(board_home())
    local restore = lease(LEASE_SECONDS)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    advance(PAST_LEASE_SECONDS)
    local renewed, message = turn.renew(backend, first)
    restore()
    testing.eq(renewed, nil)
    testing.ok(message:find("ran out", 1, true), message)
    testing.eq(turn.holder(backend), nil)
end)

testing.test("a holder that renews in time keeps the turn past its first lease", function()
    local backend = backend_at(board_home())
    local LONG_LEASE_SECONDS = 4
    local HALF_LEASE_SECONDS = 2
    local restore = lease(LONG_LEASE_SECONDS)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    advance(HALF_LEASE_SECONDS)
    testing.eq(turn.renew(backend, first), true)
    advance(HALF_LEASE_SECONDS)
    restore()
    testing.eq(turn.take(backend, "beta", "bbbb2222"), nil)
    testing.eq(assert(turn.holder(backend)).name, "alpha")
end)

testing.test("two turn cards made by a race leave one turn on the lowest id", function()
    local backend = backend_at(board_home())
    local first = assert(backend:add(turn.NAME, backend.roles.icebox, {}))
    local second = assert(backend:add(turn.NAME, backend.roles.icebox, {}))
    local lowest = first.id < second.id and first.id or second.id
    local held = assert(turn.take(backend, "alpha", "aaaa1111"))
    testing.eq(held.card, lowest)
    testing.eq(turn.take(backend, "beta", "bbbb2222"), nil)
end)

testing.test("waiting cards get the turn in the order they asked", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    assert(turn.ask(backend, { name = "beta", card = "bbbb2222", seconds = 60 }))
    assert(turn.ask(backend, { name = "gamma", card = "cccc3333", seconds = 60 }))
    turn.release(backend, first)
    local late, message = turn.take(backend, "gamma", "cccc3333")
    testing.eq(late, nil)
    testing.ok(message:find("next for beta", 1, true), message)
    local fresh = turn.take(backend, "delta", "dddd4444")
    testing.eq(fresh, nil)
    local second = assert(turn.take(backend, "beta", "bbbb2222"))
    turn.release(backend, second)
    testing.eq(assert(turn.take(backend, "gamma", "cccc3333")).holder, "gamma")
end)

testing.test("a card that leaves the line passes the turn to the next one", function()
    local backend = backend_at(board_home())
    assert(turn.ask(backend, { name = "beta", card = "bbbb2222", seconds = 60 }))
    assert(turn.ask(backend, { name = "gamma", card = "cccc3333", seconds = 60 }))
    testing.eq(turn.take(backend, "gamma", "cccc3333"), nil)
    turn.leave(backend, "beta", "bbbb2222")
    testing.eq(assert(turn.take(backend, "gamma", "cccc3333")).holder, "gamma")
end)

testing.test("a waiter that died stops holding the line after its wait", function()
    local backend = backend_at(board_home())
    local WAIT_SECONDS = 3
    local grace = turn.ASK_GRACE_SECONDS
    turn.ASK_GRACE_SECONDS = 0
    assert(turn.ask(backend, { name = "beta", card = "bbbb2222", seconds = WAIT_SECONDS }))
    local early = turn.take(backend, "gamma", "cccc3333")
    advance(PAST_LEASE_SECONDS)
    turn.ASK_GRACE_SECONDS = grace
    testing.eq(early, nil)
    testing.eq(assert(turn.take(backend, "gamma", "cccc3333")).holder, "gamma")
end)

testing.test("only the holder's fence releases the turn", function()
    local backend = backend_at(board_home())
    local restore = lease(LEASE_SECONDS)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    advance(PAST_LEASE_SECONDS)
    assert(turn.take(backend, "beta", "bbbb2222"))
    restore()
    turn.release(backend, first)
    testing.eq(assert(turn.holder(backend)).name, "beta")
    turn.release(backend, { card = first.card, fence = first.fence + 100, holder = "gamma" })
    testing.eq(assert(turn.holder(backend)).name, "beta")
end)

testing.test("a note cannot forge a turn record", function()
    testing.ok(
        require("dev.board").reserved("dev-turn: ask holder=x card=y until=2099-01-01T00:00:00Z")
    )
end)

testing.test(
    "a hold is found from the board, renews with its lease and ends when it is given back",
    function()
        local backend = backend_at(board_home())
        testing.eq(turn.held(backend, "alpha", "aaaa1111"), nil)
        local first =
            assert(turn.take(backend, "alpha", "aaaa1111", { hold = true, seconds = 600 }))
        testing.eq(first.lease, 600)
        local found = assert(turn.held(backend, "alpha", "aaaa1111"))
        testing.eq(found.fence, first.fence)
        testing.eq(found.lease, 600)
        testing.eq(turn.renew(backend, found), true)
        testing.eq(turn.held(backend, "alpha", "bbbb2222"), nil)
        turn.release(backend, found)
        testing.eq(turn.held(backend, "alpha", "aaaa1111"), nil)
        testing.eq(turn.holder(backend), nil)
    end
)

testing.test(
    "a hold that ran out is reported as lost, and a landing's own turn is no hold",
    function()
        local backend = backend_at(board_home())
        local restore = lease(LEASE_SECONDS)
        assert(turn.take(backend, "alpha", "aaaa1111", { hold = true, seconds = LEASE_SECONDS }))
        advance(PAST_LEASE_SECONDS)
        local found, message = turn.held(backend, "alpha", "aaaa1111")
        restore()
        testing.eq(found, nil)
        testing.ok(message:find("ran out or was taken", 1, true), message)
        local plain = assert(turn.take(backend, "beta", "bbbb2222"))
        testing.eq(plain.hold, false)
        testing.eq(turn.held(backend, "beta", "bbbb2222"), nil)
    end
)

testing.test("renewing a hold keeps the lease it was taken with", function()
    local backend = backend_at(board_home())
    local restore = lease(1)
    local HOLD_LEASE_SECONDS = 6
    local first = assert(
        turn.take(backend, "alpha", "aaaa1111", { hold = true, seconds = HOLD_LEASE_SECONDS })
    )
    advance(HOLD_LEASE_SECONDS - 2)
    testing.eq(turn.renew(backend, first), true)
    advance(HOLD_LEASE_SECONDS - 2)
    local second = turn.take(backend, "beta", "bbbb2222")
    restore()
    testing.eq(second, nil)
    testing.eq(assert(turn.holder(backend)).name, "alpha")
end)

testing.test("a hold cannot be extended past the most it may be kept", function()
    local backend = backend_at(board_home())
    local previous = turn.MAX_HOLD_SECONDS
    turn.MAX_HOLD_SECONDS = 1
    local first = assert(turn.take(backend, "alpha", "aaaa1111", { hold = true, seconds = 600 }))
    advance(PAST_HOLD_SECONDS)
    local renewed, message, capped = turn.extend(backend, first, 600)
    local landing, landing_message, landing_capped = turn.renew(backend, first)
    turn.MAX_HOLD_SECONDS = previous
    testing.eq(renewed, nil)
    testing.eq(capped, true)
    testing.ok(message:find("the most it may be kept", 1, true), message)
    testing.eq(landing, nil)
    testing.eq(landing_capped, true)
    testing.ok(landing_message:find("the most it may be kept", 1, true), landing_message)
end)

testing.test("extending a hold records the new lease for the next command", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111", { hold = true, seconds = 600 }))
    advance(PAST_LEASE_SECONDS)
    testing.eq(turn.extend(backend, first, 1800), true)
    local found = assert(turn.held(backend, "alpha", "aaaa1111"))
    testing.eq(found.lease, 1800)
    testing.eq(found.taken, first.taken)
    testing.eq(assert(turn.holder(backend)).since, first.taken)
end)

testing.test(
    "a waiting poll reads the turn card and its comments and never the card list",
    function()
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
            testing.eq(taken, nil)
            testing.ok(message:find("held by alpha", 1, true), message)
            testing.eq(place, first)
        end
        testing.eq(listed, 0)
        testing.eq(single, 6)
    end
)

testing.test(
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
        testing.eq(slept[1], turn.POLL_SECONDS)
        testing.eq(slept[2], turn.POLL_SECONDS * turn.POLL_BACKOFF)
        testing.ok(slept[3] > slept[2], "the third sleep did not grow")
        testing.eq(slept[8], turn.POLL_MAX_SECONDS)
        testing.eq(poll:pace("1:alpha"), turn.POLL_SECONDS)
        testing.eq(poll:pace("1:alpha"), turn.POLL_SECONDS * turn.POLL_BACKOFF)
    end
)

testing.test("jitter only shortens a sleep and never below its share", function()
    local MIN_JITTERED_SECONDS = 4
    local poll = turn.poller({
        random = function()
            return 0.999
        end,
    })
    local seconds = poll:pace("1:alpha")
    testing.ok(seconds < turn.POLL_SECONDS, seconds)
    testing.ok(seconds >= MIN_JITTERED_SECONDS, seconds)
end)

testing.test(
    "a poll falls back to the card list when the cached turn card cannot be read",
    function()
        local backend = backend_at(board_home())
        assert(turn.take(backend, "alpha", "aaaa1111"))
        local card = backend.card
        function backend:card()
            return nil, "board unavailable: card timed out"
        end
        local taken, message = turn.take(backend, "beta", "bbbb2222")
        backend.card = card
        testing.eq(taken, nil)
        testing.ok(message:find("held by alpha", 1, true), message)
    end
)

testing.test("a poll finds a new turn card once the cached one is done", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    turn.release(backend, first)
    assert(backend:move(first.card, board.DEFAULT_NAMES.done))
    local second = assert(turn.take(backend, "beta", "bbbb2222"))
    testing.ok(second.card ~= first.card, "the done turn card was reused")
end)

testing.test("a claim lost after the turn card was read still names the holder", function()
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
    testing.eq(taken, nil)
    testing.ok(message:find("held by alpha", 1, true), message)
end)

local function fill(backend, id)
    local notes = assert(backend:comments(id))
    for _ = #notes + 1, turn.MAX_NOTES do
        assert(backend:note(id, "filler"))
    end
end

local function open_turn_card(backend)
    local cards = assert(backend:cards())
    for _, card in ipairs(cards) do
        if card.name == turn.NAME and not card.done then
            return card
        end
    end
end

testing.test("a full landing turn card rotates to a fresh one", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    turn.release(backend, first)
    fill(backend, first.card)
    local second = assert(turn.take(backend, "beta", "bbbb2222"))
    testing.ok(second.card ~= first.card, "the full card was reused")
    testing.eq(open_turn_card(backend).id, second.card)
    testing.eq(assert(backend:card(first.card)).done, true)
end)

testing.test("a held landing turn card is not rotated", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    fill(backend, first.card)
    testing.eq(turn.take(backend, "beta", "bbbb2222"), nil)
    assert(turn.ask(backend, { name = "beta", card = "bbbb2222", seconds = 60 }))
    testing.eq(open_turn_card(backend).id, first.card)
    testing.eq(turn.holder(backend).name, "alpha")
    turn.release(backend, first)
    local second = assert(turn.take(backend, "beta", "bbbb2222"))
    testing.ok(second.card ~= first.card, "the freed full card was reused")
end)

testing.test("rotation keeps the line of askers", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    assert(turn.ask(backend, { name = "beta", card = "bbbb2222", seconds = 60 }))
    assert(turn.ask(backend, { name = "gamma", card = "cccc3333", seconds = 60 }))
    assert(turn.ask(backend, { name = "late", card = "dddd4444", seconds = 1 }))
    turn.release(backend, first)
    fill(backend, first.card)
    advance(turn.ASK_GRACE_SECONDS + 2)
    testing.eq(turn.take(backend, "gamma", "cccc3333"), nil)
    local fresh = open_turn_card(backend)
    testing.ok(fresh.id ~= first.card, "the full card was kept")
    local bodies = {}
    for _, comment in ipairs(assert(backend:comments(fresh.id))) do
        bodies[#bodies + 1] = comment.body
    end
    testing.eq(#bodies, 2)
    testing.ok(bodies[1]:find("holder=beta card=bbbb2222", 1, true), bodies[1])
    testing.ok(bodies[2]:find("holder=gamma card=cccc3333", 1, true), bodies[2])
    local second = assert(turn.take(backend, "beta", "bbbb2222"))
    testing.eq(second.card, fresh.id)
    turn.release(backend, second)
    testing.eq(assert(turn.take(backend, "gamma", "cccc3333")).holder, "gamma")
end)

testing.test("a card past the byte limit rotates", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    turn.release(backend, first)
    fill(backend, first.card)
    backend.move = function()
        return nil, "limit reached: at most 1048576 bytes in one task", true
    end
    local binned = false
    backend.bin = function()
        binned = true
        return true
    end
    local refused, message = turn.take(backend, "beta", "bbbb2222")
    testing.eq(refused, nil)
    testing.ok(message:find(first.card:sub(1, 8), 1, true), message)
    testing.ok(message:find("Rename it", 1, true), message)
    testing.eq(binned, false)
    testing.eq(open_turn_card(backend).id, first.card)
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

testing.test("a waiter whose card moves to Done leaves the queue within one retry", function()
    local backend = backend_at(board_home())
    local id, short = landing_card(backend)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    local naps = 0
    local result
    local nap = dev_os.nap
    dev_os.nap = function(seconds)
        naps = naps + 1
        assert(naps == 1, "the waiter kept polling after its card was done")
        advance(seconds)
        assert(backend:move(id, board.DEFAULT_NAMES.done))
    end
    local ok, err = pcall(as_agent, "beta", function()
        result = cmd_board.run("turn", { short, "--wait", "600" }, backend)
    end)
    dev_os.nap = nap
    assert(ok, err)
    testing.eq(naps, 1)
    testing.eq(result.code, 1)
    testing.ok(result.message:find(short .. " is done", 1, true), result.message)
    turn.release(backend, first)
    testing.ok(turn.take(backend, "gamma", "cccc3333"), "the done card's ask kept the line")
end)

testing.test("a waiter whose card is done is not handed a turn that frees meanwhile", function()
    local backend = backend_at(board_home())
    local id, short = landing_card(backend)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    local nap = dev_os.nap
    dev_os.nap = function(seconds)
        advance(seconds)
        turn.release(backend, first)
        assert(backend:move(id, board.DEFAULT_NAMES.done))
    end
    local result
    local ok, err = pcall(as_agent, "beta", function()
        result = cmd_board.run("turn", { short, "--wait", "600" }, backend)
    end)
    dev_os.nap = nap
    assert(ok, err)
    testing.eq(result.code, 1)
    testing.ok(result.message:find(short .. " is done", 1, true), result.message)
    testing.eq(turn.holder(backend), nil)
end)

testing.test("release drops the queued ask of a caller that holds no turn", function()
    local backend = backend_at(board_home())
    local _, short = landing_card(backend)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    assert(turn.ask(backend, { name = "beta", card = short, seconds = 600 }))
    local result
    as_agent("beta", function()
        result = cmd_board.run("turn", { short, "--release" }, backend)
    end)
    testing.eq(result.code, 1)
    turn.release(backend, first)
    testing.ok(turn.take(backend, "gamma", "cccc3333"), "the released ask kept the line")
end)

testing.test("a leave keeps a live hold", function()
    local backend = backend_at(board_home())
    local first = assert(turn.take(backend, "alpha", "aaaa1111", { hold = true, seconds = 600 }))
    turn.leave(backend, "alpha", "aaaa1111")
    local found = assert(turn.held(backend, "alpha", "aaaa1111"))
    testing.eq(found.fence, first.fence)
    turn.release(backend, found)
    testing.eq(turn.held(backend, "alpha", "aaaa1111"), nil)
end)

testing.test("a turn hold over 3600 is refused", function()
    local backend = backend_at(board_home())
    local _, short = landing_card(backend)
    testing.eq(turn.HOLD_SECONDS, 1800)
    testing.eq(turn.MAX_HOLD_SECONDS, 3600)
    local result
    as_agent("alpha", function()
        result = cmd_board.run("turn", { short, "--hold", "3601" }, backend)
    end)
    testing.eq(result.code, 2)
    testing.ok(result.message:find("up to 3600", 1, true), result.message)
    testing.eq(turn.holder(backend), nil)
end)

testing.test("turn covers rebase and land only", function()
    local backend = backend_at(board_home())
    testing.eq(turn.holder(backend), nil)
    local landing = assert(turn.take(backend, "alpha", "aaaa1111"))
    testing.eq(landing.hold, false)
    assert(turn.release(backend, landing))
    local next_landing = assert(turn.take(backend, "beta", "bbbb2222"))
    testing.eq(next_landing.hold, false)
    assert(turn.release(backend, next_landing))
    testing.eq(turn.holder(backend), nil)
end)

testing.test("turn take grabs the owner with the turn lease", function()
    local backend = backend_at(board_home())
    local restore = lease(LEASE_SECONDS)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    testing.eq(first.lease, LEASE_SECONDS)
    advance(PAST_LEASE_SECONDS)
    restore()
    testing.eq(turn.holder(backend), nil)
    local RENEWED_AT_SECONDS = 500
    local held =
        assert(turn.take(backend, "beta", "bbbb2222", { hold = true, seconds = TURN_HOLD_SECONDS }))
    testing.eq(held.lease, TURN_HOLD_SECONDS)
    advance(RENEWED_AT_SECONDS)
    testing.eq(turn.renew(backend, held), true)
    advance(TURN_HOLD_SECONDS - RENEWED_AT_SECONDS)
    testing.eq(turn.take(backend, "gamma", "cccc3333"), nil)
    testing.eq(assert(turn.holder(backend)).name, "beta")
end)

testing.test("turn release ends the owner lease", function()
    local backend = backend_at(board_home())
    local first = assert(
        turn.take(backend, "alpha", "aaaa1111", { hold = true, seconds = TURN_HOLD_SECONDS })
    )
    testing.eq(first.lease, TURN_HOLD_SECONDS)
    testing.eq(turn.renew(backend, first), true)
    testing.eq(turn.release(backend, first), true)
    testing.eq(turn.holder(backend), nil)
    local second = assert(turn.take(backend, "beta", "bbbb2222"))
    testing.eq(second.holder, "beta")
    testing.eq(turn.release(backend, first), nil)
    testing.eq(assert(turn.holder(backend)).name, "beta")
end)

testing.test("turn names the live owner as its holder", function()
    local backend = backend_at(board_home())
    local restore = lease(LEASE_SECONDS)
    assert(turn.take(backend, "alpha", "aaaa1111"))
    local refused, message = turn.take(backend, "beta", "bbbb2222")
    testing.eq(refused, nil)
    testing.ok(message:find("the landing turn is held by alpha since 20", 1, true), message)
    testing.eq(assert(turn.holder(backend)).name, "alpha")
    advance(PAST_LEASE_SECONDS)
    restore()
    testing.eq(turn.holder(backend), nil)
    testing.eq(assert(turn.take(backend, "beta", "bbbb2222")).holder, "beta")
end)

local function pomb_root()
    local ID_B = "11111111-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    local ID_C = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    local boards = '[{"id":"board-1","name":"dotfiles","archived":false}]'
    local detail = '{"id":"board-1","name":"dotfiles","swimlanes":[],"columns":['
        .. '{"id":"col-icebox","name":"'
        .. support.COLUMN_NAME.ICEBOX
        .. '"},'
        .. '{"id":"col-done","name":"'
        .. support.COLUMN_NAME.DONE
        .. '","is_done":true}]}'
    local card = '{"id":"'
        .. ID_A
        .. '","name":"landing turn","column_id":"col-icebox","position":1,"labels":[]}'
    local root = support.sandbox({
        ["boards.json"] = boards,
        ["detail.json"] = detail,
        ["colors.json"] = "[]",
        ["export.json"] = '{"tasks":[' .. card .. "]}",
        ["task.json"] = card,
        ["comments.json"] = "[]",
    }, {})
    assert(fs.write(root .. "/bin/curl", support.pomb_curl(ID_A, ID_B, ID_C)))
    assert(dev_os.run({ "chmod", "755", root .. "/bin/curl" }) == 0, "chmod failed")
    return root
end

local function on_pomb(root, run)
    local names = { "PATH", "ROOT", "DEV_BOARD_TOKEN" }
    local previous = {}
    for _, name in ipairs(names) do
        previous[name] = os.getenv(name) or ""
    end
    ffi.C.setenv("PATH", root .. "/bin:" .. previous.PATH, 1)
    ffi.C.setenv("ROOT", root, 1)
    ffi.C.setenv("DEV_BOARD_TOKEN", "pomb_SECRETtoken0123456789", 1)
    local ok, err = pcall(function()
        run(assert(pomb.new({
            url = "https://pomb.example",
            token = "pass:secrets/worker/token/pomb",
            name = "dotfiles",
        })))
    end)
    for _, name in ipairs(names) do
        ffi.C.setenv(name, previous[name], 1)
    end
    assert(ok, err)
end

local function call_to(root, route)
    for line in (fs.read(root .. "/calls") or ""):gmatch("[^\n]+") do
        if line:sub(-#route) == route then
            return line
        end
    end
    return ""
end

testing.test("taking the turn on Pomb grabs the owner with the turn lease", function()
    local root = pomb_root()
    on_pomb(root, function(backend)
        assert(turn.take(backend, "alpha", "aaaa1111"))
    end)
    local owner = call_to(root, "/api/tasks/" .. ID_A .. "/owner")
    testing.ok(owner:find('"ttl_seconds":900', 1, true), owner)
    testing.ok(owner:find('"name":"alpha"', 1, true), owner)
end)

testing.test("renewing the Pomb turn sends its fence as If-Owner-Fence", function()
    local root = pomb_root()
    on_pomb(root, function(backend)
        local held = assert(turn.take(backend, "alpha", "aaaa1111"))
        testing.eq(turn.renew(backend, held), true)
    end)
    local renewed = call_to(root, "/api/tasks/" .. ID_A .. "/owner/renew")
    testing.ok(renewed:find("If-Owner-Fence: 7", 1, true), renewed)
end)

testing.test("ending the Pomb turn releases its owner with the fence", function()
    local root = pomb_root()
    on_pomb(root, function(backend)
        local held = assert(turn.take(backend, "alpha", "aaaa1111"))
        testing.eq(turn.release(backend, held), true)
    end)
    local released = call_to(root, "/api/tasks/" .. ID_A .. "/owner/release")
    testing.ok(released:find("If-Owner-Fence: 7", 1, true), released)
    testing.ok(released:find('"name":"alpha"', 1, true), released)
end)
