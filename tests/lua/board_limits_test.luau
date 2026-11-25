local testing = require("@dev/testing")
local board = require("@dev/board")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local support = require("./support")

local TOKEN = "pomb_SECRETtoken0123456789"
local LEAD = "dotfiles/lead"
local LEAD_SECRET = "pomb_LEADtoken9876543210"
local Column = support.Column
local POMB = table.concat({
    "[board]",
    'backend = "pomb"',
    'name = "dotfiles"',
    "",
}, "\n")
local LOCAL = table.concat({
    "[board]",
    'backend = "local"',
    'name = "mine"',
    "",
}, "\n")
local NEW = "dotfiles/implementer"
local NAME = support.COLUMN_NAME
local ID = {
    DONE = "col-done",
    PROGRESS = "col-progress",
    READY = "col-ready",
    REVIEW = "col-review",
    VERIFY = "col-verify",
}
local TASK = "task"
local LIMIT_TEXT = NAME.PROGRESS .. " is at its limit of 4"
local LIMIT_BODY = '{"code":"wip_limit_reached","message":"' .. LIMIT_TEXT .. '"}'
local EPIC = "epic"
local COUNT = "count"
local HOURS = "hours"
local IN_FLIGHT = string.format(
    "3 cards are in flight in %s, %s and %s"
        .. " (aaaaaaaa, bbbbbbbb, cccccccc), at the limit of 3. Land one first.\n",
    NAME.PROGRESS,
    NAME.REVIEW,
    NAME.VERIFY
)
local FLIGHT = {
    { "a", ID.PROGRESS, TASK },
    { "b", ID.REVIEW, TASK },
    { "c", ID.VERIFY, TASK },
    { "d", ID.READY, TASK },
}
local GROUP = '[{"id":"g1","column_ids":["'
    .. ID.PROGRESS
    .. '","'
    .. ID.REVIEW
    .. '","'
    .. ID.VERIFY
    .. '"],'
local PLANNED = support.READY_DESCRIPTION_JSON
local SUBTASKS = support.subtasks(support.READY_OUTCOMES)
local BOARDS =
    '[{"id":"board-1","name":"dotfiles","archived":false},{"id":"board-2","name":"other","archived":false}]'
local COLORS = '[{"id":"yellow-id","value":"yellow","label":"1 Pomodoro"}]'
local COLUMNS = {
    { ID.READY, NAME.READY },
    { ID.PROGRESS, NAME.PROGRESS },
    { ID.REVIEW, NAME.REVIEW },
    { ID.VERIFY, NAME.VERIFY },
    { ID.DONE, NAME.DONE },
}

local PASS = string.format(
    table.concat({
        "#!/bin/sh",
        'case "$*" in *lead*) echo "%s" ;; *) echo "%s" ;; esac',
        "",
    }, "\n"),
    LEAD_SECRET,
    TOKEN
)

local function executable(path, body)
    assert(fs.write(path, body))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local SERVERS = {}

---Make the server answer the way the old curl stub answered, from the control files in the box.
local function sync(box)
    -- Read the control files the test left in the box
    local root = box.root
    local function control(name)
        return fs.read(root .. "/" .. name)
    end
    local export = control("export.json")
    local refusal = control("move_refusal")

    -- Build the routes for an owner and the stage it owns
    local function routes_for(owner, owned)
        -- List the fixed board routes
        local routes = {
            {
                path = "/api/boards/board-1/limit-groups/g1",
                status = control("limit_refusal") and 403 or 200,
                body = control("limit_refusal") and '{"message":"columns.edit is required"}'
                    or '{"ok":true}',
            },
            { path = "/api/boards", body = control("boards.json") },
            { path = "/api/boards/board-1", body = control("detail.json") },
            { path = "/api/boards/board-2", body = control("detail2.json") },
            { path = "/api/boards/board-1/colors", body = control("colors.json") },
            { path = "/api/boards/board-1/fields", body = control("fields.json") },
        }

        -- Add the task routes
        for _, route in
            ipairs(support.pomb_task_routes({
                export = export,
                owner = owner,
                move_status = refusal and 409 or nil,
                move_body = refusal,
                owner_stage = owned,
            }))
        do
            routes[#routes + 1] = route
        end

        -- End with a catch-all route
        routes[#routes + 1] = { path = "*", body = '{"ok":true}' }
        return routes
    end

    -- Serve the routes and stage a copy for the owned card
    local server = SERVERS[root]
    server:set(routes_for(nil, server:stage_copy("owned", routes_for(NEW))))
end

local function requests(box)
    return SERVERS[box.root]:requests()
end

---The request of a method the backend logged last, with its headers.
local function entry_of(box, method)
    -- Track the last match
    local found

    -- Keep each request of the method as the last match
    for _, entry in ipairs(support.pomb_requests(SERVERS[box.root])) do
        if entry.method == method then
            found = entry
        end
    end

    -- Hand back the match or fail
    return assert(found, "no " .. method .. " request logged"), found
end

local function uuid(letter)
    return letter:rep(8) .. "-1111-4111-8111-111111111111"
end

local function detail(limits, opts)
    -- Read the options and start the column list
    local groups, units = opts and opts.groups, opts and opts.units
    local parts = {}

    -- Render each column with its limit and unit
    for _, column in ipairs(COLUMNS) do
        local limit = "null"
        if limits[column[2]] then
            limit = tostring(limits[column[2]])
        end
        local unit = ""
        if units and units[column[2]] then
            unit = string.format('"limit_unit":"%s",', units[column[2]])
        end
        parts[#parts + 1] = string.format(
            '{"id":"%s","name":"%s",%s"wip_limit":%s,"is_done":%s}',
            column[1],
            column[2],
            unit,
            limit,
            tostring(column[1] == ID.DONE)
        )
    end

    -- Wrap the columns and the limit groups in the board
    return '{"id":"board-1","name":"dotfiles","swimlanes":[],"columns":['
        .. table.concat(parts, ",")
        .. "]"
        .. (groups and (',"limit_groups":' .. groups) or "")
        .. "}"
end

local function export(placed)
    -- Start the card list
    local parts = {}

    -- Render each placed card as a ready task
    for index, place in ipairs(placed) do
        parts[#parts + 1] = support.pomb_export_task({
            id = uuid(place[1]),
            name = "Card " .. place[1],
            column_id = place[2],
            position = index,
            color_id = "yellow-id",
            kind = place[3],
            labels = place[4],
            description = PLANNED,
            subtasks = SUBTASKS,
            fields = support.ready_fields(),
        })
    end

    -- Wrap the cards in the export
    return '{"tasks":[' .. table.concat(parts, ",") .. "]}"
end

local function sandbox(opts)
    -- Make the project and a home with a fake server
    local root = support.sandbox({
        [".dev/config.toml"] = opts.project,
    }, {})
    local home = support.tempdir()
    SERVERS[root] = support.fake_http({})
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))

    -- Point the user config at the server and its two token commands
    assert(fs.write(
        home .. "/.config/dev/config.toml",
        table.concat({
            "[board.pomb]",
            'url = "' .. SERVERS[root].url .. '"',
            'field_prefix = "runner"',
            'token = "pass:secrets/worker/token/pomb"',
            'lead_token = "pass:secrets/lead/token/pomb"',
            "",
        }, "\n")
    ))

    -- Write the canned responses the server serves
    for name, body in pairs({
        ["boards.json"] = BOARDS,
        ["detail.json"] = opts.detail,
        ["colors.json"] = COLORS,
        ["fields.json"] = support.FIELDS,
        ["export.json"] = opts.export,
        ["detail2.json"] = opts.other or "{}",
    }) do
        assert(fs.write(root .. "/" .. name, body))
    end

    -- Stub the secret tools and hand back the box
    executable(
        root .. "/bin/security",
        table.concat({
            "#!/bin/sh",
            "exit 1",
            "",
        }, "\n")
    )
    executable(
        root .. "/bin/sleep",
        table.concat({
            "#!/bin/sh",
            "exec " .. dev_os.which("sleep") .. " 0.2",
            "",
        }, "\n")
    )
    executable(root .. "/bin/pass", PASS)
    return { root = root, home = home }
end

local function dev(box, args, agent)
    sync(box)
    return support.dev(box.root, args, {
        env = {
            HOME = box.home,
            ROOT = box.root,
            XDG_STATE_HOME = box.home .. "/state",
            CI = "",
            CLAUDE_SESSION_ID = "one",
            DEV_AGENT = agent,
            DEV_PASS_LOCK = box.root .. "/pass.lock",
        },
    })
end

local function read(box, name)
    return assert(fs.read(box.root .. "/" .. name))
end

testing.test("take refuses at the group limit and names the cards", function()
    -- Open a board whose limit group is full
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. '"limit":3,"count":3}]' }),
        export = export(FLIGHT),
    })

    -- Take a Ready card
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")

    -- Expect a refusal that names the cards and no claim
    testing.eq(code, 3, out)
    testing.eq(out, IN_FLIGHT)
    testing.eq(requests(box):find("/owner", 1, true), nil)
end)

testing.test("take refuses at a column limit with room in its group", function()
    -- Open a board whose Progress column is full but whose group has room
    local box = sandbox({
        project = POMB,
        detail = detail({ [NAME.PROGRESS] = 1 }, { groups = GROUP .. '"limit":4,"count":3}]' }),
        export = export(FLIGHT),
    })

    -- Take a Ready card
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")

    -- Expect a refusal that names the column and no claim
    testing.eq(code, 3, out)
    testing.eq(
        out,
        NAME.PROGRESS .. " holds 1 card (aaaaaaaa), at its limit of 1. Land one first.\n"
    )
    testing.eq(requests(box):find("/owner", 1, true), nil)
end)

testing.test("a count limit still refuses at its limit", function()
    -- Open a board whose Progress column has a count limit of one
    local box = sandbox({
        project = POMB,
        detail = detail({ [NAME.PROGRESS] = 1 }, { units = { [NAME.PROGRESS] = COUNT } }),
        export = export(FLIGHT),
    })

    -- Take a Ready card
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")

    -- Expect a refusal that names the column
    testing.eq(code, 3, out)
    testing.eq(
        out,
        NAME.PROGRESS .. " holds 1 card (aaaaaaaa), at its limit of 1. Land one first.\n"
    )
end)

testing.test("an hours limit never refuses a take or move", function()
    -- Open a board whose Progress column has an hours limit of one
    local box = sandbox({
        project = POMB,
        detail = detail({ [NAME.PROGRESS] = 1 }, { units = { [NAME.PROGRESS] = HOURS } }),
        export = export(FLIGHT),
    })

    -- Take a Ready card and expect the take to go through
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")
    testing.eq(code, 0, out)
    testing.ok(out:find("took dddddddd", 1, true), out)

    -- Release the card and move it into Progress
    dev(box, { "board", "release", "dddddddd" }, "")
    out, code = dev(box, { "board", "move", "dddddddd", Column.PROGRESS }, NEW)
    testing.eq(code, 0, out)
    testing.ok(requests(box):find("/move", 1, true), requests(box))
end)

testing.test("a board with no limits is uncapped", function()
    -- Open a board with no limits
    local box = sandbox({ project = POMB, detail = detail({}), export = export(FLIGHT) })

    -- Take a Ready card and expect the take to go through
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")
    testing.eq(code, 0, out)
    testing.ok(out:find("took dddddddd", 1, true), out)

    -- Release the card
    dev(box, { "board", "release", "dddddddd" }, "")
end)

testing.test("an epic in the group is not counted", function()
    -- Open a board whose group holds two tasks and an epic
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. '"limit":3,"count":2}]' }),
        export = export({
            { "a", ID.PROGRESS, TASK },
            { "b", ID.REVIEW, TASK },
            { "c", ID.VERIFY, EPIC },
            { "d", ID.READY, TASK },
        }),
    })

    -- Take a Ready card and expect the take to go through
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")
    testing.eq(code, 0, out)

    -- Release the card
    dev(box, { "board", "release", "dddddddd" }, "")
end)

testing.test("a run card in the group is not counted", function()
    -- Open a board whose group holds two tasks and a run card
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. '"limit":3,"count":2}]' }),
        export = export({
            { "a", ID.PROGRESS, TASK },
            { "b", ID.REVIEW, TASK },
            { "c", ID.VERIFY, TASK, { board.RUN } },
            { "d", ID.READY, TASK },
        }),
    })

    -- Take a Ready card and expect the take to go through
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")
    testing.eq(code, 0, out)

    -- Release the card
    dev(box, { "board", "release", "dddddddd" }, "")
end)

testing.test("move refuses a card entering a full group and names the cards", function()
    -- Open a board whose limit group is full
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. '"limit":3,"count":3}]' }),
        export = export(FLIGHT),
    })

    -- Move a Ready card into Review
    local out, code = dev(box, { "board", "move", "dddddddd", Column.REVIEW }, "")

    -- Expect a refusal that names the cards and no move request
    testing.eq(code, 3, out)
    testing.eq(out, IN_FLIGHT)
    testing.eq(requests(box):find("/move", 1, true), nil)
end)

local function flight_with(labels)
    return {
        { "a", ID.PROGRESS, TASK },
        { "b", ID.REVIEW, TASK },
        { "c", ID.VERIFY, TASK },
        { "d", ID.READY, TASK, labels },
    }
end

testing.test("take and move accept a trunk-blocker card at the group limit", function()
    -- Open a full group whose Ready card is a trunk blocker
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. '"limit":3,"count":3}]' }),
        export = export(flight_with({ board.TRUNK_BLOCKER })),
    })

    -- Take the card and expect a forced move
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")
    testing.eq(code, 0, out)
    testing.ok(out:find("took dddddddd", 1, true), out)
    local calls = requests(box)
    testing.ok(calls:find("/move?force=true", 1, true), calls)

    -- Move the card and expect a forced move through the query alone
    out, code = dev(box, { "board", "move", "dddddddd", Column.PROGRESS }, NEW)
    testing.eq(code, 0, out)
    calls = requests(box)
    testing.ok(calls:find("/move?force=true", 1, true), calls)
    testing.eq(calls:find('"force"', 1, true), nil)
end)

testing.test("a second trunk-blocker card at the group limit is refused", function()
    -- Open a full group whose In Progress and Ready cards are both trunk blockers
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. '"limit":3,"count":3}]' }),
        export = export({
            { "a", ID.PROGRESS, TASK, { board.TRUNK_BLOCKER } },
            { "b", ID.REVIEW, TASK },
            { "c", ID.VERIFY, TASK },
            { "d", ID.READY, TASK, { board.TRUNK_BLOCKER } },
        }),
    })

    -- Expect the take to be refused
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")
    testing.eq(code, 3, out)
    testing.eq(out, IN_FLIGHT)

    -- Expect the move to be refused with no move request
    out, code = dev(box, { "board", "move", "dddddddd", Column.PROGRESS }, NEW)
    testing.eq(code, 3, out)
    testing.eq(requests(box):find("/move", 1, true), nil)
end)

testing.test("a card with another label is still refused at the group limit", function()
    -- Open a full group whose Ready card carries an ordinary label
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. '"limit":3,"count":3}]' }),
        export = export(flight_with({ "docs" })),
    })

    -- Expect the take to be refused
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")
    testing.eq(code, 3, out)
    testing.eq(out, IN_FLIGHT)

    -- Expect the move to be refused with no move request
    out, code = dev(box, { "board", "move", "dddddddd", Column.PROGRESS }, NEW)
    testing.eq(code, 3, out)
    testing.eq(requests(box):find("/move", 1, true), nil)
end)

testing.test("a plain move sends no force", function()
    -- Open a board with no limits
    local box = sandbox({ project = POMB, detail = detail({}), export = export(FLIGHT) })

    -- Move a Ready card into Progress
    local out, code = dev(box, { "board", "move", "dddddddd", Column.PROGRESS }, NEW)
    testing.eq(code, 0, out)

    -- Expect the move to name the column and carry no force
    local calls = requests(box)
    testing.ok(calls:find('"column_id":"' .. ID.PROGRESS .. '"', 1, true), calls)
    testing.eq(calls:find("force", 1, true), nil)
end)

testing.test("move refuses a card entering a full column", function()
    -- Open a board whose Review column is full but whose group has room
    local box = sandbox({
        project = POMB,
        detail = detail({ [NAME.REVIEW] = 1 }, { groups = GROUP .. '"limit":4,"count":3}]' }),
        export = export(FLIGHT),
    })

    -- Move a Ready card into Review
    local out, code = dev(box, { "board", "move", "dddddddd", Column.REVIEW }, "")

    -- Expect a refusal that names the column and no move request
    testing.eq(code, 3, out)
    testing.eq(out, NAME.REVIEW .. " holds 1 card (bbbbbbbb), at its limit of 1. Land one first.\n")
    testing.eq(requests(box):find("/move", 1, true), nil)
end)

testing.test("a move inside the group is not counted", function()
    -- Open a board whose group limit is below its count
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. '"limit":2,"count":3}]' }),
        export = export(FLIGHT),
    })

    -- Move a card from Verify into Review
    local out, code = dev(box, { "board", "move", "cccccccc", Column.REVIEW }, "")

    -- Expect the move to go through
    testing.eq(code, 0, out)
    testing.eq(out, "moved cccccccc to Review\n")
    testing.ok(requests(box):find("/move", 1, true), requests(box))
end)

testing.test("a 409 wip_limit_reached becomes the refusal and move releases the claim", function()
    -- Open a board whose server refuses the move
    local box = sandbox({ project = POMB, detail = detail({}), export = export(FLIGHT) })
    assert(fs.write(box.root .. "/move_refusal", LIMIT_BODY))

    -- Move a claimed card into Progress
    local out, code = dev(box, { "board", "move", "dddddddd", Column.PROGRESS }, NEW)

    -- Expect the server's refusal as the answer
    testing.eq(code, 3, out)
    testing.eq(out, "Pomb refused the move: " .. LIMIT_TEXT .. "\n")

    -- Expect the claim released with no force and no local claim left
    local calls = requests(box)
    testing.ok(calls:find("/api/tasks/" .. uuid("d") .. "/owner/release", 1, true), calls)
    testing.eq(calls:find("force", 1, true), nil)
    testing.eq(fs.exists(box.home .. "/state/dev/board/" .. uuid("d")), false)
end)

testing.test("take of a Ready card whose move is refused releases the claim", function()
    -- Open a board whose server refuses the move
    local box = sandbox({ project = POMB, detail = detail({}), export = export(FLIGHT) })
    assert(fs.write(box.root .. "/move_refusal", LIMIT_BODY))

    -- Take a Ready card
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")

    -- Expect the take to fail with the server's text
    testing.eq(code, 1, out)
    testing.ok(out:find(LIMIT_TEXT, 1, true), out)

    -- Expect the claim released and no local claim left
    local calls = requests(box)
    testing.ok(calls:find("/api/tasks/" .. uuid("d") .. "/owner/release", 1, true), calls)
    testing.eq(fs.exists(box.home .. "/state/dev/board/" .. uuid("d")), false)
end)

testing.test("a local board is uncapped", function()
    -- Open a local board
    local box = sandbox({
        project = LOCAL,
        detail = detail({}),
        export = export({}),
    })

    -- Create its files
    local out, code = dev(box, { "board", "init" }, "")
    testing.eq(code, 0, out)

    -- Add six cards and move each into Progress
    for index = 1, 6 do
        local args = {
            "board",
            "add",
            "Card" .. index,
            "--column",
            Column.READY,
            "--size",
            "1",
            "--description",
            support.READY_DESCRIPTION,
        }
        for _, outcome in ipairs(support.READY_OUTCOMES) do
            args[#args + 1] = "--done-when"
            args[#args + 1] = outcome.name
        end
        for _, row in ipairs(support.READY_CHECKS) do
            args[#args + 1] = "--checks"
            args[#args + 1] = row
        end
        out, code = dev(box, args, "")
        testing.eq(code, 0, out)
        local id = assert(out:match("added (%x+)"), out)
        out, code = dev(box, { "board", "move", id, Column.PROGRESS }, NEW .. "/" .. index)
        testing.eq(code, 0, out)
    end
end)

local UNITS = '"limit":4,"limit_unit":"count","count":2}]'

testing.test("limits prints each column limit with its unit and each group", function()
    -- Open a board with an hours limit on Progress and a group
    local box = sandbox({
        project = POMB,
        detail = detail(
            { [NAME.PROGRESS] = 2 },
            { groups = GROUP .. UNITS, units = { [NAME.PROGRESS] = HOURS } }
        ),
        export = export({}),
    })

    -- Print the limits
    local out, code = dev(box, { "board", "limits" }, "")

    -- Expect the column limit and the group line
    testing.eq(code, 0, out)
    testing.eq(
        out,
        table.concat({
            NAME.PROGRESS .. ": 2 hours",
            NAME.PROGRESS .. ", " .. NAME.REVIEW .. ", " .. NAME.VERIFY .. ": 4 (2 in flight)",
            "",
        }, "\n")
    )
end)

testing.test("limits --set patches the group with its columns and the new limit", function()
    -- Open a board with a limit group
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. UNITS }),
        export = export({}),
    })

    -- Set the limit as the lead
    local out, code = dev(box, { "board", "limits", "--set", "6" }, LEAD)

    -- Expect a confirmation that names the columns
    testing.eq(code, 0, out)
    testing.eq(
        out,
        string.format(
            "Set the limit of %s, %s and %s to 6.\n",
            NAME.PROGRESS,
            NAME.REVIEW,
            NAME.VERIFY
        )
    )

    -- Expect a patch that carries the columns and the new limit
    local want = "PATCH /api/boards/board-1/limit-groups/g1 body="
        .. string.format(
            '{"column_ids":["%s","%s","%s"],"limit":6}',
            ID.PROGRESS,
            ID.REVIEW,
            ID.VERIFY
        )
    testing.ok(requests(box):find("PATCH /", 1, true), requests(box))
    testing.ok(requests(box):find(want, 1, true), requests(box))
end)

testing.test("limits --set names the lead token when Pomb answers 403", function()
    -- Open a board whose server refuses the limit change
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. UNITS }),
        export = export({}),
    })
    assert(fs.write(box.root .. "/limit_refusal", "x"))

    -- Set the limit as the lead
    local out, code = dev(box, { "board", "limits", "--set", "6" }, LEAD)

    -- Expect a failure that names the lead token
    testing.eq(code, 1, out)
    testing.ok(out:find("use a lead token, which holds columns.edit.", 1, true), out)
end)

testing.test("limits --set refuses a board with no group and a bad number", function()
    -- Open a board with no limit group
    local box = sandbox({ project = POMB, detail = detail({}), export = export({}) })

    -- Expect a refusal that names the missing group
    local out, code = dev(box, { "board", "limits", "--set", "6" }, LEAD)
    testing.eq(code, 1, out)
    testing.ok(out:find("has no limit group that holds", 1, true), out)

    -- Expect a usage error for each bad number
    for _, bad in ipairs({ "0", "x", "2.5" }) do
        out, code = dev(box, { "board", "limits", "--set", bad }, LEAD)
        testing.eq(code, 2, out)
        testing.ok(out:find("needs a whole number", 1, true), out)
    end
end)

testing.test("limits --set refuses a board name beside it", function()
    -- Open a board with no limit group
    local box = sandbox({ project = POMB, detail = detail({}), export = export({}) })

    -- Set the limit with a board name beside it
    local out, code = dev(box, { "board", "limits", "other", "--set", "6" }, LEAD)

    -- Expect a usage error that names the flag
    testing.eq(code, 2, out)
    testing.ok(out:find("The --set flag changes only this project's board.", 1, true), out)
end)

testing.test("limits --set under a lead name sends the lead token", function()
    -- Open a board with a limit group
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. UNITS }),
        export = export({}),
    })

    -- Set the limit as the lead
    local out, code = dev(box, { "board", "limits", "--set", "6" }, LEAD)

    -- Expect the patch to carry the lead token
    testing.eq(code, 0, out)
    testing.ok(entry_of(box, "PATCH").text:find(LEAD_SECRET, 1, true), requests(box))
end)

testing.test("column under a lead name sends the lead token to the column", function()
    -- Open a board with a limit group
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. UNITS }),
        export = export({}),
    })

    -- Block the Review column as the lead
    local out, code = dev(box, { "board", "column", NAME.REVIEW, "--blocked", "on" }, LEAD)

    -- Expect a patch to the column that carries the lead token
    testing.eq(code, 0, out)
    testing.ok(requests(box):find("PATCH /", 1, true), requests(box))
    testing.ok(requests(box):find("/api/columns/" .. ID.REVIEW, 1, true), requests(box))
    testing.ok(entry_of(box, "PATCH").text:find(LEAD_SECRET, 1, true), requests(box))
end)

testing.test("limits without --set under a lead name sends the worker token", function()
    -- Open a board with a limit group
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. UNITS }),
        export = export({}),
    })

    -- Print the limits as the lead
    local out, code = dev(box, { "board", "limits" }, LEAD)
    testing.eq(code, 0, out)

    -- Expect the worker token on the wire and the lead token nowhere
    local sent = requests(box)
    testing.ok(sent:find(TOKEN, 1, true), sent)
    testing.eq(sent:find(LEAD_SECRET, 1, true), nil)
end)

testing.test("limits --set under a non-lead name is refused before any request", function()
    -- Open a board with a limit group
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = GROUP .. UNITS }),
        export = export({}),
    })

    -- Set the limit as an implementer
    local out, code = dev(box, { "board", "limits", "--set", "6" }, NEW)

    -- Expect a refusal and no request
    testing.eq(code, 1, out)
    testing.ok(out:find("Only the lead sets a limit.", 1, true), out)
    testing.eq(requests(box), "")
end)

testing.test("limits --set refuses a local board with a sentence", function()
    -- Open a local board
    local box = sandbox({
        project = LOCAL,
        detail = detail({}),
        export = export({}),
    })

    -- Set the limit as the lead
    local out, code = dev(box, { "board", "limits", "--set", "6" }, LEAD)

    -- Expect a refusal that says a local board has no group
    testing.eq(code, 1, out)
    testing.ok(out:find("A local board has no limit group to set.", 1, true), out)
end)

testing.test("limits exits 1 with no limit group when the board has none", function()
    -- Open a board with an empty group list
    local box = sandbox({
        project = POMB,
        detail = detail({}, { groups = "[]" }),
        export = export({}),
    })

    -- Print the limits
    local out, code = dev(box, { "board", "limits" }, "")

    -- Expect a failure that says the board has no group
    testing.eq(code, 1, out)
    testing.eq(out, "The board has no limit group.\n")
end)

testing.test("limits names a column limit with no group and still exits 1", function()
    -- Open a board with a column limit and no group
    local box = sandbox({
        project = POMB,
        detail = detail({ [NAME.READY] = 5 }),
        export = export({}),
    })

    -- Print the limits of the project's board by name
    local out, code = dev(box, { "board", "limits", "dotfiles" }, "")

    -- Expect the column limit and the missing group
    testing.eq(code, 1, out)
    testing.eq(
        out,
        table.concat({
            NAME.READY .. ": 5 count",
            "The board has no limit group.",
            "",
        }, "\n")
    )
end)

testing.test("limits names another board and reads its limits", function()
    -- Open a project board and a second board with a group
    local box = sandbox({
        project = POMB,
        detail = detail({}),
        other = detail({}, { groups = GROUP .. UNITS }),
        export = export({}),
    })

    -- Print the limits of the second board
    local out, code = dev(box, { "board", "limits", "other" }, "")

    -- Expect its group line
    testing.eq(code, 0, out)
    testing.eq(
        out,
        NAME.PROGRESS .. ", " .. NAME.REVIEW .. ", " .. NAME.VERIFY .. ": 4 (2 in flight)\n"
    )
end)
