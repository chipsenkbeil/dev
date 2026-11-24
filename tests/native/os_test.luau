local dev_os = require("dev.os")
local runtime = require("dev.runtime")

local here = arg[0]:match("^(.*)/[^/]*$") or "."
local failures = 0

local EXIT_NOT_FOUND = 127
local EXIT_NOT_EXECUTABLE = 126
local EXIT_TIMEOUT = 124
local EXIT_TERM = 143
local EXIT_INT = 130
local EXIT_HUP = 129
local POLLS = 100
local SHORT_POLLS = 20
local POLL_SECONDS = 0.1
local MEGABYTE = 1000000

local function check(name, body)
    local ok, err = pcall(body)
    if ok then
        print("ok   " .. name)
    else
        failures += 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local function same(actual, expected)
    if actual ~= expected then
        error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
    end
end

local function holds(text, part)
    if not tostring(text):find(part, 1, true) then
        error(string.format("expected %q inside %q", part, tostring(text)), 2)
    end
end

local function scratch()
    local dir = dev_os.capture({ "mktemp", "-d" })
    return (dir:gsub("\n$", ""))
end

local function wait_for(path, text)
    for _ = 1, POLLS do
        local content = dev_os.capture({ "cat", path }, { stderr = "null" })
        if content:find(text, 1, true) then
            return content
        end
        dev_os.nap(POLL_SECONDS)
    end
    error("timed out waiting for " .. text .. " in " .. path)
end

check("argv words with spaces and quotes reach the child unchanged", function()
    local hostile = "a b;$(id)'\"`\\ -x"
    local out, code = dev_os.capture({ "printf", "%s", hostile })
    same(out, hostile)
    same(code, 0)
end)

check("capture keeps stdout and the status apart from stderr", function()
    local out, code = dev_os.capture(
        { "sh", "-c", "echo out; echo err >&2; exit 3" },
        { stderr = "null" }
    )
    same(out, "out\n")
    same(code, 3)
    out = dev_os.capture({ "sh", "-c", "echo out; echo err >&2" }, { stderr = "stdout" })
    same(out, "out\nerr\n")
end)

check("capture_input sends the input through a pipe", function()
    local out, code = dev_os.capture_input({ "cat" }, "secret\n")
    same(out, "secret\n")
    same(code, 0)
    same((pcall(dev_os.capture_input, { "cat" }, "x", { stdout = "null" })), false)
end)

check("run returns the exit status and 128 plus the signal", function()
    same(dev_os.run({ "sh", "-c", "exit 7" }), 7)
    same(dev_os.run({ "sh", "-c", "kill -TERM $$" }), EXIT_TERM)
end)

check("env, unset and defaults reach the child", function()
    dev_os.defaults.env.DEV_TEST_DEFAULT = "low"
    local out = dev_os.capture(
        { "sh", "-c", 'printf %s "$DEV_TEST_DEFAULT"' },
        { env = { DEV_TEST_DEFAULT = "high" } }
    )
    same(out, "high")
    out = dev_os.capture(
        { "sh", "-c", 'printf %s "${DEV_TEST_DEFAULT-gone}"' },
        { unset = { "DEV_TEST_DEFAULT" } }
    )
    same(out, "gone")
    dev_os.defaults.env.DEV_TEST_DEFAULT = nil
    same((pcall(dev_os.run, { "true" }, { env = { ["BAD-NAME"] = "x" } })), false)
end)

check("setenv sets and unsets for dev and its children", function()
    dev_os.setenv("DEV_TEST_SETENV", "a b")
    same(dev_os.getenv("DEV_TEST_SETENV"), "a b")
    same(dev_os.vars().DEV_TEST_SETENV, "a b")
    same(dev_os.capture({ "sh", "-c", 'printf %s "$DEV_TEST_SETENV"' }), "a b")
    dev_os.setenv("DEV_TEST_SETENV", nil)
    same(dev_os.getenv("DEV_TEST_SETENV"), nil)
end)

check("cwd and stdout paths resolve as the old shell line did", function()
    local dir = scratch()
    local log = dir .. "/log"
    dev_os.run({ "sh", "-c", "pwd; echo more" }, { cwd = dir, stdout = log })
    dev_os.run({ "sh", "-c", "echo again" }, { cwd = dir, stdout = log })
    local content = dev_os.capture({ "cat", log })
    holds(content, "more\nagain\n")
    dev_os.run({ "rm", "-rf", "--", dir })
end)

check("a missing binary gives 127 and a directory gives 126", function()
    same(dev_os.run({ "/no/such/program" }), EXIT_NOT_FOUND)
    same(dev_os.run({ "/" }), EXIT_NOT_EXECUTABLE)
    local out, code = dev_os.capture({ "no-such-program-anywhere" })
    same(out, "")
    same(code, EXIT_NOT_FOUND)
    local proc, reason = dev_os.spawn({ "/no/such/program" })
    same(proc, nil)
    holds(reason, "/no/such/program")
    local ok, message = dev_os.exec({ "/no/such/program" })
    same(ok, nil)
    holds(message, "No such file")
end)

check("capture_timed collects output, input and the status", function()
    local out, code = dev_os.capture_timed(
        { "sh", "-c", "cat; echo out; exit 3" },
        10,
        { input = "in\n" }
    )
    same(out, "in\nout\n")
    same(code, 3)
    out = dev_os.capture_timed({ "sh", "-c", "echo out; echo err >&2" }, 10, { merge = true })
    same(out, "out\nerr\n")
end)

check("capture_timed hands output to on_text as it arrives", function()
    local chunks = {}
    local out = dev_os.capture_timed({ "sh", "-c", "echo first; sleep 1; echo second" }, 30, {
        on_text = function(text)
            table.insert(chunks, text)
        end,
    })
    same(table.concat(chunks), out)
    same(out, "first\nsecond\n")
    same(#chunks >= 2, true)
end)

check("a timed run kills a grandchild and returns 124", function()
    local unique = 1000000 + dev_os.getpid()
    local out, code = dev_os.capture_timed({
        "sh",
        "-c",
        ("echo before; sleep %d >/dev/null 2>&1 & sleep %d >/dev/null 2>&1; wait"):format(
            unique,
            unique + 1
        ),
    }, 1, { merge = true })
    same(code, EXIT_TIMEOUT)
    same(out, "before\n")
    local left = ""
    for _ = 1, SHORT_POLLS do
        left = dev_os.capture(
            { "pgrep", "-f", ("^sleep (%d|%d)$"):format(unique, unique + 1) },
            { stderr = "null" }
        )
        if left == "" then
            break
        end
        dev_os.nap(POLL_SECONDS)
    end
    same(left, "")
end)

check("capture_timed and capture hide or redirect stderr", function()
    local out = dev_os.capture_timed(
        { "sh", "-c", "echo out; echo err >&2" },
        10,
        { stderr = "null" }
    )
    same(out, "out\n")
    out = dev_os.capture({ "sh", "-c", "echo out; echo err >&2" }, { stderr = "inherit" })
    same(out, "out\n")
end)

check("reap kills what a finished command left running", function()
    local unique = 2000000 + dev_os.getpid()
    local out, code = dev_os.capture_timed(
        { "sh", "-c", ("sleep %d >/dev/null 2>&1 & echo done"):format(unique) },
        10,
        { reap = true }
    )
    same(code, 0)
    same(out, "done\n")
    local left = ""
    for _ = 1, SHORT_POLLS do
        left = dev_os.capture({ "pgrep", "-f", ("^sleep %d$"):format(unique) }, { stderr = "null" })
        if left == "" then
            break
        end
        dev_os.nap(POLL_SECONDS)
    end
    same(left, "")
end)

check("a timed run with no limit runs to completion, and a signal death reports 124", function()
    local out, code = dev_os.capture_timed({ "sh", "-c", "sleep 1; echo late" }, 0)
    same(out, "late\n")
    same(code, 0)
    local _, killed = dev_os.capture_timed({ "sh", "-c", "exec kill -TERM $$" }, 10)
    same(killed, EXIT_TIMEOUT)
end)

check("spawn waits, kills the group and reports status", function()
    local proc = assert(dev_os.spawn({ "sh", "-c", "sleep 30" }))
    same(type(proc.pid), "number")
    same(proc:wait(0.2), nil)
    same(proc:kill("TERM"), true)
    same(proc:wait(5), EXIT_TERM)
    local quick = assert(dev_os.spawn({ "sh", "-c", "exit 4" }, { stdout = "null" }))
    same(quick:wait(5), 4)
end)

check("a command killed by a signal runs its cleanup and exits 128 plus the signal", function()
    local dir = scratch()
    for _, case in ipairs({ { "TERM", EXIT_TERM }, { "INT", EXIT_INT }, { "HUP", EXIT_HUP } }) do
        local log = dir .. "/" .. case[1]
        local proc = assert(
            dev_os.spawn({ runtime.exe, "-l", here .. "/fixtures/wait.luau" }, { stdout = log })
        )
        wait_for(log, "ready")
        proc:kill(case[1])
        same(proc:wait(10), case[2])
        same(dev_os.capture({ "cat", log }), "ready\ncleanup\n")
    end
    dev_os.run({ "rm", "-rf", "--", dir })
end)

check("capture keeps a megabyte on stdout and on stderr when they merge", function()
    local out, code = dev_os.capture({
        "sh",
        "-c",
        ("head -c %d /dev/zero; head -c %d /dev/zero >&2"):format(MEGABYTE, MEGABYTE),
    }, { stderr = "stdout" })
    same(#out, 2 * MEGABYTE)
    same(code, 0)
end)

check("capture_input passes a large input through to a large output", function()
    local input = ("x"):rep(MEGABYTE)
    local out, code = dev_os.capture_input({ "cat" }, input)
    same(#out, MEGABYTE)
    same(code, 0)
end)

check("capture_timed and spawn see the environment overlay", function()
    dev_os.setenv("DEV_TEST_OVERLAY", "seen")
    same(dev_os.capture_timed({ "sh", "-c", "echo $DEV_TEST_OVERLAY" }, 10), "seen\n")
    local dir = scratch()
    local proc =
        assert(dev_os.spawn({ "sh", "-c", "echo $DEV_TEST_OVERLAY" }, { stdout = dir .. "/out" }))
    same(proc:wait(5), 0)
    same(dev_os.capture({ "cat", dir .. "/out" }), "seen\n")
    dev_os.run({ "rm", "-rf", "--", dir })
end)

check("a signal during capture_timed raises the interrupt and ends the group", function()
    local dir = scratch()
    local unique = 3000000 + dev_os.getpid()
    local log = dir .. "/log"
    local proc = assert(dev_os.spawn({ runtime.exe, "-l", here .. "/fixtures/timed.luau" }, {
        stdout = log,
        env = { DEV_TEST_UNIQUE = tostring(unique) },
    }))
    wait_for(log, "ready")
    local pattern = ("^sleep (%d|%d)$"):format(unique, unique + 1)
    for _ = 1, POLLS do
        if dev_os.capture({ "pgrep", "-f", pattern }, { stderr = "null" }) ~= "" then
            break
        end
        dev_os.nap(POLL_SECONDS)
    end
    proc:kill("TERM")
    same(proc:wait(10), EXIT_TERM)
    same(dev_os.capture({ "cat", log }), "ready\n")
    local left = "x"
    for _ = 1, SHORT_POLLS do
        left = dev_os.capture({ "pgrep", "-f", pattern }, { stderr = "null" })
        if left == "" then
            break
        end
        dev_os.nap(POLL_SECONDS)
    end
    same(left, "")
    dev_os.run({ "rm", "-rf", "--", dir })
end)

check("a closed pipe ends dev quietly", function()
    local line = ("%q -l %q | head -n 1"):format(runtime.exe, here .. "/fixtures/flood.luau")
    local out, code = dev_os.capture({ "sh", "-c", line }, { stderr = "stdout" })
    same(out, "1\n")
    same(code, 0)
end)

check("quote and command stay pure helpers", function()
    same(dev_os.quote("it's"), "'it'\\''s'")
    same(dev_os.command({ "a b", "c" }), "'a b' 'c'")
    same((pcall(dev_os.quote, "a\0b")), false)
    same((pcall(dev_os.command, {})), false)
end)

check("kind_of, name, arch, which, isatty and random_bytes", function()
    same(dev_os.kind_of(0x81A4), "file")
    same(dev_os.kind_of(0x41ED), "dir")
    same(dev_os.kind_of(0xA1FF), "link")
    same(dev_os.kind_of(0x1000), "other")
    local name = dev_os.name()
    same(name == "Darwin" or name == "Linux", true)
    same(type(dev_os.arch()), "string")
    same(dev_os.which("sh"):sub(1, 1), "/")
    same(dev_os.which("no-such-program-anywhere"), nil)
    same(dev_os.isatty(7), false)
    same(#assert(dev_os.random_bytes(16)), 16)
    same(dev_os.monotonic() >= 0, true)
end)

if failures > 0 then
    print(failures .. " failed")
    dev_os.exit(1)
end
