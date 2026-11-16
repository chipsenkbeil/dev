local testing = require("dev.testing")
local board = require("dev.board")
local check = require("dev.board.check")
local cmd_board = require("dev.cmd.board")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local has_jj = dev_os.which("jj") ~= nil
local IDENT = { JJ_USER = "t", JJ_EMAIL = "t@example.com" }

local function setup(files)
    local all = { [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "mine"\n' }
    for name, text in pairs(files or {}) do
        all[name] = text
    end
    local root = support.sandbox(all, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(fs.write(home .. "/.config/dev/config.toml", ""))
    return root, home
end

local function dev(root, home, args, cwd, extra)
    local env = {
        HOME = home,
        XDG_STATE_HOME = home .. "/state",
        JJ_USER = "t",
        JJ_EMAIL = "t@example.com",
    }
    for name, value in pairs(extra or {}) do
        env[name] = value
    end
    return support.dev(root, args, { env = env, cwd = cwd })
end

local function must(first, second)
    local code = type(first) == "number" and first or second
    assert(code == 0, tostring(first))
end

local function card_with(root, home, rows)
    must(dev(root, home, { "board", "init" }))
    support.drop_turn_card(home .. "/state/dev/boards/mine.json")
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

local function git_root(files)
    local root, home = setup(files)
    local function git(...)
        local argv =
            { "git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@example.com", ... }
        must(dev_os.run(argv, { stdout = "null" }))
    end
    must(dev_os.run({ "git", "init", "-q", root }, { stdout = "null" }))
    git("add", "-A")
    git("commit", "-q", "-m", "base")
    local head = dev_os.capture({ "git", "-C", root, "rev-parse", "HEAD" }):gsub("\n$", "")
    return root, home, head
end

local function comments(home)
    local doc = assert(json.decode(assert(fs.read(home .. "/state/dev/boards/mine.json"))))
    return doc.cards[1].comments or {}
end

testing.test("a row is split into words and a shell character is refused", function()
    testing.eq(check.argv("dev --remote  lint"), { "dev", "--remote", "lint" })
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
        testing.eq(argv, nil, row)
        testing.ok(why:find("only a shell reads", 1, true), why)
    end
    testing.eq(check.argv("  "), nil)
end)

testing.test("checks refuses a row with a shell character", function()
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
        testing.ok(check.refusal(row):find("only a shell reads", 1, true), row)
        testing.eq(check.argv(row), nil, row)
    end
    testing.eq(check.refusal("! rg -q a b"), nil)
    testing.eq(check.argv("! rg -q a b"), { "rg", "-q", "a", "b" })
    testing.ok(check.refusal("! rg a|b"), "a negated row keeps the refusal")
end)

testing.test("checks refuses a dotted first word", function()
    local why = check.refusal("dev.--remote.lint")
    testing.ok(why:find("dev.--remote.lint", 1, true), why)
    testing.ok(check.refusal("! dev.--remote.lint"))
    testing.eq(check.argv("dev.--remote.lint"), nil)
    testing.eq(check.refusal("tests/a.b.sh x"), nil)
    testing.eq(check.refusal("rg a.b.c file"), nil)
    testing.eq(check.refusal("dev --remote lint"), nil)
end)

testing.test("checks refuses a bare test name", function()
    local why = check.refusal("dev --remote test parse")
    testing.ok(why:find("dev --remote test -- parse", 1, true), why)
    testing.ok(check.refusal("! dev --remote test parse"))
    testing.ok(check.refusal("dev test --remote parse"))
    testing.eq(check.refusal("dev --remote lint -v"), nil)
    testing.eq(check.refusal("dev --remote lint -vvv"), nil)
    testing.eq(check.refusal("dev --remote lint --verbose"), nil)
    testing.eq(check.refusal("dev --remote lint -C sub"), nil)
    testing.ok(check.refusal("dev -C sub --remote test parse"))
    testing.ok(check.refusal("dev test parse --remote"))
    testing.eq(check.refusal("dev test parse"), nil)
    testing.eq(check.refusal("dev --remote test"), nil)
    testing.eq(check.refusal("dev --remote test -- parse"), nil)
    testing.eq(check.refusal("dev --remote lint"), nil)
    testing.eq(check.refusal("rg -q parse tests/lua/a_test.lua"), nil)
end)

testing.test("a negated row passes on no match, fails on a match and fails as an error", function()
    local root = support.tempdir()
    assert(fs.write(root .. "/hit.txt", "needle\n"))
    assert(fs.write(root .. "/miss.txt", "hay\n"))
    local function ran(row)
        local argv = assert(check.argv(row))
        return check.run({ root = root, run = row, argv = argv, seconds = 30 })
    end
    local row = ran("! grep -q needle miss.txt")
    testing.eq(row.result, "pass")
    testing.eq(row.code, 1)
    row = ran("! grep -q needle hit.txt")
    testing.eq(row.result, "fail")
    testing.ok(row.tail:find("A match was found.", 1, true), row.tail)
    row = ran("! grep -q needle absent.txt")
    testing.eq(row.result, "fail")
    testing.eq(row.code, 2)
    testing.ok(row.tail:find("is an error", 1, true), row.tail)
    testing.eq(check.argv("! grep -q needle miss.txt"), { "grep", "-q", "needle", "miss.txt" })
    for _, bad in ipairs({ "grep ! needle miss.txt", "! grep -q ! miss.txt", "!grep x y" }) do
        local argv, why = check.argv(bad)
        testing.eq(argv, nil, bad)
        testing.ok(why:find("only a shell reads", 1, true), why)
    end
    testing.eq(check.argv("!"), nil)
end)

testing.test("the reserved prefix is found whatever its case and leading space", function()
    testing.ok(board.reserved("dev-check: commit=x"))
    testing.ok(board.reserved("  DEV-CHECK: x"))
    testing.eq(board.reserved("Tests pass, dev-check: fine"), false)
end)

testing.test("check records each row and the commit, and the run is clean in git", function()
    local root, home, head = git_root()
    local id = card_with(root, home, { "true", "false" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.ok(out:find("1 pass - true", 1, true) and out:find("2 fail - false", 1, true), out)
    testing.ok(out:find("recorded on " .. id .. " at commit " .. head:sub(1, 12), 1, true), out)
    local body = comments(home)[1].body
    testing.eq(
        body,
        "dev-check: commit="
            .. head
            .. " change=- mode=run rows=2 sum="
            .. check.fingerprint({ "true", "false" })
            .. "\n1 pass -\n2 fail -"
    )
    testing.eq(comments(home)[1].kind, "status")
    must(dev(root, home, { "board", "checks", id, "true" }))
    out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 0, out)
    testing.eq(#comments(home), 2)
end)

testing.test("check records the ci run id each row printed", function()
    local root, home, head = git_root()
    local id = card_with(root, home, { "echo run 8cb600", "echo run 1f2e3d" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 0, out)
    testing.ok(out:find("1 pass 8cb600 echo run 8cb600", 1, true), out)
    testing.ok(out:find("2 pass 1f2e3d echo run 1f2e3d", 1, true), out)
    local record = check.parse(comments(home)[1].body)
    testing.eq(record.commit, head)
    testing.eq(record.rows, {
        { result = "pass", run_id = "8cb600" },
        { result = "pass", run_id = "1f2e3d" },
    })
end)

testing.test("a 147 row check record stays under the pomb comment cap", function()
    local state = { commit = string.rep("a", 40), change = string.rep("k", 32) }
    local rows, commands = {}, {}
    for i = 1, 147 do
        commands[i] = "rg -n " .. string.rep("x", 250) .. i
        rows[i] = {
            result = "fail",
            run_id = "-",
            run = commands[i],
            reason = string.rep("a long reason ", 30),
        }
    end
    local body = check.record(state, rows, false)
    testing.ok(#body < 5000, #body)
    local record = check.parse(body)
    testing.eq(#record.rows, 147)
    testing.eq(record.sum, check.fingerprint(commands))
    for i = 1, 147 do
        rows[i].reason = nil
        rows[i].run_id = "007201"
        rows[i].result = "pass"
    end
    testing.ok(#check.record(state, rows, false) < 3000)
end)

testing.test("show lists a short check record", function()
    local root, home = git_root()
    local id = card_with(root, home, { "true", "echo run 8cb600" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "show", id })
    testing.eq(code, 0, out)
    testing.ok(out:find("rows=2 sum=", 1, true), out)
    testing.ok(out:find("2 pass 8cb600", 1, true), out)
end)

testing.test("check prints each row ci run id before the row finishes", function()
    local root, home = git_root()
    local id = card_with(root, home, { "echo run 8cb600", "echo run 1f2e3d" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 0, out)
    local first = out:find("row 1 run 8cb600", 1, true)
    local second = out:find("row 2 run 1f2e3d", 1, true)
    testing.ok(first and second, out)
    testing.ok(first < out:find("1 pass 8cb600", 1, true), out)
    testing.ok(second < out:find("2 pass 1f2e3d", 1, true), out)
end)

testing.test("check.run hands each ci run id to on_run_id before the row ends", function()
    local dir = support.tempdir()
    local seen = {}
    local row = check.run({
        root = dir,
        run = "row",
        argv = {
            "sh",
            "-c",
            "echo run 8cb600; echo run ffffff; while [ ! -e seen ]; do sleep 0.1; done",
        },
        seconds = 30,
        on_run_id = function(run_id)
            seen[#seen + 1] = run_id
            assert(fs.write(dir .. "/seen", "x"))
        end,
    })
    testing.eq(row.result, "pass")
    testing.eq(seen, { "8cb600" })
    testing.eq(row.run_id, "8cb600")
end)

testing.test("check records why a row failed without a run", function()
    local root, home, head = git_root()
    local id = card_with(root, home, { "ls dev-board-check-missing-path", "false" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    local record = check.parse(comments(home)[1].body)
    testing.eq(record.commit, head)
    testing.ok(record.rows[1].reason:find("dev-board-check-missing-path", 1, true), out)
    testing.eq(record.rows[1].run_id, "-")
    testing.eq(record.rows[2].reason, nil)
end)

local REFUSED_STUB = table.concat({
    "echo 'error: the hub is draining since 1m ago by agent:infra: protocol 67 deploy; running jobs finish and nothing new starts until `ci fleet drain off`' >&2",
    "exit 1",
}, "\n")
local TARGET_STUB = table.concat({
    "echo 'error: Target linux is draining since 1m ago by agent:infra. Running jobs finish and nothing new starts on it until `ci fleet drain off linux`.' >&2",
    "exit 1",
}, "\n")
local FAILED_STUB = table.concat({
    "echo 'error: Failed to run the pipeline' >&2",
    "exit 1",
}, "\n")
local REFUSAL =
    "the hub is draining since 1m ago by agent:infra: protocol 67 deploy; running jobs finish and nothing new starts until `ci fleet drain off`"

testing.test("check records no row for a run the hub refused", function()
    local root, home = git_root({ ["stub-ci.sh"] = REFUSED_STUB })
    local id = card_with(root, home, { "true", "sh stub-ci.sh", "false" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.eq(comments(home)[1], nil)
end)

testing.test("check prints the refusal reason of a refused run and exits 1", function()
    local root, home = git_root({ ["stub-ci.sh"] = REFUSED_STUB })
    local id = card_with(root, home, { "sh stub-ci.sh" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.ok(out:find("The ci hub refused row 1 (sh stub-ci.sh).", 1, true), out)
    testing.ok(out:find("The hub said: " .. REFUSAL, 1, true), out)
    testing.eq(out:find("passed", 1, true), nil, out)
end)

testing.test("check records no row for a run a draining target refused", function()
    local root, home = git_root({ ["stub-ci.sh"] = TARGET_STUB })
    local id = card_with(root, home, { "sh stub-ci.sh" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.eq(comments(home)[1], nil)
end)

testing.test("check records no row for a negated run the hub refused", function()
    local root, home = git_root({ ["stub-ci.sh"] = REFUSED_STUB })
    local id = card_with(root, home, { "! sh stub-ci.sh" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.eq(comments(home)[1], nil)
end)

testing.test("check run fails a negated row the hub refused", function()
    local root = setup({ ["stub-ci.sh"] = REFUSED_STUB })
    local row = check.run({
        root = root,
        run = "! sh stub-ci.sh",
        argv = { "sh", "stub-ci.sh" },
        seconds = 60,
    })
    testing.eq(row.result, "fail")
    testing.eq(row.refused, REFUSAL)
end)

testing.test("check tells a refused run from a failed one", function()
    local root, home = git_root({ ["stub-ci.sh"] = FAILED_STUB })
    local id = card_with(root, home, { "sh stub-ci.sh" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.eq(out:find("The ci hub refused", 1, true), nil, out)
    local record = check.parse(comments(home)[1].body)
    testing.eq(record.rows[1].result, "fail")
    testing.eq(record.rows[1].reason, "error: Failed to run the pipeline")
end)

local CAP_LINE =
    "The drain did not lift within 60 minutes. The hub is draining since 1h ago by agent:infra: protocol 67 deploy."
local CAP_STUB = "echo 'error: " .. CAP_LINE .. "' >&2\nexit 12"
local EXIT_12_STUB = "echo 'error: something else' >&2\nexit 12"
local RUN_THEN_12_STUB = "echo 'run 8cb600'\necho 'error: late' >&2\nexit 12"

testing.test("a row that exits 12 with no run id is refused", function()
    local root, home = git_root({ ["stub-ci.sh"] = EXIT_12_STUB })
    local id = card_with(root, home, { "sh stub-ci.sh" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.ok(out:find("The ci hub refused row 1 (sh stub-ci.sh).", 1, true), out)
    testing.ok(out:find("The hub said: error: something else", 1, true), out)
    testing.eq(comments(home)[1], nil)
end)

testing.test("a row that exits 12 after its run id is not refused", function()
    local root = setup({ ["stub-ci.sh"] = RUN_THEN_12_STUB })
    local row = check.run({
        root = root,
        run = "sh stub-ci.sh",
        argv = { "sh", "stub-ci.sh" },
        seconds = 60,
    })
    testing.eq(row.result, "fail")
    testing.eq(row.refused, nil)
    testing.eq(row.run_id, "8cb600")
end)

testing.test("check prints the drain cap message of a refused run", function()
    local root, home = git_root({ ["stub-ci.sh"] = CAP_STUB })
    local id = card_with(root, home, { "sh stub-ci.sh" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.ok(out:find("The hub said: " .. CAP_LINE, 1, true), out)
    testing.eq(comments(home)[1], nil)
end)

testing.test("check records no reason for a row with a run id", function()
    local root, home = git_root()
    local id = card_with(root, home, { "echo run 8cb600" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 0, out)
    local body = comments(home)[1].body
    testing.ok(body:find("\n1 pass 8cb600", 1, true), body)
    testing.eq(check.parse(body).rows[1].reason, nil)
    testing.eq(body:find("\n%s", 1), nil)
end)

testing.test("check parse reads the reason of a row", function()
    local state = { commit = "abc123", change = "-" }
    local rows = {
        {
            result = "fail",
            run_id = "-",
            run = "dev --remote test",
            reason = "the hub is draining",
        },
        { result = "pass", run_id = "8cb600", run = "dev --remote lint" },
    }
    local body = check.record(state, rows, false)
    testing.ok(body:find("\n1 fail -\n  the hub is draining\n2 pass", 1, true), body)
    testing.eq(check.parse(body).rows, {
        { result = "fail", run_id = "-", reason = "the hub is draining" },
        { result = "pass", run_id = "8cb600" },
    })
    testing.eq(check.parse((body:gsub("draining\n", "draining\n  again\n"))), nil)
    local head = "dev-check: commit=abc123 change=- mode=run rows=0 sum=ab"
    testing.eq(check.parse(head .. "\n  orphan"), nil)
end)

testing.test("check labels the ci run of a row as repo/check/card", function()
    local root, home = git_root()
    local id = card_with(root, home, { "! printenv DEV_CI_VERB DEV_CI_CARD" })
    local out = dev(root, home, { "board", "check", id })
    testing.ok(out:find("    check\n    " .. id, 1, true), out)
end)

testing.test("check refuses a dirty git tree and records nothing", function()
    local root, home = git_root()
    local id = card_with(root, home, { "true" })
    assert(fs.write(root .. "/stray", "x"))
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.ok(out:find("working copy is dirty", 1, true), out)
    testing.eq(#comments(home), 0)
end)

testing.test("check refuses a tree that changed while the rows ran", function()
    local root, home = git_root()
    local id = card_with(root, home, { "touch moved" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.ok(
        out:find("NOT recorded", 1, true) and out:find("changed while the checks ran", 1, true),
        out
    )
    testing.eq(#comments(home), 0)
end)

testing.test("check runs a row as a plain command and never through a shell", function()
    local root, home = git_root()
    local id = card_with(root, home, { "true" })
    local path = home .. "/state/dev/boards/mine.json"
    local doc = assert(json.decode(assert(fs.read(path))))
    doc.cards[1].checks = { "touch marker; true" }
    assert(fs.write(path, json.encode(doc)))
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.ok(out:find("only a shell reads", 1, true), out)
    testing.eq(fs.exists(root .. "/marker"), false)
    testing.eq(#comments(home), 0)
end)

testing.test("check ends a row at the time limit and records a timeout", function()
    local root, home = git_root()
    local id = card_with(root, home, { "sleep 30" })
    local out, code = dev(root, home, { "board", "check", id, "--timeout", "1" })
    testing.eq(code, 1, out)
    testing.eq(comments(home)[1].body:match("\n(.*)$"), "1 timeout -")
    out, code = dev(root, home, { "board", "check", id, "--timeout", "0" })
    testing.eq(code, 2, out)
end)

testing.test("the default row limit is two hours and within the most --timeout accepts", function()
    testing.eq(check.DEFAULT_SECONDS, 7200)
    testing.ok(check.DEFAULT_SECONDS <= check.MAX_SECONDS)
end)

testing.test("--expect-fail records failing rows and reports a passing one", function()
    local root, home, head = git_root()
    local id = card_with(root, home, { "false" })
    local out, code = dev(root, home, { "board", "check", id, "--expect-fail" })
    testing.eq(code, 0, out)
    testing.eq(
        comments(home)[1].body,
        "dev-check: commit="
            .. head
            .. " change=- mode=expect-fail rows=1 sum="
            .. check.fingerprint({ "false" })
            .. "\n1 fail -"
    )
    must(dev(root, home, { "board", "checks", id, "true", "false" }))
    out, code = dev(root, home, { "board", "check", id, "--expect-fail" })
    testing.eq(code, 1, out)
    testing.ok(out:find("the passing ones prove nothing", 1, true), out)
    must(dev(root, home, { "board", "checks", id, "true" }))
    out, code = dev(root, home, { "board", "check", id, "--expect-fail" })
    testing.eq(code, 1, out)
    testing.ok(out:find("the passing ones prove nothing", 1, true), out)
    testing.eq(#comments(home), 3)
end)

testing.test("an expect-fail row that exits 127 fails the run", function()
    local root, home = git_root()
    local id = card_with(root, home, { "no-such-command-for-check" })
    local out, code = dev(root, home, { "board", "check", id, "--expect-fail" })
    testing.eq(code, 1, out)
    testing.ok(out:find("The row never started (exit 127).", 1, true), out)
    testing.ok(out:find("a row that never started proves nothing.", 1, true), out)
    local record = check.parse(comments(home)[1].body)
    testing.eq(record.mode, "expect-fail")
    testing.eq(record.rows[1].result, "error")
    testing.eq(
        check.run({
            root = root,
            run = "no-such-command-for-check",
            argv = { "no-such-command-for-check" },
            seconds = 30,
        }).result,
        "fail"
    )
end)

testing.test("an expect-fail row that exits 1 still counts as the expected failure", function()
    local root = setup()
    local row = check.run({
        root = root,
        run = "false",
        argv = { "false" },
        seconds = 30,
        expect_fail = true,
    })
    testing.eq(row.result, "fail")
    local passed, good, errors = check.summarize({ row }, true)
    testing.eq({ passed, good, errors }, { 0, true, 0 })
end)

testing.test("an expect-fail remote row that printed no run id never ran", function()
    testing.ok(check.never_started({ "dev", "--remote", "test" }, 1, nil))
    testing.ok(check.never_started({ "ci", "run" }, 2, nil))
    testing.ok(not check.never_started({ "dev", "--remote", "test" }, 1, "abc123"))
    testing.ok(not check.never_started({ "dev", "--remote", "test" }, 124, nil))
    testing.ok(not check.never_started({ "dev", "test", "--", "--remote" }, 1, nil))
    testing.ok(not check.never_started({ "rg", "-n", "x" }, 1, nil))
    testing.ok(check.never_started({ "rg", "-n", "x" }, 126, nil))
    local passed, good, errors = check.summarize({ { result = "error" } }, true)
    testing.eq({ passed, good, errors }, { 0, false, 1 })
end)

testing.test(
    "note refuses the reserved prefix, and the record cannot be edited or deleted",
    function()
        local root, home = git_root()
        local id = card_with(root, home, { "true" })
        local out, code = dev(root, home, { "board", "note", id, "dev-check:", "commit=x" })
        testing.eq(code, 1, out)
        testing.ok(
            out:find("dev-check:", 1, true) and out:find("`dev board check` writes", 1, true),
            out
        )
        testing.eq(#comments(home), 0)
        must(dev(root, home, { "board", "check", id }))
        local first = assert(dev(root, home, { "board", "notes", id }):match("^(%x+)"))
        out, code = dev(root, home, { "board", "note", id, "--edit", first, "fine" })
        testing.eq(code, 1, out)
        out, code = dev(root, home, { "board", "note", id, "--delete", first })
        testing.eq(code, 1, out)
        must(dev(root, home, { "board", "note", id, "plain" }))
        local second = assert(dev(root, home, { "board", "notes", id }):match("\n(%x+)"))
        out, code = dev(root, home, { "board", "note", id, "--edit", second, "dev-check: forged" })
        testing.eq(code, 1, out)
        testing.eq(#comments(home), 2)
    end
)

testing.test("a result that cannot be written is never reported as recorded", function()
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
    local result = cmd_board.run("check", { "11111111" }, backend)
    testing.eq(result.output, nil)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("was NOT recorded", 1, true), result.message)
    testing.ok(result.message:find("Curl exit 28.", 1, true), result.message)
    testing.ok(result.message:find("1 pass - true", 1, true), result.message)
    testing.eq(result.unqueued, nil)
end)

if has_jj then
    local function jj(root, ...)
        local argv = { "jj", "--no-pager", "--color", "never", "-R", root, ... }
        local out, code = dev_os.capture(argv, { stderr = "null", env = IDENT })
        assert(code == 0, out)
        return out
    end

    local function workspace()
        local root, home = setup()
        local init = { stdout = "null", stderr = "null", env = IDENT }
        must(dev_os.run({ "jj", "git", "init", root }, init))
        jj(root, "commit", "-m", "base")
        local ws = assert(fs.realpath(support.tempdir())) .. "/ws"
        jj(root, "workspace", "add", "--name", "w2", "-r", "@-", ws)
        return root, home, ws
    end

    testing.test("check refuses outside the workspace named for the card", function()
        local root, home, ws = workspace()
        local id = card_with(root, home, { "true" })
        local out, code = dev(root, home, { "board", "check", id }, ws)
        testing.eq(code, 1, out)
        testing.ok(out:find("w2", 1, true), out)
        testing.ok(out:find("dev ws new " .. id, 1, true), out)
        testing.eq(#comments(home), 0)
    end)

    testing.test(
        "in a jj workspace the working-copy commit is the commit, edits included",
        function()
            local root, home, ws = workspace()
            local id = card_with(root, home, { "true" })
            jj(ws, "workspace", "rename", id)
            assert(fs.write(ws .. "/edited", "x"))
            local out, code = dev(root, home, { "board", "check", id }, ws)
            testing.eq(code, 0, out)
            local want =
                jj(ws, "log", "-r", "@", "--no-graph", "-T", "commit_id ++ ' ' ++ change_id")
            local commit, change = want:match("^(%x+) (%a+)")
            testing.eq(
                comments(home)[1].body,
                "dev-check: commit="
                    .. commit
                    .. " change="
                    .. change
                    .. " mode=run rows=1 sum="
                    .. check.fingerprint({ "true" })
                    .. "\n1 pass -"
            )
            testing.ok(out:find(commit:sub(1, 12), 1, true), out)
        end
    )

    testing.test("in a jj workspace a row that edits files leaves nothing recorded", function()
        local root, home, ws = workspace()
        local id = card_with(root, home, { "touch made" })
        jj(ws, "workspace", "rename", id)
        local out, code = dev(root, home, { "board", "check", id }, ws)
        testing.eq(code, 1, out)
        testing.ok(out:find("changed while the checks ran", 1, true), out)
        testing.eq(#comments(home), 0)
    end)
end

testing.test("the claimant's note is found by the token that posted the claim", function()
    local STATUS, DECISION = board.NoteKind.STATUS, board.NoteKind.DECISION
    local function note(who, body, kind)
        return { who = who, body = body, kind = kind }
    end
    local claim = note("agents", board.claim_record("r/one"), STATUS)
    local function noted(...)
        return board.noted_since_claim({ ... }, "r/one")
    end
    testing.eq(noted(note("agents", "built it")), nil)
    testing.eq(noted(claim), false)
    testing.eq(noted(claim, note("agents", "[dev agent] done")), true)
    testing.eq(noted(note("agents", "early"), claim), false)
    testing.eq(noted(claim, note("other", "built it")), false)
    testing.eq(noted(claim, note("agents", "ruled", DECISION)), false)
    testing.eq(noted(claim, note("agents", "dev-check: x", STATUS)), false)
    testing.eq(noted(claim, note("agents", "dev-review: x", STATUS)), false)
    testing.eq(noted(claim, note("agents", "old"), claim), false)
end)
