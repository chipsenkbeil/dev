local dev_os = require("@dev/os")
local remote = require("@dev/remote")
local runtime = require("@dev/runtime")
local dev_command = require("@dev/command")

local DEFAULT_RUNS = 50
local BURNERS_PER_CORE = 2
local CASE_TIMEOUT_SECS = 300
local stdout = dev_os.stdout

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
            runtime.exe,
            "-l",
            "tests/lua/run.luau",
            "tests/lua/pkg_script_test.luau",
            "wrapper gets TERM",
        },
    },
    {
        name = "confirm and spin ctrl-c",
        argv = { "bats", "--tap", "--filter", "ctrl-c", "tests/dev/confirm.bats" },
    },
}

local function count_ran(output)
    local count = 0
    for line in output:gmatch("[^\n]+") do
        if line:find("^ok ") and not line:find("# skip", 1, true) then
            count = count + 1
        end
    end
    return count
end

local function run_case(case, number, runs, root)
    local argv = {
        "bash",
        "-c",
        WRAPPER:format(BURNERS_PER_CORE),
        "soak",
        table.unpack(case.argv),
    }
    local output, code = dev_os.capture_timed(argv, CASE_TIMEOUT_SECS, { cwd = root, merge = true })
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

return dev_command({
    summary = "Run the signal tests in a loop beside CPU burners, on a ci host only",
    group = "Check your work",
    flags = {
        { name = "runs", kind = "number", default = DEFAULT_RUNS, help = "Runs of each case" },
    },
    run = function(opts, _, ctx)
        local runs = opts.runs
        if runs < 1 or runs % 1 ~= 0 then
            dev_command.usage_error(ctx, "The --runs flag takes a whole number of 1 or more.")
        end
        if not remote.is_remote_host() then
            dev_command.die("Soak loads its host. Run it on ci with `dev --remote soak`.")
        end
        dev_command.need("bats", "pacman -S bats")

        local failed = 0
        for _, case in ipairs(CASES) do
            local passed = 0
            for number = 1, runs do
                if run_case(case, number, runs, ctx.root) then
                    passed = passed + 1
                end
            end
            failed = failed + (runs - passed)
            dev_command.say(string.format("%s: %d of %d runs passed.", case.name, passed, runs))
        end
        dev_command.say(string.format("\n%d runs failed.", failed))
        return failed == 0 and 0 or 1
    end,
})
