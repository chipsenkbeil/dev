local t = require("testing")
local box = require("dev.cmd.box")
local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local ENV = { env = { USER = "tester", NO_COLOR = "" } }

local function sandbox(listing, shown)
    local root = support.sandbox({}, {})
    assert(fs.write(root .. "/ls.json", listing))
    assert(fs.write(root .. "/show.json", shown or listing))
    local body = '#!/bin/sh\nif [ "$2" = show ]; then cat "'
        .. root
        .. '/show.json"; else cat "'
        .. root
        .. '/ls.json"; fi\n'
    assert(fs.write(root .. "/bin/ci", body))
    assert(devos.run({ "chmod", "755", root .. "/bin/ci" }) == 0, "chmod failed")
    return root
end

local function columns(line)
    local cells, rest = {}, line
    while true do
        local at, stop = rest:find("  +")
        if not at then
            cells[#cells + 1] = rest
            return cells
        end
        cells[#cells + 1] = rest:sub(1, at - 1)
        rest = rest:sub(stop + 1)
    end
end

local LISTING = [[{"ok":true,"boxes":[
{"name":"b1","state":"running","target":"linux-x86-dev","machine":"example-box","shape":"medium","created_by":"human:tester","projects":[{"name":"myproject","path":"/srv/projects/myproject"}],"expires_at":null,"delete_after":null,"tmux_sessions":[{"name":"main","attached":true,"idle_seconds":0}]},
{"name":"b2","state":"running","target":"windows-vm-dev","machine":"mac1","shape":"large","created_by":"agent:proj-86","projects":[],"expires_at":null,"delete_after":null,"tmux_sessions":[{"name":"a","attached":false,"idle_seconds":2400},{"name":"b","attached":false,"idle_seconds":300}]},
{"name":"b3","state":"stopped","target":"linux-x86-dev","machine":"example-box","shape":"small","created_by":"alice","projects":[{"name":"ci","path":"/srv/projects/ci"}],"expires_at":null,"delete_after":null,"tmux_sessions":null}],
"cap":{"running":2,"running_max":3,"memory_limits_gib":24,"memory_max_gib":32},
"machines":[{"name":"example-box","running":2,"memory_limits_gib":24,"new_box_room_gib":8,"reachable":true},{"name":"mac1","running":0,"memory_limits_gib":0,"new_box_room_gib":0,"reachable":false}]}]]

t.test("ls prints the hub line, a room pair per machine and unreachable for a dead one", function()
    local root = sandbox(LISTING)
    local out, code = support.dev(root, { "box", "ls" }, ENV)
    t.eq(code, 0)
    t.eq(out:find("\27", 1, true), nil)
    local lines = {}
    for line in out:gmatch("[^\n]*\n") do
        lines[#lines + 1] = line:sub(1, -2)
    end
    t.eq(lines[1], "           Boxes   2 of 3 running · 1 more can start")
    t.eq(lines[2], "example-box  Boxes   2 running")
    t.eq(lines[3], "           Memory  24 of 32 GiB used · 8 GiB free")
    t.eq(lines[4], "mac1       unreachable")
    t.eq(lines[5], "")
    t.eq(
        columns(lines[6]),
        { "NAME", "TARGET", "STATE", "ACTIVITY", "WHO", "SHAPE", "PROJECTS", "TIME LEFT" }
    )
    t.eq(columns(lines[7]), {
        "● b1",
        "linux-x86-dev @ example-box",
        "running",
        "attached",
        "you",
        "medium",
        "myproject",
        "kept",
    })
    t.eq(columns(lines[8]), {
        "● b2",
        "windows-vm-dev @ mac1",
        "running",
        "idle 5m",
        "agent",
        "large",
        "-",
        "kept",
    })
    t.eq(columns(lines[9]), {
        "○ b3",
        "linux-x86-dev @ example-box",
        "stopped",
        "-",
        "alice",
        "small",
        "ci",
        "-",
    })
    fs.remove(root, { recursive = true })
end)

t.test("ls with no boxes still shows the room lines", function()
    local root = sandbox('{"ok":true,"boxes":[],"cap":{"running":0,"running_max":3},"machines":[]}')
    local out, code = support.dev(root, { "box", "ls" }, ENV)
    t.eq(code, 0)
    t.eq(out, "Boxes   0 of 3 running · 3 more can start\nno boxes\n")
    fs.remove(root, { recursive = true })
end)

t.test("activity names attached, the shortest idle time, none and unread", function()
    local running = "running"
    t.eq(box.activity({ state = running, tmux_sessions = {} }), "-")
    t.eq(box.activity({ state = running, tmux_sessions = json.null }), "?")
    t.eq(box.activity({ state = running }), "?")
    t.eq(
        box.activity({
            state = running,
            tmux_sessions = { { attached = false, idle_seconds = 7200 }, { attached = true } },
        }),
        "attached"
    )
    t.eq(
        box.activity({
            state = running,
            tmux_sessions = {
                { attached = false, idle_seconds = 7200 },
                { attached = false, idle_seconds = 120 },
            },
        }),
        "idle 2m"
    )
    t.eq(box.activity({ state = "stopped" }), "-")
end)

t.test("who says you, agent, another human or ci's own label", function()
    t.eq(box.who({ created_by = "human:tester" }, "tester"), "you")
    t.eq(box.who({ created_by = "human:alice" }, "tester"), "alice")
    t.eq(box.who({ created_by = "agent:proj-86" }, "tester"), "agent")
    t.eq(box.who({ created_by = "adopted" }, "tester"), "adopted")
    t.eq(box.who({ created_by = "human:tester" }, nil), "tester")
end)

t.test("ls --json and show --json print ci's output byte for byte", function()
    local document = '{ "ok": true,\n  "boxes": [],  "cap": {}, "machines": []}\n\n'
    local shown = '{"ok":true,   "box":{"name":"b1","state":"stopped"}}\n'
    local root = sandbox(document, shown)
    local out, code = support.dev(root, { "box", "ls", "--json" }, ENV)
    t.eq(code, 0)
    t.eq(out, document)
    out, code = support.dev(root, { "box", "show", "b1", "--json" }, ENV)
    t.eq(code, 0)
    t.eq(out, shown)
    fs.remove(root, { recursive = true })
end)
