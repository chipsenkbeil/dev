local t = require("dev.testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local TOKEN = "pomb_SECRETtoken0123456789"
local COLUMN = support.COLUMN
local POMB = '[board]\nbackend = "pomb"\nname = "dotfiles"\n'
local NEW = "dotfiles/implementer"
local V1 = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone\n\n## Done when\n- [ ] done"
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
local IN_FLIGHT = string.format(
    "dev: 3 cards are in flight in %s, %s and %s"
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
local PLANNED =
    "## Problem\\nwhy\\n\\n## Change\\n- x\\n\\n## Out of scope\\nnone\\n\\n## Done when\\n- [ ] a"
local BOARDS = '[{"id":"board-1","name":"dotfiles","archived":false}]'
local COLORS = '[{"id":"yellow-id","value":"yellow","label":"1 Pomodoro"}]'
local COLUMNS = {
    { ID.READY, NAME.READY },
    { ID.PROGRESS, NAME.PROGRESS },
    { ID.REVIEW, NAME.REVIEW },
    { ID.VERIFY, NAME.VERIFY },
    { ID.DONE, NAME.DONE },
}

local CURL = [[#!/bin/sh
printf 'curl %s\n' "$*" >>"$ROOT/calls"
cat >"$ROOT/stdin"
for last; do :; done
status=200
case "$last" in
*/api/boards) body=$(cat "$ROOT/boards.json") ;;
*/api/boards/board-1) body=$(cat "$ROOT/detail.json") ;;
*/colors) body=$(cat "$ROOT/colors.json") ;;
*/fields) body=$(cat "$ROOT/fields.json") ;;
*/export-data) body=$(cat "$ROOT/export.json") ;;
*/move)
    body='{"ok":true}'
    if [ -f "$ROOT/move_refusal" ]; then
        body=$(cat "$ROOT/move_refusal")
        status=409
    fi
    ;;
*/comments) body='[]' ;;
*/claim/release) body= ;;
*/claim/heartbeat) body='{"ok":true}' ;;
*/claim) body='{"fence":7,"claimant":"x"}' ;;
*) body='{"ok":true}' ;;
esac
printf '%s\n%s' "$body" "$status"
]]

local function executable(path, body)
    assert(fs.write(path, body))
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function uuid(letter)
    return letter:rep(8) .. "-1111-4111-8111-111111111111"
end

local function detail(limits, groups)
    local parts = {}
    for _, column in ipairs(COLUMNS) do
        local limit = "null"
        if limits[column[2]] then
            limit = tostring(limits[column[2]])
        end
        parts[#parts + 1] = string.format(
            '{"id":"%s","name":"%s","wip_limit":%s,"is_done":%s}',
            column[1],
            column[2],
            limit,
            tostring(column[1] == ID.DONE)
        )
    end
    return '{"id":"board-1","name":"dotfiles","swimlanes":[],"columns":['
        .. table.concat(parts, ",")
        .. "]"
        .. (groups and (',"limit_groups":' .. groups) or "")
        .. "}"
end

local function export(placed)
    local parts = {}
    for index, place in ipairs(placed) do
        parts[#parts + 1] = string.format(
            '{"id":"%s","name":"Card %s","column_id":"%s","position":%d,"color_id":"yellow-id",'
                .. '"labels":[],"kind":"%s","description":"%s"}',
            uuid(place[1]),
            place[1],
            place[2],
            index,
            place[3],
            PLANNED
        )
    end
    return '{"tasks":[' .. table.concat(parts, ",") .. "]}"
end

local function sandbox(opts)
    local root = support.sandbox({
        [".dev/config.toml"] = opts.project,
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(
        fs.write(
            home .. "/.config/dev/config.toml",
            '[board.pomb]\nurl = "https://pomb.example"\ntoken = "pass:secrets/worker/token/pomb"\n'
        )
    )
    for name, body in pairs({
        ["boards.json"] = BOARDS,
        ["detail.json"] = opts.detail,
        ["colors.json"] = COLORS,
        ["fields.json"] = support.FIELDS,
        ["export.json"] = opts.export,
    }) do
        assert(fs.write(root .. "/" .. name, body))
    end
    executable(root .. "/bin/curl", CURL)
    executable(root .. "/bin/security", "#!/bin/sh\nexit 1\n")
    executable(root .. "/bin/sleep", "#!/bin/sh\nexec " .. devos.which("sleep") .. " 0.2\n")
    executable(root .. "/bin/pass", '#!/bin/sh\necho "' .. TOKEN .. '"\n')
    return { root = root, home = home }
end

local function dev(box, args, agent)
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

t.test("take refuses at the group limit and names the cards", function()
    local box = sandbox({
        project = POMB,
        detail = detail({}, GROUP .. '"limit":3,"count":3}]'),
        export = export(FLIGHT),
    })
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")
    t.eq(code, 1, out)
    t.eq(out, IN_FLIGHT)
    t.eq(read(box, "calls"):find("/claim", 1, true), nil)
end)

t.test("take refuses at a column limit with room in its group", function()
    local box = sandbox({
        project = POMB,
        detail = detail({ [NAME.PROGRESS] = 1 }, GROUP .. '"limit":4,"count":3}]'),
        export = export(FLIGHT),
    })
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")
    t.eq(code, 1, out)
    t.eq(
        out,
        "dev: " .. NAME.PROGRESS .. " holds 1 card (aaaaaaaa), at its limit of 1. Land one first.\n"
    )
    t.eq(read(box, "calls"):find("/claim", 1, true), nil)
end)

t.test("a board with no limits is uncapped", function()
    local box = sandbox({ project = POMB, detail = detail({}), export = export(FLIGHT) })
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")
    t.eq(code, 0, out)
    t.ok(out:find("took dddddddd", 1, true), out)
    dev(box, { "board", "release", "dddddddd" }, "")
end)

t.test("an epic in the group is not counted", function()
    local box = sandbox({
        project = POMB,
        detail = detail({}, GROUP .. '"limit":3,"count":2}]'),
        export = export({
            { "a", ID.PROGRESS, TASK },
            { "b", ID.REVIEW, TASK },
            { "c", ID.VERIFY, EPIC },
            { "d", ID.READY, TASK },
        }),
    })
    local out, code = dev(box, { "board", "take", "dddddddd", "--as", NEW }, "")
    t.eq(code, 0, out)
    dev(box, { "board", "release", "dddddddd" }, "")
end)

t.test("move refuses a card entering a full group and names the cards", function()
    local box = sandbox({
        project = POMB,
        detail = detail({}, GROUP .. '"limit":3,"count":3}]'),
        export = export(FLIGHT),
    })
    local out, code = dev(box, { "board", "move", "dddddddd", COLUMN.REVIEW }, "")
    t.eq(code, 1, out)
    t.eq(out, IN_FLIGHT)
    t.eq(read(box, "calls"):find("/move", 1, true), nil)
end)

t.test("move refuses a card entering a full column", function()
    local box = sandbox({
        project = POMB,
        detail = detail({ [NAME.REVIEW] = 1 }, GROUP .. '"limit":4,"count":3}]'),
        export = export(FLIGHT),
    })
    local out, code = dev(box, { "board", "move", "dddddddd", COLUMN.REVIEW }, "")
    t.eq(code, 1, out)
    t.eq(
        out,
        "dev: " .. NAME.REVIEW .. " holds 1 card (bbbbbbbb), at its limit of 1. Land one first.\n"
    )
    t.eq(read(box, "calls"):find("/move", 1, true), nil)
end)

t.test("a move inside the group is not counted", function()
    local box = sandbox({
        project = POMB,
        detail = detail({}, GROUP .. '"limit":2,"count":3}]'),
        export = export(FLIGHT),
    })
    local out, code = dev(box, { "board", "move", "bbbbbbbb", COLUMN.VERIFY }, "")
    t.eq(code, 0, out)
    t.eq(out, "moved bbbbbbbb to Verify\n")
    t.ok(read(box, "calls"):find("/move", 1, true), read(box, "calls"))
end)

t.test("a 409 wip_limit_reached becomes the refusal and move releases the claim", function()
    local box = sandbox({ project = POMB, detail = detail({}), export = export(FLIGHT) })
    assert(fs.write(box.root .. "/move_refusal", LIMIT_BODY))
    local out, code = dev(box, { "board", "move", "dddddddd", COLUMN.PROGRESS }, NEW)
    t.eq(code, 1, out)
    t.eq(out, "dev: Pomb refused the move: " .. LIMIT_TEXT .. "\n")
    local calls = read(box, "calls")
    t.ok(calls:find("/api/tasks/" .. uuid("d") .. "/claim/release", 1, true), calls)
    t.eq(calls:find("force", 1, true), nil)
    t.eq(fs.exists(box.home .. "/state/dev/board/" .. uuid("d")), false)
end)

t.test("a local board is uncapped", function()
    local box = sandbox({
        project = '[board]\nbackend = "local"\nname = "mine"\n',
        detail = detail({}),
        export = export({}),
    })
    local out, code = dev(box, { "board", "init" }, "")
    t.eq(code, 0, out)
    for index = 1, 6 do
        out, code = dev(box, {
            "board",
            "add",
            "Card" .. index,
            "--column",
            COLUMN.READY,
            "--size",
            "1",
            "--description",
            V1,
            "--checks",
            "dev test",
        }, "")
        t.eq(code, 0, out)
        local id = assert(out:match("added (%x+)"), out)
        out, code = dev(box, { "board", "move", id, COLUMN.PROGRESS }, NEW .. "/" .. index)
        t.eq(code, 0, out)
    end
end)
