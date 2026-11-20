local ffi = require("ffi")

local testing = require("dev.testing")
local claims = require("dev.board.claims")
local board = require("dev.board")
local clock = require("dev.board.clock")
local cmd_board = require("dev.cmd.board")
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

local function take_stub(card)
    local stub = { logged = {} }
    function stub:done_columns()
        return { support.COLUMN_NAME.DONE }
    end
    function stub:cards()
        return { card }
    end
    function stub:card(id)
        return support.listed_card(self, id)
    end
    function stub:claim(_, _, opts)
        return (opts.fence or 0) + 1
    end
    function stub:comments()
        return {}
    end
    function stub:family()
        return {}
    end
    function stub:limits()
        return { columns = {}, units = {}, groups = {} }
    end
    function stub:note()
        return true
    end
    function stub:release()
        return true
    end
    function stub:keepalive()
        return 0
    end
    function stub:log_time(id, minutes, role)
        self.logged[#self.logged + 1] = { id, minutes, role }
        return true
    end
    return stub
end

testing.test("a state write that cannot make its pending file returns the write reason", function()
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local path = claims.path(CARD)
    assert(fs.mkdir(path .. ".new", { parents = true }))
    local ok, message, reason, detail = claims.write({ card = CARD, fence = 1, pid = 1 })
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)
    testing.eq({ ok, message, reason, detail }, { nil, nil, board.FileReason.WRITE, path })
end)

testing.test("a take that cannot write its claim state prints the write sentence once", function()
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local path = claims.path(CARD)
    assert(fs.mkdir(path .. ".new", { parents = true }))
    local card = {
        id = CARD,
        name = "x",
        column = support.COLUMN_NAME.PROGRESS,
        size = "1 Pomodoro",
        labels = {},
        outcomes = {},
        checks = {},
    }
    local result = cmd_board.run(
        "take",
        { "11111111", "--as", "dotfiles/implementer/11111111" },
        take_stub(card)
    )
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)
    testing.eq(result.message, "Cannot write " .. path .. ".")
end)

testing.test("a take starts a clock under the role of the card's column", function()
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local name = "dotfiles/implementer/11111111"
    local roles = {}
    local columns = {
        support.COLUMN_NAME.PROGRESS,
        support.COLUMN_NAME.REVIEW,
        support.COLUMN_NAME.BLOCKED,
    }
    for _, column in ipairs(columns) do
        local card = {
            id = CARD,
            name = "x",
            column = column,
            size = "1 Pomodoro",
            labels = {},
            outcomes = {},
            checks = {},
        }
        local stub = take_stub(card)
        local result = cmd_board.run("take", { "11111111", "--as", name }, stub)
        local ticking = clock.read(CARD)
        roles[#roles + 1] = result.code == nil and ticking and ticking.role or result.message
        claims.stop(CARD)
        fs.remove(clock.path(CARD))
    end
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)
    testing.eq(roles, { "implementer", "reviewer", "lead" })
end)

testing.test("column_role names every column's role and takes the claimant's for Ready", function()
    local stages = board.stages({}, { "Done" })
    local who = "dotfiles/verifier/11111111"
    testing.eq(clock.column_role(stages, stages.icebox, who), "scoper")
    testing.eq(clock.column_role(stages, stages.backlog, who), "planner")
    testing.eq(clock.column_role(stages, stages.progress, who), "implementer")
    testing.eq(clock.column_role(stages, stages.review, who), "reviewer")
    testing.eq(clock.column_role(stages, stages.blocked, who), "lead")
    testing.eq(clock.column_role(stages, stages.ready, who), "verifier")
    testing.eq(clock.column_role(stages, stages.verify, who), "verifier")
    testing.eq(clock.column_role(stages, "Done", who), nil)
end)

testing.test("time stop refuses a card with no running clock", function()
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local result = clock.stop({}, { id = CARD }, nil)
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)
    testing.eq(result.code, 1)
end)

testing.test("a stop whose claim of the clock file fails logs nothing", function()
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local logged = {}
    local backend = {}
    function backend:log_time(id, minutes)
        logged[#logged + 1] = { id, minutes }
        return true
    end
    local card = { id = CARD, labels = {} }
    clock.start(card, "reviewer")
    assert(fs.write(clock.stopping_path(CARD), "taken\n"))
    local result = clock.stop(backend, card, nil)
    local kept = clock.read(CARD)
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)
    testing.eq(result.code, 1)
    testing.eq(logged, {})
    testing.ok(kept, "the clock was lost")
end)

testing.test("a start clears a stop's leftover file so the next stop logs", function()
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local logged = {}
    local backend = {}
    function backend:log_time(id, minutes)
        logged[#logged + 1] = { id, minutes }
        return true
    end
    local card = { id = CARD, labels = {} }
    assert(fs.mkdir(claims.dir(), { parents = true }))
    assert(fs.write(clock.stopping_path(CARD), "left behind\n"))
    clock.start(card, "reviewer")
    local result = clock.stop(backend, card, nil)
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)
    testing.eq(result.code, nil)
    testing.eq(#logged, 1)
end)

testing.test("a stop called from inside the first stop's log logs once", function()
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local logged = {}
    local nested
    local backend = {}
    local card = { id = CARD, labels = {} }
    function backend:log_time(id, minutes)
        logged[#logged + 1] = { id, minutes }
        nested = nested or clock.stop(backend, card, nil)
        return true
    end
    clock.start(card, "reviewer")
    local first = clock.stop(backend, card, nil)
    local left = clock.read(CARD)
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)
    testing.eq(#logged, 1)
    testing.eq(nested.code, 1)
    testing.eq(first.code, nil)
    testing.eq(left, nil)
end)

testing.test("a failed log puts the clock back so it keeps running", function()
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local backend = {}
    function backend:log_time()
        return nil, "pomb is away"
    end
    local card = { id = CARD, labels = {} }
    clock.start(card, "reviewer")
    local result = clock.stop(backend, card, nil)
    local kept = clock.read(CARD)
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)
    testing.eq(result.code, 1)
    testing.ok(kept, "the clock was lost")
end)

local function logging_backend()
    local backend = { logged = {}, stages = board.stages({}, { support.COLUMN_NAME.DONE }) }
    function backend:log_time(id, minutes, role)
        self.logged[#self.logged + 1] = { id, minutes, role }
        return true
    end
    return backend
end

testing.test("a lapsed claim logs time only up to its last heartbeat", function()
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local started = os.time()
    local original = clock.now
    clock.now = function()
        return started
    end
    local began = clock.start({ id = CARD, labels = {} }, "implementer")
    local saved = claims.write({ card = CARD, fence = 1, pid = 0 })
    local beat = fs.write(clock.beat_path(CARD), string.format("%d\n", started + 10 * 60))
    local backend = logging_backend()
    local card = { id = CARD, name = "x", size = "3 Pomodori", labels = {} }
    local ticking = clock.sweep(backend, { card }, started + 60 * 60)
    local left = clock.read(CARD)
    clock.now = original
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)
    testing.eq(began.code, nil, began.message)
    testing.eq(saved, true)
    testing.eq(beat, true)
    testing.eq(backend.logged, { { CARD, 10, "implementer" } })
    testing.eq(ticking, {})
    testing.eq(left, nil)
end)

testing.test("a clock with no claim stops at twice the card's size", function()
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local started = os.time()
    local original = clock.now
    clock.now = function()
        return started
    end
    local began = clock.start({ id = CARD, labels = {} }, "reviewer")
    local backend = logging_backend()
    local card = { id = CARD, name = "x", size = "1 Pomodoro", labels = {} }
    local early = clock.sweep(backend, { card }, started + 30 * 60)
    local late = clock.sweep(backend, { card }, started + 3 * 60 * 60)
    clock.now = original
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)
    testing.eq(began.code, nil, began.message)
    testing.eq(#early, 1)
    testing.eq(late, {})
    testing.eq(backend.logged, { { CARD, 50, "reviewer" } })
end)

testing.test("a clock on a card of another board stays and logs nothing", function()
    local previous = os.getenv("XDG_STATE_HOME") or ""
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    local started = os.time()
    local original = clock.now
    clock.now = function()
        return started
    end
    local began = clock.start({ id = CARD, labels = {} }, "reviewer")
    local backend = logging_backend()
    local ticking, warnings = clock.sweep(backend, {}, started + 3 * 60 * 60)
    local kept = clock.read(CARD)
    clock.now = original
    ffi.C.setenv("XDG_STATE_HOME", previous, 1)
    testing.eq(began.code, nil, began.message)
    testing.eq(ticking, {})
    testing.eq(warnings, {})
    testing.eq(backend.logged, {})
    testing.eq(kept ~= nil, true)
end)

testing.test("finish passes on the reason and the detail of a refused release", function()
    local backend = {
        release = function()
            return nil, nil, board.ReleaseReason.NOT_HELD, CARD
        end,
    }
    testing.eq(
        { claims.finish(backend, CARD, { fence = 3 }) },
        { false, nil, board.ReleaseReason.NOT_HELD, CARD }
    )
end)
