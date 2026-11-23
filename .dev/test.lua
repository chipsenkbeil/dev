--[[
Run every test suite under tests/ and report each by name.
Each argument is a suite file or a directory under tests/ and narrows the run to the suites at that path.
A path that names no suite is a usage error, and one under a group skipped on this machine says it is skipped here.
A suite is a .bats file, a *_test.sh or test-*.sh script, or a *_test.lua file run with luajit.
Suites run in parallel, DEV_TEST_JOBS at a time (the core count by default, 1 for one after another).
The suites that drive a terminal or compare help snapshots run one at a time.
]]
local checks = require("devrepo.checks")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local dev_command = require("dev.command")

local ctx = ...
for _, arg in ipairs(ctx.args) do
    if arg:sub(1, 1) == "-" then
        dev_command.usage_error(ctx, "Unknown flag " .. arg .. ".")
    end
end
dev_command.need("bats", "brew install bats-core")

local root = ctx.root
local stdout = io.stdout
local SKIPPED = 3
local SIGINT = 2
local POLL_SECS = 0.1
local ALIVE_POLLS = 50
local MAX_TMP_BASE_CHARS = 40
local passed, failed, skipped = 0, 0, 0

local SERIAL = {
    ["tests/dev/term.bats"] = true,
    ["tests/dev/picker.bats"] = true,
    ["tests/dev/confirm.bats"] = true,
    ["tests/dev/pager.bats"] = true,
    ["tests/dev/help_test.sh"] = true,
    ["tests/lua/help_test.lua"] = true,
}

local function record_result(name, code)
    if code == 0 then
        dev_command.say("PASS " .. name)
        passed = passed + 1
    elseif code == SKIPPED then
        dev_command.say("SKIP " .. name .. " (every case skipped)")
        skipped = skipped + 1
    else
        dev_command.say("FAIL " .. name)
        failed = failed + 1
    end
end

local function ran_a_case(output)
    for line in output:gmatch("[^\n]+") do
        if line:find("^ok ") and not line:find("# skip", 1, true) then
            return true
        end
    end
    return false
end

local function job_count()
    local set = os.getenv("DEV_TEST_JOBS")
    if set and set ~= "" then
        local jobs = set:match("^%d+$") and tonumber(set)
        if not jobs or jobs < 1 then
            dev_command.die("DEV_TEST_JOBS must be a whole number of 1 or more, got " .. set)
        end
        return jobs
    end
    local probe = dev_os.name() == "Darwin" and { "sysctl", "-n", "hw.ncpu" } or { "nproc" }
    local out, code = dev_os.capture(probe, { stderr = "null" })
    local cores = code == 0 and tonumber(out:match("%d+")) or 1
    return math.max(cores, 1)
end

local function bats_suite(file)
    return {
        name = file,
        argv = { "bats", "--tap", file },
        bats = true,
    }
end

local function script_suite(file, argv)
    return { name = file, argv = argv }
end

local suites = {}
for _, file in ipairs(checks.bats_files(root)) do
    suites[#suites + 1] = bats_suite(file)
end

local scripts = { "(", "-name", "*_test.sh", "-o", "-name", "test-*.sh", ")" }
for _, file in ipairs(checks.find(root, { "tests" }, scripts)) do
    suites[#suites + 1] = script_suite(file, { "bash", file })
end

local function under(path, dir)
    return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

local unavailable = {}

if dev_os.which("luajit") then
    for _, file in ipairs(checks.find(root, { "tests" }, { "-name", "*_test.lua" })) do
        suites[#suites + 1] = script_suite(file, { "luajit", "tests/lua/run.lua", file })
    end
else
    dev_command.say("SKIP tests/lua (needs luajit)")
    unavailable[#unavailable + 1] = { dir = "tests/lua", why = "needs luajit" }
end

if #ctx.args > 0 then
    local chosen = {}
    for _, arg in ipairs(ctx.args) do
        local path = arg:gsub("^%./", ""):gsub("/+$", "")
        local found = false
        for _, suite in ipairs(suites) do
            if under(suite.name, path) then
                chosen[suite] = true
                found = true
            end
        end
        if not found then
            for _, skip in ipairs(unavailable) do
                if under(path, skip.dir) then
                    dev_command.usage_error(ctx, arg .. " is skipped here. It " .. skip.why .. ".")
                end
            end
            dev_command.usage_error(ctx, "no suite at " .. arg)
        end
    end
    local kept = {}
    for _, suite in ipairs(suites) do
        if chosen[suite] then
            kept[#kept + 1] = suite
        end
    end
    suites = kept
end

for _, suite in ipairs(suites) do
    suite.serial = SERIAL[suite.name] == true
end

local jobs = job_count()
local function scratch_dir()
    local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
    if #base > MAX_TMP_BASE_CHARS or base:sub(1, 1) ~= "/" then
        base = "/tmp"
    end
    local out, code = dev_os.capture({ "mktemp", "-d", base .. "/dt.XXXXXX" })
    assert(code == 0, "`dev test` cannot make a scratch directory under " .. base .. ".")
    return (out:gsub("\n$", ""))
end

local scratch = scratch_dir()
local stop_marker = scratch .. "/stop"

local GUARD = [=[
set -m
watched=$1
scratch=$2
(
    trap '' INT TERM HUP
    while [ -d "$scratch" ] && kill -0 "$watched" 2>/dev/null; do sleep 0.2; done
    if [ -d "$scratch" ]; then
        for sig in TERM KILL; do
            for pidfile in "$scratch"/*.pid; do
                [ -f "$pidfile" ] && [ ! -e "${pidfile%.pid}.status" ] &&
                    kill -"$sig" -- "-$(cat "$pidfile")" 2>/dev/null
            done
            [ "$sig" = TERM ] && sleep 1
        done
        sleep 0.5
        rm -rf -- "$scratch" || { sleep 1; rm -rf -- "$scratch"; }
    fi
) </dev/null >/dev/null 2>&1 &
]=]
dev_os.run({ "sh", "-c", GUARD, "sh", tostring(dev_os.getpid()), scratch })

local LAUNCH = [[
set -m
trap '' INT
out=$1
status=$2
dir=$3
pidfile=$4
stopfile=$5
shift 5
(
    trap - INT
    ( cd -- "$dir" && "$@" ) >"$out" 2>&1 </dev/null
    echo "$?" >"$status.tmp"
    mv "$status.tmp" "$status"
) >/dev/null 2>&1 </dev/null &
{ echo "$!" >"$pidfile"; } 2>/dev/null
if [ -e "$stopfile" ] || [ ! -d "${stopfile%/*}" ]; then
    kill -TERM -- "-$!" 2>/dev/null
fi
echo "$!"
]]

local function start(index, suite)
    local base = scratch .. "/" .. index
    suite.out, suite.status, suite.tmp = base .. ".out", base .. ".status", base .. ".t"
    assert(fs.mkdir(suite.tmp))
    suite.pidfile = base .. ".pid"
    local argv =
        { "sh", "-c", LAUNCH, "sh", suite.out, suite.status, root, suite.pidfile, stop_marker }
    for _, word in ipairs(suite.argv) do
        argv[#argv + 1] = word
    end
    local pid = dev_os.capture(argv, {
        env = { TMPDIR = suite.tmp, DEV_FROM = "checkout" },
    })
    suite.pid = pid:match("%d+")
    suite.started = true
end

local function status_of(suite)
    local text = fs.read(suite.status)
    return text and (tonumber(text:match("%d+")) or 1)
end

local function finished(suite, check_alive)
    local code = status_of(suite)
    if code or not check_alive or not suite.pid then
        return code
    end
    local alive = dev_os.run({ "kill", "-0", suite.pid }, { stderr = "null" }) == 0
    if alive then
        return nil
    end
    return status_of(suite) or 1
end

local STOP = [=[
for pidfile in "$1"/*.pid; do
    [ -f "$pidfile" ] && [ ! -e "${pidfile%.pid}.status" ] &&
        kill -TERM -- "-$(cat "$pidfile")" 2>/dev/null
done
exit 0
]=]

local function stop_all()
    fs.write(stop_marker, "")
    dev_os.run({ "sh", "-c", STOP, "sh", scratch }, { stderr = "null" })
end

local function report(suite, code)
    local output = fs.read(suite.out) or ""
    dev_command.say("> " .. suite.name)
    if suite.bats or output ~= "" then
        dev_command.say((output:gsub("\n$", "")))
    end
    if suite.bats and code == 0 and not ran_a_case(output) then
        code = SKIPPED
    end
    record_result(suite.name, code)
end

local function run_all()
    local running, serial_busy, shown, done, polls = 0, false, 0, 0, 0
    local total = #suites
    while done < total do
        polls = polls + 1
        local check_alive = polls % ALIVE_POLLS == 0
        for _, suite in ipairs(suites) do
            if suite.started and not suite.code then
                suite.code = finished(suite, check_alive)
                if suite.code then
                    running = running - 1
                    done = done + 1
                    serial_busy = serial_busy and not suite.serial
                end
            end
        end
        for index, suite in ipairs(suites) do
            if running >= jobs then
                break
            end
            if not suite.started and not (suite.serial and serial_busy) then
                start(index, suite)
                running = running + 1
                serial_busy = serial_busy or suite.serial
            end
        end
        while shown < total and suites[shown + 1].code do
            shown = shown + 1
            report(suites[shown], suites[shown].code)
            stdout:flush()
        end
        if done < total then
            dev_os.nap(POLL_SECS)
        end
    end
end

local ok, err = pcall(run_all)
if not ok then
    stop_all()
end
dev_os.run({ "rm", "-rf", "--", scratch })
if not ok then
    if tostring(err):find("interrupted!", 1, true) then
        os.exit(dev_os.SIGNAL_EXIT_BASE + SIGINT)
    end
    error(err, 0)
end

dev_command.say(string.format("\n%d passed, %d failed, %d skipped", passed, failed, skipped))
stdout:flush()
if dev_os.getuid() ~= 0 or dev_os.name() ~= "Linux" then
    dev_command.note(
        "The real-root cases of tests/dev/root_test.sh and tests/dev/tools_test.sh "
            .. "were skipped. Run `dev --remote test` for them."
    )
end
return failed == 0 and 0 or 1
