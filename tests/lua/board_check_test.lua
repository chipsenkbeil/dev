local testing = require("dev.testing")
local board = require("dev.board")
local check = require("dev.board.check")
local cmd_board = require("dev.cmd.board")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local land = require("dev.board.land")
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

local passing_ci_bin

local function passing_ci_path()
    if not passing_ci_bin then
        passing_ci_bin = support.tempdir() .. "/bin"
        assert(fs.mkdir(passing_ci_bin, { parents = true }), "mkdir failed")
        assert(
            fs.write(passing_ci_bin .. "/ci", '#!/bin/sh\necho \'{"status":"passed"}\'\n'),
            "write failed"
        )
        assert(dev_os.run({ "chmod", "755", passing_ci_bin .. "/ci" }) == 0, "chmod failed")
    end
    return passing_ci_bin .. ":" .. os.getenv("PATH")
end

local function with_passing_ci(body)
    local saved = dev_os.defaults.env.PATH
    dev_os.defaults.env.PATH = passing_ci_path()
    local ok, err = pcall(body)
    dev_os.defaults.env.PATH = saved
    assert(ok, err)
end

local function dev(root, home, args, cwd, extra)
    local env = {
        HOME = home,
        XDG_STATE_HOME = home .. "/state",
        JJ_USER = "t",
        JJ_EMAIL = "t@example.com",
        PATH = passing_ci_path(),
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
    support.drop_turn_card(support.board_file(home, "mine"))
    local out = dev(root, home, {
        "board",
        "add",
        "Card",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--done-when",
        "a",
    })
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

local START_NOTE = "Check started at commit "

local function raw_comments(home)
    local doc = assert(json.decode(assert(fs.read(support.board_file(home, "mine")))))
    return doc.cards[1].comments or {}
end

local function split_comments(home)
    local started, rest = {}, {}
    for _, comment in ipairs(raw_comments(home)) do
        local into = comment.body:sub(1, #START_NOTE) == START_NOTE and started or rest
        into[#into + 1] = comment
    end
    return started, rest
end

local function all_comments(home)
    local _, rest = split_comments(home)
    return rest
end

local function start_notes(home)
    local started = split_comments(home)
    return started
end

local function comments(home)
    local kept = {}
    for _, comment in ipairs(all_comments(home)) do
        if not comment.body:find(" mode=" .. check.Mode.PARTIAL .. " ", 1, true) then
            kept[#kept + 1] = comment
        end
    end
    return kept
end

local function expected_head(commit, change, mode, commands)
    return string.format(
        "dev-check: commit=%s change=%s mode=%s rows=%d sum=%s",
        commit,
        change,
        mode,
        #commands,
        check.fingerprint(commands)
    )
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

testing.test("a row naming a command off PATH is unrunnable", function()
    local root = support.tempdir()
    local why = check.unrunnable("no-such-tool-xyz --flag", root)
    testing.ok(why:find("not on PATH", 1, true), why)
    testing.ok(check.unrunnable("! no-such-tool-xyz", root))
    testing.eq(check.unrunnable("true", root), nil)
end)

testing.test("an rg row with a word that is no path is unrunnable", function()
    local root = support.tempdir()
    assert(fs.write(root .. "/a.txt", "x\n"))
    local why = check.unrunnable("rg -n two words a.txt", root)
    testing.ok(why:find('"words"', 1, true), why)
    testing.eq(check.unrunnable("rg -n word a.txt", root), nil)
    testing.eq(check.unrunnable("! rg -n word a.txt", root), nil)
    testing.eq(check.unrunnable("rg -g a.txt word a.txt", root), nil)
    testing.eq(check.unrunnable("rg -e word a.txt", root), nil)
    testing.eq(check.unrunnable("rg -n -- word a.txt", root), nil)
    testing.eq(check.unrunnable("rg --color never word a.txt", root), nil)
    testing.ok(check.unrunnable("rg -- word missing.txt", root))
    testing.ok(check.unrunnable("rg word missing.txt", root))
end)

testing.test("a row whose rg exits 2 is an error with rg's stderr", function()
    local root = support.tempdir()
    local row = check.run({
        root = root,
        run = "rg word absent.txt",
        argv = { "rg", "word", "absent.txt" },
        seconds = 30,
    })
    testing.eq(row.result, "error")
    testing.eq(row.code, 2)
    testing.ok(row.tail:find("absent.txt", 1, true), row.tail)
end)

testing.test("board check prints the row error and rg's stderr for an rg exit 2", function()
    local root, home = git_root({ ["a.txt"] = "x\n" })
    local id = card_with(root, home, { "rg [ a.txt" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.ok(code ~= 0, out)
    testing.ok(out:find("rg exited 2", 1, true), out)
    testing.ok(out:find("regex parse error", 1, true), out)
    testing.eq(check.parse(comments(home)[1].body).rows[1].result, "error")
end)

testing.test("board checks refuses an unrunnable row and keeps the old rows", function()
    local root, home = git_root({ ["a.txt"] = "x\n" })
    local id = card_with(root, home, { "true" })
    local out, code = dev(root, home, { "board", "checks", id, "no-such-tool-xyz" })
    testing.ok(code ~= 0, out)
    testing.ok(out:find("not on PATH", 1, true), out)
    out, code = dev(root, home, { "board", "checks", id, "rg two words a.txt" })
    testing.ok(code ~= 0, out)
    testing.ok(out:find('"words"', 1, true), out)
end)

testing.test("a dev test row naming a missing suite is unrunnable", function()
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/tests/lua", { parents = true }))
    assert(fs.write(root .. "/tests/lua/a_test.lua", "x\n"))
    local why = check.unrunnable("dev --remote test -- tests/lua/b_test.lua", root)
    testing.ok(why:find('"tests/lua/b_test.lua"', 1, true), why)
    testing.ok(why:find("names no suite in the workspace", 1, true), why)
    testing.ok(check.unrunnable("dev test -- tests/lua/a_test.lua tests/nope", root))
    testing.ok(check.unrunnable("! dev --local test -- ./missing/", root))
    testing.eq(check.unrunnable("dev --remote test -- tests/lua/a_test.lua", root), nil)
    testing.eq(check.unrunnable("dev --remote test -- ./tests/lua/", root), nil)
    testing.eq(check.unrunnable("dev --remote test", root), nil)
    testing.eq(check.unrunnable("dev --remote lint -- missing", root), nil)
end)

testing.test("a dev test row naming a bare test name is runnable", function()
    local root = support.tempdir()
    local row = "dev --remote test -- ui_layout_should_equal_the_love2d_golden"
    testing.eq(check.unrunnable(row, root), nil)
end)

testing.test("a dev test row naming a missing path is still refused", function()
    local root = support.tempdir()
    local why = check.unrunnable("dev --remote test -- tests/lua/x_test.lua", root)
    testing.ok(why:find('"tests/lua/x_test.lua"', 1, true), why)
end)

local function ready_candidate(root, home, row)
    must(dev(root, home, { "board", "init" }))
    support.drop_turn_card(support.board_file(home, "mine"))
    local out = dev(root, home, {
        "board",
        "add",
        "Card",
        "--description",
        support.READY_DESCRIPTION,
        "--size",
        "2",
        "--done-when",
        "a (reviewer judgement)",
        "--done-when",
        "b (reviewer judgement)",
        "--done-when",
        "c (reviewer judgement)",
        "--checks",
        row,
    })
    return assert(out:match("added (%x+)"), out)
end

testing.test("move ready refuses a card whose rg row names a missing path", function()
    local root, home = git_root({ ["a.txt"] = "x\n" })
    local id = ready_candidate(root, home, "rg -n x a.txt")
    assert(fs.remove(root .. "/a.txt"))
    local out, code = dev(root, home, { "board", "move", id, "ready" })
    testing.eq(code, 1, out)
    testing.ok(out:find("has a checks row that cannot run and cannot enter Ready.", 1, true), out)
    testing.ok(out:find('gives rg the word "a.txt"', 1, true), out)
end)

testing.test("move ready refuses a card whose dev test row names a missing suite", function()
    local root, home = git_root({ ["tests/a_test.lua"] = "x\n" })
    local id = ready_candidate(root, home, "dev --remote test -- tests/a_test.lua")
    assert(fs.remove(root .. "/tests/a_test.lua"))
    local out, code = dev(root, home, { "board", "move", id, "ready" })
    testing.eq(code, 1, out)
    testing.ok(out:find("has a checks row that cannot run and cannot enter Ready.", 1, true), out)
    testing.ok(out:find("names no suite in the workspace", 1, true), out)
end)

testing.test("the reserved prefix is found whatever its case and leading space", function()
    testing.ok(board.reserved("dev-check: commit=x"))
    testing.ok(board.reserved("  DEV-CHECK: x"))
    testing.eq(board.reserved("Tests pass, dev-check: fine"), false)
end)

local BARE_CONFIG =
    '[board]\nbackend = "local"\nname = "mine"\n[board.lint]\nbare_rows = ["dev --remote test"]\n'

testing.test("check refuses a card with no bare row before it runs any row", function()
    local root, home =
        git_root({ [".dev/config.toml"] = BARE_CONFIG, ["tests/a_test.lua"] = "x\n" })
    local id = card_with(root, home, { "true", "dev --remote test -- tests/a_test.lua" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.ok(
        out:find("lacks the bare row dev --remote test and cannot be checked.", 1, true),
        out
    )
    testing.ok(not out:find("1 pass", 1, true), out)
    testing.eq(#comments(home), 0)
end)

testing.test("check refuses a bare_rows that is not a list of commands", function()
    local config = '[board]\nbackend = "local"\nname = "mine"\n[board.lint]\nbare_rows = "x"\n'
    local root, home = git_root({ [".dev/config.toml"] = config })
    local id = card_with(root, home, { "true" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.ok(out:find("`bare_rows` setting of `[board.lint]` must be a list", 1, true), out)
end)

testing.test("check records each row and the commit, and the run is clean in git", function()
    local root, home, head = git_root()
    local id = card_with(root, home, { "true", "false" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.ok(out:find("1 pass - true", 1, true) and out:find("2 fail - false", 1, true), out)
    testing.ok(out:find("recorded on " .. id .. " at commit " .. head:sub(1, 12), 1, true), out)
    local body = comments(home)[1].body
    testing.eq(body, expected_head(head, "-", "run", { "true", "false" }) .. "\n1 pass -\n2 fail -")
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

testing.test("check records each passed row as a partial record before the next row", function()
    local root, home, head = git_root()
    local rows = { "true", "echo run 8cb600", "false" }
    local id = card_with(root, home, rows)
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    local held = all_comments(home)
    testing.eq(#held, 3)
    testing.eq(held[1].body, expected_head(head, "-", "partial", { rows[1] }) .. "\n1 pass -")
    testing.eq(
        held[2].body,
        expected_head(head, "-", "partial", { rows[1], rows[2] }) .. "\n1 pass -\n2 pass 8cb600"
    )
    testing.eq(
        held[3].body,
        expected_head(head, "-", "run", rows) .. "\n1 pass -\n2 pass 8cb600\n3 fail -"
    )
end)

testing.test("a rerun at the same commit skips passed rows and names them", function()
    local root, home, head = git_root()
    local rows = { "echo run 8cb600", "echo run 1f2e3d", "printenv GATE_OPEN" }
    local id = card_with(root, home, rows)
    local _, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1)
    local out
    out, code = dev(root, home, { "board", "check", id }, nil, { GATE_OPEN = "1" })
    testing.eq(code, 0, out)
    testing.ok(out:find("Row 1 of 3 passed in ci run 8cb600 at this commit", 1, true), out)
    testing.ok(out:find("Row 2 of 3 passed in ci run 1f2e3d at this commit", 1, true), out)
    testing.ok(not out:find("running 1 of 3", 1, true), out)
    testing.ok(not out:find("running 2 of 3", 1, true), out)
    testing.ok(out:find("running 3 of 3", 1, true), out)
    local held = comments(home)
    testing.eq(
        held[#held].body,
        expected_head(head, "-", "run", rows) .. "\n1 pass 8cb600\n2 pass 1f2e3d\n3 pass -"
    )
end)

testing.test("a rerun at a new commit runs every row", function()
    local root, home = git_root()
    local rows = { "echo run 8cb600", "echo run 1f2e3d", "printenv GATE_OPEN" }
    local id = card_with(root, home, rows)
    local _, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1)
    must(dev_os.run({
        "git",
        "-C",
        root,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.com",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "next",
    }, { stdout = "null" }))
    local out
    out, code = dev(root, home, { "board", "check", id }, nil, { GATE_OPEN = "1" })
    testing.eq(code, 0, out)
    testing.ok(out:find("running 1 of 3", 1, true), out)
    testing.ok(out:find("running 2 of 3", 1, true), out)
    testing.ok(out:find("running 3 of 3", 1, true), out)
    testing.ok(not out:find("so it is skipped", 1, true), out)
end)

testing.test("a rerun skips no row once the card's rows changed", function()
    local root, home = git_root()
    local id = card_with(root, home, { "true", "false" })
    local _, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1)
    must(dev(root, home, { "board", "checks", id, "echo run 8cb600", "true" }))
    local out
    out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 0, out)
    testing.ok(not out:find("so it is skipped", 1, true), out)
end)

testing.test("resume keeps rows of one shared ci run all or none", function()
    local state = { commit = string.rep("a", 40), change = "-" }
    local commands = { "true", "dev --remote lint", "dev --remote test" }
    local partial = {
        body = check.record(state, {
            { run = commands[1], run_id = "-", result = "pass" },
            { run = commands[2], run_id = "8cb600", result = "pass" },
        }, check.Mode.PARTIAL),
    }
    testing.eq(#check.resume({ partial }, state.commit, commands, {}), 2)
    testing.eq(#check.resume({ partial }, state.commit, commands, { 2, 3 }), 1)
    testing.eq(#check.resume({ partial }, string.rep("b", 40), commands, {}), 0)
end)

testing.test("a partial record never lets a card land or blocks a carry", function()
    local state = { commit = string.rep("a", 40), change = "chg" }
    local rows = { "true", "false" }
    local first = { run = rows[1], run_id = "-", result = check.Result.PASS }
    local partial = { body = check.record(state, { first }, check.Mode.PARTIAL) }
    testing.ok(land.checks_problem({ partial }, state, rows):find("No run", 1, true))
    local done = { body = check.record(state, { first, first }, check.Mode.RUN) }
    testing.eq(land.checks_problem({ done, partial }, state, { "true", "true" }), nil)
    local opts = { root = "/nonexistent", comments = { partial }, state = state, rows = rows }
    testing.ok(select("#", land.carry(opts)) > 1)
    opts.comments = { partial, done }
    testing.eq(select("#", land.carry(opts)), 1)
end)

testing.test("a 147 row check record stays under the pomb comment cap", function()
    local COMMENT_CAP_BYTES = 5000
    local SHORT_RECORD_BYTES = 3000

    -- Fill 147 failing rows with long commands and reasons
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

    -- Check the record fits the cap and parses back whole
    local body = check.record(state, rows, false)
    testing.ok(#body < COMMENT_CAP_BYTES, #body)
    local record = check.parse(body)
    testing.eq(#record.rows, 147)
    testing.eq(record.sum, check.fingerprint(commands))

    -- Check passing rows with run ids and no reasons make a short record
    for i = 1, 147 do
        rows[i].reason = nil
        rows[i].run_id = "007201"
        rows[i].result = "pass"
    end
    testing.ok(#check.record(state, rows, false) < SHORT_RECORD_BYTES)
end)

testing.test("show names each check row command", function()
    local root, home = git_root()
    local id = card_with(root, home, { "true", "echo run 8cb600" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 0, out)
    out, code = dev(root, home, { "board", "show", id })
    testing.eq(code, 0, out)
    testing.ok(out:find("2 pass 8cb600 echo run 8cb600", 1, true), out)

    must(dev(root, home, { "board", "checks", id, "true", "echo run 8cb601" }))
    out, code = dev(root, home, { "board", "show", id })
    testing.eq(code, 0, out)
    testing.ok(out:find("2 pass 8cb600", 1, true), out)
    testing.eq(out:find("2 pass 8cb600 echo", 1, true), nil, out)
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
    local row
    with_passing_ci(function()
        row = check.run({
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
    end)
    testing.eq(row.result, "pass")
    testing.eq(seen, { "8cb600" })
    testing.eq(row.run_id, "8cb600")
end)

testing.test("check.reads.the.failing.case.names", function()
    local script = table.concat({
        "echo '> tests/lua/a_test.lua'",
        "echo 'ok - fine'",
        "echo 'not ok - first case'",
        "echo '    detail'",
        "echo 'not ok - second case'",
        "echo 'FAIL tests/lua/a_test.lua'",
        "echo '> tests/lua/b_test.lua'",
        "echo 'FAIL tests/lua/b_test.lua'",
        "exit 1",
    }, "; ")
    local row = check.run({
        root = support.tempdir(),
        run = "row",
        argv = { "sh", "-c", script },
        seconds = 30,
    })
    testing.eq(row.failed, { "tests/lua/a_test.lua", "tests/lua/b_test.lua" })
    testing.eq(row.cases, { "first case", "second case", "tests/lua/b_test.lua" })
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
    local path = support.board_file(home, "mine")
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

local CONFIG = '[board]\nbackend = "local"\nname = "mine"\n\n[board.check]\nseconds = '

testing.test("check setting sets the default wait", function()
    local root, home = git_root({ [".dev/config.toml"] = CONFIG .. "1\n" })
    local id = card_with(root, home, { "sleep 3" })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.eq(comments(home)[1].body:match("\n(.*)$"), "1 timeout -")
    out, code = dev(root, home, { "board", "check", id, "--timeout", "30" })
    testing.eq(code, 0, out)
end)

testing.test("check setting refuses a bad value", function()
    local root, home = git_root({ [".dev/config.toml"] = CONFIG .. "1\n" })
    local id = card_with(root, home, { "true" })
    for _, value in ipairs({ "0", "86401", '"60"', "true" }) do
        assert(fs.write(root .. "/.dev/config.toml", CONFIG .. value .. "\n"))
        local out, code = dev(root, home, { "board", "check", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("board.check.seconds", 1, true), out)
    end
    must(dev_os.run({
        "git",
        "-C",
        root,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.com",
        "commit",
        "-qam",
        "bad setting",
    }, { stdout = "null" }))
    local out, code = dev(root, home, { "board", "check", id, "--timeout", "30" })
    testing.eq(code, 0, out)
end)

local MAC_FILE = "tests/lua/mac_test.lua"
local MAC_ROW = "dev --remote test -- " .. MAC_FILE

local function mac_root(setting)
    local config = '[board]\nbackend = "local"\nname = "mine"\n\n[board.check]\n' .. setting
    return git_root({ [".dev/config.toml"] = config, [MAC_FILE] = "x\n" })
end

testing.test("NOT_RUN row for a listed mac-only file is recorded and never started", function()
    local root, home, head = mac_root('mac_only = ["' .. MAC_FILE .. '"]\n')
    local id = card_with(root, home, { "true", MAC_ROW })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 0, out)
    testing.ok(out:find("2 not-run - " .. MAC_ROW, 1, true), out)
    testing.ok(not out:find("row 2 run", 1, true), out)
    local body = comments(home)[1].body
    testing.eq(
        body,
        expected_head(head, "-", "run", { "true", MAC_ROW }) .. "\n1 pass -\n2 not-run -"
    )
end)

testing.test("a mac_only setting that is no list of paths is refused", function()
    local root, home = mac_root('mac_only = "' .. MAC_FILE .. '"\n')
    local id = card_with(root, home, { MAC_ROW })
    local out, code = dev(root, home, { "board", "check", id })
    testing.eq(code, 1, out)
    testing.ok(out:find("board.check.mac_only", 1, true), out)
end)

testing.test("not.run.parse reads a not-run row back", function()
    local commands = { "true", MAC_ROW }
    local state = { commit = "abc123", change = "-" }
    local rows = { { run = "true", result = "pass", run_id = "-" }, check.not_run(MAC_ROW) }
    local record = check.parse(check.record(state, rows, false))
    testing.eq(record.rows, {
        { result = "pass", run_id = "-" },
        { result = "not-run", run_id = "-" },
    })
    testing.eq(record.sum, check.fingerprint(commands))
    testing.eq(check.line(2, rows[2]), "2 not-run - " .. MAC_ROW)
end)

testing.test("summarize counts a not-run row as neither passed nor an error", function()
    local not_run = check.not_run(MAC_ROW)
    local pass = { run = "true", run_id = "-", result = "pass", code = 0, tail = "" }
    local fail = { run = "false", run_id = "-", result = "fail", code = 1, tail = "" }
    local summary = check.summarize({ pass, not_run }, false)
    testing.eq({ summary.passed, summary.not_run, summary.errors, summary.good }, { 1, 1, 0, true })
    testing.eq(check.summarize({ not_run }, false).good, true)
    testing.eq(check.summarize({ pass, not_run, fail }, false).good, false)
    local lint = { run = "dev --remote lint", run_id = "-", result = "pass", code = 0, tail = "" }
    testing.eq(check.summarize({ lint, not_run }, true).good, false)
end)

testing.test("mac_only names a dev test row with a listed file after the double dash", function()
    local listed = { [MAC_FILE] = true }
    testing.eq(check.mac_only({ "dev", "--remote", "test", "--", MAC_FILE }, listed), true)
    testing.eq(
        check.mac_only({ "dev", "--remote", "test", "--", MAC_FILE, MAC_FILE }, listed),
        true
    )
    testing.eq(check.mac_only({ "dev", "--remote", "test", "--", "a", MAC_FILE }, listed), false)
    testing.eq(check.mac_only({ "dev", "--remote", "test" }, listed), false)
    testing.eq(check.mac_only({ "dev", "--remote", "test", "--", "tests/a.lua" }, listed), false)
    testing.eq(check.mac_only({ "dev", "--remote", "lint", "--", MAC_FILE }, listed), false)
    testing.eq(check.mac_only({ "rg", "-n", "x", MAC_FILE }, listed), false)
end)

local function fake_ci(body)
    local bin = support.tempdir() .. "/bin"
    assert(fs.mkdir(bin, { parents = true }), "mkdir failed")
    assert(fs.write(bin .. "/ci", "#!/bin/sh\n" .. body .. "\n"), "write failed")
    must(dev_os.run({ "chmod", "755", bin .. "/ci" }))
    return { PATH = bin .. ":" .. os.getenv("PATH") }
end

local function slow_row(ci_body)
    local root, home = git_root({ ["slow.sh"] = "echo run 8cb600\nsleep 30\n" })
    local id = card_with(root, home, { "sh slow.sh" })
    local env = fake_ci(ci_body)
    local out, code = dev(root, home, { "board", "check", id, "--timeout", "2" }, nil, env)
    testing.eq(code, 1, out)
    return comments(home)[1].body, out
end

testing.test("a timeout row records the state of its ci run", function()
    local body, out = slow_row([[echo '{"status":"running"}']])
    local reason = "The ci run was running at the limit and may still finish."
    testing.ok(body:find("1 timeout 8cb600\n  " .. reason, 1, true), body)
    testing.ok(out:find(reason, 1, true), out)
    testing.ok(not out:find(reason .. ".", 1, true), out)
end)

testing.test("a timeout row says when the ci state is unreadable", function()
    local body = slow_row("exit 1")
    testing.ok(body:find("The ci run state could not be read at the limit.", 1, true), body)
end)

local function quick_row(ci_body)
    local root, home = git_root({ ["quick.sh"] = "echo run 8cb600\n" })
    local id = card_with(root, home, { "sh quick.sh" })
    local out, code = dev(root, home, { "board", "check", id }, nil, fake_ci(ci_body))
    return out, code, comments(home)[1].body
end

testing.test("a zero-exit row whose ci run is still running records error", function()
    local out, code, body = quick_row([[echo '{"status":"running"}']])
    testing.eq(code, 1, out)
    testing.ok(body:find("1 error 8cb600", 1, true), body)
    testing.ok(out:find("The ci run 8cb600 was running, not passed.", 1, true), out)
end)

testing.test("a zero-exit row whose ci run passed records pass", function()
    local out, code, body = quick_row([[echo '{"status":"passed"}']])
    testing.eq(code, 0, out)
    testing.ok(body:find("1 pass 8cb600", 1, true), body)
end)

testing.test("a zero-exit row with an unreadable ci state records error naming the run", function()
    local out, code, body = quick_row("exit 1")
    testing.eq(code, 1, out)
    testing.ok(body:find("1 error 8cb600", 1, true), body)
    testing.ok(out:find("The state of ci run 8cb600 could not be read.", 1, true), out)
end)

local PASSED =
    '{"name":"lint","state":"passed","exit_code":0},{"name":"test","state":"passed","exit_code":0}'
local TEST_FAILED =
    '{"name":"lint","state":"passed","exit_code":0},{"name":"test","state":"failed","exit_code":3}'

local function group_run(code)
    return 'echo "$DEV_AGENT $*" >> "$CI_LOG"; [ -n "$DEV_AGENT" ] || exit 9; echo "run 8cb600"; exit '
        .. code
end

local function group_ci(opts, head)
    local ps = opts.unreadable and "exit 1"
        or string.format(
            [[echo '{"status":"running","source":"local@%s","jobs":[%s]}']],
            opts.source or head:sub(1, 12),
            opts.jobs
        )
    return string.format(
        [[case "$1" in
-C)
    case "$3" in
    ps) echo "watch $4 $5" >> "$CI_LOG"; %s ;;
    *)
        case "$4" in
        "--list") echo '{"jobs":[{"name":"lint"},{"name":"test"}]}' ;;
        *) %s ;;
        esac ;;
    esac ;;
ps) %s ;;
logs) %s ;;
esac]],
        opts.watch or "exit 0",
        opts.run or "exit 9",
        ps,
        opts.logs and 'echo "logs $*" >> "$CI_LOG"; ' .. opts.logs or 'echo "output of $4"'
    )
end

---@class board_check_test.group_check.Opts
---@field jobs string? the jobs `ci ps` reports
---@field unreadable boolean? whether `ci ps` fails
---@field run string? the shell the fake `ci run` runs
---@field rows string[]? the card's checks, a lint row and a test row when nil
---@field timeout string? the `--timeout` seconds
---@field attach string? the run id passed to `--run`
---@field expect_fail boolean? whether the check passes `--expect-fail`
---@field source string? the commit the fake run reports, the working copy's commit when nil
---@field watch string? the shell the fake `ci ps --watch` runs
---@field logs string? the shell the fake `ci logs` runs, which also notes its call in the ci log
---@field touch string? a suite the working copy's commit adds alone, which narrows a plain test row

local function group_check(opts)
    local root, home, head = git_root({
        ["tests/a_test.lua"] = "x\n",
        ["tests/x_test.lua"] = "x\n",
        ["tests/y_test.lua"] = "x\n",
    })
    if opts.touch then
        assert(fs.write(root .. "/" .. opts.touch, "x\n"), "write failed")
        local identity = { "-c", "user.name=t", "-c", "user.email=t@example.com" }
        for _, step in ipairs({ { "add", "-A" }, { "commit", "-q", "-m", "touch" } }) do
            local argv = { "git", "-C", root, unpack(identity) }
            for _, word in ipairs(step) do
                argv[#argv + 1] = word
            end
            must(dev_os.run(argv, { stdout = "null" }))
        end
        head = dev_os.capture({ "git", "-C", root, "rev-parse", "HEAD" }):gsub("\n$", "")
    end
    local id = card_with(root, home, opts.rows or { "dev --remote lint", "dev --remote test" })
    local env = fake_ci(group_ci(opts, head))
    local log = support.tempdir() .. "/ci.log"
    env.CI_LOG = log
    env.DEV_AGENT = ""
    local args = { "board", "check", id }
    if opts.attach then
        args[#args + 1] = "--run"
        args[#args + 1] = opts.attach
    end
    if opts.expect_fail then
        args[#args + 1] = "--expect-fail"
    end
    if opts.timeout then
        args[#args + 1] = "--timeout"
        args[#args + 1] = opts.timeout
    end
    local out, status = dev(root, home, args, nil, env)
    local first = comments(home)[1]
    return out, status, first and first.body, fs.read(log) or "", #start_notes(home)
end

testing.test("a card with a lint row and a test row makes one ci run", function()
    local out, code, body, log = group_check({ jobs = PASSED, run = group_run(0) })
    testing.eq(code, 0, out)
    testing.eq(select(2, log:gsub("\n", "")), 1, log)
    testing.ok(log:find("mine/check/", 1, true), log)
    testing.ok(out:find("1 pass 8cb600 dev --remote lint", 1, true), out)
    testing.ok(out:find("2 pass 8cb600 dev --remote test", 1, true), out)
    local record = check.parse(body)
    testing.eq(record.rows, {
        { result = "pass", run_id = "8cb600" },
        { result = "pass", run_id = "8cb600" },
    })
end)

testing.test("a failed job records its own row and shows its own tail", function()
    local out, code, body = group_check({ jobs = TEST_FAILED, run = group_run(1) })
    testing.eq(code, 1, out)
    testing.ok(out:find("1 pass 8cb600", 1, true), out)
    testing.ok(out:find("2 fail 8cb600", 1, true), out)
    testing.ok(out:find("    output of test", 1, true), out)
    testing.ok(not out:find("output of lint", 1, true), out)
    testing.ok(body:find("2 fail 8cb600", 1, true), body)
end)

testing.test("the words after the double dash of a test row reach the one ci run", function()
    local out, code, _, log = group_check({
        jobs = PASSED,
        run = group_run(0),
        rows = { "dev --remote lint", "dev --remote test -- tests/a_test.lua" },
    })
    testing.eq(code, 0, out)
    testing.ok(log:find("-- tests/a_test.lua", 1, true), log)
end)

local FOLD_ROWS = {
    "dev --remote lint",
    "dev --remote test",
    "dev --remote test -- tests/x_test.lua",
    "dev --remote test -- tests/y_test.lua",
}
local FOLD_PASSED = 'echo "PASS tests/x_test.lua"; echo "PASS tests/y_test.lua"'
local FOLD_ONE_FAILED = 'echo "PASS tests/x_test.lua"; echo "FAIL tests/y_test.lua"'

testing.test("a named test row starts no ci run of its own beside a plain test row", function()
    local out, code, body, log = group_check({
        jobs = PASSED,
        run = group_run(0),
        rows = FOLD_ROWS,
        logs = FOLD_PASSED,
    })
    testing.eq(code, 0, out)
    testing.eq(select(2, log:gsub("mine/check/", "")), 1, log)
    testing.ok(not log:find("-- tests/x_test.lua", 1, true), log)
    testing.ok(log:find("logs 8cb600 --job test", 1, true), log)
    testing.eq(check.parse(body).rows, {
        { result = "pass", run_id = "8cb600" },
        { result = "pass", run_id = "8cb600" },
        { result = "pass", run_id = "8cb600" },
        { result = "pass", run_id = "8cb600" },
    })
end)

testing.test("a folded row records its own result from the test log", function()
    local out, code, body = group_check({
        jobs = PASSED,
        run = group_run(0),
        rows = FOLD_ROWS,
        logs = FOLD_ONE_FAILED,
    })
    testing.eq(code, 1, out)
    testing.eq(check.parse(body).rows, {
        { result = "pass", run_id = "8cb600" },
        { result = "pass", run_id = "8cb600" },
        { result = "pass", run_id = "8cb600" },
        { result = "fail", run_id = "8cb600", reason = "FAIL tests/y_test.lua" },
    })
    testing.ok(out:find("3 pass 8cb600 dev --remote test -- tests/x_test.lua", 1, true), out)
    testing.ok(out:find("4 fail 8cb600 dev --remote test -- tests/y_test.lua", 1, true), out)
end)

testing.test("a folded row the test log never names records error", function()
    local out, code, body = group_check({
        jobs = PASSED,
        run = group_run(0),
        rows = FOLD_ROWS,
        logs = 'echo "PASS tests/x_test.lua"',
    })
    testing.eq(code, 1, out)
    testing.eq(check.parse(body).rows[4], {
        result = "error",
        run_id = "8cb600",
        reason = "no result line names tests/y_test.lua",
    })
end)

testing.test("a folded row of a host that timed out records timeout without a log read", function()
    local out, code, body, log = group_check({
        jobs = PASSED,
        rows = FOLD_ROWS,
        logs = FOLD_PASSED,
        timeout = "2",
        run = 'echo "run 8cb600"; sleep 30',
        watch = "sleep 30",
    })
    testing.eq(code, 1, out)
    local rows = check.parse(body).rows
    testing.eq(rows[3], { result = "timeout", run_id = "8cb600" })
    testing.eq(rows[4], { result = "timeout", run_id = "8cb600" })
    testing.ok(not log:find("logs 8cb600", 1, true), log)
end)

testing.test("a named row between the shared rows keeps its place in the record", function()
    local out, code, body, log = group_check({
        jobs = PASSED,
        run = group_run(0),
        rows = { "dev --remote lint", "dev --remote test -- tests/x_test.lua", "dev --remote test" },
        logs = FOLD_PASSED,
    })
    testing.eq(code, 0, out)
    testing.eq(select(2, log:gsub("mine/check/", "")), 1, log)
    testing.eq(check.parse(body).rows, {
        { result = "pass", run_id = "8cb600" },
        { result = "pass", run_id = "8cb600" },
        { result = "pass", run_id = "8cb600" },
    })
end)

testing.test(
    "a folded directory row with a trailing slash reads the log by its plain name",
    function()
        local out, code, body = group_check({
            jobs = PASSED,
            run = group_run(0),
            rows = { "dev --remote lint", "dev --remote test", "dev --remote test -- tests/" },
            logs = FOLD_PASSED,
        })
        testing.eq(code, 0, out)
        testing.eq(check.parse(body).rows[3], { result = "pass", run_id = "8cb600" })
    end
)

testing.test("a narrowed test run also runs the files of the named rows", function()
    local out, code, _, log = group_check({
        jobs = PASSED,
        run = group_run(0),
        rows = { "dev --remote lint", "dev --remote test", "dev --remote test -- tests/x_test.lua" },
        logs = 'echo "PASS tests/x_test.lua"; echo "PASS tests/b_test.lua"',
        touch = "tests/b_test.lua",
    })
    testing.eq(code, 0, out)
    testing.ok(log:find("-- tests/b_test.lua tests/x_test.lua", 1, true), log)
    testing.ok(out:find("3 pass 8cb600 dev --remote test -- tests/x_test.lua", 1, true), out)
end)

testing.test("a zero-exit shared run records error for a row whose job is unfinished", function()
    local jobs = '{"name":"lint","state":"passed","exit_code":0},'
        .. '{"name":"test","state":"running","exit_code":0}'
    local out, code, body = group_check({ jobs = jobs, run = group_run(0) })
    testing.eq(code, 1, out)
    testing.ok(body:find("1 pass 8cb600", 1, true), body)
    testing.ok(body:find("2 error 8cb600", 1, true), body)
    testing.ok(out:find("The ci run 8cb600: job test was running, not passed.", 1, true), out)
end)

testing.test("a zero-exit shared run records error for a row whose job still waits", function()
    local jobs = '{"name":"lint","state":"passed","exit_code":0},'
        .. '{"name":"test","state":"waiting","exit_code":0}'
    local out, code, body = group_check({ jobs = jobs, run = group_run(0) })
    testing.eq(code, 1, out)
    testing.ok(body:find("2 error 8cb600", 1, true), body)
    testing.ok(out:find("job test was waiting, not passed.", 1, true), out)
    testing.ok(not out:find("output of test", 1, true), out)
end)

testing.test("a zero-exit shared run names a job ci did not list", function()
    local jobs = '{"name":"lint","state":"passed","exit_code":0}'
    local out, code, body = group_check({ jobs = jobs, run = group_run(0) })
    testing.eq(code, 1, out)
    testing.ok(body:find("2 error 8cb600", 1, true), body)
    testing.ok(out:find("job test is not among the jobs ci read.", 1, true), out)
end)

testing.test(
    "a zero-exit shared run records error for every row when ci cannot list the jobs",
    function()
        local out, code, body = group_check({ unreadable = true, run = group_run(0) })
        testing.eq(code, 1, out)
        testing.ok(body:find("1 error 8cb600", 1, true), body)
        testing.ok(body:find("2 error 8cb600", 1, true), body)
        testing.ok(out:find("The ci run 8cb600: its jobs could not be read.", 1, true), out)
    end
)

testing.test("a shared run the hub refused records nothing and names its first row", function()
    local out, code, body = group_check({ jobs = PASSED, run = REFUSED_STUB })
    testing.eq(code, 1, out)
    testing.eq(body, nil)
    testing.ok(out:find("The ci hub refused row 1 (dev --remote lint).", 1, true), out)
    testing.ok(out:find("The hub said: " .. REFUSAL, 1, true), out)
end)

testing.test("a shared run that outlasts the limit records every row as a timeout", function()
    local out, code, body = group_check({
        jobs = PASSED,
        run = 'echo "run 8cb600"; sleep 30',
        timeout = "2",
    })
    testing.eq(code, 1, out)
    local reason = "The ci run was running at the limit and may still finish."
    testing.ok(body:find("1 timeout 8cb600\n  " .. reason, 1, true), body)
    testing.ok(body:find("2 timeout 8cb600\n  " .. reason, 1, true), body)
end)

testing.test("a row whose wait ends early names its run and the command that records it", function()
    local out, code = group_check({
        jobs = PASSED,
        run = 'echo "run 8cb600"; sleep 30',
        timeout = "2",
    })
    testing.eq(code, 1, out)
    testing.ok(out:find("rows 1, 2 run 8cb600", 1, true), out)
    testing.ok(out:find("`dev board check %x+ %-%-run 8cb600`"), out)
end)

testing.test("check --run records the rows from a run that has ended", function()
    local out, code, body, log = group_check({ jobs = PASSED, attach = "8cb600" })
    testing.eq(code, 0, out)
    testing.ok(log:find("watch 8cb600 --watch", 1, true), log)
    testing.ok(not log:find("run --local", 1, true), log)
    testing.eq(check.parse(body).rows, {
        { result = "pass", run_id = "8cb600" },
        { result = "pass", run_id = "8cb600" },
    })
end)

testing.test("check --run records a failed job of the named run", function()
    local out, code, body = group_check({
        jobs = TEST_FAILED,
        attach = "8cb600",
        watch = "exit 1",
    })
    testing.eq(code, 1, out)
    testing.ok(body:find("1 pass 8cb600", 1, true), body)
    testing.ok(body:find("2 fail 8cb600", 1, true), body)
end)

testing.test("check --run refuses a run of another commit and records nothing", function()
    local out, code, body, log = group_check({
        jobs = PASSED,
        attach = "8cb600",
        source = "abcdef012345",
    })
    testing.eq(code, 1, out)
    testing.eq(body, nil)
    testing.ok(out:find("is of commit abcdef012345, not the checked commit", 1, true), out)
    testing.ok(not log:find("watch", 1, true), log)
end)

testing.test("check --run refuses a bad run id and a card with no shared run", function()
    local root, home = git_root()
    local id = card_with(root, home, { "true" })
    local _, code = dev(root, home, { "board", "check", id, "--run", "xyz" })
    testing.eq(code, 2)
    local out
    out, code = dev(root, home, { "board", "check", id, "--run", "8cb600" })
    testing.eq(code, 1, out)
    testing.ok(out:find("--run has nothing to record", 1, true), out)
    out, code = dev(root, home, { "board", "check", id, "--run", "8cb600", "--expect-fail" })
    testing.eq(code, 1, out)
    testing.ok(out:find("--run has nothing to record", 1, true), out)
end)

testing.test("check --run --expect-fail records the run rows as expect-fail", function()
    local out, code, body = group_check({
        jobs = TEST_FAILED,
        attach = "8cb600",
        expect_fail = true,
        rows = { "dev --remote lint", "dev --remote test -- tests/a_test.lua" },
    })
    testing.eq(code, 0, out)
    testing.ok(body:find("mode=expect-fail", 1, true), body)
    testing.ok(body:find("2 fail 8cb600", 1, true), body)
end)

testing.test("check --run --expect-fail exits 1 when the run rows passed", function()
    local out, code, body = group_check({
        jobs = PASSED,
        attach = "8cb600",
        expect_fail = true,
        rows = { "dev --remote lint", "dev --remote test -- tests/a_test.lua" },
    })
    testing.eq(code, 1, out)
    testing.ok(out:find("the passing ones prove nothing", 1, true), out)
    testing.ok(body:find("mode=expect-fail", 1, true), body)
end)

local BASELINE_ROWS = {
    "dev --remote test",
    "dev --remote test -- tests/x_test.lua",
    "dev --remote test -- tests/y_test.lua",
}

local function baseline_check(logs)
    local root, home = git_root({
        ["tests/a_test.lua"] = "x\n",
        ["tests/x_test.lua"] = "x\n",
        ["tests/y_test.lua"] = "x\n",
    })
    local id = card_with(root, home, BASELINE_ROWS)
    local bin = support.tempdir() .. "/bin"
    assert(fs.mkdir(bin, { parents = true }), "mkdir failed")
    assert(
        fs.write(bin .. "/ci", "#!/bin/sh\n" .. [[case "$1" in
-C) echo '{"jobs":[{"name":"lint"},{"name":"test"}]}' ;;
ps) echo '{"status":"failed"}' ;;
logs) echo "logs $*" >> "$CI_LOG"; ]] .. logs .. "\nesac\n"),
        "write failed"
    )
    assert(
        fs.write(
            bin .. "/dev",
            '#!/bin/sh\necho "dev $*" >> "$CI_LOG"\necho "run 8cb600"\nexit 1\n'
        ),
        "write failed"
    )
    must(dev_os.run({ "chmod", "755", bin .. "/ci", bin .. "/dev" }))
    local log = support.tempdir() .. "/ci.log"
    local env = { PATH = bin .. ":" .. os.getenv("PATH"), CI_LOG = log, DEV_AGENT = "" }
    local out, status = dev(root, home, { "board", "check", id, "--expect-fail" }, nil, env)
    local held = comments(home)
    return out, status, held[#held] and held[#held].body, fs.read(log) or ""
end

testing.test("an expect-fail named row starts no ci run of its own", function()
    local out, _, body, log = baseline_check('echo "PASS tests/a_test.lua"')
    testing.eq(select(2, log:gsub("dev %-%-remote test", "")), 1, out .. log)
    testing.ok(log:find("logs 8cb600 --job test", 1, true), log)
    testing.eq(#check.parse(body).rows, 3, body)
end)

testing.test("an expect-fail named row missing from the log records fail", function()
    local out, code, body = baseline_check('echo "PASS tests/a_test.lua"')
    testing.eq(code, 0, out)
    local rows = check.parse(body).rows
    testing.eq(rows[2].result, "fail", body)
    testing.eq(rows[3].result, "fail", body)
    testing.eq(rows[3].run_id, "8cb600", body)
end)

testing.test("an expect-fail named row that trunk passes still proves nothing", function()
    local out, code, body = baseline_check('echo "PASS tests/x_test.lua"')
    testing.eq(code, 1, out)
    testing.eq(check.parse(body).rows[2].result, "pass", body)
    testing.ok(out:find("the passing ones prove nothing", 1, true), out)
end)

testing.test("an expect-fail named row with an empty test log records error", function()
    local out, code, body = baseline_check("true")
    testing.eq(code, 1, out)
    testing.eq(check.parse(body).rows[2].result, "error", body)
end)

testing.test("check --run records a one-row card from a run that has ended", function()
    local out, code, body, log = group_check({
        jobs = PASSED,
        attach = "8cb600",
        rows = { "dev --remote test -- tests/a_test.lua" },
    })
    testing.eq(code, 0, out)
    testing.ok(log:find("watch 8cb600 --watch", 1, true), log)
    testing.eq(check.parse(body).rows, { { result = "pass", run_id = "8cb600" } })
end)

testing.test("plan shares one run only among rows that cover the whole pipeline", function()
    local function jobs(...)
        local names = { ... }
        return function()
            return names
        end
    end
    local function plan(rows, list)
        local argvs = {}
        for i, row in ipairs(rows) do
            argvs[i] = check.argv(row)
        end
        return check.plan(rows, argvs, list)
    end
    local both = { "dev --remote lint", "dev --remote test -- a b" }
    local found = plan(both, jobs("lint", "test"))
    testing.eq(found.args, { "a", "b" })
    testing.eq(found.rows[2], { index = 2, job = "test", run = "dev --remote test -- a b" })
    testing.eq(plan(both, jobs("lint", "test", "docs")), nil)
    testing.eq(plan(both, jobs("lint", "docs")), nil)
    testing.eq(plan(both, function() end), nil)
    testing.eq(plan({ "dev --remote lint" }, jobs("lint")), nil)
    testing.eq(plan({ "dev --remote lint", "dev --remote lint" }, jobs("lint", "test")), nil)
    testing.eq(plan({ "dev --remote lint", "! dev --remote test" }, jobs("lint", "test")), nil)
    testing.eq(plan({ "dev --remote lint -v", "dev --remote test" }, jobs("lint", "test")), nil)
    testing.eq(
        plan({ "dev --remote test -- a", "dev --remote lint -- b" }, jobs("lint", "test")),
        nil
    )
    local mixed = plan({ "rg x y", "dev --remote lint", "dev --remote test" }, jobs("lint", "test"))
    testing.eq(mixed.rows[1].index, 2)
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
        expected_head(head, "-", "expect-fail", { "false" }) .. "\n1 fail -"
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
    local id = card_with(root, home, { "/no-such-dir/no-such-command-for-check" })
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
            run = "/no-such-dir/no-such-command-for-check",
            argv = { "/no-such-dir/no-such-command-for-check" },
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
    local summary = check.summarize({ row }, true)
    testing.eq({ summary.passed, summary.good, summary.errors }, { 0, true, 0 })
end)

testing.test(
    "an expect-fail run passes the plain lint and test rows beside a failing row",
    function()
        local rows = {
            { result = check.Result.PASS, run = "dev --remote lint" },
            { result = check.Result.PASS, run = "dev --remote test" },
            { result = check.Result.FAIL, run = "dev --remote test -- tests/lua/new_test.lua" },
        }
        local summary = check.summarize(rows, true)
        testing.eq(
            summary,
            { passed = 2, not_run = 0, good = true, errors = 0, proves_nothing = 0 }
        )
        rows[3] =
            { result = check.Result.PASS, run = "dev --remote test -- tests/lua/new_test.lua" }
        summary = check.summarize(rows, true)
        testing.eq(
            summary,
            { passed = 3, not_run = 0, good = false, errors = 0, proves_nothing = 1 }
        )
    end
)

testing.test("an expect-fail run where no row fails is bad", function()
    local rows = {
        { result = check.Result.PASS, run = "dev --remote lint" },
        { result = check.Result.PASS, run = "dev --remote test" },
    }
    local summary = check.summarize(rows, true)
    testing.eq(summary, { passed = 2, not_run = 0, good = false, errors = 0, proves_nothing = 0 })
end)

testing.test("an expect-fail remote row that printed no run id never ran", function()
    testing.ok(check.never_started({ "dev", "--remote", "test" }, 1, nil))
    testing.ok(check.never_started({ "ci", "run" }, 2, nil))
    testing.ok(not check.never_started({ "dev", "--remote", "test" }, 1, "abc123"))
    testing.ok(not check.never_started({ "dev", "--remote", "test" }, 124, nil))
    testing.ok(not check.never_started({ "dev", "test", "--", "--remote" }, 1, nil))
    testing.ok(not check.never_started({ "rg", "-n", "x" }, 1, nil))
    testing.ok(check.never_started({ "rg", "-n", "x" }, 126, nil))
    local summary = check.summarize({ { result = "error" } }, true)
    testing.eq({ summary.passed, summary.good, summary.errors }, { 0, false, 1 })
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
        local listed = "\n" .. dev(root, home, { "board", "notes", id })
        local first = assert(listed:match("\n(%x+)[^\n]*dev%-check:"))
        out, code = dev(root, home, { "board", "note", id, "--edit", first, "fine" })
        testing.eq(code, 1, out)
        out, code = dev(root, home, { "board", "note", id, "--delete", first })
        testing.eq(code, 1, out)
        must(dev(root, home, { "board", "note", id, "plain" }))
        listed = "\n" .. dev(root, home, { "board", "notes", id })
        local second = assert(listed:match("\n(%x+)[^\n]*plain"))
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
        column = support.COLUMN_NAME.PROGRESS,
        size = "unsized",
        labels = {},
        checks = { "true" },
        outcomes = {},
    }
    local backend = { root = root }
    function backend:done_columns()
        return { support.COLUMN_NAME.DONE }
    end
    function backend:cards()
        return { card }
    end
    function backend:card(id)
        return support.listed_card(self, id)
    end
    function backend:comments()
        return {}
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

testing.test("a partial record that cannot be written does not stop the check", function()
    local root = git_root()
    local card = {
        id = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        name = "Card",
        column = support.COLUMN_NAME.PROGRESS,
        size = "unsized",
        labels = {},
        checks = { "true", "echo run 8cb600" },
        outcomes = {},
    }
    local backend = { root = root }
    local tries = 0
    function backend:done_columns()
        return { support.COLUMN_NAME.DONE }
    end
    function backend:cards()
        return { card }
    end
    function backend:card(id)
        return support.listed_card(self, id)
    end
    function backend:comments()
        return {}
    end
    function backend:note()
        tries = tries + 1
        return nil, "curl exit 28"
    end
    local result
    with_passing_ci(function()
        result = cmd_board.run("check", { "11111111" }, backend)
    end)
    testing.eq(tries, 3)
    testing.ok(result.message:find("1 pass - true", 1, true), result.message)
    testing.ok(result.message:find("2 pass 8cb600 echo run 8cb600", 1, true), result.message)
end)

testing.test("check posts a status note when it starts its rows", function()
    local root, home, head = git_root()
    local id = card_with(root, home, { "true", "echo run 8cb600" })
    local out, code = dev(root, home, { "board", "check", id }, nil, { DEV_AGENT = "t/runner/a" })
    testing.eq(code, 0, out)
    local started = start_notes(home)
    testing.eq(#started, 1)
    testing.eq(
        started[1].body,
        "Check started at commit " .. head:sub(1, 12) .. " on 2 rows, by t/runner/a."
    )
end)

testing.test("a check start note that cannot be written is told and the check goes on", function()
    local root = git_root()
    local card = {
        id = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        name = "Card",
        column = support.COLUMN_NAME.PROGRESS,
        size = "unsized",
        labels = {},
        checks = { "true" },
        outcomes = {},
    }
    local backend = { root = root }
    local bodies = {}
    function backend:done_columns()
        return { support.COLUMN_NAME.DONE }
    end
    function backend:cards()
        return { card }
    end
    function backend:card(id)
        return support.listed_card(self, id)
    end
    function backend:comments()
        return {}
    end
    function backend:note(_, body)
        bodies[#bodies + 1] = body
        if body:sub(1, #START_NOTE) == START_NOTE then
            return nil, "curl exit 28"
        end
        return true
    end
    local result = cmd_board.run("check", { "11111111" }, backend)
    testing.ok(result.code == nil or result.code == 0, result.message)
    testing.eq(#bodies, 2)
    testing.ok(bodies[2]:find("dev-check:", 1, true), bodies[2])
end)

testing.test("a check with run posts no start note", function()
    local out, code, _, _, started = group_check({ jobs = PASSED, attach = "8cb600" })
    testing.eq(code, 0, out)
    testing.eq(started, 0)
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

    testing.test("a parent behind the trunk tip is on trunk for the stack note", function()
        local root = setup()
        local bare = support.tempdir()
        local quiet = { stdout = "null", stderr = "null", env = IDENT }
        must(dev_os.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, quiet))
        must(dev_os.run({ "jj", "git", "init", root }, quiet))
        jj(root, "git", "remote", "add", "origin", bare)
        jj(root, "commit", "-m", "base")
        jj(root, "commit", "-m", "tip")
        jj(root, "bookmark", "create", "master", "-r", "@-")
        jj(root, "git", "push", "--remote", "origin", "--bookmark", "master")
        jj(root, "new", "-m", "work", "@--")
        testing.eq(land.stack_note(root), nil)
        jj(root, "new", "-m", "unlanded", "@")
        jj(root, "new", "-m", "work")
        local note = land.stack_note(root)
        testing.ok(note and note:find("not on trunk", 1, true), note)
    end)

    testing.test("check refuses outside the workspace named for the card", function()
        local root, home, ws = workspace()
        local id = card_with(root, home, { "true" })
        local out, code = dev(root, home, { "board", "check", id }, ws)
        testing.eq(code, 1, out)
        testing.ok(out:find("w2", 1, true), out)
        testing.ok(out:find("dev ws new " .. id, 1, true), out)
        testing.eq(#comments(home), 0)
    end)

    testing.test("check --expect-fail records in a workspace not named for the card", function()
        local root, home, ws = workspace()
        local id = card_with(root, home, { "false" })
        local out, code = dev(root, home, { "board", "check", id, "--expect-fail" }, ws)
        testing.eq(code, 0, out)
        testing.eq(#comments(home), 1)
    end)

    testing.test("check refuses an empty jj working-copy commit and names its parent", function()
        local root, home, ws = workspace()
        local id = card_with(root, home, { "true" })
        jj(ws, "workspace", "rename", id)
        local parent = jj(ws, "log", "-r", "@-", "--no-graph", "-T", "change_id"):match("^(%a+)")
        local out, code = dev(root, home, { "board", "check", id }, ws)
        testing.eq(code, 1, out)
        testing.ok(out:find("jj edit " .. parent, 1, true), out)
        testing.eq(#comments(home), 0)
    end)

    testing.test("check records a no-change card on an empty jj working-copy commit", function()
        local root, home, ws = workspace()
        local id = card_with(root, home, { "true" })
        jj(ws, "workspace", "rename", id)
        must(dev(root, home, { "board", "label", id, "+" .. board.NO_CHANGE }))
        local out, code = dev(root, home, { "board", "check", id }, ws)
        testing.eq(code, 0, out)
        testing.eq(#comments(home), 1)
    end)

    testing.test("check --expect-fail still runs on an empty jj working-copy commit", function()
        local root, home, ws = workspace()
        local id = card_with(root, home, { "false" })
        jj(ws, "workspace", "rename", id)
        local out, code = dev(root, home, { "board", "check", id, "--expect-fail" }, ws)
        testing.eq(code, 0, out)
        testing.eq(#comments(home), 1)
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
                expected_head(commit, change, "run", { "true" }) .. "\n1 pass -"
            )
            testing.ok(out:find(commit:sub(1, 12), 1, true), out)
        end
    )

    testing.test("in a jj workspace a row that edits files leaves nothing recorded", function()
        local root, home, ws = workspace()
        local id = card_with(root, home, { "touch made" })
        jj(ws, "workspace", "rename", id)
        assert(fs.write(ws .. "/edited", "x"))
        local out, code = dev(root, home, { "board", "check", id }, ws)
        testing.eq(code, 1, out)
        testing.ok(out:find("changed while the checks ran", 1, true), out)
        testing.eq(#comments(home), 0)
    end)
end

local DETACH_ROWS = { "dev --remote lint", "true", "dev --remote test" }

---@class board_check_test.detach_check.Opts
---@field rows string[]? the card's checks, DETACH_ROWS when nil
---@field test_state string? how the test job ended, passed when nil
---@field watch string? the shell the fake `ci ps RUN --watch` runs, given the run id as $4
---@field timeout string? the `--timeout` seconds
---@field expect_fail boolean? whether the check passes `--expect-fail`
---@field lint_start string? the shell the fake `dev --remote --detach lint` runs, printing the id when nil
---@field test_start string? the shell the fake `dev --remote --detach test` runs, printing the id when nil

local function detach_check(opts)
    local root, home = git_root({ ["tests/a_test.lua"] = "x\n" })
    local id = card_with(root, home, opts.rows or DETACH_ROWS)
    local bin = support.tempdir() .. "/bin"
    assert(fs.mkdir(bin, { parents = true }), "mkdir failed")
    local state = opts.test_state or "passed"
    local code = state == "passed" and "0" or "3"
    assert(
        fs.write(bin .. "/ci", "#!/bin/sh\n" .. [[case "$1" in
-C)
    case "$3" in
    ps) echo "watch $4" >> "$CI_LOG"; ]] .. (opts.watch or "exit 0") .. [[ ;;
    run) echo '{"jobs":[{"name":"lint"},{"name":"test"},{"name":"docs"}]}' ;;
    esac ;;
ps)
    case "$2" in
    8cb600) echo '{"jobs":[{"name":"lint","state":"passed","exit_code":0}]}' ;;
    1f2e3d) echo '{"jobs":[{"name":"test","state":"]] .. state .. [[","exit_code":]] .. code .. [[}]}' ;;
    esac ;;
logs) echo "logs $*" >> "$CI_LOG"; echo "output of $4" ;;
esac
]]),
        "write failed"
    )
    assert(
        fs.write(bin .. "/dev", "#!/bin/sh\n" .. [[echo "dev $*" >> "$CI_LOG"
case "$2" in
*detach*)
    case "$3" in
    lint) ]] .. (opts.lint_start or "echo 8cb600") .. [[ ;;
    test) ]] .. (opts.test_start or "echo 1f2e3d") .. [[ ;;
    esac ;;
esac
]]),
        "write failed"
    )
    must(dev_os.run({ "chmod", "755", bin .. "/ci", bin .. "/dev" }))
    local log = support.tempdir() .. "/ci.log"
    local env = { PATH = bin .. ":" .. os.getenv("PATH"), CI_LOG = log, DEV_AGENT = "" }
    local args = { "board", "check", id }
    if opts.expect_fail then
        args[#args + 1] = "--expect-fail"
    end
    if opts.timeout then
        args[#args + 1] = "--timeout"
        args[#args + 1] = opts.timeout
    end
    local out, status = dev(root, home, args, nil, env)
    local held = comments(home)
    return out, status, held[#held] and held[#held].body, fs.read(log) or "", #held
end

testing.test("check starts every ci row first and waits for them afterwards", function()
    local out, code, body, log = detach_check({})
    testing.eq(code, 0, out)
    local lint = log:find("dev --remote --detach lint", 1, true)
    local test = log:find("dev --remote --detach test", 1, true)
    local watch = log:find("watch ", 1, true)
    testing.ok(lint and test and watch and lint < watch and test < watch, log)
    local started = out:find("started row 3 of 3 as ci run 1f2e3d", 1, true)
    testing.ok(started and started < out:find("running 2 of 3: true", 1, true), out)
    testing.ok(out:find("running 2 of 3: true", 1, true) < out:find("waiting on row 1", 1, true))
    testing.eq(check.parse(body).rows, {
        { result = "pass", run_id = "8cb600" },
        { result = "pass", run_id = "-" },
        { result = "pass", run_id = "1f2e3d" },
    })
end)

testing.test("a check with a failed row others report and record, and it fails", function()
    local out, code, body = detach_check({ test_state = "failed" })
    testing.eq(code, 1, out)
    testing.ok(out:find("1 pass 8cb600 dev --remote lint", 1, true), out)
    testing.ok(out:find("3 fail 1f2e3d dev --remote test", 1, true), out)
    testing.eq(check.parse(body).rows, {
        { result = "pass", run_id = "8cb600" },
        { result = "pass", run_id = "-" },
        { result = "fail", run_id = "1f2e3d" },
    })
end)

testing.test("an expect-fail stays serial and starts no row detached", function()
    local out, _, _, log =
        detach_check({ rows = { "dev --remote lint", "true" }, expect_fail = true })
    testing.ok(not log:find("--detach", 1, true), log)
    testing.ok(out:find("running 1 of 2: dev --remote lint", 1, true), out)
    testing.ok(not out:find("started row", 1, true), out)
end)

testing.test("a row wait keeps time limit and a started row that outlives it times out", function()
    local out, code, body = detach_check({
        timeout = "2",
        watch = [[case "$4" in 1f2e3d) sleep 30 ;; esac]],
    })
    testing.eq(code, 1, out)
    testing.eq(check.parse(body).rows[1], { result = "pass", run_id = "8cb600" })
    local last = check.parse(body).rows[3]
    testing.eq({ last.result, last.run_id }, { "timeout", "1f2e3d" })
end)

testing.test("a refused start records nothing, names the row and starts no more", function()
    local out, code, _, log, held = detach_check({
        lint_start = 'echo "error: fleet is draining"; exit 12',
    })
    testing.eq(code, 1, out)
    testing.eq(held, 0)
    testing.ok(out:find("The ci hub refused row 1 (dev --remote lint)", 1, true), out)
    testing.ok(not log:find("--detach test", 1, true), log)
end)

testing.test("a start that fails with no run id records the row as fail", function()
    local out, code, body = detach_check({ lint_start = "echo boom; exit 1" })
    testing.eq(code, 1, out)
    local rows = check.parse(body).rows
    testing.eq({ rows[1].result, rows[1].run_id }, { "fail", "-" })
    testing.eq({ rows[3].result, rows[3].run_id }, { "pass", "1f2e3d" })
end)

testing.test("a start that exits 0 with no run id records the row as pass", function()
    local out, code, body = detach_check({ lint_start = "true" })
    testing.eq(code, 0, out)
    testing.eq(check.parse(body).rows[1], { result = "pass", run_id = "-" })
end)

testing.test("a named row runs on its own without a plain test row", function()
    local out, code, body, log = detach_check({
        rows = { "dev --remote lint", "dev --remote test -- tests/a_test.lua" },
    })
    testing.eq(code, 0, out)
    testing.ok(log:find("dev --remote --detach test -- tests/a_test.lua", 1, true), log)
    testing.ok(not log:find("logs ", 1, true), log)
    testing.eq(#check.parse(body).rows, 2)
end)

testing.test("a named row runs on its own when the plain test row has no ci run id", function()
    local out, code, body, log = detach_check({
        rows = { "dev --remote test", "dev --remote test -- tests/a_test.lua" },
        test_start = "true",
    })
    testing.eq(code, 0, out)
    testing.ok(out:find("running 2 of 2: dev --remote test -- tests/a_test.lua", 1, true), out)
    testing.ok(log:find("dev --remote test -- tests/a_test.lua", 1, true), log)
    testing.ok(not log:find("logs ", 1, true), log)
    testing.eq(check.parse(body).rows, {
        { result = "pass", run_id = "-" },
        { result = "pass", run_id = "-" },
    })
end)

testing.test("a named row with a dashed word runs on its own beside a plain test row", function()
    local out, code, body, log = detach_check({
        rows = { "dev --remote test", "dev --remote test -- --verbose tests/a_test.lua" },
    })
    testing.eq(code, 0, out)
    testing.eq(select(2, log:gsub("dev %-%-remote %-%-detach test", "")), 2, log)
    testing.eq(check.parse(body).rows, {
        { result = "pass", run_id = "1f2e3d" },
        { result = "pass", run_id = "1f2e3d" },
    })
end)

local function baseline_of(rows)
    local argvs = {}
    for i, row in ipairs(rows) do
        argvs[i] = check.argv(row)
    end
    return check.baseline(rows, argvs)
end

testing.test("the baseline drops the standard rows and keeps the rows a card adds", function()
    local both = { "rg -n x y", "dev --remote lint", "dev --remote test" }
    testing.eq(baseline_of(both).commands, { "rg -n x y" })
    testing.eq(baseline_of(both).skipped, 2)
    testing.eq(baseline_of({ "false", "! rg -n x y" }).skipped, 0)
end)

testing.test("the baseline keeps the standard test row when a new row is a test", function()
    local rows = { "dev --remote lint", "dev --remote test", "dev --remote test -- tests/a.lua" }
    local baseline = baseline_of(rows)
    testing.eq(baseline.commands, { "dev --remote test", "dev --remote test -- tests/a.lua" })
    testing.eq(baseline.skipped, 1)
end)

testing.test("the baseline keeps every row when the card adds none", function()
    local rows = { "dev --remote lint", "dev --remote test" }
    local baseline = baseline_of(rows)
    testing.eq(baseline.commands, rows)
    testing.eq(baseline.skipped, 0)
end)

testing.test("a record names its trunk proof and parse reads it back", function()
    local state = { commit = "abc123", change = "-", proof = "8af0e001@0123456789ab" }
    local rows = { { result = "fail", run_id = "-", run = "false" } }
    local record = check.parse(check.record(state, rows, true))
    testing.eq(record.proof, "8af0e001@0123456789ab")
    testing.eq(record.mode, "expect-fail")
    testing.eq(#record.rows, 1)
    testing.eq(check.parse(check.record(state, rows, true):gsub(" proof=%S+", "")).proof, nil)
end)

testing.test("expect-fail skips the standard rows when a landed card proves trunk", function()
    local root, home, base = git_root()
    assert(fs.write(root .. "/next.txt", "x\n"))
    local function git(...)
        local argv =
            { "git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@example.com", ... }
        must(dev_os.run(argv, { stdout = "null" }))
    end
    git("add", "-A")
    git("commit", "-q", "-m", "next")

    -- A landed card in Release proves the parent commit
    local landed = card_with(root, home, { "true" })
    local note = "Landed commit " .. base .. " on trunk, run by x."
    must(dev(root, home, { "board", "note", landed, note }))
    support.place(support.board_file(home, "mine"), landed, support.COLUMN_NAME.RELEASE)

    -- The baseline runs only the new row and names the proof
    local id = card_with(root, home, { "false", "dev --remote lint", "dev --remote test" })
    local out, code = dev(root, home, { "board", "check", id, "--expect-fail" })
    testing.eq(code, 0, out)
    testing.ok(out:find("1 fail - false", 1, true), out)
    testing.ok(out:find("left out 2 standard rows", 1, true), out)
    local proof = landed .. "@" .. base:sub(1, 12)
    testing.ok(out:find(proof, 1, true), out)

    -- The stored record carries the proof
    local doc = assert(json.decode(assert(fs.read(support.board_file(home, "mine")))))
    for _, card in ipairs(doc.cards) do
        if card.id:sub(1, #id) == id then
            local record = check.parse(card.comments[#card.comments].body)
            testing.eq(record.proof, proof)
            testing.eq(#record.rows, 1)
        end
    end
end)

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

testing.test("board.worked finds a note after a claim record and stops at the next one", function()
    local STATUS, DECISION = board.NoteKind.STATUS, board.NoteKind.DECISION
    local function note(who, body, kind)
        return { who = who, body = body, kind = kind }
    end
    local claim = note("agents", board.claim_record("r/one"), STATUS)
    local function worked(...)
        return board.worked({ ... }, "r/one")
    end
    testing.eq(worked(note("agents", "built it")), false)
    testing.eq(worked(claim), false)
    testing.eq(worked(claim, note("agents", "built it")), true)
    testing.eq(worked(claim, note("other", "built it")), false)
    testing.eq(worked(claim, note("agents", "ruled", DECISION)), false)
    testing.eq(worked(claim, note("agents", "dev-check: x", STATUS)), false)
    testing.eq(worked(claim, claim, note("agents", "built it")), true)
    testing.eq(
        worked(
            claim,
            note("agents", board.claim_record("r/two"), STATUS),
            note("agents", "built it")
        ),
        false
    )
    testing.eq(worked(claim, note("agents", "built it"), claim), true)
end)

local DEV_LOG = table.concat({
    "running tests",
    "PASS tests/lua/a_test.lua",
    "SKIP tests/lua/b_test.lua (every case skipped)",
    "FAIL tests/lua/c_test.lua",
    "TIMEOUT tests/lua/d_test.lua",
    "SIGSEGV tests/lua/e_test.lua",
    "> tests/lua/a_test.lua",
}, "\n")

local NEXTEST_LOG = table.concat({
    "        PASS [   0.016s] (1/2) ci agent::tests::step_title::should_x",
    "        FAIL [   0.020s] (2/2) ci agent::tests::step_title::should_y",
    "        PASS [   0.011s] (3/3) ci other::tests::ok",
}, "\n")

testing.test("a named test passes on a PASS or SKIP line", function()
    local PASS, FAIL = check.Result.PASS, check.Result.FAIL
    testing.eq((check.named_result(DEV_LOG, { "tests/lua/a_test.lua" })), PASS)
    testing.eq((check.named_result(DEV_LOG, { "tests/lua/b_test.lua" })), PASS)
    testing.eq(
        (check.named_result(DEV_LOG, { "tests/lua/a_test.lua", "tests/lua/b_test.lua" })),
        PASS
    )
    testing.eq((check.named_result(DEV_LOG, { "tests/lua/c_test.lua" })), FAIL)
    testing.eq((check.named_result(DEV_LOG, { "tests/lua/d_test.lua" })), FAIL)
    testing.eq((check.named_result(DEV_LOG, { "tests/lua/e_test.lua" })), FAIL)
    local result, reason =
        check.named_result(DEV_LOG, { "tests/lua/a_test.lua", "tests/lua/c_test.lua" })
    testing.eq(result, FAIL)
    testing.eq(reason, "FAIL tests/lua/c_test.lua")
end)

testing.test("a TAP ok line passes a named row", function()
    local log = table.concat({
        "1..3",
        "ok 240 volume-restart-vm",
        "ok 241 volume-skip # skip no vm",
        "not ok 242 volume-broken",
    }, "\n")
    testing.eq((check.named_result(log, { "volume-restart-vm" })), check.Result.PASS)
    testing.eq((check.named_result(log, { "volume-skip" })), check.Result.PASS)
    testing.eq((check.named_result(DEV_LOG, { "tests/lua/a_test.lua" })), check.Result.PASS)
end)

testing.test("a TAP not ok line fails a named row", function()
    local log = table.concat({ "ok 1 fine", "not ok 2 volume-broken" }, "\n")
    local result, reason = check.named_result(log, { "volume-broken" })
    testing.eq(result, check.Result.FAIL)
    testing.eq(reason, "not ok 2 volume-broken")
    testing.eq((check.named_result(log, { "fine", "volume-broken" })), check.Result.FAIL)
end)

testing.test("a named test matches whole nextest path segments", function()
    local PASS, FAIL, ERROR = check.Result.PASS, check.Result.FAIL, check.Result.ERROR
    testing.eq((check.named_result(NEXTEST_LOG, { "other::tests::ok" })), PASS)
    testing.eq((check.named_result(NEXTEST_LOG, { "other" })), PASS)
    testing.eq((check.named_result(NEXTEST_LOG, { "tests::ok" })), PASS)
    testing.eq((check.named_result(NEXTEST_LOG, { "step_title::should_y" })), FAIL)
    testing.eq((check.named_result(NEXTEST_LOG, { "step_title" })), FAIL)
    testing.eq((check.named_result(NEXTEST_LOG, { "should" })), ERROR)
    testing.eq((check.named_result(NEXTEST_LOG, { "tests::o" })), ERROR)
    testing.eq((check.named_result(NEXTEST_LOG, { "gent::tests" })), ERROR)
end)

testing.test("a named test missing from the log is an error", function()
    local missing = { "tests/lua/a_test.lua", "tests/lua/zzz_test.lua" }
    local result, reason = check.named_result(DEV_LOG, missing)
    testing.eq(result, check.Result.ERROR)
    testing.eq(reason:find("tests/lua/zzz_test.lua", 1, true) ~= nil, true)
    result, reason = check.named_result(DEV_LOG, missing, true)
    testing.eq(result, check.Result.FAIL)
    testing.eq(reason:find("tests/lua/zzz_test.lua", 1, true) ~= nil, true)
    testing.eq((check.named_result("", { "x" })), check.Result.ERROR)
    local both = { "tests/lua/c_test.lua", "tests/lua/zzz_test.lua" }
    testing.eq((check.named_result(DEV_LOG, both)), check.Result.FAIL)
    local header = table.concat({ "running tests", "> tests/lua/a_test.lua" }, "\n")
    testing.eq((check.named_result(header, { "tests/lua/a_test.lua" })), check.Result.ERROR)
end)

testing.test("a named directory reads every suite under it", function()
    local PASS, FAIL = check.Result.PASS, check.Result.FAIL
    local lines =
        { "PASS tests/lua/a_test.lua", "SKIP tests/lua/b_test.lua", "PASS tests/bats/x.bats" }
    local passing = table.concat(lines, "\n")
    testing.eq((check.named_result(passing, { "tests/lua" })), PASS)
    testing.eq((check.named_result(passing, { "tests" })), PASS)
    testing.eq((check.named_result(DEV_LOG, { "tests/lua" })), FAIL)
    local failing = table.concat({ passing, "FAIL tests/lua/z_test.lua" }, "\n")
    testing.eq((check.named_result(failing, { "tests/lua" })), FAIL)
    testing.eq((check.named_result(passing, { "tests/lu" })), check.Result.ERROR)
    testing.eq((check.named_result(passing, { "tests/bats" })), PASS)
end)
