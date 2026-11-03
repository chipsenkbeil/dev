local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local ENV = { env = { USER = "tester", NO_COLOR = "1" } }

local TARGETS = [[{"ok":true,"targets":[
{"target":"linux-dev","os":"linux","machines":["example-box"],"image":"devbox","min_shape":null,"can_take_box_now":true,"reason":null},
{"target":"linux-rust","os":"linux","machines":["example-box"],"image":"linux-rust","min_shape":"medium","can_take_box_now":false,"reason":"needs 8 GiB more"},
{"target":"mac-dev","os":"macos","machines":["mac1"],"image":"macos-box","min_shape":"large","can_take_box_now":true,"reason":null}]}]]

local SHAPES = [[{"ok":true,"default_shape":"medium","shapes":[
{"name":"medium","cpu":8,"memory_gib":16,"default":true,"targets":[]},
{"name":"small","cpu":4,"memory_gib":8,"default":false,"targets":[]},
{"name":"large","cpu":12,"memory_gib":32,"default":false,"targets":[]}],
"cap":{"running":1,"running_max":3,"memory_limits_gib":16,"memory_max_gib":32},
"machines":[{"name":"example-box","running":1,"memory_limits_gib":16,"new_box_room_gib":8,"reachable":true},{"name":"mac1","running":0,"memory_limits_gib":0,"new_box_room_gib":20,"reachable":true}]}]]

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

local function columns(line)
    local cells, rest = {}, (line:gsub("^%s+", ""))
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

local function split(out)
    local lines = {}
    for line in out:gmatch("[^\n]*\n") do
        lines[#lines + 1] = line:sub(1, -2)
    end
    return lines
end

t.test("targets groups by machine and shows each NOW state", function()
    local root = sandbox({ targets = TARGETS, shapes = SHAPES })
    local out, code = support.dev(root, { "box", "targets" }, ENV)
    t.eq(code, 0)
    local lines = split(out)
    t.eq(columns(lines[1]), { "example-box", "8 GiB free · 2 more boxes" })
    t.eq(columns(lines[2]), { "TARGET", "OS", "IMAGE", "MIN SHAPE", "NOW" })
    t.eq(columns(lines[3]), { "linux-dev", "Linux", "devbox", "small", "✓ fits" })
    t.eq(columns(lines[4]), { "linux-rust", "Linux", "linux-rust", "medium", "needs 8 GiB more" })
    t.eq(lines[5], "")
    t.eq(columns(lines[6]), { "mac1", "20 GiB free · 2 more boxes" })
    t.eq(columns(lines[8]), { "mac-dev", "macOS", "macos-box", "large", "✓ fits" })
    t.eq(#lines, 8)
    fs.remove(root, { recursive = true })
end)

t.test("targets reads the structured list and --json prints ci's document", function()
    local root = sandbox({ targets = TARGETS, shapes = SHAPES })
    local out, code = support.dev(root, { "box", "targets", "--json" }, ENV)
    t.eq(code, 0)
    t.eq(out, (TARGETS:gsub("\n", "")) .. "\n")
    local log = assert(fs.read(root .. "/log"))
    t.eq(log, "fleet targets --box --json\n")
    fs.remove(root, { recursive = true })
end)

t.test("targets says when ci lists none", function()
    local root = sandbox({ targets = '{"ok":true,"targets":[]}', shapes = SHAPES })
    local out, code = support.dev(root, { "box", "targets" }, ENV)
    t.eq(code, 0)
    t.eq(out, "no targets\n")
    fs.remove(root, { recursive = true })
end)

t.test("targets refuses an argument", function()
    local root = sandbox({ targets = TARGETS, shapes = SHAPES })
    local _, code = support.dev(root, { "box", "targets", "extra" }, ENV)
    t.eq(code, 2)
    fs.remove(root, { recursive = true })
end)
