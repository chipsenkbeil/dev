local t = require("testing")
local box = require("dev.cmd.box")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")

local LISTING = [[{"ok":true,"boxes":[
{"name":"run-a","state":"running","target":"linux-dev","machine":"example-box","shape":"medium","projects":[]},
{"name":"run-b","state":"running","target":"linux-dev","machine":"example-box","shape":"medium","projects":[]},
{"name":"stop-a","state":"stopped","target":"linux-dev","machine":"example-box","shape":"medium","projects":[]}]}]]

local ONE =
    [[{"ok":true,"box":{"name":"run-a","state":"running","target":"linux-dev","machine":"example-box","shape":"medium","projects":[],"tailnet_name":"run-a","expires_at":null,"delete_after":null,"tmux_sessions":[]}}]]

local DELETED =
    [[{"ok":true,"box":{"name":"run-a","state":"deleted","archive":{"path":"/var/x.tar.gz"}}}]]

local function sandbox()
    local root = support.sandbox({}, {})
    for name, body in pairs({
        ls = LISTING,
        show = ONE,
        stop = ONE,
        resume = ONE,
        extend = ONE,
        delete = DELETED,
    }) do
        assert(fs.write(root .. "/" .. name .. ".json", body))
    end
    assert(fs.write(root .. "/install-tools.json", '{"ok":true,"installed":[]}'))
    local body = '#!/bin/sh\necho "$*" >> "' .. root .. '/log"\ncat "' .. root .. '/$2.json"\n'
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

local VERBS = {
    { { "box", "show" }, "Show which box?", "show run-a --json" },
    { { "box", "stop" }, "Stop which box?", "stop run-a --json" },
    { { "box", "resume" }, "Resume which box?", "resume stop-a --json" },
    { { "box", "extend", "--keep" }, "Extend which box?", "extend run-a --keep --json" },
    { { "box", "tools", "install" }, "Install tools on which box?", "install-tools run-a --json" },
    { { "box", "delete", "-y" }, "Delete which box?", "delete run-a --json" },
}

for _, case in ipairs(VERBS) do
    local words = case[1]
    t.test("dev " .. table.concat(words, " ") .. " picks a box on a terminal", function()
        local root = sandbox()
        local pick = case[3]:match("^%S+ (%S+)")
        local _, code = support.dev(root, words, env(root, { FAKE_PICK = pick }))
        t.eq(code, 0)
        t.eq(titles(root), {
            "picker title="
                .. case[2]
                .. " auto="
                .. tostring(case[2]:find("Stop") == nil and case[2]:find("Delete") == nil),
        })
        t.eq(read(root, "log"), "box ls --json\nbox " .. case[3] .. "\n")
        fs.remove(root, { recursive = true })
    end)
end

t.test("resume lists only stopped boxes and stop only running ones", function()
    local root = sandbox()
    support.dev(root, { "box", "resume" }, env(root, { FAKE_PICK = "stop-a" }))
    local picks = read(root, "picks")
    t.ok(picks:find("stop-a", 1, true) and not picks:find("run-a", 1, true), picks)
    fs.remove(root, { recursive = true })
    root = sandbox()
    support.dev(root, { "box", "stop" }, env(root, { FAKE_PICK = "run-a" }))
    picks = read(root, "picks")
    t.ok(picks:find("run-a", 1, true) and not picks:find("stop-a", 1, true), picks)
    fs.remove(root, { recursive = true })
end)

t.test("a missing name without a terminal is exit 2 with a hint", function()
    for _, case in ipairs({
        {
            { "box", "show" },
            "dev box show: no box given and no terminal to pick one; pass a name, like dev box show ci-abc\n",
        },
        {
            { "box", "delete" },
            "dev box delete: no box given and no terminal to pick one; pass a name, like dev box delete ci-abc -y\n",
        },
        {
            { "box", "resume" },
            "dev box resume: no box given and no terminal to pick one; pass a name, like dev box resume ci-abc\n",
        },
    }) do
        local root = sandbox()
        local out, code = support.dev(root, case[1], env(root, { FAKE_TTY = "0" }))
        t.eq(code, 2)
        t.eq(out, case[2])
        t.eq(read(root, "log"), "")
        fs.remove(root, { recursive = true })
    end
end)

t.test("a verb with no box it can act on says so", function()
    local root = sandbox()
    assert(fs.write(root .. "/ls.json", '{"ok":true,"boxes":[]}'))
    local out, code = support.dev(root, { "box", "resume" }, env(root))
    t.eq(code, 1)
    t.eq(out, "dev box resume: no stopped boxes to resume\n")
    fs.remove(root, { recursive = true })
end)

t.test("the delete question names what would be lost", function()
    local question, consequence = box.delete_prompt("b", false, false)
    t.eq({ question, consequence }, { "Delete b?", "Its projects are archived first." })
    question, consequence = box.delete_prompt("b", true, false)
    t.eq(
        { question, consequence },
        { "Delete b without an archive?", "Anything not pushed is lost." }
    )
    question, consequence = box.delete_prompt("b", false, true)
    t.eq(consequence, "You're attached to it. Its projects are archived first.")
    question, consequence = box.delete_prompt("b", true, true)
    t.eq({ question, consequence }, {
        "Delete b without an archive?",
        "You're attached to it. Anything not pushed is lost.",
    })
end)

t.test("delete prints the final line with the archive", function()
    local root = sandbox()
    local out, code = support.dev(root, { "box", "delete", "run-a", "-y" }, env(root))
    t.eq(code, 0)
    t.eq(out, "Deleted run-a · archive /var/x.tar.gz\n")
    fs.remove(root, { recursive = true })
end)

t.test("connect runs the two create pickers when it makes a box", function()
    local root = sandbox()
    local TARGETS =
        [[{"ok":true,"targets":[{"target":"linux-dev","os":"linux","machines":["example-box"],"image":"devbox","min_shape":null,"can_take_box_now":true,"reason":null}]}]]
    local SHAPES =
        [[{"ok":true,"default_shape":"medium","shapes":[{"name":"medium","cpu":8,"memory_gib":16,"default":true,"targets":[{"target":"linux-dev","below_min":false,"machines":[{"machine":"example-box","fits":"start","reason":null,"warning":null}]}]}],"cap":{"running":1,"running_max":3,"memory_limits_gib":16,"memory_max_gib":32},"machines":[{"name":"example-box","running":1,"memory_limits_gib":16,"new_box_room_gib":8,"reachable":true}]}]]
    assert(fs.write(root .. "/targets.json", TARGETS))
    assert(fs.write(root .. "/shapes.json", SHAPES))
    assert(fs.write(root .. "/create.json", ONE))
    local project = root:match("([^/]+)/*$")
    support.dev(root, { "connect", "--ssh" }, env(root, { FAKE_PICK = "__new__ linux-dev medium" }))
    local log = read(root, "log")
    local want = "box create --target linux-dev --shape medium --by human:tester --json -- "
        .. project
    t.ok(log:find(want, 1, true), log)
    fs.remove(root, { recursive = true })
end)
