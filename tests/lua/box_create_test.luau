local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local support = require("./support")

local TARGETS = table.concat({
    '{"ok":true,"targets":[',
    '{"target":"linux-dev","os":"linux","machines":["example-box"],"image":"devbox","min_shape":null,"can_take_box_now":true,"reason":null},',
    '{"target":"linux-rust","os":"linux","machines":["example-box"],"image":"linux-rust","min_shape":"medium","can_take_box_now":false,"reason":"needs 8 GiB more"},',
    '{"target":"linux-mid","os":"linux","machines":["example-box"],"image":"mid","min_shape":"medium","can_take_box_now":true,"reason":null}]}',
}, "\n")

local SHAPES = table.concat({
    '{"ok":true,"default_shape":"medium","shapes":[',
    '{"name":"small","cpu":4,"memory_gib":8,"default":false,"targets":[',
    '{"target":"linux-dev","below_min":false,"machines":[{"machine":"example-box","fits":"start","reason":null,"warning":"last running slot"}]},',
    '{"target":"linux-mid","below_min":true,"machines":[{"machine":"example-box","fits":"start","reason":null,"warning":null}]}]},',
    '{"name":"medium","cpu":8,"memory_gib":16,"default":true,"targets":[',
    '{"target":"linux-dev","below_min":false,"machines":[{"machine":"example-box","fits":"wait","reason":"need 16GiB","warning":null}]},',
    '{"target":"linux-mid","below_min":false,"machines":[{"machine":"example-box","fits":"start","reason":null,"warning":null}]}]},',
    '{"name":"large","cpu":12,"memory_gib":32,"default":false,"targets":[',
    '{"target":"linux-dev","below_min":false,"machines":[{"machine":"example-box","fits":"never","reason":"needs 8 GiB more","warning":null}]},',
    '{"target":"linux-mid","below_min":false,"machines":[{"machine":"example-box","fits":"never","reason":"needs 8 GiB more","warning":null}]}]}],',
    '"cap":{"running":1,"running_max":3,"memory_limits_gib":16,"memory_max_gib":32},',
    '"machines":[{"name":"example-box","running":1,"memory_limits_gib":16,"new_box_room_gib":8,"reachable":true}]}',
}, "\n")

local CREATED =
    [[{"ok":true,"box":{"name":"proj-x1","state":"running","target":"linux-dev","machine":"example-box","shape":"medium","expires_at":null,"delete_after":null,"projects":[{"name":"proj","path":"/srv/projects/proj"}]}}]]

local LISTING = table.concat({
    '{"ok":true,"boxes":[',
    '{"name":"b1","state":"running","target":"linux-dev","machine":"example-box"},',
    '{"name":"b2","state":"stopped","target":"linux-dev","machine":"example-box"}]}',
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

local function env(root, extra)
    -- Set the defaults of a terminal session
    local set = {
        USER = "tester",
        NO_COLOR = "1",
        FAKE_DEV = "1",
        FAKE_TTY = "1",
        DEV_AGENT = "",
        PICK_LOG = root .. "/picks",
    }

    -- Overlay the caller's values
    for name, value in pairs(extra or {}) do
        set[name] = value
    end

    -- Hand back the options
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
    -- Offer targets and shapes and answer both pickers
    local root = sandbox({ targets = TARGETS, shapes = SHAPES, create = CREATED })
    local out, code = support.dev(
        root,
        { "box", "create", "--keep", "proj" },
        env(root, { FAKE_PICK = "linux-dev medium" })
    )

    -- Report the created box
    testing.eq(code, 0)
    testing.eq(
        out,
        "Created proj-x1 · linux-dev @ example-box · medium · kept · dev connect proj-x1\n"
    )

    -- Ask ci for the targets, the shapes and then the box
    testing.eq(lines_of(root .. "/log"), {
        "fleet targets --box --json",
        "fleet targets --box --target linux-dev --json",
        "box create --target linux-dev --shape medium --by human:tester --keep --json -- proj",
    })

    -- Show both pickers their rows
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

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a shape below the target's minimum is greyed", function()
    -- Pick a target whose minimum is above the small shape
    local root = sandbox({ targets = TARGETS, shapes = SHAPES, create = CREATED })
    local _, code = support.dev(
        root,
        { "box", "create", "proj" },
        env(root, { FAKE_PICK = "linux-mid medium" })
    )
    testing.eq(code, 0)

    -- Grey the small shape
    local picks = lines_of(root .. "/picks")
    testing.eq(picks[6], "small\tsmall\t4 CPU\t8 GiB\t\t!below linux-mid's minimum")

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("--target skips both pickers and takes ci's default shape", function()
    -- Create a box with the target given
    local root = sandbox({ create = CREATED })
    local _, code =
        support.dev(root, { "box", "create", "--target", "linux-dev", "proj" }, env(root))
    testing.eq(code, 0)

    -- Pass no shape to ci and show no picker
    testing.eq(
        lines_of(root .. "/log"),
        { "box create --target linux-dev --by human:tester --json -- proj" }
    )
    testing.eq(lines_of(root .. "/picks"), {})

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("--shape skips the second picker only", function()
    -- Create a box with the shape given and answer the target picker
    local root = sandbox({ targets = TARGETS, shapes = SHAPES, create = CREATED })
    local _, code = support.dev(
        root,
        { "box", "create", "--shape", "large", "proj" },
        env(root, { FAKE_PICK = "linux-dev" })
    )
    testing.eq(code, 0)

    -- Ask ci for the targets once and create with the shape
    local log = lines_of(root .. "/log")
    testing.eq(
        log[#log],
        "box create --target linux-dev --shape large --by human:tester --json -- proj"
    )
    testing.eq(#log, 2)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("--arch passes the architecture to ci box create", function()
    -- Create a box with an architecture
    local root = sandbox({ create = CREATED })
    local _, code = support.dev(
        root,
        { "box", "create", "--arch", "aarch64", "--target", "linux-dev", "proj" },
        env(root)
    )
    testing.eq(code, 0)

    -- Pass the architecture to ci
    testing.eq(
        lines_of(root .. "/log"),
        { "box create --target linux-dev --arch aarch64 --by human:tester --json -- proj" }
    )

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("without --arch ci gets no --arch flag", function()
    -- Create a box with no architecture
    local root = sandbox({ create = CREATED })
    local _, code =
        support.dev(root, { "box", "create", "--target", "linux-dev", "proj" }, env(root))
    testing.eq(code, 0)

    -- Pass no architecture to ci
    testing.eq(
        lines_of(root .. "/log"),
        { "box create --target linux-dev --by human:tester --json -- proj" }
    )

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("create at a terminal falls back to LOGNAME when USER is unset", function()
    -- Create a box with USER unset and LOGNAME set
    local root = sandbox({ create = CREATED })
    local _, code = support.dev(
        root,
        { "box", "create", "--target", "linux-dev", "proj" },
        env(root, { FAKE_TTY = "1", USER = "", DEV_AGENT = "", LOGNAME = "tester2" })
    )
    testing.eq(code, 0)

    -- Label the box with LOGNAME
    testing.eq(
        lines_of(root .. "/log"),
        { "box create --target linux-dev --by human:tester2 --json -- proj" }
    )

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("without a terminal there are no pickers and ci applies its defaults", function()
    -- Create a box with no terminal
    local root = sandbox({ create = CREATED })
    local out, code = support.dev(
        root,
        { "box", "create", "proj" },
        env(root, { FAKE_TTY = "0", DEV_AGENT = "dotfiles/runner/x" })
    )
    testing.eq(code, 0)

    -- Report the created box
    testing.eq(
        out,
        "Created proj-x1 · linux-dev @ example-box · medium · kept · dev connect proj-x1\n"
    )

    -- Leave the target and shape to ci
    testing.eq(lines_of(root .. "/log"), { "box create --by dotfiles/runner/x --json -- proj" })

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("create labels the box with DEV_AGENT when --by is missing", function()
    -- Create a box as an agent with no --by
    local root = sandbox({ create = CREATED })
    local _, code = support.dev(
        root,
        { "box", "create", "--target", "linux-dev", "proj" },
        env(root, { DEV_AGENT = "dotfiles/runner/x" })
    )
    testing.eq(code, 0)

    -- Label the box with the agent
    testing.eq(
        lines_of(root .. "/log"),
        { "box create --target linux-dev --by dotfiles/runner/x --json -- proj" }
    )

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("--by wins over DEV_AGENT", function()
    -- Create a box as an agent with a --by
    local root = sandbox({ create = CREATED })
    local _, code = support.dev(
        root,
        { "box", "create", "--target", "linux-dev", "--by", "agent:y", "proj" },
        env(root, { DEV_AGENT = "dotfiles/runner/x" })
    )
    testing.eq(code, 0)

    -- Label the box with the --by
    testing.eq(
        lines_of(root .. "/log"),
        { "box create --target linux-dev --by agent:y --json -- proj" }
    )

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("create without a terminal or DEV_AGENT refuses and names --by human:$USER", function()
    -- Create a box with no terminal and no agent
    local root = sandbox({ create = CREATED })
    local out, code = support.dev(root, { "box", "create", "proj" }, env(root, { FAKE_TTY = "0" }))

    -- Refuse and name the flag to pass
    testing.eq(code, 1)
    testing.eq(out:find("--by human:$USER", 1, true) ~= nil, true)

    -- Ask ci for nothing
    testing.eq(lines_of(root .. "/log"), {})

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("cancelling a picker exits 1 and creates nothing", function()
    -- Cancel the first picker
    local root = sandbox({ targets = TARGETS, shapes = SHAPES, create = CREATED })
    local _, code =
        support.dev(root, { "box", "create", "proj" }, env(root, { FAKE_PICK = "CANCEL" }))
    testing.eq(code, 1)

    -- Leave out any create call
    for _, line in ipairs(lines_of(root .. "/log")) do
        testing.eq(line:find("box create", 1, true), nil)
    end

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a target that waits for room can be picked and says why", function()
    -- Rename a target and add a shape row that waits for room
    local waiting = TARGETS:gsub('"linux%-rust"', '"linux-wait"')
    local shapes = SHAPES:gsub(
        '"linux%-mid","below_min":false,"machines":%[{"machine":"example%-box","fits":"start"',
        '"linux-wait","below_min":false,"machines":[{"machine":"example-box","fits":"wait","reason":"need 16GiB","warning":null}]},\n{"target":"linux-mid","below_min":false,"machines":[{"machine":"example-box","fits":"start"',
        1
    )

    -- Pick the waiting target
    local root = sandbox({ targets = waiting, shapes = shapes, create = CREATED })
    local _, code = support.dev(
        root,
        { "box", "create", "proj" },
        env(root, { FAKE_PICK = "linux-wait medium" })
    )
    testing.eq(code, 0)

    -- Say why the target waits
    local picks = lines_of(root .. "/picks")
    testing.eq(
        picks[3],
        "linux-wait\tlinux-wait\tLinux · linux-wait\tfrom medium\t@ example-box\twaits for room · needs 8 GiB more"
    )

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("when no target fits, dev names the running box to stop", function()
    -- Offer one target that cannot take a box now
    local only = table.concat({
        '{"ok":true,"targets":[',
        '{"target":"linux-rust","os":"linux","machines":["example-box"],"image":"linux-rust","min_shape":"medium","can_take_box_now":false,"reason":"needs 8 GiB more"}]}',
    }, "\n")

    -- Create a box when no target fits
    local root = sandbox({ targets = only, shapes = SHAPES, ls = LISTING, create = CREATED })
    local out, code = support.dev(root, { "box", "create", "proj" }, env(root))

    -- Refuse and name the running box to stop
    testing.eq(code, 1)
    testing.eq(out, "dev box create: no target fits now, stop a running box to make room: b1\n")

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a machine ci could not ask makes every shape unpickable", function()
    -- Make every shape unknown to fit
    local down = SHAPES:gsub('"fits":"start"', '"fits":null'):gsub('"fits":"wait"', '"fits":null')
    local root = sandbox({ targets = TARGETS, shapes = down, ls = LISTING, create = CREATED })
    local out, code =
        support.dev(root, { "box", "create", "proj" }, env(root, { FAKE_PICK = "linux-dev" }))

    -- Refuse and name the running box to stop
    testing.eq(code, 1)
    testing.eq(
        out,
        "dev box create: no shape of linux-dev fits now, stop a running box to make room: b1\n"
    )

    -- Remove the project
    fs.remove(root, { recursive = true })
end)
