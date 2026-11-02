local ffi = require("ffi")

local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local localboard = require("dev.board.localboard")
local support = require("support")
local turn = require("dev.board.turn")

local LEASE_SECONDS = 3
local PAST_LEASE_SECONDS = 4.2

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
    devos.nap(PAST_LEASE_SECONDS)
    local second = assert(turn.take(backend, "beta", "bbbb2222"))
    restore()
    t.eq(second.holder, "beta")
    t.eq(assert(turn.holder(backend)).name, "beta")
end)

t.test("a holder that returns after another took the turn is refused", function()
    local backend = backend_at(board_home())
    local restore = lease(LEASE_SECONDS)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    devos.nap(PAST_LEASE_SECONDS)
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
    devos.nap(PAST_LEASE_SECONDS)
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
    devos.nap(HALF_LEASE_SECONDS)
    t.eq(turn.renew(backend, first), true)
    devos.nap(HALF_LEASE_SECONDS)
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
    local grace = turn.ASK_GRACE_SECONDS
    turn.ASK_GRACE_SECONDS = 0
    assert(turn.ask(backend, { name = "beta", card = "bbbb2222", seconds = 1 }))
    t.eq(turn.take(backend, "gamma", "cccc3333"), nil)
    devos.nap(PAST_LEASE_SECONDS)
    turn.ASK_GRACE_SECONDS = grace
    t.eq(assert(turn.take(backend, "gamma", "cccc3333")).holder, "gamma")
end)

t.test("only the holder's fence releases the turn", function()
    local backend = backend_at(board_home())
    local restore = lease(LEASE_SECONDS)
    local first = assert(turn.take(backend, "alpha", "aaaa1111"))
    devos.nap(PAST_LEASE_SECONDS)
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
