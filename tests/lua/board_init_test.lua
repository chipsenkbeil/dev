local t = require("testing")
local board = require("dev.board")
local devos = require("dev.os")
local fs = require("dev.fs")
local init = require("dev.board.init")
local support = require("support")

local TOKEN = "pomb_SECRETtoken0123456789"
local DEVICE_CODE = "DEVCODE-secret-9876"
local ADMIN_TOKEN = "pomb_ADMINtoken0123456789"
local STANDARD = {
    "Icebox",
    "Backlog",
    "Ready",
    "In Progress",
    "Review",
    "Verify",
    "Release",
    "Blocked",
    "Done",
}

local UNCHANGED = "agent roles unchanged\n"
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
    for index, name in ipairs({ "Backlog", "Ready", "In Progress", "In Review", "Blocked", "Done" }) do
        columns[index] = { id = "col-" .. name, name = name, is_done = name == "Done" }
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
        return copy({
            columns = state.columns,
            colors = state.colors,
            cards = state.cards,
            has_checks = state.has_checks,
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
        state.columns[#state.columns + 1] = { id = "col-" .. name, name = name, is_done = is_done }
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

t.test("a missing board ends in the standard state", function()
    local layout = fake_layout({ exists = false })
    local changes, message, lines = run(layout)
    t.eq(message, nil)
    t.eq(names(layout.state.columns), STANDARD)
    t.eq(layout.state.columns[9].is_done, true)
    t.eq(color(layout, "yellow").label, "1 Pomodoro")
    t.eq(color(layout, "green").label, "2 Pomodori")
    t.eq(color(layout, "blue").label, "3 Pomodori")
    t.eq(color(layout, "red").label, ">3 Pomodori")
    t.eq(color(layout, "white").label, "Unsized")
    t.eq(color(layout, "white").is_default, true)
    t.eq(color(layout, "yellow").is_default, false)
    t.eq(lines[1], "created board demo from the agent project template")
    t.eq(changes, #lines)
end)

t.test("a board without the checks field gains it once and keeps it", function()
    local layout = fake_layout({ has_checks = false, columns = template_columns() })
    local changes, message, lines = run(layout)
    t.eq(message, nil)
    t.ok(changes >= 1)
    local said = 0
    for _, line in ipairs(lines) do
        said = said + (line == "added the checks field dev.checks" and 1 or 0)
    end
    t.eq(said, 1)
    local added = 0
    for _, write in ipairs(layout.state.writes) do
        added = added + (write[1] == "add_checks_field" and 1 or 0)
    end
    t.eq(added, 1)
    run(layout)
    added = 0
    for _, write in ipairs(layout.state.writes) do
        added = added + (write[1] == "add_checks_field" and 1 or 0)
    end
    t.eq(added, 1)
end)

t.test("a second run changes nothing and says nothing", function()
    local layout = fake_layout({ exists = false })
    run(layout)
    local writes = #layout.state.writes
    local changes, message, lines = run(layout)
    t.eq(message, nil)
    t.eq(changes, 0)
    t.eq(lines, {})
    t.eq(#layout.state.writes, writes)
end)

t.test("an old board keeps its cards and gains what is missing", function()
    local layout = fake_layout({
        columns = {
            { id = "col-Done", name = "Done", is_done = true },
            { id = "col-Ready", name = "ready", is_done = false },
            { id = "col-Backlog", name = "Backlog", is_done = false },
        },
    })
    local changes, message = run(layout)
    t.eq(message, nil)
    t.eq(names(layout.state.columns), {
        "Icebox",
        "Backlog",
        "ready",
        "In Progress",
        "Review",
        "Verify",
        "Release",
        "Blocked",
        "Done",
    })
    t.ok(changes > 0)
    local again = run(layout)
    t.eq(again, 0)
end)

t.test("an In Review column is renamed to Review with its id and cards kept", function()
    local layout = fake_layout({ columns = template_columns() })
    local _, message, lines = run(layout)
    t.eq(message, nil)
    t.eq(names(layout.state.columns), STANDARD)
    local review = layout.state.columns[5]
    t.eq(review.id, "col-In Review")
    t.eq(lines[1], "renamed column In Review to Review")
    local renames = 0
    for _, write in ipairs(layout.state.writes) do
        renames = renames + (write[1] == "rename_column" and 1 or 0)
    end
    t.eq(renames, 1)
    local again, _, said = run(layout)
    t.eq(again, 0)
    t.eq(said, {})
end)

t.test("a board with both In Review and Review renames nothing", function()
    local columns = template_columns()
    columns[#columns + 1] = { id = "col-Review", name = "Review", is_done = false }
    local layout = fake_layout({ columns = columns })
    run(layout)
    for _, write in ipairs(layout.state.writes) do
        t.ok(write[1] ~= "rename_column")
    end
end)

t.test("a column init does not recognise is reported and kept where it was named", function()
    local columns = template_columns()
    table.insert(columns, 3, { id = "col-odd", name = "Someday", is_done = false })
    local layout = fake_layout({ columns = columns })
    local _, message, lines = run(layout)
    t.eq(message, nil)
    local kept = 0
    for _, line in ipairs(lines) do
        if line == 'kept column "Someday", which is not part of the standard board' then
            kept = kept + 1
        end
    end
    t.eq(kept, 1)
    t.eq(layout.state.columns[#layout.state.columns].name, "Someday")
    t.eq(layout.state.columns[#layout.state.columns].id, "col-odd")
    for _, write in ipairs(layout.state.writes) do
        t.ok(write[1] ~= "rename")
    end
    local _, _, second = run(layout)
    t.eq(#second, 1)
    t.ok(second[1]:find("kept column", 1, true))
    t.eq(#layout.state.writes > 0, true)
end)

t.test("a Done column that does not count as done is marked", function()
    local columns = template_columns()
    columns[6].is_done = false
    local layout = fake_layout({ columns = columns })
    local _, _, lines = run(layout)
    t.eq(layout.state.columns[9].is_done, true)
    t.ok(table.concat(lines, "\n"):find("marked Done", 1, true), lines[1])
end)

t.test("size words come off names and set the colour of a card still at the default", function()
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
    t.eq(message, nil)
    local cards = layout.state.cards
    t.eq(cards[1].name, "Plain card")
    t.eq(cards[2].name, "Make it")
    t.eq(cards[2].color_id, "blue-id")
    t.eq(cards[3].name, "Big thing")
    t.eq(cards[3].color_id, "red-id")
    t.eq(cards[4].name, "Chosen")
    t.eq(cards[4].color_id, "green-id")
    t.eq(cards[5].name, "Small")
    t.eq(cards[5].color_id, "green-id")
    t.eq(cards[6].name, "(blue)")
    local joined = table.concat(lines, "\n")
    t.ok(joined:find('renamed card bbbbbbbb to "Make it" and coloured it blue', 1, true), joined)
    t.ok(
        joined:find('renamed card dddddddd to "Chosen"\n', 1, true)
            or joined:find('renamed card dddddddd to "Chosen"$'),
        joined
    )
    t.ok(joined:find("kept card ffffffff", 1, true), joined)
    local again = run(layout)
    t.eq(again, 0)
end)

t.test("split_size takes the five trailing size words and nothing else", function()
    t.eq({ init.split_size("A (yellow)") }, { "A", "yellow" })
    t.eq({ init.split_size("A (green)") }, { "A", "green" })
    t.eq({ init.split_size("A b (blue)") }, { "A b", "blue" })
    t.eq({ init.split_size("A (red)") }, { "A", "red" })
    t.eq({ init.split_size("A (red, split)") }, { "A", "red" })
    t.eq({ init.split_size("A (red) (blue)") }, { "A", "blue" })
    t.eq(init.split_size("A (blue) later"), nil)
    t.eq(init.split_size("A (purple)"), nil)
    t.eq(init.split_size("A blue"), nil)
end)

t.test("a refused change says to use --admin and stops with the changes so far said", function()
    local layout = fake_layout({ columns = template_columns() })
    function layout:set_color()
        return nil, "board unavailable: pomb answered 403: insufficient_scope"
    end
    local changes, message, lines = run(layout)
    t.eq(changes, nil)
    t.ok(message:find("run dev board init --admin", 1, true), message)
    t.eq(lines[2], "added column Icebox")
end)

local PERMISSIONS = '[{"name":"cards.read","presets":["read","work","lead","admin"]},'
    .. '{"name":"boards.write","presets":["lead","admin"]},{"name":"templates.write","presets":["admin"]}]'
local BOARDS = '[{"id":"board-1","name":"demo","archived":false}]'
local DETAIL = '{"id":"board-1","name":"demo","swimlanes":[],"columns":['
local function detail()
    local parts = {}
    for _, name in ipairs(STANDARD) do
        parts[#parts + 1] = string.format(
            '{"id":"col-%s","name":"%s","wip_limit":null,"is_done":%s}',
            name:gsub(" ", ""),
            name,
            name == "Done" and "true" or "false"
        )
    end
    return DETAIL .. table.concat(parts, ",") .. "]}"
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

local EXPORT =
    '{"tasks":[{"id":"11111111-aaaa","name":"Keep","column_id":"col-Ready","color_id":"blue-id"}]}'

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
    *" -X POST "*) body='{"id":"board-1"}' ;;
    *) body=$(cat "$ROOT/boards.json") ;;
    esac
    ;;
*/api/boards/board-1) body=$(cat "$ROOT/detail.json") ;;
*/colors) body=$(cat "$ROOT/colors.json") ;;
*/fields)
    case " $* " in
    *" -X POST "*) body='{"id":"field-1"}' ;;
    *) body=$(cat "$ROOT/fields.json") ;;
    esac
    ;;
*/export-data) body=$(cat "$ROOT/export.json") ;;
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
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
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
    executable(root .. "/bin/sleep", "#!/bin/sh\nexec " .. devos.which("sleep") .. " 0.1\n")
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

local function writes(root)
    local count = 0
    for line in read(root, "calls"):gsub("\n%%", " %%"):gmatch("[^\n]+") do
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

t.test("init on a board already at the standard says so and writes nothing", function()
    local root, home, tmp = sandbox()
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 0)
    t.eq(out, UNCHANGED .. "board demo already follows the standard, nothing to change\n")
    t.eq(writes(root), 0)
    t.ok(read(root, "calls"):find("pass show secrets/lead/token/pomb", 1, true))
    t.eq(read(root, "stdin"), 'header = "Authorization: Bearer ' .. TOKEN .. '"\n')
end)

t.test("init --admin pairs through pending, slow_down and success", function()
    local root, home, tmp = sandbox({
        script = '428|{"code":"authorization_pending","message":"wait"}\n'
            .. '429|{"code":"slow_down","message":"slower"}\n'
            .. '428|{"code":"authorization_pending","message":"wait"}\n'
            .. '200|{"token":"'
            .. ADMIN_TOKEN
            .. '","name":"n","scopes":["admin"]}\n',
    })
    local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
    t.eq(code, 0)
    t.eq(
        out,
        "approve the admin sign-in at https://pomb.example/device\n"
            .. "code: ABCD-EFGH\n"
            .. UNCHANGED
            .. "board demo already follows the standard, nothing to change\n"
    )
    t.eq(read(root, "polls"), "4\n")
    local calls = read(root, "calls")
    t.ok(calls:find('"client_name":"dev-board-init@', 1, true), calls)
    t.ok(calls:find('"scopes":["admin"]', 1, true), calls)
    t.eq(calls:find("pass show", 1, true), nil)
    t.eq(read(root, "stdin"), 'header = "Authorization: Bearer ' .. ADMIN_TOKEN .. '"\n')
end)

t.test("the device token never reaches argv, the environment, a file or the output", function()
    local root, home, tmp = sandbox()
    local out = dev(root, home, tmp, { "-vv", "board", "init", "--admin" })
    t.eq(out:find(ADMIN_TOKEN, 1, true), nil)
    t.eq(read(root, "calls"):find(ADMIN_TOKEN, 1, true), nil)
    t.eq(read(root, "env"):find(ADMIN_TOKEN, 1, true), nil)
    t.eq(read(root, "calls"):find(DEVICE_CODE, 1, true), nil)
    t.eq(read(root, "env"):find(DEVICE_CODE, 1, true), nil)
    t.ok(read(root, "bodies"):find(DEVICE_CODE, 1, true))
    t.eq(read(root, "bodies"):find(ADMIN_TOKEN, 1, true), nil)
    t.eq(fs.list(tmp), {})
    t.eq(fs.list(home .. "/state") == nil or #fs.list(home .. "/state") == 0, true)
    local found = devos.capture({ "grep", "-rl", ADMIN_TOKEN, home, tmp })
    t.eq(found, "")
end)

t.test("a denied sign-in ends the run with no board call", function()
    local root, home, tmp = sandbox({
        script = '403|{"code":"access_denied","message":"no"}\n',
    })
    local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
    t.eq(code, 1)
    t.ok(out:find("dev: the sign-in was denied", 1, true), out)
    t.eq(read(root, "calls"):find("/api/boards", 1, true), nil)
    t.eq(fs.list(tmp), {})
end)

t.test("an expired or unknown sign-in ends the run", function()
    for _, case in ipairs({
        { '410|{"code":"device_code_expired","message":"x"}\n', "not approved in time" },
        { '400|{"code":"invalid_grant","message":"x"}\n', "no longer knows" },
        { '409|{"code":"quota_exceeded","message":"x"}\n', "revoke one" },
        { '200|{"token":"bad\\"token","name":"n"}\n', "not plain text" },
    }) do
        local root, home, tmp = sandbox({ script = case[1] })
        local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
        t.eq(code, 1)
        t.ok(out:find(case[2], 1, true), out)
    end
end)

t.test("a token the approver lowered is refused", function()
    local root, home, tmp = sandbox()
    assert(fs.write(root .. "/whoami.json", '{"kind":"token","name":"x","scope":"work"}'))
    local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
    t.eq(code, 1)
    t.ok(out:find("the approved token has the work scope, init needs admin", 1, true), out)
    t.eq(writes(root), 0)
end)

t.test("init without a lead token or --admin says what to set", function()
    local root, home, tmp = sandbox({ user = '[board.pomb]\nurl = "https://pomb.example"\n' })
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 1)
    t.ok(out:find("lead_token is not set", 1, true), out)
end)

t.test("a project with no [board] section needs --name and then gets one", function()
    local root, home, tmp = sandbox({ project = "" })
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 1)
    t.ok(out:find("pass --name N", 1, true), out)
    t.eq(read(root, ".dev/config.toml"), "")
    out, code = dev(root, home, tmp, { "board", "init", "--name", "demo" })
    t.eq(code, 0)
    t.eq(
        out,
        UNCHANGED
            .. "wrote [board] to .dev/config.toml\n"
            .. "board demo already follows the standard, nothing to change\n"
    )
    t.eq(read(root, ".dev/config.toml"), '[board]\nbackend = "pomb"\nname = "demo"\n')
    out, code = dev(root, home, tmp, { "board", "status" })
    t.eq(out, "backend: pomb\nboard: demo\n")
end)

t.test("a project with no .dev/config.toml takes --name and gets the file", function()
    local root, home, tmp = sandbox({ project = false })
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 1)
    t.ok(out:find("pass --name N", 1, true), out)
    out, code = dev(root, home, tmp, { "board", "init", "--name", "demo" })
    t.eq(code, 0)
    t.eq(
        out,
        UNCHANGED
            .. "wrote [board] to .dev/config.toml\n"
            .. "board demo already follows the standard, nothing to change\n"
    )
    t.eq(read(root, ".dev/config.toml"), '[board]\nbackend = "pomb"\nname = "demo"\n')
end)

t.test("a project with no .dev directory gets it and the file", function()
    local root, home, tmp = sandbox({ project = false })
    assert(fs.remove(root .. "/.dev", { recursive = true }))
    local out, code = dev(root, home, tmp, { "board", "init", "--name", "demo" })
    t.eq(code, 0, out)
    t.eq(
        out,
        UNCHANGED
            .. "wrote [board] to .dev/config.toml\n"
            .. "board demo already follows the standard, nothing to change\n"
    )
    t.ok(fs.is_dir(root .. "/.dev"))
    t.eq(read(root, ".dev/config.toml"), '[board]\nbackend = "pomb"\nname = "demo"\n')
end)

t.test("the section is appended after other config", function()
    local root, home, tmp = sandbox({ project = '[remote]\nrunner = "ci"' })
    dev(root, home, tmp, { "board", "init", "--name", "demo" })
    t.eq(
        read(root, ".dev/config.toml"),
        '[remote]\nrunner = "ci"\n\n[board]\nbackend = "pomb"\nname = "demo"\n'
    )
end)

t.test("--name that disagrees with the [board] name is a usage error", function()
    local root, home, tmp = sandbox()
    local out, code = dev(root, home, tmp, { "board", "init", "--name", "other" })
    t.eq(code, 2)
    t.ok(out:find("--name other is not the [board] name demo", 1, true), out)
    t.eq(read(root, "calls"), "")
end)

t.test("init refuses an unknown flag and a stray argument", function()
    local root, home, tmp = sandbox()
    local _, code = dev(root, home, tmp, { "board", "init", "--bogus" })
    t.eq(code, 2)
    _, code = dev(root, home, tmp, { "board", "init", "extra" })
    t.eq(code, 2)
end)

local function calls_of(root)
    return (read(root, "calls"):gsub("\n%%", " %%"))
end

t.test("init defines the checks field once with the dev definition", function()
    local root, home, tmp = sandbox({ fields = "[]" })
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 0, out)
    t.eq(out, UNCHANGED .. "added the checks field dev.checks\nboard demo: 1 change\n")
    local body = '{"columns":[{"key":"run","kind":"text","label":"Run","options":[],"required":true},'
        .. '{"key":"on","kind":"multiselect","label":"On","options":["local"],"required":false}],'
        .. '"key":"dev.checks","kind":"table","label":"Checks","required":true}'
    t.ok(
        calls_of(root):find(
            "--data-raw " .. body .. " https://pomb.example/api/boards/board-1/fields",
            1,
            true
        ),
        calls_of(root)
    )
    t.eq(writes(root), 1)
    root, home, tmp = sandbox()
    out = dev(root, home, tmp, { "board", "init" })
    t.eq(out, UNCHANGED .. "board demo already follows the standard, nothing to change\n")
    t.eq(writes(root), 0)
end)

t.test("init sends the changes an old board needs as the API's own calls", function()
    local root, home, tmp = sandbox()
    local last = DETAIL
    local ordered = {
        "Backlog",
        "Ready",
        "In Progress",
        "Review",
        "Verify",
        "Release",
        "Blocked",
        "Done",
        "Icebox",
    }
    local parts = {}
    for _, name in ipairs(ordered) do
        parts[#parts + 1] = string.format(
            '{"id":"col-%s","name":"%s","wip_limit":null,"is_done":%s}',
            name:gsub(" ", ""),
            name,
            name == "Done" and "true" or "false"
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
    assert(
        fs.write(
            root .. "/export.json",
            '{"tasks":[{"id":"11111111-aaaa","name":"Keep it (blue)","column_id":"col-Ready","color_id":"yellow-id"}]}'
        )
    )
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 0)
    local calls = calls_of(root)
    t.ok(calls:find("-X POST", 1, true), calls)
    t.ok(
        calls:find(
            '--data-raw {"position":0} https://pomb.example/api/columns/col-Icebox/move',
            1,
            true
        ),
        calls
    )
    t.ok(calls:find("-X PATCH", 1, true), calls)
    t.ok(
        calls:find(
            '--data-raw {"description":"One pomodoro or less","label":"1 Pomodoro"} https://pomb.example/api/boards/board-1/colors/yellow-id',
            1,
            true
        ),
        calls
    )
    t.ok(
        calls:find(
            '--data-raw {"is_default":true} https://pomb.example/api/boards/board-1/colors/white-id',
            1,
            true
        ),
        calls
    )
    t.ok(
        calls:find(
            '--data-raw {"color_id":"blue-id","name":"Keep it"} https://pomb.example/api/tasks/11111111-aaaa',
            1,
            true
        ),
        calls
    )
    t.ok(out:find("moved column Icebox to position 0\n", 1, true), out)
    t.ok(out:find('named yellow "1 Pomodoro"\n', 1, true), out)
    t.ok(out:find("made white the default colour\n", 1, true), out)
    t.ok(out:find('renamed card 11111111 to "Keep it" and coloured it blue\n', 1, true), out)
    t.eq(out:find(TOKEN, 1, true), nil)
end)

t.test("init renames In Review to Review through the column update", function()
    local root, home, tmp = sandbox()
    local parts = {}
    for _, name in ipairs({
        "Icebox",
        "Backlog",
        "Ready",
        "In Progress",
        "In Review",
        "Verify",
        "Release",
        "Blocked",
        "Done",
    }) do
        parts[#parts + 1] = string.format(
            '{"id":"col-%s","name":"%s","wip_limit":null,"is_done":%s}',
            name:gsub(" ", ""),
            name,
            name == "Done" and "true" or "false"
        )
    end
    assert(fs.write(root .. "/detail.json", DETAIL .. table.concat(parts, ",") .. "]}"))
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 0, out)
    t.ok(
        calls_of(root):find(
            '--data-raw {"name":"Review"} https://pomb.example/api/columns/col-InReview',
            1,
            true
        ),
        calls_of(root)
    )
    t.ok(out:find("renamed column In Review to Review\n", 1, true), out)
end)

t.test("init makes a missing board from the agent project template", function()
    local root, home, tmp = sandbox()
    assert(fs.write(root .. "/boards.json", "[]"))
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 0)
    local calls = calls_of(root)
    t.ok(
        calls:find(
            '--data-raw {"name":"demo","template_id":"tpl-1"} https://pomb.example/api/boards',
            1,
            true
        ),
        calls
    )
    t.ok(out:find("created board demo from the agent project template\n", 1, true), out)
end)

t.test("init adds a column with the done flag where it belongs", function()
    local root, home, tmp = sandbox()
    assert(
        fs.write(
            root .. "/detail.json",
            '{"id":"board-1","name":"demo","swimlanes":[],"columns":[{"id":"col-Backlog","name":"Backlog","is_done":false}]}'
        )
    )
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 1)
    local calls = calls_of(root)
    t.ok(
        calls:find(
            '--data-raw {"board_id":"board-1","is_done":true,"name":"Done"} https://pomb.example/api/columns',
            1,
            true
        ),
        calls
    )
    t.ok(calls:find('"is_done":false,"name":"Icebox"', 1, true), calls)
    t.ok(out:find("added column Icebox\n", 1, true), out)
    t.ok(out:find("still has no Icebox column", 1, true), out)
end)

t.test("board names the columns init lays out", function()
    t.eq(board.roles().list, STANDARD)
end)

t.test("a run that stops while stripping can be repeated without losing a size", function()
    local layout = fake_layout({
        columns = template_columns(),
        cards = { { id = "aaaaaaaa-1", name = "Thing (red)", color_id = "yellow-id" } },
    })
    local set_card = layout.set_card
    function layout:set_card()
        return nil, "board unavailable: pomb answered 503: down"
    end
    local changes = run(layout)
    t.eq(changes, nil)
    layout.set_card = set_card
    run(layout)
    t.eq(layout.state.cards[1].name, "Thing")
    t.eq(layout.state.cards[1].color_id, "red-id")
end)

t.test("colours outside the size palette are disabled and the five are enabled", function()
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
    t.eq(message, nil)
    local joined = table.concat(lines, "\n")
    for _, line in ipairs({
        "enabled white",
        "disabled orange",
        "disabled purple",
        "disabled brown",
    }) do
        t.ok(joined:find(line .. "\n", 1, true) or joined:find(line .. "$"), joined)
    end
    for _, value in ipairs({ "yellow", "green", "blue", "red", "white" }) do
        t.eq(color(layout, value).enabled, true)
    end
    for _, value in ipairs({ "orange", "purple", "brown" }) do
        t.eq(color(layout, value).enabled, false)
    end
    local again, _, second = run(layout)
    t.eq(again, 0)
    t.eq(second, {})
end)

t.test("a card wearing a disabled colour is reported on every run and left alone", function()
    local layout = fake_layout({
        columns = template_columns(),
        cards = { { id = "aaaaaaaa-1", name = "Odd", color_id = "orange-id" } },
    })
    local _, _, lines = run(layout)
    local report = "card aaaaaaaa wears the disabled colour orange, left as it is"
    t.eq(lines[#lines], report)
    t.eq(layout.state.cards[1].color_id, "orange-id")
    local changes, _, second = run(layout)
    t.eq(changes, 0)
    t.eq(second, { report })
end)

t.test("a token that may not enable colours leaves them and carries on", function()
    local layout = fake_layout({ columns = template_columns() })
    local set_color = layout.set_color
    function layout:set_color(id, fields)
        if fields.enabled ~= nil then
            return nil, "board unavailable: pomb answered 403: insufficient_scope"
        end
        return set_color(self, id, fields)
    end
    local changes, message, lines = run(layout)
    t.eq(message, nil)
    t.ok(changes > 0)
    local left = 0
    for _, line in ipairs(lines) do
        if line:find("run dev board init --admin", 1, true) then
            left = left + 1
        end
    end
    t.eq(left, 1)
    t.eq(color(layout, "orange").enabled, true)
    t.eq(color(layout, "white").is_default, true)
end)

t.test("init sends enabled through the palette PATCH for each colour", function()
    local root, home, tmp = sandbox()
    local orange = ',{"id":"orange-id","value":"orange","label":"Orange",'
        .. '"description":"","is_default":false,"enabled":true}]'
    assert(fs.write(root .. "/colors.json", colors_json():gsub("%]$", "") .. orange))
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 0)
    local patch = '--data-raw {"enabled":false} '
        .. "https://pomb.example/api/boards/board-1/colors/orange-id"
    t.ok(calls_of(root):find(patch, 1, true), calls_of(root))
    t.eq(out, UNCHANGED .. "disabled orange\nboard demo: 1 change\n")
end)

t.test("agent-roles-create: a first init posts the board id and prints names", function()
    local root, home, tmp = sandbox({
        roles = '200|{"created":["planner","implementer","reviewer","verifier","release","lead"],'
            .. '"roles":[]}\n',
    })
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 0, out)
    t.eq(
        out,
        "created agent roles planner, implementer, reviewer, verifier, release, lead\n"
            .. "board demo: 1 change\n"
    )
    t.ok(
        calls_of(root):find(
            '--data-raw {"boards":["board-1"]} https://pomb.example/api/v1/agent-roles/standard',
            1,
            true
        ),
        calls_of(root)
    )
end)

t.test("agent-roles-unchanged: a rerun prints unchanged and counts no change", function()
    local root, home, tmp = sandbox()
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 0, out)
    t.eq(out, UNCHANGED .. "board demo already follows the standard, nothing to change\n")
    t.ok(calls_of(root):find("/api/v1/agent-roles/standard", 1, true), calls_of(root))
end)

t.test("agent-roles-create: the step runs once through a layout", function()
    local layout = fake_layout({ columns = template_columns() })
    local lines = {}
    local changes = init.run(layout, "demo", function(line)
        lines[#lines + 1] = line
    end)
    t.ok(changes >= 1)
    t.ok(table.concat(lines, "\n"):find("created agent roles planner, implementer", 1, true))
    lines = {}
    t.eq(
        init.run(layout, "demo", function(line)
            lines[#lines + 1] = line
        end),
        0
    )
    t.eq(lines, { "agent roles unchanged" })
end)

t.test("a board with no roles says nothing about them", function()
    local layout = fake_layout({ columns = template_columns(), roles = false })
    local lines = {}
    init.run(layout, "demo", function(line)
        lines[#lines + 1] = line
    end)
    for _, line in ipairs(lines) do
        t.eq(line:find("agent roles", 1, true), nil, line)
    end
end)

t.test("agent-roles-exceeds-grant: a board the init token does not hold is named", function()
    local root, home, tmp = sandbox({
        roles = '403|{"code":"exceeds_grant","message":"the calling token does not hold board board-1"}\n',
    })
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 1)
    t.ok(out:find("the token does not hold board demo (board-1)", 1, true), out)
    t.ok(out:find("add the board to the token", 1, true), out)
    t.eq(out:find("--admin", 1, true), nil)
end)

t.test("agent-roles-denied: a permission_denied names the missing permission", function()
    local root, home, tmp = sandbox({
        roles = '403|{"code":"permission_denied","message":"no","permission":"settings.write",'
            .. '"board_id":null}\n',
    })
    local out, code = dev(root, home, tmp, { "board", "init" })
    t.eq(code, 1)
    t.ok(out:find("lacks the settings.write permission", 1, true), out)
end)

t.test("init --admin accepts a token with the admin preset's permissions on every board", function()
    local root, home, tmp = sandbox()
    assert(
        fs.write(
            root .. "/whoami.json",
            '{"permissions":["cards.read","boards.write","templates.write"],"boards":"all"}'
        )
    )
    local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
    t.eq(code, 0)
    t.ok(out:find("already follows the standard", 1, true), out)
end)

t.test("init --admin refuses a token missing an admin permission or some boards", function()
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
        t.eq(code, 1)
        t.ok(out:find(case[2], 1, true), out)
        t.eq(writes(root), 0)
    end
end)

t.test("init --admin refuses a catalog that lists no admin preset", function()
    local root, home, tmp = sandbox()
    assert(fs.write(root .. "/whoami.json", '{"permissions":[],"boards":"all"}'))
    assert(fs.write(root .. "/permissions.json", "[]"))
    local out, code = dev(root, home, tmp, { "board", "init", "--admin" })
    t.eq(code, 1)
    t.ok(out:find("lists no admin preset", 1, true), out)
    t.eq(writes(root), 0)
end)

t.test(
    "init on a permission_denied with no board suggests --admin, with a board does not",
    function()
        local layout = fake_layout({ columns = template_columns() })
        function layout:set_color()
            return nil,
                "board unavailable: pomb answered 403: this token lacks the boards.write permission "
                    .. "on every board; use a token that has it"
        end
        local _, message = run(layout)
        t.ok(message:find("run dev board init --admin", 1, true), message)
        function layout:set_color()
            return nil,
                "board unavailable: this token has the boards.write permission but is not assigned "
                    .. "to board b; add the board to the token"
        end
        _, message = run(layout)
        t.eq(message:find("--admin", 1, true), nil)
    end
)
