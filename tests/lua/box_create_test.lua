local testing = require("dev.testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")

local TARGETS = [[{"ok":true,"targets":[
{"target":"linux-dev","os":"linux","machines":["example-box"],"image":"devbox","min_shape":null,"can_take_box_now":true,"reason":null},
{"target":"linux-rust","os":"linux","machines":["example-box"],"image":"linux-rust","min_shape":"medium","can_take_box_now":false,"reason":"needs 8 GiB more"},
{"target":"linux-mid","os":"linux","machines":["example-box"],"image":"mid","min_shape":"medium","can_take_box_now":true,"reason":null}]}]]

local SHAPES = [[{"ok":true,"default_shape":"medium","shapes":[
{"name":"small","cpu":4,"memory_gib":8,"default":false,"targets":[
{"target":"linux-dev","below_min":false,"machines":[{"machine":"example-box","fits":"start","reason":null,"warning":"last running slot"}]},
{"target":"linux-mid","below_min":true,"machines":[{"machine":"example-box","fits":"start","reason":null,"warning":null}]}]},
{"name":"medium","cpu":8,"memory_gib":16,"default":true,"targets":[
{"target":"linux-dev","below_min":false,"machines":[{"machine":"example-box","fits":"wait","reason":"need 16GiB","warning":null}]},
{"target":"linux-mid","below_min":false,"machines":[{"machine":"example-box","fits":"start","reason":null,"warning":null}]}]},
{"name":"large","cpu":12,"memory_gib":32,"default":false,"targets":[
{"target":"linux-dev","below_min":false,"machines":[{"machine":"example-box","fits":"never","reason":"needs 8 GiB more","warning":null}]},
{"target":"linux-mid","below_min":false,"machines":[{"machine":"example-box","fits":"never","reason":"needs 8 GiB more","warning":null}]}]}],
"cap":{"running":1,"running_max":3,"memory_limits_gib":16,"memory_max_gib":32},
"machines":[{"name":"example-box","running":1,"memory_limits_gib":16,"new_box_room_gib":8,"reachable":true}]}]]

local CREATED =
    [[{"ok":true,"box":{"name":"proj-x1","state":"running","target":"linux-dev","machine":"example-box","shape":"medium","expires_at":null,"delete_after":null,"projects":[{"name":"proj","path":"/srv/projects/proj"}]}}]]

local LISTING = [[{"ok":true,"boxes":[
{"name":"b1","state":"running","target":"linux-dev","machine":"example-box"},
{"name":"b2","state":"stopped","target":"linux-dev","machine":"example-box"}]}]]

local function sandbox(files)
    local root = support.sandbox({}, {})
    for name, body in pairs(files) do
        assert(fs.write(root .. "/" .. name .. ".json", (body:gsub("\n", "")) .. "\n"))
    end
    local body = ([[#!/bin/sh
echo "$*" >> "%s/log"
cat "%s/$2.json"
[ "$1" != fleet ] || cat "%s/shapes.json"
]]):format(root, root, root)
    assert(fs.write(root .. "/bin/ci", body))
    assert(devos.run({ "chmod", "755", root .. "/bin/ci" }) == 0, "chmod failed")
    return root
end

local function env(root, extra)
    local set = {
        USER = "tester",
        NO_COLOR = "1",
        LUA_INIT = "@" .. REPO .. "/tests/lua/fake_env.lua",
        FAKE_TTY = "1",
        PICK_LOG = root .. "/picks",
    }
    for name, value in pairs(extra or {}) do
        set[name] = value
    end
    return { env = set }
end

local function lines_of(path)
    local lines = {}
    local text = fs.read(path) or ""
    for line in text:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    return lines
end

testing.test("create asks for the target, then the shape, then creates", function()
    local root = sandbox({ targets = TARGETS, shapes = SHAPES, create = CREATED })
    local out, code = support.dev(
        root,
        { "box", "create", "--keep", "proj" },
        env(root, { FAKE_PICK = "linux-dev medium" })
    )
    testing.eq(code, 0)
    testing.eq(
        out,
        "Created proj-x1 · linux-dev @ example-box · medium · kept · dev connect proj-x1\n"
    )
    testing.eq(lines_of(root .. "/log"), {
        "fleet targets --box --json",
        "fleet targets --box --target linux-dev --json",
        "box create --target linux-dev --shape medium --by human:tester --keep --json -- proj",
    })
    testing.eq(lines_of(root .. "/picks"), {
        "picker title=What should the proj box run? auto=nil note=example-box 8 GiB free",
        "linux-dev\tlinux-dev\tLinux · devbox\tfrom small\t@ example-box",
        "linux-rust\tlinux-rust\tLinux · linux-rust\tfrom medium\t@ example-box\t!needs 8 GiB more",
        "linux-mid\tlinux-mid\tLinux · mid\tfrom medium\t@ example-box",
        "picker title=Pick a shape for linux-dev on example-box auto=nil note=example-box 8 GiB free initial=medium",
        "small\tsmall\t4 CPU\t8 GiB\tlast running slot",
        "medium\tmedium\t8 CPU\t16 GiB\twaits for room",
        "large\tlarge\t12 CPU\t32 GiB\t\t!needs 8 GiB more",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("a shape below the target's minimum is greyed", function()
    local root = sandbox({ targets = TARGETS, shapes = SHAPES, create = CREATED })
    local _, code = support.dev(
        root,
        { "box", "create", "proj" },
        env(root, { FAKE_PICK = "linux-mid medium" })
    )
    testing.eq(code, 0)
    local picks = lines_of(root .. "/picks")
    testing.eq(picks[6], "small\tsmall\t4 CPU\t8 GiB\t\t!below linux-mid's minimum")
    fs.remove(root, { recursive = true })
end)

testing.test("--target skips both pickers and takes ci's default shape", function()
    local root = sandbox({ create = CREATED })
    local _, code =
        support.dev(root, { "box", "create", "--target", "linux-dev", "proj" }, env(root))
    testing.eq(code, 0)
    testing.eq(
        lines_of(root .. "/log"),
        { "box create --target linux-dev --by human:tester --json -- proj" }
    )
    testing.eq(lines_of(root .. "/picks"), {})
    fs.remove(root, { recursive = true })
end)

testing.test("--shape skips the second picker only", function()
    local root = sandbox({ targets = TARGETS, shapes = SHAPES, create = CREATED })
    local _, code = support.dev(
        root,
        { "box", "create", "--shape", "large", "proj" },
        env(root, { FAKE_PICK = "linux-dev" })
    )
    testing.eq(code, 0)
    local log = lines_of(root .. "/log")
    testing.eq(
        log[#log],
        "box create --target linux-dev --shape large --by human:tester --json -- proj"
    )
    testing.eq(#log, 2)
    fs.remove(root, { recursive = true })
end)

testing.test("--arch passes the architecture to ci box create", function()
    local root = sandbox({ create = CREATED })
    local _, code = support.dev(
        root,
        { "box", "create", "--arch", "aarch64", "--target", "linux-dev", "proj" },
        env(root)
    )
    testing.eq(code, 0)
    testing.eq(
        lines_of(root .. "/log"),
        { "box create --target linux-dev --arch aarch64 --by human:tester --json -- proj" }
    )
    fs.remove(root, { recursive = true })
end)

testing.test("without --arch ci gets no --arch flag", function()
    local root = sandbox({ create = CREATED })
    local _, code =
        support.dev(root, { "box", "create", "--target", "linux-dev", "proj" }, env(root))
    testing.eq(code, 0)
    testing.eq(
        lines_of(root .. "/log"),
        { "box create --target linux-dev --by human:tester --json -- proj" }
    )
    fs.remove(root, { recursive = true })
end)

testing.test("without a terminal there are no pickers and ci applies its defaults", function()
    local root = sandbox({ create = CREATED })
    local out, code = support.dev(root, { "box", "create", "proj" }, env(root, { FAKE_TTY = "0" }))
    testing.eq(code, 0)
    testing.eq(
        out,
        "Created proj-x1 · linux-dev @ example-box · medium · kept · dev connect proj-x1\n"
    )
    testing.eq(lines_of(root .. "/log"), { "box create --by human:tester --json -- proj" })
    fs.remove(root, { recursive = true })
end)

testing.test("cancelling a picker exits 1 and creates nothing", function()
    local root = sandbox({ targets = TARGETS, shapes = SHAPES, create = CREATED })
    local _, code =
        support.dev(root, { "box", "create", "proj" }, env(root, { FAKE_PICK = "CANCEL" }))
    testing.eq(code, 1)
    for _, line in ipairs(lines_of(root .. "/log")) do
        testing.eq(line:find("box create", 1, true), nil)
    end
    fs.remove(root, { recursive = true })
end)

testing.test("a target that waits for room can be picked and says why", function()
    local waiting = TARGETS:gsub('"linux%-rust"', '"linux-wait"')
    local shapes = SHAPES:gsub(
        '"linux%-mid","below_min":false,"machines":%[{"machine":"example%-box","fits":"start"',
        '"linux-wait","below_min":false,"machines":[{"machine":"example-box","fits":"wait","reason":"need 16GiB","warning":null}]},\n{"target":"linux-mid","below_min":false,"machines":[{"machine":"example-box","fits":"start"',
        1
    )
    local root = sandbox({ targets = waiting, shapes = shapes, create = CREATED })
    local _, code = support.dev(
        root,
        { "box", "create", "proj" },
        env(root, { FAKE_PICK = "linux-wait medium" })
    )
    testing.eq(code, 0)
    local picks = lines_of(root .. "/picks")
    testing.eq(
        picks[3],
        "linux-wait\tlinux-wait\tLinux · linux-wait\tfrom medium\t@ example-box\twaits for room · needs 8 GiB more"
    )
    fs.remove(root, { recursive = true })
end)

testing.test("when no target fits, dev names the running box to stop", function()
    local only = [[{"ok":true,"targets":[
{"target":"linux-rust","os":"linux","machines":["example-box"],"image":"linux-rust","min_shape":"medium","can_take_box_now":false,"reason":"needs 8 GiB more"}]}]]
    local root = sandbox({ targets = only, shapes = SHAPES, ls = LISTING, create = CREATED })
    local out, code = support.dev(root, { "box", "create", "proj" }, env(root))
    testing.eq(code, 1)
    testing.eq(out, "dev box create: no target fits now, stop a running box to make room: b1\n")
    fs.remove(root, { recursive = true })
end)

testing.test("a machine ci could not ask makes every shape unpickable", function()
    local down = SHAPES:gsub('"fits":"start"', '"fits":null'):gsub('"fits":"wait"', '"fits":null')
    local root = sandbox({ targets = TARGETS, shapes = down, ls = LISTING, create = CREATED })
    local out, code =
        support.dev(root, { "box", "create", "proj" }, env(root, { FAKE_PICK = "linux-dev" }))
    testing.eq(code, 1)
    testing.eq(
        out,
        "dev box create: no shape of linux-dev fits now, stop a running box to make room: b1\n"
    )
    fs.remove(root, { recursive = true })
end)
