--[[
group: Check your work
Run the signal tests in a loop beside CPU burners, on a ci host only.
usage: dev --remote soak [-- --runs N]
flags: --runs
Each run starts two busy loops per core, runs one case, prints the load it ran under and stops the
loops. The cases are the pkg_script TERM test, the confirm and spin ctrl-c tests and the guide
interrupt tests. A case that fails keeps its output in the report, and a case that ran no test
fails. The verb exits 1 when any run failed. N is 50 by default.
]]
local dev_os = require("dev.os")
local remote = require("dev.remote")
local dev_command = require("dev.command")

local ctx = ...

local DEFAULT_RUNS = 50
local BURNERS_PER_CORE = 2
local CASE_TIMEOUT_SECS = 300
local stdout = io.stdout

local WRAPPER = [=[
cores=$(nproc)
burners=$((cores * %d))
for _ in $(seq "$burners"); do
    ( while :; do :; done ) &
done
trap 'kill $(jobs -p) 2>/dev/null' EXIT
trap 'exit 130' INT TERM
"$@"
code=$?
read -r load _ _ running _ </proc/loadavg
printf 'load: %%s burners, %%s cores, loadavg %%s, runnable %%s\n' "$burners" "$cores" "$load" "${running%%%%/*}"
exit $code
]=]

local CASES = {
    {
        name = "pkg_script TERM",
        argv = {
            "luajit",
            "tests/lua/run.lua",
            "tests/lua/pkg_script_test.lua",
            "wrapper gets TERM",
        },
    },
    {
        name = "confirm and spin ctrl-c",
        argv = { "bats", "--tap", "--filter", "ctrl-c", "tests/dev/confirm.bats" },
    },
    {
        name = "guide interrupt",
        argv = {
            "bats",
            "--tap",
            "--filter",
            "Ctrl-C removes|interrupted run on a terminal|TERM to the launcher alone",
            "tests/guide/guide.bats",
        },
    },
}

local function runs_wanted()
    local args = ctx.args
    if #args == 0 then
        return DEFAULT_RUNS
    end
    local given = args[1] == "--runs" and args[2] or args[1]:match("^%-%-runs=(.*)$")
    local count = given and given:match("^%d+$") and tonumber(given)
    local words = args[1] == "--runs" and 2 or 1
    if #args ~= words or not count or count < 1 then
        dev_command.usage_error(ctx, "--runs takes a whole number of 1 or more")
    end
    return count
end

local function count_ran(output)
    local count = 0
    for line in output:gmatch("[^\n]+") do
        if line:find("^ok ") and not line:find("# skip", 1, true) then
            count = count + 1
        end
    end
    return count
end

local function run_case(case, number, runs)
    local argv = { "bash", "-c", WRAPPER:format(BURNERS_PER_CORE), "soak", unpack(case.argv) }
    local output, code =
        dev_os.capture_timed(argv, CASE_TIMEOUT_SECS, { cwd = ctx.root, merge = true })
    local load_line = output:match("load: [^\n]*\n?$") or "load: not recorded"
    local ran = count_ran(output)
    local passed = code == 0 and ran > 0
    dev_command.say(
        string.format(
            "%s %s %d/%d (%d cases) %s",
            passed and "PASS" or "FAIL",
            case.name,
            number,
            runs,
            ran,
            (load_line:gsub("\n$", ""))
        )
    )
    if not passed then
        dev_command.say(output)
    end
    stdout:flush()
    return passed
end

local runs = runs_wanted()
if not remote.is_remote_host() then
    dev_command.die("dev soak loads the host it runs on, so run it on ci: dev --remote soak")
end
dev_command.need("bats", "pacman -S bats")

local failed = 0
for _, case in ipairs(CASES) do
    local passed = 0
    for number = 1, runs do
        if run_case(case, number, runs) then
            passed = passed + 1
        end
    end
    failed = failed + (runs - passed)
    dev_command.say(string.format("%s: %d of %d runs passed", case.name, passed, runs))
end
dev_command.say(string.format("\n%d runs failed", failed))
return failed == 0 and 0 or 1
