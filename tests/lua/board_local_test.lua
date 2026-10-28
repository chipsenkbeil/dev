local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local TOKEN = "pomb_SECRETtoken0123456789"
local ID_A = "aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa"
local ID_B = "bbbbbbbb-1111-4bbb-8bbb-bbbbbbbbbbbb"
local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/dotfiles/bin/.local/share/dev/main.lua"

local function setup(project)
    local root = support.sandbox({ [".dev/config.toml"] = project }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(
        fs.write(
            home .. "/.config/dev/config.toml",
            '[board.pomb]\nurl = "https://pomb.example"\ntoken = "pass:secrets/worker/token/pomb"\n'
        )
    )
    return root, home
end

local function env_of(home, extra)
    local env = { HOME = home, XDG_STATE_HOME = home .. "/state", CLAUDE_SESSION_ID = "one" }
    for name, value in pairs(extra or {}) do
        env[name] = value
    end
    return env
end

local function dev(root, home, args, extra)
    return support.dev(root, args, { env = env_of(home, extra) })
end

local function local_board(project)
    local root, home = setup(project or '[board]\nbackend = "local"\nname = "mine"\n')
    local out, code = dev(root, home, { "board", "init" })
    t.eq(code, 0, out)
    return root, home
end

local function file_of(home)
    return home .. "/state/dev/boards/mine.json"
end

local function document(path)
    return assert(json.decode(assert(fs.read(path))))
end

local function prefix_of(out)
    return assert(out:match("added (%x+)"), out)
end

local function mode(path)
    return string.format("%o", bit.band(assert(fs.stat(path)).mode, 511))
end

t.test("init lays out the seven columns and the palette and is idempotent", function()
    local root, home = setup('[board]\nbackend = "local"\nname = "mine"\n')
    local out, code = dev(root, home, { "board", "init" })
    t.eq(code, 0, out)
    t.ok(out:find("created board mine with no template", 1, true), out)
    for _, column in ipairs({
        "Icebox",
        "Backlog",
        "Ready",
        "In Progress",
        "In Review",
        "Blocked",
        "Done",
    }) do
        t.ok(out:find("added column " .. column, 1, true), out)
    end
    t.ok(out:find('named yellow "1 Pomodoro"', 1, true), out)
    t.ok(out:find('named white "Unsized"', 1, true), out)
    t.ok(out:find("made white the default colour", 1, true), out)
    local doc = document(file_of(home))
    local names = {}
    for _, column in ipairs(doc.columns) do
        names[#names + 1] = column.name
    end
    t.eq(names, { "Icebox", "Backlog", "Ready", "In Progress", "In Review", "Blocked", "Done" })
    t.eq(doc.columns[7].is_done, true)
    local labels = {}
    for _, color in ipairs(doc.colors) do
        labels[#labels + 1] = color.value .. "=" .. color.label
    end
    t.eq(labels, {
        "yellow=1 Pomodoro",
        "green=2 Pomodori",
        "blue=3 Pomodori",
        "red=>3 Pomodori",
        "white=Unsized",
    })
    out, code = dev(root, home, { "board", "init" })
    t.eq(code, 0, out)
    t.eq(out, "board mine already follows the standard, nothing to change\n")
end)

t.test("the board file is private and writes leave no temporary file", function()
    local root, home = local_board()
    dev(root, home, { "board", "add", "One" })
    t.eq(mode(file_of(home)), "600")
    t.eq(mode(home .. "/state/dev/boards"), "700")
    local names = fs.list(home .. "/state/dev/boards")
    t.eq(names, { "mine.json", "mine.json.lock" })
end)

t.test("add, ls, next, move, size and label work on a local board", function()
    local root, home = local_board()
    local out, code = dev(root, home, {
        "board",
        "add",
        "Write docs",
        "--column",
        "ready",
        "--size",
        "2",
        "--label",
        "docs",
        "--label",
        "needs:lead",
        "--description",
        "why",
    })
    t.eq(code, 0, out)
    local a = prefix_of(out)
    t.ok(out:find("Ready", 1, true), out)
    out = dev(root, home, { "board", "add", "Second" })
    local b = prefix_of(out)
    out = dev(root, home, { "board", "ls" })
    t.eq(
        out,
        b
            .. "  Backlog  Unsized     -                Second\n"
            .. a
            .. "  Ready    2 Pomodori  docs,needs:lead  Write docs\n"
    )
    out = dev(root, home, { "board", "ls", "--size", "3+" })
    t.eq(out, "no cards\n")
    out = dev(root, home, { "board", "ls", "--label", "docs" })
    t.ok(out:find("Write docs", 1, true), out)
    out = dev(root, home, { "board", "next" })
    t.eq(out, a .. "  Ready  2 Pomodori  docs,needs:lead  Write docs\n")
    out = dev(root, home, { "board", "move", a, "review" })
    t.eq(out, "moved " .. a .. " to In Review\n")
    out = dev(root, home, { "board", "next" })
    t.eq(out, "no ready cards\n")
    out = dev(root, home, { "board", "size", b, "1" })
    t.eq(out, "sized " .. b .. " 1\n")
    out = dev(root, home, { "board", "label", a, "+extra", "--remove", "docs" })
    t.eq(out, "labelled " .. a .. " needs:lead,extra\n")
    out = dev(root, home, { "board", "move", a, "done" })
    out = dev(root, home, { "board", "ls" })
    t.eq(out, b .. "  Backlog  1 Pomodoro  -  Second\n")
    out = dev(root, home, { "board", "ls", "--column", "done" })
    t.ok(out:find("Done  2 Pomodori", 1, true), out)
end)

t.test("notes, edit and delete work on a local board and refuse another author's", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "Card" })))
    local out = dev(root, home, { "board", "note", a, "first", "thought" })
    t.eq(out, "noted " .. a .. "\n")
    dev(root, home, { "board", "note", a, "second" })
    out = dev(root, home, { "board", "notes", a })
    local first = assert(out:match("^(%x+)"))
    t.ok(out:find("agent  ", 1, true) and out:find("first thought", 1, true), out)
    local second = assert(out:match("\n(%x+)"))
    out = dev(root, home, { "board", "note", a, "--edit", first, "better", "words" })
    t.eq(out, "edited " .. a .. " " .. first .. "\n")
    out = dev(root, home, { "board", "note", a, "--delete", second })
    t.eq(out, "deleted " .. a .. " " .. second .. "\n")
    out = dev(root, home, { "board", "notes", a })
    t.ok(out:find("better words", 1, true) and not out:find("second", 1, true), out)
    local doc = document(file_of(home))
    doc.cards[1].comments[1].who = "human"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    out = dev(root, home, { "board", "note", a, "--edit", first, "x" })
    t.eq(out, "dev: that comment is not yours to change\n")
end)

t.test("stale counts the days a card sat in its column", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "Old", "--column", "ready" })))
    prefix_of((dev(root, home, { "board", "add", "New", "--column", "ready" })))
    local doc = document(file_of(home))
    doc.cards[1].entered_at = "2020-01-01T00:00:00Z"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    local out = dev(root, home, { "board", "stale" })
    t.ok(out:find(a .. "  Ready  ", 1, true) and out:find("Old", 1, true), out)
    t.ok(not out:find("New", 1, true), out)
end)

t.test("take holds a claim with an expiry and no loop, and release gives it up", function()
    local root, home = local_board()
    local a =
        prefix_of((dev(root, home, { "board", "add", "Card", "--column", "ready", "--size", "1" })))
    local out, code = dev(root, home, { "board", "take", a })
    t.eq(code, 0, out)
    t.eq(out, "took " .. a .. ", fence 1, held for 50m\n")
    local doc = document(file_of(home))
    t.eq(doc.cards[1].claim.fence, 1)
    t.ok(doc.cards[1].claim.expires_at > os.date("!%Y-%m-%dT%H:%M:%SZ"), "expiry in the future")
    out = dev(root, home, { "board", "ls" })
    t.ok(out:find("dev@", 1, true), out)
    out = dev(root, home, { "board", "next" })
    t.eq(out, "no ready cards\n")
    out, code = dev(root, home, { "board", "take", a }, { CLAUDE_SESSION_ID = "other" })
    t.eq(code, 1)
    t.ok(out:find("is claimed by dev@", 1, true), out)
    out = dev(root, home, { "board", "take", a })
    t.eq(out, "took " .. a .. ", fence 1, held for 50m\n")
    out = dev(root, home, { "board", "release", a })
    t.eq(out, "released " .. a .. "\n")
    out = dev(root, home, { "board", "next" })
    t.ok(out:find("Card", 1, true), out)
    out = dev(root, home, { "board", "take", a }, { CLAUDE_SESSION_ID = "other" })
    t.eq(out, "took " .. a .. ", fence 2, held for 50m\n")
end)

t.test("a stale fence is refused once another process holds the claim", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "Card" })))
    dev(root, home, { "board", "take", a })
    local doc = document(file_of(home))
    doc.cards[1].claim.fence = 9
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    local out, code = dev(root, home, { "board", "note", a, "hello" })
    t.eq(code, 1)
    t.ok(out:find("is held by dev@", 1, true) and out:find("fence 9", 1, true), out)
end)

t.test("an expired claim does not block the card", function()
    local root, home = local_board()
    local a = prefix_of((dev(root, home, { "board", "add", "Card", "--column", "ready" })))
    dev(root, home, { "board", "take", a })
    local doc = document(file_of(home))
    doc.cards[1].claim.expires_at = "2020-01-01T00:00:00Z"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    local out = dev(root, home, { "board", "next" })
    t.ok(out:find("Card", 1, true), out)
    out = dev(root, home, { "board", "note", a, "still works" })
    t.eq(out, "noted " .. a .. "\n")
end)

t.test("a tracked path keeps the board in the project, readable by everyone", function()
    local root, home = local_board('[board]\nbackend = "local"\npath = ".dev/board.json"\n')
    local out = dev(root, home, { "board", "add", "Tracked" })
    prefix_of(out)
    t.ok(fs.exists(root .. "/.dev/board.json"))
    t.eq(fs.exists(home .. "/state/dev/boards/mine.json"), false)
    t.eq(document(root .. "/.dev/board.json").cards[1].name, "Tracked")
    t.ok(mode(root .. "/.dev/board.json") ~= "600", "not private")
    local text = assert(fs.read(root .. "/.dev/board.json"))
    t.ok(select(2, text:gsub("\n", "")) > 4, "one line per card")
end)

t.test("a path outside the project, or on a pomb board, is refused", function()
    for _, path in ipairs({ "../board.json", "/etc/board.json", "a//b.json", ".dev/../x.json" }) do
        local root, home = setup('[board]\nbackend = "local"\npath = "' .. path .. '"\n')
        local out, code = dev(root, home, { "board", "ls" })
        t.eq(code, 1, path)
        t.ok(out:find("[board] path must be a relative path", 1, true), out)
    end
    local root, home = setup('[board]\nbackend = "pomb"\npath = ".dev/board.json"\n')
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find('path only applies to backend = "local"', 1, true), out)
end)

t.test("a local board's name has to make a file name unless a path is set", function()
    local root, home = setup('[board]\nbackend = "local"\nname = "a/b"\n')
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("name must be letters, digits", 1, true), out)
end)

t.test("init refuses --admin on a local board and a different --name", function()
    local root, home = setup('[board]\nbackend = "local"\nname = "mine"\n')
    local out, code = dev(root, home, { "board", "init", "--admin" })
    t.eq(code, 2, out)
    out, code = dev(root, home, { "board", "init", "--name", "other" })
    t.eq(code, 2, out)
end)

t.test("sync on a local board says there is nothing to sync", function()
    local root, home = local_board()
    local out, code = dev(root, home, { "board", "sync" })
    t.eq(code, 1)
    t.eq(out, "dev: a local board has nothing to sync\n")
end)

t.test("six processes writing at once lose no card", function()
    local root, home = local_board()
    local script = string.format(
        'for i in 1 2 3 4 5 6; do luajit %s board add "card $i" & done; wait',
        devos.quote(MAIN)
    )
    local out, code = devos.capture({ "sh", "-c", script }, {
        cwd = root,
        stderr = "stdout",
        env = {
            HOME = home,
            XDG_STATE_HOME = home .. "/state",
            PATH = root .. "/bin:" .. os.getenv("PATH"),
            DEV_SELF = REPO .. "/dotfiles/bin/.local/bin/dev",
        },
    })
    t.eq(code, 0, out)
    local doc = document(file_of(home))
    t.eq(#doc.cards, 6)
    local ids = {}
    for _, card in ipairs(doc.cards) do
        ids[card.id] = true
    end
    local count = 0
    for _ in pairs(ids) do
        count = count + 1
    end
    t.eq(count, 6)
    t.eq(fs.list(home .. "/state/dev/boards"), { "mine.json", "mine.json.lock" })
end)

local BOARDS = '[{"id":"board-1","name":"dotfiles","archived":false}]'
local DETAIL = '{"id":"board-1","name":"dotfiles","columns":['
    .. '{"id":"col-backlog","name":"Backlog"},{"id":"col-ready","name":"Ready"},'
    .. '{"id":"col-review","name":"In Review"},{"id":"col-done","name":"Done"}]}'
local COLORS = '[{"id":"white-id","value":"white","label":"Unsized"}]'
local EXPORT = '{"tasks":[{"id":"'
    .. ID_A
    .. '","name":"First","column_id":"col-ready","position":1,"color_id":null,"labels":[]},'
    .. '{"id":"'
    .. ID_B
    .. '","name":"Second","column_id":"col-ready","position":2,"color_id":null,"labels":[]}]}'

local CURL = [[#!/bin/sh
cat >"$ROOT/stdin"
if [ -f "$ROOT/down" ]; then exit 7; fi
if [ -f "$ROOT/gateway" ]; then printf '<html>bad gateway</html>\n502'; exit 0; fi
method=GET
prev=
for arg; do
    if [ "$prev" = -X ]; then method=$arg; fi
    prev=$arg
done
for last; do :; done
printf '%s %s\n' "$method" "$last" >>"$ROOT/calls"
status=200
case "$last" in
*/api/boards) body=$(cat "$ROOT/boards.json") ;;
*/api/boards/board-1) body=$(cat "$ROOT/detail.json") ;;
*/colors) body=$(cat "$ROOT/colors.json") ;;
*/export-data) body=$(cat "$ROOT/export.json") ;;
*/api/tasks) body='{"id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc","name":"x","column_id":"col-backlog"}' ;;
*) body='{"ok":true}' ;;
esac
printf '%s\n%s' "$body" "$status"
]]

local function pomb(opts)
    opts = opts or {}
    local root, home = setup('[board]\nbackend = "pomb"\nname = "dotfiles"\n')
    for name, body in pairs({
        ["boards.json"] = BOARDS,
        ["detail.json"] = DETAIL,
        ["colors.json"] = COLORS,
        ["export.json"] = EXPORT,
    }) do
        assert(fs.write(root .. "/" .. name, body))
    end
    assert(fs.write(root .. "/bin/curl", CURL))
    assert(devos.run({ "chmod", "755", root .. "/bin/curl" }) == 0, "chmod failed")
    assert(
        fs.write(
            root .. "/bin/pass",
            "#!/bin/sh\n" .. (opts.locked and "exit 1\n" or ('echo "' .. TOKEN .. '"\n'))
        )
    )
    assert(devos.run({ "chmod", "755", root .. "/bin/pass" }) == 0, "chmod failed")
    return root, home
end

local function pomb_dev(root, home, args)
    return dev(root, home, args, { ROOT = root })
end

local function queue_path(home)
    return home .. "/state/dev/boards/dotfiles.queue"
end

local function calls(root)
    return fs.read(root .. "/calls") or ""
end

local QUEUED = "queued: Pomb unreachable, will sync\n"

t.test("writes while Pomb is unreachable are queued and the queue is private", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    t.eq(out, QUEUED)
    t.eq(code, 0)
    out = pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "kept", "words" })
    t.eq(out, QUEUED)
    out = pomb_dev(root, home, { "board", "add", "Later", "--size", "2", "--label", "docs" })
    t.eq(out, QUEUED)
    out = pomb_dev(root, home, { "board", "size", ID_B:sub(1, 8), "3" })
    t.eq(out, QUEUED)
    out = pomb_dev(root, home, { "board", "label", ID_B:sub(1, 8), "+x" })
    t.eq(out, QUEUED)
    local entries = document(queue_path(home))
    t.eq(#entries, 5)
    t.eq(entries[1].sub, "move")
    t.eq(entries[1].args, { ID_A:sub(1, 8), "review" })
    t.eq(entries[2].args, { ID_A:sub(1, 8), "kept", "words" })
    t.eq(entries[3].sub, "add")
    t.eq(mode(queue_path(home)), "600")
    t.eq(mode(home .. "/state/dev/boards"), "700")
    t.ok(not assert(fs.read(queue_path(home))):find(TOKEN, 1, true), "no token in the queue")
    t.eq(calls(root), "")
end)

t.test("after a gateway error only a change that is safe to repeat is queued", function()
    local root, home = pomb()
    assert(fs.write(root .. "/gateway", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    t.eq(out, QUEUED)
    t.eq(code, 0)
    out, code = pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "once" })
    t.eq(code, 1, out)
    out, code = pomb_dev(root, home, { "board", "add", "Once" })
    t.eq(code, 1, out)
    t.eq(#document(queue_path(home)), 1)
end)

t.test("a hand-edited board file keeps its other keys and gets its name back", function()
    local root, home = local_board()
    local doc = document(file_of(home))
    doc.name = nil
    doc.note = "kept"
    assert(fs.write(file_of(home), assert(json.encode(doc))))
    dev(root, home, { "board", "add", "One" })
    doc = document(file_of(home))
    t.eq(doc.note, "kept")
    t.eq(doc.name, "mine")
end)

t.test("a tracked board leaves no lock file in the project", function()
    local root, home = local_board('[board]\nbackend = "local"\npath = ".dev/board.json"\n')
    dev(root, home, { "board", "add", "One" })
    t.eq(fs.list(root .. "/.dev"), { "board.json", "config.toml" })
end)

t.test("a locked pass queues a write the same way", function()
    local root, home = pomb({ locked = true })
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    t.eq(out, QUEUED)
    t.eq(code, 0)
    t.eq(#document(queue_path(home)), 1)
end)

t.test("reads, usage errors and refusals are not queued", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("cannot reach", 1, true), out)
    out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "nowhere" })
    t.eq(code, 2, out)
    out, code = pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "--edit", "aaaaaaaa", "x" })
    t.eq(code, 1, out)
    out, code = pomb_dev(root, home, { "board", "take", ID_A:sub(1, 8) })
    t.eq(code, 1, out)
    t.eq(fs.exists(queue_path(home)), false)
end)

t.test("sync replays the queue in order and empties it", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    pomb_dev(root, home, { "board", "note", ID_B:sub(1, 8), "hello" })
    pomb_dev(root, home, { "board", "add", "Later" })
    assert(fs.remove(root .. "/down"))
    local out, code = pomb_dev(root, home, { "board", "sync" })
    t.eq(code, 0, out)
    t.eq(out, "synced move aaaaaaaa\nsynced note bbbbbbbb\nsynced add Later\nsynced\n")
    t.eq(fs.exists(queue_path(home)), false)
    local log = calls(root)
    local move = assert(log:find("POST [^\n]*/move", 1))
    local note = assert(log:find("POST [^\n]*/comments", 1))
    local add = assert(log:find("POST [^\n]*/api/tasks\n", 1))
    t.ok(move < note and note < add, log)
    out = pomb_dev(root, home, { "board", "sync" })
    t.eq(out, "nothing queued\n")
end)

t.test("a replay Pomb refuses is reported and dropped, the rest still go", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", "deadbeef", "review" })
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "still goes" })
    assert(fs.remove(root .. "/down"))
    local out, code = pomb_dev(root, home, { "board", "sync" })
    t.eq(code, 0, out)
    t.ok(out:find("dropped move deadbeef: no card starts with deadbeef", 1, true), out)
    t.ok(out:find("synced note aaaaaaaa", 1, true), out)
    t.eq(fs.exists(queue_path(home)), false)
end)

t.test("a sync that finds Pomb still down keeps every change queued", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "second" })
    local out, code = pomb_dev(root, home, { "board", "sync" })
    t.eq(code, 1)
    t.eq(out, "Pomb is still unreachable, move aaaaaaaa stays queued\nqueued: 2\n")
    t.eq(#document(queue_path(home)), 2)
end)

t.test("any pomb command syncs a waiting queue first", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "waiting" })
    assert(fs.remove(root .. "/down"))
    local out, code = pomb_dev(root, home, { "board", "ls" })
    t.eq(code, 0, out)
    t.ok(out:find("synced note aaaaaaaa", 1, true), out)
    t.ok(out:find("First", 1, true), out)
    t.eq(fs.exists(queue_path(home)), false)
    local log = calls(root)
    t.ok(log:find("POST [^\n]*/comments\nGET [^\n]*/export%-data\n$"), log)
end)

t.test("status syncs a waiting queue and reports what is left", function()
    local root, home = pomb()
    assert(fs.write(root .. "/down", ""))
    pomb_dev(root, home, { "board", "note", ID_A:sub(1, 8), "waiting" })
    local out = pomb_dev(root, home, { "board", "status" })
    t.eq(
        out,
        "backend: pomb\nboard: dotfiles\nPomb is still unreachable, note aaaaaaaa stays queued\nqueued: 1\n"
    )
end)

local function bad_queue(text)
    local root, home = pomb()
    assert(fs.mkdir(home .. "/state/dev/boards", { parents = true }))
    assert(fs.write(queue_path(home), text))
    return root, home
end

t.test("sync on a malformed queue is an error that names the line and keeps the file", function()
    local root, home = bad_queue('[{"sub":"move",\n"args":["aaaaaaaa" "review"]}]\n')
    local out, code = pomb_dev(root, home, { "board", "sync" })
    t.eq(code, 1)
    t.ok(out:find(queue_path(home) .. ":2: ", 1, true), out)
    t.ok(out:find("left in place", 1, true), out)
    t.ok(not out:find("nothing queued", 1, true), out)
    t.ok(assert(fs.read(queue_path(home))):find('"review"]}]', 1, true))
    t.eq(calls(root), "")
end)

t.test("a queue that is not a list of commands is malformed", function()
    local root, home = bad_queue('{"sub":"move"}\n')
    local out, code = pomb_dev(root, home, { "board", "sync" })
    t.eq(code, 1)
    t.ok(out:find(":1: not a list of queued commands", 1, true), out)
    root, home = bad_queue('[{"sub":"move","args":["a"]},"oops"]\n')
    out, code = pomb_dev(root, home, { "board", "sync" })
    t.eq(code, 1)
    t.ok(out:find("entry 2 is not a queued command", 1, true), out)
end)

t.test("another command warns about a malformed queue, runs and keeps the file", function()
    local root, home = bad_queue("not json")
    local out, code = pomb_dev(root, home, { "board", "ls" })
    t.eq(code, 0, out)
    t.ok(out:find(queue_path(home) .. ":1: ", 1, true), out)
    t.ok(out:find("First", 1, true), out)
    t.eq(assert(fs.read(queue_path(home))), "not json")
    out, code = pomb_dev(root, home, { "board", "status" })
    t.eq(code, 0, out)
    t.ok(out:find("left in place", 1, true), out)
    t.eq(assert(fs.read(queue_path(home))), "not json")
end)

t.test("a write that cannot reach Pomb does not overwrite a malformed queue", function()
    local root, home = bad_queue("not json")
    assert(fs.write(root .. "/down", ""))
    local out, code = pomb_dev(root, home, { "board", "move", ID_A:sub(1, 8), "review" })
    t.eq(code, 1, out)
    t.ok(out:find("could not be queued", 1, true), out)
    t.eq(assert(fs.read(queue_path(home))), "not json")
end)

t.test("a local board never queues", function()
    local root, home = local_board()
    dev(root, home, { "board", "add", "One" })
    t.eq(fs.exists(home .. "/state/dev/boards/mine.queue"), false)
end)
