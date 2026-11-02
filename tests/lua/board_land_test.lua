local ffi = require("ffi")

local t = require("testing")
local check = require("dev.board.check")
local commands = require("dev.cmd.board")
local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local land = require("dev.board.land")
local localboard = require("dev.board.localboard")
local review = require("dev.board.review")
local support = require("support")
local turn = require("dev.board.turn")

local has_jj = devos.which("jj") ~= nil
local IDENT = { JJ_USER = "t", JJ_EMAIL = "t@example.com" }
local LAND_STUB = [[#!/bin/sh
for word in "$@"; do
    case "$word" in
    *bare*)
        if [ -n "$SHAPE_FAIL" ]; then
            exit 1
        fi
        ;;
    fetch)
        if [ -n "$FETCH_LOG" ]; then
            echo fetch >>"$FETCH_LOG"
        fi
        if [ -n "$FETCH_FAIL" ] && [ -s "$LAND_LOG" ]; then
            echo "fetch refused"
            exit 1
        fi
        ;;
    esac
    if [ "$word" = land ]; then
        echo "$*" >>"$LAND_LOG"
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
        echo "$LAND_MSG"
        exit "${LAND_CODE:-0}"
    fi
done
exec "$REAL_JJ" "$@"
]]
local COMMIT = ("a"):rep(40)
local OTHER = ("b"):rep(40)
local PAST_HOLD_SECONDS = 2.2
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

t.test("check.parse reads what check.record wrote and nothing else", function()
    local rows = {
        { run_id = "8cb600", run = "dev lint", result = "pass", code = 0, tail = "" },
        { run_id = "-", run = "dev test", result = "fail", code = 1, tail = "" },
    }
    local record = check.parse(check.record(STATE, rows, true))
    t.eq(record.commit, COMMIT)
    t.eq(record.change, "chg")
    t.eq(record.mode, "expect-fail")
    t.eq(record.rows, {
        { run_id = "8cb600", run = "dev lint", result = "pass" },
        { run_id = "-", run = "dev test", result = "fail" },
    })
    t.eq(check.parse("a note"), nil)
    t.eq(check.parse("dev-check: commit=zz change=c mode=run"), nil)
    t.eq(check.parse("dev-check: commit=aa change=c mode=run\n2 pass x"), nil)
    t.eq(check.parse("dev-check: commit=aa change=c mode=run\n1 pass dev lint"), nil)
    t.eq(check.parse("dev-check: commit=aa change=c mode=run\n1 pass zz dev lint"), nil)
end)

t.test("review.parse reads what review.record wrote and nothing else", function()
    local text = review.record("style", "rev1", { commit = COMMIT, change = "chg" })
    t.eq(review.parse(text), { kind = "style", by = "rev1", commit = COMMIT, change = "chg" })
    t.eq(review.parse("dev-review: kind=style"), nil)
    t.eq(review.parse("a note"), nil)
end)

t.test("missing_reviews wants a code and a style review of the change", function()
    t.eq(land.missing_reviews({ reviewed("code", COMMIT), reviewed("style", COMMIT) }, STATE), {})
    local missing = land.missing_reviews({ reviewed("code", COMMIT) }, STATE)
    t.eq(#missing, 1)
    t.ok(missing[1]:find("no style review", 1, true), missing[1])
    t.eq(#land.missing_reviews({}, STATE), 2)
    t.eq(
        #land.missing_reviews(
            { reviewed("code", COMMIT), reviewed("style", COMMIT) },
            { commit = COMMIT, change = "other" }
        ),
        2
    )
end)

t.test("a review of an earlier commit needs a recheck at the landing commit", function()
    local old = { reviewed("code", OTHER), reviewed("style", OTHER) }
    local missing = land.missing_reviews(old, STATE)
    t.eq(#missing, 2)
    t.ok(missing[1]:find("earlier commit", 1, true), missing[1])
    old[#old + 1] = reviewed("recheck", OTHER)
    t.eq(#land.missing_reviews(old, STATE), 2)
    old[#old + 1] = reviewed("recheck", COMMIT)
    t.eq(land.missing_reviews(old, STATE), {})
end)

t.test("checks_problem counts only the newest passing run at the commit", function()
    local rows = { "dev lint", "dev test" }
    local pass = checked(COMMIT, "run", { "pass - dev lint", "pass - dev test" })
    t.eq(land.checks_problem({ pass }, STATE, rows), nil)
    t.ok(land.checks_problem({ pass }, STATE, {}):find("no checks rows", 1, true))
    t.ok(land.checks_problem({}, STATE, rows):find("no run of dev board check", 1, true))
    t.ok(
        land.checks_problem({ checked(OTHER, "run", { "pass - a", "pass - b" }) }, STATE, rows)
            :find("no run of dev board check", 1, true)
    )
    local expect = checked(COMMIT, "expect-fail", { "fail - dev lint", "fail - dev test" })
    t.ok(land.checks_problem({ expect }, STATE, rows):find("expect-fail", 1, true))
    local failed = checked(COMMIT, "run", { "pass - dev lint", "fail - dev test" })
    t.ok(land.checks_problem({ pass, failed }, STATE, rows):find("2 fail dev test", 1, true))
    t.eq(land.checks_problem({ failed, pass }, STATE, rows), nil)
    t.ok(land.checks_problem({ pass }, STATE, { "dev lint" }):find("has 2 rows", 1, true))
    t.ok(land.checks_problem({ pass }, STATE, { "dev lint", "dev x" }):find("dev x", 1, true))
    t.ok(
        land.checks_problem(
            { checked(COMMIT, "run", { "timeout - dev lint" }) },
            STATE,
            { "dev lint" }
        )
    )
end)

t.test("overlap names the landing paths a held check reads", function()
    local shared = { "Cargo.lock", "crates/physics" }
    t.eq(land.overlap({ "docs/a.md", "src/b.rs" }, { "src/c.rs" }, shared), {})
    t.eq(land.overlap({ "lib/a.txt", "libx/b.txt" }, {}, { "lib/" }), { "lib/a.txt" })
    t.eq(land.overlap({ "Cargo.lock", "docs/a.md" }, { "src/c.rs" }, shared), { "Cargo.lock" })
    t.eq(land.overlap({ "crates/physics/lib.rs", "crates/physicsx" }, {}, shared), {
        "crates/physics/lib.rs",
    })
    t.eq(land.overlap({ "src/c.rs", "old.rs", "docs/a.md" }, { "old.rs", "src/c.rs" }, shared), {
        "old.rs",
        "src/c.rs",
    })
end)

local function dev(root, home, log, args, extra)
    local env = {
        HOME = home,
        XDG_STATE_HOME = home .. "/state",
        JJ_USER = "t",
        JJ_EMAIL = "t@example.com",
        DEV_AGENT = "lander",
        LAND_LOG = log,
        LAND_MSG = "stub land",
        REAL_JJ = devos.which("jj"),
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
    return id
end

local function approve(root, home, log, id)
    for _, kind in ipairs({ "code", "style" }) do
        must(
            dev(
                root,
                home,
                log,
                { "board", "review", id, "--kind", kind, "--by", "rev", "--rev", "@" }
            )
        )
    end
    must(dev(root, home, log, { "board", "check", id }))
    must(dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
end

local function refused(root, home, log, id, wanted, extra)
    local out, code = dev(root, home, log, { "board", "land", id }, extra)
    t.eq(code, 1, out)
    for _, text in ipairs(wanted) do
        t.ok(out:find(text, 1, true), text .. "\n" .. out)
    end
    t.eq(landed_calls(log), "")
    t.eq(out:find("landed " .. id, 1, true), nil)
    t.ok(column_of(home) ~= "Done", column_of(home))
    return out
end

t.test("land refuses a git project and a caller with no name", function()
    local root, home, log = setup()
    must(devos.run({ "git", "init", "-q", root }, { stdout = "null" }))
    local id = new_card(root, home, log)
    refused(root, home, log, id, { "needs a jj project" })
    local out, code = dev(root, home, log, { "board", "land", id }, { DEV_AGENT = "" })
    t.eq(code, 2, out)
    t.ok(out:find("needs DEV_AGENT", 1, true), out)
    out, code = dev(root, home, log, { "board", "land" })
    t.eq(code, 2, out)
    t.ok(out:find("needs a card", 1, true), out)
end)

t.test("land refuses an agent name that is not one word", function()
    local root, home, log = setup()
    local id = new_card(root, home, log)
    local out, code = dev(root, home, log, { "board", "land", id }, { DEV_AGENT = "two words" })
    t.eq(code, 2, out)
    t.ok(out:find("an agent name is one word of letters, digits and . - _ /", 1, true), out)
    t.eq(landed_calls(log), "")
end)

local CARD_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
local CARD_PREFIX = CARD_ID:sub(1, 8)

local function fake_backend(root, card)
    local backend = { root = root, column_map = {}, notes = {} }
    card = card or {}
    local view = {
        id = CARD_ID,
        name = "Card",
        column = "In Review",
        labels = {},
        outcomes = { { id = "o1", name = "It works", done = true } },
        checks = { "true" },
    }
    for key, value in pairs(card) do
        view[key] = value
    end
    function backend:done_columns()
        return { "Done" }
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
    ffi.C.setenv("DEV_AGENT", "lander", 1)
    local ok, result = pcall(commands.run, "land", { CARD_PREFIX }, backend)
    ffi.C.setenv("DEV_AGENT", previous, 1)
    assert(ok, result)
    return result
end

t.test("land refuses a board with no project root", function()
    local backend = fake_backend(nil)
    local result = land_as_lander(backend)
    t.eq(result.code, 1)
    t.eq(result.message, "dev board land needs the project's root")
    t.eq(backend.notes, {})
end)

if has_jj then
    local function jj(root, ...)
        local argv = { "jj", "--no-pager", "--color", "never", "-R", root, ... }
        local out, code = devos.capture(argv, { stderr = "null", env = IDENT })
        assert(code == 0, out)
        return out
    end

    local function git(dir, ...)
        local argv =
            { "git", "-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.com", ... }
        must(devos.run(argv, { stdout = "null", stderr = "null" }))
    end

    local LIB_CONFIG = '\n[board.land]\nshared = ["lib"]\n'

    local function jj_project(extra)
        local root, home, log = setup(extra or LIB_CONFIG)
        assert(fs.write(root .. "/bin/jj", LAND_STUB), "write failed")
        must(devos.run({ "chmod", "755", root .. "/bin/jj" }))
        local bare = support.tempdir()
        must(
            devos.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, { stdout = "null" })
        )
        must(
            devos.run(
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
        backend.roles = { icebox = "Icebox" }
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

    t.test("a card that meets every condition lands, gets a done note and reaches Done", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        local commit = head(root)
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        t.eq(code, 0, out)
        t.ok(
            out:find(
                "landed " .. id .. " at commit " .. commit:sub(1, 12) .. " and moved it to Done",
                1,
                true
            ),
            out
        )
        t.ok(landed_calls(log):find("land --yes", 1, true), landed_calls(log))
        local list = comments(home)
        local last = list[#list]
        t.eq(last.kind, "done")
        t.ok(last.body:find("Landed commit " .. commit:sub(1, 12), 1, true), last.body)
        t.eq(column_of(home), "Done")
    end)

    t.test("a land that rewrites the commit notes the commit on trunk", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        local before = head(root)
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "rewrite" })
        t.eq(code, 0, out)
        local after = jj(root, "log", "-r", "master@origin", "--no-graph", "-T", "commit_id")
        t.ok(before ~= after, "the stub must rewrite the commit")
        t.ok(out:find("at commit " .. after:sub(1, 12) .. " and moved", 1, true), out)
        t.eq(out:find(before:sub(1, 12), 1, true), nil, out)
        local list = comments(home)
        local last = list[#list]
        t.ok(last.body:find("Landed commit " .. after:sub(1, 12), 1, true), last.body)
        t.eq(last.body:find(before:sub(1, 12), 1, true), nil, last.body)
        t.eq(column_of(home), "Done")
    end)

    t.test(
        "a land whose trunk cannot be read notes the earlier commit and still reaches Done",
        function()
            local root, home, log = jj_project()
            local id = new_card(root, home, log)
            must(dev(root, home, log, { "board", "move", id, "review" }))
            approve(root, home, log, id)
            local commit = head(root)
            local out, code = dev(root, home, log, { "board", "land", id })
            t.eq(code, 0, out)
            t.ok(out:find("at commit " .. commit:sub(1, 12), 1, true), out)
            t.ok(out:find("trunk could not be read", 1, true), out)
            local list = comments(home)
            local last = list[#list]
            t.eq(last.kind, "done")
            t.ok(last.body:find(commit:sub(1, 12), 1, true), last.body)
            t.ok(last.body:find("may differ", 1, true), last.body)
            t.eq(column_of(home), "Done")
        end
    )

    t.test("a failed jj land leaves the card In Review and exits non-zero", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        local before = #comments(home)
        local out, code = dev(
            root,
            home,
            log,
            { "board", "land", id },
            { LAND_CODE = "1", LAND_MSG = "boom" }
        )
        t.eq(code, 1, out)
        t.ok(out:find("stays in In Review", 1, true) and out:find("boom", 1, true), out)
        t.ok(landed_calls(log):find("land", 1, true))
        t.eq(#comments(home), before)
        t.eq(column_of(home), "In Review")
    end)

    t.test("land names every missing condition and runs nothing", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        refused(root, home, log, id, {
            "it is in Backlog, and only a card in In Review lands",
            "1 of 1 outcomes are unticked",
            "no code review of change",
            "no style review of change",
            "no run of dev board check",
        })
    end)

    t.test("land refuses another claimant's card", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "take", id, "--as", "builder" }))
        refused(root, home, log, id, { "claimed by builder", "not lander" })
        must(dev(root, home, log, { "board", "release", id }))
    end)

    t.test("a claimed card's review comes from another name, never its claimant", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "take", id, "--as", "builder" }))
        local before = #comments(home, id)
        for _, kind in ipairs({ "code", "style", "recheck" }) do
            local out, code = dev(root, home, log, {
                "board",
                "review",
                id,
                "--kind",
                kind,
                "--by",
                "builder",
                "--rev",
                "@",
            })
            t.eq(code, 1, out)
            t.ok(out:find("a reviewer other than builder must record it", 1, true), out)
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
            }, { DEV_AGENT = "builder" })
            t.eq(code, 1, out)
            t.ok(out:find("a reviewer other than builder must record it", 1, true), out)
        end
        t.eq(#comments(home, id), before)
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
        }))
        local list = comments(home, id)
        t.eq(#list, before + 1)
        t.ok(list[#list].body:find("dev-review: kind=code by=rev", 1, true), list[#list].body)
    end)

    t.test("land refuses a working copy that is empty or undescribed", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        jj(root, "describe", "-m", "")
        refused(root, home, log, id, { "has no description" })
        jj(root, "describe", "-m", "feat: work")
        jj(root, "new", "-m", "next")
        refused(root, home, log, id, { "is empty" })
    end)

    t.test("a check run at an older commit or with a failing row does not count", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        assert(fs.write(root .. "/work.txt", "two\n"), "write failed")
        refused(root, home, log, id, { "no run of dev board check is recorded at commit" })
        must(dev(root, home, log, { "board", "checks", id, "false" }))
        local _, code = dev(root, home, log, { "board", "check", id })
        t.eq(code, 1)
        refused(root, home, log, id, {
            "earlier commit than",
            "did not pass every row (1 fail false)",
        })
    end)

    t.test("an expect-fail record never counts as a passing check", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "checks", id, "false" }))
        must(dev(root, home, log, { "board", "move", id, "review" }))
        for _, kind in ipairs({ "code", "style" }) do
            must(
                dev(
                    root,
                    home,
                    log,
                    { "board", "review", id, "--kind", kind, "--by", "rev", "--rev", "@" }
                )
            )
        end
        must(dev(root, home, log, { "board", "check", id, "--expect-fail" }))
        must(dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        refused(root, home, log, id, { "no run of dev board check is recorded", "expect-fail" })
    end)

    t.test("a change after the reviews needs a recheck at the landing commit", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        assert(fs.write(root .. "/work.txt", "two\n"), "write failed")
        must(dev(root, home, log, { "board", "check", id }))
        refused(root, home, log, id, { "earlier commit than", "dev board review --kind recheck" })
        must(
            dev(
                root,
                home,
                log,
                { "board", "review", id, "--kind", "recheck", "--by", "rev", "--rev", "@" }
            )
        )
        local out, code = dev(root, home, log, { "board", "land", id })
        t.eq(code, 0, out)
    end)

    t.test("land rebases onto trunk under the turn when trunk has moved", function()
        local root, home, log, bare = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        local other = support.tempdir() .. "/clone"
        must(
            devos.run(
                { "git", "clone", "-q", "--branch", "master", bare, other },
                { stdout = "null", stderr = "null" }
            )
        )
        git(other, "commit", "-q", "--allow-empty", "-m", "moved")
        git(other, "push", "-q", "origin", "HEAD:refs/heads/master")
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        t.eq(code, 0, out)
        t.eq(out:find("trunk has moved", 1, true), nil, out)
        t.eq(column_of(home), "Done")
        t.eq(turn_holder(home), nil)
    end)

    t.test("land names the holder and since when while another card holds the turn", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        local held = hold_turn(home, "other", "cccc3333")
        local out, code = dev(root, home, log, { "board", "land", id, "--wait", "0" })
        t.eq(code, 1, out)
        t.ok(out:find("held by other since 20", 1, true), out)
        t.eq(column_of(home), "In Review")
        _, code = dev(root, home, log, { "board", "land", id, "--wait", "x" })
        t.eq(code, 2)
        _, code = dev(root, home, log, { "board", "land", id, "--wait", "999999999" })
        t.eq(code, 2)
        release_turn(home, held)
        out, code = dev(
            root,
            home,
            log,
            { "board", "land", id, "--wait", "0" },
            { LAND_TRUNK = "keep" }
        )
        t.eq(code, 0, out)
        t.eq(column_of(home), "Done")
        t.eq(turn_holder(home), nil)
    end)

    t.test("land leaves a change on an unlanded parent where it is", function()
        local root, home, log, bare = jj_project()
        jj(root, "new", "-m", "feat: child")
        assert(fs.write(root .. "/child.txt", "two\n"), "write failed")
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        local other = support.tempdir() .. "/clone"
        must(
            devos.run(
                { "git", "clone", "-q", "--branch", "master", bare, other },
                { stdout = "null", stderr = "null" }
            )
        )
        git(other, "commit", "-q", "--allow-empty", "-m", "moved")
        git(other, "push", "-q", "origin", "HEAD:refs/heads/master")
        local before = head(root)
        refused(root, home, log, id, { "sits on an unlanded parent" })
        t.eq(head(root), before)
        t.eq(turn_holder(home), nil)
    end)

    t.test("land waits up to the wait and then names the holder", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        local held = hold_turn(home, "other", "cccc3333")
        local out, code = dev(root, home, log, { "board", "land", id, "--wait", "1" })
        t.eq(code, 1, out)
        t.ok(out:find("held by other since", 1, true), out)
        t.eq(assert(turn_holder(home)).name, "other")
        release_turn(home, held)
    end)

    t.test("land gives the turn back when it refuses", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        must(dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        local out, code = dev(root, home, log, { "board", "land", id })
        t.eq(code, 1, out)
        t.ok(out:find("no code review", 1, true), out)
        t.ok(
            fs.read(home .. "/state/dev/boards/mine.json"):find("dev-turn: holder=lander", 1, true)
        )
        t.eq(turn_holder(home), nil)
    end)

    local function trunk_moves(root, bare, files)
        local other = support.tempdir() .. "/clone"
        must(
            devos.run(
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
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        return id
    end

    t.test("land after another lander's turn ends rebases without a trunk-moved refusal", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        local held = hold_turn(home, "other", "cccc3333")
        local first, first_code = dev(root, home, log, { "board", "land", id, "--wait", "0" })
        t.eq(first_code, 1, first)
        t.ok(first:find("held by other since", 1, true), first)
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        release_turn(home, held)
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        t.eq(code, 0, out)
        t.ok(not out:find("trunk has moved", 1, true), out)
        t.eq(column_of(home), "Done")
        t.eq(turn_holder(home), nil)
    end)

    t.test("land carries the check and reviews over a rebase past unrelated commits", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        local before = head(root)
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        t.ok(head(root) ~= before, "the rebase must rewrite the commit")
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        t.eq(code, 0, out)
        local list = comments(home)
        local last = list[#list]
        t.eq(last.kind, "done")
        t.ok(last.body:find("carried over from commit " .. before:sub(1, 12), 1, true), last.body)
        t.eq(column_of(home), "Done")
    end)

    t.test("land reads trunk under the turn, to carry and after the land", function()
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
        t.eq(code, 0, out)
        local list = comments(home)
        t.ok(list[#list].body:find("carried over", 1, true), list[#list].body)
        t.eq(fs.read(reads), "fetch\nfetch\nfetch\n")
    end)

    t.test("land stays put when the push after a carry is rejected", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        local out, code = dev(root, home, log, { "board", "land", id }, {
            LAND_CODE = "1",
            LAND_MSG = "push rejected: trunk moved",
        })
        t.eq(code, 1, out)
        t.ok(out:find("jj land failed", 1, true), out)
        t.ok(out:find("push rejected: trunk moved", 1, true), out)
        t.eq(column_of(home), "In Review")
    end)

    t.test("land does not carry a pass over a failed run at the rebased commit", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare, "test ! -e docs.txt")
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        local out, code = dev(root, home, log, { "board", "check", id })
        t.ok(code ~= 0, out)
        refused(root, home, log, id, { "did not pass every row" })
    end)

    t.test("land does not carry over an expect-fail record at the rebased commit", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        dev(root, home, log, { "board", "check", id, "--expect-fail" })
        refused(root, home, log, id, { "no run of dev board check is recorded" })
    end)

    t.test("land refuses a rebase past a commit that touches the change's file", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["shared.txt"] = "A\nb\nc\nd\ne\nf\ng\n" })
        rebase_onto_trunk(root)
        refused(root, home, log, id, { "touch files this change changes: shared.txt" })
    end)

    t.test("land names only the unticked outcome after a rebase that the carry accepts", function()
        local root, home, log, bare = jj_project()
        trunk_moves(root, bare, { ["shared.txt"] = SHARED })
        rebase_onto_trunk(root)
        assert(fs.write(root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nG\n"), "write failed")
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        for _, kind in ipairs({ "code", "style" }) do
            must(
                dev(
                    root,
                    home,
                    log,
                    { "board", "review", id, "--kind", kind, "--by", "rev", "--rev", "@" }
                )
            )
        end
        must(dev(root, home, log, { "board", "check", id }))
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        local out = refused(root, home, log, id, { "1 of 1 outcomes are unticked" })
        t.eq(out:find("review of", 1, true), nil, out)
        t.eq(out:find("no run of dev board check", 1, true), nil, out)
    end)

    t.test("land names the overlap beside an unticked outcome", function()
        local root, home, log, bare = jj_project()
        trunk_moves(root, bare, { ["shared.txt"] = SHARED })
        rebase_onto_trunk(root)
        assert(fs.write(root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nG\n"), "write failed")
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        for _, kind in ipairs({ "code", "style" }) do
            must(
                dev(
                    root,
                    home,
                    log,
                    { "board", "review", id, "--kind", kind, "--by", "rev", "--rev", "@" }
                )
            )
        end
        must(dev(root, home, log, { "board", "check", id }))
        trunk_moves(root, bare, { ["shared.txt"] = "A\nb\nc\nd\ne\nf\ng\n" })
        rebase_onto_trunk(root)
        refused(root, home, log, id, {
            "1 of 1 outcomes are unticked",
            "touch files this change changes: shared.txt",
        })
    end)

    t.test("land names the column beside the carry after an accepted rebase", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        must(dev(root, home, log, { "board", "move", id, "progress" }))
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        local out = refused(root, home, log, id, { "only a card in" })
        t.eq(out:find("earlier commit", 1, true), nil, out)
        t.eq(out:find("no run of dev board check", 1, true), nil, out)
    end)

    t.test(
        "land refuses a carry when trunk changed a shared path the change does not touch",
        function()
            local root, home, log, bare = jj_project()
            local id = review_ready(root, home, log, bare)
            trunk_moves(root, bare, { ["lib/core.txt"] = "core\n" })
            rebase_onto_trunk(root)
            refused(
                root,
                home,
                log,
                id,
                { "the shared paths differ from the checked commit", "lib/core.txt" }
            )
        end
    )

    t.test("land carries nothing in a project that lists no shared paths", function()
        local root, home, log, bare = jj_project("")
        local id = review_ready(root, home, log, bare)
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        refused(root, home, log, id, { "lists no shared paths under [board.land]" })
    end)

    local BAD_LISTS = {
        { 'shared = ["a\\\\b"]', "not a plain path" },
        { 'shared = ["a\\"b"]', "not a plain path" },
        { 'shared = [""]', "not a plain path" },
        { "shared = [3]", "not a plain path" },
        { 'shared = "lib"', "must be a list of paths" },
        { "shared = []", "lists no shared paths" },
        { 'shared = ["lib", "libb"]', "libb matches no file" },
    }

    for _, bad in ipairs(BAD_LISTS) do
        t.test("land carries nothing for " .. bad[1], function()
            local root, home, log, bare = jj_project("\n[board.land]\n" .. bad[1] .. "\n")
            local id = review_ready(root, home, log, bare)
            trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(root)
            refused(root, home, log, id, { bad[2] })
        end)
    end

    t.test("land refuses a rebase of a commit that differs from the checked one", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        local before = head(root)
        assert(fs.write(root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nH\n"), "write failed")
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        refused(root, home, log, id, { "differs from the checked commit " .. before:sub(1, 12) })
    end)

    t.test("land refuses a duplicate of the checked change under another change id", function()
        local root, home, log, bare = jj_project()
        local id = review_ready(root, home, log, bare)
        jj(root, "duplicate", "@")
        local copy = jj(root, "log", "-r", "children(@-) ~ @", "--no-graph", "-T", "change_id")
        jj(root, "edit", copy)
        local out = refused(root, home, log, id, { "no code review of change" })
        t.eq(out:find("carried over", 1, true), nil, out)
    end)

    t.test("land does not carry a review that was never recorded at the checked commit", function()
        local root, home, log, bare = jj_project()
        trunk_moves(root, bare, { ["shared.txt"] = SHARED })
        rebase_onto_trunk(root)
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        must(
            dev(
                root,
                home,
                log,
                { "board", "review", id, "--kind", "code", "--by", "rev", "--rev", "@" }
            )
        )
        must(dev(root, home, log, { "board", "check", id }))
        must(dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        trunk_moves(root, bare, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(root)
        refused(root, home, log, id, { "no style review of change" })
    end)

    t.test("land refuses a working copy that holds conflicts", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        local first = jj(root, "log", "-r", "@", "--no-graph", "-T", "change_id")
        jj(root, "new", "master", "-m", "feat: other")
        assert(fs.write(root .. "/work.txt", "two\n"), "write failed")
        jj(root, "rebase", "-r", "@", "-d", first)
        refused(root, home, log, id, { "the working-copy commit has conflicts" })
    end)

    t.test("land refuses a card labelled needs:human", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "blocked" }))
        must(dev(root, home, log, { "board", "label", id, "needs:human" }))
        refused(root, home, log, id, { "is labelled needs:human", "waits on the owner" })
    end)

    t.test("land refuses when the fetch from the remote of record fails", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        jj(root, "git", "remote", "set-url", "origin", root .. "/missing-remote")
        refused(root, home, log, id, { "trunk cannot be compared", "the fetch from origin failed" })
    end)

    t.test("land refuses when the card's comments cannot be read", function()
        local root = jj_project()
        local backend = fake_backend(root)
        function backend:comments()
            return nil, "board unavailable: comments timed out"
        end
        local result = land_as_lander(backend)
        t.eq(result.code, 1)
        t.eq(result.message, "board unavailable: comments timed out")
        t.eq(backend.notes, {})
    end)

    t.test("land refuses when the board's cards cannot be read", function()
        local root = jj_project()
        local backend = fake_backend(root)
        function backend:cards()
            return nil, "board unavailable: cards timed out"
        end
        local result = land_as_lander(backend)
        t.eq(result.code, 1)
        t.eq(result.message, "board unavailable: cards timed out")
        t.eq(backend.notes, {})
    end)

    t.test("land names outcomes that cannot be read and does not land", function()
        local root = jj_project()
        local backend = fake_backend(root, { outcomes_unreadable = true })
        local result = land_as_lander(backend)
        t.eq(result.code, 1)
        t.ok(result.message:find(CARD_PREFIX .. " cannot land:", 1, true), result.message)
        t.ok(
            result.message:find(
                "its outcomes cannot be read from Pomb, so they cannot be checked",
                1,
                true
            ),
            result.message
        )
        t.eq(backend.notes, {})
    end)

    t.test("land refuses a working copy that jj cannot read", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
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
        t.ok(out:find(root, 1, true), out)
    end)

    t.test("land refuses a remote of record that is not a remote of the project", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        refused(root, home, log, id, {
            "trunk cannot be compared: the remote of record gerrit is not a remote of this project",
        }, { JJ_FORGE = "gerrit" })
    end)

    t.test("a landed commit whose done note was not written is named and exits non-zero", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        local commit = head(root)
        local out, code = dev(root, home, log, { "board", "land", id }, {
            LAND_TRUNK = "keep",
            BREAK_BOARD = home .. "/state/dev/boards/mine.json",
        })
        t.eq(code, 1, out)
        t.ok(landed_calls(log):find("land --yes", 1, true), landed_calls(log))
        t.ok(
            out:find(
                "landed commit " .. commit:sub(1, 12) .. ", but the done note was NOT written",
                1,
                true
            ),
            out
        )
        t.ok(out:find("the card was not moved", 1, true), out)
    end)

    t.test("a fetch that fails after the land falls back to the commit from before it", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        local before = head(root)
        local out, code = dev(root, home, log, { "board", "land", id }, {
            LAND_TRUNK = "rewrite",
            FETCH_FAIL = "1",
        })
        t.eq(code, 0, out)
        local after = jj(root, "log", "-r", "master@origin", "--no-graph", "-T", "commit_id")
        t.ok(before ~= after, "the stub must rewrite the commit")
        t.ok(out:find("at commit " .. before:sub(1, 12), 1, true), out)
        t.ok(out:find("trunk could not be read", 1, true), out)
        t.eq(out:find(after:sub(1, 12), 1, true), nil, out)
        local list = comments(home)
        local last = list[#list]
        t.eq(last.kind, "done")
        t.ok(last.body:find(before:sub(1, 12), 1, true), last.body)
        t.ok(last.body:find("may differ", 1, true), last.body)
        t.eq(column_of(home), "Done")
    end)

    t.test("a landed card whose move to Done fails is named and exits non-zero", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        local out = dev(
            root,
            home,
            log,
            { "board", "add", "Child", "--problem", "x", "--size", "1", "--done-when", "x" }
        )
        local child = assert(out:match("added (%x+)"), out)
        must(dev(root, home, log, { "board", "link", child, "parent", id }))
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        must(dev(root, home, log, { "board", "turn", id }))
        local commit = head(root)
        local code
        out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        t.eq(turn_holder(home), nil)
        t.eq(code, 1, out)
        t.ok(landed_calls(log):find("land --yes", 1, true), landed_calls(log))
        t.ok(
            out:find("landed commit " .. commit:sub(1, 12) .. " and noted it on " .. id, 1, true),
            out
        )
        t.ok(out:find("but the move to Done failed", 1, true), out)
        t.ok(out:find("1 of 1 children are open", 1, true), out)
        local list = comments(home, id)
        t.eq(list[#list].kind, "done")
        t.eq(column_of(home, id), "In Review")
    end)

    local function in_review(root, home, log)
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        return id
    end

    t.test("a held turn survives a check and lands the card under it", function()
        local root, home, log = jj_project()
        local id = in_review(root, home, log)
        local out, code = dev(root, home, log, { "board", "turn", id })
        t.eq(code, 0, out)
        t.ok(out:find("holding the landing turn for " .. id, 1, true), out)
        approve(root, home, log, id)
        t.eq(assert(turn_holder(home)).name, "lander")
        out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        t.eq(code, 0, out)
        t.eq(column_of(home, id), "Done")
        t.eq(turn_holder(home), nil)
    end)

    t.test("a second runner is told who holds the turn and since when", function()
        local root, home, log = jj_project()
        local id = in_review(root, home, log)
        must(dev(root, home, log, { "board", "turn", id }))
        local out, code = dev(
            root,
            home,
            log,
            { "board", "turn", id, "--wait", "0" },
            { DEV_AGENT = "other" }
        )
        t.eq(code, 1, out)
        t.ok(out:find("held by lander since 20", 1, true), out)
        out, code = dev(root, home, log, { "board", "turn", id, "--hold", "120" })
        t.eq(code, 0, out)
        t.ok(out:find("renewed the landing turn held for " .. id, 1, true), out)
        t.eq(assert(turn_holder(home)).name, "lander")
    end)

    t.test("land refuses a hold that ran out and lands nothing", function()
        local root, home, log = jj_project()
        local id = in_review(root, home, log)
        approve(root, home, log, id)
        must(dev(root, home, log, { "board", "turn", id, "--hold", "1" }))
        devos.nap(PAST_HOLD_SECONDS)
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        t.eq(code, 1, out)
        t.ok(out:find("ran out or was taken by another", 1, true), out)
        t.eq(landed_calls(log), "")
        t.eq(column_of(home, id), "In Review")
    end)

    t.test("land refuses a hold another runner took after it ran out", function()
        local root, home, log = jj_project()
        local id = in_review(root, home, log)
        approve(root, home, log, id)
        must(dev(root, home, log, { "board", "turn", id, "--hold", "1" }))
        devos.nap(PAST_HOLD_SECONDS)
        must(dev(root, home, log, { "board", "turn", id }, { DEV_AGENT = "other" }))
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        t.eq(code, 1, out)
        t.ok(out:find("ran out or was taken by another", 1, true), out)
        t.eq(landed_calls(log), "")
        t.eq(assert(turn_holder(home)).name, "other")
    end)

    t.test("a refused landing keeps the hold until it is released", function()
        local root, home, log = jj_project()
        local id = in_review(root, home, log)
        must(dev(root, home, log, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        must(dev(root, home, log, { "board", "turn", id }))
        local out, code = dev(root, home, log, { "board", "land", id })
        t.eq(code, 1, out)
        t.ok(out:find("no code review", 1, true), out)
        t.ok(out:find("turn you hold for " .. id .. " stays held", 1, true), out)
        t.eq(assert(turn_holder(home)).name, "lander")
        out, code = dev(root, home, log, { "board", "turn", id, "--release" })
        t.eq(code, 0, out)
        t.eq(turn_holder(home), nil)
        _, code = dev(root, home, log, { "board", "turn", id, "--release" })
        t.eq(code, 1)
    end)

    t.test("a landing refused before the turn is read says the hold is kept", function()
        local root, home, log = jj_project()
        local id = in_review(root, home, log)
        must(dev(root, home, log, { "board", "turn", id }))
        local out, code = dev(root, home, log, { "board", "land", id })
        t.eq(code, 1, out)
        t.ok(out:find("turn you hold for " .. id .. " stays held", 1, true), out)
        t.eq(assert(turn_holder(home)).name, "lander")
    end)

    t.test("turn refuses a hold outside 1 to 7200 seconds", function()
        local root, home, log = jj_project()
        local id = in_review(root, home, log)
        for _, bad in ipairs({ "0", "7201", "x" }) do
            local out, code = dev(root, home, log, { "board", "turn", id, "--hold", bad })
            t.eq(code, 2, out)
        end
        local _, code = dev(root, home, log, { "board", "turn", id, "--hold", "7200" })
        t.eq(code, 0)
    end)

    t.test("release clears a hold that ran out, and land then asks for a fresh turn", function()
        local root, home, log = jj_project()
        local id = in_review(root, home, log)
        approve(root, home, log, id)
        must(dev(root, home, log, { "board", "turn", id, "--hold", "1" }))
        devos.nap(PAST_HOLD_SECONDS)
        local out, code = dev(root, home, log, { "board", "turn", id, "--release" })
        t.eq(code, 0, out)
        t.ok(out:find("was already gone", 1, true), out)
        out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        t.eq(code, 0, out)
        t.eq(column_of(home, id), "Done")
    end)

    t.test("turn refuses a card that is already in Done", function()
        local root, home, log = jj_project()
        local id = in_review(root, home, log)
        approve(root, home, log, id)
        must(dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" }))
        local out, code = dev(root, home, log, { "board", "turn", id })
        t.eq(code, 1, out)
        t.ok(out:find("is done", 1, true), out)
        t.eq(turn_holder(home), nil)
    end)

    local function turn_notes(home)
        local doc = assert(
            json.decode(assert(fs.read(home .. "/state/dev/boards/mine.json"), "read failed")),
            "decode failed"
        )
        for _, card in ipairs(doc.cards) do
            if card.name == turn.NAME then
                return card.comments or {}
            end
        end
        return {}
    end

    local function hold_check(home, commit)
        local backend, restore = board_at(home)
        assert(
            turn.begin_check(
                backend,
                { name = "other", card = "cccc3333", commit = commit, seconds = 600 }
            )
        )
        restore()
    end

    local function end_hold(home, commit)
        local backend, restore = board_at(home)
        turn.end_check(backend, { name = "other", card = "cccc3333", commit = commit })
        restore()
    end

    local function sibling_commit(root, work)
        jj(root, "new", "master", "-m", "held")
        assert(fs.write(root .. "/held.txt", "held\n"), "write failed")
        local commit = head(root)
        jj(root, "edit", work)
        return commit
    end

    local function blocked(opts)
        local root, home, log = opts.root, opts.home, opts.log
        local out, code = dev(root, home, log, { "board", "land", opts.id, "--wait", "0" })
        t.eq(code, 1, out)
        for _, text in ipairs(opts.wanted) do
            t.ok(out:find(text, 1, true), text .. "\n" .. out)
        end
        t.eq(landed_calls(log), "")
        t.eq(turn_holder(home), nil)
        t.ok(column_of(home) ~= "Done", column_of(home))
    end

    local function lander_ready(root, home, log)
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        return id
    end

    t.test("check holds itself on the turn card while it runs and lets go when it ends", function()
        local root, home, log = jj_project()
        lander_ready(root, home, log)
        local notes = turn_notes(home)
        local seen = {}
        for _, note in ipairs(notes) do
            seen[#seen + 1] = note.body:match("^dev%-turn: (%a+) holder=lander card=%x+")
        end
        t.eq(seen, { "check", "checked" })
        local backend, restore = board_at(home)
        t.eq(turn.checking(backend), {})
        restore()
    end)

    t.test("a failing check still ends its hold", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "checks", id, "false" }))
        local _, code = dev(root, home, log, { "board", "check", id })
        t.eq(code, 1)
        local kinds = {}
        for _, note in ipairs(turn_notes(home)) do
            kinds[#kinds + 1] = note.body:match("^dev%-turn: (%a+) holder=lander")
        end
        t.eq(kinds, { "check", "checked" })
    end)

    t.test("check writes no hold with --expect-fail or without a shared list", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        dev(root, home, log, { "board", "check", id, "--expect-fail" })
        t.eq(turn_notes(home), {})
        local bare_root, bare_home, bare_log = jj_project("")
        local bare_id = new_card(bare_root, bare_home, bare_log)
        must(dev(bare_root, bare_home, bare_log, { "board", "check", bare_id }))
        t.eq(turn_notes(bare_home), {})
    end)

    t.test("a landing that touches nothing a held check reads goes ahead", function()
        local root, home, log = jj_project()
        local id = lander_ready(root, home, log)
        hold_check(home, sibling_commit(root, head(root)))
        local out, code = dev(root, home, log, { "board", "land", id, "--wait", "0" }, {
            LAND_TRUNK = "keep",
        })
        t.eq(code, 0, out)
        t.eq(column_of(home), "Done")
    end)

    t.test("a landing that touches a file of the held change waits for the check", function()
        local root, home, log = jj_project()
        local id = lander_ready(root, home, log)
        local work_commit = head(root)
        hold_check(home, work_commit)
        blocked({
            root = root,
            home = home,
            log = log,
            id = id,
            wanted = { "check held for cccc3333", "work.txt" },
        })
        end_hold(home, work_commit)
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        t.eq(code, 0, out)
        t.eq(column_of(home), "Done")
    end)

    t.test("a landing polls under --wait and goes ahead once the hold lapses", function()
        local root, home, log = jj_project()
        local id = lander_ready(root, home, log)
        local previous = turn.CHECK_GRACE_SECONDS
        turn.CHECK_GRACE_SECONDS = 0
        local backend, restore = board_at(home)
        assert(
            turn.begin_check(
                backend,
                { name = "other", card = "cccc3333", commit = head(root), seconds = 3 }
            )
        )
        restore()
        turn.CHECK_GRACE_SECONDS = previous
        local started = os.time()
        local out, code = dev(root, home, log, { "board", "land", id, "--wait", "30" }, {
            LAND_TRUNK = "keep",
        })
        t.eq(code, 0, out)
        t.ok(os.time() - started >= 2, "the landing must wait for the hold")
        t.eq(column_of(home), "Done")
    end)

    t.test("a landing on a shared path waits for a check that does not touch it", function()
        local root, home, log = jj_project()
        assert(fs.write(root .. "/lib/extra.txt", "extra\n"), "write failed")
        local id = lander_ready(root, home, log)
        hold_check(home, sibling_commit(root, head(root)))
        blocked({
            root = root,
            home = home,
            log = log,
            id = id,
            wanted = { "check held for cccc3333", "lib/extra.txt" },
        })
    end)

    t.test("a held check whose runner died stops blocking once its end time passes", function()
        local root, home, log = jj_project()
        local id = lander_ready(root, home, log)
        local previous = turn.CHECK_GRACE_SECONDS
        turn.CHECK_GRACE_SECONDS = 0
        local backend, restore = board_at(home)
        assert(
            turn.begin_check(
                backend,
                { name = "other", card = "cccc3333", commit = head(root), seconds = 3 }
            )
        )
        t.eq(#assert(turn.checking(backend)), 1)
        devos.nap(PAST_HOLD_SECONDS + 2)
        t.eq(turn.checking(backend), {})
        restore()
        turn.CHECK_GRACE_SECONDS = previous
        local out, code = dev(root, home, log, { "board", "land", id }, { LAND_TRUNK = "keep" })
        t.eq(code, 0, out)
    end)
end
