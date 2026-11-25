local testing = require("@dev/testing")
local box = require("@dev/cmd/box")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local json = require("@dev/json")
local support = require("./support")

local ENV = { env = { USER = "tester", NO_COLOR = "" } }

local function sandbox(listing, shown)
    -- Write the listing and the box ci answers with
    local root = support.sandbox({}, {})
    assert(fs.write(root .. "/ls.json", listing))
    assert(fs.write(root .. "/show.json", shown or listing))

    -- Stand in for ci with a script that prints those files
    local body = table.concat({
        "#!/bin/sh",
        'if [ "$2" = show ]; then cat "'
            .. root
            .. '/show.json"; else cat "'
            .. root
            .. '/ls.json"; fi',
        "",
    }, "\n")
    assert(fs.write(root .. "/bin/ci", body))
    assert(dev_os.run({ "chmod", "755", root .. "/bin/ci" }) == 0, "chmod failed")
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

local LISTING = table.concat({
    '{"ok":true,"boxes":[',
    '{"name":"b1","state":"running","target":"linux-x86-dev","machine":"example-box","shape":"medium","created_by":"human:tester","projects":[{"name":"myproject","path":"/srv/projects/myproject"}],"expires_at":null,"delete_after":null,"tmux_sessions":[{"name":"main","attached":true,"idle_seconds":0}]},',
    '{"name":"b2","state":"running","target":"windows-vm-dev","machine":"mac1","shape":"large","created_by":"agent:proj-86","projects":[],"expires_at":null,"delete_after":null,"tmux_sessions":[{"name":"a","attached":false,"idle_seconds":2400},{"name":"b","attached":false,"idle_seconds":300}]},',
    '{"name":"b3","state":"stopped","target":"linux-x86-dev","machine":"example-box","shape":"small","created_by":"alice","projects":[{"name":"ci","path":"/srv/projects/ci"}],"expires_at":null,"delete_after":null,"tmux_sessions":null}],',
    '"cap":{"running":2,"running_max":3,"memory_limits_gib":24,"memory_max_gib":32},',
    '"machines":[{"name":"example-box","running":2,"memory_limits_gib":24,"new_box_room_gib":8,"reachable":true},{"name":"mac1","running":0,"memory_limits_gib":0,"new_box_room_gib":0,"reachable":false}]}',
}, "\n")

testing.test(
    "ls prints the hub line, a room pair per machine and unreachable for a dead one",
    function()
        -- List the boxes in plain text
        local root = sandbox(LISTING)
        local out, code = support.dev(root, { "box", "ls" }, ENV)
        testing.eq(code, 0)
        testing.eq(out:find("\27", 1, true), nil)
        local lines = {}
        for line in out:gmatch("[^\n]*\n") do
            lines[#lines + 1] = line:sub(1, -2)
        end

        -- Print the hub line and a room pair per machine
        testing.eq(lines[1], "             Boxes   2 of 3 running · 1 more can start")
        testing.eq(lines[2], "example-box  Boxes   2 running")
        testing.eq(lines[3], "             Memory  24 of 32 GiB used · 8 GiB free")
        testing.eq(lines[4], "mac1         unreachable")
        testing.eq(lines[5], "")

        -- Print the header and a row per box
        testing.eq(
            columns(lines[6]),
            { "NAME", "TARGET", "STATE", "ACTIVITY", "WHO", "SHAPE", "PROJECTS", "TIME LEFT" }
        )
        testing.eq(columns(lines[7]), {
            "● b1",
            "linux-x86-dev @ example-box",
            "running",
            "attached",
            "you",
            "medium",
            "myproject",
            "kept",
        })
        testing.eq(columns(lines[8]), {
            "● b2",
            "windows-vm-dev @ mac1",
            "running",
            "idle 5m",
            "agent",
            "large",
            "-",
            "kept",
        })
        testing.eq(columns(lines[9]), {
            "○ b3",
            "linux-x86-dev @ example-box",
            "stopped",
            "-",
            "alice",
            "small",
            "ci",
            "-",
        })

        -- Remove the project
        fs.remove(root, { recursive = true })
    end
)

local function memory_line(machine: string): string?
    -- Build a listing with the one machine
    local listing = table.concat({
        '{"ok":true,"boxes":[],"cap":{"running":1,"running_max":3},"machines":[',
        machine,
        "]}",
    })

    -- List the boxes
    local root = sandbox(listing)
    local out, code = support.dev(root, { "box", "ls" }, ENV)
    testing.eq(code, 0)

    -- Remove the project
    fs.remove(root, { recursive = true })

    -- Hand back the memory line
    return out:match("Memory  ([^\n]*)")
end

testing.test("ls takes the memory total from the machine and says overcommitted", function()
    testing.eq(
        memory_line(
            '{"name":"hub","running":3,"memory_limits_gib":24,"new_box_room_gib":-15,"host_total_gib":9,"reachable":true}'
        ),
        "24 of 9 GiB used · overcommitted by 15 GiB"
    )
end)

testing.test("ls prints the room as free memory beside the machine total", function()
    testing.eq(
        memory_line(
            '{"name":"hub","running":1,"memory_limits_gib":16,"new_box_room_gib":46,"host_total_gib":93,"reachable":true}'
        ),
        "16 of 93 GiB used · 46 GiB free"
    )
    testing.eq(
        memory_line(
            '{"name":"hub","running":1,"memory_limits_gib":16,"new_box_room_gib":8,"host_total_gib":null,"reachable":true}'
        ),
        "16 of 24 GiB used · 8 GiB free"
    )
    testing.eq(
        memory_line(
            '{"name":"hub","running":1,"memory_limits_gib":16,"new_box_room_gib":-4,"reachable":true}'
        ),
        "16 of 16 GiB used · overcommitted by 4 GiB"
    )
end)

testing.test("ls with no boxes still shows the room lines", function()
    -- List the boxes of a hub with none
    local root = sandbox('{"ok":true,"boxes":[],"cap":{"running":0,"running_max":3},"machines":[]}')
    local out, code = support.dev(root, { "box", "ls" }, ENV)
    testing.eq(code, 0)

    -- Print the room line and say there are no boxes
    testing.eq(out, "Boxes   0 of 3 running · 3 more can start\nno boxes\n")

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("activity names attached, the shortest idle time, none and unread", function()
    local running = "running"
    testing.eq(box.activity({ state = running, tmux_sessions = {} }), "-")
    testing.eq(box.activity({ state = running, tmux_sessions = json.null }), "?")
    testing.eq(box.activity({ state = running }), "?")
    testing.eq(
        box.activity({
            state = running,
            tmux_sessions = { { attached = false, idle_seconds = 7200 }, { attached = true } },
        }),
        "attached"
    )
    testing.eq(
        box.activity({
            state = running,
            tmux_sessions = {
                { attached = false, idle_seconds = 7200 },
                { attached = false, idle_seconds = 120 },
            },
        }),
        "idle 2m"
    )
    testing.eq(box.activity({ state = "stopped" }), "-")
end)

testing.test("who says you, agent, another human or ci's own label", function()
    testing.eq(box.who({ created_by = "human:tester" }, "tester"), "you")
    testing.eq(box.who({ created_by = "human:alice" }, "tester"), "alice")
    testing.eq(box.who({ created_by = "agent:proj-86" }, "tester"), "agent")
    testing.eq(box.who({ created_by = "adopted" }, "tester"), "adopted")
    testing.eq(box.who({ created_by = "human:tester" }, nil), "tester")
end)

testing.test("ls --json and show --json print ci's output byte for byte", function()
    -- Answer with oddly spaced documents
    local document = table.concat({
        '{ "ok": true,',
        '  "boxes": [],  "cap": {}, "machines": []}',
        "",
        "",
    }, "\n")
    local shown = '{"ok":true,   "box":{"name":"b1","state":"stopped"}}\n'
    local root = sandbox(document, shown)

    -- Print the listing untouched
    local out, code = support.dev(root, { "box", "ls", "--json" }, ENV)
    testing.eq(code, 0)
    testing.eq(out, document)

    -- Print the shown box untouched
    out, code = support.dev(root, { "box", "show", "b1", "--json" }, ENV)
    testing.eq(code, 0)
    testing.eq(out, shown)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)
