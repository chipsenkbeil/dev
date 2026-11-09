--[[
Run every test suite under tests/ and report each by name.
Each argument is a suite file or a directory under tests/ and narrows the run to the suites at that path.
A path that names no suite is a usage error.
A suite is a .bats file, a *_test.sh or test-*.sh script, or a *_test.lua file run with luajit.
The neomutt scripts run only when neomutt and tmux are both on PATH.
Suites run in parallel, DEV_TEST_JOBS at a time (the core count by default, 1 for one after another).
The suites that drive a terminal or compare help snapshots run one at a time.
]]
local checks = require("dotfiles.checks")
local devos = require("dev.os")
local fs = require("dev.fs")
local verb = require("dev.verb")

local ctx = ...
for _, arg in ipairs(ctx.args) do
    if arg:sub(1, 1) == "-" then
        verb.usage_error(ctx, "unknown flag " .. arg)
    end
end
verb.need("bats", "brew install bats-core")

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
    ["tests/dev/sync_test.sh"] = true,
    ["tests/dev/help_test.sh"] = true,
    ["tests/lua/help_test.lua"] = true,
    ["tests/tmux/conf_test.sh"] = true,
    ["tests/jj/land.bats"] = true,
    ["tests/neomutt/filter-bytes.sh"] = true,
    ["tests/neomutt/pager-passthrough.sh"] = true,
    ["tests/neomutt/parse-check.sh"] = true,
}

local function record_result(name, code)
    if code == 0 then
        stdout:write("PASS ", name, "\n")
        passed = passed + 1
    elseif code == SKIPPED then
        stdout:write("SKIP ", name, " (every case skipped)\n")
        skipped = skipped + 1
    else
        stdout:write("FAIL ", name, "\n")
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
            verb.die("DEV_TEST_JOBS must be a whole number of 1 or more, got " .. set)
        end
        return jobs
    end
    local probe = devos.name() == "Darwin" and { "sysctl", "-n", "hw.ncpu" } or { "nproc" }
    local out, code = devos.capture(probe, { stderr = "null" })
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

if devos.which("luajit") then
    for _, file in ipairs(checks.find(root, { "tests" }, { "-name", "*_test.lua" })) do
        suites[#suites + 1] = script_suite(file, { "luajit", "tests/lua/run.lua", file })
    end
else
    stdout:write("SKIP tests/lua (needs luajit)\n")
end

if devos.which("neomutt") and devos.which("tmux") then
    for _, name in ipairs({ "filter-bytes", "pager-passthrough" }) do
        local file = "tests/neomutt/" .. name .. ".sh"
        suites[#suites + 1] = script_suite(file, { "bash", file })
    end
    local parse = "tests/neomutt/parse-check.sh"
    local colors = "dotfiles/neomutt/.config/neomutt/colors.mutt"
    suites[#suites + 1] = script_suite(parse, { "bash", parse, colors })
else
    stdout:write("SKIP tests/neomutt/*.sh (needs neomutt and tmux on PATH)\n")
end

if #ctx.args > 0 then
    local chosen = {}
    for _, arg in ipairs(ctx.args) do
        local path = arg:gsub("^%./", ""):gsub("/+$", "")
        local found = false
        for _, suite in ipairs(suites) do
            if suite.name == path or suite.name:sub(1, #path + 1) == path .. "/" then
                chosen[suite] = true
                found = true
            end
        end
        if not found then
            verb.usage_error(ctx, "no suite at " .. arg)
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
    local out, code = devos.capture({ "mktemp", "-d", base .. "/dt.XXXXXX" })
    assert(code == 0, "dev test cannot make a scratch directory under " .. base)
    return (out:gsub("\n$", ""))
end

local scratch = scratch_dir()

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
devos.run({ "sh", "-c", GUARD, "sh", tostring(devos.getpid()), scratch })

local LAUNCH = [[
set -m
out=$1
status=$2
dir=$3
pidfile=$4
shift 4
(
    ( cd -- "$dir" && "$@" ) >"$out" 2>&1 </dev/null
    echo "$?" >"$status.tmp"
    mv "$status.tmp" "$status"
) >/dev/null 2>&1 </dev/null &
echo "$!" >"$pidfile"
echo "$!"
]]

local function start(index, suite)
    local base = scratch .. "/" .. index
    suite.out, suite.status, suite.tmp = base .. ".out", base .. ".status", base .. ".t"
    assert(fs.mkdir(suite.tmp))
    local argv = { "sh", "-c", LAUNCH, "sh", suite.out, suite.status, root, base .. ".pid" }
    for _, word in ipairs(suite.argv) do
        argv[#argv + 1] = word
    end
    local pid = devos.capture(argv, { env = { TMPDIR = suite.tmp } })
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
    local alive = devos.run({ "kill", "-0", suite.pid }, { stderr = "null" }) == 0
    if alive then
        return nil
    end
    return status_of(suite) or 1
end

local function stop_all()
    for _, suite in ipairs(suites) do
        if suite.pid and not suite.code then
            devos.run({ "kill", "--", "-" .. suite.pid }, { stderr = "null" })
        end
    end
end

local function report(suite, code)
    local output = fs.read(suite.out) or ""
    stdout:write("> ", suite.name, "\n")
    if suite.bats or output ~= "" then
        stdout:write(output, output:sub(-1) == "\n" and "" or "\n")
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
            devos.nap(POLL_SECS)
        end
    end
end

local ok, err = pcall(run_all)
if not ok then
    stop_all()
end
devos.run({ "rm", "-rf", "--", scratch })
if not ok then
    if tostring(err):find("interrupted!", 1, true) then
        os.exit(devos.SIGNAL_EXIT_BASE + SIGINT)
    end
    error(err, 0)
end

stdout:write(string.format("\n%d passed, %d failed, %d skipped\n", passed, failed, skipped))
stdout:flush()
if devos.getuid() ~= 0 or devos.name() ~= "Linux" then
    verb.note(
        "dev: the real-root cases of tests/dev/root_test.sh and tests/dev/tools_test.sh "
            .. "were skipped, run dev --remote test for them"
    )
end
return failed == 0 and 0 or 1
