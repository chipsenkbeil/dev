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
    "heads((::"*"& ::@-")
        if [ -n "$ANCESTOR_FAIL_AT" ]; then
            case "$word" in
            "heads((::$ANCESTOR_FAIL_AT-)"*) exit 1 ;;
            esac
        fi
        ;;
    "heads((::"*)
        if [ -n "$PARENT_FAIL_AT" ]; then
            case "$word" in
            "heads((::$PARENT_FAIL_AT-)"*) exit 1 ;;
            esac
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
local LAND_TRUNK_KEEP = "keep"
local LAND_TRUNK_REWRITE = "rewrite"
local KIND_DONE = "done"
local COMMIT = ("a"):rep(40)
local OTHER = ("b"):rep(40)
local PAST_HOLD_SECONDS = 2.2
local SHORT_CLAIM_SECONDS = 60
local ASK_TIMEOUT_SECONDS = 30
local ASK_POLL_SECONDS = 0.2
local LOST_HOLD_SECONDS = "1"
local SHORT_WAIT_SECONDS = "1"
local LONG_WAIT_SECONDS = "60"
local HELD_LEASE_SECONDS = 600
local TURN_CAP_SECONDS = 1
local PAST_CAP_SECONDS = 2
local CHECK_WAIT_SECONDS = 60
local CHECK_STOP_SECONDS = 300
local SHARED = "a\nb\nc\nd\ne\nf\ng\n"
local NEAR_EDIT = "a\nb\nc\nD\ne\nf\ng\n"
local NARROWED = '[board]\nbackend = "local"\nname = "mine"\n\n[board.land]\nrecheck = []\n'

local function setup(extra)
    local root = support.sandbox({
        [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "mine"\n' .. (extra or ""),
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    assert(fs.write(home .. "/.config/dev/config.toml", ""), "write failed")
    return { root = root, home = home, log = support.tempdir() .. "/land.log" }
end

local function must(first, second)
    local code = type(first) == "number" and first or second
    assert(code == 0, tostring(first))
end

local function checked(commit, mode, rows)
    local lines, commands = {}, {}
    for i, row in ipairs(rows) do
        local result, run_id, command = row:match("^(%a+) (%S+) (.+)$")
        lines[i] = i .. " " .. result .. " " .. run_id
        commands[i] = command
    end
    local head = string.format(
        "dev-check: commit=%s change=chg mode=%s rows=%d sum=%s",
        commit,
        mode,
        #rows,
        check.fingerprint(commands)
    )
    return { body = head .. "\n" .. table.concat(lines, "\n") }
end

local function reviewed(kind, commit, of)
    return {
        body = "dev-review: kind="
            .. kind
            .. " by=r commit="
            .. commit
            .. " change=chg"
            .. (of and (" of=" .. of) or ""),
    }
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
    testing.eq(record.mode, check.Mode.EXPECT_FAIL)
    testing.eq(record.rows, {
        { run_id = "8cb600", result = "pass" },
        { run_id = "-", result = "fail" },
    })
    testing.eq(record.sum, check.fingerprint({ "dev lint", "dev test" }))
    local head = "dev-check: commit=aa change=c mode=run rows="
    testing.eq(check.parse("a note"), nil)
    testing.eq(check.parse("dev-check: commit=zz change=c mode=run rows=0 sum=ab"), nil)
    testing.eq(check.parse(head .. "1 sum=ab\n2 pass x"), nil)
    testing.eq(check.parse(head .. "1 sum=ab\n1 pass dev lint"), nil)
    testing.eq(check.parse(head .. "2 sum=ab\n1 pass 8cb600"), nil)
end)

testing.test("land reads a short check record and refuses rows that changed", function()
    local rows = { "dev lint", "dev test" }
    local pass = checked(COMMIT, check.Mode.RUN, { "pass 8cb600 dev lint", "pass 1f2e3d dev test" })
    testing.eq(land.checks_problem({ pass }, STATE, rows), nil)
    local problem = land.checks_problem({ pass }, STATE, { "dev lint", "dev other" })
    testing.ok(problem:find("checks rows changed", 1, true), problem)
    testing.ok(problem:find("Run `dev board check` again", 1, true), problem)
    local swapped = land.checks_problem({ pass }, STATE, { "dev test", "dev lint" })
    testing.ok(swapped:find("checks rows changed", 1, true), swapped)
end)

testing.test("an old check record is refused with a rerun sentence", function()
    local old = {
        body = "dev-check: commit=" .. COMMIT .. " change=chg mode=run\n1 pass 8cb600 dev lint",
    }
    local problem = land.checks_problem({ old }, STATE, { "dev lint" })
    testing.ok(problem:find("could not be read", 1, true), problem)
    testing.ok(problem:find("Run `dev board check` again.", 1, true), problem)
end)

testing.test("carry reads a short check record as the commit's own and does not carry", function()
    local pass = checked(COMMIT, check.Mode.RUN, { "pass 8cb600 dev lint" })
    local opts = {
        root = "/nonexistent",
        comments = { pass, reviewed("code", COMMIT), reviewed("style", COMMIT) },
        state = STATE,
        rows = { "dev lint" },
    }
    testing.eq(check.parse(pass.body).commit, COMMIT)
    testing.eq({ land.carry(opts) }, {})
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
    testing.ok(missing[1]:find("No style review", 1, true), missing[1])
    testing.eq(#land.missing_reviews({}, STATE), 2)
    testing.eq(
        #land.missing_reviews(
            { reviewed("code", COMMIT), reviewed("style", COMMIT) },
            { commit = COMMIT, change = "other" }
        ),
        2
    )
end)

local function judged(kind, commit, opts)
    return {
        body = review.record(
            kind,
            opts.by,
            { commit = commit, change = "chg" },
            opts.verdict,
            opts.of
        ),
    }
end

testing.test("refused_reviews names the reviewer whose latest verdict is needs-work", function()
    local clean = judged("code", COMMIT, { by = "r1", verdict = "clean" })
    testing.eq(land.refused_reviews({ clean }, STATE), {})
    local minor = judged("style", COMMIT, { by = "r2", verdict = "minor" })
    testing.eq(land.refused_reviews({ minor }, STATE), {})
    testing.eq(land.refused_reviews({ reviewed("code", COMMIT) }, STATE), {})
    local style_needs = judged("style", COMMIT, { by = "r2", verdict = "needs-work" })
    local refused = land.refused_reviews({ style_needs }, STATE)
    testing.eq(#refused, 1)
    testing.ok(refused[1]:find("style review by r2", 1, true), refused[1])
    testing.ok(refused[1]:find("needs-work", 1, true), refused[1])
    local recheck = judged("recheck", COMMIT, { by = "r3", verdict = "needs-work", of = "code" })
    refused = land.refused_reviews({ recheck }, STATE)
    testing.ok(refused[1]:find("recheck review by r3", 1, true), refused[1])
    local code_needs = judged("code", COMMIT, { by = "r1", verdict = "needs-work" })
    local code_clean = judged("code", COMMIT, { by = "r4", verdict = "clean" })
    testing.eq(land.refused_reviews({ code_needs, code_clean }, STATE), {})
    local other = judged("code", OTHER, { by = "r1", verdict = "needs-work" })
    testing.eq(land.refused_reviews({ other }, STATE), {})
end)

testing.test("a review of an earlier commit needs a recheck at the landing commit", function()
    local old = { reviewed("code", OTHER), reviewed("style", OTHER) }
    local missing = land.missing_reviews(old, STATE)
    testing.eq(#missing, 2)
    testing.ok(missing[1]:find("earlier commit", 1, true), missing[1])
    old[#old + 1] = reviewed("recheck", OTHER, "code")
    testing.eq(#land.missing_reviews(old, STATE), 2)
    old[#old + 1] = reviewed("recheck", COMMIT, "code")
    old[#old + 1] = reviewed("recheck", COMMIT, "style")
    testing.eq(land.missing_reviews(old, STATE), {})
end)

testing.test("missing_reviews counts a recheck only for the kind it names", function()
    local old = { reviewed("code", OTHER), reviewed("style", OTHER) }
    old[#old + 1] = reviewed("recheck", COMMIT, "code")
    local missing = land.missing_reviews(old, STATE)
    testing.eq(#missing, 1)
    testing.ok(missing[1]:find("The style review is of an earlier commit", 1, true), missing[1])
    testing.ok(missing[1]:find("--kind recheck --of style", 1, true), missing[1])
    local bare = { reviewed("code", OTHER), reviewed("style", OTHER), reviewed("recheck", COMMIT) }
    testing.eq(#land.missing_reviews(bare, STATE), 2)
    local lifted = { judged("recheck", COMMIT, { by = "r", verdict = "needs-work", of = "style" }) }
    lifted[#lifted + 1] = judged("recheck", COMMIT, { by = "r", verdict = "clean", of = "code" })
    local refused = land.refused_reviews(lifted, STATE)
    testing.eq(#refused, 1)
    testing.ok(refused[1]:find("recheck review by r", 1, true), refused[1])
end)

testing.test("checks_problem counts only the newest passing run at the commit", function()
    local rows = { "dev lint", "dev test" }
    local pass = checked(COMMIT, check.Mode.RUN, { "pass - dev lint", "pass - dev test" })
    testing.eq(land.checks_problem({ pass }, STATE, rows), nil)
    testing.ok(
        land.checks_problem({ pass }, STATE, {}):find("The card has no checks rows", 1, true)
    )
    testing.ok(land.checks_problem({}, STATE, rows):find("No run of `dev board check`", 1, true))
    testing.ok(
        land.checks_problem(
            { checked(OTHER, check.Mode.RUN, { "pass - a", "pass - b" }) },
            STATE,
            rows
        )
            :find("No run of `dev board check`", 1, true)
    )
    local expect = checked(COMMIT, check.Mode.EXPECT_FAIL, { "fail - dev lint", "fail - dev test" })
    testing.ok(land.checks_problem({ expect }, STATE, rows):find("expect-fail", 1, true))
    local failed = checked(COMMIT, check.Mode.RUN, { "pass - dev lint", "fail - dev test" })
    testing.ok(
        land.checks_problem({ pass, failed }, STATE, rows)
            :find("Row 2, `dev test`, ended with fail.", 1, true)
    )
    testing.eq(land.checks_problem({ failed, pass }, STATE, rows), nil)
    testing.ok(land.checks_problem({ pass }, STATE, { "dev lint" }):find("has 2 rows", 1, true))
    testing.ok(
        land.checks_problem({ pass }, STATE, { "dev lint", "dev x" })
            :find("checks rows changed", 1, true)
    )
    testing.ok(
        land.checks_problem(
            { checked(COMMIT, check.Mode.RUN, { "timeout - dev lint" }) },
            STATE,
            { "dev lint" }
        )
    )
end)

testing.test("checks_problem says a record it cannot read is unreadable, not missing", function()
    local rows = { "dev lint", "dev test" }
    local unreadable =
        { body = checked(COMMIT, check.Mode.RUN, { "pass dev lint", "pass dev test" }).body }
    local problem = land.checks_problem({ unreadable }, STATE, rows)
    testing.ok(problem:find("could not be read", 1, true), problem)
    testing.ok(problem:find(land.short(COMMIT), 1, true), problem)
    testing.ok(problem:find("Run `dev board check` again.", 1, true), problem)
    testing.eq(check.unreadable(unreadable.body), COMMIT)
    local other = checked(OTHER, check.Mode.RUN, { "pass dev lint", "pass dev test" })
    testing.ok(
        land.checks_problem({ other }, STATE, rows):find("No run of `dev board check`", 1, true)
    )
    local pass = checked(COMMIT, check.Mode.RUN, { "pass - dev lint", "pass - dev test" })
    testing.eq(land.checks_problem({ unreadable, pass }, STATE, rows), nil)
    testing.ok(
        land.checks_problem({ pass, unreadable }, STATE, rows):find("could not be read", 1, true)
    )
    testing.eq(check.unreadable(pass.body), nil)
    testing.eq(check.unreadable("a note"), nil)
end)

testing.test("an unreadable expect-fail record never refuses a landing", function()
    local rows = { "dev lint", "dev test" }
    local pass = checked(COMMIT, check.Mode.RUN, { "pass - dev lint", "pass - dev test" })
    local skipped = checked(COMMIT, check.Mode.EXPECT_FAIL, { "fail dev lint", "fail dev test" })
    testing.eq(check.unreadable(skipped.body), COMMIT)
    testing.eq(select(2, check.unreadable(skipped.body)), check.Mode.EXPECT_FAIL)
    testing.eq(land.checks_problem({ pass, skipped }, STATE, rows), nil)
    testing.eq(land.checks_problem({ skipped, pass }, STATE, rows), nil)
    local unreadable = checked(COMMIT, check.Mode.RUN, { "pass dev lint", "pass dev test" })
    testing.ok(
        land.checks_problem({ pass, unreadable }, STATE, rows):find("could not be read", 1, true)
    )
    testing.ok(
        land.checks_problem({ skipped }, STATE, rows):find("No run of `dev board check`", 1, true)
    )
end)

local function at_root(project, root)
    return { root = root, home = project.home, log = project.log, bare = project.bare }
end

local function dev(project, args, extra)
    local env = {
        HOME = project.home,
        XDG_STATE_HOME = project.home .. "/state",
        JJ_USER = "t",
        JJ_EMAIL = "t@example.com",
        DEV_AGENT = "dotfiles/lander",
        LAND_LOG = project.log,
        LAND_MSG = "stub land",
        REAL_JJ = dev_os.which("jj"),
    }
    local cwd
    for name, value in pairs(extra or {}) do
        if name == "cwd" then
            cwd = value
        else
            env[name] = value
        end
    end
    return support.dev(project.root, args, { env = env, cwd = cwd })
end

local function board_card(doc, id)
    for _, card in ipairs(doc.cards) do
        if id then
            if card.id:sub(1, #id) == id then
                return card
            end
        elseif card.name ~= turn.NAME then
            return card
        end
    end
    if id then
        error("no card starts with " .. id, 2)
    end
end

local function board_doc(home)
    local text = assert(fs.read(support.board_file(home, "mine")), "read failed")
    return assert(json.decode(text), "decode failed")
end

local function read_card(home, id)
    local doc = board_doc(home)
    return doc, board_card(doc, id)
end

local function comments(home, id)
    local _, card = read_card(home, id)
    return card.comments or {}
end

local function claim_of(home, id)
    local _, card = read_card(home, id)
    return card.claim
end

local function landed_calls(log)
    return fs.read(log) or ""
end

local function column_of(home, id)
    local doc, card = read_card(home, id)
    for _, column in ipairs(doc.columns) do
        if column.id == card.column_id then
            return column.name
        end
    end
    return "?"
end

local function rename_workspace(root, name)
    local argv = { "jj", "-R", root, "workspace", "rename", name }
    must(dev_os.run(argv, { stdout = "null", stderr = "null", env = IDENT }))
end

local function new_card(project)
    must(dev(project, { "board", "init" }))
    local out = dev(project, {
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
        "It works",
    })
    local id = assert(out:match("added (%x+)"), out)
    must(dev(project, { "board", "checks", id, "true" }))
    if fs.is_dir(project.root .. "/.jj") then
        rename_workspace(project.root, id)
    end
    return id
end

local function record_review(project, id, opts)
    opts = opts or {}
    local kind = opts.kind or "code"
    local by = opts.by or "rev"
    local args = {
        "board",
        "review",
        id,
        "--kind",
        kind,
        "--by",
        by,
        "--rev",
        opts.rev or "@",
        "--verdict",
        opts.verdict or "clean",
    }
    if opts.of then
        args[#args + 1] = "--of"
        args[#args + 1] = opts.of
    else
        support.with_of(kind, args)
    end
    return (opts.run or dev)(project, args, { DEV_AGENT = opts.env or by })
end

local function approve_reviews(project, id)
    for _, kind in ipairs({ "code", "style" }) do
        must(record_review(project, id, { kind = kind }))
    end
end

local function to_review(project, id, extra)
    local env = { DEV_AGENT = "dotfiles/builder" }
    for name, value in pairs(extra or {}) do
        env[name] = value
    end
    must(support.to_review(function(args)
        return dev(project, args, env)
    end, id))
end

local function to_verify(project, id, extra)
    to_review(project, id, extra)
    must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }, extra))
    must(dev(project, { "board", "outcome", id, "--untick", "1" }, extra))
end

local function approve(project, id)
    approve_reviews(project, id)
    must(dev(project, { "board", "check", id }))
    must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
end

local function verified_card(project)
    local id = new_card(project)
    to_verify(project, id)
    approve(project, id)
    return id
end

local function refused(project, id, wanted, opts)
    local out, code = dev(project, { "board", "land", id }, opts)
    testing.eq(code, 1, out)
    for _, text in ipairs(wanted) do
        testing.ok(out:find(text, 1, true), text .. "\n" .. out)
    end
    testing.eq(landed_calls(project.log), "")
    testing.eq(out:find("landed " .. id, 1, true), nil)
    testing.ok(column_of(project.home) ~= support.COLUMN_NAME.DONE, column_of(project.home))
    return out
end

testing.test("land refuses a caller with no name", function()
    local project = setup()
    local id = new_card(project)
    local out, code = dev(project, { "board", "land", id }, { DEV_AGENT = "" })
    testing.eq(code, 2, out)
    testing.ok(out:find("Needs DEV_AGENT", 1, true), out)
    out, code = dev(project, { "board", "land" })
    testing.eq(code, 2, out)
    testing.ok(out:find("Needs a card.", 1, true), out)
end)

testing.test("land refuses an agent name that is not one word", function()
    local project = setup()
    local id = new_card(project)
    local out, code = dev(project, { "board", "land", id }, { DEV_AGENT = "two words" })
    testing.eq(code, 2, out)
    testing.ok(out:find("An agent name is one word of letters, digits and . - _ /", 1, true), out)
    testing.eq(landed_calls(project.log), "")
end)

local CARD_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
local CARD_PREFIX = CARD_ID:sub(1, 8)

local function fake_backend(root, card)
    local backend = { root = root, column_map = {}, notes = {} }
    if root and fs.is_dir(root .. "/.jj") then
        rename_workspace(root, CARD_PREFIX)
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
    function backend:card(id)
        for _, listed in ipairs(self:cards()) do
            if listed.id == id then
                return listed
            end
        end
        return nil, "no card " .. id
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

local function land_word(backend, word)
    local previous = os.getenv("DEV_AGENT") or ""
    ffi.C.setenv("DEV_AGENT", "dotfiles/lander", 1)
    local ok, result = pcall(cmd_board.run, "land", { word }, backend)
    ffi.C.setenv("DEV_AGENT", previous, 1)
    assert(ok, result)
    return result
end

local function land_as_lander(backend)
    return land_word(backend, CARD_PREFIX)
end

testing.test("land refuses a card id that is too short or not hex", function()
    local backend = fake_backend(nil)
    for _, word in ipairs({ "aaa", "zzzzzzzz" }) do
        local result = land_word(backend, word)
        testing.eq(result.code, 1)
        testing.eq(
            result.message,
            "A card id needs at least " .. board.MIN_PREFIX .. " hex characters: " .. word .. "."
        )
    end
    testing.eq(backend.notes, {})
end)

testing.test("land refuses a card id that no card starts with", function()
    local backend = fake_backend(nil)
    local result = land_word(backend, "bbbbbbbb")
    testing.eq(result.code, 1)
    testing.eq(result.message, "No card starts with bbbbbbbb.")
    testing.eq(backend.notes, {})
end)

testing.test("land refuses a card id that more than one card starts with", function()
    local backend = fake_backend(nil)
    function backend:cards()
        return {
            { id = "cccccccc-1111-4ccc-8ccc-cccccccccccc", name = "One" },
            { id = "cccccccc-2222-4ccc-8ccc-cccccccccccc", name = "Two" },
        }
    end
    local result = land_word(backend, "cccccccc")
    testing.eq(result.code, 1)
    testing.eq(result.message, "More than one card starts with cccccccc. Give more characters.")
    testing.eq(backend.notes, {})
end)

testing.test("land on a board with In Review and no Verify names dev board init", function()
    local backend = fake_backend("/nonexistent")
    backend.rows = {
        { name = support.COLUMN_NAME.IN_REVIEW, is_done = false },
        { name = support.COLUMN_NAME.DONE, is_done = true },
    }
    local result = land_as_lander(backend)
    testing.eq(result.code, 1)
    testing.ok(
        result.message:find("Run `dev board init` to move the board to the stage columns.", 1, true),
        result.message
    )
    testing.eq(backend.notes, {})
end)

testing.test("land refuses a board with no project root", function()
    local backend = fake_backend(nil)
    local result = land_as_lander(backend)
    testing.eq(result.code, 1)
    testing.eq(result.message, "`dev board land` needs the project's root.")
    testing.eq(backend.notes, {})
end)

if has_jj then
    local function jj(root, ...)
        local argv = { "jj", "--no-pager", "--color", "never", "-R", root, ... }
        local out, code = dev_os.capture(argv, { stderr = "null", env = IDENT })
        assert(code == 0, out)
        return out
    end

    local function push_trunk(project, files)
        local other = support.tempdir() .. "/clone"
        must(
            dev_os.run(
                { "git", "clone", "-q", "--branch", "master", project.bare, other },
                { stdout = "null", stderr = "null" }
            )
        )
        for path, body in pairs(files or {}) do
            assert(fs.mkdir(fs.dirname(other .. "/" .. path), { parents = true }), "mkdir failed")
            assert(fs.write(other .. "/" .. path, body), "write failed")
            support.git(other, "add", path)
        end
        support.git(other, "commit", "-q", "--allow-empty", "-m", "moved")
        support.git(other, "push", "-q", "origin", "HEAD:refs/heads/master")
    end

    local function trunk_moves(project, files)
        push_trunk(project, files)
        jj(project.root, "git", "fetch", "--remote", "origin")
    end

    local function jj_project(extra)
        local project = setup(extra)
        assert(fs.write(project.root .. "/bin/jj", LAND_STUB), "write failed")
        must(dev_os.run({ "chmod", "755", project.root .. "/bin/jj" }))
        local bare = support.tempdir()
        project.bare = bare
        must(
            dev_os.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, { stdout = "null" })
        )
        must(
            dev_os.run(
                { "jj", "git", "init", project.root },
                { stdout = "null", stderr = "null", env = IDENT }
            )
        )
        jj(project.root, "git", "remote", "add", "origin", bare)
        assert(fs.mkdir(project.root .. "/lib", { parents = true }), "mkdir failed")
        assert(fs.write(project.root .. "/lib/seed.txt", "seed\n"), "write failed")
        jj(project.root, "commit", "-m", "base")
        jj(project.root, "bookmark", "create", "master", "-r", "@-")
        jj(project.root, "git", "push", "--remote", "origin", "--bookmark", "master")
        assert(fs.write(project.root .. "/work.txt", "one\n"), "write failed")
        jj(project.root, "describe", "-m", "feat: work")
        return project
    end

    local function head(root)
        return jj(root, "log", "-r", "@", "--no-graph", "-T", "commit_id")
    end

    local function board_at(home)
        local previous = os.getenv("XDG_STATE_HOME") or ""
        ffi.C.setenv("XDG_STATE_HOME", home .. "/state", 1)
        local backend = localboard.new({
            name = "mine",
            path = support.board_file(home, "mine"),
            private = true,
        })
        backend.stages = { icebox = support.COLUMN_NAME.ICEBOX }
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
        local project = jj_project()
        local id = verified_card(project)
        jj(project.root, "workspace", "rename", "elsewhere")
        refused(project, id, { "elsewhere", "dev ws new " .. id })
    end)

    testing.test("land refuses when jj cannot read the workspace list", function()
        local project = jj_project()
        local id = verified_card(project)
        local before = #comments(project.home, id)
        refused(
            project,
            id,
            { "The `jj` command could not read the workspace of" },
            { LOG_FAIL_AT = "workspace" }
        )
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)
        testing.eq(#comments(project.home, id), before)
    end)

    testing.test(
        "workspace check passes when another workspace shares the working-copy commit",
        function()
            local project = jj_project()
            local id = new_card(project)
            jj(project.root, "workspace", "rename", id)
            local base = assert(fs.realpath(support.tempdir()))
            local path = base .. "/other"
            jj(project.root, "workspace", "add", "--name", "other", path)
            local work = head(project.root)
            jj(path, "edit", work)
            testing.eq(head(path), work)
            must(dev(project, { "board", "turn", id }))
            local out, code = dev(project, { "board", "turn", id, "--release" })
            testing.eq(code, 0, out)
        end
    )

    testing.test("turn refuses outside the workspace named for the card", function()
        local project = jj_project()
        local id = new_card(project)
        must(dev(project, { "board", "turn", id }))
        jj(project.root, "workspace", "rename", "elsewhere")
        local out, code = dev(project, { "board", "turn", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("elsewhere", 1, true), out)
        testing.ok(out:find("dev ws new " .. id, 1, true), out)
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")
        out, code = dev(project, { "board", "turn", id, "--release" })
        testing.eq(code, 0, out)
        testing.ok(out:find("Gave back the landing turn held for " .. id .. ".", 1, true), out)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test(
        "a card that meets every condition lands, gets a done note and reaches Done",
        function()
            local project = jj_project()
            local id = verified_card(project)
            local commit = head(project.root)
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            testing.ok(
                out:find(
                    "landed " .. id .. " at commit " .. commit:sub(1, 12) .. " and moved it to Done",
                    1,
                    true
                ),
                out
            )
            testing.ok(
                landed_calls(project.log):find("land --yes", 1, true),
                landed_calls(project.log)
            )
            local list = comments(project.home)
            local last = list[#list]
            testing.eq(last.kind, KIND_DONE)
            testing.ok(last.body:find("Landed commit " .. commit:sub(1, 12), 1, true), last.body)
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        end
    )

    local function second_card(project)
        local out = dev(project, {
            "board",
            "add",
            "Second",
            "--problem",
            "x",
            "--change",
            "x",
            "--out-of-scope",
            "y",
            "--size",
            "1",
            "--done-when",
            "It works",
        })
        local id = assert(out:match("added (%x+)"), out)
        must(dev(project, { "board", "checks", id, "true" }))
        return id
    end

    testing.test("land with two cards on one change moves both to Done with a note", function()
        local project = jj_project()
        local first = verified_card(project)
        local second = second_card(project)
        to_verify(project, second)
        jj(project.root, "workspace", "rename", second)
        approve(project, second)
        jj(project.root, "workspace", "rename", first)
        local commit = head(project.root)
        local out, code = dev(
            project,
            { "board", "land", first, second },
            { LAND_TRUNK = LAND_TRUNK_KEEP }
        )
        testing.eq(code, 0, out)
        for _, id in ipairs({ first, second }) do
            local list = comments(project.home, id)
            testing.eq(list[#list].kind, KIND_DONE)
            testing.ok(list[#list].body:find("Landed commit " .. commit:sub(1, 12), 1, true))
            testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
        end
    end)

    testing.test("land with a second card that fails its rules lands nothing", function()
        local project = jj_project()
        local first = verified_card(project)
        local second = second_card(project)
        to_verify(project, second)
        local out, code = dev(
            project,
            { "board", "land", first, second },
            { LAND_TRUNK = LAND_TRUNK_KEEP }
        )
        testing.eq(code, 1, out)
        testing.ok(out:find("cannot land", 1, true), out)
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, first), board.DEFAULT_NAMES.verify)
        testing.eq(column_of(project.home, second), board.DEFAULT_NAMES.verify)
    end)

    testing.test("land names the same card twice and lands nothing", function()
        local project = jj_project()
        local id = verified_card(project)
        local out, code = dev(project, { "board", "land", id, id })
        testing.eq(code, 2, out)
        testing.ok(out:find("twice", 1, true), out)
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)
    end)

    testing.test(
        "land runs jj land with DEV_BOARD_LAND=1 so the jj guard lets it through",
        function()
            local project = jj_project()
            local id = verified_card(project)
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            testing.ok(
                landed_calls(project.log):find("land --yes", 1, true),
                landed_calls(project.log)
            )
            testing.ok(
                landed_calls(project.log):find("DEV_BOARD_LAND=1", 1, true),
                landed_calls(project.log)
            )
        end
    )

    testing.test("an old-shape claimant still checks and lands its claimed card", function()
        local project = jj_project()
        local id = verified_card(project)
        local old = "dotfiles/implementer/38f0e013/1"
        local backend, restore = board_at(project.home)
        local cards = assert(backend:cards())
        for _, card in ipairs(cards) do
            if card.id:sub(1, #id) == id then
                assert(backend:claim(card.id, old, { ttl = 3600, lease = true }))
            end
        end
        restore()
        local as_old = { DEV_AGENT = old, LAND_TRUNK = LAND_TRUNK_KEEP }
        local out, code = dev(project, { "board", "check", id }, as_old)
        testing.eq(code, 0, out)
        out, code = dev(project, { "board", "land", id }, as_old)
        testing.eq(code, 0, out)
        testing.ok(out:find("landed " .. id, 1, true), out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("land refuses a card in Review and names Verify", function()
        local project = jj_project()
        local id = new_card(project)
        must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        to_review(project, id)
        approve_reviews(project, id)
        must(dev(project, { "board", "check", id }))
        refused(project, id, { "It is in Review, and only a card in Verify lands." })
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.REVIEW)
    end)

    testing.test("land moves a verified card to Release when the project deploys", function()
        local project = jj_project("\n[board.land]\ndeploys = true\n")
        local id = verified_card(project)
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.ok(out:find("and moved it to Release", 1, true), out)
        local list = comments(project.home, id)
        testing.eq(list[#list].kind, KIND_DONE)
        testing.ok(
            list[#list].body:find("waits in Release for the deploy", 1, true),
            list[#list].body
        )
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.RELEASE)
    end)

    testing.test(
        "land moves a card touching only unlisted paths to Done when it deploys",
        function()
            local project =
                jj_project('\n[board.land]\ndeploys = true\ndeployed = ["lib/**", "bin/*"]\n')
            local id = verified_card(project)
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            testing.ok(out:find("and moved it to Done", 1, true), out)
            local list = comments(project.home, id)
            testing.eq(list[#list].body:find("waits in Release", 1, true), nil)
            testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
        end
    )

    testing.test("land moves a card touching a listed path to Release", function()
        local project =
            jj_project('\n[board.land]\ndeploys = true\ndeployed = ["lib/**", "*.txt"]\n')
        local id = verified_card(project)
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.ok(out:find("and moved it to Release", 1, true), out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("land moves a verified card to Done when the project does not deploy", function()
        local project = jj_project()
        local id = verified_card(project)
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.ok(out:find("and moved it to Done", 1, true), out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("a card in Release moves to Done once every outcome is ticked", function()
        local project = jj_project()
        local id = verified_card(project)
        support.place(support.board_file(project.home, "mine"), id, support.COLUMN_NAME.RELEASE)
        must(dev(project, { "board", "outcome", id, "--untick", "1" }))
        local out, code = dev(project, { "board", "move", id, support.Column.DONE })
        testing.eq(code, 1, out)
        testing.ok(out:find("1 of 1 outcomes are unticked", 1, true), out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.RELEASE)
        must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        must(dev(project, { "board", "move", id, support.Column.DONE }))
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("a land that rewrites the commit notes the commit on trunk", function()
        local project = jj_project()
        local id = verified_card(project)
        local before = head(project.root)
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_REWRITE })
        testing.eq(code, 0, out)
        local after =
            jj(project.root, "log", "-r", "master@origin", "--no-graph", "-T", "commit_id")
        testing.ok(before ~= after, "the stub must rewrite the commit")
        testing.ok(out:find("at commit " .. after:sub(1, 12) .. " and moved", 1, true), out)
        testing.eq(out:find(before:sub(1, 12), 1, true), nil, out)
        local list = comments(project.home)
        local last = list[#list]
        testing.ok(last.body:find("Landed commit " .. after:sub(1, 12), 1, true), last.body)
        testing.eq(last.body:find(before:sub(1, 12), 1, true), nil, last.body)
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test(
        "a land whose trunk cannot be read notes the earlier commit and still reaches Done",
        function()
            local project = jj_project()
            local id = verified_card(project)
            local commit = head(project.root)
            local out, code = dev(project, { "board", "land", id })
            testing.eq(code, 0, out)
            testing.ok(out:find("at commit " .. commit:sub(1, 12), 1, true), out)
            testing.ok(out:find("trunk could not be read", 1, true), out)
            local list = comments(project.home)
            local last = list[#list]
            testing.eq(last.kind, KIND_DONE)
            testing.ok(last.body:find(commit:sub(1, 12), 1, true), last.body)
            testing.ok(last.body:find("may differ", 1, true), last.body)
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test(
        "land verdict refuses needs-work, names the reviewer, and accepts minor",
        function()
            local project = jj_project()
            local id = verified_card(project)
            local function judge(by, verdict)
                must(record_review(project, id, { by = by, verdict = verdict }))
            end
            judge("picky", "needs-work")
            refused(project, id, { "code review by picky", "needs-work" })
            judge("kind", "minor")
            local out, code = dev(project, { "board", "land", id })
            testing.eq(code, 0, out)
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test(
        "land refuses a needs-work style review and a needs-work recheck of either kind",
        function()
            local cases = {
                { kind = "style", by = "style-picky", label = "style review" },
                {
                    kind = "recheck",
                    of = "code",
                    by = "code-recheck-picky",
                    label = "recheck review",
                },
                {
                    kind = "recheck",
                    of = "style",
                    by = "style-recheck-picky",
                    label = "recheck review",
                },
            }
            for _, case in ipairs(cases) do
                local project = jj_project()
                local id = verified_card(project)
                must(
                    record_review(
                        project,
                        id,
                        { kind = case.kind, of = case.of, by = case.by, verdict = "needs-work" }
                    )
                )
                refused(project, id, { case.label .. " by " .. case.by, "needs-work" })
            end
        end
    )

    testing.test("a failed jj land leaves the card in Verify and exits non-zero", function()
        local project = jj_project()
        local id = verified_card(project)
        local before = #comments(project.home)
        local out, code = dev(
            project,
            { "board", "land", id },
            { LAND_CODE = "1", LAND_MSG = "boom" }
        )
        testing.eq(code, 1, out)
        testing.ok(out:find("stays in Verify", 1, true) and out:find("boom", 1, true), out)
        testing.ok(landed_calls(project.log):find("land", 1, true))
        testing.eq(#comments(project.home), before)
        testing.eq(column_of(project.home), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("land names every missing condition and runs nothing", function()
        local project = jj_project()
        local id = new_card(project)
        refused(project, id, {
            "It is in Backlog, and only a card in Verify lands.",
            "1 of 1 outcomes are unticked",
            "No code review of change",
            "No style review of change",
            "No run of `dev board check`",
        })
    end)

    testing.test("land refuses another claimant's card", function()
        local project = jj_project()
        local id = new_card(project)
        must(dev(project, { "board", "take", id, "--as", "dotfiles/builder" }))
        refused(project, id, { "claimed by dotfiles/builder", "not dotfiles/lander" })
        must(dev(project, { "board", "release", id }))
    end)

    testing.test("land succeeds after a take --from handoff", function()
        local project = jj_project()
        local id = verified_card(project)
        must(dev(project, { "board", "take", id, "--as", "dotfiles/builder" }))
        refused(project, id, { "claimed by dotfiles/builder", "not dotfiles/lander" })
        must(dev(project, { "board", "take", id, "--from", "dotfiles/builder" }))
        testing.eq(claim_of(project.home, id).claimant, "dotfiles/lander")
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.ok(out:find("landed " .. id, 1, true), out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("a claimed card's review comes from another name, never its claimant", function()
        local project = jj_project()
        local id = new_card(project)
        must(dev(project, { "board", "take", id, "--as", "dotfiles/builder" }))
        local before = #comments(project.home, id)
        for _, kind in ipairs({ "code", "style", "recheck" }) do
            local out, code = record_review(project, id, { kind = kind, by = "dotfiles/builder" })
            testing.eq(code, 1, out)
            testing.ok(
                out:find("A reviewer other than dotfiles/builder must record it", 1, true),
                out
            )
        end
        for _, kind in ipairs({ "code", "style", "recheck" }) do
            local out, code = record_review(project, id, { kind = kind, env = "dotfiles/builder" })
            testing.eq(code, 1, out)
            testing.ok(out:find("dotfiles/builder cannot record a review by rev", 1, true), out)
        end
        testing.eq(#comments(project.home, id), before)
        must(record_review(project, id))
        local list = comments(project.home, id)
        testing.eq(#list, before + 1)
        testing.ok(list[#list].body:find("dev-review: kind=code by=rev", 1, true), list[#list].body)
    end)

    testing.test("land refuses a working copy that is empty or undescribed", function()
        local project = jj_project()
        local id = verified_card(project)
        jj(project.root, "describe", "-m", "")
        refused(project, id, { "has no description" })
        jj(project.root, "describe", "-m", "feat: work")
        jj(project.root, "new", "-m", "next")
        refused(project, id, { "is empty" })
    end)

    testing.test("a check run at an older commit or with a failing row does not count", function()
        local project = jj_project()
        local id = verified_card(project)
        assert(fs.write(project.root .. "/work.txt", "two\n"), "write failed")
        refused(project, id, { "No run of `dev board check` is recorded at commit" })
        must(dev(project, { "board", "checks", id, "false" }))
        local _, code = dev(project, { "board", "check", id })
        testing.eq(code, 1)
        refused(project, id, {
            "earlier commit than",
            "did not pass every row. Row 1, `false`, ended with fail.",
        })
    end)

    testing.test("an expect-fail record never counts as a passing check", function()
        local project = jj_project()
        local id = new_card(project)
        must(dev(project, { "board", "checks", id, "false" }))
        to_verify(project, id)
        approve_reviews(project, id)
        must(dev(project, { "board", "check", id, "--expect-fail" }))
        must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        refused(project, id, { "No run of `dev board check` is recorded", "expect-fail" })
    end)

    testing.test("a change after the reviews needs a recheck at the landing commit", function()
        local project = jj_project()
        local id = verified_card(project)
        assert(fs.write(project.root .. "/work.txt", "two\n"), "write failed")
        must(dev(project, { "board", "check", id }))
        refused(project, id, { "earlier commit than", "dev board review --kind recheck" })
        for _, of in ipairs({ "code", "style" }) do
            must(record_review(project, id, { kind = "recheck", of = of }))
            local out, code = dev(project, { "board", "land", id })
            testing.eq(code == 0, of == "style", out)
        end
    end)

    testing.test("land rebases onto trunk under the turn when trunk has moved", function()
        local project = jj_project()
        local id = verified_card(project)
        push_trunk(project)
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(out:find("Trunk has moved", 1, true), nil, out)
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test(
        "land names the holder and since when while another card holds the turn",
        function()
            local project = jj_project()
            local id = verified_card(project)
            local held = hold_turn(project.home, "other", "cccc3333")
            local out, code = dev(project, { "board", "land", id, "--wait", "0" })
            testing.eq(code, 1, out)
            testing.ok(out:find("held by other since 20", 1, true), out)
            testing.eq(column_of(project.home), support.COLUMN_NAME.VERIFY)
            _, code = dev(project, { "board", "land", id, "--wait", "x" })
            testing.eq(code, 2)
            _, code = dev(project, { "board", "land", id, "--wait", "999999999" })
            testing.eq(code, 2)
            release_turn(project.home, held)
            out, code = dev(
                project,
                { "board", "land", id, "--wait", "0" },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
            testing.eq(turn_holder(project.home), nil)
        end
    )

    testing.test("land leaves a change on an unlanded parent where it is", function()
        local project = jj_project()
        jj(project.root, "new", "-m", "feat: child")
        assert(fs.write(project.root .. "/child.txt", "two\n"), "write failed")
        local id = verified_card(project)
        push_trunk(project)
        local before = head(project.root)
        refused(project, id, { "sits on an unlanded parent" })
        testing.eq(head(project.root), before)
        testing.eq(turn_holder(project.home), nil)
    end)

    local function stack_on_parent(project, parent)
        jj(project.root, "new", "master", unpack(parent.args))
        if parent.body then
            assert(fs.write(project.root .. "/mid.txt", parent.body), "write failed")
        end
        jj(project.root, "new", "-m", "feat: child")
        assert(fs.write(project.root .. "/child.txt", "two\n"), "write failed")
    end

    ---The parent spec for an empty undescribed commit
    local EMPTY_PARENT = { args = {} }

    testing.test(
        "land accepts a change whose parent is an empty undescribed commit on trunk",
        function()
            local project = jj_project()
            stack_on_parent(project, EMPTY_PARENT)
            local id = verified_card(project)
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
            testing.eq(turn_holder(project.home), nil)
        end
    )

    testing.test(
        "land carries a check across the rebase past an empty undescribed parent",
        function()
            local project = jj_project()
            stack_on_parent(project, EMPTY_PARENT)
            local id = verified_card(project)
            local before = head(project.root)
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            testing.ok(head(project.root) ~= before, "the rebase must rewrite the commit")
            local list = comments(project.home)
            local last = list[#list]
            testing.eq(last.kind, KIND_DONE)
            testing.ok(
                last.body:find("carried over from commit " .. before:sub(1, 12), 1, true),
                last.body
            )
        end
    )

    testing.test("land abandons the empty undescribed parent it rebases past", function()
        local project = jj_project()
        stack_on_parent(project, EMPTY_PARENT)
        local id = verified_card(project)
        local parent = jj(project.root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
        local alive = "::visible_heads() & " .. parent
        testing.eq(jj(project.root, "log", "-r", alive, "--no-graph", "-T", "commit_id"), parent)
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(jj(project.root, "log", "-r", alive, "--no-graph", "-T", "commit_id"), "")
    end)

    testing.test(
        "land refuses a change whose parent is an empty commit with a description",
        function()
            local project = jj_project()
            stack_on_parent(project, { args = { "-m", "docs: keep this" } })
            local id = verified_card(project)
            local before = head(project.root)
            refused(project, id, { "sits on an unlanded parent" })
            testing.eq(head(project.root), before)
            testing.eq(turn_holder(project.home), nil)
        end
    )

    testing.test("land refuses a change whose parent is a non-empty undescribed commit", function()
        local project = jj_project()
        stack_on_parent(project, { args = {}, body = "mid\n" })
        local id = verified_card(project)
        local before = head(project.root)
        refused(project, id, { "sits on an unlanded parent" })
        testing.eq(head(project.root), before)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test("land waits up to the wait and then names the holder", function()
        local project = jj_project()
        local id = verified_card(project)
        local held = hold_turn(project.home, "other", "cccc3333")
        local backend, restore = board_at(project.home)
        backend.root = project.root
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
        testing.eq(assert(turn_holder(project.home)).name, "other")
        release_turn(project.home, held)
    end)

    testing.test("land with no wait refuses at once and names the holder", function()
        local project = jj_project()
        local id = verified_card(project)
        local held = hold_turn(project.home, "other", "cccc3333")
        local backend, restore = board_at(project.home)
        backend.root = project.root
        local nap = dev_os.nap
        local naps = 0
        dev_os.nap = function()
            naps = naps + 1
        end
        local previous = os.getenv("DEV_AGENT") or ""
        ffi.C.setenv("DEV_AGENT", "dotfiles/lander", 1)
        local ok, result = pcall(cmd_board.run, "land", { id }, backend)
        ffi.C.setenv("DEV_AGENT", previous, 1)
        dev_os.nap = nap
        restore()
        assert(ok, result)
        testing.eq(result.code, 1, result.message)
        testing.ok(result.message:find("held by other since", 1, true), result.message)
        testing.eq(naps, 0)
        testing.eq(assert(turn_holder(project.home)).name, "other")
        release_turn(project.home, held)
    end)

    testing.test("land asks for no turn when it refuses", function()
        local project = jj_project()
        local id = new_card(project)
        to_verify(project, id)
        must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("No code review", 1, true), out)
        testing.ok(
            not fs.read(support.board_file(project.home, "mine"))
                :find("dev-turn: holder=dotfiles/lander", 1, true)
        )
        testing.eq(turn_holder(project.home), nil)
    end)

    local function rebase_onto_trunk(root)
        jj(root, "rebase", "-r", "@", "-d", "master")
    end

    local function review_ready(project, row)
        trunk_moves(project, { ["shared.txt"] = SHARED })
        rebase_onto_trunk(project.root)
        assert(fs.write(project.root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nG\n"), "write failed")
        local id = new_card(project)
        if row then
            must(dev(project, { "board", "checks", id, row }))
        end
        to_verify(project, id)
        approve(project, id)
        return id
    end

    local function standalone_ready(project)
        assert(fs.mkdir(project.root .. "/.dev/standalone", { parents = true }), "mkdir failed")
        assert(fs.write(project.root .. "/.dev/standalone/x.sh", "#!/bin/sh\n"), "write failed")
        local id = new_card(project)
        to_verify(project, id)
        return id
    end

    testing.test(
        "land refuses a commit that adds a standalone file without standalone-ok",
        function()
            local project = jj_project()
            local id = standalone_ready(project)
            approve(project, id)
            refused(project, id, {
                "adds .dev/standalone/x.sh, which needs the standalone-ok label",
            })
        end
    )

    testing.test("land refuses a commit that moves a file into .dev/standalone", function()
        local project = jj_project()
        jj(project.root, "describe", "-m", "base2")
        assert(fs.write(project.root .. "/x.sh", "#!/bin/sh\n"), "write failed")
        jj(project.root, "commit", "-m", "base2")
        jj(project.root, "bookmark", "set", "master", "-r", "@-")
        jj(project.root, "git", "push", "--remote", "origin", "--bookmark", "master")
        jj(project.root, "describe", "-m", "feat: move")
        assert(fs.mkdir(project.root .. "/.dev/standalone", { parents = true }), "mkdir failed")
        must(dev_os.run({ "mv", project.root .. "/x.sh", project.root .. "/.dev/standalone/x.sh" }))
        local id = verified_card(project)
        refused(project, id, { "adds .dev/standalone/x.sh" })
    end)

    testing.test(
        "land lands a commit that adds a standalone file when the card has standalone-ok",
        function()
            local project = jj_project()
            local id = standalone_ready(project)
            must(dev(project, { "board", "label", id, "+standalone-ok" }, { DEV_AGENT = "" }))
            approve(project, id)
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            testing.eq(column_of(project.home), board.DEFAULT_NAMES.done)
        end
    )

    local TEMPLATE_DIR = "dotfiles/claude/.claude/skills/style/lint/lua"

    local function template_ready(project, opts)
        assert(fs.mkdir(project.root .. "/" .. TEMPLATE_DIR, { parents = true }), "mkdir failed")
        assert(
            fs.write(project.root .. "/" .. TEMPLATE_DIR .. "/lint.lua", opts.template),
            "write failed"
        )
        assert(fs.mkdir(project.root .. "/.dev", { parents = true }), "mkdir failed")
        if opts.baked then
            assert(fs.write(project.root .. "/.dev/baked.txt", opts.baked), "write failed")
        end
        return verified_card(project)
    end

    local CALLS_EXISTS = 'local fs = require("dev.fs")\nreturn fs.exists("x")\n'

    testing.test(
        "land refuses a template change that calls a dev function the baked list lacks",
        function()
            local project = jj_project()
            local id = template_ready(project, { template = CALLS_EXISTS, baked = "dev.fs\n" })
            refused(project, id, {
                "The lint-set template calls dev.fs.exists, which .dev/baked.txt",
                "have infra rebake the ci images, then land the template change",
            })
        end
    )

    testing.test("land refuses a template change from a subdirectory", function()
        local project = jj_project()
        local id = template_ready(project, { template = CALLS_EXISTS, baked = "dev.fs\n" })
        local subdirectory = project.root .. "/" .. TEMPLATE_DIR
        refused(project, id, {
            "The lint-set template calls dev.fs.exists, which .dev/baked.txt",
            "have infra rebake the ci images, then land the template change",
        }, { cwd = subdirectory })
    end)

    testing.test(
        "land refuses a template change when the dev change is already on trunk",
        function()
            local project = jj_project()
            trunk_moves(project, {
                ["dotfiles/bin/.local/share/dev/lua/dev/fs.lua"] = "return {}\n",
                [".dev/baked.txt"] = "dev.fs\n",
            })
            local id = template_ready(project, { template = CALLS_EXISTS })
            refused(project, id, { "The lint-set template calls dev.fs.exists," })
        end
    )

    testing.test(
        "land refuses a template change that requires a module the baked list lacks",
        function()
            local project = jj_project()
            local id = template_ready(project, { template = CALLS_EXISTS })
            refused(project, id, { "The lint-set template calls dev.fs, dev.fs.exists," })
        end
    )

    testing.test("land lands a template change whose dev calls the baked list holds", function()
        local project = jj_project()
        local id = template_ready(project, {
            template = CALLS_EXISTS,
            baked = "dev.fs\ndev.fs.exists\n",
        })
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(column_of(project.home), board.DEFAULT_NAMES.done)
    end)

    testing.test("land lands a template change that calls no dev function", function()
        local project = jj_project()
        local id = template_ready(project, { template = "return 1\n" })
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(column_of(project.home), board.DEFAULT_NAMES.done)
    end)

    testing.test(
        "land after another lander's turn ends rebases without a trunk-moved refusal",
        function()
            local project = jj_project()
            local id = review_ready(project)
            local held = hold_turn(project.home, "other", "cccc3333")
            local first, first_code = dev(project, { "board", "land", id, "--wait", "0" })
            testing.eq(first_code, 1, first)
            testing.ok(first:find("held by other since", 1, true), first)
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            release_turn(project.home, held)
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            testing.ok(not out:find("Trunk has moved", 1, true), out)
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
            testing.eq(turn_holder(project.home), nil)
        end
    )

    testing.test(
        "land carries the check and reviews over a rebase past unrelated commits",
        function()
            local project = jj_project()
            local id = review_ready(project)
            local before = head(project.root)
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)
            testing.ok(head(project.root) ~= before, "the rebase must rewrite the commit")
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            local list = comments(project.home)
            local last = list[#list]
            testing.eq(last.kind, KIND_DONE)
            testing.ok(
                last.body:find("carried over from commit " .. before:sub(1, 12), 1, true),
                last.body
            )
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test(
        "land carries over a rebase with no interdiff that targets the working copy",
        function()
            local project = jj_project()
            local id = review_ready(project)
            local before = head(project.root)
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP, INTERDIFF_FAIL_AT = "--to @" }
            )
            testing.eq(code, 0, out)
            local list = comments(project.home)
            testing.ok(
                list[#list].body:find("carried over from commit " .. before:sub(1, 12), 1, true),
                list[#list].body
            )
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test("land carries the check and reviews over the rebase it makes itself", function()
        local project = jj_project()
        local id = review_ready(project)
        local before = head(project.root)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        local list = comments(project.home)
        testing.ok(
            list[#list].body:find("carried over from commit " .. before:sub(1, 12), 1, true),
            list[#list].body
        )
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("land refuses when the recheck stretch loses the turn", function()
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        must(dev(project, { "board", "turn", id }))
        local backend, restore = board_at(project.home)
        backend.root = project.root
        local stretch = turn.stretch
        turn.stretch = function()
            return nil, "The turn was lost."
        end
        local previous = os.getenv("DEV_AGENT") or ""
        ffi.C.setenv("DEV_AGENT", "dotfiles/lander", 1)
        local ok, result = pcall(cmd_board.run, "land", { id }, backend)
        ffi.C.setenv("DEV_AGENT", previous, 1)
        turn.stretch = stretch
        restore()
        assert(ok, result)
        testing.eq(result.code, 1, result.message)
        testing.ok(result.message:find("The turn was lost.", 1, true), result.message)
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
        testing.eq(turn_holder(project.home), nil)
    end)

    local CARRY_SCRIPT = [=[
local ctx = ...
local board = require("dev.board")
local scm = require("dev.scm")

local found = assert(board.find(scm.workspace(ctx.root)))
local card = assert(found:find_card(ctx.args[1]))
local ok, why = card:carry_proof()
print("carry: " .. tostring(ok) .. " " .. tostring(why))
]=]

    local function carry_project()
        local project = jj_project()
        assert(fs.write(project.root .. "/.dev/carry.lua", CARRY_SCRIPT), "write failed")
        return project
    end

    local function move_to_release(project, id)
        return dev(project, { "board", "move", id, support.COLUMN_NAME.RELEASE })
    end

    testing.test("carry_proof writes the records a rebased commit lacks", function()
        local project = carry_project()
        local id = review_ready(project)
        local before = head(project.root)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        testing.ok(head(project.root) ~= before, "the rebase must rewrite the commit")
        local out, code = move_to_release(project, id)
        testing.eq(code, 1, out)
        testing.ok(out:find("No run of `dev board check`", 1, true), out)
        out = dev(project, { "carry", id })
        testing.ok(out:find("carry: true", 1, true), out)
        local records = 0
        for _, comment in ipairs(comments(project.home, id)) do
            if comment.body:find(head(project.root), 1, true) then
                records = records + 1
            end
        end
        testing.eq(records, 3)
    end)

    testing.test("a carried card's move to Release names only its change not on trunk", function()
        local project = carry_project()
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        local out = dev(project, { "carry", id })
        testing.ok(out:find("carry: true", 1, true), out)
        local written = #comments(project.home, id)
        out = dev(project, { "carry", id })
        testing.ok(out:find("carry: true", 1, true), out)
        testing.eq(#comments(project.home, id), written)
        local moved, code = move_to_release(project, id)
        testing.eq(code, 1, moved)
        testing.eq(moved:find("No run of `dev board check`", 1, true), nil, moved)
        testing.ok(moved:find("not on trunk", 1, true), moved)
        testing.ok(column_of(project.home, id) ~= support.COLUMN_NAME.RELEASE)
    end)

    testing.test("a move to Done of a proven card not on trunk names dev board land", function()
        local project = jj_project()
        local id = verified_card(project)
        local out, code = dev(project, { "board", "move", id, support.COLUMN_NAME.DONE })
        testing.eq(code, 1, out)
        testing.ok(out:find("Its change is not on trunk.", 1, true), out)
        testing.ok(out:find("Run `dev board land " .. id:sub(1, 8) .. "` first.", 1, true), out)
        testing.ok(column_of(project.home, id) ~= support.COLUMN_NAME.DONE)
    end)

    for _, label in ipairs({ board.NO_CHANGE, board.TRUNK_BLOCKER }) do
        testing.test(
            "a " .. label .. " card moves to Done though its change is not on trunk",
            function()
                local project = jj_project()
                local id = verified_card(project)
                must(dev(project, { "board", "label", id, "+" .. label }, { DEV_AGENT = "" }))
                local out, code = dev(project, { "board", "move", id, support.COLUMN_NAME.DONE })
                testing.eq(out:find("is not on trunk", 1, true), nil, out)
                testing.eq(code, 0, out)
                testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
            end
        )
    end

    testing.test("carry_proof writes nothing for a commit whose patch differs", function()
        local project = carry_project()
        local id = review_ready(project)
        assert(fs.write(project.root .. "/work.txt", "two\n"), "write failed")
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        local before = #comments(project.home, id)
        local out = dev(project, { "carry", id })
        testing.ok(out:find("carry: nil", 1, true), out)
        testing.eq(#comments(project.home, id), before)
        local moved, code = move_to_release(project, id)
        testing.eq(code, 1, moved)
        testing.ok(column_of(project.home, id) ~= support.COLUMN_NAME.RELEASE)
    end)

    local function squashed_parent(project)
        stack_on_parent(project, { args = { "-m", "test: parent" }, body = "mid\n" })
        local id = verified_card(project)
        local checked_at = head(project.root)
        jj(project.root, "squash", "--from", "@-", "--into", "@", "--use-destination-message")
        testing.ok(head(project.root) ~= checked_at, "the squash must rewrite the commit")
        return id, checked_at
    end

    testing.test("land carries the check across a squash that leaves the tree identical", function()
        local project = jj_project()
        local id, checked_at = squashed_parent(project)
        local out = refused(project, id, {
            "The check at commit " .. checked_at:sub(1, 12) .. " carries over",
            "The code review is of an earlier commit",
            "The style review is of an earlier commit",
        })
        testing.eq(out:find("No run of `dev board check`", 1, true), nil, out)
        approve_reviews(project, id)
        local landed, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, landed)
        local list = comments(project.home)
        local carried = "The check was carried over from commit " .. checked_at:sub(1, 12)
        testing.ok(list[#list].body:find(carried, 1, true), list[#list].body)
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("land keeps the check stale after a squash that changes the tree", function()
        local project = jj_project()
        local id = squashed_parent(project)
        assert(fs.write(project.root .. "/extra.txt", "extra\n"), "write failed")
        local out = refused(project, id, { "No run of `dev board check`" })
        testing.eq(out:find("carries over", 1, true), nil, out)
    end)

    testing.test("land keeps the reviews stale after a squash and says so", function()
        local project = jj_project()
        local id = squashed_parent(project)
        refused(project, id, {
            "Its reviews do not carry over.",
            "The code review is of an earlier commit",
            "The style review is of an earlier commit",
        })
    end)

    testing.test("land reads trunk before and under the turn, and after the land", function()
        -- Move trunk over an unrelated file and rebase the reviewed change onto it
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Land it with a log of every trunk read
        local reads = support.tempdir() .. "/fetch.log"
        local out, code = dev(
            project,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, FETCH_LOG = reads }
        )
        testing.eq(code, 0, out)

        -- Check the carried check note and the four reads
        local list = comments(project.home)
        testing.ok(list[#list].body:find("carried over", 1, true), list[#list].body)
        testing.eq(fs.read(reads), "fetch\nfetch\nfetch\nfetch\n")
    end)

    local function recheck_project(row)
        return jj_project('\n[board.land]\nrecheck = ["' .. row .. '"]\n')
    end

    testing.test("land reruns the recheck rows when trunk changes the patch's context", function()
        -- Set up a recheck row that leaves a marker
        local marker = support.tempdir() .. "/rechecked"
        local project = recheck_project("touch " .. marker)

        -- Move trunk near the patch and rebase onto it
        local id = review_ready(project)
        trunk_moves(project, { ["shared.txt"] = NEAR_EDIT })
        rebase_onto_trunk(project.root)

        -- Land it and look for the marker
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.ok(fs.is_file(marker), "the recheck row never ran")
    end)

    testing.test("land takes no turn while the recheck rows run", function()
        -- Set up a recheck row that copies the board while it runs
        local snapshot = support.tempdir() .. "/board.json"
        local project = recheck_project("bin/snap")
        assert(
            fs.write(
                project.root .. "/bin/snap",
                '#!/bin/sh\ncp "' .. support.board_file(project.home, "mine") .. '" "$SNAPSHOT"\n'
            ),
            "write failed"
        )
        must(dev_os.run({ "chmod", "755", project.root .. "/bin/snap" }))

        -- Move trunk near the patch and land onto it
        local id = review_ready(project)
        trunk_moves(project, { ["shared.txt"] = NEAR_EDIT })
        rebase_onto_trunk(project.root)
        local out, code = dev(
            project,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, SNAPSHOT = snapshot }
        )
        testing.eq(code, 0, out)

        -- Check that the board copy shows the turn free and nobody holds it now
        local doc = assert(json.decode(assert(fs.read(snapshot))), "decode failed")
        for _, card in ipairs(doc.cards) do
            if card.name == turn.NAME then
                testing.ok(card.claim == nil or card.claim == json.null, "the turn was held")
            end
        end
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test("land runs the recheck rows with DEV_CI_PRIORITY set to 1", function()
        -- Set up a recheck row that writes its priority variable to a file
        local mark = support.tempdir() .. "/priority"
        local project = recheck_project("bin/prio")
        local body = table.concat({
            "#!/bin/sh",
            'printf %s "$DEV_CI_PRIORITY" >"$MARK"',
            "",
        }, "\n")
        assert(fs.write(project.root .. "/bin/prio", body), "write failed")
        must(dev_os.run({ "chmod", "755", project.root .. "/bin/prio" }))

        -- Move trunk near the patch and land onto it
        local id = review_ready(project)
        trunk_moves(project, { ["shared.txt"] = NEAR_EDIT })
        rebase_onto_trunk(project.root)
        local out, code = dev(
            project,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, MARK = mark }
        )
        testing.eq(code, 0, out)

        -- Check the row saw priority 1
        testing.eq(fs.read(mark), "1")
    end)

    local function counting_project(runs, moves)
        local script = support.tempdir() .. "/rows.sh"
        local project = recheck_project("sh " .. script)
        local lines = { "#!/bin/sh", "echo run >>" .. runs }
        if moves then
            local marker = support.tempdir() .. "/moved"
            if moves == "once" then
                lines[#lines + 1] = "[ -e " .. marker .. " ] && exit 0"
                lines[#lines + 1] = "touch " .. marker
            end
            lines[#lines + 1] = "d=$(mktemp -d)"
            lines[#lines + 1] = "git clone -q --branch master " .. project.bare .. ' "$d/c"'
            lines[#lines + 1] = 'cd "$d/c" && echo "$d" >moved.txt && git add moved.txt'
            lines[#lines + 1] = "git -c user.name=t -c user.email=t@example.com commit -q -m moved"
            lines[#lines + 1] = "git push -q origin HEAD:refs/heads/master"
            lines[#lines + 1] = ""
        end
        assert(fs.write(script, table.concat(lines, "\n")), "write failed")
        return project
    end

    testing.test("land keeps a held turn and stretches it for the recheck", function()
        -- Set up a recheck row that copies the board while it runs
        local snapshot = support.tempdir() .. "/board.json"
        local project = recheck_project("bin/snap")
        assert(
            fs.write(
                project.root .. "/bin/snap",
                '#!/bin/sh\ncp "' .. support.board_file(project.home, "mine") .. '" "$SNAPSHOT"\n'
            ),
            "write failed"
        )
        must(dev_os.run({ "chmod", "755", project.root .. "/bin/snap" }))

        -- Hold the turn, then land onto a moved trunk
        local id = review_ready(project)
        trunk_moves(project, { ["shared.txt"] = NEAR_EDIT })
        rebase_onto_trunk(project.root)
        must(dev(project, { "board", "turn", id }))
        local out, code = dev(
            project,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, SNAPSHOT = snapshot }
        )
        testing.eq(code, 0, out)

        -- Check the board copy still shows a hold stretched past the lease
        local doc = assert(json.decode(assert(fs.read(snapshot))), "decode failed")
        local claim
        for _, card in ipairs(doc.cards) do
            if card.name == turn.NAME then
                claim = card.claim
            end
        end
        testing.ok(type(claim) == "table", "the hold was not kept while the row ran")
        testing.ok(
            claim.expires_at > store.stamp(os.time() + turn.LEASE_SECONDS + 60),
            claim.expires_at
        )
    end)

    testing.test("land refuses after trunk moves in every recheck", function()
        -- Set up a row that moves trunk on every run
        local runs = support.tempdir() .. "/runs"
        local project = counting_project(runs, "always")
        local id = review_ready(project)
        trunk_moves(project, { ["shared.txt"] = NEAR_EDIT })
        rebase_onto_trunk(project.root)

        -- Land and expect the refusal
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 1, out)

        -- Check five runs, no push and no turn left held
        testing.ok(out:find("Trunk moved during each of 5 rechecks", 1, true), out)
        testing.eq(fs.read(runs), string.rep("run\n", 5))
        testing.eq(fs.read(project.log), nil)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test("land rechecks again when trunk moves during the recheck", function()
        -- Set up a row that moves trunk on its first run only
        local runs = support.tempdir() .. "/runs"
        local project = counting_project(runs, "once")
        local id = review_ready(project)
        trunk_moves(project, { ["shared.txt"] = NEAR_EDIT })
        rebase_onto_trunk(project.root)

        -- Land and expect two runs
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(fs.read(runs), "run\nrun\n")

        -- Check that both the moved trunk and the change landed
        local log = dev_os.capture({ "git", "-C", project.bare, "log", "master", "--format=%s" })
        testing.ok(log:find("moved", 1, true), log)
        testing.ok(log:find("feat: work", 1, true), log)
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("land pushes after one recheck when trunk stays put", function()
        -- Set up a row that leaves trunk alone
        local runs = support.tempdir() .. "/runs"
        local project = counting_project(runs, false)
        local id = review_ready(project)
        trunk_moves(project, { ["shared.txt"] = NEAR_EDIT })
        rebase_onto_trunk(project.root)

        -- Land and expect one run
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(fs.read(runs), "run\n")

        -- Check the card is Done
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("a failed recheck row refuses the land and leaves trunk alone", function()
        -- Set up a recheck row that fails and move trunk near the patch
        local project = recheck_project("false")
        local id = review_ready(project)
        trunk_moves(project, { ["shared.txt"] = NEAR_EDIT })
        rebase_onto_trunk(project.root)

        -- Land and expect the refusal naming the row
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("recheck row failed. Nothing was pushed.", 1, true), out)
        testing.ok(out:find("fail - false", 1, true), out)

        -- Check nothing was pushed and the card stays in Verify
        testing.eq(fs.read(project.log), nil)
        testing.eq(column_of(project.home), board.DEFAULT_NAMES.verify)
    end)

    testing.test("land skips the recheck rows over unrelated trunk files", function()
        -- Set up a recheck row that leaves a marker and move trunk far from the patch
        local marker = support.tempdir() .. "/rechecked"
        local project = recheck_project("touch " .. marker)
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n", ["shared.txt"] = "A\nb\nc\nd\ne\nf\ng\n" })
        rebase_onto_trunk(project.root)

        -- Land it
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Check the row never ran and the card is Done
        testing.ok(not fs.is_file(marker), "the recheck row ran")
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("land skips the recheck when the check sits on the current trunk", function()
        -- Set up a recheck row that leaves a marker and review the change on current trunk
        local marker = support.tempdir() .. "/rechecked"
        local project = recheck_project("touch " .. marker)
        local id = review_ready(project)

        -- Land it with trunk unmoved
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Check the row never ran
        testing.ok(not fs.is_file(marker), "the recheck row ran")
    end)

    testing.test("land reruns trunk's recheck rows when the change empties its own", function()
        -- Set up a recheck row on trunk and a change that empties it
        local marker = support.tempdir() .. "/rechecked"
        local project = recheck_project("touch " .. marker)
        assert(fs.write(project.root .. "/.dev/config.toml", NARROWED), "write failed")

        -- Move trunk near the patch and rebase onto it
        local id = review_ready(project)
        trunk_moves(project, { ["shared.txt"] = NEAR_EDIT })
        rebase_onto_trunk(project.root)

        -- Land it and look for the marker
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.ok(fs.is_file(marker), "trunk's recheck row never ran")
    end)

    testing.test("land ignores a recheck row the change adds to its own config", function()
        -- Give the change a config that adds a failing recheck row
        local project = jj_project()
        assert(
            fs.write(
                project.root .. "/.dev/config.toml",
                '[board]\nbackend = "local"\nname = "mine"\n\n[board.land]\nrecheck = ["false"]\n'
            ),
            "write failed"
        )

        -- Move trunk over an unrelated file and rebase onto it
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Land it and check the row never failed the land
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.ok(not out:find("recheck row failed", 1, true), out)
    end)

    testing.test("land stays put when the push after a carry is rejected", function()
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        local out, code = dev(project, { "board", "land", id }, {
            LAND_CODE = "1",
            LAND_MSG = "push rejected: trunk moved",
        })
        testing.eq(code, 1, out)
        testing.ok(out:find("`jj land` failed with this output.", 1, true), out)
        testing.ok(out:find("push rejected: trunk moved", 1, true), out)
        testing.eq(column_of(project.home), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("land does not carry a pass over a failed run at the rebased commit", function()
        local project = jj_project()
        local id = review_ready(project, "! test -e docs.txt")
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        local out, code = dev(project, { "board", "check", id })
        testing.ok(code ~= 0, out)
        refused(project, id, { "did not pass every row" })
    end)

    testing.test("land does not carry over an expect-fail record at the rebased commit", function()
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        dev(project, { "board", "check", id, "--expect-fail" })
        refused(project, id, { "No run of `dev board check` is recorded" })
    end)

    testing.test("land does not carry over an unreadable record at the rebased commit", function()
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        local record = "dev-check: commit="
            .. head(project.root)
            .. " change=chg mode=run\n1 pass dev lint"
        local backend, restore = board_at(project.home)
        for _, card in ipairs(assert(backend:cards())) do
            if card.id:sub(1, #id) == id then
                assert(backend:note(card.id, record))
            end
        end
        restore()
        refused(project, id, { "could not be read", "Run `dev board check` again." })
    end)

    testing.test("clean rebase carries the check", function()
        local project = jj_project()
        local id = review_ready(project)
        local before = head(project.root)
        trunk_moves(project, { ["shared.txt"] = "A\nb\nc\nd\ne\nf\ng\n" })
        rebase_onto_trunk(project.root)
        testing.ok(head(project.root) ~= before, "the rebase must rewrite the commit")
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        local list = comments(project.home)
        testing.ok(
            list[#list].body:find("carried over from commit " .. before:sub(1, 12), 1, true),
            list[#list].body
        )
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    local function child_workspace(project, name, files)
        local dir = support.tempdir() .. "/" .. name
        jj(project.root, "workspace", "add", dir, "--name", name, "-r", "@")
        for path, body in pairs(files or {}) do
            assert(fs.write(dir .. "/" .. path, body), "write failed")
        end
        return dir
    end

    testing.test("land moves a child workspace onto the rebased commit and names it", function()
        local project = jj_project()
        local id = review_ready(project)
        local dir = child_workspace(project, "my kid", { ["kid.txt"] = "kid\n" })
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.ok(out:find("Moved the workspace my kid at " .. dir, 1, true), out)
        local parent = jj(dir, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
        local trunk = jj(dir, "log", "-r", "master", "--no-graph", "-T", "commit_id")
        testing.eq(parent, trunk)
        testing.eq(fs.read(dir .. "/kid.txt"), "kid\n")
    end)

    testing.test("land leaves a child workspace with conflicts alone and names it", function()
        local project = jj_project()
        local id = review_ready(project)
        local dir = child_workspace(project, "kid", { ["docs.txt"] = "child docs\n" })
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        local left = "Left the workspace kid at " .. dir .. " alone: its commit has conflicts"
        testing.ok(out:find(left, 1, true), out)
        testing.eq(out:find("Moved the workspace kid", 1, true), nil, out)
    end)

    testing.test("a rebase that leaves a conflict does not carry the check", function()
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["shared.txt"] = "a\nb\nc\nd\ne\nf\nX\n" })
        rebase_onto_trunk(project.root)
        refused(project, id, {
            "The working-copy commit has conflicts",
            "run `dev board check` again",
        })
    end)

    testing.test(
        "land names only the unticked outcome after a rebase that the carry accepts",
        function()
            local project = jj_project()
            trunk_moves(project, { ["shared.txt"] = SHARED })
            rebase_onto_trunk(project.root)
            assert(fs.write(project.root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nG\n"), "write failed")
            local id = new_card(project)
            to_verify(project, id)
            approve_reviews(project, id)
            must(dev(project, { "board", "check", id }))
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)
            local out = refused(project, id, { "1 of 1 outcomes are unticked" })
            testing.eq(out:find("review of", 1, true), nil, out)
            testing.eq(out:find("No run of `dev board check`", 1, true), nil, out)
        end
    )

    testing.test("land names the column beside the carry after an accepted rebase", function()
        local project = jj_project()
        local id = review_ready(project)
        must(dev(project, { "board", "move", id, support.Column.PROGRESS }))
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        local out = refused(project, id, { "only a card in" })
        testing.eq(out:find("earlier commit", 1, true), nil, out)
        testing.eq(out:find("No run of `dev board check`", 1, true), nil, out)
    end)

    testing.test("land carries over a rebase past a changed former shared path", function()
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["lib/core.txt"] = "core\n" })
        rebase_onto_trunk(project.root)
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("land refuses the carry when jj cannot compare the checked commit", function()
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        refused(
            project,
            id,
            { "The `jj` command could not compare the checked commit" },
            { INTERDIFF_FAIL = "1" }
        )
    end)

    testing.test(
        "land carries a child's check after its checked parent landed rewritten",
        function()
            local project = jj_project()
            stack_on_parent(project, { args = { "-m", "feat: parent" }, body = "mid\n" })
            local id = verified_card(project)
            local before = head(project.root)
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            jj(project.root, "rebase", "-s", "@-", "-d", "master")
            jj(project.root, "bookmark", "set", "master", "-r", "@-")
            jj(project.root, "git", "push", "--remote", "origin", "--bookmark", "master")
            testing.ok(head(project.root) ~= before, "the rebase must rewrite the child")
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            local list = comments(project.home)
            testing.ok(
                list[#list].body:find("carried over from commit " .. before:sub(1, 12), 1, true),
                list[#list].body
            )
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test(
        "land refuses a rebase that changes the patch and names the checked commit",
        function()
            local project = jj_project()
            local id = review_ready(project)
            local before = head(project.root)
            assert(fs.write(project.root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nH\n"), "write failed")
            trunk_moves(project, { ["shared.txt"] = "A\nb\nc\nd\ne\nf\ng\n" })
            rebase_onto_trunk(project.root)
            refused(project, id, {
                "This commit differs from the checked commit " .. before:sub(1, 12),
            })
        end
    )

    testing.test(
        "land refuses the carry when the checked commit sat off trunk's ancestry",
        function()
            local project = jj_project()
            trunk_moves(project, { ["shared.txt"] = SHARED })
            jj(project.root, "new", "master", "-m", "side")
            assert(fs.write(project.root .. "/side.txt", "side\n"), "write failed")
            jj(project.root, "new", "-m", "feat: work")
            assert(fs.write(project.root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nG\n"), "write failed")
            local id = verified_card(project)
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)
            refused(project, id, { "does not sit on a single ancestor of trunk" })
        end
    )

    testing.test("land refuses a carry from a checked commit of another change", function()
        local project = jj_project()
        local id = new_card(project)
        to_verify(project, id)
        must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        local trunk = jj(project.root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
        local change = jj(project.root, "log", "-r", "@", "--no-graph", "-T", "change_id")
        local at = { commit = trunk, change = change }
        local records = {
            check.record(at, { { result = check.Result.PASS, run_id = "-", run = "true" } }, false),
            review.record(review.Kind.CODE, "rev", at, review.Verdict.CLEAN),
            review.record(review.Kind.STYLE, "rev", at, review.Verdict.CLEAN),
        }
        local backend, restore = board_at(project.home)
        for _, card in ipairs(assert(backend:cards())) do
            if card.id:sub(1, #id) == id then
                for _, body in ipairs(records) do
                    assert(backend:note(card.id, body))
                end
            end
        end
        restore()
        local before = #comments(project.home, id)
        refused(project, id, {
            "The checked commit " .. trunk:sub(1, 12) .. " is not of change",
        })
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)
        testing.eq(#comments(project.home, id), before)
    end)

    local function reviewed_and_checked(opts)
        local project, id = opts.project, opts.id
        approve_reviews(project, id)
        must(dev(project, { "board", "check", id }))
        return head(project.root)
    end

    local function two_checked_commits(opts)
        local project = opts.project
        trunk_moves(project, { ["shared.txt"] = SHARED })
        rebase_onto_trunk(project.root)
        assert(fs.write(project.root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nG\n"), "write failed")
        local id = new_card(project)
        to_verify(project, id)
        must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        local older = reviewed_and_checked({ project = project, id = id })
        assert(fs.write(project.root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nH\n"), "write failed")
        local newer = reviewed_and_checked({ project = project, id = id })
        assert(fs.write(project.root .. "/shared.txt", opts.final_shared), "write failed")
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        return id, older, newer
    end

    testing.test("land carries from an older checked commit when the newest one differs", function()
        local project = jj_project()
        local id, older = two_checked_commits({
            project = project,
            final_shared = "a\nb\nc\nd\ne\nf\nG\n",
        })
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        local list = comments(project.home)
        testing.ok(list[#list].body:find("carried over from commit " .. older:sub(1, 12), 1, true))
    end)

    testing.test("a commit with two passing runs still carries", function()
        local project = jj_project()
        trunk_moves(project, { ["shared.txt"] = SHARED })
        rebase_onto_trunk(project.root)
        assert(fs.write(project.root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nG\n"), "write failed")
        local id = new_card(project)
        to_verify(project, id)
        must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        local older = reviewed_and_checked({ project = project, id = id })
        must(dev(project, { "board", "check", id }))
        assert(fs.write(project.root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nH\n"), "write failed")
        reviewed_and_checked({ project = project, id = id })
        assert(fs.write(project.root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nG\n"), "write failed")
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        local list = comments(project.home)
        testing.ok(list[#list].body:find("carried over from commit " .. older:sub(1, 12), 1, true))
    end)

    testing.test(
        "land carries a checked commit whose reviews sit at an earlier identical patch",
        function()
            local project = jj_project()
            local id = new_card(project)
            to_verify(project, id)
            must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
            approve_reviews(project, id)
            jj(project.root, "describe", "-m", "feat: work again")
            must(dev(project, { "board", "check", id }))
            local at_check = head(project.root)
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            local list = comments(project.home)
            testing.ok(
                list[#list].body:find("carried over from commit " .. at_check:sub(1, 12), 1, true)
            )
        end
    )

    testing.test(
        "land does not carry a checked commit whose reviews sit at a different patch",
        function()
            local project = jj_project()
            local id = new_card(project)
            to_verify(project, id)
            must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
            approve_reviews(project, id)
            assert(fs.write(project.root .. "/other.txt", "other\n"), "write failed")
            must(dev(project, { "board", "check", id }))
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)
            local out = refused(project, id, { "No run of `dev board check`" })
            testing.eq(out:find("carried over", 1, true), nil, out)
        end
    )

    testing.test("land names the newest checked commit when no candidate carries", function()
        local project = jj_project()
        local id, older, newer = two_checked_commits({
            project = project,
            final_shared = "a\nb\nc\nd\ne\nf\nZ\n",
        })
        local out = refused(project, id, { "differs from the checked commit " .. newer:sub(1, 12) })
        testing.eq(out:find(older:sub(1, 12), 1, true), nil, out)
    end)

    testing.test("land refuses at once when jj cannot read the newest checked commit", function()
        local project = jj_project()
        local id, older, newer = two_checked_commits({
            project = project,
            final_shared = "a\nb\nc\nd\ne\nf\nG\n",
        })
        local out = refused(
            project,
            id,
            { "The `jj` command could not compare the checked commit " .. newer:sub(1, 12) },
            { INTERDIFF_FAIL_AT = newer }
        )
        testing.eq(out:find(older:sub(1, 12), 1, true), nil, out)
    end)

    testing.test(
        "land refuses at once when jj cannot read the newest checked commit's change",
        function()
            local project = jj_project()
            local id, older, newer = two_checked_commits({
                project = project,
                final_shared = "a\nb\nc\nd\ne\nf\nG\n",
            })
            local out = refused(
                project,
                id,
                { "The `jj` command could not read the checked commit " .. newer:sub(1, 12) },
                { LOG_FAIL_AT = newer }
            )
            testing.eq(out:find(older:sub(1, 12), 1, true), nil, out)
        end
    )

    local failed_reads = {
        {
            name = "parent",
            switch = "PARENT_FAIL_AT",
            message = "The `jj` command could not read the parent of the checked commit ",
        },
        {
            name = "ancestor",
            switch = "ANCESTOR_FAIL_AT",
            message = "The `jj` command could not read the ancestor of the checked commit ",
        },
    }
    for _, case in ipairs(failed_reads) do
        testing.test("land refuses at once when jj cannot read the older " .. case.name, function()
            local project = jj_project()
            local id, older, newer = two_checked_commits({
                project = project,
                final_shared = "a\nb\nc\nd\ne\nf\nG\n",
            })
            local out = refused(project, id, { case.message }, { [case.switch] = older })
            testing.eq(out:find("carried over", 1, true), nil, out)
            testing.eq(out:find(newer:sub(1, 12), 1, true), nil, out)
        end)
    end

    testing.test("land names the older candidate when its interdiff read fails", function()
        local project = jj_project()
        local id, older = two_checked_commits({
            project = project,
            final_shared = "a\nb\nc\nd\ne\nf\nZ\n",
        })
        refused(
            project,
            id,
            { "The `jj` command could not compare the checked commit " .. older:sub(1, 12) },
            { INTERDIFF_FAIL_AT = older }
        )
    end)

    testing.test("land refuses a rebase of a commit that differs from the checked one", function()
        local project = jj_project()
        local id = review_ready(project)
        local before = head(project.root)
        assert(fs.write(project.root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nH\n"), "write failed")
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        refused(project, id, { "differs from the checked commit " .. before:sub(1, 12) })
    end)

    testing.test(
        "land refuses a duplicate of the checked change under another change id",
        function()
            local project = jj_project()
            local id = review_ready(project)
            jj(project.root, "duplicate", "@")
            local copy =
                jj(project.root, "log", "-r", "children(@-) ~ @", "--no-graph", "-T", "change_id")
            jj(project.root, "edit", copy)
            local out = refused(project, id, { "No code review of change" })
            testing.eq(out:find("carried over", 1, true), nil, out)
        end
    )

    testing.test(
        "land does not carry a review that was never recorded at the checked commit",
        function()
            local project = jj_project()
            trunk_moves(project, { ["shared.txt"] = SHARED })
            rebase_onto_trunk(project.root)
            local id = new_card(project)
            to_verify(project, id)
            must(record_review(project, id))
            must(dev(project, { "board", "check", id }))
            local at_check = head(project.root)
            must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)
            local out = refused(project, id, { "No style review of change" })
            testing.ok(
                out:find(
                    "The check at commit " .. at_check:sub(1, 12) .. " cannot carry over",
                    1,
                    true
                ),
                out
            )
            local _, repeats = out:gsub("No style review of change", "")
            testing.eq(repeats, 1, out)
        end
    )

    testing.test("land refuses a working copy that holds conflicts", function()
        local project = jj_project()
        local id = new_card(project)
        to_verify(project, id)
        local first = jj(project.root, "log", "-r", "@", "--no-graph", "-T", "change_id")
        jj(project.root, "new", "master", "-m", "feat: other")
        assert(fs.write(project.root .. "/work.txt", "two\n"), "write failed")
        jj(project.root, "rebase", "-r", "@", "-d", first)
        refused(project, id, {
            "The working-copy commit has conflicts",
            "run `dev board check` again",
        })
    end)

    testing.test("land refuses a card labelled needs:human", function()
        local project = jj_project()
        local id = new_card(project)
        must(dev(project, { "board", "move", id, support.Column.BLOCKED }))
        must(dev(project, { "board", "label", id, "needs:human" }))
        refused(project, id, { "is labelled needs:human", "waits on the owner" })
    end)

    testing.test("land refuses when the fetch from the remote of record fails", function()
        local project = jj_project()
        local id = verified_card(project)
        jj(project.root, "git", "remote", "set-url", "origin", project.root .. "/missing-remote")
        refused(project, id, { "Trunk cannot be compared", "The fetch from origin failed" })
    end)

    testing.test("land retries a refused ssh signature once", function()
        local project = jj_project()
        local id = review_ready(project)
        local count = support.tempdir() .. "/count.log"
        local out, code = dev(
            project,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, FETCH_REFUSALS = "1", FETCH_COUNT = count }
        )
        testing.eq(code, 0, out)
        testing.eq(fs.read(count), "1\n")
        testing.ok(out:find("landed " .. id, 1, true), out)
    end)

    testing.test("land names the hardware key after a second refusal", function()
        local project = jj_project()
        local id = review_ready(project)
        local count = support.tempdir() .. "/count.log"
        refused(project, id, {
            "The fetch from origin failed",
            "Touch the hardware key",
            "run `dev board land` again.",
        }, { FETCH_REFUSALS = "5", FETCH_COUNT = count })
        testing.eq(fs.read(count), "2\n")
    end)

    testing.test("land ends a hung fetch at a timeout", function()
        local project = jj_project()
        local id = review_ready(project)
        refused(project, id, {
            "The fetch from origin failed",
            "The fetch ran past 1 seconds",
            "Touch it and run `dev board land` again.",
        }, { FETCH_HANG = "1", DEV_LAND_FETCH_SECONDS = "1" })
    end)

    testing.test("land refuses when the card's comments cannot be read", function()
        local project = jj_project()
        local backend = fake_backend(project.root)
        function backend:comments()
            return nil, "board unavailable: comments timed out"
        end
        local result = land_as_lander(backend)
        testing.eq(result.code, 1)
        testing.eq(result.message, "board unavailable: comments timed out")
        testing.eq(backend.notes, {})
    end)

    testing.test("land refuses when the board's cards cannot be read", function()
        local project = jj_project()
        local backend = fake_backend(project.root)
        function backend:cards()
            return nil, "board unavailable: cards timed out"
        end
        local result = land_as_lander(backend)
        testing.eq(result.code, 1)
        testing.eq(result.message, "board unavailable: cards timed out")
        testing.eq(backend.notes, {})
    end)

    testing.test("land names outcomes that cannot be read and does not land", function()
        local project = jj_project()
        local backend = fake_backend(project.root, { outcomes_unreadable = true })
        local result = land_as_lander(backend)
        testing.eq(result.code, 1)
        testing.ok(
            result.message:find(
                "Card " .. CARD_PREFIX .. " cannot land for these reasons.",
                1,
                true
            ),
            result.message
        )
        testing.ok(
            result.message:find(
                "Its outcomes cannot be read from Pomb. They cannot be checked.",
                1,
                true
            ),
            result.message
        )
        testing.eq(backend.notes, {})
    end)

    testing.test("land names a renamed Done column for unreadable outcomes", function()
        local project = jj_project()
        local backend = fake_backend(project.root, { outcomes_unreadable = true })
        backend.column_map = { done = "Shipped" }
        local result = land_as_lander(backend)
        testing.eq(result.code, 1)
        testing.ok(
            result.message:find("cannot move to Shipped. Its outcomes", 1, true),
            result.message
        )
    end)

    testing.test("land names a renamed Done column for unticked outcomes", function()
        local project = jj_project()
        local backend = fake_backend(project.root, {
            outcomes = { { id = "o1", name = "It works", done = false } },
        })
        backend.column_map = { done = "Shipped" }
        local result = land_as_lander(backend)
        testing.eq(result.code, 1)
        testing.ok(
            result.message:find("cannot move to Shipped. 1 of 1 outcomes", 1, true),
            result.message
        )
    end)

    testing.test("land refuses a working copy that jj cannot read", function()
        local project = jj_project()
        local id = verified_card(project)
        local out = refused(
            project,
            id,
            { "The `jj` command could not read the working-copy commit of" },
            {
                SHAPE_FAIL = "1",
            }
        )
        testing.ok(out:find(project.root, 1, true), out)
    end)

    testing.test("land refuses when the rebase onto trunk fails", function()
        local project = jj_project()
        local id = verified_card(project)
        push_trunk(project)
        local FAIL_AT = { REBASE = "rebase" }
        refused(project, id, { "The rebase onto trunk failed" }, { LOG_FAIL_AT = FAIL_AT.REBASE })
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test(
        "land refuses a rebase of its own that leaves conflicts and frees the turn",
        function()
            local project = jj_project()
            local id = review_ready(project)
            trunk_moves(project, { ["shared.txt"] = "a\nb\nc\nd\ne\nf\nX\n" })
            refused(project, id, { "The working-copy commit has conflicts" })
            testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)
            testing.eq(turn_holder(project.home), nil)
        end
    )

    testing.test("land refuses a remote of record that is not a remote of the project", function()
        local project = jj_project()
        local id = verified_card(project)
        refused(project, id, {
            "Trunk cannot be compared. The remote of record gerrit is not a remote of this project",
        }, { JJ_FORGE = "gerrit" })
    end)

    testing.test("land refuses a forge value that is not gerrit, github or plain", function()
        local project = jj_project()
        local id = verified_card(project)
        refused(project, id, {
            "Trunk cannot be compared. Forge must be gerrit, github or plain "
                .. "(got: bogus, from JJ_FORGE=bogus).",
        }, { JJ_FORGE = "bogus" })
    end)

    testing.test("land refuses when jj cannot name the working-copy commit", function()
        local project = jj_project()
        local id = verified_card(project)
        local out = refused(
            project,
            id,
            { "The `jj` command could not name the working-copy commit of" },
            { LOG_FAIL_AT = "log" }
        )
        testing.ok(out:find(project.root, 1, true), out)
    end)

    testing.test("land refuses a jj project when jj is not on PATH", function()
        local project = jj_project()
        local backend = fake_backend(project.root)
        local original = os.getenv("PATH")
        local bare = support.tempdir()
        must(dev_os.run({ "ln", "-s", assert(dev_os.which("sh")), bare .. "/sh" }))
        ffi.C.setenv("PATH", bare, 1)
        local ok, result = pcall(land_as_lander, backend)
        ffi.C.setenv("PATH", original, 1)
        assert(ok, result)
        testing.eq(result.code, 1)
        testing.ok(
            result.message:find("could not read the worktree of " .. project.root, 1, true),
            result.message
        )
        testing.eq(backend.notes, {})
    end)

    local function land_through_stub(project, id, wrap)
        local backend, restore = board_at(project.home)
        backend.root = project.root
        wrap(backend)
        local set = {
            PATH = project.root .. "/bin:" .. os.getenv("PATH"),
            LAND_LOG = project.log,
            LAND_MSG = "stub land",
            REAL_JJ = dev_os.which("jj"),
            DEV_AGENT = "dotfiles/lander",
        }
        local saved = {}
        for name, value in pairs(set) do
            saved[name] = os.getenv(name) or ""
            ffi.C.setenv(name, value, 1)
        end
        local ok, result = pcall(cmd_board.run, "land", { id }, backend)
        for name, value in pairs(saved) do
            ffi.C.setenv(name, value, 1)
        end
        restore()
        assert(ok, result)
        return result
    end

    local function has_landed(project)
        return landed_calls(project.log) ~= ""
    end

    testing.test(
        "a landed card that is no longer planned is named when its move to Done fails",
        function()
            local project = jj_project()
            local id = verified_card(project)
            local result = land_through_stub(project, id, function(backend)
                local cards = backend.cards
                function backend:cards()
                    local list, message = cards(self)
                    if not list or not has_landed(project) then
                        return list, message
                    end
                    for _, card in ipairs(list) do
                        card.color = nil
                    end
                    return list
                end
                local single = backend.card
                function backend:card(...)
                    local found, message = single(self, ...)
                    if found and has_landed(project) then
                        found.color = nil
                    end
                    return found, message
                end
            end)
            testing.eq(result.code, 1, result.message)
            testing.ok(result.message:find("The move to Done failed.", 1, true), result.message)
            testing.ok(
                result.message:find(
                    "is not planned and cannot enter " .. support.COLUMN_NAME.DONE,
                    1,
                    true
                ),
                result.message
            )
            testing.ok(result.message:find("It lacks a size.", 1, true), result.message)
        end
    )

    testing.test(
        "a landed epic whose family cannot be read is named when its move to Done fails",
        function()
            local project = jj_project()
            local id = new_card(project)
            must(dev(project, { "board", "epic", id }))
            to_verify(project, id)
            approve(project, id)
            local result = land_through_stub(project, id, function(backend)
                local family = backend.family
                function backend:family(...)
                    if has_landed(project) then
                        return nil, "board unavailable: family timed out"
                    end
                    return family(self, ...)
                end
            end)
            testing.eq(result.code, 1, result.message)
            testing.ok(result.message:find("The move to Done failed.", 1, true), result.message)
            testing.ok(
                result.message:find("Board unavailable: family timed out.", 1, true),
                result.message
            )
        end
    )

    testing.test(
        "a landed commit whose done note was not written is named and exits non-zero",
        function()
            local project = jj_project()
            local id = verified_card(project)
            local commit = head(project.root)
            local out, code = dev(project, { "board", "land", id }, {
                LAND_TRUNK = LAND_TRUNK_KEEP,
                BREAK_BOARD = support.board_file(project.home, "mine"),
            })
            testing.eq(code, 1, out)
            testing.ok(
                landed_calls(project.log):find("land --yes", 1, true),
                landed_calls(project.log)
            )
            testing.ok(
                out:find(
                    "Landed commit " .. commit:sub(1, 12) .. ". The done note was NOT written",
                    1,
                    true
                ),
                out
            )
            testing.ok(out:find("and the card was not moved.", 1, true), out)
        end
    )

    local function reached_trunk(project)
        jj(project.root, "bookmark", "set", "master", "-r", "@")
        jj(project.root, "git", "push", "--remote", "origin", "--bookmark", "master")
        jj(project.root, "new")
    end

    local function trunk_commit(project)
        return jj(project.root, "log", "-r", "master@origin", "--no-graph", "-T", "commit_id")
    end

    testing.test("a rerun of land finishes a card whose change already reached trunk", function()
        local project = jj_project()
        local id = verified_card(project)
        local commit = head(project.root)
        reached_trunk(project)
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 0, out)
        testing.ok(out:find("settled " .. id, 1, true), out)
        testing.ok(out:find("at commit " .. commit:sub(1, 12), 1, true), out)
        testing.eq(landed_calls(project.log), "")
        testing.eq(trunk_commit(project), commit)
        local list = comments(project.home, id)
        local last = list[#list]
        testing.eq(last.kind, KIND_DONE)
        testing.ok(last.body:find("Landed commit " .. commit:sub(1, 12), 1, true), last.body)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("a rerun of land names a check that did not pass at the landed commit", function()
        local project = jj_project()
        local id = new_card(project)
        must(dev(project, { "board", "checks", id, "false" }))
        to_verify(project, id)
        approve_reviews(project, id)
        local _, failed = dev(project, { "board", "check", id })
        testing.ok(failed ~= 0, "the check must fail")
        must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        reached_trunk(project)
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("its board half cannot finish", 1, true), out)
        testing.ok(out:find("did not pass every row", 1, true), out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("a rerun of land names the reviews a landed change lacks", function()
        local project = jj_project()
        local id = new_card(project)
        to_verify(project, id)
        must(dev(project, { "board", "check", id }))
        must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        reached_trunk(project)
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("its board half cannot finish", 1, true), out)
        testing.ok(out:find("review", 1, true), out)
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("a rerun of land names a missing check run on a card in Verify", function()
        local project = jj_project()
        local id = new_card(project)
        to_verify(project, id)
        approve_reviews(project, id)
        must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        reached_trunk(project)
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("No run of `dev board check` is recorded on the card", 1, true), out)
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("a rerun of land leaves a card whose change is not on trunk in Verify", function()
        local project = jj_project()
        local id = verified_card(project)
        jj(project.root, "new")
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("The working-copy commit is empty", 1, true), out)
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    testing.test(
        "a fetch that fails after the land falls back to the commit from before it",
        function()
            local project = jj_project()
            local id = verified_card(project)
            local before = head(project.root)
            local out, code = dev(project, { "board", "land", id }, {
                LAND_TRUNK = LAND_TRUNK_REWRITE,
                FETCH_FAIL = "1",
            })
            testing.eq(code, 0, out)
            local after =
                jj(project.root, "log", "-r", "master@origin", "--no-graph", "-T", "commit_id")
            testing.ok(before ~= after, "the stub must rewrite the commit")
            testing.ok(out:find("at commit " .. before:sub(1, 12), 1, true), out)
            testing.ok(out:find("trunk could not be read", 1, true), out)
            testing.eq(out:find(after:sub(1, 12), 1, true), nil, out)
            local list = comments(project.home)
            local last = list[#list]
            testing.eq(last.kind, KIND_DONE)
            testing.ok(last.body:find(before:sub(1, 12), 1, true), last.body)
            testing.ok(last.body:find("may differ", 1, true), last.body)
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test("a landed card whose move to Done fails is named and exits non-zero", function()
        local project = jj_project()
        local id = new_card(project)
        local out = dev(project, {
            "board",
            "add",
            "Child",
            "--problem",
            "x",
            "--change",
            "x",
            "--out-of-scope",
            "y",
            "--size",
            "1",
            "--done-when",
            "x",
        })
        local child = assert(out:match("added (%x+)"), out)
        must(dev(project, { "board", "epic", id }))
        must(dev(project, { "board", "link", child, "parent", id }))
        to_verify(project, id)
        approve(project, id)
        must(dev(project, { "board", "turn", id }))
        local commit = head(project.root)
        local code
        out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(turn_holder(project.home), nil)
        testing.eq(code, 1, out)
        testing.ok(landed_calls(project.log):find("land --yes", 1, true), landed_calls(project.log))
        testing.ok(
            out:find(
                "Landed commit " .. commit:sub(1, 12) .. " and noted it on card " .. id,
                1,
                true
            ),
            out
        )
        testing.ok(out:find("The move to Done failed.", 1, true), out)
        testing.ok(out:find("1 of 1 children are open.", 1, true), out)
        local list = comments(project.home, id)
        testing.eq(list[#list].kind, KIND_DONE)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    local function in_verify(project)
        local id = new_card(project)
        to_verify(project, id)
        return id
    end

    testing.test("a held turn survives a check and lands the card under it", function()
        local project = jj_project()
        local id = in_verify(project)
        local out, code = dev(project, { "board", "turn", id })
        testing.eq(code, 0, out)
        testing.ok(out:find("Holding the landing turn for " .. id, 1, true), out)
        approve(project, id)
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")
        out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test("a second runner is told who holds the turn and since when", function()
        local project = jj_project()
        local id = in_verify(project)
        must(dev(project, { "board", "turn", id }))
        local out, code = dev(
            project,
            { "board", "turn", id, "--wait", "0" },
            { DEV_AGENT = "dotfiles/other" }
        )
        testing.eq(code, 1, out)
        testing.ok(out:find("held by dotfiles/lander since 20", 1, true), out)
        out, code = dev(project, { "board", "turn", id, "--hold", "120" })
        testing.eq(code, 0, out)
        testing.ok(
            out:find(
                "Renewed the landing turn held for " .. id .. " for 120 more seconds.",
                1,
                true
            ),
            out
        )
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")
    end)

    testing.test("a turn wait that times out exits nonzero and names the holder", function()
        local project = jj_project()
        local id = in_verify(project)
        must(dev(project, { "board", "turn", id }, { DEV_AGENT = "dotfiles/other" }))
        local out, code = dev(project, { "board", "turn", id, "--wait", "1" })
        testing.eq(code, 1, out)
        testing.ok(out:find("cannot take the landing turn", 1, true), out)
        testing.ok(out:find("held by dotfiles/other since", 1, true), out)
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/other")
    end)

    testing.test("land lands under a live claim whose hold note is stale", function()
        local project = jj_project()
        local id = in_verify(project)
        approve(project, id)
        must(dev(project, { "board", "turn", id, "--hold", "1" }))
        dev_os.nap(PAST_HOLD_SECONDS)
        local backend, restore = board_at(project.home)
        local cards = assert(backend:cards())
        for _, card in ipairs(cards) do
            if card.name == turn.NAME then
                assert(backend:claim(card.id, "dotfiles/lander", { ttl = 600, lease = true }))
            end
        end
        restore()
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test("land refuses a hold that ran out and lands nothing", function()
        local project = jj_project()
        local id = in_verify(project)
        approve(project, id)
        must(dev(project, { "board", "turn", id, "--hold", "1" }))
        dev_os.nap(PAST_HOLD_SECONDS)
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 1, out)
        testing.ok(out:find("ran out or was taken by another", 1, true), out)
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("land refuses a hold another runner took after it ran out", function()
        local project = jj_project()
        local id = in_verify(project)
        approve(project, id)
        must(dev(project, { "board", "turn", id, "--hold", "1" }))
        dev_os.nap(PAST_HOLD_SECONDS)
        must(dev(project, { "board", "turn", id }, { DEV_AGENT = "dotfiles/other" }))
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 1, out)
        testing.ok(out:find("ran out or was taken by another", 1, true), out)
        testing.eq(landed_calls(project.log), "")
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/other")
    end)

    local function lost_hold_taken_by_other(project, id)
        must(dev(project, { "board", "turn", id, "--hold", LOST_HOLD_SECONDS }))
        dev_os.nap(PAST_HOLD_SECONDS)
        must(dev(project, { "board", "turn", id }, { DEV_AGENT = "dotfiles/other" }))
    end

    local function land_waiting(project, id, seconds)
        local backend, restore = board_at(project.home)
        backend.root = project.root
        local previous = os.getenv("DEV_AGENT") or ""
        ffi.C.setenv("DEV_AGENT", "dotfiles/lander", 1)
        local ok, result = pcall(cmd_board.run, "land", { id, "--wait", seconds }, backend)
        ffi.C.setenv("DEV_AGENT", previous, 1)
        restore()
        assert(ok, result)
        return result
    end

    testing.test("land --wait waits out another holder after its own hold ran out", function()
        local project = jj_project()
        local id = verified_card(project)
        lost_hold_taken_by_other(project, id)
        local nap, now = dev_os.nap, store.now
        local clock = now()
        local naps = 0
        store.now = function()
            return clock
        end
        dev_os.nap = function(secs)
            naps = naps + 1
            clock = clock + math.ceil(secs)
        end
        local result = land_waiting(project, id, SHORT_WAIT_SECONDS)
        dev_os.nap = nap
        store.now = now
        testing.eq(result.code, 1, result.message)
        testing.ok(result.message:find("held by dotfiles/other since", 1, true), result.message)
        testing.eq(result.message:find("ran out or was taken", 1, true), nil)
        testing.ok(naps > 0, "the wait never slept")
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/other")
    end)

    testing.test("land --wait takes the turn once the other holder lets go", function()
        local project = jj_project()
        local id = verified_card(project)
        lost_hold_taken_by_other(project, id)
        local nap = dev_os.nap
        dev_os.nap = function()
            dev_os.nap = nap
            local other = { DEV_AGENT = "dotfiles/other" }
            must(dev(project, { "board", "turn", id, "--release" }, other))
            must(dev(project, { "board", "move", id, support.Column.BLOCKED }))
        end
        local result = land_waiting(project, id, LONG_WAIT_SECONDS)
        dev_os.nap = nap
        testing.eq(result.code, 1, result.message)
        testing.ok(result.message:find("cannot land", 1, true), result.message)
        testing.eq(result.message:find("ran out or was taken", 1, true), nil)
        testing.eq(turn_holder(project.home), nil)
    end)

    local function shortened_claim(project, id)
        local doc = board_doc(project.home)
        local short = store.stamp(store.now() + SHORT_CLAIM_SECONDS)
        board_card(doc, id).claim.expires_at = short
        local path = support.board_file(project.home, "mine")
        assert(fs.write(path, json.encode(doc)), "write failed")
        return short
    end

    testing.test("a check by the claimant renews its claim", function()
        local project = jj_project()
        local id = new_card(project)
        local builder = { DEV_AGENT = "dotfiles/builder" }
        must(dev(project, { "board", "move", id, support.Column.PROGRESS }, builder))
        local short = shortened_claim(project, id)
        local fence = claim_of(project.home, id).fence
        local out, code = dev(project, { "board", "check", id }, builder)
        testing.eq(code, 0, out)
        testing.eq(out:find("not renewed", 1, true), nil, out)
        local claim = claim_of(project.home, id)
        testing.eq(claim.fence, fence)
        testing.ok(claim.expires_at > short, claim.expires_at)
    end)

    testing.test("a check by another name renews no claim", function()
        local project = jj_project()
        local id = new_card(project)
        local builder = { DEV_AGENT = "dotfiles/builder" }
        must(dev(project, { "board", "move", id, support.Column.PROGRESS }, builder))
        local short = shortened_claim(project, id)
        local out, code = dev(project, { "board", "check", id }, { DEV_AGENT = "dotfiles/other" })
        testing.eq(code, 0, out)
        testing.eq(claim_of(project.home, id).expires_at, short)
    end)

    testing.test("a check on a card with no claim takes none", function()
        local project = jj_project()
        local id = new_card(project)
        local out, code = dev(project, { "board", "check", id }, { DEV_AGENT = "dotfiles/builder" })
        testing.eq(code, 0, out)
        testing.eq(claim_of(project.home, id), nil)
    end)

    testing.test("a land by the claimant renews its claim", function()
        local project = jj_project()
        local id = verified_card(project)
        must(dev(project, { "board", "take", id }))
        local short = shortened_claim(project, id)
        local out, code = dev(project, { "board", "land", id }, { LAND_CODE = "1" })
        testing.eq(code, 1, out)
        testing.eq(out:find("not renewed", 1, true), nil, out)
        testing.ok(claim_of(project.home, id).expires_at > short, out)
    end)

    testing.test("a review record renews the claimant's claim", function()
        local project = jj_project()
        local id = new_card(project)
        local builder = { DEV_AGENT = "dotfiles/builder" }
        must(dev(project, { "board", "move", id, support.Column.PROGRESS }, builder))
        local short = shortened_claim(project, id)
        local fence = claim_of(project.home, id).fence
        local out, code = record_review(project, id, { by = "dotfiles/code-examiner/x" })
        testing.eq(code, 0, out)
        local claim = claim_of(project.home, id)
        testing.eq(claim.fence, fence)
        testing.ok(claim.expires_at > short, claim.expires_at)
    end)

    testing.test("a move by the claimant renews its claim", function()
        local project = jj_project()
        local id = new_card(project)
        local builder = { DEV_AGENT = "dotfiles/builder" }
        must(dev(project, { "board", "move", id, support.Column.PROGRESS }, builder))
        must(dev(project, { "board", "note", id, "built and tried" }, builder))
        local short = shortened_claim(project, id)
        local fence = claim_of(project.home, id).fence
        local out, code = dev(project, { "board", "move", id, support.Column.BLOCKED }, builder)
        testing.eq(code, 0, out)
        local claim = claim_of(project.home, id)
        testing.eq(claim.fence, fence)
        testing.ok(claim.expires_at > short, claim.expires_at)
    end)

    local function lander_asked(home)
        local backend, restore = board_at(home)
        local found = false
        for _ = 1, ASK_TIMEOUT_SECONDS / ASK_POLL_SECONDS do
            for _, card in ipairs(assert(backend:cards())) do
                if card.name == turn.NAME then
                    for _, note in ipairs(assert(backend:comments(card.id))) do
                        found = found or note.body:find("ask holder=dotfiles/lander", 1, true)
                    end
                end
            end
            if found then
                break
            end
            dev_os.nap(ASK_POLL_SECONDS)
        end
        restore()
        return found
    end

    testing.test("land --wait lands once the other holder gives the turn back", function()
        local project = jj_project()
        local id = verified_card(project)
        lost_hold_taken_by_other(project, id)
        local argv = { "board", "land", id, "--wait", LONG_WAIT_SECONDS }
        local running = support.dev_async(project.root, argv, {
            env = {
                HOME = project.home,
                XDG_STATE_HOME = project.home .. "/state",
                JJ_USER = "t",
                JJ_EMAIL = "t@example.com",
                DEV_AGENT = "dotfiles/lander",
                LAND_LOG = project.log,
                LAND_MSG = "stub land",
                LAND_TRUNK = LAND_TRUNK_KEEP,
                REAL_JJ = dev_os.which("jj"),
            },
        })
        testing.ok(lander_asked(project.home), "the land never joined the line")
        testing.eq(running.finished(), false)
        must(dev(project, { "board", "turn", id, "--release" }, { DEV_AGENT = "dotfiles/other" }))
        local output, status = running.wait()
        testing.eq(status, 0, output)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test("a refused landing keeps the hold until it is released", function()
        local project = jj_project()
        local id = in_verify(project)
        must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        must(dev(project, { "board", "turn", id }))
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("No code review", 1, true), out)
        testing.ok(out:find("turn you hold for " .. id .. " stays held", 1, true), out)
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")
        out, code = dev(project, { "board", "turn", id, "--release" })
        testing.eq(code, 0, out)
        testing.eq(turn_holder(project.home), nil)
        _, code = dev(project, { "board", "turn", id, "--release" })
        testing.eq(code, 1)
    end)

    testing.test("land leaves no owner on the landed card", function()
        for _, deploys in ipairs({ "", "\n[board.land]\ndeploys = true\n" }) do
            local project = jj_project(deploys)
            local id = verified_card(project)
            local backend, restore = board_at(project.home)
            for _, card in ipairs(assert(backend:cards())) do
                if card.id:sub(1, #id) == id then
                    assert(backend:claim(card.id, "dotfiles/lander", { ttl = 3600, lease = true }))
                end
            end
            restore()
            testing.ok(claim_of(project.home, id), "the card must be claimed before the land")
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            testing.eq(claim_of(project.home, id), nil)
        end
    end)

    testing.test("land refused before the move keeps its hold", function()
        local project = jj_project()
        local id = in_verify(project)
        must(dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
        must(dev(project, { "board", "turn", id }))
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)
    end)

    testing.test("a landing refused before the turn is read says the hold is kept", function()
        local project = jj_project()
        local id = in_verify(project)
        must(dev(project, { "board", "turn", id }))
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("turn you hold for " .. id .. " stays held", 1, true), out)
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")
    end)

    testing.test("turn refuses a hold outside 1 to 3600 seconds", function()
        local project = jj_project()
        local id = in_verify(project)
        for _, bad in ipairs({ "0", "3601", "x" }) do
            local out, code = dev(project, { "board", "turn", id, "--hold", bad })
            testing.eq(code, 2, out)
        end
        local _, code = dev(project, { "board", "turn", id, "--hold", "3600" })
        testing.eq(code, 0)
    end)

    testing.test(
        "release clears a hold that ran out, and land then asks for a fresh turn",
        function()
            local project = jj_project()
            local id = in_verify(project)
            approve(project, id)
            must(dev(project, { "board", "turn", id, "--hold", "1" }))
            dev_os.nap(PAST_HOLD_SECONDS)
            local out, code = dev(project, { "board", "turn", id, "--release" })
            testing.eq(code, 0, out)
            testing.ok(out:find("was already gone", 1, true), out)
            out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
            testing.eq(code, 0, out)
            testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
        end
    )

    testing.test("turn refuses a card that is already in Done", function()
        local project = jj_project()
        local id = in_verify(project)
        approve(project, id)
        must(dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP }))
        local out, code = dev(project, { "board", "turn", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("is done", 1, true), out)
        testing.eq(turn_holder(project.home), nil)
    end)

    local function lander_ready(project)
        local id = verified_card(project)
        return id
    end

    testing.test("a land that waited keeps a hold taken meanwhile", function()
        local project = jj_project()
        local id = lander_ready(project)
        local held = hold_turn(project.home, "other", "cccc3333")
        local backend, restore = board_at(project.home)
        backend.root = project.root
        local nap = dev_os.nap
        dev_os.nap = function()
            dev_os.nap = nap
            release_turn(project.home, held)
            must(dev(project, { "board", "turn", id, "--hold", "60" }))
            must(dev(project, { "board", "move", id, support.Column.BLOCKED }))
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
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")
        local out, code = dev(project, { "board", "turn", id, "--release" })
        testing.eq(code, 0, out)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test("turn refuses a hold kept past its cap and frees the turn", function()
        -- Hold the turn on a verified card
        local project = jj_project()
        local id = in_verify(project)
        must(dev(project, { "board", "turn", id, "--hold", tostring(HELD_LEASE_SECONDS) }))

        -- Fake a clock past the cap and shorten the cap
        local backend, restore = board_at(project.home)
        backend.root = project.root
        local now, cap = store.now, turn.MAX_HOLD_SECONDS
        local later = now() + PAST_CAP_SECONDS
        store.now = function()
            return later
        end
        turn.MAX_HOLD_SECONDS = TURN_CAP_SECONDS

        -- Request the turn as the lander, then restore the fakes
        local previous = os.getenv("DEV_AGENT") or ""
        ffi.C.setenv("DEV_AGENT", "dotfiles/lander", 1)
        local ok, result =
            pcall(cmd_board.run, "turn", { id, "--hold", tostring(TURN_CAP_SECONDS) }, backend)
        ffi.C.setenv("DEV_AGENT", previous, 1)
        turn.MAX_HOLD_SECONDS = cap
        store.now = now
        restore()

        -- Refuse the request and free the turn
        assert(ok, result)
        testing.eq(result.code, 1)
        testing.ok(result.message:find("the most it may be kept", 1, true), result.message)
        testing.eq(turn_holder(project.home), nil)

        -- Let another agent take the freed turn
        local out, code = dev(project, { "board", "turn", id }, { DEV_AGENT = "dotfiles/other" })
        testing.eq(code, 0, out)
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/other")
    end)

    testing.test("a failed jj land under a hold keeps the hold with the kept line", function()
        local project = jj_project()
        local id = verified_card(project)
        must(dev(project, { "board", "turn", id }))
        local out, code = dev(
            project,
            { "board", "land", id },
            { LAND_CODE = "1", LAND_MSG = "boom" }
        )
        testing.eq(code, 1, out)
        testing.ok(out:find("boom", 1, true), out)
        testing.ok(out:find("turn you hold for " .. id .. " stays held", 1, true), out)
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("another check does not block a land", function()
        local project = jj_project()
        local landing = lander_ready(project)
        local out = dev(project, {
            "board",
            "add",
            "Other",
            "--problem",
            "x",
            "--change",
            "x",
            "--out-of-scope",
            "y",
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
        must(dev(project, { "board", "checks", other, "sh " .. slow }))
        local elsewhere = support.tempdir() .. "/other"
        jj(project.root, "workspace", "add", "--name", other, elsewhere)
        local running = support.dev_async(elsewhere, { "board", "check", other }, {
            env = {
                HOME = project.home,
                XDG_STATE_HOME = project.home .. "/state",
                JJ_USER = "t",
                JJ_EMAIL = "t@example.com",
                DEV_AGENT = "dotfiles/lander",
                LAND_LOG = project.log,
                REAL_JJ = dev_os.which("jj"),
            },
        })
        local deadline = os.time() + CHECK_WAIT_SECONDS
        while not fs.exists(started) and os.time() < deadline do
            dev_os.nap(0.1)
        end
        testing.ok(fs.exists(started), "the other card's check must be running")
        local landed, code = dev(project, { "board", "land", landing, "--wait", "0" }, {
            LAND_TRUNK = LAND_TRUNK_KEEP,
        })
        testing.eq(code, 0, landed)
        testing.eq(column_of(project.home, landing), support.COLUMN_NAME.DONE)
        testing.eq(running.finished(), false)
        assert(fs.write(stop, ""), "write failed")
        local output, status = running.wait()
        testing.eq(status, 0, output)
    end)

    local function rebased_and_checked(project, id)
        rebase_onto_trunk(project.root)
        must(dev(project, { "board", "check", id }))
    end

    testing.test("a clean rebase keeps its reviews", function()
        local project = jj_project()
        local id = review_ready(project)
        local before = head(project.root)
        trunk_moves(project, { ["lib/extra.txt"] = "extra\n" })
        rebased_and_checked(project, id)
        testing.ok(head(project.root) ~= before, "the rebase must rewrite the commit")
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        local list = comments(project.home)
        testing.eq(list[#list].kind, KIND_DONE)
        testing.eq(list[#list].body:find("carried over", 1, true), nil, list[#list].body)
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("a rebase over edits to the same file keeps its reviews", function()
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["shared.txt"] = "A\nb\nc\nd\ne\nf\ng\n" })
        rebased_and_checked(project, id)
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("a changed patch still needs a recheck", function()
        local project = jj_project()
        local id = review_ready(project)
        assert(fs.write(project.root .. "/shared.txt", "a\nb\nc\nd\ne\nf\nH\n"), "write failed")
        trunk_moves(project, { ["lib/extra.txt"] = "extra\n" })
        rebased_and_checked(project, id)
        refused(project, id, {
            "The code review is of an earlier commit",
            "The style review is of an earlier commit",
        })
    end)

    testing.test("a needs-work review of the same patch still refuses", function()
        local project = jj_project()
        local id = review_ready(project)
        must(record_review(project, id, { by = "rev2", verdict = "needs-work" }))
        trunk_moves(project, { ["lib/extra.txt"] = "extra\n" })
        rebased_and_checked(project, id)
        refused(project, id, { "The code review by rev2", "says needs-work" })
    end)

    local function central_project(extra)
        local project = jj_project(extra)
        local id = new_card(project)
        jj(project.root, "workspace", "rename", "default")
        local base = assert(fs.realpath(support.tempdir()))
        local path = base .. "/proj/" .. id
        assert(fs.mkdir(base .. "/proj", { parents = true }), "mkdir failed")
        jj(project.root, "workspace", "add", "--name", id, "-r", "master", path)
        assert(fs.write(path .. "/work.txt", "two\n"), "write failed")
        jj(path, "describe", "-m", "feat: work")
        jj(path, "bookmark", "create", id, "-r", "@")
        local inside = at_root(project, path)
        to_verify(inside, id, { DEV_WS_ROOT = base })
        approve(inside, id)
        return project, id, path, base, inside
    end

    testing.test("land removes the workspace and bookmark in a jj project", function()
        local project, id, path, base, inside = central_project()
        local out, code = dev(
            inside,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.ok(out:find("Deleted bookmark " .. id, 1, true), out)
        testing.ok(out:find("Moved " .. path, 1, true), out)
        testing.eq(fs.exists(path), false)
        testing.eq(
            jj(project.root, "bookmark", "list", "-T", 'name ++ "\\n"'):find(id, 1, true),
            nil
        )
        testing.eq(jj(project.root, "workspace", "list"):find(id .. ":", 1, true), nil)
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
    end)

    local function follow_script(project)
        local script = project.root .. "/.dev/follow.sh"
        assert(fs.write(script, '#!/bin/sh\necho "followed $PWD"\n'), "write failed")
        must(dev_os.run({ "chmod", "755", script }))
    end

    testing.test("land.runs.the.project.follow.script.on.a.board.with.no.release.column", function()
        local project, id, _, base, inside = central_project()
        follow_script(project)
        local out, code = dev(
            inside,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.ok(out:find("followed " .. project.root, 1, true), out)
    end)

    testing.test("land.leaves.a.main.checkout.with.edits.alone.and.says.why", function()
        local project, id, _, base, inside = central_project()
        local out, code = dev(
            inside,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.ok(
            out:find(project.root .. " was left alone: it has uncommitted changes.", 1, true),
            out
        )
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
    end)

    testing.test("land.skips.follow.on.a.board.with.a.release.column", function()
        local project, id, _, base, inside = central_project("\n[board.land]\ndeploys = true\n")
        follow_script(project)
        local out, code = dev(
            inside,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.eq(out:find("followed", 1, true), nil, out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("land moves the workspace off the landed change and removes it", function()
        local project, id, path, base, inside = central_project()
        local out, code = dev(
            inside,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.ok(out:find("Moved " .. path, 1, true), out)
        testing.ok(out:find("Run the next command from another folder.", 1, true), out)
        testing.eq(fs.exists(path), false)
        testing.eq(jj(project.root, "workspace", "list"):find(id .. ":", 1, true), nil)
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
    end)

    testing.test("clean up names the workspace path and the jj message when it keeps it", function()
        local _, id, path, base = central_project()
        local bin = support.tempdir()
        local script = table.concat({
            "#!/bin/sh",
            'for word in "$@"; do',
            '    if [ "$word" = forget ]; then',
            '        echo "forget refused" >&2',
            "        exit 1",
            "    fi",
            "done",
            "exec " .. assert(dev_os.which("jj")) .. ' "$@"',
            "",
        }, "\n")
        assert(fs.write(bin .. "/jj", script), "write failed")
        must(dev_os.run({ "chmod", "755", bin .. "/jj" }))
        jj(path, "bookmark", "set", "master", "-r", "@")
        jj(path, "git", "push", "--remote", "origin", "--bookmark", "master")
        local original = os.getenv("PATH")
        ffi.C.setenv("DEV_WS_ROOT", base, 1)
        ffi.C.setenv("PATH", bin .. ":" .. original, 1)
        local lines = cmd_board.clean_up(path, id)
        ffi.C.setenv("PATH", original, 1)
        ffi.C.setenv("DEV_WS_ROOT", "", 1)
        testing.ok(
            lines:find(
                "Kept the workspace. The jj command exited 1: forget refused. The workspace is at "
                    .. path
                    .. ".",
                1,
                true
            ),
            lines
        )
        testing.eq(fs.exists(path), true)
    end)

    testing.test("land keeps a workspace with uncommitted changes", function()
        local project, id, path, base, inside = central_project()
        local out, code = dev(inside, { "board", "land", id }, {
            LAND_TRUNK = LAND_TRUNK_KEEP,
            LAND_NEW = "1",
            LAND_STRAY = "stray.txt",
            DEV_WS_ROOT = base,
        })
        testing.eq(code, 0, out)
        testing.ok(out:find("Kept the workspace. " .. path .. " holds changes", 1, true), out)
        testing.eq(out:find("Run the next command", 1, true), nil, out)
        testing.eq(fs.exists(path .. "/stray.txt"), true)
        testing.ok(
            jj(project.root, "workspace", "list"):find(id .. ":", 1, true),
            "the workspace is forgotten"
        )
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
    end)

    testing.test("land removes the workspace it runs in", function()
        local project, id, path, base, inside = central_project()
        local out, code = dev(
            inside,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.ok(out:find("Run the next command from another folder.", 1, true), out)
        local list = comments(project.home, id)
        testing.eq(list[#list].kind, board.NoteKind.DONE)
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
        testing.eq(fs.exists(path), false)
    end)

    testing.test("land keeps a workspace outside the central root and says why", function()
        local project = jj_project()
        local id = verified_card(project)
        local base = assert(fs.realpath(support.tempdir()))
        local out, code = dev(
            project,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.ok(
            out:find("Kept the workspace. " .. project.root .. " is outside " .. base, 1, true),
            out
        )
        testing.eq(fs.exists(project.root), true)
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
    end)
end

testing.test("land removes the worktree and branch in a git project", function()
    local base = assert(fs.realpath(support.tempdir()))
    local root = assert(fs.realpath(support.tempdir()))
    support.git(root, "init", "-q", "-b", "master")
    support.git(root, "commit", "-q", "--allow-empty", "-m", "base")
    local path = base .. "/" .. fs.basename(root) .. "/card"
    assert(fs.mkdir(base .. "/" .. fs.basename(root), { parents = true }), "mkdir failed")
    support.git(root, "worktree", "add", "-q", "-b", "card", path)
    ffi.C.setenv("DEV_WS_ROOT", base, 1)
    local deleted, why = vcs.delete_branch(root, vcs.GIT, "card")
    testing.eq(deleted, nil)
    testing.ok(why:find("card", 1, true), why)
    local result = ws.remove(root, "card", { inside = true })
    testing.eq(result.ok, true, result.message)
    local trash = base .. "/.trash/" .. fs.basename(root) .. "/card-"
    testing.ok(result.message:find("Moved " .. path .. " to " .. trash, 1, true), result.message)
    testing.eq(fs.exists(path), false)
    testing.eq(vcs.delete_branch(root, vcs.GIT, "card"), true)
    testing.eq(vcs.delete_branch(root, vcs.GIT, "card"), false)
    assert(fs.remove(base .. "/.trash", { recursive = true }))
    support.git(root, "worktree", "add", "-q", "-b", "card", path)
    local lines = cmd_board.clean_up(path, "card")
    testing.ok(lines:find("Moved " .. path, 1, true), lines)
    testing.ok(lines:find("Deleted branch card", 1, true), lines)
    testing.eq(fs.exists(path), false)
    ffi.C.setenv("DEV_WS_ROOT", "", 1)
end)

local function git_dev(project, args, extra)
    local env = {}
    for name, value in pairs(support.GIT_IDENT) do
        env[name] = value
    end
    for name, value in pairs(extra or {}) do
        env[name] = value
    end
    return dev(project, args, env)
end

local function git_project(extra)
    local project = setup(extra)
    local root = project.root
    project.bare = support.tempdir()
    must(
        dev_os.run(
            { "git", "init", "--bare", "-q", "-b", "master", project.bare },
            { stdout = "null" }
        )
    )
    must(dev_os.run({ "git", "init", "-q", "-b", "master", root }, { stdout = "null" }))
    support.git(root, "remote", "add", "origin", project.bare)
    project.id = new_card(project)
    support.git(root, "add", "-A")
    support.git(root, "commit", "-q", "-m", "base")
    support.git(root, "push", "-q", "origin", "master")
    support.git(root, "checkout", "-q", "-b", "work")
    assert(fs.write(root .. "/work.txt", "one\n"), "write failed")
    support.git(root, "add", "-A")
    support.git(root, "commit", "-q", "-m", "feat: work")
    return project
end

local function git_approve(project)
    local id = project.id
    local builder = { DEV_AGENT = "dotfiles/builder" }
    must(support.to_review(function(args)
        return git_dev(project, args, builder)
    end, id))
    must(git_dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
    for _, kind in ipairs({ "code", "style" }) do
        must(record_review(project, id, { kind = kind, rev = "HEAD", run = git_dev }))
    end
    must(git_dev(project, { "board", "check", id }))
    must(git_dev(project, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
end

local function git_trunk_moves(project, name, text)
    local clone = assert(fs.realpath(support.tempdir())) .. "/clone"
    must(dev_os.run({ "git", "clone", "-q", project.bare, clone }, { stdout = "null" }))
    assert(fs.write(clone .. "/" .. name, text), "write failed")
    support.git(clone, "add", "-A")
    support.git(clone, "commit", "-q", "-m", "trunk moves")
    support.git(clone, "push", "-q", "origin", "master")
end

local function git_rev(dir, rev)
    local out = dev_os.capture({ "git", "-C", dir, "rev-parse", rev })
    return out:match("^(%x+)")
end

local function git_remote_master(project)
    return git_rev(project.bare, "refs/heads/master")
end

testing.test(
    "land.git.a rerun of land finishes a card whose commit already reached trunk",
    function()
        local project = git_project()
        local id = project.id
        git_approve(project)
        local landed = git_rev(project.root, "HEAD")
        support.git(project.root, "push", "-q", "origin", "HEAD:master")
        local out, code = git_dev(project, { "board", "land", id })
        testing.eq(code, 0, out)
        testing.ok(out:find("settled " .. id, 1, true), out)
        testing.eq(git_remote_master(project), landed)
        local list = comments(project.home, id)
        local note = list[#list]
        testing.eq(note.kind, board.NoteKind.DONE)
        testing.ok(note.body:find("Landed commit " .. landed:sub(1, 12), 1, true), note.body)
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
    end
)

testing.test("land.git.lands rebases a card onto fetched trunk and pushes it", function()
    local project = git_project()
    local id = project.id
    git_approve(project)
    git_trunk_moves(project, "other.txt", "other\n")
    local trunk = git_remote_master(project)
    local out, code = git_dev(project, { "board", "land", id })
    testing.eq(code, 0, out)
    testing.ok(out:find("landed " .. id, 1, true), out)
    local landed = git_rev(project.root, "HEAD")
    testing.eq(git_remote_master(project), landed)
    testing.eq(git_rev(project.root, "HEAD~1"), trunk)
    local list = comments(project.home, id)
    local note = list[#list]
    testing.eq(note.kind, board.NoteKind.DONE)
    testing.ok(note.body:find("Landed commit " .. landed:sub(1, 12), 1, true), note.body)
    testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
end)

testing.test("land.git.recheck reruns trunk's rows when the change empties its own", function()
    local marker = support.tempdir() .. "/rechecked"
    local project = git_project('\n[board.land]\nrecheck = ["touch ' .. marker .. '"]\n')
    local id = project.id
    assert(fs.write(project.root .. "/.dev/config.toml", NARROWED), "write failed")
    support.git(project.root, "add", "-A")
    support.git(project.root, "commit", "-q", "--amend", "--no-edit")
    git_approve(project)
    git_trunk_moves(
        project,
        ".dev/config.toml",
        '[board]\nbackend = "local"\nname = "mine"\n# t\n[board.land]\nrecheck = ["touch '
            .. marker
            .. '"]\n'
    )
    local out, code = git_dev(project, { "board", "land", id })
    testing.eq(code, 0, out)
    testing.ok(fs.is_file(marker), "trunk's recheck row never ran")
end)

testing.test("land.git.recheck skips the rows when the patch is unchanged", function()
    local marker = support.tempdir() .. "/rechecked"
    local project = git_project('\n[board.land]\nrecheck = ["touch ' .. marker .. '"]\n')
    local id = project.id
    git_approve(project)
    git_trunk_moves(project, "other.txt", "other\n")
    local out, code = git_dev(project, { "board", "land", id })
    testing.eq(code, 0, out)
    testing.ok(not fs.is_file(marker), "the recheck row ran")
    testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
end)

testing.test("land.git.refused names a failed fetch or rebase and keeps the card", function()
    local project = git_project()
    local id = project.id
    git_approve(project)
    local before = git_rev(project.root, "HEAD")
    git_trunk_moves(project, "work.txt", "other\n")
    local trunk = git_remote_master(project)
    local out, code = git_dev(project, { "board", "land", id })
    testing.eq(code, 1, out)
    testing.ok(out:find("The rebase onto trunk failed", 1, true), out)
    testing.eq(git_rev(project.root, "HEAD"), before)
    testing.eq(git_remote_master(project), trunk)
    testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)
    support.git(project.root, "remote", "set-url", "origin", project.bare .. "/missing")
    out, code = git_dev(project, { "board", "land", id })
    testing.eq(code, 1, out)
    testing.ok(out:find("The fetch from origin failed", 1, true), out)
    testing.eq(git_remote_master(project), trunk)
    testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)
end)

local function linked_worktree(prepare)
    local project = git_project()
    local id = project.id
    local main = project.root
    support.git(main, "checkout", "-q", "master")
    local base = assert(fs.realpath(support.tempdir()))
    local folder = base .. "/" .. fs.basename(main)
    local path = folder .. "/" .. id
    assert(fs.mkdir(folder, { parents = true }), "mkdir failed")
    support.git(main, "worktree", "add", "-q", "-b", id, path, "work")
    if prepare then
        prepare(main, folder, path)
    end
    local tree = at_root(project, path)
    tree.id = id
    git_approve(tree)
    return project, tree, base, path
end

testing.test("land.git.worktree lands a linked worktree and removes it", function()
    local project, tree, base, path = linked_worktree()
    local id = project.id
    local landed = git_rev(path, "HEAD")
    local out, code = git_dev(tree, { "board", "land", id }, { DEV_WS_ROOT = base })
    testing.eq(code, 0, out)
    testing.ok(out:find("Moved " .. path, 1, true), out)
    testing.ok(out:find("Deleted branch " .. id, 1, true), out)
    testing.eq(fs.exists(path), false)
    testing.eq(git_remote_master(project), landed)
    testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
end)

local function land_kept_worktree(prepare)
    local project, tree, base, path = linked_worktree(prepare)
    local id = project.id
    local landed = git_rev(path, "HEAD")
    local out, code = git_dev(tree, { "board", "land", id }, { DEV_WS_ROOT = base })
    testing.eq(code, 0, out)
    testing.eq(fs.exists(path), true)
    testing.eq(out:find("The workspace is gone", 1, true), nil, out)
    testing.eq(git_remote_master(project), landed)
    testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
    return out, path
end

testing.test("land.git.worktree.keeps.a.locked worktree and says why", function()
    local out, path = land_kept_worktree(function(main, _, tree)
        support.git(main, "worktree", "lock", tree)
    end)
    local reason = path .. " is a locked git worktree. Run git worktree unlock first."
    testing.ok(out:find("Kept the workspace. " .. reason, 1, true), out)
end)

testing.test("land.test.card.lookup.fails.naming.an.id that matches no card", function()
    local doc = { cards = { { id = "abc123", name = "Card" } } }
    testing.eq(board_card(doc, "abc").id, "abc123")
    testing.raises(function()
        board_card(doc, "zzz999")
    end, "no card starts with zzz999")
end)

testing.test("land.git.worktree.keeps.one.beside.a.prunable sibling and says why", function()
    local sibling
    local out = land_kept_worktree(function(main, folder)
        sibling = folder .. "/sibling"
        support.git(main, "worktree", "add", "-q", "-b", "sibling", sibling, "work")
        assert(fs.remove(sibling, { recursive = true }))
    end)
    local reason = "Git worktree prune would also drop the record of "
        .. sibling
        .. ", which git marks prunable. Run git worktree prune first."
    testing.ok(out:find("Kept the workspace. " .. reason, 1, true), out)
end)
