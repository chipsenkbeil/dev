local t = require("testing")
local board = require("dev.board")
local commands = require("dev.cmd.board")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local TOKEN = "pomb_SECRETtoken0123456789"
local ID_A = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
local ID_B = "11111111-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
local ID_C = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

local function executable(path, body)
    assert(fs.write(path, body))
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function fake(cards)
    local calls = {}
    local backend = { calls = calls }
    function backend:describe()
        return "fake"
    end
    function backend:cards()
        return cards
    end
    function backend:next()
        return cards[1]
    end
    function backend:add(name, column, description)
        calls[#calls + 1] = { "add", name, column, description }
        return { id = ID_C, name = name, column = column, size = "unsized", labels = {} }
    end
    function backend:note(id, text)
        calls[#calls + 1] = { "note", id, text }
        return true
    end
    function backend:move(id, column)
        calls[#calls + 1] = { "move", id, column }
        return true
    end
    return backend
end

local function sample()
    return {
        {
            id = ID_A,
            name = "Write docs",
            column = "Ready",
            size = "1 Pomodoro",
            labels = { "docs" },
        },
        { id = ID_B, name = "Fix lint", column = "Backlog", size = "unsized", labels = {} },
        { id = ID_C, name = "Old thing", column = "Done", size = "unsized", labels = {} },
    }
end

t.test("column takes the names and the short forms in any case", function()
    t.eq(board.column("ready"), "Ready")
    t.eq(board.column("PROGRESS"), "In Progress")
    t.eq(board.column("in  review"), "In Review")
    t.eq(board.column("review"), "In Review")
    for _, short in ipairs({ "blocked", "done", "backlog", "icebox" }) do
        t.eq(board.column(short):lower(), short)
    end
    t.eq(board.column("doing"), nil)
end)

t.test("resolve takes a unique prefix of at least 8 characters", function()
    local cards = sample()
    t.eq(board.resolve(cards, "11111111-a").id, ID_A)
    t.eq(board.resolve(cards, ID_B).id, ID_B)
    t.eq(board.resolve(cards, "CCCCCCCC").id, ID_C)
end)

t.test("resolve refuses a short, unknown or ambiguous prefix", function()
    local cards = sample()
    local card, message = board.resolve(cards, "1111111")
    t.eq(card, nil)
    t.ok(message:find("at least 8", 1, true), message)
    card, message = board.resolve(cards, "11111111")
    t.eq(card, nil)
    t.ok(message:find("more than one card", 1, true), message)
    card, message = board.resolve(cards, "deadbeef")
    t.eq(card, nil)
    t.ok(message:find("no card starts with deadbeef", 1, true), message)
    card, message = board.resolve(cards, "zzzzzzzz")
    t.eq(card, nil)
    t.ok(message:find("hex", 1, true), message)
end)

t.test("ls hides Done and aligns the columns", function()
    local result = commands.run("ls", {}, fake(sample()))
    t.eq(
        result.output,
        "11111111  Ready    1 Pomodoro  docs  Write docs\n11111111  Backlog  unsized     -     Fix lint"
    )
end)

t.test("ls filters by column and label", function()
    local result = commands.run("ls", { "--column", "done" }, fake(sample()))
    t.eq(result.output, "cccccccc  Done  unsized  -  Old thing")
    result = commands.run("ls", { "--label", "docs" }, fake(sample()))
    t.eq(result.output, "11111111  Ready  1 Pomodoro  docs  Write docs")
    result = commands.run("ls", { "--label", "none" }, fake(sample()))
    t.eq(result.output, "no cards")
end)

t.test("ls refuses an unknown column and an unknown flag with a usage error", function()
    local result = commands.run("ls", { "--column", "doing" }, fake(sample()))
    t.eq(result.code, 2)
    t.ok(result.message:find("unknown column doing", 1, true), result.message)
    result = commands.run("ls", { "--bogus" }, fake(sample()))
    t.eq(result.code, 2)
    result = commands.run("ls", { "--column" }, fake(sample()))
    t.eq(result.code, 2)
end)

t.test("add defaults to Backlog and joins the words of the name", function()
    local backend = fake(sample())
    local result = commands.run("add", { "A", "new", "card" }, backend)
    t.eq(result.output, "added cccccccc Backlog")
    t.eq(backend.calls[1], { "add", "A new card", "Backlog", nil })
    result = commands.run("add", { "X", "--column", "ready", "--description", "why" }, backend)
    t.eq(backend.calls[2], { "add", "X", "Ready", "why" })
    t.eq(commands.run("add", {}, backend).code, 2)
end)

t.test("note and move resolve the card by prefix", function()
    local backend = fake(sample())
    local result = commands.run("note", { "cccccccc", "landed", "as", "abc" }, backend)
    t.eq(result.output, "noted cccccccc")
    t.eq(backend.calls[1], { "note", ID_C, "landed as abc" })
    result = commands.run("move", { "cccccccc", "progress" }, backend)
    t.eq(result.output, "moved cccccccc to In Progress")
    t.eq(backend.calls[2], { "move", ID_C, "In Progress" })
    result = commands.run("move", { "cccccccc", "in", "review" }, backend)
    t.eq(backend.calls[3], { "move", ID_C, "In Review" })
end)

t.test("move and note refuse before the backend is called", function()
    local backend = fake(sample())
    local result = commands.run("move", { "cccccccc", "doing" }, backend)
    t.eq(result.code, 2)
    result = commands.run("move", { "deadbeef", "ready" }, backend)
    t.eq(result.code, 1)
    result = commands.run("note", { "cccccccc" }, backend)
    t.eq(result.code, 2)
    t.eq(#backend.calls, 0)
end)

t.test("next shows the top card or says none", function()
    local result = commands.run("next", {}, fake(sample()))
    t.eq(result.output, "11111111  Ready  1 Pomodoro  docs  Write docs")
    result = commands.run("next", {}, fake({}))
    t.eq(result.output, "no ready cards")
end)

local BOARDS = '[{"id":"board-1","name":"dotfiles","archived":false}]'
local DETAIL = '{"id":"board-1","name":"dotfiles","swimlanes":[],"columns":['
    .. '{"id":"col-icebox","name":"Icebox"},{"id":"col-backlog","name":"Backlog"},'
    .. '{"id":"col-ready","name":"Ready"},{"id":"col-progress","name":"In Progress"},'
    .. '{"id":"col-review","name":"In Review"},{"id":"col-blocked","name":"Blocked"},'
    .. '{"id":"col-done","name":"Done"}]}'
local COLORS = '[{"id":"yellow-id","label":"1 Pomodoro"},{"id":"white-id","label":"Unsized"}]'
local EXPORT = '{"tasks":['
    .. '{"id":"'
    .. ID_B
    .. '","name":"Second","column_id":"col-ready","position":2,"color_id":null,"labels":[]},'
    .. '{"id":"'
    .. ID_A
    .. '","name":"First","column_id":"col-ready","position":1,"color_id":"yellow-id","labels":["docs"]},'
    .. '{"id":"'
    .. ID_C
    .. '","name":"Early","column_id":"col-backlog","position":1,"color_id":"white-id","labels":[]}]}'
local TASK = '{"id":"'
    .. ID_A
    .. '","name":"First","column_id":"col-ready","color_id":"yellow-id","labels":["docs"]}'

local CURL = [[#!/bin/sh
printf 'curl %s\n' "$*" >>"$ROOT/calls"
cat >"$ROOT/stdin"
for last; do :; done
case "$last" in
*/api/boards) body=$(cat "$ROOT/boards.json") ;;
*/api/boards/board-1) body=$(cat "$ROOT/detail.json") ;;
*/colors) body=$(cat "$ROOT/colors.json") ;;
*/export-data) body=$(cat "$ROOT/export.json") ;;
*/tasks\?*) body='{"items":[{"id":"]] .. ID_A .. [["}],"next_cursor":null}' ;;
*/api/tasks/]] .. ID_A .. [[) body=$(cat "$ROOT/task.json") ;;
*/api/tasks) body=$(cat "$ROOT/task.json") ;;
*) body='{"ok":true}' ;;
esac
printf '%s\n%s' "$body" "${HTTP_STATUS:-200}"
]]

local function sandbox(opts)
    opts = opts or {}
    local root = support.sandbox({
        [".dev/config.toml"] = opts.project or '[board]\nbackend = "pomb"\nname = "dotfiles"\n',
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(
        fs.write(
            home .. "/.config/dev/config.toml",
            opts.user
                or '[board.pomb]\nurl = "https://pomb.example"\ntoken = "pass:secrets/worker/token/pomb"\n'
        )
    )
    for name, body in pairs({
        ["boards.json"] = BOARDS,
        ["detail.json"] = DETAIL,
        ["colors.json"] = COLORS,
        ["export.json"] = EXPORT,
        ["task.json"] = TASK,
    }) do
        assert(fs.write(root .. "/" .. name, body))
    end
    executable(root .. "/bin/curl", CURL)
    executable(
        root .. "/bin/pass",
        '#!/bin/sh\nprintf "pass %s opts=%s\\n" "$*" "$PASSWORD_STORE_GPG_OPTS" >>"$ROOT/calls"\n'
            .. (opts.locked and "exit 1\n" or ('echo "' .. TOKEN .. '"\n'))
    )
    return root, home
end

local function dev(root, home, args)
    return support.dev(root, args, { env = { HOME = home, ROOT = root } })
end

local function read(root, name)
    return fs.read(root .. "/" .. name) or ""
end

t.test("every subcommand without a [board] section says so and exits 1", function()
    local root, home = sandbox({ project = "" })
    for _, args in ipairs({ { "board", "status" }, { "board", "ls" }, { "board", "next" } }) do
        local out, code = dev(root, home, args)
        t.eq(out, "dev: no board for this project\n")
        t.eq(code, 1)
    end
    t.eq(read(root, "calls"), "")
end)

t.test("status prints the backend and the board without reaching out", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "status" })
    t.eq(out, "backend: pomb\nboard: dotfiles\n")
    t.eq(code, 0)
    t.eq(read(root, "calls"), "")
end)

t.test("the board name defaults to the project directory", function()
    local root, home = sandbox({ project = '[board]\nbackend = "pomb"\n' })
    local out = dev(root, home, { "board", "status" })
    t.eq(out, "backend: pomb\nboard: " .. fs.basename(root) .. "\n")
end)

t.test("a local backend is a clear error for now", function()
    local root, home = sandbox({ project = '[board]\nbackend = "local"\n' })
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(out, "dev: the local board backend is not built yet\n")
    t.eq(code, 1)
    out, code = dev(root, home, { "board", "status" })
    t.eq(out, "backend: local\nboard: " .. fs.basename(root) .. "\n")
end)

t.test("an unknown backend is refused", function()
    local root, home = sandbox({ project = '[board]\nbackend = "jira"\n' })
    local out, code = dev(root, home, { "board", "status" })
    t.ok(out:find('must be "pomb" or "local"', 1, true), out)
    t.eq(code, 1)
end)

t.test("ls lists the cards in column order through pass and curl", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 0)
    t.eq(
        out,
        "cccccccc  Backlog  Unsized     -     Early\n"
            .. "11111111  Ready    1 Pomodoro  docs  First\n"
            .. "11111111  Ready    unsized     -     Second\n"
    )
    local calls = read(root, "calls")
    t.ok(
        calls:find(
            "pass show secrets/worker/token/pomb opts=--pinentry-mode error --batch",
            1,
            true
        ),
        calls
    )
    t.ok(calls:find("https://pomb.example/api/boards/board-1/export-data", 1, true), calls)
end)

t.test("the token reaches curl on stdin and nowhere else", function()
    local root, home = sandbox()
    local out = dev(root, home, { "-vv", "board", "ls" })
    t.eq(read(root, "stdin"), 'header = "Authorization: Bearer ' .. TOKEN .. '"\n')
    t.eq(out:find(TOKEN, 1, true), nil)
    t.eq(read(root, "calls"):find(TOKEN, 1, true), nil)
    t.ok(read(root, "calls"):find("-K -", 1, true), read(root, "calls"))
    out = dev(root, home, { "-v", "board", "move", "11111111-a", "done" })
    t.eq(out:find(TOKEN, 1, true), nil)
end)

t.test("the token is not in the environment curl or pass is started with", function()
    local root, home = sandbox()
    executable(root .. "/bin/curl", (CURL:gsub("cat >", 'env >"$ROOT/env"\ncat >', 1)))
    dev(root, home, { "board", "ls" })
    t.eq(read(root, "env"):find(TOKEN, 1, true), nil)
end)

t.test("a locked store fails at once and curl never runs", function()
    local root, home = sandbox({ locked = true })
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("board unavailable: pass is locked", 1, true), out)
    t.eq(read(root, "calls"):find("curl", 1, true), nil)
end)

t.test("a token that is not plain text is refused without echoing it", function()
    local root, home = sandbox()
    executable(root .. "/bin/pass", "#!/bin/sh\necho 'bad token\"; evil'\n")
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("empty or not plain text", 1, true), out)
    t.eq(out:find("evil", 1, true), nil)
end)

t.test("a project config cannot choose the server or the token", function()
    local root, home = sandbox({
        project = '[board]\nbackend = "pomb"\nname = "dotfiles"\n'
            .. '[board.pomb]\nurl = "https://evil.example"\ntoken = "pass:Other/entry"\n',
    })
    dev(root, home, { "board", "ls" })
    local calls = read(root, "calls")
    t.eq(calls:find("evil", 1, true), nil)
    t.eq(calls:find("Other/entry", 1, true), nil)
    t.ok(calls:find("pomb.example", 1, true), calls)
end)

t.test("a missing user url or token reference is a plain error", function()
    local root, home = sandbox({ user = "" })
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("[board.pomb] url", 1, true), out)
    root, home =
        sandbox({ user = '[board.pomb]\nurl = "https://pomb.example"\ntoken = "$(pass x)"\n' })
    out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("pass:<entry>", 1, true), out)
    t.eq(read(root, "calls"), "")
end)

t.test("an http error reports the server's message", function()
    local root, home = sandbox()
    executable(
        root .. "/bin/curl",
        '#!/bin/sh\ncat >/dev/null\nprintf \'{"code":"x","message":"nope"}\\n403\'\n'
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("board unavailable: pomb answered 403: nope", 1, true), out)
end)

t.test("an unreachable server reports the curl exit", function()
    local root, home = sandbox()
    executable(root .. "/bin/curl", "#!/bin/sh\ncat >/dev/null\nexit 7\n")
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(
        out:find("board unavailable: cannot reach https://pomb.example (curl exit 7)", 1, true),
        out
    )
end)

t.test("next asks for the unclaimed unblocked top of Ready", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "board", "next" })
    t.eq(code, 0)
    t.eq(out, "11111111  Ready  1 Pomodoro  docs  First\n")
    t.ok(
        read(root, "calls"):find(
            "/api/boards/board-1/tasks?limit=1&ready=true&claimed=false&column_id=col-ready",
            1,
            true
        ),
        read(root, "calls")
    )
end)

t.test("add posts the card to the named column", function()
    local root, home = sandbox()
    local out, code =
        dev(root, home, { "board", "add", "New card", "--column", "ready", "--description", "why" })
    t.eq(code, 0)
    t.eq(out, "added 11111111 Ready\n")
    local calls = read(root, "calls")
    t.ok(calls:find("-X POST", 1, true), calls)
    t.ok(
        calls:find(
            '--data-raw {"name":"New card","column_id":"col-ready","description":"why"}',
            1,
            true
        ) or calls:find('"column_id":"col-ready"', 1, true),
        calls
    )
end)

t.test("note posts a comment of kind agent and move goes to the top of the column", function()
    local root, home = sandbox()
    local out = dev(root, home, { "board", "note", "11111111-a", "landed", "it" })
    t.eq(out, "noted 11111111\n")
    local calls = read(root, "calls")
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/comments", 1, true), calls)
    t.ok(calls:find('"kind":"agent"', 1, true), calls)
    out = dev(root, home, { "board", "move", "11111111-a", "review" })
    t.eq(out, "moved 11111111 to In Review\n")
    calls = read(root, "calls")
    t.ok(calls:find("/api/tasks/" .. ID_A .. "/move", 1, true), calls)
    t.ok(calls:find('"column_id":"col-review"', 1, true), calls)
    t.ok(calls:find('"position":0', 1, true), calls)
end)

t.test("a nonexistent column on the board is reported", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/detail.json", '{"id":"board-1","name":"dotfiles","columns":[]}'))
    local out, code = dev(root, home, { "board", "add", "x" })
    t.eq(code, 1)
    t.ok(out:find("the board has no Backlog column", 1, true), out)
end)

t.test("board refuses --remote like the other machine-local nouns", function()
    local root, home = sandbox()
    local out, code = dev(root, home, { "--remote", "--", "board", "ls" })
    t.eq(code, 2)
    t.eq(out, "dev board ls: runs on this machine only, so --remote does not apply\n")
end)

t.test("capture_input hands the input to stdin and keeps it out of argv", function()
    local out, code = devos.capture_input({ "sh", "-c", "cat; echo done" }, "secret\n")
    t.eq(out, "secret\ndone\n")
    t.eq(code, 0)
    out, code = devos.capture_input({ "sh", "-c", "cat >/dev/null; exit 5" }, "x")
    t.eq(code, 5)
    t.raises(function()
        devos.capture_input({ "cat" }, "x", { stdout = "null" })
    end, "standard output")
end)

t.test("capture_input leaves no temporary file behind", function()
    local dir = support.tempdir()
    local script = string.format(
        "package.path = %q; local o = require('dev.os'); o.capture_input({'cat'}, 'x'); o.capture_input({'sh', '-c', 'cat >/dev/null; exit 3'}, 'x')",
        support.absolute_path()
    )
    local _, code = devos.capture({ "luajit", "-e", script }, { env = { TMPDIR = dir } })
    t.eq(code, 0)
    t.eq(fs.list(dir), {})
end)

t.test("a non-JSON answer from the server is reported as unreadable", function()
    local root, home = sandbox()
    executable(
        root .. "/bin/curl",
        "#!/bin/sh\ncat >/dev/null\nprintf '<html>bad gateway</html>\\n502'\n"
    )
    local out, code = dev(root, home, { "board", "ls" })
    t.eq(code, 1)
    t.ok(out:find("board unavailable: pomb sent an answer dev cannot read", 1, true), out)
end)

t.test("a note may begin with a dash", function()
    local backend = fake(sample())
    local result = commands.run("note", { "cccccccc", "- fixed", "it" }, backend)
    t.eq(backend.calls[1], { "note", ID_C, "- fixed it" })
    t.eq(result.output, "noted cccccccc")
end)
