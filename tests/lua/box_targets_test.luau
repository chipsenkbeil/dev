local testing = require("@dev/testing")
local fs = require("@dev/fs")
local support = require("./support")

local ENV = { env = { USER = "tester", NO_COLOR = "1" } }

local TARGETS = table.concat({
    '{"ok":true,"targets":[',
    '{"target":"linux-dev","os":"linux","machines":["example-box"],"image":"devbox","min_shape":null,"can_take_box_now":true,"reason":null},',
    '{"target":"linux-rust","os":"linux","machines":["example-box"],"image":"linux-rust","min_shape":"medium","can_take_box_now":false,"reason":"needs 8 GiB more"},',
    '{"target":"mac-dev","os":"macos","machines":["mac1"],"image":"macos-box","min_shape":"large","can_take_box_now":true,"reason":null}]}',
}, "\n")

local SHAPES = table.concat({
    '{"ok":true,"default_shape":"medium","shapes":[',
    '{"name":"medium","cpu":8,"memory_gib":16,"default":true,"targets":[]},',
    '{"name":"small","cpu":4,"memory_gib":8,"default":false,"targets":[]},',
    '{"name":"large","cpu":12,"memory_gib":32,"default":false,"targets":[]}],',
    '"cap":{"running":1,"running_max":3,"memory_limits_gib":16,"memory_max_gib":32},',
    '"machines":[{"name":"example-box","running":1,"memory_limits_gib":16,"new_box_room_gib":8,"reachable":true},{"name":"mac1","running":0,"memory_limits_gib":0,"new_box_room_gib":20,"reachable":true}]}',
}, "\n")

local function sandbox(files)
    -- Make an empty project
    local root = support.sandbox({}, {})

    -- Write each answer on one line
    for name, body in pairs(files) do
        assert(fs.write(root .. "/" .. name .. ".json", (body:gsub("\n", "")) .. "\n"))
    end

    -- Stand in for ci
    support.fake_ci(root)
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

testing.test("targets groups by machine and shows each NOW state", function()
    -- List the targets
    local root = sandbox({ targets = TARGETS, shapes = SHAPES })
    local out, code = support.dev(root, { "box", "targets" }, ENV)
    testing.eq(code, 0)
    local lines = split(out)

    -- Group the first machine's targets under its room
    testing.eq(columns(lines[1]), { "example-box", "8 GiB free · 2 more boxes" })
    testing.eq(columns(lines[2]), { "TARGET", "OS", "IMAGE", "MIN SHAPE", "NOW" })
    testing.eq(columns(lines[3]), { "linux-dev", "Linux", "devbox", "small", "✓ fits" })
    testing.eq(
        columns(lines[4]),
        { "linux-rust", "Linux", "linux-rust", "medium", "needs 8 GiB more" }
    )

    -- Group the second machine's targets under its room
    testing.eq(lines[5], "")
    testing.eq(columns(lines[6]), { "mac1", "20 GiB free · 2 more boxes" })
    testing.eq(columns(lines[8]), { "mac-dev", "macOS", "macos-box", "large", "✓ fits" })
    testing.eq(#lines, 8)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("targets reads the structured list and --json prints ci's document", function()
    -- List the targets as JSON
    local root = sandbox({ targets = TARGETS, shapes = SHAPES })
    local out, code = support.dev(root, { "box", "targets", "--json" }, ENV)
    testing.eq(code, 0)

    -- Print ci's document
    testing.eq(out, (TARGETS:gsub("\n", "")) .. "\n")

    -- Ask ci for the targets alone
    local log = assert(fs.read(root .. "/log"))
    testing.eq(log, "fleet targets --box --json\n")

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("targets says when ci lists none", function()
    -- List the targets of a ci with none
    local root = sandbox({ targets = '{"ok":true,"targets":[]}', shapes = SHAPES })
    local out, code = support.dev(root, { "box", "targets" }, ENV)
    testing.eq(code, 0)

    -- Say there are no targets
    testing.eq(out, "no targets\n")

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("targets refuses an argument", function()
    -- List the targets with an extra word
    local root = sandbox({ targets = TARGETS, shapes = SHAPES })
    local _, code = support.dev(root, { "box", "targets", "extra" }, ENV)

    -- Refuse the word
    testing.eq(code, 2)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test(
    "targets after a shapes-only failure exits with ci's code and prints its message",
    function()
        -- Make ci fail the shapes request
        local root = sandbox({
            targets = TARGETS,
            shapes = '{"ok":false,"error":{"message":"the shapes are unavailable"}}',
        })
        assert(fs.write(root .. "/rc", "3"))

        -- List the targets
        local out, code = support.dev(root, { "box", "targets" }, ENV)

        -- Exit with ci's code and print its message
        testing.eq(code, 3)
        testing.eq(out, "dev box targets: the shapes are unavailable\n")

        -- Remove the project
        fs.remove(root, { recursive = true })
    end
)

testing.test("targets after both requests failed prints both messages and ci's code", function()
    -- Make ci fail both requests
    local root = sandbox({
        targets = '{"ok":false,"error":{"message":"the targets are unavailable"}}',
        shapes = '{"ok":false,"error":{"message":"the shapes are unavailable"}}',
    })
    assert(fs.write(root .. "/rc", "4"))

    -- List the targets
    local out, code = support.dev(root, { "box", "targets" }, ENV)

    -- Exit with ci's code and print both messages
    testing.eq(code, 4)
    testing.eq(
        out,
        table.concat({
            "dev box targets: the targets are unavailable",
            "dev box targets: the shapes are unavailable",
            "",
        }, "\n")
    )

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test(
    "targets after empty output with a non-zero exit prints nothing and ci's code",
    function()
        -- Make ci print nothing and fail
        local root = sandbox({ targets = "", shapes = "" })
        assert(fs.write(root .. "/rc", "5"))

        -- List the targets
        local out, code = support.dev(root, { "box", "targets" }, ENV)

        -- Exit with ci's code and print nothing
        testing.eq(code, 5)
        testing.eq(out, "")

        -- Remove the project
        fs.remove(root, { recursive = true })
    end
)
