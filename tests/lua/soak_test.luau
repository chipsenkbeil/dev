local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local runtime = require("@dev/runtime")
local fs = require("@dev/fs")
local support = require("./support")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local ON_CI = { CI = "true" }

local function project(bats_body)
    local root = support.sandbox({
        [".dev/commands/soak.luau"] = assert(fs.read(REPO .. "/.dev/commands/soak.luau")),
        ["tests/lua/run.luau"] = 'print("ok - a case")\n',
        ["bin/nproc"] = "#!/bin/sh\necho 1\n",
        ["bin/bats"] = "#!/bin/sh\n" .. bats_body .. "\n",
    }, {})
    for _, tool in ipairs({ "nproc", "bats" }) do
        assert(dev_os.run({ "chmod", "755", root .. "/bin/" .. tool }) == 0, "chmod failed")
    end
    return root
end

testing.test("soak refuses to run off a ci host", function()
    local root = project("exit 0")
    local out, code = support.dev(
        root,
        { "soak" },
        { env = { CI = "", DEV_BOX_MARKER = root .. "/no-box" } }
    )
    testing.eq(code, 1)
    testing.ok(out:find("dev --remote soak", 1, true), out)
end)

testing.test("soak rejects a runs count that is not a whole number of 1 or more", function()
    local root = project("exit 0")
    for _, args in ipairs({
        { "--runs", "0" },
        { "--runs", "x" },
        { "--runs" },
        { "-" },
        { "--runs=1", "junk" },
    }) do
        local argv = { "soak", table.unpack(args) }
        local out, code = support.dev(root, argv, { env = ON_CI })
        testing.ok(code == 2, table.concat(args, " ") .. ": " .. out)
    end
end)

testing.test("soak loops every case and reports the load of each run", function()
    local root = project('echo "ok 1 case"')
    local out, code = support.dev(root, { "soak", "--runs", "2" }, { env = ON_CI })
    testing.eq(code, 0, out)
    testing.ok(
        out:find("PASS pkg_script TERM 2/2 (1 cases) load: 2 burners, 1 cores", 1, true),
        out
    )
    testing.ok(out:find("confirm and spin ctrl-c: 2 of 2 runs passed", 1, true), out)
    testing.ok(out:find("0 runs failed", 1, true), out)
end)

testing.test("soak fails a run whose case exits non-zero and keeps its output", function()
    local root = project('echo "not ok 1 case"; exit 1')
    local out, code = support.dev(root, { "soak", "--runs=1" }, { env = ON_CI })
    testing.eq(code, 1)
    testing.ok(out:find("FAIL confirm and spin ctrl-c 1/1", 1, true), out)
    testing.ok(out:find("not ok 1 case", 1, true), out)
    testing.ok(out:find("PASS pkg_script TERM 1/1", 1, true), out)
    testing.ok(out:find("1 runs failed", 1, true), out)
end)

testing.test("soak fails a run in which no case ran", function()
    local root = project("echo 1..0")
    local out, code = support.dev(root, { "soak", "--runs", "1" }, { env = ON_CI })
    testing.eq(code, 1)
    testing.ok(out:find("FAIL confirm and spin ctrl-c 1/1 (0 cases)", 1, true), out)
end)

local MAIN = runtime.exe

local DRIVER = [[
set -m
"$MAIN" soak --runs 1 >/dev/null 2>&1 &
soak=$!
n=0
while [ ! -s "$GROUP" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
[ -s "$GROUP" ] || exit 2
kill -TERM "$soak"
wait "$soak"
group=$(tr -d ' \n' <"$GROUP")
alive() {
    ps -A -o pgid= -o stat= | awk -v g="$group" '$1 == g && $2 !~ /^Z/ { found = 1 } END { exit !found }'
}
n=0
while alive && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
if alive; then
    kill -KILL -- "-$group"
    exit 1
fi
]]

testing.test("a TERM to dev alone stops the case and its busy loops", function()
    local root = project("")
    local group = root .. "/group"
    assert(
        fs.write(
            root .. "/bin/bats",
            ("#!/bin/sh\nps -o pgid= -p $$ >%s\nsleep 60\n"):format(group)
        )
    )
    assert(fs.write(root .. "/driver.sh", DRIVER))
    local code = dev_os.run({ "bash", root .. "/driver.sh" }, {
        cwd = root,
        env = {
            CI = "true",
            MAIN = MAIN,
            GROUP = group,
            DEV_SELF = runtime.exe,
            DEV_BOARD_TOKEN = "",
            PATH = root .. "/bin:" .. dev_os.getenv("PATH"),
        },
    })
    testing.eq(code, 0)
end)
