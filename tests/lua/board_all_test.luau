local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local support = require("./support")

local TOKEN = "pomb_SECRETtoken0123456789"
local POMB = '[board]\nbackend = "pomb"\nname = "dotfiles"\n'
local NAME = support.COLUMN_NAME
local READY = "col-ready"
local DONE = "col-done"
local BOARDS =
    '[{"id":"board-1","name":"dotfiles","archived":false},{"id":"board-2","name":"other","archived":false}]'
local COLORS = '[{"id":"yellow-id","value":"yellow","label":"1 Pomodoro"}]'
local DETAIL = '{"id":"board-1","name":"dotfiles","swimlanes":[],"columns":['
    .. '{"id":"'
    .. READY
    .. '","name":"'
    .. NAME.READY
    .. '","wip_limit":null,"is_done":false},'
    .. '{"id":"'
    .. DONE
    .. '","name":"'
    .. NAME.DONE
    .. '","wip_limit":null,"is_done":true}]}'

local UUID = ("%w"):rep(8)
    .. "%-"
    .. ("%w"):rep(4)
    .. "%-"
    .. ("%w"):rep(4)
    .. "%-"
    .. ("%w"):rep(4)
    .. "%-"
    .. ("%w"):rep(12)

---Make the server answer the way the old curl stub answered, from the fixture files in the box.
local function sync(box)
    local function control(name)
        return fs.read(box.root .. "/" .. name)
    end
    local routes = {}
    local ids, seen = {}, {}
    for _, name in ipairs(fs.list(box.root) or {}) do
        local text = name:find("%.json$") and control(name) or ""
        for id in text:gmatch(UUID) do
            if not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end
    routes[#routes + 1] =
        { path = "/api/search*", contains = "cursor=c2", body = control("search2.json") }
    routes[#routes + 1] = { path = "/api/search*", body = control("search1.json") }
    for _, id in ipairs(ids) do
        routes[#routes + 1] = { path = "/api/tasks/" .. id .. "/comments", body = "[]" }
        routes[#routes + 1] = { path = "/api/tasks/" .. id .. "/links", body = "[]" }
        local task = control("task_" .. id .. ".json")
        routes[#routes + 1] = task and { path = "/api/tasks/" .. id, body = task }
            or {
                path = "/api/tasks/" .. id,
                status = 403,
                body = '{"code":"forbidden","message":"the token cannot read this board"}',
            }
    end
    local export = control("export.json") or '{"tasks":[]}'
    local plain = {
        { "/api/boards", control("boards.json") },
        { "/api/boards/board-1", control("detail.json") },
        { "/api/boards/board-1/colors", control("colors.json") },
        { "/api/boards/board-1/fields", control("fields.json") },
        { "/api/boards/board-1/export-data", export },
        { "/api/boards/board-1/tasks", support.export_page(export) },
    }
    for _, entry in ipairs(plain) do
        routes[#routes + 1] = { path = entry[1], body = entry[2] }
    end
    routes[#routes + 1] = { path = "*", body = '{"ok":true}' }
    box.server:set(routes)
end
local PASS = string.format('#!/bin/sh\necho "%s"\n', TOKEN)

local function executable(path, body)
    assert(fs.write(path, body))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function uuid(letter)
    return letter:rep(8) .. "-1111-4111-8111-111111111111"
end

local function hit(letter, board_name, name)
    return string.format(
        '{"task_id":"%s","name":"%s","board_id":"id-%s","board_name":"%s",'
            .. '"column_name":"%s","status":"open"}',
        uuid(letter),
        name,
        board_name,
        board_name,
        support.COLUMN_NAME.BLOCKED
    )
end

local function page(hits, cursor)
    return string.format(
        '{"items":[%s],"truncated":%s,"next_cursor":%s}',
        table.concat(hits, ","),
        cursor and "true" or "false",
        cursor and ('"' .. cursor .. '"') or "null"
    )
end

local function sandbox(files)
    local root = support.sandbox({ [".dev/config.toml"] = POMB }, {})
    local home = support.tempdir()
    local server = support.fake_http({})
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(
        fs.write(
            home .. "/.config/dev/config.toml",
            '[board.pomb]\nurl = "'
                .. server.url
                .. '"\nfield_prefix = "runner"\ntoken = "pass:secrets/worker/token/pomb"\n'
        )
    )
    local all = {
        ["boards.json"] = BOARDS,
        ["detail.json"] = DETAIL,
        ["colors.json"] = COLORS,
        ["fields.json"] = support.FIELDS,
        ["export.json"] = '{"tasks":[]}',
    }
    for name, body in pairs(files) do
        all[name] = body
    end
    for name, body in pairs(all) do
        assert(fs.write(root .. "/" .. name, body))
    end
    executable(root .. "/bin/security", "#!/bin/sh\nexit 1\n")
    executable(root .. "/bin/pass", PASS)
    return { root = root, home = home, server = server }
end

local function dev(box, args)
    sync(box)
    return support.dev(box.root, args, {
        env = {
            HOME = box.home,
            ROOT = box.root,
            XDG_STATE_HOME = box.home .. "/state",
            CI = "",
            CLAUDE_SESSION_ID = "one",
            DEV_AGENT = "",
            DEV_PASS_LOCK = box.root .. "/pass.lock",
        },
    })
end

local function task(letter, entered, epic)
    return string.format(
        '{"id":"%s","name":"Card %s","column_entered_at":"%s","created_at":"2026-01-01T00:00:00Z"%s}',
        uuid(letter),
        letter,
        entered,
        epic and (',"parent":{"id":"' .. uuid("e") .. '","name":"' .. epic .. '"}') or ""
    )
end

local function at(text, needle)
    local found = text:find(needle, 1, true)
    testing.ok(found, needle .. " is missing from " .. text)
    return found
end

testing.test("status --all lists cards of two boards newest first across pages", function()
    local box = sandbox({
        ["search1.json"] = page({
            hit("a", "dotfiles", "Oldest card"),
            hit("b", "other", "Newest card"),
        }, "c2"),
        ["search2.json"] = page({ hit("c", "dotfiles", "Middle card") }),
        ["task_" .. uuid("a") .. ".json"] = task("a", "2026-11-01T10:00:00Z", "Big epic"),
        ["task_" .. uuid("b") .. ".json"] = task("b", "2026-11-03T10:00:00Z"),
        ["task_" .. uuid("c") .. ".json"] = task("c", "2026-11-02T10:00:00Z"),
    })
    local out, code = dev(box, { "board", "status", "--all" })
    testing.eq(code, 0, out)
    testing.ok(out:find("backend: pomb", 1, true), out)
    local newest, middle, oldest = at(out, "bbbbbbbb"), at(out, "cccccccc"), at(out, "aaaaaaaa")
    testing.ok(newest < middle and middle < oldest, out)
    at(out, "other")
    at(out, "Big epic")
    at(out, "Newest card")
    testing.eq(out:find("unreadable", 1, true), nil)
    local calls = box.server:requests()
    at(calls, "/api/search?q=label:needs:human&limit=100")
    at(calls, "cursor=c2")
end)

testing.test("status --all names a board it cannot read and lists the rest", function()
    local box = sandbox({
        ["search1.json"] = page({
            hit("a", "dotfiles", "Readable card"),
            hit("b", "secret", "Hidden card"),
        }),
        ["task_" .. uuid("a") .. ".json"] = task("a", "2026-11-01T10:00:00Z", "Big epic"),
    })
    local out, code = dev(box, { "board", "status", "--all" })
    testing.eq(code, 0, out)
    at(out, "Readable card")
    at(out, "Hidden card")
    at(out, "unreadable: secret")
end)

testing.test("status --all with no cards says so", function()
    local box = sandbox({ ["search1.json"] = page({}) })
    local out, code = dev(box, { "board", "status", "--all" })
    testing.eq(code, 0, out)
    at(out, "No cards.")
end)

testing.test("show on an epic names the board of a child on another board", function()
    local epic = uuid("e")
    local children = string.format(
        '[{"id":"%s","name":"Far child","board_id":"board-2","column_name":"%s","done":false},'
            .. '{"id":"%s","name":"Own child","board_id":"board-1","column_name":"%s","done":true}]',
        uuid("f"),
        NAME.READY,
        uuid("g"),
        NAME.DONE
    )
    local box = sandbox({
        ["export.json"] = '{"tasks":[' .. support.pomb_export_task({
            id = epic,
            name = "Big epic",
            column_id = READY,
            color_id = "yellow-id",
            kind = "epic",
        }) .. "]}",
        ["task_" .. epic .. ".json"] = '{"id":"'
            .. epic
            .. '","name":"Big epic","column_id":"'
            .. READY
            .. '","color_id":"yellow-id","labels":[],"kind":"epic","children_total":2,"children_done":1,"children":'
            .. children
            .. "}",
    })
    local out, code = dev(box, { "board", "show", "eeeeeeee" })
    testing.eq(code, 0, out)
    at(out, "children: 1 of 2 done")
    at(out, "- [other] ffffffff Far child (" .. NAME.READY .. ")")
    at(out, "- gggggggg Own child (" .. NAME.DONE .. ")")
end)
