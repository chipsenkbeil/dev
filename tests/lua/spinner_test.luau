local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local testing = require("@dev/testing")
local ui = require("@dev/ui")

local INTERRUPTED_CODE = 130

local plain = ui.context({ color = false, interactive = false, width = 80 })

testing.test("spinner_line joins glyph, label, detail and elapsed time", function()
    testing.eq(
        ui.spinner_line(plain, {
            frame = 5,
            label = "Creating myproject-wqz",
            detail = "cloning myproject",
            seconds = 41,
        }),
        "⠼ Creating myproject-wqz · cloning myproject 0:41"
    )
end)

testing.test("spinner_line wraps the frame after the tenth", function()
    testing.eq(
        ui.spinner_line(plain, { frame = 11, label = "x", detail = "y", seconds = 0 }),
        "⠋ x · y 0:00"
    )
end)

testing.test("spinner_line drops the separator when there is no detail", function()
    testing.eq(
        ui.spinner_line(plain, { frame = 1, label = "x", detail = "", seconds = 75 }),
        "⠋ x 1:15"
    )
end)

testing.test("spin without a terminal returns the exit code", function()
    testing.eq(ui.spin(plain, "x", { "sh", "-c", "exit 4" }), 4)
end)

testing.test("spin with capture and no terminal returns the code and standard output", function()
    local code, out = ui.spin(plain, "x", { "sh", "-c", "echo hi; echo no >&2; exit 4" }, {
        capture = true,
    })
    testing.eq(code, 4)
    testing.eq(out, "hi\n")
end)

local function interrupt()
    error("interrupted!", 0)
end

local function on_terminal(handlers, body)
    -- Make an interactive context
    local ctx = ui.context({
        color = false,
        interactive = true,
        width = 80,
        getenv = function()
            return nil
        end,
    })

    -- Fake the terminal, the temp files and the spawn
    local made = {}
    local real_mktemp, real_spawn, real_isatty = fs.mktemp, dev_os.spawn, dev_os.isatty
    dev_os.isatty = function()
        return true
    end
    fs.mktemp = function(opts)
        if handlers.mktemp then
            handlers.mktemp(#made)
        end
        local path = real_mktemp(opts)
        made[#made + 1] = path
        return path
    end
    dev_os.spawn = handlers.spawn

    -- Run the body, then put the real functions back
    local ok, err = pcall(body, ctx, made)
    fs.mktemp, dev_os.spawn, dev_os.isatty = real_mktemp, real_spawn, real_isatty

    -- Remove the temp files the body left
    for _, path in ipairs(made) do
        fs.remove(path)
    end
    assert(ok, err)
end

local function gone(made)
    for _, path in ipairs(made) do
        if fs.exists(path) then
            return false
        end
    end
    return #made > 0
end

local function fake_job(waits)
    local job = { kills = {} }
    job.pid = 4242
    function job:kill(signal)
        self.kills[#self.kills + 1] = signal
        return true
    end
    function job:wait()
        return waits(self)
    end
    return job
end

testing.test("a second ctrl-c during cleanup still kills the job and removes the files", function()
    local job = fake_job(function()
        interrupt()
    end)
    on_terminal({
        spawn = function()
            return job
        end,
    }, function(ctx, made)
        testing.eq(ui.spin(ctx, "x", { "sleep", "9" }), INTERRUPTED_CODE)
        testing.eq(job.kills, { "TERM", "KILL" })
        testing.ok(gone(made), "a temp file is still there")
    end)
end)

testing.test("a ctrl-c during the second mktemp exits 130 and leaves no temp file", function()
    on_terminal({
        mktemp = function(count)
            if count == 1 then
                interrupt()
            end
        end,
        spawn = function()
            error("the job should not start")
        end,
    }, function(ctx, made)
        testing.eq(ui.spin(ctx, "x", { "sleep", "9" }, { capture = true }), INTERRUPTED_CODE)
        testing.ok(gone(made), "a temp file is still there")
    end)
end)

testing.test("a ctrl-c while the job runs stops it once and removes the files", function()
    local waits = 0
    local job = fake_job(function()
        waits = waits + 1
        if waits == 1 then
            interrupt()
        end
        return 143
    end)
    on_terminal({
        spawn = function()
            return job
        end,
    }, function(ctx, made)
        testing.eq(ui.spin(ctx, "x", { "sleep", "9" }), INTERRUPTED_CODE)
        testing.eq(job.kills, { "TERM" })
        testing.ok(gone(made), "a temp file is still there")
    end)
end)

testing.test("a job that cannot start returns 126 and leaves no temp file", function()
    on_terminal({
        spawn = function()
            return nil, "no such program"
        end,
    }, function(ctx, made)
        testing.eq(ui.spin(ctx, "x", { "sleep", "9" }), dev_os.EXEC_FAILED)
        testing.ok(gone(made), "a temp file is still there")
    end)
end)
