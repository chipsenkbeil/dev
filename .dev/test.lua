--[[
Run every test suite under tests/ and report each by name.
A suite is a .bats file, a *_test.sh or test-*.sh script, or a *_test.lua file run with luajit.
The neomutt scripts run only when neomutt and tmux are both on PATH.
]]
local checks = require("dotfiles.checks")
local devos = require("dev.os")
local verb = require("dev.verb")

local ctx = ...
verb.no_args(ctx)
verb.need("bats", "brew install bats-core")

local root = ctx.root
local stdout, stderr = io.stdout, io.stderr
local SKIPPED = 3
local passed, failed, skipped = 0, 0, 0

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

local function run_script(name, argv)
    stdout:write("> ", name, "\n")
    record_result(name, devos.run(argv, { cwd = root }))
end

local function ran_a_case(output)
    for line in output:gmatch("[^\n]+") do
        if line:find("^ok ") and not line:find("# skip", 1, true) then
            return true
        end
    end
    return false
end

local function run_bats(name)
    stdout:write("> ", name, "\n")
    local output, code = devos.capture({ "bats", "--tap", name }, { cwd = root, stderr = "stdout" })
    stdout:write(output, output:sub(-1) == "\n" and "" or "\n")
    if code == 0 and not ran_a_case(output) then
        code = SKIPPED
    end
    record_result(name, code)
end

for _, file in ipairs(checks.bats_files(root)) do
    run_bats(file)
end

local scripts = { "(", "-name", "*_test.sh", "-o", "-name", "test-*.sh", ")" }
for _, file in ipairs(checks.find(root, { "tests" }, scripts)) do
    run_script(file, { "bash", file })
end

if devos.which("luajit") then
    for _, file in ipairs(checks.find(root, { "tests" }, { "-name", "*_test.lua" })) do
        run_script(file, { "luajit", "tests/lua/run.lua", file })
    end
else
    stdout:write("SKIP tests/lua (needs luajit)\n")
end

if devos.which("neomutt") and devos.which("tmux") then
    for _, name in ipairs({ "filter-bytes", "pager-passthrough" }) do
        local file = "tests/neomutt/" .. name .. ".sh"
        run_script(file, { "bash", file })
    end
    local parse = "tests/neomutt/parse-check.sh"
    run_script(parse, { "bash", parse, "dotfiles/neomutt/.config/neomutt/colors.mutt" })
else
    stdout:write("SKIP tests/neomutt/*.sh (needs neomutt and tmux on PATH)\n")
end

stdout:write(string.format("\n%d passed, %d failed, %d skipped\n", passed, failed, skipped))
stdout:flush()
if devos.getuid() ~= 0 or devos.name() ~= "Linux" then
    stderr:write(
        "dev: the real-root cases of tests/dev/root_test.sh and tests/dev/tools_test.sh ",
        "were skipped, run dev --remote test for them\n"
    )
end
return failed == 0 and 0 or 1
