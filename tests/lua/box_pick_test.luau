local testing = require("@dev/testing")
local box = require("@dev/cmd/box")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local support = require("./support")

local LISTING = [[{"ok":true,"boxes":[
{"name":"run-a","state":"running","target":"linux-dev","machine":"example-box","shape":"medium","projects":[]},
{"name":"run-b","state":"running","target":"linux-dev","machine":"example-box","shape":"medium","projects":[]},
{"name":"stop-a","state":"stopped","target":"linux-dev","machine":"example-box","shape":"medium","projects":[]}]}]]

local ONE =
    [[{"ok":true,"box":{"name":"run-a","state":"running","target":"linux-dev","machine":"example-box","shape":"medium","projects":[],"tailnet_name":"run-a","expires_at":null,"delete_after":null,"tmux_sessions":[]}}]]

local DELETED =
    [[{"ok":true,"box":{"name":"run-a","state":"deleted","archive":{"path":"/var/x.tar.gz"}}}]]

local RETAGGED = [[{"ok":true,"retagged":[{"name":"run-a","skipped":false,"error":null}]}]]

local FAILED_RETAG =
    [[{"ok":false,"retagged":[{"name":"run-a","skipped":false,"error":"no instance"}]}]]

local function sandbox()
    local root = support.sandbox({}, {})
    for name, body in pairs({
        ls = LISTING,
        show = ONE,
        stop = ONE,
        resume = ONE,
        extend = ONE,
        delete = DELETED,
        retag = RETAGGED,
        config = "",
    }) do
        assert(fs.write(root .. "/" .. name .. ".json", body))
    end
    assert(fs.write(root .. "/install-tools.json", '{"ok":true,"installed":[]}'))
    support.fake_ci(root)
    return root
end

local function env(root, extra)
    local set = {
        USER = "tester",
        DEV_AGENT = "",
        NO_COLOR = "1",
        FAKE_DEV = "1",
        FAKE_TTY = "1",
        PICK_LOG = root .. "/picks",
    }
    for name, value in pairs(extra or {}) do
        set[name] = value
    end
    return { env = set }
end

local function read(root, name)
    return fs.read(root .. "/" .. name) or ""
end

local function titles(root)
    local found = {}
    for line in read(root, "picks"):gmatch("[^\n]+") do
        if line:find("^picker") then
            found[#found + 1] = line
        end
    end
    return found
end

local COMMANDS = {
    { { "box", "show" }, "Show which box?", "show run-a --json" },
    { { "box", "stop" }, "Stop which box?", "stop run-a --json" },
    { { "box", "resume" }, "Resume which box?", "resume stop-a --json" },
    { { "box", "extend", "--keep" }, "Extend which box?", "extend run-a --keep --json" },
    { { "box", "tools", "install" }, "Install tools on which box?", "install-tools run-a --json" },
    { { "box", "delete", "-y" }, "Delete which box?", "delete run-a --json" },
}

for _, case in ipairs(COMMANDS) do
    local words = case[1]
    testing.test("dev " .. table.concat(words, " ") .. " picks a box on a terminal", function()
        local root = sandbox()
        local pick = case[3]:match("^%S+ (%S+)")
        local _, code = support.dev(root, words, env(root, { FAKE_PICK = pick }))
        testing.eq(code, 0)
        testing.eq(titles(root), {
            "picker title="
                .. case[2]
                .. " auto="
                .. tostring(case[2]:find("Stop") == nil and case[2]:find("Delete") == nil),
        })
        testing.eq(read(root, "log"), "box ls --json\nbox " .. case[3] .. "\n")
        fs.remove(root, { recursive = true })
    end)
end

testing.test("resume lists only stopped boxes and stop only running ones", function()
    local root = sandbox()
    support.dev(root, { "box", "resume" }, env(root, { FAKE_PICK = "stop-a" }))
    local picks = read(root, "picks")
    testing.ok(picks:find("stop-a", 1, true) and not picks:find("run-a", 1, true), picks)
    fs.remove(root, { recursive = true })
    root = sandbox()
    support.dev(root, { "box", "stop" }, env(root, { FAKE_PICK = "run-a" }))
    picks = read(root, "picks")
    testing.ok(picks:find("run-a", 1, true) and not picks:find("stop-a", 1, true), picks)
    fs.remove(root, { recursive = true })
end)

testing.test("a missing name without a terminal is exit 2 with a hint", function()
    for _, case in ipairs({
        {
            { "box", "show" },
            "dev box show: No box given and no terminal to pick one. Pass a name, like dev box show ci-example.\n",
        },
        {
            { "box", "delete" },
            "dev box delete: No box given and no terminal to pick one. Pass a name, like dev box delete ci-example -y.\n",
        },
        {
            { "box", "resume" },
            "dev box resume: No box given and no terminal to pick one. Pass a name, like dev box resume ci-example.\n",
        },
    }) do
        local root = sandbox()
        local out, code = support.dev(root, case[1], env(root, { FAKE_TTY = "0" }))
        testing.eq(code, 2)
        testing.eq(out, case[2])
        testing.eq(read(root, "log"), "")
        fs.remove(root, { recursive = true })
    end
end)

testing.test("a command with no box it can act on says so", function()
    local root = sandbox()
    assert(fs.write(root .. "/ls.json", '{"ok":true,"boxes":[]}'))
    local out, code = support.dev(root, { "box", "resume" }, env(root))
    testing.eq(code, 1)
    testing.eq(out, "There are no stopped boxes to resume.\n")
    fs.remove(root, { recursive = true })
end)

testing.test("the delete question names what would be lost", function()
    local question, consequence = box.delete_prompt("b", false, false)
    testing.eq({ question, consequence }, { "Delete b?", "Its projects are archived first." })
    question, consequence = box.delete_prompt("b", true, false)
    testing.eq(
        { question, consequence },
        { "Delete b without an archive?", "Anything not pushed is lost." }
    )
    question, consequence = box.delete_prompt("b", false, true)
    testing.eq(consequence, "You're attached to it. Its projects are archived first.")
    question, consequence = box.delete_prompt("b", true, true)
    testing.eq({ question, consequence }, {
        "Delete b without an archive?",
        "You're attached to it. Anything not pushed is lost.",
    })
end)

testing.test("delete prints the final line with the archive", function()
    local root = sandbox()
    local out, code = support.dev(root, { "box", "delete", "run-a", "-y" }, env(root))
    testing.eq(code, 0)
    testing.eq(out, "Deleted run-a · archive /var/x.tar.gz\n")
    fs.remove(root, { recursive = true })
end)

testing.test("retag runs ci box retag with the target and prints the move", function()
    local root = sandbox()
    local out, code =
        support.dev(root, { "box", "retag", "run-a", "--target", "linux-dev" }, env(root))
    testing.eq(code, 0)
    testing.eq(out, "retagged run-a to linux-dev\n")
    testing.eq(read(root, "log"), "box retag run-a --target linux-dev --json\n")
    fs.remove(root, { recursive = true })
end)

testing.test("retag prints the box's own error and exits with ci's code", function()
    local root = sandbox()
    assert(fs.write(root .. "/retag.json", FAILED_RETAG))
    assert(fs.write(root .. "/rc", "1"))
    local out, code =
        support.dev(root, { "box", "retag", "run-a", "--target", "linux-dev" }, env(root))
    testing.eq(code, 1)
    testing.eq(out, "dev box retag: no instance\n")
    fs.remove(root, { recursive = true })
end)

testing.test("retag without a box name or a target is a usage error before ci runs", function()
    local root = sandbox()
    local _, code = support.dev(root, { "box", "retag", "--target", "linux-dev" }, env(root))
    testing.eq(code, 2)
    _, code = support.dev(root, { "box", "retag", "run-a" }, env(root))
    testing.eq(code, 2)
    testing.eq(read(root, "log"), "")
    fs.remove(root, { recursive = true })
end)

testing.test("connect runs the two create pickers when it makes a box", function()
    local root = sandbox()
    local TARGETS =
        [[{"ok":true,"targets":[{"target":"linux-dev","os":"linux","machines":["example-box"],"image":"devbox","min_shape":null,"can_take_box_now":true,"reason":null}]}]]
    local SHAPES =
        [[{"ok":true,"default_shape":"medium","shapes":[{"name":"medium","cpu":8,"memory_gib":16,"default":true,"targets":[{"target":"linux-dev","below_min":false,"machines":[{"machine":"example-box","fits":"start","reason":null,"warning":null}]}]}],"cap":{"running":1,"running_max":3,"memory_limits_gib":16,"memory_max_gib":32},"machines":[{"name":"example-box","running":1,"memory_limits_gib":16,"new_box_room_gib":8,"reachable":true}]}]]
    assert(fs.write(root .. "/targets.json", TARGETS .. "\n"))
    assert(fs.write(root .. "/shapes.json", SHAPES .. "\n"))
    assert(fs.write(root .. "/create.json", ONE))
    local project = root:match("([^/]+)/*$")
    support.dev(root, { "connect", "--ssh" }, env(root, { FAKE_PICK = "__new__ linux-dev medium" }))
    local log = read(root, "log")
    local want = "box create --target linux-dev --shape medium --by human:tester --json -- "
        .. project
    testing.ok(log:find(want, 1, true), log)
    fs.remove(root, { recursive = true })
end)
