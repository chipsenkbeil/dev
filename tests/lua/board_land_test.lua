local ffi = require("ffi")

local testing = require("dev.testing")
local board = require("dev.board")
local check = require("dev.board.check")
local cmd_board = require("dev.cmd.board")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local land = require("dev.board.land")
local localboard = require("dev.board.localboard")
local review = require("dev.board.review")
local store = require("dev.board.store")
local support = require("support")
local turn = require("dev.board.turn")
local vcs = require("dev.vcs")
local ws = require("dev.cmd.ws")

local has_jj = dev_os.which("jj") ~= nil
local IDENT = { JJ_USER = "t", JJ_EMAIL = "t@example.com" }
local LAND_STUB = [[#!/bin/sh
for word in "$@"; do
    if [ -n "$LOG_FAIL_AT" ] && [ "$word" = "$LOG_FAIL_AT" ]; then
        exit 1
    fi
    case "$word" in
    *bare*)
        if [ -n "$SHAPE_FAIL" ]; then
            exit 1
        fi
        ;;
    interdiff)
        if [ -n "$INTERDIFF_FAIL" ]; then
            exit 1
        fi
        if [ -n "$INTERDIFF_FAIL_AT" ]; then
            case "$*" in
            *"$INTERDIFF_FAIL_AT"*) exit 1 ;;
            esac
        fi
        ;;
    *"- & ::@-"*)
        if [ -n "$ANCESTOR_FAIL_AT" ] && [ "$word" = "$ANCESTOR_FAIL_AT- & ::@-" ]; then
            exit 1
        fi
        ;;
    [0-9a-f]*-)
        if [ -n "$PARENT_FAIL_AT" ] && [ "$word" = "$PARENT_FAIL_AT-" ]; then
            exit 1
        fi
        ;;
    fetch)
        if [ -n "$FETCH_LOG" ]; then
            echo fetch >>"$FETCH_LOG"
        fi
        if [ -n "$FETCH_REFUSALS" ]; then
            count=$(cat "$FETCH_COUNT" 2>/dev/null || echo 0)
            if [ "$count" -lt "$FETCH_REFUSALS" ]; then
                echo $((count + 1)) >"$FETCH_COUNT"
                echo "agent refused operation"
                exit 1
            fi
        fi
        if [ -n "$FETCH_HANG" ]; then
            exec sleep 30
        fi
        if [ -n "$FETCH_FAIL" ] && [ -s "$LAND_LOG" ]; then
            echo "fetch refused"
            exit 1
        fi
        ;;
    esac
    if [ "$word" = land ]; then
        echo "$* DEV_BOARD_LAND=${DEV_BOARD_LAND:-unset}" >>"$LAND_LOG"
        if [ -n "$BREAK_BOARD" ]; then
            printf '{' >"$BREAK_BOARD"
        fi
        if [ "$LAND_TRUNK" = rewrite ]; then
            "$REAL_JJ" describe -m "feat: work, rewritten" >/dev/null 2>&1
        fi
        if [ -n "$LAND_TRUNK" ]; then
            "$REAL_JJ" bookmark set master -r @ >/dev/null 2>&1
            "$REAL_JJ" git push --remote origin --bookmark master >/dev/null 2>&1
        fi
        if [ -n "$LAND_NEW" ]; then
            "$REAL_JJ" new >/dev/null 2>&1
        fi
        if [ -n "$LAND_STRAY" ]; then
            echo stray >"$LAND_STRAY"
        fi
        echo "$LAND_MSG"
        exit "${LAND_CODE:-0}"
    fi
done
exec "$REAL_JJ" "$@"
]]
local COMMIT = ("a"):rep(40)
local OTHER = ("b"):rep(40)
local PAST_HOLD_SECONDS = 2.2
local CHECK_WAIT_SECONDS = 60
local CHECK_STOP_SECONDS = 300
local SHARED = "a\nb\nc\nd\ne\nf\ng\n"

local function setup(extra)
    local root = support.sandbox({
        [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "mine"\n' .. (extra or ""),
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    assert(fs.write(home .. "/.config/dev/config.toml", ""), "write failed")
    return root, home, support.tempdir() .. "/land.log"
end

local function must(first, second)
    local code = type(first) == "number" and first or second
    assert(code == 0, tostring(first))
end

local function checked(commit, mode, rows)
    local lines = { "dev-check: commit=" .. commit .. " change=chg mode=" .. mode }
    for i, row in ipairs(rows) do
        lines[#lines + 1] = i .. " " .. row
    end
    return { body = table.concat(lines, "\n") }
end

local function reviewed(kind, commit)
    return { body = "dev-review: kind=" .. kind .. " by=r commit=" .. commit .. " change=chg" }
end

local STATE = { commit = COMMIT, change = "chg" }

testing.test("check.parse reads what check.record wrote and nothing else", function()
    local rows = {
        { run_id = "8cb600", run = "dev lint", result = "pass", code = 0, tail = "" },
        { run_id = "-", run = "dev test", result = "fail", code = 1, tail = "" },
    }
    local record = check.parse(check.record(STATE, rows, true))
    testing.eq(record.commit, COMMIT)
    testing.eq(record.change, "chg")
    testing.eq(record.mode, check.MODE.EXPECT_FAIL)
    testing.eq(record.rows, {
        { run_id = "8cb600", run = "dev lint", result = "pass" },
        { run_id = "-", run = "dev test", result = "fail" },
    })
    testing.eq(check.parse("a note"), nil)
    testing.eq(check.parse("dev-check: commit=zz change=c mode=run"), nil)
    testing.eq(check.parse("dev-check: commit=aa change=c mode=run\n2 pass x"), nil)
    testing.eq(check.parse("dev-check: commit=aa change=c mode=run\n1 pass dev lint"), nil)
    testing.eq(check.parse("dev-check: commit=aa change=c mode=run\n1 pass zz dev lint"), nil)
end)

testing.test("review.parse reads what review.record wrote and nothing else", function()
    local text = review.record("style", "rev1", { commit = COMMIT, change = "chg" }, "minor")
    testing.eq(
        review.parse(text),
        { kind = "style", by = "rev1", commit = COMMIT, change = "chg", verdict = "minor" }
    )
    testing.eq(
        review.parse("dev-review: kind=code by=r commit=" .. COMMIT .. " change=chg"),
        { kind = "code", by = "r", commit = COMMIT, change = "chg" }
    )
    testing.eq(review.parse("dev-review: kind=style"), nil)
    testing.eq(review.parse("a note"), nil)
end)

testing.test("missing_reviews wants a code and a style review of the change", function()
    testing.eq(
        land.missing_reviews({ reviewed("code", COMMIT), reviewed("style", COMMIT) }, STATE),
        {}
    )
    local missing = land.missing_reviews({ reviewed("code", COMMIT) }, STATE)
    testing.eq(#missing, 1)
    testing.ok(missing[1]:find("no style review", 1, true), missing[1])
    testing.eq(#land.missing_reviews({}, STATE), 2)
    testing.eq(
        #land.missing_reviews(
            { reviewed("code", COMMIT), reviewed("style", COMMIT) },
            { commit = COMMIT, change = "other" }
        ),
        2
    )
end)

local function judged(kind, commit, by, verdict)
    return {
        body = review.record(kind, by, { commit = commit, change = "chg" }, verdict),
    }
end

testing.test("refused_reviews names the reviewer whose latest verdict is needs-work", function()
    testing.eq(land.refused_reviews({ judged("code", COMMIT, "r1", "clean") }, STATE), {})
    testing.eq(land.refused_reviews({ judged("style", COMMIT, "r2", "minor") }, STATE), {})
    testing.eq(land.refused_reviews({ reviewed("code", COMMIT) }, STATE), {})
    local refused = land.refused_reviews({ judged("style", COMMIT, "r2", "needs-work") }, STATE)
    testing.eq(#refused, 1)
    testing.ok(refused[1]:find("style review by r2", 1, true), refused[1])
    testing.ok(refused[1]:find("needs-work", 1, true), refused[1])
    refused = land.refused_reviews({ judged("recheck", COMMIT, "r3", "needs-work") }, STATE)
    testing.ok(refused[1]:find("recheck review by r3", 1, true), refused[1])
    testing.eq(
        land.refused_reviews({
            judged("code", COMMIT, "r1", "needs-work"),
            judged("code", COMMIT, "r4", "clean"),
        }, STATE),
        {}
    )
    testing.eq(land.refused_reviews({ judged("code", OTHER, "r1", "needs-work") }, STATE), {})
end)

testing.test("a review of an earlier commit needs a recheck at the landing commit", function()
    local old = { reviewed("code", OTHER), reviewed("style", OTHER) }
    local missing = land.missing_reviews(old, STATE)
    testing.eq(#missing, 2)
    testing.ok(missing[1]:find("earlier commit", 1, true), missing[1])
    old[#old + 1] = reviewed("recheck", OTHER)
    testing.eq(#land.missing_reviews(old, STATE), 2)
    old[#old + 1] = reviewed("recheck", COMMIT)
    testing.eq(land.missing_reviews(old, STATE), {})
end)

testing.test("checks_problem counts only the newest passing run at the commit", function()
    local rows = { "dev lint", "dev test" }
    local pass = checked(COMMIT, check.MODE.RUN, { "pass - dev lint", "pass - dev test" })
    testing.eq(land.checks_problem({ pass }, STATE, rows), nil)
    testing.ok(land.checks_problem({ pass }, STATE, {}):find("no checks rows", 1, true))
    testing.ok(land.checks_problem({}, STATE, rows):find("no run of dev board check", 1, true))
    testing.ok(
        land.checks_problem(
            { checked(OTHER, check.MODE.RUN, { "pass - a", "pass - b" }) },
            STATE,
            rows
        )
            :find("no run of dev board check", 1, true)
    )
    local expect = checked(COMMIT, check.MODE.EXPECT_FAIL, { "fail - dev lint", "fail - dev test" })
    testing.ok(land.checks_problem({ expect }, STATE, rows):find("expect-fail", 1, true))
    local failed = checked(COMMIT, check.MODE.RUN, { "pass - dev lint", "fail - dev test" })
    testing.ok(land.checks_problem({ pass, failed }, STATE, rows):find("2 fail dev test", 1, true))
    testing.eq(land.checks_problem({ failed, pass }, STATE, rows), nil)
    testing.ok(land.checks_problem({ pass }, STATE, { "dev lint" }):find("has 2 rows", 1, true))
    testing.ok(land.checks_problem({ pass }, STATE, { "dev lint", "dev x" }):find("dev x", 1, true))
    testing.ok(
        land.checks_problem(
            { checked(COMMIT, check.MODE.RUN, { "timeout - dev lint" }) },
            STATE,
            { "dev lint" }
        )
    )
end)

testing.test("checks_problem says a record it cannot read is unreadable, not missing", function()
    local rows = { "dev lint", "dev test" }
    local unreadable =
        { body = checked(COMMIT, check.MODE.RUN, { "pass dev lint", "pass dev test" }).body }
    local problem = land.checks_problem({ unreadable }, STATE, rows)
    testing.ok(problem:find("could not be read", 1, true), problem)
    testing.ok(problem:find(land.short(COMMIT), 1, true), problem)
    testing.ok(problem:find("run dev board check again", 1, true), problem)
    testing.eq(check.unreadable(unreadable.body), COMMIT)
    local other = checked(OTHER, check.MODE.RUN, { "pass dev lint", "pass dev test" })
    testing.ok(
        land.checks_problem({ other }, STATE, rows):find("no run of dev board check", 1, true)
    )
    local pass = checked(COMMIT, check.MODE.RUN, { "pass - dev lint", "pass - dev test" })
    testing.eq(land.checks_problem({ unreadable, pass }, STATE, rows), nil)
    testing.ok(
        land.checks_problem({ pass, unreadable }, STATE, rows):find("could not be read", 1, true)
    )
    testing.eq(check.unreadable(pass.body), nil)
    testing.eq(check.unreadable("a note"), nil)
end)

testing.test("an unreadable expect-fail record never refuses a landing", function()
    local rows = { "dev lint", "dev test" }
    local pass = checked(COMMIT, check.MODE.RUN, { "pass - dev lint", "pass - dev test" })
    local skipped = checked(COMMIT, check.MODE.EXPECT_FAIL, { "fail dev lint", "fail dev test" })
    testing.eq(check.unreadable(skipped.body), COMMIT)
    testing.eq(select(2, check.unreadable(skipped.body)), check.MODE.EXPECT_FAIL)
    testing.eq(land.checks_problem({ pass, skipped }, STATE, rows), nil)
    testing.eq(land.checks_problem({ skipped, pass }, STATE, rows), nil)
    local unreadable = checked(COMMIT, check.MODE.RUN, { "pass dev lint", "pass dev test" })
    testing.ok(
        land.checks_problem({ pass, unreadable }, STATE, rows):find("could not be read", 1, true)
    )
    testing.ok(
        land.checks_problem({ skipped }, STATE, rows):find("no run of dev board check", 1, true)
    )
end)

local function dev(root, home, log, args, extra)
    local env = {
        HOME = home,
        XDG_STATE_HOME = home .. "/state",
        JJ_USER = "t",
        JJ_EMAIL = "t@example.com",
        DEV_AGENT = "dotfiles/lander",
        LAND_LOG = log,
        LAND_MSG = "stub land",
        REAL_JJ = dev_os.which("jj"),
    }
    for name, value in pairs(extra or {}) do
        env[name] = value
    end
    return support.dev(root, args, { env = env })
end

local function board_card(doc, id)
    for _, card in ipairs(doc.cards) do
        if id and card.id:sub(1, #id) == id then
            return card
        end
    end
    for _, card in ipairs(doc.cards) do
        if card.name ~= turn.NAME then
            return card
        end
    end
end

local function comments(home, id)
    local doc = assert(
        json.decode(assert(fs.read(home .. "/state/dev/boards/mine.json"), "read failed")),
        "decode failed"
    )
    return board_card(doc, id).comments or {}
end

local function claim_of(home, id)
    local doc = assert(
        json.decode(assert(fs.read(home .. "/state/dev/boards/mine.json"), "read failed")),
        "decode failed"
    )
    return board_card(doc, id).claim
end

local function landed_calls(log)
    return fs.read(log) or ""
end

local function column_of(home, id)
    local doc = assert(
        json.decode(assert(fs.read(home .. "/state/dev/boards/mine.json"), "read failed")),
        "decode failed"
    )
    local card = board_card(doc, id)
    for _, column in ipairs(doc.columns) do
        if column.id == card.column_id then
            return column.name
        end
    end
    return "?"
end

local function new_card(root, home, log)
    must(dev(root, home, log, { "board", "init" }))
    local out = dev(root, home, log, {
        "board",
        "add",
        "Card",
        "--problem",
        "x",
        "--size",
        "1",
        "--done-when",
        "It works",
    })
    local id = assert(out:match("added (%x+)"), out)
    must(dev(root, home, log, { "board", "checks", id, "true" }))
    if fs.is_dir(root .. "/.jj") then
        local rename = { "jj", "-R", root, "workspace", "rename", id }
        must(dev_os.run(rename, { stdout = "null", stderr = "null", env = IDENT }))
    end
    return id
end

local function approve_reviews(root, home, log, id)
    for _, kind in ipairs({ "code", "style" }) do
        must(dev(root, home, log, {
            "board",
            "review",
            id,
            "--kind",
            kind,
            "--by",
            "rev",
            "--rev",
            "@",
            "--verdict",
            "clean",
        }))
    end
end

local function approve(root, home, log, id)
    approve_reviews(root, home, log, id)
    must(dev(root, home, log, { "board", "check", id }))
    must(dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
end

local function refused(root, home, log, id, wanted, extra)
    local out, code = dev(root, home, log, { "board", "land", id }, extra)
    testing.eq(code, 1, out)
    for _, text in ipairs(wanted) do
        testing.ok(out:find(text, 1, true), text .. "\n" .. out)
    end
    testing.eq(landed_calls(log), "")
    testing.eq(out:find("landed " .. id, 1, true), nil)
    testing.ok(column_of(home) ~= support.COLUMN_NAME.DONE, column_of(home))
    return out
end

testing.test("land refuses a git project and a caller with no name", function()
    local root, home, log = setup()
    must(dev_os.run({ "git", "init", "-q", root }, { stdout = "null" }))
    local id = new_card(root, home, log)
    refused(root, home, log, id, { "needs a jj project" })
    local out, code = dev(root, home, log, { "board", "land", id }, { DEV_AGENT = "" })
    testing.eq(code, 2, out)
    testing.ok(out:find("needs DEV_AGENT", 1, true), out)
    out, code = dev(root, home, log, { "board", "land" })
    testing.eq(code, 2, out)
    testing.ok(out:find("needs a card", 1, true), out)
end)

testing.test("land refuses an agent name that is not one word", function()
    local root, home, log = setup()
    local id = new_card(root, home, log)
    local out, code = dev(root, home, log, { "board", "land", id }, { DEV_AGENT = "two words" })
    testing.eq(code, 2, out)
    testing.ok(out:find("an agent name is one word of letters, digits and . - _ /", 1, true), out)
    testing.eq(landed_calls(log), "")
end)

local CARD_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
local CARD_PREFIX = CARD_ID:sub(1, 8)

local function fake_backend(root, card)
    local backend = { root = root, column_map = {}, notes = {} }
    if root and fs.is_dir(root .. "/.jj") then
        local rename = { "jj", "-R", root, "workspace", "rename", CARD_PREFIX }
        must(dev_os.run(rename, { stdout = "null", stderr = "null", env = IDENT }))
    end
    card = card or {}
    local view = {
        id = CARD_ID,
        name = "Card",
        column = support.COLUMN_NAME.VERIFY,
        labels = {},
        outcomes = { { id = "o1", name = "It works", done = true } },
        checks = { "true" },
    }
    for key, value in pairs(card) do
        view[key] = value
    end
    function backend:done_columns()
        return { support.COLUMN_NAME.DONE }
    end
    function backend:columns()
        return backend.rows or {}
    end
    function backend:cards()
        return { view }
    end
    function backend:comments()
        return {}
    end
    function backend:note(_, text)
        self.notes[#self.notes + 1] = text
        return true
    end
    return backend
end

local function land_as_lander(backend)
    local previous = os.getenv("DEV_AGENT") or ""
    ffi.C.setenv("DEV_AGENT", "dotfiles/lander", 1)
    local ok, result = pcall(cmd_board.run, "land", { CARD_PREFIX }, backend)
    ffi.C.setenv("DEV_AGENT", previous, 1)
    assert(ok, result)
    return result
end

testing.test("land on a board with In Review and no Verify names dev board init", function()
    local backend = fake_backend("/nonexistent")
    backend.rows = {
        { name = "In Review", is_done = false },
        { name = support.COLUMN_NAME.DONE, is_done = true },
    }
    local result = land_as_lander(backend)
    testing.eq(result.code, 1)
    testing.ok(
        result.message:find("run dev board init to move the board to the stage columns", 1, true),
        result.message
    )
    testing.eq(backend.notes, {})
end)

testing.test("land refuses a board with no project root", function()
    local backend = fake_backend(nil)
    local result = land_as_lander(backend)
    testing.eq(result.code, 1)
    testing.eq(result.message, "dev board land needs the project's root")
    testing.eq(backend.notes, {})
end)

if has_jj then
    local function jj(root, ...)
        local argv = { "jj", "--no-pager", "--color", "never", "-R", root, ... }
        local out, code = dev_os.capture(argv, { stderr = "null", env = IDENT })
        assert(code == 0, out)
        return out
    end

    local function git(dir, ...)
        local argv =
            { "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", ... }
        must(dev_os.run(argv, { stdout = "null", stderr = "null" }))
    end

    local function jj_project(extra)
        local root, home, log = setup(extra)
        assert(fs.write(root .. "/bin/jj", LAND_STUB), "write failed")
        must(dev_os.run({ "chmod", "755", root .. "/bin/jj" }))
        local bare = support.tempdir()
        must(
            dev_os.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, { stdout = "null" })
        )
        must(
            dev_os.run(
                { "jj", "git", "init", root },
                { stdout = "null", stderr = "null", env = IDENT }
            )
        )
        jj(root, "git", "remote", "add", "origin", bare)
        assert(fs.mkdir(root .. "/lib", { parents = true }), "mkdir failed")
        assert(fs.write(root .. "/lib/seed.txt", "seed\n"), "write failed")
        jj(root, "commit", "-m", "base")
        jj(root, "bookmark", "create", "master", "-r", "@-")
        jj(root, "git", "push", "--remote", "origin", "--bookmark", "master")
        assert(fs.write(root .. "/work.txt", "one\n"), "write failed")
        jj(root, "describe", "-m", "feat: work")
        return root, home, log, bare
    end

    local function head(root)
        return jj(root, "log", "-r", "@", "--no-graph", "-T", "commit_id")
    end

    local function board_at(home)
        local previous = os.getenv("XDG_STATE_HOME") or ""
        ffi.C.setenv("XDG_STATE_HOME", home .. "/state", 1)
        local backend = localboard.new({
            name = "mine",
            path = home .. "/state/dev/boards/mine.json",
            private = true,
        })
        backend.roles = { icebox = support.COLUMN_NAME.ICEBOX }
        return backend,
            function()
                ffi.C.setenv("XDG_STATE_HOME", previous, 1)
            end
    end

    local function hold_turn(home, name, card)
        local backend, restore = board_at(home)
        local held = assert(turn.take(backend, name, card))
        restore()
        return held
    end

    local function release_turn(home, held)
        local backend, restore = board_at(home)
        turn.release(backend, held)
        restore()
    end

    local function turn_holder(home)
        local backend, restore = board_at(home)
        local holder = turn.holder(backend)
        restore()
        return holder
    end

    testing.test("land refuses outside the workspace named for the card", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        jj(root, "workspace", "rename", "elsewhere")
        refused(root, home, log, id, { "elsewhere", "dev ws new " .. id })
    end)

    testing.test("land refuses when jj cannot read the workspace list", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        local before = #comments(home, id)
        refused(
            root,
            home,
            log,
            id,
            { "jj could not read the workspace of" },
            { LOG_FAIL_AT = "workspace" }
        )
        testing.eq(column_of(home, id), board.DEFAULT_NAMES.verify)
        testing.eq(#comments(home, id), before)
    end)

    testing.test(
        "workspace check passes when another workspace shares the working-copy commit",
        function()
            local root, home, log = jj_project()
            local id = new_card(root, home, log)
            jj(root, "workspace", "rename", id)
            local base = assert(fs.realpath(support.tempdir()))
            local path = base .. "/other"
            jj(root, "workspace", "add", "--name", "other", path)
            local work = head(root)
            jj(path, "edit", work)
            testing.eq(head(path), work)
            must(dev(root, home, log, { "board", "turn", id }))
            local out, code = dev(root, home, log, { "board", "turn", id, "--release" })
            testing.eq(code, 0, out)
        end
    )

    testing.test("turn refuses outside the workspace named for the card", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "turn", id }))
        jj(root, "workspace", "rename", "elsewhere")
        local out, code = dev(root, home, log, { "board", "turn", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("elsewhere", 1, true), out)
        testing.ok(out:find("dev ws new " .. id, 1, true), out)
        testing.eq(assert(turn_holder(home)).name, "dotfiles/lander")
        out, code = dev(root, home, log, { "board", "turn", id, "--release" })
        testing.eq(code, 0, out)
        testing.ok(out:find("gave back the landing turn held for " .. id, 1, true), out)
        testing.eq(turn_holder(home), nil)
    end)

    testing.test(
        "a card that meets every condition lands, gets a done note and reaches Done",
        function()
            local root, home, log = jj_project()
            local id = new_card(root, home, log)
            must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
            approve(root, home, log, id)
            local commit = head(root)
            local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
            testing.eq(code, 0, out)
            testing.ok(
                out:find(
                    "landed " .. id .. " at commit " .. commit:sub(1, 12) .. " and moved it to Done",
                    1,
                    true
                ),
                out
            )
            testing.ok(landed_calls(log):find("land --yes", 1, true), landed_calls(log))
            local list = comments(home)
            local last = list[#list]
            testing.eq(last.kind, "done")
            testing.ok(last.body:find("Landed commit " .. commit:sub(1, 12), 1, true), last.body)
            testing.eq(column_of(home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test(
        "land runs jj land with DEV_BOARD_LAND=1 so the jj guard lets it through",
        function()
            local root, home, log = jj_project()
            local id = new_card(root, home, log)
            must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
            approve(root, home, log, id)
            local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
            testing.eq(code, 0, out)
            testing.ok(landed_calls(log):find("land --yes", 1, true), landed_calls(log))
            testing.ok(landed_calls(log):find("DEV_BOARD_LAND=1", 1, true), landed_calls(log))
        end
    )

    testing.test("an old-shape claimant still checks and lands its claimed card", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        local old = "dotfiles/implementer/38f0e013/1"
        local backend, restore = board_at(home)
        local cards = assert(backend:cards())
        for _, card in ipairs(cards) do
            if card.id:sub(1, #id) == id then
                assert(backend:claim(card.id, old, 3600, nil, { lease = true }))
            end
        end
        restore()
        local as_old = { DEV_AGENT = old, LAND_TRUNK = "keep" }
        local out, code = dev(root, home, log, { "board", "check", id }, as_old)
        testing.eq(code, 0, out)
        out, code = dev(root, home, log, { "board", "land", id }, as_old)
        testing.eq(code, 0, out)
        testing.ok(out:find("landed " .. id, 1, true), out)
        testing.eq(column_of(home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("land refuses a card in Review and names Verify", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.REVIEW }))
        approve(root, home, log, id)
        refused(root, home, log, id, { "it is in Review, and only a card in Verify lands" })
        testing.eq(column_of(home, id), support.COLUMN_NAME.REVIEW)
    end)

    testing.test("land moves a verified card to Release when the project deploys", function()
        local root, home, log = jj_project("\n[board.land]\ndeploys = true\n")
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        testing.ok(out:find("and moved it to Release", 1, true), out)
        local list = comments(home, id)
        testing.eq(list[#list].kind, "done")
        testing.ok(
            list[#list].body:find("waits in Release for the deploy", 1, true),
            list[#list].body
        )
        testing.eq(column_of(home, id), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("land moves a verified card to Done when the project does not deploy", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        testing.ok(out:find("and moved it to Done", 1, true), out)
        testing.eq(column_of(home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("a card in Release moves to Done once every outcome is ticked", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.RELEASE }))
        local out, code = dev(root, home, log, { "board", "move", id, support.COLUMN.DONE })
        testing.eq(code, 1, out)
        testing.ok(out:find("1 of 1 outcomes are unticked", 1, true), out)
        testing.eq(column_of(home, id), support.COLUMN_NAME.RELEASE)
        must(dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.DONE }))
        testing.eq(column_of(home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("a land that rewrites the commit notes the commit on trunk", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        local before = head(root)
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "rewrite" })
        testing.eq(code, 0, out)
        local after = jj(root, "log", "-r", "master@origin", "--no-graph", "-T", "commit_id")
        testing.ok(before ~= after, "the stub must rewrite the commit")
        testing.ok(out:find("at commit " .. after:sub(1, 12) .. " and moved", 1, true), out)
        testing.eq(out:find(before:sub(1, 12), 1, true), nil, out)
        local list = comments(home)
        local last = list[#list]
        testing.ok(last.body:find("Landed commit " .. after:sub(1, 12), 1, true), last.body)
        testing.eq(last.body:find(before:sub(1, 12), 1, true), nil, last.body)
        testing.eq(column_of(home), support.COLUMN_NAME.DONE)
    end)

    testing.test(
        "a land whose trunk cannot be read notes the earlier commit and still reaches Done",
        function()
            local root, home, log = jj_project()
            local id = new_card(root, home, log)
            must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
            approve(root, home, log, id)
            local commit = head(root)
            local out, code = dev(root, home, log, { "board", "land", id })
            testing.eq(code, 0, out)
            testing.ok(out:find("at commit " .. commit:sub(1, 12), 1, true), out)
            testing.ok(out:find("trunk could not be read", 1, true), out)
            local list = comments(home)
            local last = list[#list]
            testing.eq(last.kind, "done")
            testing.ok(last.body:find(commit:sub(1, 12), 1, true), last.body)
            testing.ok(last.body:find("may differ", 1, true), last.body)
            testing.eq(column_of(home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test(
        "land verdict refuses needs-work, names the reviewer, and accepts minor",
        function()
            local root, home, log = jj_project()
            local id = new_card(root, home, log)
            must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
            approve(root, home, log, id)
            local function judge(by, verdict)
                must(dev(root, home, log, {
                    "board",
                    "review",
                    id,
                    "--kind",
                    "code",
                    "--by",
                    by,
                    "--rev",
                    "@",
                    "--verdict",
                    verdict,
                }))
            end
            judge("picky", "needs-work")
            refused(root, home, log, id, { "code review by picky", "needs-work" })
            judge("kind", "minor")
            local out, code = dev(root, home, log, { "board", "land", id })
            testing.eq(code, 0, out)
            testing.eq(column_of(home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test("a failed jj land leaves the card in Verify and exits non-zero", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        local before = #comments(home)
        local out, code = dev(
            root,
            home,
            log,
            { "board", "land", id },
            { LAND_CODE = "1", LAND_MSG = "boom" }
        )
        testing.eq(code, 1, out)
        testing.ok(out:find("stays in Verify", 1, true) and out:find("boom", 1, true), out)
        testing.ok(landed_calls(log):find("land", 1, true))
        testing.eq(#comments(home), before)
        testing.eq(column_of(home), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("land names every missing condition and runs nothing", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        refused(root, home, log, id, {
            "it is in Backlog, and only a card in Verify lands",
            "1 of 1 outcomes are unticked",
            "no code review of change",
            "no style review of change",
            "no run of dev board check",
        })
    end)

    testing.test("land refuses another claimant's card", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "take", id, "--as", "dotfiles/builder" }))
        refused(root, home, log, id, { "claimed by dotfiles/builder", "not dotfiles/lander" })
        must(dev(root, home, log, { "board", "release", id }))
    end)

    testing.test("land succeeds after a take --from handoff", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        must(dev(root, home, log, { "board", "take", id, "--as", "dotfiles/builder" }))
        refused(root, home, log, id, { "claimed by dotfiles/builder", "not dotfiles/lander" })
        must(dev(root, home, log, { "board", "take", id, "--from", "dotfiles/builder" }))
        testing.eq(claim_of(home, id).claimant, "dotfiles/lander")
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        testing.ok(out:find("landed " .. id, 1, true), out)
        testing.eq(column_of(home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("a claimed card's review comes from another name, never its claimant", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "take", id, "--as", "dotfiles/builder" }))
        local before = #comments(home, id)
        for _, kind in ipairs({ "code", "style", "recheck" }) do
            local out, code = dev(root, home, log, {
                "board",
                "review",
                id,
                "--kind",
                kind,
                "--by",
                "dotfiles/builder",
                "--rev",
                "@",
                "--verdict",
                "clean",
            })
            testing.eq(code, 1, out)
            testing.ok(
                out:find("a reviewer other than dotfiles/builder must record it", 1, true),
                out
            )
        end
        for _, kind in ipairs({ "code", "style", "recheck" }) do
            local out, code = dev(root, home, log, {
                "board",
                "review",
                id,
                "--kind",
                kind,
                "--by",
                "rev",
                "--rev",
                "@",
                "--verdict",
                "clean",
            }, { DEV_AGENT = "dotfiles/builder" })
            testing.eq(code, 1, out)
            testing.ok(
                out:find("a reviewer other than dotfiles/builder must record it", 1, true),
                out
            )
        end
        testing.eq(#comments(home, id), before)
        must(dev(root, home, log, {
            "board",
            "review",
            id,
            "--kind",
            "code",
            "--by",
            "rev",
            "--rev",
            "@",
            "--verdict",
            "clean",
        }))
        local list = comments(home, id)
        testing.eq(#list, before + 1)
        testing.ok(list[#list].body:find("dev-review: kind=code by=rev", 1, true), list[#list].body)
    end)

    testing.test("land refuses a working copy that is empty or undescribed", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        jj(root, "describe", "-m", "")
        refused(root, home, log, id, { "has no description" })
        jj(root, "describe", "-m", "feat: work")
        jj(root, "new", "-m", "next")
        refused(root, home, log, id, { "is empty" })
    end)

    testing.test("a check run at an older commit or with a failing row does not count", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        assert(fs.write(root .. "/work.txt", "two\n"), "write failed")
        refused(root, home, log, id, { "no run of dev board check is recorded at commit" })
        must(dev(root, home, log, { "board", "checks", id, "false" }))
        local _, code = dev(root, home, log, { "board", "check", id })
        testing.eq(code, 1)
        refused(root, home, log, id, {
            "earlier commit than",
            "did not pass every row (1 fail false)",
        })
    end)

    testing.test("an expect-fail record never counts as a passing check", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "checks", id, "false" }))
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve_reviews(root, home, log, id)
        must(dev(root, home, log, { "board", "check", id, "--expect-fail" }))
        must(dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        refused(root, home, log, id, { "no run of dev board check is recorded", "expect-fail" })
    end)

    testing.test("a change after the reviews needs a recheck at the landing commit", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        assert(fs.write(root .. "/work.txt", "two\n"), "write failed")
        must(dev(root, home, log, { "board", "check", id }))
        refused(root, home, log, id, { "earlier commit than", "dev board review --kind recheck" })
        must(dev(root, home, log, {
            "board",
            "review",
            id,
            "--kind",
            "recheck",
            "--by",
            "rev",
            "--rev",
            "@",
            "--verdict",
            "clean",
        }))
        local out, code = dev(root, home, log, { "board", "land", id })
        testing.eq(code, 0, out)
    end)

    testing.test("land rebases onto trunk under the turn when trunk has moved", function()
        local root, home, log, bare = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        local other = support.tempdir() .. "/clone"
        must(
            dev_os.run(
                { "git", "clone", "-q", "--branch", "master", bare, other },
                { stdout = "null", stderr = "null" }
            )
        )
        git(other, "commit", "-q", "--allow-empty", "-m", "moved")
        git(other, "push", "-q", "origin", "HEAD:refs/heads/master")
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        testing.eq(out:find("trunk has moved", 1, true), nil, out)
        testing.eq(column_of(home), support.COLUMN_NAME.DONE)
        testing.eq(turn_holder(home), nil)
    end)

    testing.test(
        "land names the holder and since when while another card holds the turn",
        function()
            local root, home, log = jj_project()
            local id = new_card(root, home, log)
            must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
            approve(root, home, log, id)
            local held = hold_turn(home, "other", "cccc3333")
            local out, code = dev(root, home, log, { "board", "land", id, "--wait", "0" })
            testing.eq(code, 1, out)
            testing.ok(out:find("held by other since 20", 1, true), out)
            testing.eq(column_of(home), support.COLUMN_NAME.VERIFY)
            _, code = dev(root, home, log, { "board", "land", id, "--wait", "x" })
            testing.eq(code, 2)
            _, code = dev(root, home, log, { "board", "land", id, "--wait", "999999999" })
            testing.eq(code, 2)
            release_turn(home, held)
            out, code = dev(
                root,
                home,
                log,
                { "board", "land", id, "--wait", "0" },
                { LAND_TRUNK = "keep" }
            )
            testing.eq(code, 0, out)
            testing.eq(column_of(home), support.COLUMN_NAME.DONE)
            testing.eq(turn_holder(home), nil)
        end
    )

    testing.test("land leaves a change on an unlanded parent where it is", function()
        local root, home, log, bare = jj_project()
        jj(root, "new", "-m", "feat: child")
        assert(fs.write(root .. "/child.txt", "two\n"), "write failed")
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        local other = support.tempdir() .. "/clone"
        must(
            dev_os.run(
                { "git", "clone", "-q", "--branch", "master", bare, other },
                { stdout = "null", stderr = "null" }
            )
        )
        git(other, "commit", "-q", "--allow-empty", "-m", "moved")
        git(other, "push", "-q", "origin", "HEAD:refs/heads/master")
        local before = head(root)
        refused(root, home, log, id, { "sits on an unlanded parent" })
        testing.eq(head(root), before)
        testing.eq(turn_holder(home), nil)
    end)

    testing.test("land waits up to the wait and then names the holder", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        local held = hold_turn(home, "other", "cccc3333")
        local backend, restore = board_at(home)
        backend.root = root
        local nap, now = dev_os.nap, store.now
        local clock = now()
        local naps = {}
        store.now = function()
            return clock
        end
        dev_os.nap = function(secs)
            naps[#naps + 1] = secs
            clock = clock + math.ceil(secs)
        end
        local previous = os.getenv("DEV_AGENT") or ""
        ffi.C.setenv("DEV_AGENT", "dotfiles/lander", 1)
        local ok, result = pcall(cmd_board.run, "land", { id, "--wait", "1" }, backend)
        ffi.C.setenv("DEV_AGENT", previous, 1)
        dev_os.nap = nap
        store.now = now
        restore()
        assert(ok, result)
        testing.eq(result.code, 1, result.message)
        testing.ok(result.message:find("held by other since", 1, true), result.message)
        testing.ok(#naps > 0, "the wait never slept")
        for _, secs in ipairs(naps) do
            testing.ok(secs <= 1, "the wait slept past its deadline: " .. secs)
        end
        testing.eq(assert(turn_holder(home)).name, "other")
        release_turn(home, held)
    end)

    testing.test("land gives the turn back when it refuses", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        must(dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        local out, code = dev(root, home, log, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("no code review", 1, true), out)
        testing.ok(
            fs.read(home .. "/state/dev/boards/mine.json")
                :find("dev-turn: holder=dotfiles/lander", 1, true)
        )
        testing.eq(turn_holder(home), nil)
    end)

    local function trunk_moves(root, bare, files)
        local other = support.tempdir() .. "/clone"
        must(
            dev_os.run(
                { "git", "clone", "-q", "--branch", "master", bare, other },
                { stdout = "null", stderr = "null" }
            )
        )
        for path, body in pairs(files) do
            assert(fs.write(other .. "/" .. path, body), "write failed")
            git(other, "add", path)
        end
        git(other, "commit", "-q", "-m", "moved")
        git(other, "push", "-q", "origin", "HEAD:refs/heads/master")
        jj(root, "git", "fetch", "--remote", "origin")
    end

    local function rebase_onto_trunk(root)
        jj(root, "rebase", "-r", "@", "-d", "master")
    end

    local function review_ready(root, home, log, bare, row)
        trunk_moves(root, bare, { ["shared.txt"] = SHARED })
        rebase_onto_trunk(root)
        assert(fs.write(root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nG\n"), "write failed")
        local id = new_card(root, home, log)
        if row then
            must(dev(root, home, log, { "board", "checks", id, row }))
        end
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        return id
    end

    local function standalone_ready(root, home, log)
        assert(fs.mkdir(root .. "/.dev/standalone", { parents = true }), "mkdir failed")
        assert(fs.write(root .. "/.dev/standalone/x.sh", "#!/bin/sh\n"), "write failed")
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        return id
    end

    testing.test(
        "land refuses a commit that adds a standalone file without standalone-ok",
        function()
            local root, home, log = jj_project()
            local id = standalone_ready(root, home, log)
            approve(root, home, log, id)
            refused(root, home, log, id, {
                "adds .dev/standalone/x.sh, which needs the standalone-ok label",
            })
        end
    )

    testing.test("land refuses a commit that moves a file into .dev/standalone", function()
        local root, home, log = jj_project()
        jj(root, "describe", "-m", "base2")
        assert(fs.write(root .. "/x.sh", "#!/bin/sh\n"), "write failed")
        jj(root, "commit", "-m", "base2")
        jj(root, "bookmark", "set", "master", "-r", "@-")
        jj(root, "git", "push", "--remote", "origin", "--bookmark", "master")
        jj(root, "describe", "-m", "feat: move")
        assert(fs.mkdir(root .. "/.dev/standalone", { parents = true }), "mkdir failed")
        must(dev_os.run({ "mv", root .. "/x.sh", root .. "/.dev/standalone/x.sh" }))
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        refused(root, home, log, id, { "adds .dev/standalone/x.sh" })
    end)

    testing.test(
        "land lands a commit that adds a standalone file when the card has standalone-ok",
        function()
            local root, home, log = jj_project()
            local id = standalone_ready(root, home, log)
            must(
                dev(root, home, log, { "board", "label", id, "+standalone-ok" }, { DEV_AGENT = "" })
            )
            approve(root, home, log, id)
            local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
            testing.eq(code, 0, out)
            testing.eq(column_of(home), board.DEFAULT_NAMES.done)
        end
    )

    local TEMPLATE_DIR = "dotfiles/claude/.claude/skills/style/lint/lua"
    local MODULE_DIR = "dotfiles/bin/.local/share/dev/lua/dev"

    local function template_ready(root, home, log, opts)
        assert(fs.mkdir(root .. "/" .. TEMPLATE_DIR, { parents = true }), "mkdir failed")
        assert(fs.mkdir(root .. "/" .. MODULE_DIR, { parents = true }), "mkdir failed")
        assert(
            fs.write(root .. "/" .. TEMPLATE_DIR .. "/lint.lua", 'local fs = require("dev.fs")\n'),
            "write failed"
        )
        if opts.module then
            assert(
                fs.write(root .. "/" .. MODULE_DIR .. "/" .. opts.module, "return {}\n"),
                "write"
            )
        end
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        return id
    end

    testing.test(
        "land refuses a commit that changes the lint-set template and a dev module it requires",
        function()
            local root, home, log = jj_project()
            local id = template_ready(root, home, log, { module = "fs.lua" })
            refused(root, home, log, id, {
                "This commit changes the lint-set template and " .. MODULE_DIR .. "/fs.lua",
                "Land the dev change first, have infra rebake the ci images,",
            })
        end
    )

    testing.test("land lands a template change with a dev module it does not require", function()
        local root, home, log = jj_project()
        local id = template_ready(root, home, log, { module = "other.lua" })
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        testing.eq(column_of(home), board.DEFAULT_NAMES.done)
    end)

    testing.test("land lands a commit that changes only the lint-set template", function()
        local root, home, log = jj_project()
        local id = template_ready(root, home, log, {})
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        testing.eq(column_of(home), board.DEFAULT_NAMES.done)
    end)

    testing.test(
        "land after another lander's turn ends rebases without a trunk-moved refusal",
        function()
            local root, home, log, bare = jj_project()
            local id = review_ready(root, home, log, bare)
            local held = hold_turn(home, "other", "cccc3333")
            local first, first_code = dev(root, home, log, { "board", "land", id, "--wait", "0" })
            testing.eq(first_code, 1, first)
            testing.ok(first:find("held by other since", 1, true), first)
            trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
            release_turn(home, held)
            local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
            testing.eq(code, 0, out)
            testing.ok(not out:find("trunk has moved", 1, true), out)
            testing.eq(column_of(home), support.COLUMN_NAME.DONE)
            testing.eq(turn_holder(home), nil)
        end
    )

    testing.test(
        "land carries the check and reviews over a rebase past unrelated commits",
        function()
            local root, home, log, bare = jj_project()
            local id = review_ready(root, home, log, bare)
            local before = head(root)
            trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(root)
            testing.ok(head(root) ~= before, "the rebase must rewrite the commit")
            local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
            testing.eq(code, 0, out)
            local list = comments(home)
            local last = list[#list]
            testing.eq(last.kind, "done")
            testing.ok(
                last.body:find("carried over from commit " .. before:sub(1, 12), 1, true),
                last.body
            )
            testing.eq(column_of(home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test("land reads trunk under the turn, to carry and after the land", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        local reads = support.tempdir() .. "/fetch.log"
        local out, code = dev(
            root,
            home,
            log,
            { "board", "land", id },
            { LAND_TRUNK = "keep", FETCH_LOG = reads }
        )
        testing.eq(code, 0, out)
        local list = comments(home)
        testing.ok(list[#list].body:find("carried over", 1, true), list[#list].body)
        testing.eq(fs.read(reads), "fetch\nfetch\nfetch\n")
    end)

    local function recheck_project(row)
        return jj_project('\n[board.land]\nrecheck = ["' .. row .. '"]\n')
    end

    testing.test("land reruns the recheck rows when the carry crosses trunk commits", function()
        local marker = support.tempdir() .. "/rechecked"
        local root, home, log, bare = recheck_project("touch " .. marker)
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        testing.ok(fs.is_file(marker), "the recheck row never ran")
    end)

    testing.test("a failed recheck row refuses the land and leaves trunk alone", function()
        local root, home, log, bare = recheck_project("false")
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        local out, code = dev(root, home, log, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("recheck row failed and nothing was pushed", 1, true), out)
        testing.ok(out:find("fail - false", 1, true), out)
        testing.eq(fs.read(log), nil)
        testing.eq(column_of(home), board.DEFAULT_NAMES.verify)
    end)

    testing.test("land skips the recheck when the check sits on the current trunk", function()
        local marker = support.tempdir() .. "/rechecked"
        local root, home, log, bare = recheck_project("touch " .. marker)
        local id = review_ready(root, home, log, bare)
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        testing.ok(not fs.is_file(marker), "the recheck row ran")
    end)

    testing.test("land stays put when the push after a carry is rejected", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        local out, code = dev(root, home, log, { "board", "land", id }, {
            LAND_CODE = "1",
            LAND_MSG = "push rejected: trunk moved",
        })
        testing.eq(code, 1, out)
        testing.ok(out:find("jj land failed", 1, true), out)
        testing.ok(out:find("push rejected: trunk moved", 1, true), out)
        testing.eq(column_of(home), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("land does not carry a pass over a failed run at the rebased commit", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare, "! test -e docs.txt")
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        local out, code = dev(root, home, log, { "board", "check", id })
        testing.ok(code ~= 0, out)
        refused(root, home, log, id, { "did not pass every row" })
    end)

    testing.test("land does not carry over an expect-fail record at the rebased commit", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        dev(root, home, log, { "board", "check", id, "--expect-fail" })
        refused(root, home, log, id, { "no run of dev board check is recorded" })
    end)

    testing.test("land does not carry over an unreadable record at the rebased commit", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        local record = "dev-check: commit=" .. head(root) .. " change=chg mode=run\n1 pass dev lint"
        local backend, restore = board_at(home)
        for _, card in ipairs(assert(backend:cards())) do
            if card.id:sub(1, #id) == id then
                assert(backend:note(card.id, record))
            end
        end
        restore()
        refused(root, home, log, id, { "could not be read", "run dev board check again" })
    end)

    testing.test("clean rebase carries the check", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        local before = head(root)
        trunk_moves(root, bare, { ["shared.txt"] = "A\nb\nc\nd\ne\nf\ng\n" })
        rebase_onto_trunk(root)
        testing.ok(head(root) ~= before, "the rebase must rewrite the commit")
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        local list = comments(home)
        testing.ok(
            list[#list].body:find("carried over from commit " .. before:sub(1, 12), 1, true),
            list[#list].body
        )
        testing.eq(column_of(home), support.COLUMN_NAME.DONE)
    end)

    testing.test("a rebase that leaves a conflict does not carry the check", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["shared.txt"] = "a\nb\nc\nd\ne\nf\nX\n" })
        rebase_onto_trunk(root)
        refused(root, home, log, id, {
            "the working-copy commit has conflicts",
            "run dev board check again",
        })
    end)

    testing.test(
        "land names only the unticked outcome after a rebase that the carry accepts",
        function()
            local root, home, log, bare = jj_project()
            trunk_moves(root, bare, { ["shared.txt"] = SHARED })
            rebase_onto_trunk(root)
            assert(fs.write(root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nG\n"), "write failed")
            local id = new_card(root, home, log)
            must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
            approve_reviews(root, home, log, id)
            must(dev(root, home, log, { "board", "check", id }))
            trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(root)
            local out = refused(root, home, log, id, { "1 of 1 outcomes are unticked" })
            testing.eq(out:find("review of", 1, true), nil, out)
            testing.eq(out:find("no run of dev board check", 1, true), nil, out)
        end
    )

    testing.test("land names the column beside the carry after an accepted rebase", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.PROGRESS }))
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        local out = refused(root, home, log, id, { "only a card in" })
        testing.eq(out:find("earlier commit", 1, true), nil, out)
        testing.eq(out:find("no run of dev board check", 1, true), nil, out)
    end)

    testing.test("land carries over a rebase past a changed former shared path", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["lib/core.txt"] = "core\n" })
        rebase_onto_trunk(root)
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        testing.eq(column_of(home), support.COLUMN_NAME.DONE)
    end)

    testing.test("land refuses the carry when jj cannot compare the checked commit", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        refused(
            root,
            home,
            log,
            id,
            { "jj could not compare the checked commit" },
            { INTERDIFF_FAIL = "1" }
        )
    end)

    testing.test(
        "land refuses the carry when the checked commit sat off trunk's ancestry",
        function()
            local root, home, log, bare = jj_project()
            trunk_moves(root, bare, { ["shared.txt"] = SHARED })
            jj(root, "new", "master", "-m", "side")
            assert(fs.write(root .. "/side.txt", "side\n"), "write failed")
            jj(root, "new", "-m", "feat: work")
            assert(fs.write(root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nG\n"), "write failed")
            local id = new_card(root, home, log)
            must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
            approve(root, home, log, id)
            trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(root)
            refused(root, home, log, id, { "does not sit on a single ancestor of trunk" })
        end
    )

    testing.test("land refuses a carry from a checked commit of another change", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        must(dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        local trunk = jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
        local change = jj(root, "log", "-r", "@", "--no-graph", "-T", "change_id")
        local at = { commit = trunk, change = change }
        local records = {
            check.record(at, { { result = check.RESULT.PASS, run_id = "-", run = "true" } }, false),
            review.record(review.KIND.CODE, "rev", at, review.VERDICT.CLEAN),
            review.record(review.KIND.STYLE, "rev", at, review.VERDICT.CLEAN),
        }
        local backend, restore = board_at(home)
        for _, card in ipairs(assert(backend:cards())) do
            if card.id:sub(1, #id) == id then
                for _, body in ipairs(records) do
                    assert(backend:note(card.id, body))
                end
            end
        end
        restore()
        local before = #comments(home, id)
        refused(root, home, log, id, {
            "the checked commit " .. trunk:sub(1, 12) .. " is not of change",
        })
        testing.eq(column_of(home, id), board.DEFAULT_NAMES.verify)
        testing.eq(#comments(home, id), before)
    end)

    local function reviewed_and_checked(opts)
        local root, home, log, id = opts.root, opts.home, opts.log, opts.id
        approve_reviews(root, home, log, id)
        must(dev(root, home, log, { "board", "check", id }))
        return head(root)
    end

    local function two_checked_commits(opts)
        local root, home, log, bare = opts.root, opts.home, opts.log, opts.bare
        trunk_moves(root, bare, { ["shared.txt"] = SHARED })
        rebase_onto_trunk(root)
        assert(fs.write(root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nG\n"), "write failed")
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        must(dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        local older = reviewed_and_checked({ root = root, home = home, log = log, id = id })
        assert(fs.write(root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nH\n"), "write failed")
        local newer = reviewed_and_checked({ root = root, home = home, log = log, id = id })
        assert(fs.write(root .. "/shared.txt", opts.final_shared), "write failed")
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        return id, older, newer
    end

    testing.test("land carries from an older checked commit when the newest one differs", function()
        local root, home, log, bare = jj_project()
        local id, older = two_checked_commits({
            root = root,
            home = home,
            log = log,
            bare = bare,
            final_shared = "a\nb\nc\nd\ne\nf\nG\n",
        })
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        local list = comments(home)
        testing.ok(list[#list].body:find("carried over from commit " .. older:sub(1, 12), 1, true))
    end)

    testing.test("land names the newest checked commit when no candidate carries", function()
        local root, home, log, bare = jj_project()
        local id, older, newer = two_checked_commits({
            root = root,
            home = home,
            log = log,
            bare = bare,
            final_shared = "a\nb\nc\nd\ne\nf\nZ\n",
        })
        local out =
            refused(root, home, log, id, { "differs from the checked commit " .. newer:sub(1, 12) })
        testing.eq(out:find(older:sub(1, 12), 1, true), nil, out)
    end)

    testing.test("land refuses at once when jj cannot read the newest checked commit", function()
        local root, home, log, bare = jj_project()
        local id, older, newer = two_checked_commits({
            root = root,
            home = home,
            log = log,
            bare = bare,
            final_shared = "a\nb\nc\nd\ne\nf\nG\n",
        })
        local out = refused(
            root,
            home,
            log,
            id,
            { "jj could not compare the checked commit " .. newer:sub(1, 12) },
            { INTERDIFF_FAIL_AT = newer }
        )
        testing.eq(out:find(older:sub(1, 12), 1, true), nil, out)
    end)

    testing.test(
        "land refuses at once when jj cannot read the newest checked commit's change",
        function()
            local root, home, log, bare = jj_project()
            local id, older, newer = two_checked_commits({
                root = root,
                home = home,
                log = log,
                bare = bare,
                final_shared = "a\nb\nc\nd\ne\nf\nG\n",
            })
            local out = refused(
                root,
                home,
                log,
                id,
                { "jj could not read the checked commit " .. newer:sub(1, 12) },
                { LOG_FAIL_AT = newer }
            )
            testing.eq(out:find(older:sub(1, 12), 1, true), nil, out)
        end
    )

    local failed_reads = {
        {
            name = "parent",
            switch = "PARENT_FAIL_AT",
            message = "jj could not read the parent of the checked commit ",
        },
        {
            name = "ancestor",
            switch = "ANCESTOR_FAIL_AT",
            message = "jj could not read the ancestor of the checked commit ",
        },
    }
    for _, case in ipairs(failed_reads) do
        testing.test("land refuses at once when jj cannot read the older " .. case.name, function()
            local root, home, log, bare = jj_project()
            local id, older, newer = two_checked_commits({
                root = root,
                home = home,
                log = log,
                bare = bare,
                final_shared = "a\nb\nc\nd\ne\nf\nG\n",
            })
            local out = refused(root, home, log, id, { case.message }, { [case.switch] = older })
            testing.eq(out:find("carried over", 1, true), nil, out)
            testing.eq(out:find(newer:sub(1, 12), 1, true), nil, out)
        end)
    end

    testing.test("land names the older candidate when its interdiff read fails", function()
        local root, home, log, bare = jj_project()
        local id, older = two_checked_commits({
            root = root,
            home = home,
            log = log,
            bare = bare,
            final_shared = "a\nb\nc\nd\ne\nf\nZ\n",
        })
        refused(
            root,
            home,
            log,
            id,
            { "jj could not compare the checked commit " .. older:sub(1, 12) },
            { INTERDIFF_FAIL_AT = older }
        )
    end)

    testing.test("land refuses a rebase of a commit that differs from the checked one", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        local before = head(root)
        assert(fs.write(root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nH\n"), "write failed")
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        refused(root, home, log, id, { "differs from the checked commit " .. before:sub(1, 12) })
    end)

    testing.test(
        "land refuses a duplicate of the checked change under another change id",
        function()
            local root, home, log, bare = jj_project()
            local id = review_ready(root, home, log, bare)
            jj(root, "duplicate", "@")
            local copy = jj(root, "log", "-r", "children(@-) ~ @", "--no-graph", "-T", "change_id")
            jj(root, "edit", copy)
            local out = refused(root, home, log, id, { "no code review of change" })
            testing.eq(out:find("carried over", 1, true), nil, out)
        end
    )

    testing.test(
        "land does not carry a review that was never recorded at the checked commit",
        function()
            local root, home, log, bare = jj_project()
            trunk_moves(root, bare, { ["shared.txt"] = SHARED })
            rebase_onto_trunk(root)
            local id = new_card(root, home, log)
            must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
            must(dev(root, home, log, {
                "board",
                "review",
                id,
                "--kind",
                "code",
                "--by",
                "rev",
                "--rev",
                "@",
                "--verdict",
                "clean",
            }))
            must(dev(root, home, log, { "board", "check", id }))
            must(
                dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" })
            )
            trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(root)
            refused(root, home, log, id, { "no style review of change" })
        end
    )

    testing.test("land refuses a working copy that holds conflicts", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        local first = jj(root, "log", "-r", "@", "--no-graph", "-T", "change_id")
        jj(root, "new", "master", "-m", "feat: other")
        assert(fs.write(root .. "/work.txt", "two\n"), "write failed")
        jj(root, "rebase", "-r", "@", "-d", first)
        refused(root, home, log, id, {
            "the working-copy commit has conflicts",
            "run dev board check again",
        })
    end)

    testing.test("land refuses a card labelled needs:human", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.BLOCKED }))
        must(dev(root, home, log, { "board", "label", id, "needs:human" }))
        refused(root, home, log, id, { "is labelled needs:human", "waits on the owner" })
    end)

    testing.test("land refuses when the fetch from the remote of record fails", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        jj(root, "git", "remote", "set-url", "origin", root .. "/missing-remote")
        refused(root, home, log, id, { "trunk cannot be compared", "the fetch from origin failed" })
    end)

    testing.test("land retries a refused ssh signature once", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        local count = support.tempdir() .. "/count.log"
        local out, code = dev(
            root,
            home,
            log,
            { "board", "land", id },
            { LAND_TRUNK = "keep", FETCH_REFUSALS = "1", FETCH_COUNT = count }
        )
        testing.eq(code, 0, out)
        testing.eq(fs.read(count), "1\n")
        testing.ok(out:find("landed " .. id, 1, true), out)
    end)

    testing.test("land names the hardware key after a second refusal", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        local count = support.tempdir() .. "/count.log"
        refused(
            root,
            home,
            log,
            id,
            { "the fetch from origin failed", "Touch the hardware key", "run land again." },
            { FETCH_REFUSALS = "5", FETCH_COUNT = count }
        )
        testing.eq(fs.read(count), "2\n")
    end)

    testing.test("land ends a hung fetch at a timeout", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        refused(root, home, log, id, {
            "the fetch from origin failed",
            "The fetch ran past 1 seconds",
            "touch it and run land again.",
        }, { FETCH_HANG = "1", DEV_LAND_FETCH_SECONDS = "1" })
    end)

    testing.test("land refuses when the card's comments cannot be read", function()
        local root = jj_project()
        local backend = fake_backend(root)
        function backend:comments()
            return nil, "board unavailable: comments timed out"
        end
        local result = land_as_lander(backend)
        testing.eq(result.code, 1)
        testing.eq(result.message, "board unavailable: comments timed out")
        testing.eq(backend.notes, {})
    end)

    testing.test("land refuses when the board's cards cannot be read", function()
        local root = jj_project()
        local backend = fake_backend(root)
        function backend:cards()
            return nil, "board unavailable: cards timed out"
        end
        local result = land_as_lander(backend)
        testing.eq(result.code, 1)
        testing.eq(result.message, "board unavailable: cards timed out")
        testing.eq(backend.notes, {})
    end)

    testing.test("land names outcomes that cannot be read and does not land", function()
        local root = jj_project()
        local backend = fake_backend(root, { outcomes_unreadable = true })
        local result = land_as_lander(backend)
        testing.eq(result.code, 1)
        testing.ok(result.message:find(CARD_PREFIX .. " cannot land:", 1, true), result.message)
        testing.ok(
            result.message:find(
                "its outcomes cannot be read from Pomb, so they cannot be checked",
                1,
                true
            ),
            result.message
        )
        testing.eq(backend.notes, {})
    end)

    testing.test("land refuses a working copy that jj cannot read", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        local out = refused(
            root,
            home,
            log,
            id,
            { "jj could not read the working-copy commit of" },
            {
                SHAPE_FAIL = "1",
            }
        )
        testing.ok(out:find(root, 1, true), out)
    end)

    testing.test("land refuses when the rebase onto trunk fails", function()
        local root, home, log, bare = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        local other = support.tempdir() .. "/clone"
        must(
            dev_os.run(
                { "git", "clone", "-q", "--branch", "master", bare, other },
                { stdout = "null", stderr = "null" }
            )
        )
        git(other, "commit", "-q", "--allow-empty", "-m", "moved")
        git(other, "push", "-q", "origin", "HEAD:refs/heads/master")
        local FAIL_AT = { REBASE = "rebase" }
        refused(
            root,
            home,
            log,
            id,
            { "the rebase onto trunk failed" },
            { LOG_FAIL_AT = FAIL_AT.REBASE }
        )
        testing.eq(column_of(home, id), board.DEFAULT_NAMES.verify)
        testing.eq(turn_holder(home), nil)
    end)

    testing.test("land refuses a remote of record that is not a remote of the project", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        refused(root, home, log, id, {
            "trunk cannot be compared: the remote of record gerrit is not a remote of this project",
        }, { JJ_FORGE = "gerrit" })
    end)

    testing.test(
        "a landed commit whose done note was not written is named and exits non-zero",
        function()
            local root, home, log = jj_project()
            local id = new_card(root, home, log)
            must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
            approve(root, home, log, id)
            local commit = head(root)
            local out, code = dev(root, home, log, { "board", "land", id }, {
                LAND_TRUNK = "keep",
                BREAK_BOARD = home .. "/state/dev/boards/mine.json",
            })
            testing.eq(code, 1, out)
            testing.ok(landed_calls(log):find("land --yes", 1, true), landed_calls(log))
            testing.ok(
                out:find(
                    "landed commit " .. commit:sub(1, 12) .. ", but the done note was NOT written",
                    1,
                    true
                ),
                out
            )
            testing.ok(out:find("the card was not moved", 1, true), out)
        end
    )

    testing.test(
        "a fetch that fails after the land falls back to the commit from before it",
        function()
            local root, home, log = jj_project()
            local id = new_card(root, home, log)
            must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
            approve(root, home, log, id)
            local before = head(root)
            local out, code = dev(root, home, log, { "board", "land", id }, {
                LAND_TRUNK = "rewrite",
                FETCH_FAIL = "1",
            })
            testing.eq(code, 0, out)
            local after = jj(root, "log", "-r", "master@origin", "--no-graph", "-T", "commit_id")
            testing.ok(before ~= after, "the stub must rewrite the commit")
            testing.ok(out:find("at commit " .. before:sub(1, 12), 1, true), out)
            testing.ok(out:find("trunk could not be read", 1, true), out)
            testing.eq(out:find(after:sub(1, 12), 1, true), nil, out)
            local list = comments(home)
            local last = list[#list]
            testing.eq(last.kind, "done")
            testing.ok(last.body:find(before:sub(1, 12), 1, true), last.body)
            testing.ok(last.body:find("may differ", 1, true), last.body)
            testing.eq(column_of(home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test("a landed card whose move to Done fails is named and exits non-zero", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        local out = dev(
            root,
            home,
            log,
            { "board", "add", "Child", "--problem", "x", "--size", "1", "--done-when", "x" }
        )
        local child = assert(out:match("added (%x+)"), out)
        must(dev(root, home, log, { "board", "epic", id }))
        must(dev(root, home, log, { "board", "link", child, "parent", id }))
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        must(dev(root, home, log, { "board", "turn", id }))
        local commit = head(root)
        local code
        out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(turn_holder(home), nil)
        testing.eq(code, 1, out)
        testing.ok(landed_calls(log):find("land --yes", 1, true), landed_calls(log))
        testing.ok(
            out:find("landed commit " .. commit:sub(1, 12) .. " and noted it on " .. id, 1, true),
            out
        )
        testing.ok(out:find("but the move to Done failed", 1, true), out)
        testing.ok(out:find("1 of 1 children are open", 1, true), out)
        local list = comments(home, id)
        testing.eq(list[#list].kind, "done")
        testing.eq(column_of(home, id), support.COLUMN_NAME.VERIFY)
    end)

    local function in_verify(root, home, log)
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        return id
    end

    testing.test("a held turn survives a check and lands the card under it", function()
        local root, home, log = jj_project()
        local id = in_verify(root, home, log)
        local out, code = dev(root, home, log, { "board", "turn", id })
        testing.eq(code, 0, out)
        testing.ok(out:find("holding the landing turn for " .. id, 1, true), out)
        approve(root, home, log, id)
        testing.eq(assert(turn_holder(home)).name, "dotfiles/lander")
        out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        testing.eq(column_of(home, id), support.COLUMN_NAME.DONE)
        testing.eq(turn_holder(home), nil)
    end)

    testing.test("a second runner is told who holds the turn and since when", function()
        local root, home, log = jj_project()
        local id = in_verify(root, home, log)
        must(dev(root, home, log, { "board", "turn", id }))
        local out, code = dev(
            root,
            home,
            log,
            { "board", "turn", id, "--wait", "0" },
            { DEV_AGENT = "dotfiles/other" }
        )
        testing.eq(code, 1, out)
        testing.ok(out:find("held by dotfiles/lander since 20", 1, true), out)
        out, code = dev(root, home, log, { "board", "turn", id, "--hold", "120" })
        testing.eq(code, 0, out)
        testing.ok(out:find("renewed the landing turn held for " .. id, 1, true), out)
        testing.eq(assert(turn_holder(home)).name, "dotfiles/lander")
    end)

    testing.test("land refuses a hold that ran out and lands nothing", function()
        local root, home, log = jj_project()
        local id = in_verify(root, home, log)
        approve(root, home, log, id)
        must(dev(root, home, log, { "board", "turn", id, "--hold", "1" }))
        dev_os.nap(PAST_HOLD_SECONDS)
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 1, out)
        testing.ok(out:find("ran out or was taken by another", 1, true), out)
        testing.eq(landed_calls(log), "")
        testing.eq(column_of(home, id), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("land refuses a hold another runner took after it ran out", function()
        local root, home, log = jj_project()
        local id = in_verify(root, home, log)
        approve(root, home, log, id)
        must(dev(root, home, log, { "board", "turn", id, "--hold", "1" }))
        dev_os.nap(PAST_HOLD_SECONDS)
        must(dev(root, home, log, { "board", "turn", id }, { DEV_AGENT = "dotfiles/other" }))
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 1, out)
        testing.ok(out:find("ran out or was taken by another", 1, true), out)
        testing.eq(landed_calls(log), "")
        testing.eq(assert(turn_holder(home)).name, "dotfiles/other")
    end)

    testing.test("a refused landing keeps the hold until it is released", function()
        local root, home, log = jj_project()
        local id = in_verify(root, home, log)
        must(dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        must(dev(root, home, log, { "board", "turn", id }))
        local out, code = dev(root, home, log, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("no code review", 1, true), out)
        testing.ok(out:find("turn you hold for " .. id .. " stays held", 1, true), out)
        testing.eq(assert(turn_holder(home)).name, "dotfiles/lander")
        out, code = dev(root, home, log, { "board", "turn", id, "--release" })
        testing.eq(code, 0, out)
        testing.eq(turn_holder(home), nil)
        _, code = dev(root, home, log, { "board", "turn", id, "--release" })
        testing.eq(code, 1)
    end)

    testing.test("land leaves no owner on the landed card", function()
        for _, deploys in ipairs({ "", "\n[board.land]\ndeploys = true\n" }) do
            local root, home, log = jj_project(deploys)
            local id = new_card(root, home, log)
            must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
            approve(root, home, log, id)
            local backend, restore = board_at(home)
            for _, card in ipairs(assert(backend:cards())) do
                if card.id:sub(1, #id) == id then
                    assert(backend:claim(card.id, "dotfiles/lander", 3600, nil, { lease = true }))
                end
            end
            restore()
            testing.ok(claim_of(home, id), "the card must be claimed before the land")
            local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
            testing.eq(code, 0, out)
            testing.eq(claim_of(home, id), nil)
        end
    end)

    testing.test("land refused before the move keeps its hold", function()
        local root, home, log = jj_project()
        local id = in_verify(root, home, log)
        must(dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        must(dev(root, home, log, { "board", "turn", id }))
        local out, code = dev(root, home, log, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.eq(assert(turn_holder(home)).name, "dotfiles/lander")
        testing.eq(column_of(home, id), board.DEFAULT_NAMES.verify)
    end)

    testing.test("a landing refused before the turn is read says the hold is kept", function()
        local root, home, log = jj_project()
        local id = in_verify(root, home, log)
        must(dev(root, home, log, { "board", "turn", id }))
        local out, code = dev(root, home, log, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("turn you hold for " .. id .. " stays held", 1, true), out)
        testing.eq(assert(turn_holder(home)).name, "dotfiles/lander")
    end)

    testing.test("turn refuses a hold outside 1 to 3600 seconds", function()
        local root, home, log = jj_project()
        local id = in_verify(root, home, log)
        for _, bad in ipairs({ "0", "3601", "x" }) do
            local out, code = dev(root, home, log, { "board", "turn", id, "--hold", bad })
            testing.eq(code, 2, out)
        end
        local _, code = dev(root, home, log, { "board", "turn", id, "--hold", "3600" })
        testing.eq(code, 0)
    end)

    testing.test(
        "release clears a hold that ran out, and land then asks for a fresh turn",
        function()
            local root, home, log = jj_project()
            local id = in_verify(root, home, log)
            approve(root, home, log, id)
            must(dev(root, home, log, { "board", "turn", id, "--hold", "1" }))
            dev_os.nap(PAST_HOLD_SECONDS)
            local out, code = dev(root, home, log, { "board", "turn", id, "--release" })
            testing.eq(code, 0, out)
            testing.ok(out:find("was already gone", 1, true), out)
            out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
            testing.eq(code, 0, out)
            testing.eq(column_of(home, id), support.COLUMN_NAME.DONE)
        end
    )

    testing.test("turn refuses a card that is already in Done", function()
        local root, home, log = jj_project()
        local id = in_verify(root, home, log)
        approve(root, home, log, id)
        must(dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" }))
        local out, code = dev(root, home, log, { "board", "turn", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("is done", 1, true), out)
        testing.eq(turn_holder(home), nil)
    end)

    local function lander_ready(root, home, log)
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        return id
    end

    testing.test("a land that waited keeps a hold taken meanwhile", function()
        local root, home, log = jj_project()
        local id = lander_ready(root, home, log)
        local held = hold_turn(home, "other", "cccc3333")
        local backend, restore = board_at(home)
        backend.root = root
        local nap = dev_os.nap
        dev_os.nap = function()
            dev_os.nap = nap
            release_turn(home, held)
            must(dev(root, home, log, { "board", "turn", id, "--hold", "60" }))
            must(dev(root, home, log, { "board", "move", id, support.COLUMN.BLOCKED }))
        end
        local previous = os.getenv("DEV_AGENT") or ""
        ffi.C.setenv("DEV_AGENT", "dotfiles/lander", 1)
        local ok, result = pcall(cmd_board.run, "land", { id, "--wait", "30" }, backend)
        ffi.C.setenv("DEV_AGENT", previous, 1)
        dev_os.nap = nap
        restore()
        assert(ok, result)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("cannot land", 1, true), result.message)
        testing.ok(result.message:find("stays held", 1, true), result.message)
        testing.eq(assert(turn_holder(home)).name, "dotfiles/lander")
        local out, code = dev(root, home, log, { "board", "turn", id, "--release" })
        testing.eq(code, 0, out)
        testing.eq(turn_holder(home), nil)
    end)

    testing.test("another check does not block a land", function()
        local root, home, log = jj_project()
        local landing = lander_ready(root, home, log)
        local out = dev(root, home, log, {
            "board",
            "add",
            "Other",
            "--problem",
            "x",
            "--size",
            "1",
            "--done-when",
            "It works",
        })
        local other = assert(out:match("added (%x+)"), out)
        local scripts = support.tempdir()
        local started, stop = scripts .. "/started", scripts .. "/stop"
        local slow = scripts .. "/slow.sh"
        assert(
            fs.write(
                slow,
                "touch "
                    .. started
                    .. "\n"
                    .. "n=0\n"
                    .. "while [ ! -e "
                    .. stop
                    .. " ] && [ $n -lt "
                    .. CHECK_STOP_SECONDS * 10
                    .. " ]; do\n"
                    .. "    sleep 0.1\n"
                    .. "    n=$((n + 1))\n"
                    .. "done\n"
            ),
            "write failed"
        )
        must(dev(root, home, log, { "board", "checks", other, "sh " .. slow }))
        local elsewhere = support.tempdir() .. "/other"
        jj(root, "workspace", "add", "--name", other, elsewhere)
        local running = support.dev_async(elsewhere, { "board", "check", other }, {
            env = {
                HOME = home,
                XDG_STATE_HOME = home .. "/state",
                JJ_USER = "t",
                JJ_EMAIL = "t@example.com",
                DEV_AGENT = "dotfiles/lander",
                LAND_LOG = log,
                REAL_JJ = dev_os.which("jj"),
            },
        })
        local deadline = os.time() + CHECK_WAIT_SECONDS
        while not fs.exists(started) and os.time() < deadline do
            dev_os.nap(0.1)
        end
        testing.ok(fs.exists(started), "the other card's check must be running")
        local landed, code = dev(root, home, log, { "board", "land", landing, "--wait", "0" }, {
            LAND_TRUNK = "keep",
        })
        testing.eq(code, 0, landed)
        testing.eq(column_of(home, landing), support.COLUMN_NAME.DONE)
        testing.eq(running.finished(), false)
        assert(fs.write(stop, ""), "write failed")
        local output, status = running.wait()
        testing.eq(status, 0, output)
    end)

    local function rebased_and_checked(root, home, log, id)
        rebase_onto_trunk(root)
        must(dev(root, home, log, { "board", "check", id }))
    end

    testing.test("a clean rebase keeps its reviews", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        local before = head(root)
        trunk_moves(root, bare, { ["lib/extra.txt"] = "extra\n" })
        rebased_and_checked(root, home, log, id)
        testing.ok(head(root) ~= before, "the rebase must rewrite the commit")
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        local list = comments(home)
        testing.eq(list[#list].kind, "done")
        testing.eq(list[#list].body:find("carried over", 1, true), nil, list[#list].body)
        testing.eq(column_of(home), support.COLUMN_NAME.DONE)
    end)

    testing.test("a rebase over edits to the same file keeps its reviews", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["shared.txt"] = "A\nb\nc\nd\ne\nf\ng\n" })
        rebased_and_checked(root, home, log, id)
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        testing.eq(code, 0, out)
        testing.eq(column_of(home), support.COLUMN_NAME.DONE)
    end)

    testing.test("a changed patch still needs a recheck", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        assert(fs.write(root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nH\n"), "write failed")
        trunk_moves(root, bare, { ["lib/extra.txt"] = "extra\n" })
        rebased_and_checked(root, home, log, id)
        refused(root, home, log, id, {
            "the code review is of an earlier commit",
            "the style review is of an earlier commit",
        })
    end)

    testing.test("a needs-work review of the same patch still refuses", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        must(dev(root, home, log, {
            "board",
            "review",
            id,
            "--kind",
            "code",
            "--by",
            "rev2",
            "--rev",
            "@",
            "--verdict",
            "needs-work",
        }))
        trunk_moves(root, bare, { ["lib/extra.txt"] = "extra\n" })
        rebased_and_checked(root, home, log, id)
        refused(root, home, log, id, { "the code review by rev2", "says needs-work" })
    end)

    local function central_project()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        jj(root, "workspace", "rename", "default")
        local base = assert(fs.realpath(support.tempdir()))
        local path = base .. "/proj/" .. id
        assert(fs.mkdir(base .. "/proj", { parents = true }), "mkdir failed")
        jj(root, "workspace", "add", "--name", id, "-r", "master", path)
        assert(fs.write(path .. "/work.txt", "two\n"), "write failed")
        jj(path, "describe", "-m", "feat: work")
        jj(path, "bookmark", "create", id, "-r", "@")
        must(
            dev(
                path,
                home,
                log,
                { "board", "move", id, support.COLUMN.VERIFY },
                { DEV_WS_ROOT = base }
            )
        )
        approve(path, home, log, id)
        return root, home, log, id, path, base
    end

    testing.test("land removes the workspace and bookmark in a jj project", function()
        local root, home, log, id, path, base = central_project()
        local out, code = dev(
            path,
            home,
            log,
            { "board", "land", id },
            { LAND_TRUNK = "keep", LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.ok(out:find("Deleted bookmark " .. id, 1, true), out)
        testing.ok(out:find("removed " .. path, 1, true), out)
        testing.eq(fs.exists(path), false)
        testing.eq(jj(root, "bookmark", "list", "-T", 'name ++ "\\n"'):find(id, 1, true), nil)
        testing.eq(jj(root, "workspace", "list"):find(id .. ":", 1, true), nil)
        testing.eq(column_of(home, id), board.DEFAULT_NAMES.done)
    end)

    testing.test("land keeps a workspace with uncommitted changes", function()
        local root, home, log, id, path, base = central_project()
        local out, code = dev(path, home, log, { "board", "land", id }, {
            LAND_TRUNK = "keep",
            LAND_NEW = "1",
            LAND_STRAY = "stray.txt",
            DEV_WS_ROOT = base,
        })
        testing.eq(code, 0, out)
        testing.ok(out:find("Kept the workspace: " .. path .. " holds changes", 1, true), out)
        testing.eq(out:find("Run the next command", 1, true), nil, out)
        testing.eq(fs.exists(path .. "/stray.txt"), true)
        testing.ok(
            jj(root, "workspace", "list"):find(id .. ":", 1, true),
            "the workspace is forgotten"
        )
        testing.eq(column_of(home, id), board.DEFAULT_NAMES.done)
    end)

    testing.test("land removes the workspace it runs in", function()
        local _, home, log, id, path, base = central_project()
        local out, code = dev(
            path,
            home,
            log,
            { "board", "land", id },
            { LAND_TRUNK = "keep", LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.ok(out:find("Run the next command from another folder.", 1, true), out)
        local list = comments(home, id)
        testing.eq(list[#list].kind, board.NoteKind.DONE)
        testing.eq(column_of(home, id), board.DEFAULT_NAMES.done)
        testing.eq(fs.exists(path), false)
    end)

    testing.test("land keeps a workspace outside the central root and says why", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, support.COLUMN.VERIFY }))
        approve(root, home, log, id)
        local base = assert(fs.realpath(support.tempdir()))
        local out, code = dev(
            root,
            home,
            log,
            { "board", "land", id },
            { LAND_TRUNK = "keep", LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.ok(out:find("Kept the workspace: " .. root .. " is outside " .. base, 1, true), out)
        testing.eq(fs.exists(root), true)
        testing.eq(column_of(home, id), board.DEFAULT_NAMES.done)
    end)
end

testing.test("land removes the worktree and branch in a git project", function()
    local base = assert(fs.realpath(support.tempdir()))
    local root = assert(fs.realpath(support.tempdir()))
    local function git(...)
        local argv =
            { "git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@example.com", ... }
        must(dev_os.run(argv, { stdout = "null", stderr = "null" }))
    end
    git("init", "-q", "-b", "master")
    git("commit", "-q", "--allow-empty", "-m", "base")
    local path = base .. "/" .. fs.basename(root) .. "/card"
    assert(fs.mkdir(base .. "/" .. fs.basename(root), { parents = true }), "mkdir failed")
    git("worktree", "add", "-q", "-b", "card", path)
    ffi.C.setenv("DEV_WS_ROOT", base, 1)
    local deleted, why = vcs.delete_branch(root, vcs.GIT, "card")
    testing.eq(deleted, nil)
    testing.ok(why:find("card", 1, true), why)
    local removed, message = ws.remove(root, "card", { inside = true })
    testing.eq(removed, true, message)
    testing.eq(message, "removed " .. path)
    testing.eq(fs.exists(path), false)
    testing.eq(vcs.delete_branch(root, vcs.GIT, "card"), true)
    testing.eq(vcs.delete_branch(root, vcs.GIT, "card"), false)
    git("worktree", "add", "-q", "-b", "card", path)
    local lines = cmd_board.clean_up(path, "card")
    testing.ok(lines:find("removed " .. path, 1, true), lines)
    testing.ok(lines:find("Deleted branch card", 1, true), lines)
    testing.eq(fs.exists(path), false)
    ffi.C.setenv("DEV_WS_ROOT", "", 1)
end)
