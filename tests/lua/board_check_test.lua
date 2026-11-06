local t = require("testing")
local board = require("dev.board")
local check = require("dev.board.check")
local commands = require("dev.cmd.board")
local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local has_jj = devos.which("jj") ~= nil
local IDENT = { JJ_USER = "t", JJ_EMAIL = "t@example.com" }

local function setup()
    local root = support.sandbox(
        { [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "mine"\n' },
        {}
    )
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(fs.write(home .. "/.config/dev/config.toml", ""))
    return root, home
end

local function dev(root, home, args, cwd)
    local env = {
        HOME = home,
        XDG_STATE_HOME = home .. "/state",
        JJ_USER = "t",
        JJ_EMAIL = "t@example.com",
    }
    return support.dev(root, args, { env = env, cwd = cwd })
end

local function must(first, second)
    local code = type(first) == "number" and first or second
    assert(code == 0, tostring(first))
end

local function card_with(root, home, rows)
    must(dev(root, home, { "board", "init" }))
    local out = dev(
        root,
        home,
        { "board", "add", "Card", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
    local id = assert(out:match("added (%x+)"), out)
    local args = { "board", "checks", id }
    for _, row in ipairs(rows) do
        args[#args + 1] = row
    end
    must(dev(root, home, args))
    return id
end

local function git_root()
    local root, home = setup()
    local function git(...)
        local argv =
            { "git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@example.com", ... }
        must(devos.run(argv, { stdout = "null" }))
    end
    must(devos.run({ "git", "init", "-q", root }, { stdout = "null" }))
    git("add", "-A")
    git("commit", "-q", "-m", "base")
    local head = devos.capture({ "git", "-C", root, "rev-parse", "HEAD" }):gsub("\n$", "")
    return root, home, head
end

local function comments(home)
    local doc = assert(json.decode(assert(fs.read(home .. "/state/dev/boards/mine.json"))))
    return doc.cards[1].comments or {}
end

t.test("a row is split into words and a shell character is refused", function()
    t.eq(check.argv("dev --remote  lint"), { "dev", "--remote", "lint" })
    for _, row in ipairs({
        "a; b",
        "a | b",
        "a && b",
        "echo $(x)",
        "echo `x`",
        "a > f",
        "a 'b'",
        "a\nb",
    }) do
        local argv, why = check.argv(row)
        t.eq(argv, nil, row)
        t.ok(why:find("only a shell reads", 1, true), why)
    end
    t.eq(check.argv("  "), nil)
end)

t.test("checks refuses a row with a shell character", function()
    for _, char in ipairs({
        "|",
        "&",
        ";",
        "<",
        ">",
        "(",
        ")",
        "$",
        "`",
        "\\",
        '"',
        "'",
        "*",
        "?",
        "!",
        "\n",
    }) do
        local row = "rg a" .. char .. "b"
        t.ok(check.refusal(row):find("only a shell reads", 1, true), row)
        t.eq(check.argv(row), nil, row)
    end
    t.eq(check.refusal("! rg -q a b"), nil)
    t.eq(check.argv("! rg -q a b"), { "rg", "-q", "a", "b" })
    t.ok(check.refusal("! rg a|b"), "a negated row keeps the refusal")
end)

t.test("checks refuses a dotted first word", function()
    local why = check.refusal("dev.--remote.lint")
    t.ok(why:find("dev.--remote.lint", 1, true), why)
    t.ok(check.refusal("! dev.--remote.lint"))
    t.eq(check.argv("dev.--remote.lint"), nil)
    t.eq(check.refusal("tests/a.b.sh x"), nil)
    t.eq(check.refusal("rg a.b.c file"), nil)
    t.eq(check.refusal("dev --remote lint"), nil)
end)

t.test("a negated row passes on no match, fails on a match and fails as an error", function()
    local root = support.tempdir()
    assert(fs.write(root .. "/hit.txt", "needle\n"))
    assert(fs.write(root .. "/miss.txt", "hay\n"))
    local function ran(row)
        local argv = assert(check.argv(row))
        return check.run({ root = root, run = row, argv = argv, seconds = 30 })
    end
    local row = ran("! grep -q needle miss.txt")
    t.eq(row.result, "pass")
    t.eq(row.code, 1)
    row = ran("! grep -q needle hit.txt")
    t.eq(row.result, "fail")
    t.ok(row.tail:find("a match was found", 1, true), row.tail)
    row = ran("! grep -q needle absent.txt")
    t.eq(row.result, "fail")
    t.eq(row.code, 2)
    t.ok(row.tail:find("is an error", 1, true), row.tail)
    t.eq(check.argv("! grep -q needle miss.txt"), { "grep", "-q", "needle", "miss.txt" })
    for _, bad in ipairs({ "grep ! needle miss.txt", "! grep -q ! miss.txt", "!grep x y" }) do
        local argv, why = check.argv(bad)
        t.eq(argv, nil, bad)
        t.ok(why:find("only a shell reads", 1, true), why)
    end
    t.eq(check.argv("!"), nil)
end)

t.test("the reserved prefix is found whatever its case and leading space", function()
    t.ok(board.reserved("dev-check: commit=x"))
    t.ok(board.reserved("  DEV-CHECK: x"))
    t.eq(board.reserved("Tests pass, dev-check: fine"), false)
end)

t.test("check records each row and the commit, and the run is clean in git", function()
    local root, home, head = git_root()
    local id = card_with(root, home, { "true", "false" })
    local out, code = dev(root, home, { "board", "check", id })
    t.eq(code, 1, out)
    t.ok(out:find("1 pass - true", 1, true) and out:find("2 fail - false", 1, true), out)
    t.ok(out:find("recorded on " .. id .. " at commit " .. head:sub(1, 12), 1, true), out)
    local body = comments(home)[1].body
    t.eq(body, "dev-check: commit=" .. head .. " change=- mode=run\n1 pass - true\n2 fail - false")
    t.eq(comments(home)[1].kind, "status")
    must(dev(root, home, { "board", "checks", id, "true" }))
    out, code = dev(root, home, { "board", "check", id })
    t.eq(code, 0, out)
    t.eq(#comments(home), 2)
end)

t.test("check records the ci run id each row printed", function()
    local root, home, head = git_root()
    local id = card_with(root, home, { "echo run 8cb600", "echo run 1f2e3d" })
    local out, code = dev(root, home, { "board", "check", id })
    t.eq(code, 0, out)
    t.ok(out:find("1 pass 8cb600 echo run 8cb600", 1, true), out)
    t.ok(out:find("2 pass 1f2e3d echo run 1f2e3d", 1, true), out)
    local record = check.parse(comments(home)[1].body)
    t.eq(record.commit, head)
    t.eq(record.rows, {
        { result = "pass", run_id = "8cb600", run = "echo run 8cb600" },
        { result = "pass", run_id = "1f2e3d", run = "echo run 1f2e3d" },
    })
end)

t.test("check labels the ci run of a row as repo/check/card", function()
    local root, home = git_root()
    local id = card_with(root, home, { "! printenv DEV_CI_VERB DEV_CI_CARD" })
    local out = dev(root, home, { "board", "check", id })
    t.ok(out:find("    check\n    " .. id, 1, true), out)
end)

t.test("check refuses a dirty git tree and records nothing", function()
    local root, home = git_root()
    local id = card_with(root, home, { "true" })
    assert(fs.write(root .. "/stray", "x"))
    local out, code = dev(root, home, { "board", "check", id })
    t.eq(code, 1, out)
    t.ok(out:find("working copy is dirty", 1, true), out)
    t.eq(#comments(home), 0)
end)

t.test("check refuses a tree that changed while the rows ran", function()
    local root, home = git_root()
    local id = card_with(root, home, { "touch moved" })
    local out, code = dev(root, home, { "board", "check", id })
    t.eq(code, 1, out)
    t.ok(
        out:find("NOT recorded", 1, true) and out:find("changed while the checks ran", 1, true),
        out
    )
    t.eq(#comments(home), 0)
end)

t.test("check runs a row as a plain command and never through a shell", function()
    local root, home = git_root()
    local id = card_with(root, home, { "true" })
    local path = home .. "/state/dev/boards/mine.json"
    local doc = assert(json.decode(assert(fs.read(path))))
    doc.cards[1].checks = { "touch marker; true" }
    assert(fs.write(path, json.encode(doc)))
    local out, code = dev(root, home, { "board", "check", id })
    t.eq(code, 1, out)
    t.ok(out:find("only a shell reads", 1, true), out)
    t.eq(fs.exists(root .. "/marker"), false)
    t.eq(#comments(home), 0)
end)

t.test("check ends a row at the time limit and records a timeout", function()
    local root, home = git_root()
    local id = card_with(root, home, { "sleep 30" })
    local out, code = dev(root, home, { "board", "check", id, "--timeout", "1" })
    t.eq(code, 1, out)
    t.eq(comments(home)[1].body:match("\n(.*)$"), "1 timeout - sleep 30")
    out, code = dev(root, home, { "board", "check", id, "--timeout", "0" })
    t.eq(code, 2, out)
end)

t.test("the default row limit is two hours and within the most --timeout accepts", function()
    t.eq(check.DEFAULT_SECONDS, 7200)
    t.ok(check.DEFAULT_SECONDS <= check.MAX_SECONDS)
end)

t.test("--expect-fail records failing rows and reports a passing one", function()
    local root, home, head = git_root()
    local id = card_with(root, home, { "false" })
    local out, code = dev(root, home, { "board", "check", id, "--expect-fail" })
    t.eq(code, 0, out)
    t.eq(
        comments(home)[1].body,
        "dev-check: commit=" .. head .. " change=- mode=expect-fail\n1 fail - false"
    )
    must(dev(root, home, { "board", "checks", id, "true", "false" }))
    out, code = dev(root, home, { "board", "check", id, "--expect-fail" })
    t.eq(code, 1, out)
    t.ok(out:find("the passing ones prove nothing", 1, true), out)
    must(dev(root, home, { "board", "checks", id, "true" }))
    out, code = dev(root, home, { "board", "check", id, "--expect-fail" })
    t.eq(code, 1, out)
    t.ok(out:find("the passing ones prove nothing", 1, true), out)
    t.eq(#comments(home), 3)
end)

t.test("note refuses the reserved prefix, and the record cannot be edited or deleted", function()
    local root, home = git_root()
    local id = card_with(root, home, { "true" })
    local out, code = dev(root, home, { "board", "note", id, "dev-check:", "commit=x" })
    t.eq(code, 1, out)
    t.ok(out:find("dev-check:", 1, true) and out:find("dev board check writes", 1, true), out)
    t.eq(#comments(home), 0)
    must(dev(root, home, { "board", "check", id }))
    local first = assert(dev(root, home, { "board", "notes", id }):match("^(%x+)"))
    out, code = dev(root, home, { "board", "note", id, "--edit", first, "fine" })
    t.eq(code, 1, out)
    out, code = dev(root, home, { "board", "note", id, "--delete", first })
    t.eq(code, 1, out)
    must(dev(root, home, { "board", "note", id, "plain" }))
    local second = assert(dev(root, home, { "board", "notes", id }):match("\n(%x+)"))
    out, code = dev(root, home, { "board", "note", id, "--edit", second, "dev-check: forged" })
    t.eq(code, 1, out)
    t.eq(#comments(home), 2)
end)

t.test("a result that cannot be written is never reported as recorded", function()
    local root = git_root()
    local card = {
        id = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        name = "Card",
        column = "In Progress",
        size = "unsized",
        labels = {},
        checks = { "true" },
        outcomes = {},
    }
    local backend = { root = root }
    function backend:done_columns()
        return { "Done" }
    end
    function backend:cards()
        return { card }
    end
    function backend:note()
        return nil, "curl exit 28"
    end
    local result = commands.run("check", { "11111111" }, backend)
    t.eq(result.output, nil)
    t.eq(result.code, 1)
    t.ok(result.message:find("was NOT recorded", 1, true), result.message)
    t.ok(result.message:find("curl exit 28", 1, true), result.message)
    t.ok(result.message:find("1 pass - true", 1, true), result.message)
    t.eq(result.unqueued, nil)
end)

if has_jj then
    local function jj(root, ...)
        local argv = { "jj", "--no-pager", "--color", "never", "-R", root, ... }
        local out, code = devos.capture(argv, { stderr = "null", env = IDENT })
        assert(code == 0, out)
        return out
    end

    local function workspace()
        local root, home = setup()
        local init = { stdout = "null", stderr = "null", env = IDENT }
        must(devos.run({ "jj", "git", "init", root }, init))
        jj(root, "commit", "-m", "base")
        local ws = assert(fs.realpath(support.tempdir())) .. "/ws"
        jj(root, "workspace", "add", "--name", "w2", "-r", "@-", ws)
        return root, home, ws
    end

    t.test("check refuses outside the workspace named for the card", function()
        local root, home, ws = workspace()
        local id = card_with(root, home, { "true" })
        local out, code = dev(root, home, { "board", "check", id }, ws)
        t.eq(code, 1, out)
        t.ok(out:find("w2", 1, true), out)
        t.ok(out:find("dev ws new " .. id, 1, true), out)
        t.eq(#comments(home), 0)
    end)

    t.test("in a jj workspace the working-copy commit is the commit, edits included", function()
        local root, home, ws = workspace()
        local id = card_with(root, home, { "true" })
        jj(ws, "workspace", "rename", id)
        assert(fs.write(ws .. "/edited", "x"))
        local out, code = dev(root, home, { "board", "check", id }, ws)
        t.eq(code, 0, out)
        local want = jj(ws, "log", "-r", "@", "--no-graph", "-T", "commit_id ++ ' ' ++ change_id")
        local commit, change = want:match("^(%x+) (%a+)")
        t.eq(
            comments(home)[1].body,
            "dev-check: commit=" .. commit .. " change=" .. change .. " mode=run\n1 pass - true"
        )
        t.ok(out:find(commit:sub(1, 12), 1, true), out)
    end)

    t.test("in a jj workspace a row that edits files leaves nothing recorded", function()
        local root, home, ws = workspace()
        local id = card_with(root, home, { "touch made" })
        jj(ws, "workspace", "rename", id)
        local out, code = dev(root, home, { "board", "check", id }, ws)
        t.eq(code, 1, out)
        t.ok(out:find("changed while the checks ran", 1, true), out)
        t.eq(#comments(home), 0)
    end)
end

t.test("the claimant's note is found by the token that posted the claim", function()
    local STATUS, DECISION = board.NoteKind.STATUS, board.NoteKind.DECISION
    local function note(who, body, kind)
        return { who = who, body = body, kind = kind }
    end
    local claim = note("agents", board.claim_record("r/one"), STATUS)
    local function noted(...)
        return board.noted_since_claim({ ... }, "r/one")
    end
    t.eq(noted(note("agents", "built it")), nil)
    t.eq(noted(claim), false)
    t.eq(noted(claim, note("agents", "[dev agent] done")), true)
    t.eq(noted(note("agents", "early"), claim), false)
    t.eq(noted(claim, note("other", "built it")), false)
    t.eq(noted(claim, note("agents", "ruled", DECISION)), false)
    t.eq(noted(claim, note("agents", "dev-check: x", STATUS)), false)
    t.eq(noted(claim, note("agents", "dev-review: x", STATUS)), false)
    t.eq(noted(claim, note("agents", "old"), claim), false)
end)
