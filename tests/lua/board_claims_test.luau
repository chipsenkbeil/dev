local testing = require("@dev/testing")
local claims = require("@dev/board/claims")
local board = require("@dev/board")
local clock = require("@dev/board/clock")
local cmd_board = require("@dev/cmd/board")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local support = require("./support")

local CARD = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
local POLLS = 50
local POLL_SECONDS = 0.1
local LAPSE_SECONDS = 3 * 60 * 60

local function spawn_loop()
    local out = dev_os.capture(
        { "sh", "-c", "sh -c 'sleep 30; :' __board keepalive >/dev/null 2>&1 & echo $!" },
        { stderr = "null" }
    )
    return assert(tonumber(out:match("%d+")), out)
end

local function running(pid)
    local out = dev_os.capture({ "ps", "-p", tostring(pid), "-o", "command=" }, { stderr = "null" })
    return out:find("__board keepalive", 1, true) ~= nil
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
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local old = spawn_loop()
    local new = spawn_loop()
    testing.ok(running(old), "the stub loop did not start")
    assert(claims.write({ card = CARD, fence = 4, pid = old }))

    -- Replace the claim and capture what happened
    local ok, message = claims.replace({ card = CARD, fence = 4, pid = new }, old)
    local old_ended = ended(old)
    local new_running = running(new)
    local state = claims.read(CARD)

    -- Stop the new loop and restore the environment
    dev_os.run({ "kill", tostring(new) }, { stderr = "null" })
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check the old loop ended and the claim names the new one
    testing.ok(ok, message)
    testing.ok(old_ended, "the old loop kept running")
    testing.ok(new_running, "the new loop was stopped")
    testing.eq(state.pid, new)
    testing.eq(state.fence, 4)
end)

testing.test("time start keeps a running clock and time stop logs it and removes it", function()
    -- Point the state at a scratch home and fake the clock and the backend
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
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
    local started = clock.start(card, support.ROLE.REVIEWER)
    local ticking = clock.read(CARD)
    clock.now = function()
        return 1000 + 25 * 60
    end
    local stopped = clock.stop(backend, card, "looked")
    local left = clock.read(CARD)

    -- Restore the environment
    clock.now = now
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check the clock ran, logged under its role and is gone
    testing.eq(started.output, "started the reviewer clock on 11111111")
    testing.eq(ticking.role, support.ROLE.REVIEWER)
    testing.eq(ticking.start, 1000)
    testing.eq(logged, { { CARD, 25, support.ROLE.REVIEWER, "looked" } })
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
    -- Block the claim's pending file in a scratch home
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local path = claims.path(CARD)
    assert(fs.mkdir(path .. ".new", { parents = true }))

    -- Write a claim into the blocked state
    local ok, message, reason, detail = claims.write({ card = CARD, fence = 1, pid = 1 })

    -- Restore the environment
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check the write reason and the blocked path come back
    testing.eq({ ok, message, reason, detail }, { nil, nil, board.FileReason.WRITE, path })
end)

testing.test("a take that cannot write its claim state prints the write sentence once", function()
    -- Block the claim's pending file in a scratch home
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local path = claims.path(CARD)
    assert(fs.mkdir(path .. ".new", { parents = true }))

    -- Take a card into the blocked state
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

    -- Restore the environment
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check the write sentence names the blocked path
    testing.eq(result.message, "Cannot write " .. path .. ".")
end)

testing.test("a take starts a clock under the role of the card's column", function()
    -- Point the state at a scratch home and pick the columns to take from
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local name = "dotfiles/implementer/11111111"
    local roles = {}
    local columns = {
        support.COLUMN_NAME.PROGRESS,
        support.COLUMN_NAME.REVIEW,
        support.COLUMN_NAME.BLOCKED,
    }

    -- Take a card from each column and note the role its clock counts for
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

    -- Restore the environment
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check each column counted for its own role
    testing.eq(roles, { support.ROLE.IMPLEMENTER, support.ROLE.REVIEWER, support.ROLE.LEAD })
end)

testing.test("column_role names every column's role and takes the claimant's for Ready", function()
    local stages = board.stages({}, { support.COLUMN_NAME.DONE })
    local who = "dotfiles/verifier/11111111"
    testing.eq(clock.column_role(stages, stages.icebox, who), support.ROLE.SCOPER)
    testing.eq(clock.column_role(stages, stages.backlog, who), support.ROLE.PLANNER)
    testing.eq(clock.column_role(stages, stages.progress, who), support.ROLE.IMPLEMENTER)
    testing.eq(clock.column_role(stages, stages.review, who), support.ROLE.REVIEWER)
    testing.eq(clock.column_role(stages, stages.blocked, who), support.ROLE.LEAD)
    testing.eq(clock.column_role(stages, stages.ready, who), support.ROLE.VERIFIER)
    testing.eq(clock.column_role(stages, stages.verify, who), support.ROLE.VERIFIER)
    testing.eq(clock.column_role(stages, support.COLUMN_NAME.DONE, who), nil)
end)

testing.test("time stop refuses a card with no running clock", function()
    -- Point the state at a scratch home
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())

    -- Stop a card that has no clock
    local result = clock.stop({}, { id = CARD }, nil)

    -- Restore the environment
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check the stop was refused
    testing.eq(result.code, 1)
end)

testing.test("a stop whose claim of the clock file fails logs nothing", function()
    -- Point the state at a scratch home and fake the backend
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local logged = {}
    local backend = {}
    function backend:log_time(id, minutes)
        logged[#logged + 1] = { id, minutes }
        return true
    end

    -- Age a clock past two hours with its stopping file already taken
    local card = { id = CARD, labels = {} }
    local restore = support.start_aged(card, support.ROLE.REVIEWER, 120)
    assert(fs.write(clock.stopping_path(CARD), "taken\n"))

    -- Stop the card and see what is left of its clock
    local result = clock.stop(backend, card, nil)
    local kept = clock.read(CARD)

    -- Restore the environment
    restore()
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check the stop failed, logged nothing and kept the clock
    testing.eq(result.code, 1)
    testing.eq(logged, {})
    testing.ok(kept, "the clock was lost")
end)

testing.test("a start clears a stop's leftover file so the next stop logs", function()
    -- Point the state at a scratch home and fake the backend
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local logged = {}
    local backend = {}
    function backend:log_time(id, minutes)
        logged[#logged + 1] = { id, minutes }
        return true
    end

    -- Leave a stop's file behind, then start an aged clock over it
    local card = { id = CARD, labels = {} }
    assert(fs.mkdir(claims.dir(), { parents = true }))
    assert(fs.write(clock.stopping_path(CARD), "left behind\n"))
    local restore = support.start_aged(card, support.ROLE.REVIEWER, 120)

    -- Stop the card
    local result = clock.stop(backend, card, nil)

    -- Restore the environment
    restore()
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check the stop went through and logged once
    testing.eq(result.code, nil)
    testing.eq(#logged, 1)
end)

testing.test("a stop called from inside the first stop's log logs once", function()
    -- Point the state at a scratch home and fake a backend that stops again while logging
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local logged = {}
    local nested
    local backend = {}
    local card = { id = CARD, labels = {} }
    function backend:log_time(id, minutes)
        logged[#logged + 1] = { id, minutes }
        nested = nested or clock.stop(backend, card, nil)
        return true
    end

    -- Age a clock past two hours and stop it
    local restore = support.start_aged(card, support.ROLE.REVIEWER, 120)
    local first = clock.stop(backend, card, nil)
    local left = clock.read(CARD)

    -- Restore the environment
    restore()
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check only the outer stop logged and the clock is gone
    testing.eq(#logged, 1)
    testing.eq(nested.code, 1)
    testing.eq(first.code, nil)
    testing.eq(left, nil)
end)

testing.test("a failed log puts the clock back so it keeps running", function()
    -- Point the state at a scratch home and fake a backend that fails to log
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local backend = {}
    function backend:log_time()
        return nil, "pomb is away"
    end

    -- Age a clock past two hours and stop it
    local card = { id = CARD, labels = {} }
    local restore = support.start_aged(card, support.ROLE.REVIEWER, 120)
    local result = clock.stop(backend, card, nil)
    local kept = clock.read(CARD)

    -- Restore the environment
    restore()
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check the stop failed and the clock is still there
    testing.eq(result.code, 1)
    testing.ok(kept, "the clock was lost")
end)

testing.test("a stretch under a minute logs nothing and still clears the clock", function()
    -- Point the state at a scratch home and fake the backend
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local logged = {}
    local backend = {}
    function backend:log_time(id, minutes)
        logged[#logged + 1] = { id, minutes }
        return true
    end

    -- Age a clock to 59 seconds and stop it twice
    local card = { id = CARD, labels = {} }
    local restore = support.start_aged(card, support.ROLE.REVIEWER, 59)
    local result = clock.stop(backend, card, nil)
    local left = clock.read(CARD)
    local again = clock.stop(backend, card, nil)

    -- Restore the environment
    restore()
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check nothing was logged and the clock is cleared
    testing.eq(result.output, "logged nothing as reviewer on 11111111, under a minute")
    testing.eq(logged, {})
    testing.eq(left, nil)
    testing.eq(again.code, 1)
end)

testing.test("a stretch of exactly a minute still logs one minute", function()
    -- Point the state at a scratch home and fake the backend
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local logged = {}
    local backend = {}
    function backend:log_time(id, minutes)
        logged[#logged + 1] = { id, minutes }
        return true
    end

    -- Age a clock to exactly a minute and stop it
    local card = { id = CARD, labels = {} }
    local restore = support.start_aged(card, support.ROLE.REVIEWER, 60)
    local result = clock.stop(backend, card, nil)

    -- Restore the environment
    restore()
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check one minute was logged
    testing.eq(result.output, "logged 1 minutes as reviewer on 11111111")
    testing.eq(logged, { { CARD, 1 } })
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
    -- Point the state at a scratch home and freeze the clock
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local started = os.time()
    local original = clock.now
    clock.now = function()
        return started
    end

    -- Start a clock with a claim whose last heartbeat came ten minutes in
    local began = clock.start({ id = CARD, labels = {} }, support.ROLE.IMPLEMENTER)
    local saved = claims.write({ card = CARD, fence = 1, pid = 0 })
    local beat = fs.write(clock.beat_path(CARD), string.format("%d\n", started + 10 * 60))

    -- Sweep an hour later
    local backend = logging_backend()
    local card = { id = CARD, name = "x", size = "3 Pomodori", labels = {} }
    local ticking = clock.sweep(backend, { card }, started + 60 * 60)
    local left = clock.read(CARD)

    -- Restore the environment
    clock.now = original
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check only the minutes up to the heartbeat were logged
    testing.eq(began.code, nil, began.message)
    testing.eq(saved, true)
    testing.eq(beat, true)
    testing.eq(backend.logged, { { CARD, 10, support.ROLE.IMPLEMENTER } })
    testing.eq(ticking, {})
    testing.eq(left, nil)
end)

testing.test("a clock with no claim stops at twice the card's size", function()
    -- Point the state at a scratch home and freeze the clock
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local started = os.time()
    local original = clock.now
    clock.now = function()
        return started
    end

    -- Start a clock on a one-Pomodoro card with no claim
    local began = clock.start({ id = CARD, labels = {} }, support.ROLE.REVIEWER)
    local backend = logging_backend()
    local card = { id = CARD, name = "x", size = "1 Pomodoro", labels = {} }

    -- Sweep before and after the clock reaches twice the card's size
    local early = clock.sweep(backend, { card }, started + 30 * 60)
    local late = clock.sweep(backend, { card }, started + LAPSE_SECONDS)

    -- Restore the environment
    clock.now = original
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check the clock ran until the later sweep stopped it
    testing.eq(began.code, nil, began.message)
    testing.eq(#early, 1)
    testing.eq(late, {})
    testing.eq(backend.logged, { { CARD, 50, support.ROLE.REVIEWER } })
end)

testing.test("a sweep that stops a clock within a minute logs nothing and clears it", function()
    -- Point the state at a scratch home and freeze the clock
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local original = clock.now
    clock.now = function()
        return support.CLOCK_START
    end

    -- Start a clock whose last heartbeat came thirty seconds in
    local began = clock.start({ id = CARD, labels = {} }, support.ROLE.REVIEWER)
    local beat = fs.write(clock.beat_path(CARD), string.format("%d\n", support.CLOCK_START + 30))

    -- Sweep once the lapse has passed
    local backend = logging_backend()
    local card = { id = CARD, name = "x", size = "1 Pomodoro", labels = {} }
    local ticking, warnings = clock.sweep(backend, { card }, support.CLOCK_START + LAPSE_SECONDS)
    local left = clock.read(CARD)

    -- Restore the environment
    clock.now = original
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check the clock was cleared without logging
    testing.eq(began.code, nil, began.message)
    testing.eq(beat, true)
    testing.eq(ticking, {})
    testing.eq(warnings, {})
    testing.eq(backend.logged, {})
    testing.eq(left, nil)
end)

testing.test("a clock on a card of another board stays and logs nothing", function()
    -- Point the state at a scratch home and freeze the clock
    local previous = dev_os.getenv("XDG_STATE_HOME") or ""
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local started = os.time()
    local original = clock.now
    clock.now = function()
        return started
    end

    -- Start a clock and sweep a board that lists no card for it
    local began = clock.start({ id = CARD, labels = {} }, support.ROLE.REVIEWER)
    local backend = logging_backend()
    local ticking, warnings = clock.sweep(backend, {}, started + LAPSE_SECONDS)
    local kept = clock.read(CARD)

    -- Restore the environment
    clock.now = original
    dev_os.setenv("XDG_STATE_HOME", previous)

    -- Check the clock stays and nothing was logged
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
