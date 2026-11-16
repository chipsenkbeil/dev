local testing = require("dev.testing")
local board = require("dev.board")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local init = require("dev.board.init")
local support = require("support")

local TOKEN = "pomb_SECRETtoken0123456789"
local DEVICE_CODE = "DEVCODE-secret-9876"
local ADMIN_TOKEN = "pomb_ADMINtoken0123456789"
local READY_COLUMN = support.column_id(support.COLUMN_NAME.READY)
local STANDARD = {
    support.COLUMN_NAME.ICEBOX,
    support.COLUMN_NAME.BACKLOG,
    support.COLUMN_NAME.READY,
    support.COLUMN_NAME.PROGRESS,
    support.COLUMN_NAME.REVIEW,
    support.COLUMN_NAME.VERIFY,
    support.COLUMN_NAME.RELEASE,
    support.COLUMN_NAME.BLOCKED,
    support.COLUMN_NAME.DONE,
}

local UNCHANGED = "agent roles unchanged\n"

local function turn_row(column)
    return support.pomb_export_task({
        id = "22222222-bbbb",
        name = board.TURN_NAME,
        column_id = support.column_id(column),
    })
end
local LANES_DIE = "dev: [board] lanes must be a list of lane names in .dev/config.toml"
local STANDARD_ROLES = { "planner", "implementer", "reviewer", "verifier", "release", "lead" }

local function copy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, inner in pairs(value) do
        out[key] = copy(inner)
    end
    return out
end

local function stock_palette()
    local colors = {}
    for index, value in ipairs({ "yellow", "green", "blue", "red", "orange", "white" }) do
        colors[index] = {
            id = value .. "-id",
            value = value,
            label = value:sub(1, 1):upper() .. value:sub(2),
            description = "",
            is_default = value == "yellow",
            enabled = true,
        }
    end
    return colors
end

local function template_columns()
    local columns = {}
    for index, name in ipairs({
        support.COLUMN_NAME.BACKLOG,
        support.COLUMN_NAME.READY,
        support.COLUMN_NAME.PROGRESS,
        "In Review",
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.DONE,
    }) do
        columns[index] = {
            id = support.column_id(name),
            name = name,
            is_done = name == support.COLUMN_NAME.DONE,
            is_blocked = name == support.COLUMN_NAME.BLOCKED,
        }
    end
    return columns
end

local function fake_layout(opts)
    opts = opts or {}
    local state = {
        exists = opts.exists ~= false,
        columns = opts.columns or {},
        colors = opts.colors or stock_palette(),
        cards = opts.cards or {},
        has_checks = opts.has_checks ~= false,
        roles = opts.roles == nil and {} or opts.roles,
        groups = opts.groups or {},
        writes = {},
    }
    local layout = { state = state }
    local function write(...)
        state.writes[#state.writes + 1] = { ... }
    end
    function layout:find()
        return state.exists
    end
    function layout:create()
        write("create")
        state.exists = true
        state.columns = template_columns()
        return true, "agent project"
    end
    function layout:read()
        local columns = copy(state.columns)
        for _, column in ipairs(columns) do
            if column.is_blocked == nil and not opts.without_blocked then
                column.is_blocked = false
            end
        end
        return copy({
            columns = columns,
            colors = state.colors,
            cards = state.cards,
            has_checks = state.has_checks,
            lanes = opts.lanes,
        })
    end
    function layout:add_roles()
        if state.roles == false then
            return false
        end
        local created = {}
        if #state.roles == 0 then
            state.roles = copy(STANDARD_ROLES)
            created = copy(STANDARD_ROLES)
        end
        return created
    end
    function layout:add_checks_field()
        write("add_checks_field")
        state.has_checks = true
        return true
    end
    function layout:add_column(name, is_done)
        write("add_column", name, is_done)
        state.columns[#state.columns + 1] =
            { id = "col-" .. name, name = name, is_done = is_done, is_blocked = false }
        return true
    end
    function layout:rename_column(id, name)
        write("rename_column", id, name)
        for _, column in ipairs(state.columns) do
            if column.id == id then
                column.name = name
            end
        end
        return true
    end
    function layout:move_column(id, position)
        write("move_column", id, position)
        for at, column in ipairs(state.columns) do
            if column.id == id then
                table.insert(state.columns, position + 1, table.remove(state.columns, at))
                break
            end
        end
        return true
    end
    function layout:mark_done(id)
        write("mark_done", id)
        for _, column in ipairs(state.columns) do
            if column.id == id then
                column.is_done = true
            end
        end
        return true
    end
    function layout:mark_blocked(id)
        write("mark_blocked", id)
        for _, column in ipairs(state.columns) do
            if column.id == id then
                column.is_blocked = true
            end
        end
        return true, nil, true
    end
    function layout:set_color(id, fields)
        write("set_color", id)
        for _, color in ipairs(state.colors) do
            if fields.is_default then
                color.is_default = color.id == id
            end
            if color.id == id and fields.enabled ~= nil then
                color.enabled = fields.enabled
            end
            if color.id == id then
                color.label = fields.label or color.label
                color.description = fields.description or color.description
            end
        end
        return true
    end
    function layout:limit_groups()
        return copy(state.groups)
    end
    function layout:add_limit_group(names, limit)
        write("add_limit_group", table.concat(names, ","), limit)
        state.groups[#state.groups + 1] = { column_names = names, limit = limit }
        return true
    end
    function layout:add(name, column, add_opts)
        for _, card in ipairs(state.cards) do
            if add_opts and add_opts.once and card.name == name then
                return card, nil, true
            end
        end
        write("add", name)
        local card = { id = "card-" .. #state.cards, name = name, column = column }
        state.cards[#state.cards + 1] = card
        return card
    end
    function layout:set_card(id, fields)
        write("set_card", id)
        for _, card in ipairs(state.cards) do
            if card.id == id then
                card.name = fields.name or card.name
                card.color_id = fields.color_id or card.color_id
            end
        end
        return true
    end
    return layout
end

local function names(columns)
    local out = {}
    for index, column in ipairs(columns) do
        out[index] = column.name
    end
    return out
end

local function run(layout)
    local lines = {}
    local changes, message = init.run(layout, "demo", function(line)
        if line ~= "agent roles unchanged" then
            lines[#lines + 1] = line
        end
    end)
    return changes, message, lines
end

local function color(layout, value)
    for _, candidate in ipairs(layout.state.colors) do
        if candidate.value == value then
            return candidate
        end
    end
end

testing.test("a fresh board has one landing turn card after init", function()
    -- Run init on a missing board and check the report names the turn card
    local layout = fake_layout({ exists = false })
    local _, message, lines = run(layout)
    testing.eq(message, nil)
    local said = 'created the "' .. board.TURN_NAME .. '" card'
    testing.ok(table.concat(lines, "\n"):find(said, 1, true))

    -- Count the turn cards in the layout and check where the first one sits
    local function count()
        local found = 0
        for _, card in ipairs(layout.state.cards) do
            found = found + (card.name == board.TURN_NAME and 1 or 0)
        end
        return found
    end
    testing.eq(count(), 1)
    testing.eq(layout.state.cards[1].column, support.COLUMN_NAME.ICEBOX)

    -- Run init again and expect still one turn card
    run(layout)
    testing.eq(count(), 1)
end)

testing.test("a missing board ends in the standard state", function()
    local layout = fake_layout({ exists = false })
    local changes, message, lines = run(layout)
    testing.eq(message, nil)
    testing.eq(names(layout.state.columns), STANDARD)
    testing.eq(layout.state.columns[9].is_done, true)
    testing.eq(color(layout, "yellow").label, "1 Pomodoro")
    testing.eq(color(layout, "green").label, "2 Pomodori")
    testing.eq(color(layout, "blue").label, "3 Pomodori")
    testing.eq(color(layout, "red").label, ">3 Pomodori")
    testing.eq(color(layout, "white").label, "Unsized")
    testing.eq(color(layout, "white").is_default, true)
    testing.eq(color(layout, "yellow").is_default, false)
    testing.eq(lines[1], "created board demo from the agent project template")
    testing.eq(changes, #lines)
end)

testing.test("a board without the checks field gains it once and keeps it", function()
    local layout = fake_layout({ has_checks = false, columns = template_columns() })
    local changes, message, lines = run(layout)
    testing.eq(message, nil)
    testing.ok(changes >= 1)
    local said = 0
    for _, line in ipairs(lines) do
        said = said + (line == "added the checks field dev.checks" and 1 or 0)
    end
    testing.eq(said, 1)
    local added = 0
    for _, write in ipairs(layout.state.writes) do
        added = added + (write[1] == "add_checks_field" and 1 or 0)
    end
    testing.eq(added, 1)
    run(layout)
    added = 0
    for _, write in ipairs(layout.state.writes) do
        added = added + (write[1] == "add_checks_field" and 1 or 0)
    end
    testing.eq(added, 1)
end)

testing.test("a second run changes nothing and says nothing", function()
    local layout = fake_layout({ exists = false })
    run(layout)
    local writes = #layout.state.writes
    local changes, message, lines = run(layout)
    testing.eq(message, nil)
    testing.eq(changes, 0)
    testing.eq(lines, {})
    testing.eq(#layout.state.writes, writes)
end)

testing.test("an old board keeps its cards and gains what is missing", function()
    local layout = fake_layout({
        columns = {
            { id = "col-Done", name = support.COLUMN_NAME.DONE, is_done = true },
            { id = "col-Ready", name = support.COLUMN.READY, is_done = false },
            { id = "col-Backlog", name = support.COLUMN_NAME.BACKLOG, is_done = false },
        },
    })
    local changes, message = run(layout)
    testing.eq(message, nil)
    testing.eq(names(layout.state.columns), {
        support.COLUMN_NAME.ICEBOX,
        support.COLUMN_NAME.BACKLOG,
        support.COLUMN.READY,
        support.COLUMN_NAME.PROGRESS,
        support.COLUMN_NAME.REVIEW,
        support.COLUMN_NAME.VERIFY,
        support.COLUMN_NAME.RELEASE,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.DONE,
    })
    testing.ok(changes > 0)
    local again = run(layout)
    testing.eq(again, 0)
end)

testing.test("an In Review column is renamed to Review with its id and cards kept", function()
    local layout = fake_layout({ columns = template_columns() })
    local _, message, lines = run(layout)
    testing.eq(message, nil)
    testing.eq(names(layout.state.columns), STANDARD)
    local review = layout.state.columns[5]
    testing.eq(review.id, "col-In Review")
    testing.eq(lines[1], "renamed column In Review to Review")
    local renames = 0
    for _, write in ipairs(layout.state.writes) do
        renames = renames + (write[1] == "rename_column" and 1 or 0)
    end
    testing.eq(renames, 1)
    local again, _, said = run(layout)
    testing.eq(again, 0)
    testing.eq(said, {})
end)

testing.test("a board with both In Review and Review renames nothing", function()
    local columns = template_columns()
    columns[#columns + 1] =
        { id = "col-Review", name = support.COLUMN_NAME.REVIEW, is_done = false }
    local layout = fake_layout({ columns = columns })
    run(layout)
    for _, write in ipairs(layout.state.writes) do
        testing.ok(write[1] ~= "rename_column")
    end
end)

testing.test("a column init does not recognise is reported and kept where it was named", function()
    local columns = template_columns()
    table.insert(columns, 3, { id = "col-odd", name = "Someday", is_done = false })
    local layout = fake_layout({ columns = columns })
    local _, message, lines = run(layout)
    testing.eq(message, nil)
    local kept = 0
    for _, line in ipairs(lines) do
        if line == 'kept column "Someday", which is not part of the standard board' then
            kept = kept + 1
        end
    end
    testing.eq(kept, 1)
    testing.eq(layout.state.columns[#layout.state.columns].name, "Someday")
    testing.eq(layout.state.columns[#layout.state.columns].id, "col-odd")
    for _, write in ipairs(layout.state.writes) do
        testing.ok(write[1] ~= "rename")
    end
    local _, _, second = run(layout)
    testing.eq(#second, 1)
    testing.ok(second[1]:find("kept column", 1, true))
    testing.eq(#layout.state.writes > 0, true)
end)

testing.test("a Done column that does not count as done is marked", function()
    local columns = template_columns()
    columns[6].is_done = false
    local layout = fake_layout({ columns = columns })
    local _, _, lines = run(layout)
    testing.eq(layout.state.columns[9].is_done, true)
    testing.ok(table.concat(lines, "\n"):find("marked Done", 1, true), lines[1])
end)

testing.test(
    "size words come off names and set the colour of a card still at the default",
    function()
        local layout = fake_layout({
            columns = template_columns(),
            cards = {
                { id = "aaaaaaaa-1", name = "Plain card", color_id = "yellow-id" },
                { id = "bbbbbbbb-1", name = "Make it (blue)", color_id = "yellow-id" },
                { id = "cccccccc-1", name = "Big thing (red, split)", color_id = nil },
                { id = "dddddddd-1", name = "Chosen (yellow)", color_id = "green-id" },
                { id = "eeeeeeee-1", name = "Small (green)", color_id = "white-id" },
                { id = "ffffffff-1", name = "(blue)", color_id = nil },
            },
        })
        local _, message, lines = run(layout)
        testing.eq(message, nil)
        local cards = layout.state.cards
        testing.eq(cards[1].name, "Plain card")
        testing.eq(cards[2].name, "Make it")
        testing.eq(cards[2].color_id, "blue-id")
        testing.eq(cards[3].name, "Big thing")
        testing.eq(cards[3].color_id, "red-id")
        testing.eq(cards[4].name, "Chosen")
        testing.eq(cards[4].color_id, "green-id")
        testing.eq(cards[5].name, "Small")
        testing.eq(cards[5].color_id, "green-id")
        testing.eq(cards[6].name, "(blue)")
        local joined = table.concat(lines, "\n")
        testing.ok(
            joined:find('renamed card bbbbbbbb to "Make it" and coloured it blue', 1, true),
            joined
        )
        testing.ok(
            joined:find('renamed card dddddddd to "Chosen"\n', 1, true)
                or joined:find('renamed card dddddddd to "Chosen"$'),
            joined
        )
        testing.ok(joined:find("kept card ffffffff", 1, true), joined)
        local again = run(layout)
        testing.eq(again, 0)
    end
)

testing.test("split_size takes the five trailing size words and nothing else", function()
    testing.eq({ init.split_size("A (yellow)") }, { "A", "yellow" })
    testing.eq({ init.split_size("A (green)") }, { "A", "green" })
    testing.eq({ init.split_size("A b (blue)") }, { "A b", "blue" })
    testing.eq({ init.split_size("A (red)") }, { "A", "red" })
    testing.eq({ init.split_size("A (red, split)") }, { "A", "red" })
    testing.eq({ init.split_size("A (red) (blue)") }, { "A", "blue" })
    testing.eq(init.split_size("A (blue) later"), nil)
    testing.eq(init.split_size("A (purple)"), nil)
    testing.eq(init.split_size("A blue"), nil)
end)

testing.test(
    "a refused change says to use --admin and stops with the changes so far said",
    function()
        local layout = fake_layout({ columns = template_columns() })
        function layout:set_color()
            return nil, "board unavailable: pomb answered 403: insufficient_scope"
        end
        local changes, message, lines = run(layout)
        testing.eq(changes, nil)
        testing.ok(message:find("run `dev board init --admin`", 1, true), message)
        testing.eq(lines[2], "added column Icebox")
    end
)

local PERMISSIONS = '[{"name":"cards.read","presets":["read","work","lead","admin"]},'
    .. '{"name":"boards.write","presets":["lead","admin"]},{"name":"templates.write","presets":["admin"]}]'
local BOARDS = '[{"id":"board-1","name":"demo","archived":false}]'
local DETAIL = '{"id":"board-1","name":"demo","swimlanes":[],"columns":['
local GROUPS = '"limit_groups":[{"id":"g1","column_ids":["col-InProgress","col-Review","col-Verify"],'
    .. '"limit":4,"limit_unit":"count","count":0}]'
local function detail()
    local parts = {}
    for _, name in ipairs(STANDARD) do
        parts[#parts + 1] = string.format(
            '{"id":"col-%s","name":"%s","wip_limit":null,"is_done":%s,"is_blocked":%s}',
            name:gsub(" ", ""),
            name,
            name == support.COLUMN_NAME.DONE and "true" or "false",
            name == support.COLUMN_NAME.BLOCKED and "true" or "false"
        )
    end
    return DETAIL .. table.concat(parts, ",") .. "]," .. GROUPS .. "}"
end

local function colors_json()
    local labels = {
        yellow = "1 Pomodoro",
        green = "2 Pomodori",
        blue = "3 Pomodori",
        red = ">3 Pomodori",
        white = "Unsized",
    }
    local descriptions = {}
    for _, swatch in ipairs(init.PALETTE) do
        descriptions[swatch.value] = swatch.description
    end
    local parts = {}
    for _, value in ipairs({ "yellow", "green", "blue", "red", "white" }) do
        parts[#parts + 1] = string.format(
            '{"id":"%s-id","value":"%s","label":"%s","description":"%s","is_default":%s,"enabled":true}',
            value,
            value,
            labels[value],
            descriptions[value],
            value == "white" and "true" or "false"
        )
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

local FIELDS =
    '[{"id":"f1","key":"dev.checks","label":"Checks","kind":"table","options":[],"columns":[],"required":true}]'

local EXPORT = '{"tasks":['
    .. support.pomb_export_task({
        id = "11111111-aaaa",
        name = "Keep",
        column_id = READY_COLUMN,
        color_id = "blue-id",
    })
    .. ","
    .. turn_row(support.COLUMN_NAME.ICEBOX)
    .. "]}"

local CURL = [[#!/bin/sh
printf 'curl %s\n' "$*" >>"$ROOT/calls"
env >>"$ROOT/env"
case " $* " in *" -K - "*) cat >"$ROOT/stdin" ;; esac
for a; do case "$a" in @*) cat "${a#@}" >>"$ROOT/bodies"; echo >>"$ROOT/bodies" ;; esac; done
for last; do :; done
status=200
case "$last" in
*/api/v1/auth/device) body='{"device_code":"]] .. DEVICE_CODE .. [[","user_code":"ABCD-EFGH","verification_url":"https://pomb.example/device","expires_in_seconds":600,"interval_seconds":1}' ;;
*/api/v1/auth/device/token)
    n=$(cat "$ROOT/polls" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" >"$ROOT/polls"
    line=$(sed -n "${n}p" "$ROOT/script")
    status=${line%%|*}
    body=${line#*|}
    ;;
*/api/v1/auth/whoami) body=$(cat "$ROOT/whoami.json") ;;
*/api/v1/auth/permissions) body=$(cat "$ROOT/permissions.json") ;;
*/api/templates) body=$(cat "$ROOT/templates.json") ;;
*/api/boards)
    case " $* " in
    *" -X POST "*)
        touch "$ROOT/created"
        body='{"id":"board-1"}'
        ;;
    *)
        body=$(cat "$ROOT/boards.json")
        if [ -f "$ROOT/created" ]; then
            body='[{"id":"board-1","name":"demo","archived":false}]'
        fi
        ;;
    esac
    ;;
*/api/boards/board-1) body=$(cat "$ROOT/detail.json") ;;
*/colors) body=$(cat "$ROOT/colors.json") ;;
*/api/tasks) body='{"id":"33333333-cccc"}' ;;
*/fields)
    case " $* " in
    *" -X POST "*) body='{"id":"field-1"}' ;;
    *) body=$(cat "$ROOT/fields.json") ;;
    esac
    ;;
*/export-data) body=$(cat "$ROOT/export.json") ;;
*/api/v1/agent-roles)
    body=$(cat "$ROOT/rolelist.json")
    if [ -f "$ROOT/rolelist.fail" ]; then
        line=$(cat "$ROOT/rolelist.fail")
        status=${line%%|*}
        body=${line#*|}
    fi
    ;;
*/api/v1/agent-roles/standard)
    line=$(cat "$ROOT/roles.json")
    status=${line%%|*}
    body=${line#*|}
    ;;
*) body='{"ok":true}' ;;
esac
printf '%s\n%s' "$body" "$status"
]]

local function executable(path, body)
    assert(fs.write(path, body))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function sandbox(opts)
    opts = opts or {}
    local files = {}
    if opts.project ~= false then
        files[".dev/config.toml"] = opts.project or '[board]\nbackend = "pomb"\nname = "demo"\n'
    end
    local root = support.sandbox(files, {})
    local home = support.tempdir()
    local tmp = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(
        fs.write(
            home .. "/.config/dev/config.toml",
            opts.user
                or '[board.pomb]\nurl = "https://pomb.example"\nlead_token = "pass:secrets/lead/token/pomb"\n'
        )
    )
    for name, body in pairs({
        ["boards.json"] = BOARDS,
        ["detail.json"] = detail(),
        ["colors.json"] = colors_json(),
        ["fields.json"] = opts.fields or FIELDS,
        ["roles.json"] = opts.roles or '200|{"created":[],"roles":[]}\n',
        ["rolelist.json"] = opts.rolelist or "{}",
        ["export.json"] = EXPORT,
        ["templates.json"] = '[{"id":"tpl-1","name":"agent project","built_in":false}]',
        ["whoami.json"] = '{"kind":"token","name":"x","scope":"admin"}',
        ["permissions.json"] = PERMISSIONS,
        ["script"] = opts.script
            or ("200|" .. '{"token":"' .. ADMIN_TOKEN .. '","name":"n","scopes":["admin"]}\n'),
    }) do
        assert(fs.write(root .. "/" .. name, body))
    end
    executable(root .. "/bin/curl", CURL)
    executable(root .. "/bin/sleep", "#!/bin/sh\nexec " .. dev_os.which("sleep") .. " 0.1\n")
    executable(
        root .. "/bin/pass",
        '#!/bin/sh\nprintf "pass %s\\n" "$*" >>"$ROOT/calls"\necho "' .. TOKEN .. '"\n'
    )
    return root, home, tmp
end

local function dev(root, home, tmp, args)
    return support.dev(root, args, {
        env = {
            HOME = home,
            ROOT = root,
            TMPDIR = tmp,
            XDG_STATE_HOME = home .. "/state",
            DEV_PASS_LOCK = tmp .. "/pass.lock",
        },
    })
end

local function read(root, name)
    return fs.read(root .. "/" .. name) or ""
end

local function calls_of(root)
    local joined = read(root, "calls"):gsub("\nretry%-after:%%header{retry%-after}", "")
    return (joined:gsub("\n%%", " %%"))
end

local function writes(root)
    local count = 0
    for line in calls_of(root):gmatch("[^\n]+") do
        if
            line:find("-X PATCH", 1, true)
            or (
                line:find("-X POST", 1, true)
                and not line:find("/auth/", 1, true)
                and not line:find("/agent-roles/standard", 1, true)
            )
        then
            count = count + 1
        end
    end
    return count
end

testing.test("init on a board already at the standard says so and writes nothing", function()
    local root, home, tmp = sandbox()
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0)
    testing.eq(out, UNCHANGED .. "Board demo already follows the standard. Nothing changed.\n")
    testing.eq(writes(root), 0)
    testing.ok(read(root, "calls"):find("pass show secrets/lead/token/pomb", 1, true))
    testing.eq(read(root, "stdin"), 'header = "Authorization: Bearer ' .. TOKEN .. '"\n')
end)

testing.test("init --admin pairs through pending, slow_down and success", function()
    local root, home, tmp = sandbox({
        script = '428|{"code":"authorization_pending","message":"wait"}\n'
            .. '429|{"code":"slow_down","message":"slower"}\n'
            .. '428|{"code":"authorization_pending","message":"wait"}\n'
            .. '200|{"token":"'
            .. ADMIN_TOKEN
            .. '","name":"n","scopes":["admin"]}\n',
    })
    local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
    testing.eq(code, 0)
    testing.eq(
        out,
        "approve the admin sign-in at https://pomb.example/device\n"
            .. "code: ABCD-EFGH\n"
            .. UNCHANGED
            .. "Board demo already follows the standard. Nothing changed.\n"
    )
    testing.eq(read(root, "polls"), "4\n")
    local calls = read(root, "calls")
    testing.ok(calls:find('"client_name":"dev-board-init@', 1, true), calls)
    testing.ok(calls:find('"scopes":["admin"]', 1, true), calls)
    testing.eq(calls:find("pass show", 1, true), nil)
    testing.eq(read(root, "stdin"), 'header = "Authorization: Bearer ' .. ADMIN_TOKEN .. '"\n')
end)

testing.test(
    "the device token never reaches argv, the environment, a file or the output",
    function()
        local root, home, tmp = sandbox()
        local out = dev(root, home, tmp, { "-vv", "board", "init", "--admin" })
        testing.eq(out:find(ADMIN_TOKEN, 1, true), nil)
        testing.eq(read(root, "calls"):find(ADMIN_TOKEN, 1, true), nil)
        testing.eq(read(root, "env"):find(ADMIN_TOKEN, 1, true), nil)
        testing.eq(read(root, "calls"):find(DEVICE_CODE, 1, true), nil)
        testing.eq(read(root, "env"):find(DEVICE_CODE, 1, true), nil)
        testing.ok(read(root, "bodies"):find(DEVICE_CODE, 1, true))
        testing.eq(read(root, "bodies"):find(ADMIN_TOKEN, 1, true), nil)
        testing.eq(fs.list(tmp), {})
        testing.eq(fs.list(home .. "/state") == nil or #fs.list(home .. "/state") == 0, true)
        local found = dev_os.capture({ "grep", "-rl", ADMIN_TOKEN, home, tmp })
        testing.eq(found, "")
    end
)

testing.test("a denied sign-in ends the run with no board call", function()
    local root, home, tmp = sandbox({
        script = '403|{"code":"access_denied","message":"no"}\n',
    })
    local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
    testing.eq(code, 1)
    testing.ok(out:find("dev: the sign-in was denied", 1, true), out)
    testing.eq(read(root, "calls"):find("/api/boards", 1, true), nil)
    testing.eq(fs.list(tmp), {})
end)

testing.test("an expired or unknown sign-in ends the run", function()
    for _, case in ipairs({
        { '410|{"code":"device_code_expired","message":"x"}\n', "not approved in time" },
        { '400|{"code":"invalid_grant","message":"x"}\n', "no longer knows" },
        { '409|{"code":"quota_exceeded","message":"x"}\n', "revoke one" },
        { '200|{"token":"bad\\"token","name":"n"}\n', "not plain text" },
    }) do
        local root, home, tmp = sandbox({ script = case[1] })
        local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
        testing.eq(code, 1)
        testing.ok(out:find(case[2], 1, true), out)
    end
end)

testing.test("a token the approver lowered is refused", function()
    local root, home, tmp = sandbox()
    assert(fs.write(root .. "/whoami.json", '{"kind":"token","name":"x","scope":"work"}'))
    local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
    testing.eq(code, 1)
    testing.ok(out:find("the approved token has the work scope, init needs admin", 1, true), out)
    testing.eq(writes(root), 0)
end)

testing.test("init without a lead token or --admin says what to set", function()
    local root, home, tmp = sandbox({ user = '[board.pomb]\nurl = "https://pomb.example"\n' })
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 1)
    testing.ok(out:find("lead_token is not set", 1, true), out)
end)

testing.test("a project with no [board] section needs --name and then gets one", function()
    local root, home, tmp = sandbox({ project = "" })
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 1)
    testing.ok(out:find("pass --name N", 1, true), out)
    testing.eq(read(root, ".dev/config.toml"), "")
    out, code = dev(root, home, tmp, { "board", "init", "--name", "demo" })
    testing.eq(code, 0)
    testing.eq(
        out,
        UNCHANGED
            .. "wrote [board] to .dev/config.toml\n"
            .. "Board demo already follows the standard. Nothing changed.\n"
    )
    testing.eq(read(root, ".dev/config.toml"), '[board]\nbackend = "pomb"\nname = "demo"\n')
    out, code = dev(root, home, tmp, { "board", "status" })
    testing.eq(out, "backend: pomb\nboard: demo\n")
end)

testing.test("a project with no .dev/config.toml takes --name and gets the file", function()
    local root, home, tmp = sandbox({ project = false })
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 1)
    testing.ok(out:find("pass --name N", 1, true), out)
    out, code = dev(root, home, tmp, { "board", "init", "--name", "demo" })
    testing.eq(code, 0)
    testing.eq(
        out,
        UNCHANGED
            .. "wrote [board] to .dev/config.toml\n"
            .. "Board demo already follows the standard. Nothing changed.\n"
    )
    testing.eq(read(root, ".dev/config.toml"), '[board]\nbackend = "pomb"\nname = "demo"\n')
end)

testing.test("a project with no .dev directory gets it and the file", function()
    local root, home, tmp = sandbox({ project = false })
    assert(fs.remove(root .. "/.dev", { recursive = true }))
    local out, code = dev(root, home, tmp, { "board", "init", "--name", "demo" })
    testing.eq(code, 0, out)
    testing.eq(
        out,
        UNCHANGED
            .. "wrote [board] to .dev/config.toml\n"
            .. "Board demo already follows the standard. Nothing changed.\n"
    )
    testing.ok(fs.is_dir(root .. "/.dev"))
    testing.eq(read(root, ".dev/config.toml"), '[board]\nbackend = "pomb"\nname = "demo"\n')
end)

testing.test("the section is appended after other config", function()
    local root, home, tmp = sandbox({ project = '[remote]\nrunner = "ci"' })
    dev(root, home, tmp, { "board", "init", "--name", "demo" })
    testing.eq(
        read(root, ".dev/config.toml"),
        '[remote]\nrunner = "ci"\n\n[board]\nbackend = "pomb"\nname = "demo"\n'
    )
end)

testing.test("--name that disagrees with the [board] name is a usage error", function()
    local root, home, tmp = sandbox()
    local out, code = dev(root, home, tmp, { "board", "init", "--name", "other" })
    testing.eq(code, 2)
    testing.ok(out:find("--name other is not the [board] name demo", 1, true), out)
    testing.eq(read(root, "calls"), "")
end)

testing.test("init refuses an unknown flag and a stray argument", function()
    local root, home, tmp = sandbox()
    local _, code = dev(root, home, tmp, { "board", "init", "--bogus" })
    testing.eq(code, 2)
    _, code = dev(root, home, tmp, { "board", "init", "extra" })
    testing.eq(code, 2)
end)

testing.test("init on Pomb posts a landing turn card only when no open one exists", function()
    local function posts(export)
        -- Run init against an export of cards
        local root, home, tmp = sandbox()
        assert(fs.write(root .. "/export.json", export))
        local out, code = dev(root, home, tmp, { "board", "init" })
        assert(code == 0, out)

        -- Count the posts that make a task
        local found = 0
        for line in calls_of(root):gmatch("[^\n]+") do
            if line:find("-X POST", 1, true) and line:find("pomb.example/api/tasks", 1, true) then
                found = found + 1
            end
        end
        return found
    end
    local open = turn_row(support.COLUMN_NAME.ICEBOX)
    local done = turn_row(support.COLUMN_NAME.DONE)
    testing.eq(posts('{"tasks":[' .. open .. "]}"), 0)
    testing.eq(posts('{"tasks":[]}'), 1)
    testing.eq(posts('{"tasks":[' .. done .. "]}"), 1)
end)

testing.test("init defines the checks field once with the dev definition", function()
    local root, home, tmp = sandbox({ fields = "[]" })
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(out, UNCHANGED .. "added the checks field dev.checks\nboard demo: 1 change\n")
    local body = '{"columns":[{"key":"run","kind":"text","label":"Run","options":[],"required":true},'
        .. '{"key":"on","kind":"multiselect","label":"On","options":["local"],"required":false}],'
        .. '"key":"dev.checks","kind":"table","label":"Checks","required":true}'
    testing.ok(
        calls_of(root):find(
            "--data-raw " .. body .. " https://pomb.example/api/boards/board-1/fields",
            1,
            true
        ),
        calls_of(root)
    )
    testing.eq(writes(root), 1)
    root, home, tmp = sandbox()
    out = dev(root, home, tmp, { "board", "init" })
    testing.eq(out, UNCHANGED .. "Board demo already follows the standard. Nothing changed.\n")
    testing.eq(writes(root), 0)
end)

testing.test("init sends the changes an old board needs as the API's own calls", function()
    local root, home, tmp = sandbox()
    local last = DETAIL
    local ordered = {
        support.COLUMN_NAME.BACKLOG,
        support.COLUMN_NAME.READY,
        support.COLUMN_NAME.PROGRESS,
        support.COLUMN_NAME.REVIEW,
        support.COLUMN_NAME.VERIFY,
        support.COLUMN_NAME.RELEASE,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.DONE,
        support.COLUMN_NAME.ICEBOX,
    }
    local parts = {}
    for _, name in ipairs(ordered) do
        parts[#parts + 1] = string.format(
            '{"id":"col-%s","name":"%s","wip_limit":null,"is_done":%s,"is_blocked":%s}',
            name:gsub(" ", ""),
            name,
            name == support.COLUMN_NAME.DONE and "true" or "false",
            name == support.COLUMN_NAME.BLOCKED and "true" or "false"
        )
    end
    assert(fs.write(root .. "/detail.json", last .. table.concat(parts, ",") .. "]}"))
    local stock = {}
    for _, value in ipairs({ "yellow", "green", "blue", "red", "white" }) do
        stock[#stock + 1] = string.format(
            '{"id":"%s-id","value":"%s","label":"%s","description":"","is_default":%s}',
            value,
            value,
            value:sub(1, 1):upper() .. value:sub(2),
            value == "yellow" and "true" or "false"
        )
    end
    assert(fs.write(root .. "/colors.json", "[" .. table.concat(stock, ",") .. "]"))
    assert(fs.write(root .. "/export.json", '{"tasks":[' .. support.pomb_export_task({
        id = "11111111-aaaa",
        name = "Keep it (blue)",
        column_id = READY_COLUMN,
        color_id = "yellow-id",
    }) .. "," .. turn_row(support.COLUMN_NAME.ICEBOX) .. "]}"))
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0)
    local calls = calls_of(root)
    testing.ok(calls:find("-X POST", 1, true), calls)
    testing.ok(
        calls:find(
            '--data-raw {"position":0} https://pomb.example/api/columns/col-Icebox/move',
            1,
            true
        ),
        calls
    )
    testing.ok(calls:find("-X PATCH", 1, true), calls)
    testing.ok(
        calls:find(
            '--data-raw {"description":"One pomodoro or less","label":"1 Pomodoro"} https://pomb.example/api/boards/board-1/colors/yellow-id',
            1,
            true
        ),
        calls
    )
    testing.ok(
        calls:find(
            '--data-raw {"is_default":true} https://pomb.example/api/boards/board-1/colors/white-id',
            1,
            true
        ),
        calls
    )
    testing.ok(
        calls:find(
            '--data-raw {"color_id":"blue-id","name":"Keep it"} https://pomb.example/api/tasks/11111111-aaaa',
            1,
            true
        ),
        calls
    )
    testing.ok(out:find("moved column Icebox to position 0\n", 1, true), out)
    testing.ok(out:find('named yellow "1 Pomodoro"\n', 1, true), out)
    testing.ok(out:find("made white the default colour\n", 1, true), out)
    testing.ok(out:find('renamed card 11111111 to "Keep it" and coloured it blue\n', 1, true), out)
    testing.eq(out:find(TOKEN, 1, true), nil)
end)

testing.test("init renames In Review to Review through the column update", function()
    local root, home, tmp = sandbox()
    local parts = {}
    for _, name in ipairs({
        support.COLUMN_NAME.ICEBOX,
        support.COLUMN_NAME.BACKLOG,
        support.COLUMN_NAME.READY,
        support.COLUMN_NAME.PROGRESS,
        "In Review",
        support.COLUMN_NAME.VERIFY,
        support.COLUMN_NAME.RELEASE,
        support.COLUMN_NAME.BLOCKED,
        support.COLUMN_NAME.DONE,
    }) do
        parts[#parts + 1] = string.format(
            '{"id":"col-%s","name":"%s","wip_limit":null,"is_done":%s,"is_blocked":%s}',
            name:gsub(" ", ""),
            name,
            name == support.COLUMN_NAME.DONE and "true" or "false",
            name == support.COLUMN_NAME.BLOCKED and "true" or "false"
        )
    end
    local body = DETAIL .. table.concat(parts, ",") .. "]," .. GROUPS .. "}"
    assert(fs.write(root .. "/detail.json", body))
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.ok(
        calls_of(root):find(
            '--data-raw {"name":"Review"} https://pomb.example/api/columns/col-InReview',
            1,
            true
        ),
        calls_of(root)
    )
    testing.ok(out:find("renamed column In Review to Review\n", 1, true), out)
end)

testing.test("init makes a missing board from the agent project template", function()
    local root, home, tmp = sandbox()
    assert(fs.write(root .. "/boards.json", "[]"))
    local out, code = dev(root, home, tmp, { "board", "init" })
    assert(code == 0, out)
    local calls = calls_of(root)
    testing.ok(
        calls:find(
            '--data-raw {"name":"demo","template_id":"tpl-1"} https://pomb.example/api/boards',
            1,
            true
        ),
        calls
    )
    testing.ok(out:find("created board demo from the agent project template\n", 1, true), out)
end)

testing.test("init adds a column with the done flag where it belongs", function()
    local root, home, tmp = sandbox()
    assert(
        fs.write(
            root .. "/detail.json",
            '{"id":"board-1","name":"demo","swimlanes":[],"columns":[{"id":"col-Backlog","name":"Backlog","is_done":false}]}'
        )
    )
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 1)
    local calls = calls_of(root)
    testing.ok(
        calls:find(
            '--data-raw {"board_id":"board-1","is_done":true,"name":"Done"} https://pomb.example/api/columns',
            1,
            true
        ),
        calls
    )
    testing.ok(calls:find('"is_done":false,"name":"Icebox"', 1, true), calls)
    testing.ok(out:find("added column Icebox\n", 1, true), out)
    testing.ok(out:find("still has no Icebox column", 1, true), out)
end)

testing.test("board names the columns init lays out", function()
    testing.eq(board.roles().list, STANDARD)
end)

testing.test("a run that stops while stripping can be repeated without losing a size", function()
    local layout = fake_layout({
        columns = template_columns(),
        cards = { { id = "aaaaaaaa-1", name = "Thing (red)", color_id = "yellow-id" } },
    })
    local set_card = layout.set_card
    function layout:set_card()
        return nil, "board unavailable: pomb answered 503: down"
    end
    local changes = run(layout)
    testing.eq(changes, nil)
    layout.set_card = set_card
    run(layout)
    testing.eq(layout.state.cards[1].name, "Thing")
    testing.eq(layout.state.cards[1].color_id, "red-id")
end)

testing.test("colours outside the size palette are disabled and the five are enabled", function()
    local colors = stock_palette()
    for _, value in ipairs({ "purple", "brown" }) do
        colors[#colors + 1] = {
            id = value .. "-id",
            value = value,
            label = value,
            description = "",
            is_default = false,
            enabled = true,
        }
    end
    color({ state = { colors = colors } }, "white").enabled = false
    local layout = fake_layout({ columns = template_columns(), colors = colors })
    local _, message, lines = run(layout)
    testing.eq(message, nil)
    local joined = table.concat(lines, "\n")
    for _, line in ipairs({
        "enabled white",
        "disabled orange",
        "disabled purple",
        "disabled brown",
    }) do
        testing.ok(joined:find(line .. "\n", 1, true) or joined:find(line .. "$"), joined)
    end
    for _, value in ipairs({ "yellow", "green", "blue", "red", "white" }) do
        testing.eq(color(layout, value).enabled, true)
    end
    for _, value in ipairs({ "orange", "purple", "brown" }) do
        testing.eq(color(layout, value).enabled, false)
    end
    local again, _, second = run(layout)
    testing.eq(again, 0)
    testing.eq(second, {})
end)

testing.test("a card wearing a disabled colour is reported on every run and left alone", function()
    local layout = fake_layout({
        columns = template_columns(),
        cards = { { id = "aaaaaaaa-1", name = "Odd", color_id = "orange-id" } },
    })
    local _, _, lines = run(layout)
    local report = "card aaaaaaaa wears the disabled colour orange, left as it is"
    testing.eq(lines[#lines], report)
    testing.eq(layout.state.cards[1].color_id, "orange-id")
    local changes, _, second = run(layout)
    testing.eq(changes, 0)
    testing.eq(second, { report })
end)

testing.test("a token that may not enable colours leaves them and carries on", function()
    local layout = fake_layout({ columns = template_columns() })
    local set_color = layout.set_color
    function layout:set_color(id, fields)
        if fields.enabled ~= nil then
            return nil, "board unavailable: pomb answered 403: insufficient_scope"
        end
        return set_color(self, id, fields)
    end
    local changes, message, lines = run(layout)
    testing.eq(message, nil)
    testing.ok(changes > 0)
    local left = 0
    for _, line in ipairs(lines) do
        if line:find("Run `dev board init --admin`", 1, true) then
            left = left + 1
        end
    end
    testing.eq(left, 1)
    testing.eq(color(layout, "orange").enabled, true)
    testing.eq(color(layout, "white").is_default, true)
end)

testing.test("init sends enabled through the palette PATCH for each colour", function()
    local root, home, tmp = sandbox()
    local orange = ',{"id":"orange-id","value":"orange","label":"Orange",'
        .. '"description":"","is_default":false,"enabled":true}]'
    assert(fs.write(root .. "/colors.json", colors_json():gsub("%]$", "") .. orange))
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0)
    local patch = '--data-raw {"enabled":false} '
        .. "https://pomb.example/api/boards/board-1/colors/orange-id"
    testing.ok(calls_of(root):find(patch, 1, true), calls_of(root))
    testing.eq(out, UNCHANGED .. "disabled orange\nboard demo: 1 change\n")
end)

testing.test("agent-roles-create: a first init posts the board id and prints names", function()
    local root, home, tmp = sandbox({
        roles = '200|{"created":["planner","implementer","reviewer","verifier","release","lead"],'
            .. '"roles":[]}\n',
    })
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(
        out,
        "created agent roles planner, implementer, reviewer, verifier, release, lead\n"
            .. "board demo: 1 change\n"
    )
    testing.ok(
        calls_of(root):find(
            '--data-raw {"boards":["board-1"]} https://pomb.example/api/v1/agent-roles/standard',
            1,
            true
        ),
        calls_of(root)
    )
end)

testing.test("agent-roles-unchanged: a rerun prints unchanged and counts no change", function()
    local root, home, tmp = sandbox()
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(out, UNCHANGED .. "Board demo already follows the standard. Nothing changed.\n")
    testing.ok(calls_of(root):find("/api/v1/agent-roles/standard", 1, true), calls_of(root))
end)

testing.test("agent-roles-create: the step runs once through a layout", function()
    local layout = fake_layout({ columns = template_columns() })
    local lines = {}
    local changes = init.run(layout, "demo", function(line)
        lines[#lines + 1] = line
    end)
    testing.ok(changes >= 1)
    testing.ok(table.concat(lines, "\n"):find("created agent roles planner, implementer", 1, true))
    lines = {}
    testing.eq(
        init.run(layout, "demo", function(line)
            lines[#lines + 1] = line
        end),
        0
    )
    testing.eq(lines, { "agent roles unchanged" })
end)

testing.test("a board with no roles says nothing about them", function()
    local layout = fake_layout({ columns = template_columns(), roles = false })
    local lines = {}
    init.run(layout, "demo", function(line)
        lines[#lines + 1] = line
    end)
    for _, line in ipairs(lines) do
        testing.eq(line:find("agent roles", 1, true), nil, line)
    end
end)

testing.test("agent-roles-exceeds-grant: a board the init token does not hold is named", function()
    local root, home, tmp = sandbox({
        roles = '403|{"code":"exceeds_grant","message":"the calling token does not hold board board-1"}\n',
    })
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 1)
    testing.ok(out:find("the token does not hold board demo (board-1)", 1, true), out)
    testing.ok(out:find("add the board to the token", 1, true), out)
    testing.eq(out:find("--admin", 1, true), nil)
end)

testing.test("agent-roles-denied: a permission_denied names the missing permission", function()
    local root, home, tmp = sandbox({
        roles = '403|{"code":"permission_denied","message":"no","permission":"settings.write",'
            .. '"board_id":null}\n',
    })
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 1)
    testing.ok(out:find("lacks the settings.write permission", 1, true), out)
end)

testing.test(
    "init --admin accepts a token with the admin preset's permissions on every board",
    function()
        local root, home, tmp = sandbox()
        assert(
            fs.write(
                root .. "/whoami.json",
                '{"permissions":["cards.read","boards.write","templates.write"],"boards":"all"}'
            )
        )
        local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
        testing.eq(code, 0)
        testing.ok(out:find("already follows the standard", 1, true), out)
    end
)

testing.test("init --admin refuses a token missing an admin permission or some boards", function()
    for _, case in ipairs({
        {
            '{"permissions":["cards.read","boards.write"],"boards":"all"}',
            "lacks the templates.write permission, init needs the admin preset",
        },
        {
            '{"permissions":["cards.read","boards.write","templates.write"],'
                .. '"boards":[{"id":"b","name":"n"}]}',
            "assigned only some boards, init needs all of them",
        },
    }) do
        local root, home, tmp = sandbox()
        assert(fs.write(root .. "/whoami.json", case[1]))
        local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
        testing.eq(code, 1)
        testing.ok(out:find(case[2], 1, true), out)
        testing.eq(writes(root), 0)
    end
end)

testing.test("init --admin refuses a catalog that lists no admin preset", function()
    local root, home, tmp = sandbox()
    assert(fs.write(root .. "/whoami.json", '{"permissions":[],"boards":"all"}'))
    assert(fs.write(root .. "/permissions.json", "[]"))
    local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
    testing.eq(code, 1)
    testing.ok(out:find("lists no admin preset", 1, true), out)
    testing.eq(writes(root), 0)
end)

testing.test(
    "init on a permission_denied with no board suggests --admin, with a board does not",
    function()
        local layout = fake_layout({ columns = template_columns() })
        function layout:set_color()
            return nil,
                "board unavailable: pomb answered 403: this token lacks the boards.write permission "
                    .. "on every board; use a token that has it"
        end
        local _, message = run(layout)
        testing.ok(message:find("run `dev board init --admin`", 1, true), message)
        function layout:set_color()
            return nil,
                "board unavailable: this token has the boards.write permission but is not assigned "
                    .. "to board b; add the board to the token"
        end
        _, message = run(layout)
        testing.eq(message:find("--admin", 1, true), nil)
    end
)

testing.test("init marks blocked on a new board", function()
    local layout = fake_layout({ exists = false })
    local create = layout.create
    function layout:create()
        local made, template = create(self)
        for _, column in ipairs(self.state.columns) do
            column.is_blocked = false
        end
        return made, template
    end
    local changes, message, lines = run(layout)
    testing.eq(message, nil)
    testing.eq(layout.state.columns[8].is_blocked, true)
    testing.ok(
        table
            .concat(lines, "\n")
            :find("marked Blocked as the column of cards waiting on an answer", 1, true)
    )
    testing.ok(changes > 0)
end)

testing.test("init blocked rerun says nothing", function()
    local columns = template_columns()
    for _, column in ipairs(columns) do
        column.is_blocked = false
    end
    local layout = fake_layout({ columns = columns })
    local first = run(layout)
    testing.eq(layout.state.columns[8].is_blocked, true)
    local again, message, said = run(layout)
    testing.eq(message, nil)
    testing.eq(again, 0)
    testing.eq(said, {})
    testing.ok(first > 0)
    local marks = 0
    for _, write in ipairs(layout.state.writes) do
        marks = marks + (write[1] == "mark_blocked" and 1 or 0)
    end
    testing.eq(marks, 1)
end)

testing.test("init refuses when pomb lacks is blocked", function()
    local columns = template_columns()
    for _, column in ipairs(columns) do
        column.is_blocked = nil
    end
    local layout = fake_layout({ columns = columns, without_blocked = true })
    local changes, message = run(layout)
    testing.eq(changes, nil)
    testing.ok(message:find("cannot mark a Blocked column", 1, true), message)
    testing.ok(message:find("dev board ask", 1, true), message)
    for _, write in ipairs(layout.state.writes) do
        testing.ok(write[1] ~= "mark_blocked")
    end
end)

testing.test("init sends is blocked through the column update", function()
    local root, home, tmp = sandbox()
    local unmarked = detail():gsub(
        '("name":"Blocked","wip_limit":null,"is_done":false,"is_blocked":)true',
        "%1false"
    )
    assert(fs.write(root .. "/detail.json", unmarked))
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.ok(
        calls_of(root):find(
            '%-X PATCH[^\n]*%-%-data%-raw {"is_blocked":true} https://pomb%.example/api/columns/col%-Blocked'
        ),
        calls_of(root)
    )
    testing.ok(
        out:find("marked Blocked as the column of cards waiting on an answer\n", 1, true),
        out
    )
end)

testing.test("init stops before any write when the column views carry no is blocked", function()
    local root, home, tmp = sandbox()
    local bare = detail():gsub(',"is_blocked":%a+', "")
    assert(fs.write(root .. "/detail.json", bare))
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 1)
    testing.ok(out:find("cannot mark a Blocked column yet", 1, true), out)
    testing.eq(writes(root), 0)
end)

local function limit_posts(root)
    local count = 0
    for line in calls_of(root):gmatch("[^\n]+") do
        count = count
            + (line:find("/limit-groups", 1, true) and line:find("-X POST", 1, true) and 1 or 0)
    end
    return count
end

testing.test("init creates the limit group of 4 on a board that has none", function()
    local root, home, tmp = sandbox()
    assert(fs.write(root .. "/detail.json", (detail():gsub(',"limit_groups":%b[]', ""))))
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(limit_posts(root), 1)
    testing.ok(
        calls_of(root):find(
            '--data-raw {"column_ids":["col-InProgress","col-Review","col-Verify"],"limit":4} https://pomb.example/api/boards/board-1/limit-groups',
            1,
            true
        ),
        calls_of(root)
    )
    testing.ok(out:find("created limit group In Progress, Review and Verify at 4\n", 1, true), out)
    testing.ok(out:find("board demo: 1 change\n", 1, true), out)
end)

local function granted_roles(skip)
    local rows = {}
    for index, key in ipairs({ "planner", "implementer", "reviewer", "verifier", "release", "lead" }) do
        if key ~= skip then
            rows[#rows + 1] = '{"id":"role-'
                .. index
                .. '","name":"'
                .. key
                .. '","standard":"'
                .. key
                .. '","boards":["board-1"]}'
        end
    end
    return "[" .. table.concat(rows, ",") .. "]"
end

local function roles_posts(root)
    return calls_of(root):find("/api/v1/agent-roles/standard", 1, true)
end

testing.test(
    "agent-roles-granted-sends-no-post: every standard role on the board skips it",
    function()
        local root, home, tmp = sandbox({ rolelist = granted_roles() })
        local out, code = dev(root, home, tmp, { "board", "init" })
        testing.eq(code, 0, out)
        testing.eq(roles_posts(root), nil, calls_of(root))
        testing.eq(out, UNCHANGED .. "Board demo already follows the standard. Nothing changed.\n")
    end
)

testing.test("agent-roles-missing-still-posts: one role off the board sends the post", function()
    local root, home, tmp = sandbox({ rolelist = granted_roles("verifier") })
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.ok(roles_posts(root), calls_of(root))
end)

testing.test("agent-roles-granted-reaches-limits: a refused post is never sent", function()
    local root, home, tmp = sandbox({
        rolelist = granted_roles(),
        roles = '403|{"code":"permission_denied","message":"no","permission":"roles.grant",'
            .. '"board_id":null}\n',
    })
    assert(fs.write(root .. "/detail.json", (detail():gsub(',"limit_groups":%b[]', ""))))
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(roles_posts(root), nil, calls_of(root))
    testing.eq(limit_posts(root), 1)
end)

testing.test("init leaves a board that has a limit group alone and says nothing", function()
    local root, home, tmp = sandbox()
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(limit_posts(root), 0)
    testing.eq(out:find("limit group", 1, true), nil)
end)

testing.test("init leaves a board with any other limit group alone", function()
    local root, home, tmp = sandbox()
    local other = detail():gsub('"column_ids":%b[]', '"column_ids":["col-Ready","col-InProgress"]')
    assert(fs.write(root .. "/detail.json", other))
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(limit_posts(root), 0)
end)

testing.test("init says to use --admin when Pomb refuses the limit group", function()
    local layout = fake_layout({ columns = template_columns() })
    function layout:limit_groups()
        return {}
    end
    function layout:add_limit_group()
        return nil, "board unavailable: pomb answered 403: insufficient_scope"
    end
    local changes, message = run(layout)
    testing.eq(changes, nil)
    testing.ok(message:find("run `dev board init --admin`", 1, true), message)
end)

testing.test("a layout with no limits gets no limit group", function()
    local layout = fake_layout({ columns = template_columns() })
    function layout:limit_groups()
        return false
    end
    function layout:add_limit_group()
        error("must not be called")
    end
    local changes, message = run(layout)
    testing.eq(message, nil)
    testing.ok(changes > 0)
end)

testing.test("a missing board gets one limit group once", function()
    local layout = fake_layout({ exists = false })
    local _, _, lines = run(layout)
    local said = 0
    for _, line in ipairs(lines) do
        said = said + (line == "created limit group In Progress, Review and Verify at 4" and 1 or 0)
    end
    testing.eq(said, 1)
    testing.eq(layout.state.groups[1].limit, 4)
    testing.eq(
        layout.state.groups[1].column_names,
        { support.COLUMN_NAME.PROGRESS, support.COLUMN_NAME.REVIEW, support.COLUMN_NAME.VERIFY }
    )
    local changes
    changes, _, lines = run(layout)
    testing.eq(changes, 0)
    testing.eq(#lines, 0)
end)

local LANES_PROJECT =
    '[board]\nbackend = "pomb"\nname = "demo"\nlanes = ["Parity", "Fixes", "Features"]\n'
local NO_ROLES_GRANT = '403|{"code":"permission_denied","message":"no",'
    .. '"permission":"roles.grant","board_id":null}\n'

local function with_lanes(root, json)
    local text = detail():gsub('"swimlanes":%[%]', '"swimlanes":' .. json, 1)
    assert(fs.write(root .. "/detail.json", text))
end

testing.test("init creates the lanes the board config lists", function()
    local root, home, tmp = sandbox({ project = LANES_PROJECT })
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(
        out,
        UNCHANGED
            .. 'created lane "Parity"\ncreated lane "Fixes"\ncreated lane "Features"\n'
            .. "board demo: 3 changes\n"
    )
    local calls = calls_of(root)
    local at = 1
    for _, lane in ipairs({ "Parity", "Fixes", "Features" }) do
        local body = '{"board_id":"board-1","name":"' .. lane .. '"}'
        local sent = "--data-raw " .. body .. " https://pomb.example/api/swimlanes"
        local from = calls:find(sent, at, true)
        testing.ok(from, calls)
        at = from + 1
    end
    testing.eq(writes(root), 3)
    testing.eq(read(root, "stdin"), 'header = "Authorization: Bearer ' .. TOKEN .. '"\n')
end)

testing.test("init leaves the lanes that exist alone", function()
    local root, home, tmp = sandbox({ project = LANES_PROJECT })
    with_lanes(root, '[{"id":"l1","name":"parity"},{"id":"l2","name":"Fixes"}]')
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(out, UNCHANGED .. 'created lane "Features"\nboard demo: 1 change\n')
    testing.eq(writes(root), 1)
    root, home, tmp = sandbox({ project = LANES_PROJECT })
    with_lanes(
        root,
        '[{"id":"l1","name":"Parity"},{"id":"l2","name":"Fixes"},{"id":"l3","name":"Features"}]'
    )
    out = dev(root, home, tmp, { "board", "init" })
    testing.eq(out, UNCHANGED .. "Board demo already follows the standard. Nothing changed.\n")
    testing.eq(writes(root), 0)
end)

testing.test("init warns when the first lane is not in the lanes list", function()
    -- Expect the warning after the new lanes on a Pomb board with an unlisted first lane
    local root, home, tmp = sandbox({ project = LANES_PROJECT })
    with_lanes(root, '[{"id":"l1","name":"Default"}]')
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(out, UNCHANGED .. table.concat({
        'created lane "Parity"',
        'created lane "Fixes"',
        'created lane "Features"',
        'The first lane "Default" is not in the [board] lanes list. '
            .. "Cards filed without --lane land in it. "
            .. "Delete or reorder it in the Pomb UI.",
        "board demo: 3 changes",
    }, "\n") .. "\n")

    -- Expect no warning from a local board, even with an unlisted first lane
    local lines = {}
    local layout = fake_layout({ columns = template_columns(), lanes = { "Default", "Parity" } })
    init.run(layout, "demo", function(line)
        lines[#lines + 1] = line
    end, { lanes = { "Parity" }, warn_first_lane = false })
    for _, line in ipairs(lines) do
        testing.eq(line:find("first lane", 1, true), nil, line)
    end

    -- Expect no warning without a lanes list, even with an unlisted first lane
    local plain_root, plain_home, plain_tmp = sandbox()
    with_lanes(plain_root, '[{"id":"l1","name":"Default"}]')
    local plain_out, plain_code = dev(plain_root, plain_home, plain_tmp, { "board", "init" })
    testing.eq(plain_code, 0, plain_out)
    testing.eq(
        plain_out,
        UNCHANGED .. "Board demo already follows the standard. Nothing changed.\n"
    )
end)

testing.test("init stays silent when the first lane is listed", function()
    local root, home, tmp = sandbox({ project = LANES_PROJECT })
    with_lanes(root, '[{"id":"l1","name":"parity"},{"id":"l2","name":"Extra"}]')
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.eq(out, UNCHANGED .. table.concat({
        'created lane "Fixes"',
        'created lane "Features"',
        "board demo: 2 changes",
    }, "\n") .. "\n")
end)

testing.test("a worker token is refused a lane", function()
    local root, home, tmp = sandbox({ project = LANES_PROJECT })
    local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
    testing.eq(code, 1, out)
    testing.ok(out:find("swimlanes.create", 1, true), out)
    testing.ok(out:find("lead token", 1, true), out)
    testing.eq(calls_of(root):find("/api/swimlanes", 1, true), nil)
    testing.eq(writes(root), 0)
end)

testing.test("init-lead-without-roles-grant-creates-lanes", function()
    local root, home, tmp = sandbox({ project = LANES_PROJECT, roles = NO_ROLES_GRANT })
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    local calls = calls_of(root)
    for _, lane in ipairs({ "Parity", "Fixes", "Features" }) do
        local body = '{"board_id":"board-1","name":"' .. lane .. '"}'
        local sent = "--data-raw " .. body .. " https://pomb.example/api/swimlanes"
        testing.ok(calls:find(sent, 1, true), calls)
    end
    testing.eq(
        out,
        "The agent roles are left for `dev board init --admin`.\n"
            .. 'created lane "Parity"\ncreated lane "Fixes"\ncreated lane "Features"\n'
            .. "board demo: 3 changes\n"
    )
end)

testing.test("init-lead-without-roles-grant-names-the-roles-step", function()
    local layout = fake_layout({ columns = template_columns() })
    function layout:add_roles()
        return nil,
            "board unavailable: pomb answered 403: this token lacks the roles.grant permission "
                .. "on every board; use a token that has it",
            "roles.grant"
    end
    local changes, message, lines = run(layout)
    testing.eq(message, nil)
    testing.ok(changes > 0)
    local said = 0
    for _, line in ipairs(lines) do
        said = said + (line == "The agent roles are left for `dev board init --admin`." and 1 or 0)
    end
    testing.eq(said, 1)
end)

testing.test("init-lead-roles-read-fails-names-the-failure", function()
    local root, home, tmp = sandbox({ project = LANES_PROJECT, roles = NO_ROLES_GRANT })
    assert(
        fs.write(
            root .. "/rolelist.fail",
            '403|{"code":"permission_denied","message":"no","permission":"settings.read",'
                .. '"board_id":null}\n'
        )
    )
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.ok(
        out:find("agent roles not checked, the roles list could not be read: ", 1, true),
        out
    )
    testing.ok(out:find("settings.read", 1, true), out)
    testing.eq(out:find("left for `dev board init --admin`", 1, true), nil, out)
    testing.eq(roles_posts(root) ~= nil, true, calls_of(root))
end)

testing.test("init-lead-roles-missing-after-a-read-still-names-the-admin-step", function()
    local root, home, tmp = sandbox({
        project = LANES_PROJECT,
        roles = NO_ROLES_GRANT,
        rolelist = granted_roles("verifier"),
    })
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 0, out)
    testing.ok(out:find("The agent roles are left for `dev board init --admin`.\n", 1, true), out)
    testing.eq(out:find("could not be read", 1, true), nil, out)
end)

testing.test("init refuses a lanes value that is not a list", function()
    local root, home, tmp = sandbox({
        project = '[board]\nbackend = "pomb"\nname = "demo"\nlanes = "Parity"\n',
    })
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 1, out)
    testing.ok(out:find(LANES_DIE, 1, true), out)
    testing.eq(writes(root), 0)
end)

testing.test("init refuses a lane name that is empty", function()
    local root, home, tmp = sandbox({
        project = '[board]\nbackend = "pomb"\nname = "demo"\nlanes = [""]\n',
    })
    local out, code = dev(root, home, tmp, { "board", "init" })
    testing.eq(code, 1, out)
    testing.ok(out:find(LANES_DIE, 1, true), out)
    testing.eq(writes(root), 0)
end)
