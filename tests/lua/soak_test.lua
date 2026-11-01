local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
local ON_CI = { CI = "true" }

local function project(bats_body)
    local root = support.sandbox({
        [".dev/soak.lua"] = assert(fs.read(REPO .. "/.dev/soak.lua")),
        ["tests/lua/run.lua"] = 'print("ok - a case")\n',
        ["bin/nproc"] = "#!/bin/sh\necho 1\n",
        ["bin/bats"] = "#!/bin/sh\n" .. bats_body .. "\n",
    }, {})
    for _, tool in ipairs({ "nproc", "bats" }) do
        assert(devos.run({ "chmod", "755", root .. "/bin/" .. tool }) == 0, "chmod failed")
    end
    return root
end

t.test("soak refuses to run off a ci host", function()
    local root = project("exit 0")
    local out, code = support.dev(
        root,
        { "soak" },
        { env = { CI = "", DEV_BOX_MARKER = root .. "/no-box" } }
    )
    t.eq(code, 1)
    t.ok(out:find("dev --remote soak", 1, true), out)
end)

t.test("soak rejects a runs count that is not a whole number of 1 or more", function()
    local root = project("exit 0")
    for _, args in ipairs({
        { "--runs", "0" },
        { "--runs", "x" },
        { "--runs" },
        { "-" },
        { "--runs=1", "junk" },
    }) do
        local argv = { "soak", unpack(args) }
        local out, code = support.dev(root, argv, { env = ON_CI })
        t.ok(code == 2, table.concat(args, " ") .. ": " .. out)
    end
end)

t.test("soak loops every case and reports the load of each run", function()
    local root = project('echo "ok 1 case"')
    local out, code = support.dev(root, { "soak", "--runs", "2" }, { env = ON_CI })
    t.eq(code, 0, out)
    t.ok(out:find("PASS pkg_script TERM 2/2 (1 cases) load: 2 burners, 1 cores", 1, true), out)
    t.ok(out:find("guide interrupt: 2 of 2 runs passed", 1, true), out)
    t.ok(out:find("0 runs failed", 1, true), out)
end)

t.test("soak fails a run whose case exits non-zero and keeps its output", function()
    local root = project('echo "not ok 1 case"; exit 1')
    local out, code = support.dev(root, { "soak", "--runs=1" }, { env = ON_CI })
    t.eq(code, 1)
    t.ok(out:find("FAIL confirm and spin ctrl-c 1/1", 1, true), out)
    t.ok(out:find("not ok 1 case", 1, true), out)
    t.ok(out:find("PASS pkg_script TERM 1/1", 1, true), out)
    t.ok(out:find("2 runs failed", 1, true), out)
end)

t.test("soak fails a run in which no case ran", function()
    local root = project("echo 1..0")
    local out, code = support.dev(root, { "soak", "--runs", "1" }, { env = ON_CI })
    t.eq(code, 1)
    t.ok(out:find("FAIL guide interrupt 1/1 (0 cases)", 1, true), out)
end)
