local ffi = require("ffi")

local testing = require("dev.testing")
local claims = require("dev.board.claims")
local clock = require("dev.board.clock")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local CARD = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
local POLLS = 50
local POLL_SECONDS = 0.1

local function spawn_loop(script)
    local out = dev_os.capture(
        { "sh", "-c", 'sh "$1" >/dev/null 2>&1 & echo $!', "sh", script },
        { stderr = "null" }
    )
    return assert(tonumber(out:match("%d+")), out)
end

local function running(pid)
    local out = dev_os.capture({ "ps", "-p", tostring(pid), "-o", "command=" }, { stderr = "null" })
    return out:find("board/keepalive.sh", 1, true) ~= nil
end

local function ended(pid)
    for _ = 1, POLLS do
        if not running(pid) then
            return true
        end
        dev_os.nap(POLL_SECONDS)
    end
    return false
end

testing.test("replace stops the old loop and records the new pid", function()
    -- Start two stub loops and record the old claim
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local dir = support.tempdir() .. "/board"
    assert(fs.mkdir(dir, { parents = true }))
    assert(fs.write(dir .. "/keepalive.sh", "sleep 30\n"))
    local old = spawn_loop(dir .. "/keepalive.sh")
    local new = spawn_loop(dir .. "/keepalive.sh")
    testing.ok(running(old), "the stub loop did not start")
    assert(claims.write({ card = CARD, fence = 4, pid = old }))

    -- Replace the claim and capture what happened
    local ok, message = claims.replace({ card = CARD, fence = 4, pid = new }, old)
    local old_ended = ended(old)
    local new_running = running(new)
    local state = claims.read(CARD)

    -- Stop the new loop and restore the environment
    dev_os.run({ "kill", tostring(new) }, { stderr = "null" })
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)

    -- Check the old loop ended and the claim names the new one
    testing.ok(ok, message)
    testing.ok(old_ended, "the old loop kept running")
    testing.ok(new_running, "the new loop was stopped")
    testing.eq(state.pid, new)
    testing.eq(state.fence, 4)
end)

testing.test("time start keeps a running clock and time stop logs it and removes it", function()
    -- Point the state at a scratch home and fake the clock and the backend
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local now = clock.now
    local logged = {}
    local backend = {}
    function backend:log_time(id, minutes, role, note)
        logged[#logged + 1] = { id, minutes, role, note }
        return true
    end
    local card = { id = CARD, labels = {} }

    -- Start at one time, stop 25 minutes later
    clock.now = function()
        return 1000
    end
    local started = clock.start(card, "reviewer")
    local ticking = clock.read(CARD)
    clock.now = function()
        return 1000 + 25 * 60
    end
    local stopped = clock.stop(backend, card, "looked")
    local left = clock.read(CARD)

    -- Restore the environment
    clock.now = now
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)

    -- Check the clock ran, logged under its role and is gone
    testing.eq(started.output, "started the reviewer clock on 11111111")
    testing.eq(ticking.role, "reviewer")
    testing.eq(ticking.start, 1000)
    testing.eq(logged, { { CARD, 25, "reviewer", "looked" } })
    testing.eq(stopped.output, "logged 25 minutes as reviewer on 11111111")
    testing.eq(left, nil)
end)

testing.test("time stop refuses a card with no running clock", function()
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local result = clock.stop({}, { id = CARD }, nil)
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)
    testing.eq(result.code, 1)
end)
