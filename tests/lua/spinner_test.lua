local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")
local testing = require("dev.testing")
local ui = require("dev.ui")

local INTERRUPTED_CODE = 130
local JOB_PID = "4242"

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

local function is_stop(argv)
    return argv[1] == "sh" and argv[3] ~= nil and argv[3]:find("kill -s TERM", 1, true) ~= nil
end

local function is_launch(argv)
    return argv[1] == "sh" and argv[3] ~= nil and argv[3]:find('trap "hit=1" INT', 1, true) ~= nil
end

local function is_poll(argv)
    return argv[1] == "sh" and argv[3] ~= nil and argv[3]:find("kill -0", 1, true) ~= nil
end

local function interrupt()
    error("interrupted!", 0)
end

local function on_terminal(handlers, body)
    local tmp = support.tempdir()
    local ctx = ui.context({
        color = false,
        interactive = true,
        width = 80,
        getenv = function(name)
            if name == "TMPDIR" then
                return tmp
            end
            return nil
        end,
    })
    local real_run, real_capture, real_isatty = dev_os.run, dev_os.capture, dev_os.isatty
    dev_os.isatty = function()
        return true
    end
    dev_os.run = function(argv, opts)
        return (handlers.run and handlers.run(argv, real_run)) or real_run(argv, opts)
    end
    dev_os.capture = function(argv, opts)
        if handlers.capture then
            local out, code = handlers.capture(argv)
            if out then
                return out, code
            end
        end
        return real_capture(argv, opts)
    end
    local ok, err = pcall(body, ctx, tmp)
    dev_os.run, dev_os.capture, dev_os.isatty = real_run, real_capture, real_isatty
    fs.remove(tmp, { recursive = true })
    assert(ok, err)
end

testing.test(
    "a second ctrl-c during cleanup still stops the job and removes the directory",
    function()
        local stops, pids = 0, {}
        local dir
        on_terminal({
            capture = function(argv)
                if is_launch(argv) then
                    return JOB_PID .. "\n", 0
                end
                if is_poll(argv) then
                    return "", INTERRUPTED_CODE
                end
            end,
            run = function(argv)
                if argv[1] == "mkdir" then
                    dir = argv[5]
                end
                if is_stop(argv) then
                    stops = stops + 1
                    pids[#pids + 1] = argv[5]
                    if stops == 1 then
                        interrupt()
                    end
                    return stops == 2 and INTERRUPTED_CODE or 0
                end
            end,
        }, function(ctx)
            testing.eq(ui.spin(ctx, "x", { "sleep", "9" }), INTERRUPTED_CODE)
            testing.eq(pids, { JOB_PID, JOB_PID, JOB_PID })
            testing.ok(dir ~= nil and not fs.exists(dir), "the temp directory is still there")
        end)
    end
)

testing.test("a ctrl-c during mktemp exits 130 and leaves no temp directory", function()
    on_terminal({
        capture = function(argv)
            if argv[1] == "mktemp" then
                error("capture lost the exit status of mktemp", 0)
            end
        end,
    }, function(ctx, tmp)
        testing.eq(ui.spin(ctx, "x", { "sleep", "9" }), INTERRUPTED_CODE)
        testing.eq(#fs.list(tmp), 0)
    end)
end)

testing.test("a ctrl-c that lands once mkdir made the directory removes it", function()
    local dir
    on_terminal({
        run = function(argv, real_run)
            if argv[1] == "mkdir" then
                dir = argv[5]
                real_run(argv)
                return INTERRUPTED_CODE
            end
        end,
    }, function(ctx, tmp)
        testing.eq(ui.spin(ctx, "x", { "sleep", "9" }), INTERRUPTED_CODE)
        testing.ok(dir ~= nil, "mkdir never ran")
        testing.eq(#fs.list(tmp), 0)
    end)
end)

testing.test("a launcher that fails after backgrounding the job stops it", function()
    local pids = {}
    on_terminal({
        capture = function(argv)
            if is_launch(argv) then
                assert(fs.write(argv[5] .. "/pid", JOB_PID .. "\n"))
                return "", 1
            end
        end,
        run = function(argv)
            if is_stop(argv) then
                pids[#pids + 1] = argv[5]
                return 0
            end
        end,
    }, function(ctx, tmp)
        testing.eq(ui.spin(ctx, "x", { "sleep", "9" }), 1)
        testing.eq(pids, { JOB_PID })
        testing.eq(#fs.list(tmp), 0)
    end)
end)
