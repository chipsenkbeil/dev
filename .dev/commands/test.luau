local checks = require("@lib/devrepo/checks")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local runtime = require("@dev/runtime")
local dev_command = require("@dev/command")
local supervise = require("@lib/devrepo/supervise")

local SKIPPED = 3
local SIGINT = 2
local POLL_SECS = 0.1
local ALIVE_POLLS = 50

---The suites that cannot run beside another one.
local SERIAL = {
    ["tests/dev/term.bats"] = true,
    ["tests/dev/picker.bats"] = true,
    ["tests/dev/confirm.bats"] = true,
    ["tests/dev/pager.bats"] = true,
    ["tests/dev/help_test.sh"] = true,
    ["tests/lua/help_test.luau"] = true,
}

local function execute(opts, args, ctx)
    dev_command.need("bats", "brew install bats-core")

    local root = ctx.root
    local stdout = dev_os.stdout
    local passed, failed, skipped = 0, 0, 0

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
        local set = dev_os.getenv("DEV_TEST_JOBS")
        if set and set ~= "" then
            local jobs = set:match("^%d+$") and tonumber(set)
            if not jobs or jobs < 1 then
                dev_command.die(
                    "DEV_TEST_JOBS must be a whole number of 1 or more, got " .. set .. "."
                )
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

    for _, file in ipairs(checks.find(root, { "tests/lua" }, { "-name", "*_test.luau" })) do
        suites[#suites + 1] = script_suite(file, { runtime.exe, "-l", "tests/lua/run.luau", file })
    end

    if fs.is_file(fs.join(root, "Cargo.toml")) and dev_os.which("cargo") then
        suites[#suites + 1] = script_suite("cargo test", { "cargo", "test" })
    end

    if #args.path > 0 then
        local chosen = {}
        for _, arg in ipairs(args.path) do
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
                        local why = arg .. " is skipped here. It " .. skip.why .. "."
                        dev_command.usage_error(ctx, why)
                    end
                end
                dev_command.usage_error(ctx, "There is no suite at " .. arg .. ".")
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
    local supervisor = supervise.new(root)

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
                    suite.code = supervisor:finished(suite, check_alive)
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
                    supervisor:start(index, suite)
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
        supervisor:stop_all()
    end
    supervisor:cleanup()
    if not ok then
        if tostring(err):find("interrupted!", 1, true) then
            dev_os.exit(dev_os.SIGNAL_EXIT_BASE + SIGINT)
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
end

return dev_command({
    summary = "Run every test suite and report each by name",
    args = { { name = "path", list = true } },
    run = execute,
})
