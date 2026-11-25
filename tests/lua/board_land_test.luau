local testing = require("@dev/testing")
local board = require("@dev/board")
local check = require("@dev/board/check")
local cmd_board = require("@dev/cmd/board")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local json = require("@dev/json")
local land = require("@dev/board/land")
local localboard = require("@dev/board/localboard")
local review = require("@dev/board/review")
local store = require("@dev/board/store")
local support = require("./support")
local turn = require("@dev/board/turn")
local vcs = require("@dev/vcs")
local wiring = require("@dev/board/wiring")
local ws = require("@dev/cmd/ws")

local has_jj = dev_os.which("jj") ~= nil
local IDENT = { JJ_USER = "t", JJ_EMAIL = "t@example.com" }
local LAND_STUB = table.concat({
    "#!/bin/sh",
    'for word in "$@"; do',
    '    if [ -n "$LOG_FAIL_AT" ] && [ "$word" = "$LOG_FAIL_AT" ]; then',
    "        exit 1",
    "    fi",
    '    case "$word" in',
    "    *bare*)",
    '        if [ -n "$SHAPE_FAIL" ]; then',
    "            exit 1",
    "        fi",
    "        ;;",
    "    interdiff)",
    '        if [ -n "$INTERDIFF_FAIL" ]; then',
    "            exit 1",
    "        fi",
    '        if [ -n "$INTERDIFF_FAIL_AT" ]; then',
    '            case "$*" in',
    '            *"$INTERDIFF_FAIL_AT"*) exit 1 ;;',
    "            esac",
    "        fi",
    "        ;;",
    '    "heads((::"*"& ::@-")',
    '        if [ -n "$ANCESTOR_FAIL_AT" ]; then',
    '            case "$word" in',
    '            "heads((::$ANCESTOR_FAIL_AT-)"*) exit 1 ;;',
    "            esac",
    "        fi",
    "        ;;",
    '    "heads((::"*)',
    '        if [ -n "$PARENT_FAIL_AT" ]; then',
    '            case "$word" in',
    '            "heads((::$PARENT_FAIL_AT-)"*) exit 1 ;;',
    "            esac",
    "        fi",
    "        ;;",
    "    fetch)",
    '        if [ -n "$FETCH_LOG" ]; then',
    '            echo fetch >>"$FETCH_LOG"',
    "        fi",
    '        if [ -n "$FETCH_SKIP" ]; then',
    "            exit 0",
    "        fi",
    '        if [ -n "$FETCH_REFUSALS" ]; then',
    '            count=$(cat "$FETCH_COUNT" 2>/dev/null || echo 0)',
    '            if [ "$count" -lt "$FETCH_REFUSALS" ]; then',
    '                echo $((count + 1)) >"$FETCH_COUNT"',
    '                echo "agent refused operation"',
    "                exit 1",
    "            fi",
    "        fi",
    '        if [ -n "$FETCH_HANG" ]; then',
    "            exec sleep 30",
    "        fi",
    '        if [ -n "$FETCH_FAIL" ] && [ -s "$LAND_LOG" ]; then',
    '            echo "fetch refused"',
    "            exit 1",
    "        fi",
    "        ;;",
    "    esac",
    '    if [ "$word" = land ]; then',
    '        echo "$* DEV_BOARD_LAND=${DEV_BOARD_LAND:-unset}" >>"$LAND_LOG"',
    '        if [ -n "$BREAK_BOARD" ]; then',
    "            printf '{' >\"$BREAK_BOARD\"",
    "        fi",
    '        if [ "$LAND_TRUNK" = rewrite ]; then',
    '            "$REAL_JJ" describe -m "feat: work, rewritten" >/dev/null 2>&1',
    "        fi",
    '        if [ -n "$LAND_TRUNK" ]; then',
    '            "$REAL_JJ" bookmark set master -r @ >/dev/null 2>&1',
    '            "$REAL_JJ" git push --remote origin --bookmark master >/dev/null 2>&1',
    "        fi",
    '        if [ -n "$LAND_NEW" ]; then',
    '            "$REAL_JJ" new >/dev/null 2>&1',
    "        fi",
    '        if [ -n "$LAND_STRAY" ]; then',
    '            echo stray >"$LAND_STRAY"',
    "        fi",
    '        echo "$LAND_MSG"',
    '        exit "${LAND_CODE:-0}"',
    "    fi",
    "done",
    'exec "$REAL_JJ" "$@"',
    "",
}, "\n")
local LAND_TRUNK_KEEP = "keep"
local LAND_TRUNK_REWRITE = "rewrite"
local KIND_DONE = "done"
local COMMIT = ("a"):rep(40)
local OTHER = ("b"):rep(40)
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
local SHARED = table.concat({ "a", "b", "c", "d", "e", "f", "g", "" }, "\n")
local NEAR_EDIT = table.concat({ "a", "b", "c", "D", "e", "f", "g", "" }, "\n")
local FIRST_EDIT = table.concat({ "A", "b", "c", "d", "e", "f", "g", "" }, "\n")
local LAST_EDIT = table.concat({ "a", "b", "c", "d", "e", "f", "G", "" }, "\n")
local LAST_OTHER = table.concat({ "a", "b", "c", "d", "e", "f", "H", "" }, "\n")
local LAST_CLASH = table.concat({ "a", "b", "c", "d", "e", "f", "X", "" }, "\n")
local LAST_ODD = table.concat({ "a", "b", "c", "d", "e", "f", "Z", "" }, "\n")
local DEPLOYS_CONFIG = table.concat({ "", "[board.land]", "deploys = true", "" }, "\n")
local NARROWED = table.concat({
    "[board]",
    'backend = "local"',
    'name = "mine"',
    "",
    "[board.land]",
    "recheck = []",
    "",
}, "\n")

local function setup(extra)
    -- Build a sandbox whose board is a local one
    local root = support.sandbox({
        [".dev/config.toml"] = table.concat({
            "[board]",
            'backend = "local"',
            'name = "mine"',
            "",
        }, "\n") .. (extra or ""),
    }, {})

    -- Give the run a home with an empty user config
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    assert(fs.write(home .. "/.config/dev/config.toml", ""), "write failed")

    -- Hand back the paths a test works with
    return { root = root, home = home, log = support.tempdir() .. "/land.log" }
end

local function must(first, second)
    local code = type(first) == "number" and first or second
    assert(code == 0, tostring(first))
end

local function checked(commit, mode, rows)
    -- Split each row into its numbered line and its command
    local lines, commands = {}, {}
    for i, row in ipairs(rows) do
        local result, run_id, command = row:match("^([%a-]+) (%S+) (.+)$")
        lines[i] = i .. " " .. result .. " " .. run_id
        commands[i] = command
    end

    -- Fingerprint the commands into the record head
    local head = string.format(
        "dev-check: commit=%s change=chg mode=%s rows=%d sum=%s",
        commit,
        mode,
        #rows,
        check.fingerprint(commands)
    )

    -- Join the head and the rows into one comment body
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
    -- Write a record and parse it back
    local rows = {
        { run_id = "8cb600", run = "dev lint", result = "pass", code = 0, tail = "" },
        { run_id = "-", run = "dev test", result = "fail", code = 1, tail = "" },
    }
    local record = check.parse(check.record(STATE, rows, true))

    -- Read every field of the record back
    testing.eq(record.commit, COMMIT)
    testing.eq(record.change, "chg")
    testing.eq(record.mode, check.Mode.EXPECT_FAIL)
    testing.eq(record.rows, {
        { run_id = "8cb600", result = "pass" },
        { run_id = "-", result = "fail" },
    })
    testing.eq(record.sum, check.fingerprint({ "dev lint", "dev test" }))

    -- Refuse text that is not a well-formed record
    local head = "dev-check: commit=aa change=c mode=run rows="
    testing.eq(check.parse("a note"), nil)
    testing.eq(check.parse("dev-check: commit=zz change=c mode=run rows=0 sum=ab"), nil)
    testing.eq(check.parse(table.concat({ head .. "1 sum=ab", "2 pass x" }, "\n")), nil)
    testing.eq(check.parse(table.concat({ head .. "1 sum=ab", "1 pass dev lint" }, "\n")), nil)
    testing.eq(check.parse(table.concat({ head .. "2 sum=ab", "1 pass 8cb600" }, "\n")), nil)
end)

testing.test("land reads a short check record and refuses rows that changed", function()
    -- Accept a record whose rows match the configured ones
    local rows = { "dev lint", "dev test" }
    local pass = checked(COMMIT, check.Mode.RUN, { "pass 8cb600 dev lint", "pass 1f2e3d dev test" })
    testing.eq(land.checks_problem({ pass }, STATE, rows), nil)

    -- Refuse a record once a row's command changed
    local problem = land.checks_problem({ pass }, STATE, { "dev lint", "dev other" })
    testing.ok(problem:find("checks rows changed", 1, true), problem)
    testing.ok(problem:find("Run `dev board check` again", 1, true), problem)

    -- Refuse a record once the rows swap order
    local swapped = land.checks_problem({ pass }, STATE, { "dev test", "dev lint" })
    testing.ok(swapped:find("checks rows changed", 1, true), swapped)
end)

testing.test("land accepts a not-run row and still refuses a failed one", function()
    local rows = { "dev lint", "dev test" }
    local skipped =
        checked(COMMIT, check.Mode.RUN, { "pass 8cb600 dev lint", "not-run - dev test" })
    testing.eq(land.checks_problem({ skipped }, STATE, rows), nil)
    local failed = checked(COMMIT, check.Mode.RUN, { "not-run - dev lint", "fail 1f2e3d dev test" })
    local problem = land.checks_problem({ failed }, STATE, rows)
    testing.ok(problem:find("Row 2, `dev test`, ended with fail.", 1, true), problem)
end)

testing.test("an old check record is refused with a rerun sentence", function()
    local old = {
        body = table.concat({
            "dev-check: commit=" .. COMMIT .. " change=chg mode=run",
            "1 pass 8cb600 dev lint",
        }, "\n"),
    }
    local problem = land.checks_problem({ old }, STATE, { "dev lint" })
    testing.ok(problem:find("could not be read", 1, true), problem)
    testing.ok(problem:find("Run `dev board check` again.", 1, true), problem)
end)

testing.test("carry reads a short check record as the commit's own and does not carry", function()
    -- Record a passing check at the commit
    local pass = checked(COMMIT, check.Mode.RUN, { "pass 8cb600 dev lint" })

    -- Gather the comments carry reads, with both reviews present
    local opts = {
        root = "/nonexistent",
        comments = { pass, reviewed("code", COMMIT), reviewed("style", COMMIT) },
        state = STATE,
        rows = { "dev lint" },
    }

    -- Read the record as the commit's own and carry nothing
    testing.eq(check.parse(pass.body).commit, COMMIT)
    testing.eq({ land.carry(opts) }, {})
end)

testing.test("review.parse reads what review.record wrote and nothing else", function()
    -- Write a review with a verdict and parse it back
    local text = review.record("style", "rev1", { commit = COMMIT, change = "chg" }, "minor")
    testing.eq(
        review.parse(text),
        { kind = "style", by = "rev1", commit = COMMIT, change = "chg", verdict = "minor" }
    )

    -- Read a review that carries no verdict
    testing.eq(
        review.parse("dev-review: kind=code by=r commit=" .. COMMIT .. " change=chg"),
        { kind = "code", by = "r", commit = COMMIT, change = "chg" }
    )

    -- Refuse text that is not a whole review
    testing.eq(review.parse("dev-review: kind=style"), nil)
    testing.eq(review.parse("a note"), nil)
end)

testing.test("missing_reviews wants a code and a style review of the change", function()
    -- Want nothing once both reviews are in
    testing.eq(
        land.missing_reviews({ reviewed("code", COMMIT), reviewed("style", COMMIT) }, STATE),
        {}
    )

    -- Name the one review that is missing
    local missing = land.missing_reviews({ reviewed("code", COMMIT) }, STATE)
    testing.eq(#missing, 1)
    testing.ok(missing[1]:find("No style review", 1, true), missing[1])

    -- Want both reviews when none exist
    testing.eq(#land.missing_reviews({}, STATE), 2)

    -- Want both reviews again when they belong to another change
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
    -- Refuse nothing for a clean, minor or verdictless review
    local clean = judged("code", COMMIT, { by = "r1", verdict = "clean" })
    testing.eq(land.refused_reviews({ clean }, STATE), {})
    local minor = judged("style", COMMIT, { by = "r2", verdict = "minor" })
    testing.eq(land.refused_reviews({ minor }, STATE), {})
    testing.eq(land.refused_reviews({ reviewed("code", COMMIT) }, STATE), {})

    -- Name the reviewer of a style review that needs work
    local style_needs = judged("style", COMMIT, { by = "r2", verdict = "needs-work" })
    local refused = land.refused_reviews({ style_needs }, STATE)
    testing.eq(#refused, 1)
    testing.ok(refused[1]:find("style review by r2", 1, true), refused[1])
    testing.ok(refused[1]:find("needs-work", 1, true), refused[1])

    -- Name the reviewer of a recheck that needs work
    local recheck = judged("recheck", COMMIT, { by = "r3", verdict = "needs-work", of = "code" })
    refused = land.refused_reviews({ recheck }, STATE)
    testing.ok(refused[1]:find("recheck review by r3", 1, true), refused[1])

    -- Let a later clean review lift an earlier refusal
    local code_needs = judged("code", COMMIT, { by = "r1", verdict = "needs-work" })
    local code_clean = judged("code", COMMIT, { by = "r4", verdict = "clean" })
    testing.eq(land.refused_reviews({ code_needs, code_clean }, STATE), {})

    -- Ignore a refusal recorded at another commit
    local other = judged("code", OTHER, { by = "r1", verdict = "needs-work" })
    testing.eq(land.refused_reviews({ other }, STATE), {})
end)

testing.test("a review of an earlier commit needs a recheck at the landing commit", function()
    -- Want a recheck for reviews of an earlier commit
    local old = { reviewed("code", OTHER), reviewed("style", OTHER) }
    local missing = land.missing_reviews(old, STATE)
    testing.eq(#missing, 2)
    testing.ok(missing[1]:find("earlier commit", 1, true), missing[1])

    -- Ignore a recheck made at that earlier commit
    old[#old + 1] = reviewed("recheck", OTHER, "code")
    testing.eq(#land.missing_reviews(old, STATE), 2)

    -- Accept rechecks made at the landing commit
    old[#old + 1] = reviewed("recheck", COMMIT, "code")
    old[#old + 1] = reviewed("recheck", COMMIT, "style")
    testing.eq(land.missing_reviews(old, STATE), {})
end)

testing.test("missing_reviews counts a recheck only for the kind it names", function()
    -- Count a recheck for the kind it names and still want the other
    local old = { reviewed("code", OTHER), reviewed("style", OTHER) }
    old[#old + 1] = reviewed("recheck", COMMIT, "code")
    local missing = land.missing_reviews(old, STATE)
    testing.eq(#missing, 1)
    testing.ok(missing[1]:find("The style review is of an earlier commit", 1, true), missing[1])
    testing.ok(missing[1]:find("--kind recheck --of style", 1, true), missing[1])

    -- Count a recheck without a kind toward neither
    local bare = { reviewed("code", OTHER), reviewed("style", OTHER), reviewed("recheck", COMMIT) }
    testing.eq(#land.missing_reviews(bare, STATE), 2)

    -- Refuse on a recheck of one kind that needs work
    local lifted = { judged("recheck", COMMIT, { by = "r", verdict = "needs-work", of = "style" }) }
    lifted[#lifted + 1] = judged("recheck", COMMIT, { by = "r", verdict = "clean", of = "code" })
    local refused = land.refused_reviews(lifted, STATE)
    testing.eq(#refused, 1)
    testing.ok(refused[1]:find("recheck review by r", 1, true), refused[1])
end)

local function on_credential(who, comment)
    comment.who = who
    return comment
end

local function claimed_by(who, name)
    return { who = who, body = "dev-claim: by=" .. name }
end

local function with_reviewer_token(set, run)
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    local text = set and table.concat({ "[board.pomb]", 'reviewer_token = "t"', "" }, "\n") or ""
    assert(fs.write(home .. "/.config/dev/config.toml", text), "write failed")
    local previous = dev_os.getenv("HOME")
    dev_os.setenv("HOME", home)
    local ok, err = pcall(run)
    dev_os.setenv("HOME", previous)
    assert(ok, err)
end

testing.test("land refuses a review recorded on the claimant's credential", function()
    -- Record a claim and a review on the claimant's own credential
    local comments = {
        claimed_by("runner-token", "dotfiles/implementer/c1"),
        on_credential("runner-token", reviewed("code", COMMIT)),
    }

    -- Find the review that shares the claimant's credential
    testing.eq(
        land.shared_credentials(comments, STATE),
        { { kind = "code", by = "r", claimant = "dotfiles/implementer/c1" } }
    )

    -- Turn the shared review into a landing problem once a reviewer token is set
    with_reviewer_token(true, function()
        local problems = wiring.credential_problems(comments, STATE)
        testing.eq(#problems, 1)
        testing.eq(
            problems[1],
            "The code review by r was recorded on the credential of dotfiles/implementer/c1, "
                .. "which claimed the card. Record a new code review from a reviewer credential, "
                .. "which a reviewer holds only when its agent name has the form "
                .. string.format(
                    "PROJECT/SEAT-reviewer/CARD (for example PROJECT/%s-reviewer/CARD).",
                    "code"
                )
        )
    end)
end)

testing.test("the credential refusal names the kind to record again", function()
    local comments = {
        claimed_by("runner-token", "dotfiles/implementer/c1"),
        on_credential("runner-token", reviewed("style", COMMIT)),
    }
    with_reviewer_token(true, function()
        local problems = wiring.credential_problems(comments, STATE)
        testing.eq(#problems, 1)
        testing.ok(problems[1]:find("Record a new style review", 1, true), problems[1])
        testing.ok(problems[1]:find("for example PROJECT/style-", 1, true), problems[1])
    end)
end)

testing.test("land accepts a review recorded on another credential", function()
    -- Record a claim and a review on a credential other than the claimant's
    local comments = {
        claimed_by("runner-token", "dotfiles/implementer/c1"),
        on_credential("reviewer-token", reviewed("code", COMMIT)),
        reviewed("style", COMMIT),
    }

    -- Find no review that shares the claimant's credential
    testing.eq(land.shared_credentials(comments, STATE), {})

    -- Raise no landing problem once a reviewer token is set
    with_reviewer_token(true, function()
        testing.eq(wiring.credential_problems(comments, STATE), {})
    end)
end)

testing.test(
    "an older shared review clears once a fresh review lands on another credential",
    function()
        -- Record a shared review and then a fresh one on another credential
        local comments = {
            claimed_by("runner-token", "dotfiles/implementer/c1"),
            on_credential("runner-token", reviewed("code", COMMIT)),
            on_credential("reviewer-token", reviewed("code", COMMIT)),
            reviewed("style", COMMIT),
        }

        -- Find no review that still shares the claimant's credential
        testing.eq(land.shared_credentials(comments, STATE), {})

        -- Raise no landing problem once a reviewer token is set
        with_reviewer_token(true, function()
            testing.eq(wiring.credential_problems(comments, STATE), {})
        end)
    end
)

testing.test("a.newer.review.under.another.name.clears.a.shared.one", function()
    -- Record a shared review and a newer one under another name and credential
    local comments = {
        claimed_by("runner-token", "dotfiles/implementer/c1"),
        on_credential("runner-token", judged("code", COMMIT, { by = "old", verdict = "clean" })),
        on_credential("reviewer-token", judged("code", COMMIT, { by = "new", verdict = "clean" })),
        reviewed("style", COMMIT),
    }

    -- Find no review that still shares the claimant's credential
    testing.eq(land.shared_credentials(comments, STATE), {})

    -- Raise no landing problem once a reviewer token is set
    with_reviewer_token(true, function()
        testing.eq(wiring.credential_problems(comments, STATE), {})
    end)
end)

testing.test("land refuses when the newest review shares the claimant credential", function()
    -- Record an own-credential review newer than the other credential's one
    local comments = {
        claimed_by("runner-token", "dotfiles/implementer/c1"),
        on_credential("reviewer-token", reviewed("code", COMMIT)),
        on_credential("runner-token", reviewed("code", COMMIT)),
        reviewed("style", COMMIT),
    }

    -- Find the newest review sharing the claimant's credential
    testing.eq(
        land.shared_credentials(comments, STATE),
        { { kind = "code", by = "r", claimant = "dotfiles/implementer/c1" } }
    )

    -- Turn it into a landing problem once a reviewer token is set
    with_reviewer_token(true, function()
        testing.eq(#wiring.credential_problems(comments, STATE), 1)
    end)
end)

testing.test("a fresh recheck of one kind does not clear a shared recheck of the other", function()
    local comments = {
        claimed_by("runner-token", "dotfiles/implementer/c1"),
        on_credential("runner-token", reviewed("recheck", COMMIT, "style")),
        on_credential("reviewer-token", reviewed("recheck", COMMIT, "code")),
    }
    testing.eq(
        land.shared_credentials(comments, STATE),
        { { kind = "recheck", by = "r", claimant = "dotfiles/implementer/c1" } }
    )
end)

testing.test("land skips the credential check when no reviewer token is set", function()
    local comments = {
        claimed_by("runner-token", "dotfiles/implementer/c1"),
        on_credential("runner-token", reviewed("code", COMMIT)),
    }
    with_reviewer_token(false, function()
        testing.eq(wiring.credential_problems(comments, STATE), {})
    end)
end)

local function seat(name, verdict, revision, holder)
    return {
        name = name,
        role = "reviewer",
        verdict = verdict,
        revision = revision,
        holder = holder,
    }
end

local function with_seats(seats)
    return {
        seats = function()
            return seats
        end,
    }
end

local function seat_opts(carried, comments)
    return { carried = carried, comments = comments or {} }
end

testing.test("land.refuses.a.seat.still.waiting", function()
    local problems = land.seats_problem({ seat("code", nil, nil, "r") }, COMMIT, seat_opts())
    testing.eq(problems, { "The reviewer seat code has not answered." })
    local style = with_seats({ seat("style", nil, nil, "r") })
    testing.eq(wiring.seat_problems(style, { id = "c" }, STATE, seat_opts()), {
        "The reviewer seat style has not answered.",
    })
end)

testing.test("an.open.seat.asks.nothing", function()
    local open = with_seats({ seat("code") })
    testing.eq(land.seats_problem({ seat("code") }, COMMIT, seat_opts()), {})
    testing.eq(wiring.seat_problems(open, { id = "c" }, STATE, seat_opts()), {})
end)

testing.test("a.working.seat.has.not.answered", function()
    local problems = land.seats_problem({ seat("code", nil, nil, "r") }, COMMIT, seat_opts())
    testing.eq(problems, { "The reviewer seat code has not answered." })
end)

testing.test("a.reasked.seat.has.not.answered", function()
    local reasked = seat("code", nil, OTHER, "r")
    testing.eq(
        land.seats_problem({ reasked }, COMMIT, seat_opts(OTHER)),
        { "The reviewer seat code has not answered." }
    )
    testing.eq(
        wiring.seat_problems(with_seats({ reasked }), { id = "c" }, STATE, seat_opts(OTHER)),
        { "The reviewer seat code has not answered." }
    )
end)

testing.test("land.refuses.a.seat.that.asks.for.changes", function()
    local problems = land.seats_problem(
        { seat("code", review.SeatVerdict.CHANGES_NEEDED, COMMIT) },
        COMMIT,
        seat_opts()
    )
    testing.eq(problems, { "The reviewer seat code asks for changes." })
end)

testing.test("land.refuses.an.approval.of.an.older.revision", function()
    local problems = land.seats_problem(
        { seat("code", review.SeatVerdict.APPROVED, OTHER) },
        COMMIT,
        seat_opts()
    )
    testing.eq(problems, {
        "The reviewer seat code approved commit "
            .. land.short(OTHER)
            .. ", not the commit "
            .. land.short(COMMIT)
            .. " that would land.",
    })
    testing.eq(
        #land.seats_problem({ seat("code", review.SeatVerdict.APPROVED) }, COMMIT, seat_opts()),
        1
    )
end)

testing.test("land.lands.when.every.seat.approved.the.revision", function()
    -- Seat a reviewer that approved the commit and one that approved the carried one
    local seats = {
        seat("code", review.SeatVerdict.APPROVED, COMMIT),
        seat("style", review.SeatVerdict.APPROVED, OTHER),
        seat("recheck"),
    }

    -- Find no problem when the land module reads the seats
    testing.eq(land.seats_problem(seats, COMMIT, seat_opts(OTHER)), {})

    -- Find no problem when the wiring reads the seats
    testing.eq(wiring.seat_problems(with_seats(seats), { id = "c" }, STATE, seat_opts(OTHER)), {})
end)

testing.test("land.asks.nothing.of.a.card.without.seats", function()
    testing.eq(land.seats_problem({}, COMMIT, seat_opts()), {})
    testing.eq(wiring.seat_problems(with_seats({}), { id = "c" }, STATE, seat_opts()), {})
    testing.eq(wiring.seat_problems({}, { id = "c" }, STATE, seat_opts()), {})
end)

testing.test("land.names.a.failed.seat.read", function()
    local backend = {
        seats = function()
            return nil, "pomb answered 500"
        end,
    }
    testing.eq(wiring.seat_problems(backend, { id = "c" }, STATE, seat_opts()), {
        "The card's seats could not be read: pomb answered 500",
    })
end)

local function rechecked_as(of, commit, verdict)
    return {
        body = review.record(
            review.Kind.RECHECK,
            "r",
            { commit = commit, change = "chg" },
            verdict,
            of
        ),
    }
end

testing.test("land.accepts.a.seat.a.recheck.covers", function()
    -- Seat reviewers that answered at an older commit
    local seats = {
        seat(review.Kind.CODE, review.SeatVerdict.APPROVED, OTHER),
        seat(review.Kind.STYLE, review.SeatVerdict.CHANGES_NEEDED, OTHER),
    }

    -- Recheck both kinds at the landing commit
    local comments = {
        rechecked_as(review.Kind.CODE, COMMIT, review.Verdict.CLEAN),
        rechecked_as(review.Kind.STYLE, COMMIT, review.Verdict.MINOR),
    }

    -- Find the rechecks cover both seats
    testing.eq(land.seats_problem(seats, COMMIT, seat_opts(nil, comments)), {})
end)

testing.test("land.takes.the.newest.recheck.of.a.kind", function()
    -- Seat a reviewer that answered at an older commit
    local seats = { seat(review.Kind.CODE, review.SeatVerdict.APPROVED, OTHER) }

    -- Recheck the kind clean and then needing work
    local comments = {
        rechecked_as(review.Kind.CODE, COMMIT, review.Verdict.CLEAN),
        rechecked_as(review.Kind.CODE, COMMIT, review.Verdict.NEEDS_WORK),
    }

    -- Find the seat stale because the newest recheck wins
    testing.eq(land.seats_problem(seats, COMMIT, seat_opts(nil, comments)), {
        "The reviewer seat code approved commit "
            .. land.short(OTHER)
            .. ", not the commit "
            .. land.short(COMMIT)
            .. " that would land.",
    })
end)

testing.test("land.refuses.a.recheck.that.cannot.cover.a.seat", function()
    -- Seat an approval at an older commit and word the stale problem
    local approved = seat(review.Kind.CODE, review.SeatVerdict.APPROVED, OTHER)
    local stale = "The reviewer seat code approved commit "
        .. land.short(OTHER)
        .. ", not the commit "
        .. land.short(COMMIT)
        .. " that would land."

    -- Refuse a recheck that needs work
    testing.eq(
        land.seats_problem(
            { approved },
            COMMIT,
            seat_opts(nil, { rechecked_as(review.Kind.CODE, COMMIT, review.Verdict.NEEDS_WORK) })
        ),
        { stale }
    )

    -- Refuse a recheck of another kind
    testing.eq(
        land.seats_problem(
            { approved },
            COMMIT,
            seat_opts(nil, { rechecked_as(review.Kind.STYLE, COMMIT, review.Verdict.CLEAN) })
        ),
        { stale }
    )

    -- Refuse a recheck made at the older commit
    testing.eq(
        land.seats_problem(
            { approved },
            COMMIT,
            seat_opts(nil, { rechecked_as(review.Kind.CODE, OTHER, review.Verdict.CLEAN) })
        ),
        { stale }
    )

    -- Keep a changes-requested seat refused despite a clean recheck
    testing.eq(
        land.seats_problem(
            { seat(review.Kind.CODE, review.SeatVerdict.CHANGES_NEEDED, COMMIT) },
            COMMIT,
            seat_opts(nil, { rechecked_as(review.Kind.CODE, COMMIT, review.Verdict.CLEAN) })
        ),
        { "The reviewer seat code asks for changes." }
    )
end)

testing.test("land.lands.on.a.recheck.of.a.stale.seat", function()
    -- Seat approvals at an older commit beside an idle recheck seat
    local seats = {
        seat(review.Kind.CODE, review.SeatVerdict.APPROVED, OTHER),
        seat(review.Kind.STYLE, review.SeatVerdict.APPROVED, OTHER),
        seat(review.Kind.RECHECK),
    }

    -- Recheck both kinds clean at the landing commit
    local comments = {
        rechecked_as(review.Kind.CODE, COMMIT, review.Verdict.CLEAN),
        rechecked_as(review.Kind.STYLE, COMMIT, review.Verdict.CLEAN),
    }

    -- Land on the rechecks
    testing.eq(
        wiring.seat_problems(with_seats(seats), { id = "c" }, STATE, seat_opts(nil, comments)),
        {}
    )

    -- Refuse both stale seats without them
    testing.eq(#wiring.seat_problems(with_seats(seats), { id = "c" }, STATE, seat_opts()), 2)
end)

testing.test("a clean recheck at the landing commit meets a stale recheck seat", function()
    -- Seat stale recheck reviewers and the rechecks that may meet them
    local stale = seat(review.Kind.RECHECK, review.SeatVerdict.APPROVED, OTHER)
    local changes = seat(review.Kind.RECHECK, review.SeatVerdict.CHANGES_NEEDED, OTHER)
    local clean = { rechecked_as(review.Kind.CODE, COMMIT, review.Verdict.CLEAN) }
    local minor = { rechecked_as(review.Kind.STYLE, COMMIT, review.Verdict.MINOR) }

    -- Accept a clean or minor recheck at the landing commit
    testing.eq(land.seats_problem({ stale }, COMMIT, seat_opts(nil, clean)), {})
    testing.eq(land.seats_problem({ stale }, COMMIT, seat_opts(nil, minor)), {})
    testing.eq(land.seats_problem({ changes }, COMMIT, seat_opts(nil, clean)), {})

    -- Refuse a recheck that needs work and a missing recheck
    local refused = {
        rechecked_as(review.Kind.CODE, COMMIT, review.Verdict.CLEAN),
        rechecked_as(review.Kind.STYLE, COMMIT, review.Verdict.NEEDS_WORK),
    }
    testing.eq(#land.seats_problem({ stale }, COMMIT, seat_opts(nil, refused)), 1)
    testing.eq(#land.seats_problem({ stale }, COMMIT, seat_opts(nil, {})), 1)

    -- Refuse a recheck made at the older commit
    local older = { rechecked_as(review.Kind.CODE, OTHER, review.Verdict.CLEAN) }
    testing.eq(#land.seats_problem({ stale }, COMMIT, seat_opts(nil, older)), 1)
end)

testing.test(
    "a clean recheck at the landing commit meets a stale changes requested seat",
    function()
        -- Seat stale reviewers, one of which asked for changes
        local seats = {
            seat(review.Kind.CODE, review.SeatVerdict.APPROVED, OTHER),
            seat(review.Kind.STYLE, review.SeatVerdict.CHANGES_NEEDED, OTHER),
            seat(review.Kind.RECHECK, review.SeatVerdict.APPROVED, OTHER),
        }

        -- Accept clean rechecks of both kinds at the landing commit
        local comments = {
            rechecked_as(review.Kind.CODE, COMMIT, review.Verdict.CLEAN),
            rechecked_as(review.Kind.STYLE, COMMIT, review.Verdict.CLEAN),
        }
        testing.eq(
            wiring.seat_problems(with_seats(seats), { id = "c" }, STATE, seat_opts(nil, comments)),
            {}
        )

        -- Refuse the seats when one recheck needs work
        local bad = {
            rechecked_as(review.Kind.CODE, COMMIT, review.Verdict.CLEAN),
            rechecked_as(review.Kind.STYLE, COMMIT, review.Verdict.NEEDS_WORK),
        }
        testing.eq(
            #wiring.seat_problems(with_seats(seats), { id = "c" }, STATE, seat_opts(nil, bad)),
            2
        )
    end
)

testing.test("a recheck reviewer recheck meets a seat the code reviewer held", function()
    -- Seat a recheck reviewer that approved an older commit
    local seats = {
        seat(review.Kind.CODE, review.SeatVerdict.APPROVED, COMMIT),
        seat(review.Kind.STYLE, review.SeatVerdict.APPROVED, COMMIT),
        seat(review.Kind.RECHECK, review.SeatVerdict.APPROVED, OTHER),
    }

    -- Recheck the code kind clean at the landing commit
    local comments = {
        {
            body = review.record(
                review.Kind.RECHECK,
                "dotfiles/recheck-examiner/c1",
                { commit = COMMIT, change = "chg" },
                review.Verdict.CLEAN,
                review.Kind.CODE
            ),
            who = "reviewer-token",
        },
    }

    -- Accept the seat with the recheck
    testing.eq(
        wiring.seat_problems(with_seats(seats), { id = "c" }, STATE, seat_opts(nil, comments)),
        {}
    )

    -- Refuse the seat without it
    testing.eq(#wiring.seat_problems(with_seats(seats), { id = "c" }, STATE, seat_opts()), 1)
end)

testing.test("checks_problem counts only the newest passing run at the commit", function()
    -- Accept a passing run of every row
    local rows = { "dev lint", "dev test" }
    local pass = checked(COMMIT, check.Mode.RUN, { "pass - dev lint", "pass - dev test" })
    testing.eq(land.checks_problem({ pass }, STATE, rows), nil)

    -- Refuse a card without rows or without a run at this commit
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

    -- Refuse a run that expected failure
    local expect = checked(COMMIT, check.Mode.EXPECT_FAIL, { "fail - dev lint", "fail - dev test" })
    testing.ok(land.checks_problem({ expect }, STATE, rows):find("expect-fail", 1, true))

    -- Count only the newest run, so a later failure refuses and a later pass accepts
    local failed = checked(COMMIT, check.Mode.RUN, { "pass - dev lint", "fail - dev test" })
    testing.ok(
        land.checks_problem({ pass, failed }, STATE, rows)
            :find("Row 2, `dev test`, ended with fail.", 1, true)
    )
    testing.eq(land.checks_problem({ failed, pass }, STATE, rows), nil)

    -- Refuse a run whose rows differ in count or command
    testing.ok(land.checks_problem({ pass }, STATE, { "dev lint" }):find("has 2 rows", 1, true))
    testing.ok(
        land.checks_problem({ pass }, STATE, { "dev lint", "dev x" })
            :find("checks rows changed", 1, true)
    )

    -- Refuse a run whose row timed out
    testing.ok(
        land.checks_problem(
            { checked(COMMIT, check.Mode.RUN, { "timeout - dev lint" }) },
            STATE,
            { "dev lint" }
        )
    )
end)

testing.test("checks_problem says a record it cannot read is unreadable, not missing", function()
    -- Name the commit of a record that cannot be read
    local rows = { "dev lint", "dev test" }
    local unreadable =
        { body = checked(COMMIT, check.Mode.RUN, { "pass dev lint", "pass dev test" }).body }
    local problem = land.checks_problem({ unreadable }, STATE, rows)
    testing.ok(problem:find("could not be read", 1, true), problem)
    testing.ok(problem:find(land.short(COMMIT), 1, true), problem)
    testing.ok(problem:find("Run `dev board check` again.", 1, true), problem)
    testing.eq(check.unreadable(unreadable.body), COMMIT)

    -- Call a record of another commit missing rather than unreadable
    local other = checked(OTHER, check.Mode.RUN, { "pass dev lint", "pass dev test" })
    testing.ok(
        land.checks_problem({ other }, STATE, rows):find("No run of `dev board check`", 1, true)
    )

    -- Let a newer readable run override an older unreadable one only
    local pass = checked(COMMIT, check.Mode.RUN, { "pass - dev lint", "pass - dev test" })
    testing.eq(land.checks_problem({ unreadable, pass }, STATE, rows), nil)
    testing.ok(
        land.checks_problem({ pass, unreadable }, STATE, rows):find("could not be read", 1, true)
    )

    -- Call readable records and plain notes not unreadable
    testing.eq(check.unreadable(pass.body), nil)
    testing.eq(check.unreadable("a note"), nil)
end)

testing.test("an unreadable expect-fail record never refuses a landing", function()
    -- Record a pass and an unreadable expect-fail run
    local rows = { "dev lint", "dev test" }
    local pass = checked(COMMIT, check.Mode.RUN, { "pass - dev lint", "pass - dev test" })
    local skipped = checked(COMMIT, check.Mode.EXPECT_FAIL, { "fail dev lint", "fail dev test" })
    testing.eq(check.unreadable(skipped.body), COMMIT)
    testing.eq(select(2, check.unreadable(skipped.body)), check.Mode.EXPECT_FAIL)

    -- Land whichever order the pass and the expect-fail record come in
    testing.eq(land.checks_problem({ pass, skipped }, STATE, rows), nil)
    testing.eq(land.checks_problem({ skipped, pass }, STATE, rows), nil)

    -- Still refuse an unreadable run of the ordinary mode
    local unreadable = checked(COMMIT, check.Mode.RUN, { "pass dev lint", "pass dev test" })
    testing.ok(
        land.checks_problem({ pass, unreadable }, STATE, rows):find("could not be read", 1, true)
    )

    -- Call an expect-fail record alone no run at all
    testing.ok(
        land.checks_problem({ skipped }, STATE, rows):find("No run of `dev board check`", 1, true)
    )
end)

local function at_root(project, root)
    return { root = root, home = project.home, log = project.log, bare = project.bare }
end

local function carried_note(body, from, lead)
    local short = from:sub(1, 12)
    testing.ok(body:find((lead or "") .. "carried over from commit " .. short, 1, true), body)
end

local function dev(project, args, extra)
    -- Give the run the identity, state and stub paths it needs
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

    -- Let the caller override variables and pick the working directory
    local cwd
    for name, value in pairs(extra or {}) do
        if name == "cwd" then
            cwd = value
        else
            env[name] = value
        end
    end

    -- Run dev in the project
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

local function lapse_hold(project)
    -- Read the board as it stands
    local doc = board_doc(project.home)

    -- Age the hold's claim past its lease
    for _, card in ipairs(doc.cards) do
        if card.name == turn.NAME then
            card.claim.expires_at = store.stamp(store.now() - SHORT_CLAIM_SECONDS)
        end
    end

    -- Write the board back
    local path = support.board_file(project.home, "mine")
    assert(fs.write(path, json.encode(doc)), "write failed")
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

local function add_outcomes(args)
    for _, outcome in ipairs(support.READY_OUTCOMES) do
        args[#args + 1] = "--done-when"
        args[#args + 1] = (outcome.name:gsub("%(check: .*%)$", board.JUDGEMENT))
    end
end

local function new_card(project)
    -- Initialise the board
    must(dev(project, { "board", "init" }))

    -- Spell out the fields a card needs, outcomes included
    local args = {
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
    }
    add_outcomes(args)

    -- Add the card and read back its id
    local out = dev(project, args)
    local id = assert(out:match("added (%x+)"), out)

    -- Give it a passing check and a workspace of its own
    must(dev(project, { "board", "checks", id, "true" }))
    if fs.is_dir(project.root .. "/.jj") then
        rename_workspace(project.root, id)
    end
    return id
end

local function record_review(project, id, opts)
    -- Default the kind and the reviewer
    opts = opts or {}
    local kind = opts.kind or "code"
    local by = opts.by or "rev"

    -- Spell out the review command
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

    -- Say which kind a recheck is of
    if opts.of then
        args[#args + 1] = "--of"
        args[#args + 1] = opts.of
    else
        support.with_of(kind, args)
    end

    -- Run it as the reviewer
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

local function tick_all(project, id, opts)
    opts = opts or {}
    for number = 1, 3 do
        local args = { "board", "outcome", id, "--tick", tostring(number), "--as", "verifier" }
        must((opts.run or dev)(project, args, opts.extra))
    end
end

local function untick_all(project, id, extra)
    for number = 1, 3 do
        must(dev(project, { "board", "outcome", id, "--untick", tostring(number) }, extra))
    end
end

local function to_verify(project, id, extra)
    to_review(project, id, extra)
    tick_all(project, id, { extra = extra })
    untick_all(project, id, extra)
end

local function approve(project, id)
    approve_reviews(project, id)
    must(dev(project, { "board", "check", id }))
    tick_all(project, id)
end

local function verified_card(project)
    local id = new_card(project)
    to_verify(project, id)
    approve(project, id)
    return id
end

local function refused(project, id, wanted, opts)
    -- Run land and expect it to refuse
    local out, code = dev(project, { "board", "land", id }, opts)
    testing.eq(code, 1, out)

    -- Find every wanted sentence in the refusal
    for _, text in ipairs(wanted) do
        testing.ok(out:find(text, 1, true), text .. "\n" .. out)
    end

    -- Check nothing landed and the card stayed put
    testing.eq(landed_calls(project.log), "")
    testing.eq(out:find("landed " .. id, 1, true), nil)
    testing.ok(column_of(project.home) ~= support.COLUMN_NAME.DONE, column_of(project.home))
    return out
end

testing.test("land refuses a caller with no name", function()
    -- Add a card to land
    local project = setup()
    local id = new_card(project)

    -- Refuse a caller whose name is empty
    local out, code = dev(project, { "board", "land", id }, { DEV_AGENT = "" })
    testing.eq(code, 2, out)
    testing.ok(out:find("Needs DEV_AGENT", 1, true), out)

    -- Refuse a land that names no card
    out, code = dev(project, { "board", "land" })
    testing.eq(code, 2, out)
    testing.ok(out:find("Needs a card.", 1, true), out)
end)

testing.test("land refuses an agent name that is not one word", function()
    -- Add a card to land
    local project = setup()
    local id = new_card(project)

    -- Land it as an agent whose name is two words
    local out, code = dev(project, { "board", "land", id }, { DEV_AGENT = "two words" })

    -- Refuse the name and land nothing
    testing.eq(code, 2, out)
    testing.ok(out:find("An agent name is one word of letters, digits and . - _ /", 1, true), out)
    testing.eq(landed_calls(project.log), "")
end)

local CARD_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
local CARD_PREFIX = CARD_ID:sub(1, 8)

local function fake_backend(root, card)
    -- Start a backend that records the notes it is given
    local backend = { root = root, column_map = {}, notes = {} }
    if root and fs.is_dir(root .. "/.jj") then
        rename_workspace(root, CARD_PREFIX)
    end

    -- Build the one card it serves, with the caller's overrides
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

    -- Answer the reads land makes
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
        return support.listed_card(self, id)
    end
    function backend:comments()
        return {}
    end

    -- Keep every note it is asked to write
    function backend:note(_, text)
        self.notes[#self.notes + 1] = text
        return true
    end

    return backend
end

local function land_word(backend, word)
    -- Act as the lander
    local previous = dev_os.getenv("DEV_AGENT") or ""
    dev_os.setenv("DEV_AGENT", "dotfiles/lander")

    -- Run land without letting an error skip the restore
    local ok, result = pcall(cmd_board.run, "land", { word }, backend)

    -- Put the caller's name back and surface any error
    dev_os.setenv("DEV_AGENT", previous)
    assert(ok, result)
    return result
end

local function land_as_lander(backend)
    return land_word(backend, CARD_PREFIX)
end

testing.test("land refuses a card id that is too short or not hex", function()
    -- Serve a card from a backend with no project root
    local backend = fake_backend(nil)

    -- Refuse a word that is too short and one that is not hex
    for _, word in ipairs({ "aaa", "zzzzzzzz" }) do
        local result = land_word(backend, word)
        testing.eq(result.code, 1)
        testing.eq(
            result.message,
            "A card id needs at least " .. board.MIN_PREFIX .. " hex characters: " .. word .. "."
        )
    end

    -- Write no note
    testing.eq(backend.notes, {})
end)

testing.test("land refuses a card id that no card starts with", function()
    -- Serve a card from a backend with no project root
    local backend = fake_backend(nil)

    -- Land a prefix no card starts with
    local result = land_word(backend, "bbbbbbbb")
    testing.eq(result.code, 1)
    testing.eq(result.message, "No card starts with bbbbbbbb.")

    -- Write no note
    testing.eq(backend.notes, {})
end)

testing.test("land refuses a card id that more than one card starts with", function()
    -- Serve two cards that share a prefix
    local backend = fake_backend(nil)
    function backend:cards()
        return {
            { id = "cccccccc-1111-4ccc-8ccc-cccccccccccc", name = "One" },
            { id = "cccccccc-2222-4ccc-8ccc-cccccccccccc", name = "Two" },
        }
    end

    -- Land the shared prefix
    local result = land_word(backend, "cccccccc")
    testing.eq(result.code, 1)
    testing.eq(result.message, "More than one card starts with cccccccc. Give more characters.")

    -- Write no note
    testing.eq(backend.notes, {})
end)

testing.test("land on a board with In Review and no Verify names dev board init", function()
    -- Serve a board whose columns lack Verify
    local backend = fake_backend("/nonexistent")
    backend.rows = {
        { name = support.COLUMN_NAME.IN_REVIEW, is_done = false },
        { name = support.COLUMN_NAME.DONE, is_done = true },
    }

    -- Land the card and point at dev board init
    local result = land_as_lander(backend)
    testing.eq(result.code, 1)
    testing.ok(
        result.message:find("Run `dev board init` to move the board to the stage columns.", 1, true),
        result.message
    )

    -- Write no note
    testing.eq(backend.notes, {})
end)

testing.test("land refuses a board with no project root", function()
    -- Serve a card from a backend with no project root
    local backend = fake_backend(nil)

    -- Land the card and name the missing root
    local result = land_as_lander(backend)
    testing.eq(result.code, 1)
    testing.eq(result.message, "`dev board land` needs the project's root.")

    -- Write no note
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
        -- Clone trunk from the bare remote
        local other = support.tempdir() .. "/clone"
        must(
            dev_os.run(
                { "git", "clone", "-q", "--branch", "master", project.bare, other },
                { stdout = "null", stderr = "null" }
            )
        )

        -- Stage the files that trunk gains
        for path, body in pairs(files or {}) do
            assert(fs.mkdir(fs.dirname(other .. "/" .. path), { parents = true }), "mkdir failed")
            assert(fs.write(other .. "/" .. path, body), "write failed")
            support.git(other, "add", path)
        end

        -- Commit them and push to trunk
        support.git(other, "commit", "-q", "--allow-empty", "-m", "moved")
        support.git(other, "push", "-q", "origin", "HEAD:refs/heads/master")
    end

    local function trunk_moves(project, files)
        push_trunk(project, files)
        jj(project.root, "git", "fetch", "--remote", "origin")
    end

    local function jj_project(extra)
        -- Put the jj stub on the project's path
        local project = setup(extra)
        assert(fs.write(project.root .. "/bin/jj", LAND_STUB), "write failed")
        must(dev_os.run({ "chmod", "755", project.root .. "/bin/jj" }))

        -- Make the bare remote that plays trunk
        local bare = support.tempdir()
        project.bare = bare
        must(
            dev_os.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, { stdout = "null" })
        )

        -- Start jj in the project and point it at that remote
        must(
            dev_os.run(
                { "jj", "git", "init", project.root },
                { stdout = "null", stderr = "null", env = IDENT }
            )
        )
        jj(project.root, "git", "remote", "add", "origin", bare)

        -- Seed trunk with a base commit
        assert(fs.mkdir(project.root .. "/lib", { parents = true }), "mkdir failed")
        assert(fs.write(project.root .. "/lib/seed.txt", "seed\n"), "write failed")
        jj(project.root, "commit", "-m", "base")
        jj(project.root, "bookmark", "create", "master", "-r", "@-")
        jj(project.root, "git", "push", "--remote", "origin", "--bookmark", "master")

        -- Start the card's work on top of trunk
        assert(fs.write(project.root .. "/work.txt", "one\n"), "write failed")
        jj(project.root, "describe", "-m", "feat: work")
        return project
    end

    local function head(root)
        return jj(root, "log", "-r", "@", "--no-graph", "-T", "commit_id")
    end

    local function board_at(home)
        -- Point the state home at the sandbox
        local previous = dev_os.getenv("XDG_STATE_HOME") or ""
        dev_os.setenv("XDG_STATE_HOME", home .. "/state")

        -- Open the local board there
        local backend = localboard.new({
            name = "mine",
            path = support.board_file(home, "mine"),
            private = true,
        })
        backend.stages = { icebox = support.COLUMN_NAME.ICEBOX }

        -- Hand back the board with a way to undo the redirect
        return backend, function()
            dev_os.setenv("XDG_STATE_HOME", previous)
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
        -- Verify a card in its own project
        local project = jj_project()
        local id = verified_card(project)

        -- Rename the workspace away from the card's name
        jj(project.root, "workspace", "rename", "elsewhere")

        -- Refuse and say how to get a workspace for the card
        refused(project, id, { "elsewhere", "dev ws new " .. id })
    end)

    testing.test("land refuses when jj cannot read the workspace list", function()
        -- Verify a card and count its comments
        local project = jj_project()
        local id = verified_card(project)
        local before = #comments(project.home, id)

        -- Fail the stub's workspace read and refuse
        refused(
            project,
            id,
            { "The `jj` command could not read the workspace of" },
            { LOG_FAIL_AT = "workspace" }
        )

        -- Leave the card in Verify with no new comment
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)
        testing.eq(#comments(project.home, id), before)
    end)

    testing.test(
        "workspace check passes when another workspace shares the working-copy commit",
        function()
            -- Name the card's workspace and add another beside it
            local project = jj_project()
            local id = new_card(project)
            jj(project.root, "workspace", "rename", id)
            local base = assert(fs.realpath(support.tempdir()))
            local path = base .. "/other"
            jj(project.root, "workspace", "add", "--name", "other", path)

            -- Share the working-copy commit between the two
            local work = head(project.root)
            jj(path, "edit", work)
            testing.eq(head(path), work)

            -- Take and release the turn despite the shared commit
            must(dev(project, { "board", "turn", id }))
            local out, code = dev(project, { "board", "turn", id, "--release" })
            testing.eq(code, 0, out)
        end
    )

    testing.test("turn refuses outside the workspace named for the card", function()
        -- Hold the turn for a new card
        local project = jj_project()
        local id = new_card(project)
        must(dev(project, { "board", "turn", id }))

        -- Rename the workspace away from the card's name
        jj(project.root, "workspace", "rename", "elsewhere")

        -- Refuse a second take and keep the first holder
        local out, code = dev(project, { "board", "turn", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("elsewhere", 1, true), out)
        testing.ok(out:find("dev ws new " .. id, 1, true), out)
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")

        -- Release the turn from the misnamed workspace
        out, code = dev(project, { "board", "turn", id, "--release" })
        testing.eq(code, 0, out)
        testing.ok(out:find("Gave back the landing turn held for " .. id .. ".", 1, true), out)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test(
        "a card that meets every condition lands, gets a done note and reaches Done",
        function()
            -- Verify a card and note the commit it lands
            local project = jj_project()
            local id = verified_card(project)
            local commit = head(project.root)

            -- Land it through the stub
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )

            -- Report the landing and run the confirmed jj land
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

            -- Leave a done note and move the card to Done
            local list = comments(project.home)
            local last = list[#list]
            testing.eq(last.kind, KIND_DONE)
            testing.ok(last.body:find("Landed commit " .. commit:sub(1, 12), 1, true), last.body)
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        end
    )

    local CI_STUB = table.concat({
        "#!/bin/sh",
        'dir=$(dirname "$0")',
        'case "$*" in',
        '*"ps -a"*) cat "$dir/runs.json" ;;',
        '*) echo \'{"jobs":[{"job":"test:windows:1","state":"failed"}]}\' ;;',
        "esac",
        "",
    }, "\n")

    local REQUIRE_RUN = table.concat({ "", "[board.land]", "require_change_run = true", "" }, "\n")

    local function gerrit_project(extra, status)
        -- Verify a card in a project that has a gerrit remote
        local project = jj_project(extra)
        jj(project.root, "git", "remote", "add", "gerrit", "ssh://c@g:29418/dotfiles")
        local id = verified_card(project)
        local commit = head(project.root)

        -- Stub ci so it reports the commit's change run
        local stubs = support.tempdir()
        assert(fs.write(stubs .. "/ci", CI_STUB), "write failed")
        must(dev_os.run({ "chmod", "755", stubs .. "/ci" }))
        assert(
            fs.write(
                stubs .. "/runs.json",
                '{"runs":[{"run":"r9","source":"pushed@'
                    .. commit:sub(1, 12)
                    .. '","status":"'
                    .. (status or "failed")
                    .. '","created_at":5}]}'
            ),
            "write failed"
        )

        -- Put the stubs ahead of the real tools on the run's path
        project.env = {
            FETCH_SKIP = "1",
            PATH = stubs .. ":" .. project.root .. "/bin:" .. dev_os.getenv("PATH"),
        }
        return project, id, commit
    end

    testing.test("with the opt-in, land refuses a rebased commit with no change run", function()
        -- Verify a card whose only change run passed
        local project, id = gerrit_project(REQUIRE_RUN, "passed")

        -- Move trunk so the card's commit would rebase
        trunk_moves(project, { ["moved.txt"] = "moved\n" })

        -- Refuse for want of a change run of the rebased commit
        refused(
            project,
            id,
            { "no change run of the rebased commit", "`jj submit`", "--ignore-change-run REASON" },
            project.env
        )
    end)

    testing.test("with the opt-in, land refuses a change run still going", function()
        local project, id, commit = gerrit_project(REQUIRE_RUN, "running")
        refused(
            project,
            id,
            { "The change run r9 of commit " .. commit:sub(1, 12) .. " is still going" },
            project.env
        )
    end)

    testing.test("land refuses a card whose gerrit change run failed and names the run", function()
        -- Verify a card whose change run failed, then move trunk
        local project, id, commit = gerrit_project()
        trunk_moves(project, { ["moved.txt"] = "moved\n" })

        -- Word the refusal that names the failed run
        local wanted = {
            "The change run r9 of commit " .. commit:sub(1, 12) .. " failed in test:windows:1",
            "--ignore-change-run REASON",
        }

        -- Refuse, keeping the commit where it was
        refused(project, id, wanted, project.env)
        testing.eq(head(project.root), commit)

        -- Refuse again the same way
        refused(project, id, wanted, project.env)
        testing.eq(head(project.root), commit)
    end)

    local function lands_with_reason(argv)
        -- Verify a card whose change run failed
        local project, id = gerrit_project()

        -- Build the command and add a reason to skip the change run
        local words = {}
        for _, word in ipairs(argv(id)) do
            words[#words + 1] = word
        end
        words[#words + 1] = "--ignore-change-run"
        words[#words + 1] = "windows runner is down"

        -- Land the card
        local out, code = dev(
            project,
            words,
            { LAND_TRUNK = LAND_TRUNK_KEEP, FETCH_SKIP = "1", PATH = project.env.PATH }
        )
        testing.eq(code, 0, out)

        -- Find the reason in the done note and the card in Done
        local list = comments(project.home)
        local last = list[#list]
        testing.eq(last.kind, KIND_DONE)
        testing.ok(
            last.body:find("The change run check was skipped: windows runner is down.", 1, true),
            last.body
        )
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end

    testing.test(
        "board land with --ignore-change-run lands and puts the reason in the done note",
        function()
            lands_with_reason(function(id)
                return { "board", "land", id }
            end)
        end
    )

    testing.test("dev land passes --ignore-change-run on to the board land", function()
        lands_with_reason(function(id)
            return { "land", "--card", id }
        end)
    end)

    testing.test("dev land prints the no change run line once", function()
        -- Verify a card and leave its stub with no runs
        local project, id = gerrit_project()
        local stubs = project.env.PATH:match("^([^:]+)")
        assert(fs.write(stubs .. "/runs.json", '{"runs":[]}'), "write failed")

        -- Land it through dev land
        local out, code = dev(
            project,
            { "land", "--card", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, FETCH_SKIP = "1", PATH = project.env.PATH }
        )
        testing.eq(code, 0, out)

        -- Print the no-change-run line once
        local line = "No change run of commit"
        local first = out:find(line, 1, true)
        testing.ok(first, out)
        testing.eq(out:find(line, first + 1, true), nil, out)
    end)

    local function second_card(project)
        -- Spell out the fields a card needs, outcomes included
        local args = {
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
        }
        add_outcomes(args)

        -- Add the card and read back its id
        local out = dev(project, args)
        local id = assert(out:match("added (%x+)"), out)

        -- Give it a passing check
        must(dev(project, { "board", "checks", id, "true" }))
        return id
    end

    testing.test("land with two cards on one change moves both to Done with a note", function()
        -- Verify a first card
        local project = jj_project()
        local first = verified_card(project)

        -- Verify a second card from a workspace of its own
        local second = second_card(project)
        to_verify(project, second)
        jj(project.root, "workspace", "rename", second)
        approve(project, second)

        -- Land both cards in one call
        jj(project.root, "workspace", "rename", first)
        local commit = head(project.root)
        local out, code = dev(
            project,
            { "board", "land", first, second },
            { LAND_TRUNK = LAND_TRUNK_KEEP }
        )
        testing.eq(code, 0, out)

        -- Find each card done with a landing note
        for _, id in ipairs({ first, second }) do
            local list = comments(project.home, id)
            testing.eq(list[#list].kind, KIND_DONE)
            testing.ok(list[#list].body:find("Landed commit " .. commit:sub(1, 12), 1, true))
            testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
        end
    end)

    testing.test("land with a second card that fails its rules lands nothing", function()
        -- Verify one card
        local project = jj_project()
        local first = verified_card(project)

        -- Bring a second card to Verify without its reviews
        local second = second_card(project)
        to_verify(project, second)

        -- Land both in one call and refuse the pair
        local out, code = dev(
            project,
            { "board", "land", first, second },
            { LAND_TRUNK = LAND_TRUNK_KEEP }
        )
        testing.eq(code, 1, out)
        testing.ok(out:find("cannot land", 1, true), out)

        -- Leave both cards in Verify with nothing landed
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, first), board.DEFAULT_NAMES.verify)
        testing.eq(column_of(project.home, second), board.DEFAULT_NAMES.verify)
    end)

    testing.test("land names the same card twice and lands nothing", function()
        -- Verify a card
        local project = jj_project()
        local id = verified_card(project)

        -- Land it while naming it twice
        local out, code = dev(project, { "board", "land", id, id })
        testing.eq(code, 2, out)
        testing.ok(out:find("twice", 1, true), out)

        -- Leave the card in Verify with nothing landed
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)
    end)

    testing.test(
        "land runs jj land with DEV_BOARD_LAND=1 so the jj guard lets it through",
        function()
            -- Verify a card
            local project = jj_project()
            local id = verified_card(project)

            -- Land it through the stub
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)

            -- Find the guard variable on the confirmed jj land
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
        -- Verify a card and claim it under an old-shape name
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

        -- Check the card as that claimant
        local as_old = { DEV_AGENT = old, LAND_TRUNK = LAND_TRUNK_KEEP }
        local out, code = dev(project, { "board", "check", id }, as_old)
        testing.eq(code, 0, out)

        -- Land it as that claimant
        out, code = dev(project, { "board", "land", id }, as_old)
        testing.eq(code, 0, out)
        testing.ok(out:find("landed " .. id, 1, true), out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("land refuses a card in Review and names Verify", function()
        -- Bring a card to Review with its reviews and a check
        local project = jj_project()
        local id = new_card(project)
        tick_all(project, id)
        to_review(project, id)
        approve_reviews(project, id)
        must(dev(project, { "board", "check", id }))

        -- Refuse to land it and name the Verify stage
        refused(project, id, { "It is in Review, and only a card in Verify lands." })

        -- Leave the card in Review
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.REVIEW)
    end)

    testing.test(
        "land refuses a repo that names its own land command and pushes nothing",
        function()
            -- Verify a card in a repo that names its own land command
            local project = jj_project(table.concat({
                "",
                "[board.land]",
                'command = "dev release land"',
                "",
            }, "\n"))
            local id = verified_card(project)

            -- Refuse to land it and name that command
            local out = refused(project, id, { "`dev release land`", "refuses to land card" })

            -- Leave the card in Verify and point at the command
            testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
            testing.eq(out:find("Run `dev release land` instead.", 1, true) ~= nil, true)
        end
    )

    testing.test("land still lands a repo whose land command is empty", function()
        -- Verify a card in a repo whose land command is empty
        local project = jj_project(table.concat({ "", "[board.land]", 'command = ""', "" }, "\n"))
        local id = verified_card(project)

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Move the card to Done
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("land moves a verified card to Release when the project deploys", function()
        -- Verify a card in a project that deploys
        local project = jj_project(table.concat({ "", "[board.land]", "deploys = true", "" }, "\n"))
        local id = verified_card(project)

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.ok(out:find("and moved it to Release", 1, true), out)

        -- Leave a done note that waits for the deploy
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
            -- Verify a card in a project that deploys only some paths
            local project = jj_project(table.concat({
                "",
                "[board.land]",
                "deploys = true",
                'deployed = ["lib/**", "bin/*"]',
                "",
            }, "\n"))
            local id = verified_card(project)

            -- Land it through the stub
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            testing.ok(out:find("and moved it to Done", 1, true), out)

            -- Leave no note about waiting for a deploy
            local list = comments(project.home, id)
            testing.eq(list[#list].body:find("waits in Release", 1, true), nil)
            testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
        end
    )

    testing.test("land moves a card touching a listed path to Release", function()
        -- Verify a card in a project that deploys text files
        local project = jj_project(table.concat({
            "",
            "[board.land]",
            "deploys = true",
            'deployed = ["lib/**", "*.txt"]',
            "",
        }, "\n"))
        local id = verified_card(project)

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.ok(out:find("and moved it to Release", 1, true), out)

        -- Move the card to Release
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("land moves a verified card to Done when the project does not deploy", function()
        -- Verify a card in a project that does not deploy
        local project = jj_project()
        local id = verified_card(project)

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.ok(out:find("and moved it to Done", 1, true), out)

        -- Move the card to Done
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("a card in Release moves to Done once every outcome is ticked", function()
        -- Place a verified card in Release with one outcome unticked
        local project = jj_project()
        local id = verified_card(project)
        support.place(support.board_file(project.home, "mine"), id, support.COLUMN_NAME.RELEASE)
        must(dev(project, { "board", "outcome", id, "--untick", "1" }))

        -- Refuse to move it to Done while an outcome is unticked
        local out, code = dev(project, { "board", "move", id, support.Column.DONE })
        testing.eq(code, 1, out)
        testing.ok(out:find("1 of 3 outcomes are unticked", 1, true), out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.RELEASE)

        -- Move it to Done once every outcome is ticked
        tick_all(project, id)
        must(dev(project, { "board", "move", id, support.Column.DONE }))
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("a land that rewrites the commit notes the commit on trunk", function()
        -- Verify a card and note its commit
        local project = jj_project()
        local id = verified_card(project)
        local before = head(project.root)

        -- Land it through a stub that rewrites the commit
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_REWRITE })
        testing.eq(code, 0, out)

        -- Report the commit on trunk, not the old one
        local after =
            jj(project.root, "log", "-r", "master@origin", "--no-graph", "-T", "commit_id")
        testing.ok(before ~= after, "the stub must rewrite the commit")
        testing.ok(out:find("at commit " .. after:sub(1, 12) .. " and moved", 1, true), out)
        testing.eq(out:find(before:sub(1, 12), 1, true), nil, out)

        -- Put the commit on trunk in the done note
        local list = comments(project.home)
        local last = list[#list]
        testing.ok(last.body:find("Landed commit " .. after:sub(1, 12), 1, true), last.body)
        testing.eq(last.body:find(before:sub(1, 12), 1, true), nil, last.body)
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test(
        "a land whose trunk cannot be read notes the earlier commit and still reaches Done",
        function()
            -- Verify a card and note its commit
            local project = jj_project()
            local id = verified_card(project)
            local commit = head(project.root)

            -- Land it with no stub to move trunk
            local out, code = dev(project, { "board", "land", id })
            testing.eq(code, 0, out)
            testing.ok(out:find("at commit " .. commit:sub(1, 12), 1, true), out)
            testing.ok(out:find("trunk could not be read", 1, true), out)

            -- Put the earlier commit in the done note and reach Done
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
            -- Verify a card and a way to record reviews on it
            local project = jj_project()
            local id = verified_card(project)
            local function judge(by, verdict)
                must(record_review(project, id, { by = by, verdict = verdict }))
            end

            -- Refuse once a reviewer says needs-work, naming them
            judge("picky", "needs-work")
            refused(project, id, { "code review by picky", "needs-work" })

            -- Land once a later review says minor
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
        -- Verify a card and count its comments
        local project = jj_project()
        local id = verified_card(project)
        local before = #comments(project.home)

        -- Land it through a stub whose jj land fails
        local out, code = dev(
            project,
            { "board", "land", id },
            { LAND_CODE = "1", LAND_MSG = "boom" }
        )

        -- Report the failure and that land was attempted
        testing.eq(code, 1, out)
        testing.ok(out:find("stays in Verify", 1, true) and out:find("boom", 1, true), out)
        testing.ok(landed_calls(project.log):find("land", 1, true))

        -- Add no comment and leave the card in Verify
        testing.eq(#comments(project.home), before)
        testing.eq(column_of(project.home), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("land names every missing condition and runs nothing", function()
        local project = jj_project()
        local id = new_card(project)
        refused(project, id, {
            "It is in Backlog, and only a card in Verify lands.",
            "3 of 3 outcomes are unticked",
            "No code review of change",
            "No style review of change",
            "No run of `dev board check`",
        })
    end)

    testing.test("land refuses another claimant's card", function()
        -- Add a card and claim it as the builder
        local project = jj_project()
        local id = new_card(project)
        must(dev(project, { "board", "take", id, "--as", "dotfiles/builder" }))

        -- Refuse to land it as the lander
        refused(project, id, { "claimed by dotfiles/builder", "not dotfiles/lander" })

        -- Give the claim back
        must(dev(project, { "board", "release", id }))
    end)

    testing.test("land succeeds after a take --from handoff", function()
        -- Verify a card and claim it as the builder
        local project = jj_project()
        local id = verified_card(project)
        must(dev(project, { "board", "take", id, "--as", "dotfiles/builder" }))

        -- Refuse to land it as the lander
        refused(project, id, { "claimed by dotfiles/builder", "not dotfiles/lander" })

        -- Take the claim over from the builder
        must(dev(project, { "board", "take", id, "--from", "dotfiles/builder" }))
        testing.eq(claim_of(project.home, id).claimant, "dotfiles/lander")

        -- Land the card
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.ok(out:find("landed " .. id, 1, true), out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("a claimed card's review comes from another name, never its claimant", function()
        -- Claim a card as the builder and count its comments
        local project = jj_project()
        local id = new_card(project)
        must(dev(project, { "board", "take", id, "--as", "dotfiles/builder" }))
        local before = #comments(project.home, id)

        -- Refuse every kind of review that the claimant names itself as the reviewer of
        for _, kind in ipairs({ "code", "style", "recheck" }) do
            local out, code = record_review(project, id, { kind = kind, by = "dotfiles/builder" })
            testing.eq(code, 1, out)
            testing.ok(
                out:find("A reviewer other than dotfiles/builder must record it", 1, true),
                out
            )
        end

        -- Refuse every kind that the claimant records under another name
        for _, kind in ipairs({ "code", "style", "recheck" }) do
            local out, code = record_review(project, id, { kind = kind, env = "dotfiles/builder" })
            testing.eq(code, 1, out)
            testing.ok(out:find("dotfiles/builder cannot record a review by rev", 1, true), out)
        end

        -- Leave the card's comments as they were
        testing.eq(#comments(project.home, id), before)

        -- Accept a review from another name
        must(record_review(project, id))
        local list = comments(project.home, id)
        testing.eq(#list, before + 1)
        testing.ok(list[#list].body:find("dev-review: kind=code by=rev", 1, true), list[#list].body)
    end)

    testing.test("land refuses a working copy that is empty or undescribed", function()
        -- Verify a card
        local project = jj_project()
        local id = verified_card(project)

        -- Refuse a working copy with no description
        jj(project.root, "describe", "-m", "")
        refused(project, id, { "has no description" })

        -- Refuse an empty working copy
        jj(project.root, "describe", "-m", "feat: work")
        jj(project.root, "new", "-m", "next")
        refused(project, id, { "is empty" })
    end)

    testing.test("a check run at an older commit or with a failing row does not count", function()
        -- Verify a card and change its work after the check
        local project = jj_project()
        local id = verified_card(project)
        assert(fs.write(project.root .. "/work.txt", "two\n"), "write failed")

        -- Refuse for want of a run at the new commit
        refused(project, id, { "No run of `dev board check` is recorded at commit" })

        -- Record a run whose row fails
        must(dev(project, { "board", "checks", id, "false" }))
        local _, code = dev(project, { "board", "check", id })
        testing.eq(code, 1)

        -- Refuse for the earlier commit and the failing row
        refused(project, id, {
            "earlier commit than",
            "did not pass every row. Row 1, `false`, ended with fail.",
        })
    end)

    testing.test("a stack note prints when the parent is off trunk", function()
        -- Bring a card to Verify with its reviews
        local project = jj_project()
        local id = new_card(project)
        to_verify(project, id)
        approve_reviews(project, id)

        -- Check from trunk's child and see no note and no fetch
        local reads = support.tempdir() .. "/fetch.log"
        local clean = dev(project, { "board", "check", id }, { FETCH_LOG = reads })
        testing.eq(clean:find("squash the commits", 1, true), nil, clean)
        testing.eq(fs.read(reads), nil)

        -- Stack a second commit on the first
        jj(project.root, "new", "-m", "second")
        assert(fs.write(project.root .. "/more.txt", "two\n"), "write failed")

        -- Check again and see the stack note after one fetch
        local out, code = dev(project, { "board", "check", id }, { FETCH_LOG = reads })
        testing.eq(code, 0, out)
        testing.ok(out:find("squash the commits into one change", 1, true), out)
        testing.eq(fs.read(reads), "fetch\n")
    end)

    testing.test(
        "no stack note prints when the parent landed after the workspace was made",
        function()
            -- Bring a card to Verify with its reviews
            local project = jj_project()
            local id = new_card(project)
            to_verify(project, id)
            approve_reviews(project, id)

            -- Stack a second commit on the first
            jj(project.root, "new", "-m", "second")
            assert(fs.write(project.root .. "/more.txt", "two\n"), "write failed")

            -- Land the parent on trunk
            local parent = jj(project.root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
            must(dev_os.run({
                "git",
                "--git-dir=" .. project.root .. "/.git",
                "push",
                "-q",
                project.bare,
                parent .. ":refs/heads/master",
            }, { stdout = "null", stderr = "null" }))

            -- Check and see no stack note
            local out, code = dev(project, { "board", "check", id })
            testing.eq(code, 0, out)
            testing.eq(out:find("squash the commits", 1, true), nil, out)
        end
    )

    testing.test("an expect-fail record never counts as a passing check", function()
        -- Bring a card whose check fails to Verify with its reviews
        local project = jj_project()
        local id = new_card(project)
        must(dev(project, { "board", "checks", id, "false" }))
        to_verify(project, id)
        approve_reviews(project, id)

        -- Record the check as expected to fail
        must(dev(project, { "board", "check", id, "--expect-fail" }))
        tick_all(project, id)

        -- Refuse for want of a passing run
        refused(project, id, { "No run of `dev board check` is recorded", "expect-fail" })
    end)

    testing.test("a change after the reviews needs a recheck at the landing commit", function()
        -- Verify a card
        local project = jj_project()
        local id = verified_card(project)

        -- Change its work and record a fresh check
        assert(fs.write(project.root .. "/work.txt", "two\n"), "write failed")
        must(dev(project, { "board", "check", id }))

        -- Refuse for want of a recheck at the landing commit
        refused(project, id, { "earlier commit than", "dev board review --kind recheck" })

        -- Land only once both kinds are rechecked
        for _, of in ipairs({ "code", "style" }) do
            must(record_review(project, id, { kind = "recheck", of = of }))
            local out, code = dev(project, { "board", "land", id })
            testing.eq(code == 0, of == "style", out)
        end
    end)

    testing.test("land rebases onto trunk under the turn when trunk has moved", function()
        -- Verify a card and move trunk under it
        local project = jj_project()
        local id = verified_card(project)
        push_trunk(project)

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(out:find("Trunk has moved", 1, true), nil, out)

        -- Move the card to Done and give the turn back
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test(
        "land names the holder and since when while another card holds the turn",
        function()
            -- Verify a card while another card holds the turn
            local project = jj_project()
            local id = verified_card(project)
            local held = hold_turn(project.home, "other", "cccc3333")

            -- Refuse without waiting and name the holder
            local out, code = dev(project, { "board", "land", id, "--wait", "0" })
            testing.eq(code, 1, out)
            testing.ok(out:find("held by other since 20", 1, true), out)
            testing.eq(column_of(project.home), support.COLUMN_NAME.VERIFY)

            -- Refuse a wait that is not a number or is too long
            _, code = dev(project, { "board", "land", id, "--wait", "x" })
            testing.eq(code, 2)
            _, code = dev(project, { "board", "land", id, "--wait", "999999999" })
            testing.eq(code, 2)

            -- Land once the holder lets go
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
        -- Put the change on top of an unlanded parent
        local project = jj_project()
        jj(project.root, "new", "-m", "feat: child")
        assert(fs.write(project.root .. "/child.txt", "two\n"), "write failed")

        -- Verify the card and move trunk
        local id = verified_card(project)
        push_trunk(project)
        local before = head(project.root)

        -- Refuse and leave the change where it was
        refused(project, id, { "sits on an unlanded parent" })
        testing.eq(head(project.root), before)
        testing.eq(turn_holder(project.home), nil)
    end)

    local function stack_on_parent(project, parent)
        -- Start the parent on trunk
        jj(project.root, "new", "master", table.unpack(parent.args))

        -- Give it content when the spec has a body
        if parent.body then
            assert(fs.write(project.root .. "/mid.txt", parent.body), "write failed")
        end

        -- Stack the child with a file of its own
        jj(project.root, "new", "-m", "feat: child")
        assert(fs.write(project.root .. "/child.txt", "two\n"), "write failed")
    end

    ---The parent spec for an empty undescribed commit
    local EMPTY_PARENT = { args = {} }

    testing.test(
        "land accepts a change whose parent is an empty undescribed commit on trunk",
        function()
            -- Verify a change whose parent is empty and undescribed
            local project = jj_project()
            stack_on_parent(project, EMPTY_PARENT)
            local id = verified_card(project)

            -- Land it through the stub
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)

            -- Move the card to Done and give the turn back
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
            testing.eq(turn_holder(project.home), nil)
        end
    )

    testing.test(
        "land carries a check across the rebase past an empty undescribed parent",
        function()
            -- Verify a change whose parent is empty and undescribed
            local project = jj_project()
            stack_on_parent(project, EMPTY_PARENT)
            local id = verified_card(project)
            local before = head(project.root)

            -- Land it through the stub
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)
            testing.ok(head(project.root) ~= before, "the rebase must rewrite the commit")

            -- Note in the done comment that the check was carried
            local list = comments(project.home)
            local last = list[#list]
            testing.eq(last.kind, KIND_DONE)
            carried_note(last.body, before)
        end
    )

    testing.test("land abandons the empty undescribed parent it rebases past", function()
        -- Verify a change whose parent is empty and undescribed
        local project = jj_project()
        stack_on_parent(project, EMPTY_PARENT)
        local id = verified_card(project)

        -- See the parent still visible before landing
        local parent = jj(project.root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
        local alive = "::visible_heads() & " .. parent
        testing.eq(jj(project.root, "log", "-r", alive, "--no-graph", "-T", "commit_id"), parent)

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- See the parent abandoned
        testing.eq(jj(project.root, "log", "-r", alive, "--no-graph", "-T", "commit_id"), "")
    end)

    testing.test(
        "land refuses a change whose parent is an empty commit with a description",
        function()
            -- Verify a change whose parent is an empty described commit
            local project = jj_project()
            stack_on_parent(project, { args = { "-m", "docs: keep this" } })
            local id = verified_card(project)
            local before = head(project.root)

            -- Refuse and leave the change where it was
            refused(project, id, { "sits on an unlanded parent" })
            testing.eq(head(project.root), before)
            testing.eq(turn_holder(project.home), nil)
        end
    )

    testing.test("land refuses a change whose parent is a non-empty undescribed commit", function()
        -- Verify a change whose parent is a non-empty undescribed commit
        local project = jj_project()
        stack_on_parent(project, { args = {}, body = "mid\n" })
        local id = verified_card(project)
        local before = head(project.root)

        -- Refuse and leave the change where it was
        refused(project, id, { "sits on an unlanded parent" })
        testing.eq(head(project.root), before)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test("land waits up to the wait and then names the holder", function()
        -- Verify a card while another card holds the turn
        local project = jj_project()
        local id = verified_card(project)
        local held = hold_turn(project.home, "other", "cccc3333")
        local backend, restore = board_at(project.home)
        backend.root = project.root

        -- Run on a fake clock whose naps advance it
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

        -- Land as the lander with a one-second wait, then undo every override
        local previous = dev_os.getenv("DEV_AGENT") or ""
        dev_os.setenv("DEV_AGENT", "dotfiles/lander")
        local ok, result = pcall(cmd_board.run, "land", { id, "--wait", "1" }, backend)
        dev_os.setenv("DEV_AGENT", previous)
        dev_os.nap = nap
        store.now = now
        restore()
        assert(ok, result)

        -- Refuse after waiting no longer than the deadline
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
        -- Verify a card while another card holds the turn
        local project = jj_project()
        local id = verified_card(project)
        local held = hold_turn(project.home, "other", "cccc3333")
        local backend, restore = board_at(project.home)
        backend.root = project.root

        -- Count the naps instead of sleeping
        local nap = dev_os.nap
        local naps = 0
        dev_os.nap = function()
            naps = naps + 1
        end

        -- Land as the lander with no wait, then undo every override
        local previous = dev_os.getenv("DEV_AGENT") or ""
        dev_os.setenv("DEV_AGENT", "dotfiles/lander")
        local ok, result = pcall(cmd_board.run, "land", { id }, backend)
        dev_os.setenv("DEV_AGENT", previous)
        dev_os.nap = nap
        restore()
        assert(ok, result)

        -- Refuse at once, with no nap, and leave the holder in place
        testing.eq(result.code, 1, result.message)
        testing.ok(result.message:find("held by other since", 1, true), result.message)
        testing.eq(naps, 0)
        testing.eq(assert(turn_holder(project.home)).name, "other")
        release_turn(project.home, held)
    end)

    testing.test("land asks for no turn when it refuses", function()
        -- Bring a card to Verify with its outcomes ticked but no reviews
        local project = jj_project()
        local id = new_card(project)
        to_verify(project, id)
        tick_all(project, id)

        -- Refuse to land it
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("No code review", 1, true), out)

        -- Leave no turn held or recorded
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
        -- Rebase the work onto a trunk that holds a shared file
        trunk_moves(project, { ["shared.txt"] = SHARED })
        rebase_onto_trunk(project.root)

        -- Change the shared file's last line
        assert(fs.write(project.root .. "/shared.txt", LAST_EDIT), "write failed")

        -- Add a card, with the check row when given, and bring it to Verify approved
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
        -- Put a plain script on trunk
        local project = jj_project()
        jj(project.root, "describe", "-m", "base2")
        assert(fs.write(project.root .. "/x.sh", "#!/bin/sh\n"), "write failed")
        jj(project.root, "commit", "-m", "base2")
        jj(project.root, "bookmark", "set", "master", "-r", "@-")
        jj(project.root, "git", "push", "--remote", "origin", "--bookmark", "master")

        -- Move the script into .dev/standalone in the card's change
        jj(project.root, "describe", "-m", "feat: move")
        assert(fs.mkdir(project.root .. "/.dev/standalone", { parents = true }), "mkdir failed")
        must(dev_os.run({ "mv", project.root .. "/x.sh", project.root .. "/.dev/standalone/x.sh" }))

        -- Verify the card and refuse it
        local id = verified_card(project)
        refused(project, id, { "adds .dev/standalone/x.sh" })
    end)

    testing.test(
        "land lands a commit that adds a standalone file when the card has standalone-ok",
        function()
            -- Add a card whose change adds a standalone file
            local project = jj_project()
            local id = standalone_ready(project)

            -- Allow it with the standalone-ok label and approve it
            must(dev(project, { "board", "label", id, "+standalone-ok" }, { DEV_AGENT = "" }))
            approve(project, id)

            -- Land it into Done
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
        -- Write the template the card changes
        assert(fs.mkdir(project.root .. "/" .. TEMPLATE_DIR, { parents = true }), "mkdir failed")
        assert(
            fs.write(project.root .. "/" .. TEMPLATE_DIR .. "/lint.lua", opts.template),
            "write failed"
        )

        -- Write the baked list when the test gives one
        assert(fs.mkdir(project.root .. "/.dev", { parents = true }), "mkdir failed")
        if opts.baked then
            assert(fs.write(project.root .. "/.dev/baked.txt", opts.baked), "write failed")
        end

        -- Verify the card
        return verified_card(project)
    end

    local CALLS_EXISTS = table.concat({
        'local fs = require("@dev/fs")',
        'return fs.exists("x")',
        "",
    }, "\n")

    local function template_project()
        return jj_project(table.concat({
            "",
            "[sync]",
            'templates = ["' .. TEMPLATE_DIR .. '"]',
            'baked = ".dev/baked.txt"',
            "",
        }, "\n"))
    end

    testing.test(
        "land refuses a template change that calls a dev function the baked list lacks",
        function()
            local project = template_project()
            local id = template_ready(project, { template = CALLS_EXISTS, baked = "dev.fs\n" })
            refused(project, id, {
                "The lint-set template calls dev.fs.exists, which .dev/baked.txt",
                "rebuild the ci images, then land the template change",
            })
        end
    )

    testing.test("land refuses a template change from a subdirectory", function()
        local project = template_project()
        local id = template_ready(project, { template = CALLS_EXISTS, baked = "dev.fs\n" })
        local subdirectory = project.root .. "/" .. TEMPLATE_DIR
        refused(project, id, {
            "The lint-set template calls dev.fs.exists, which .dev/baked.txt",
            "rebuild the ci images, then land the template change",
        }, { cwd = subdirectory })
    end)

    testing.test(
        "land refuses a template change when the dev change is already on trunk",
        function()
            -- Open a project that guards its templates
            local project = template_project()

            -- Put the dev function and its baked list on trunk
            trunk_moves(project, {
                ["lua/dev/fs.lua"] = "return {}\n",
                [".dev/baked.txt"] = "dev.fs\n",
            })

            -- Change the template and refuse the landing
            local id = template_ready(project, { template = CALLS_EXISTS })
            refused(project, id, { "The lint-set template calls dev.fs.exists," })
        end
    )

    testing.test(
        "land refuses a template change that requires a module the baked list lacks",
        function()
            local project = template_project()
            local id = template_ready(project, { template = CALLS_EXISTS })
            refused(project, id, { "The lint-set template calls dev.fs, dev.fs.exists," })
        end
    )

    testing.test("land lands a template change whose dev calls the baked list holds", function()
        -- Add a template change whose calls the baked list holds
        local project = template_project()
        local id = template_ready(project, {
            template = CALLS_EXISTS,
            baked = table.concat({ "dev.fs", "dev.fs.exists", "" }, "\n"),
        })

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Reach Done
        testing.eq(column_of(project.home), board.DEFAULT_NAMES.done)
    end)

    testing.test("land lands a template change that calls no dev function", function()
        -- Add a template change that calls no dev function
        local project = template_project()
        local id = template_ready(project, { template = "return 1\n" })

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Reach Done
        testing.eq(column_of(project.home), board.DEFAULT_NAMES.done)
    end)

    testing.test("the template guard stays quiet without sync.templates", function()
        -- Add a template change in a project with no template guard
        local project = jj_project()
        local id = template_ready(project, { template = CALLS_EXISTS })

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Reach Done
        testing.eq(column_of(project.home), board.DEFAULT_NAMES.done)
    end)

    testing.test("dev_calls lists the modules and functions a template takes from dev", function()
        local text = table.concat({
            'local fs = require("@dev/fs")',
            'local dev_os = require("@dev/os")',
            'local standalone = require("@dev/standalone")',
            'local x = require("@dev/command").say',
            "return fs.exists(a) and dev_os.run(b) and self.fs.read(c) and other.run(d)",
            "",
        }, "\n")
        testing.eq(land.dev_calls(text), {
            "dev.command",
            "dev.command.say",
            "dev.fs",
            "dev.fs.exists",
            "dev.os",
            "dev.os.run",
            "dev.standalone",
        })
    end)

    testing.test("dev_calls ignores a call named only in a comment", function()
        local text = table.concat({
            'local ui = require("@dev/ui")',
            "-- see ui.confirm",
            "    --- also ui.ask",
            "",
        }, "\n")
        testing.eq(land.dev_calls(text), { "dev.ui" })
    end)

    testing.test("dev_calls lists nothing for a file that requires no dev module", function()
        local text = table.concat({ 'local fs = require("lfs")', "return fs.exists(a)", "" }, "\n")
        testing.eq(land.dev_calls(text), {})
    end)

    testing.test(
        "land after another lander's turn ends rebases without a trunk-moved refusal",
        function()
            -- Verify a card while another card holds the turn
            local project = jj_project()
            local id = review_ready(project)
            local held = hold_turn(project.home, "other", "cccc3333")

            -- Refuse without waiting and name the holder
            local first, first_code = dev(project, { "board", "land", id, "--wait", "0" })
            testing.eq(first_code, 1, first)
            testing.ok(first:find("held by other since", 1, true), first)

            -- Move trunk and free the turn
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            release_turn(project.home, held)

            -- Land and rebase with no trunk-moved refusal
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
            -- Verify a card and note its commit
            local project = jj_project()
            local id = review_ready(project)
            local before = head(project.root)

            -- Move trunk and rebase the card onto it
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)
            testing.ok(head(project.root) ~= before, "the rebase must rewrite the commit")

            -- Land it through the stub
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)

            -- Note the carry in the done comment and reach Done
            local list = comments(project.home)
            local last = list[#list]
            testing.eq(last.kind, KIND_DONE)
            carried_note(last.body, before)
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test("land carries past two rebases the check and reviews", function()
        -- Verify a card and note its commit
        local project = jj_project()
        local id = review_ready(project)
        local before = head(project.root)

        -- Rebase the card past a first trunk move
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        local middle = head(project.root)
        testing.ok(middle ~= before, "the first rebase must rewrite the commit")

        -- Rebase it past a second trunk move
        trunk_moves(project, { ["notes.txt"] = "notes\n" })
        rebase_onto_trunk(project.root)
        testing.ok(head(project.root) ~= middle, "the second rebase must rewrite the commit")

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Note the carry in the done comment and reach Done
        local list = comments(project.home)
        carried_note(list[#list].body, before, "The check and reviews were ")
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("land carries across a trunk merge commit", function()
        -- Verify a card and note its commit
        local project = jj_project()
        local id = review_ready(project)
        local before = head(project.root)

        -- Push a merge commit to trunk through a second clone
        local other = support.tempdir() .. "/clone"
        must(
            dev_os.run(
                { "git", "clone", "-q", "--branch", "master", project.bare, other },
                { stdout = "null", stderr = "null" }
            )
        )
        support.git(other, "checkout", "-q", "-b", "side")
        assert(fs.write(other .. "/side.txt", "side\n"), "write failed")
        support.git(other, "add", "side.txt")
        support.git(other, "commit", "-q", "-m", "side")
        support.git(other, "checkout", "-q", "master")
        assert(fs.write(other .. "/main.txt", "main\n"), "write failed")
        support.git(other, "add", "main.txt")
        support.git(other, "commit", "-q", "-m", "main")
        support.git(other, "merge", "-q", "--no-ff", "-m", "merge side", "side")
        support.git(other, "push", "-q", "origin", "HEAD:refs/heads/master")

        -- Rebase the reviewed change onto the merged trunk
        jj(project.root, "git", "fetch", "--remote", "origin")
        rebase_onto_trunk(project.root)
        testing.ok(head(project.root) ~= before, "the rebase must rewrite the commit")

        -- Land it and check the carried note
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        local list = comments(project.home)
        carried_note(list[#list].body, before, "The check and reviews were ")
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("land carries after a refusal between two rebases", function()
        -- Verify a card and note its commit
        local project = jj_project()
        local id = review_ready(project)
        local before = head(project.root)

        -- Rebase once, then hold the turn so the first land refuses
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        local held = hold_turn(project.home, "other", "cccc3333")
        local first, first_code = dev(project, { "board", "land", id, "--wait", "0" })
        testing.eq(first_code, 1, first)
        testing.ok(first:find("held by other since", 1, true), first)

        -- Rebase again after the refusal
        local middle = head(project.root)
        trunk_moves(project, { ["notes.txt"] = "notes\n" })
        rebase_onto_trunk(project.root)
        testing.ok(head(project.root) ~= middle, "the second rebase must rewrite the commit")

        -- Release the turn and land
        release_turn(project.home, held)
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        local list = comments(project.home)
        carried_note(list[#list].body, before, "The check and reviews were ")
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("land carries past three rebases through nested directories", function()
        -- Verify a card whose check reads the shared file
        local project = jj_project()
        local id = review_ready(project, "rg -n G shared.txt")
        local before = head(project.root)

        -- Rebase it past three trunk moves in nested directories
        local moves = {
            { ["lib/deep/one.txt"] = "one\n" },
            { ["docs/two.txt"] = "two\n", ["lib/three.txt"] = "three\n" },
            { ["four/five/six.txt"] = "six\n" },
        }
        for _, files in ipairs(moves) do
            trunk_moves(project, files)
            rebase_onto_trunk(project.root)
        end

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Note the carry in the done comment
        local list = comments(project.home)
        carried_note(list[#list].body, before, "The check and reviews were ")
    end)

    testing.test("land refuses a carry past two rebases when the checks rows changed", function()
        -- Verify a card whose check reads the shared file
        local project = jj_project()
        local id = review_ready(project, "rg -n G shared.txt")

        -- Rebase it past two trunk moves
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        trunk_moves(project, { ["notes.txt"] = "notes\n" })
        rebase_onto_trunk(project.root)

        -- Change the checks rows and refuse the carry
        must(dev(project, { "board", "checks", id, "rg -n a shared.txt" }, { DEV_AGENT = "" }))
        refused(project, id, { "checks rows changed" }, { LAND_TRUNK = LAND_TRUNK_KEEP })
    end)

    testing.test("a recheck keeps its of kind across a rebase carry-over", function()
        -- Build a card rechecked for the given kinds and then rebased
        local function rechecked(ofs)
            local project = jj_project()
            local id = verified_card(project)
            assert(fs.write(project.root .. "/work.txt", "two\n"), "write failed")
            must(dev(project, { "board", "check", id }))
            for _, of in ipairs(ofs) do
                must(record_review(project, id, { kind = "recheck", of = of }))
            end
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)
            return project, id
        end

        -- Land a card rechecked for both kinds
        local project, id = rechecked({ "code", "style" })
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)

        -- Refuse a card rechecked for the code kind alone
        project, id = rechecked({ "code" })
        refused(project, id, { "--kind recheck --of style" }, { LAND_TRUNK = LAND_TRUNK_KEEP })
    end)

    testing.test(
        "land carries over a rebase with no interdiff that targets the working copy",
        function()
            -- Verify a card and note its commit
            local project = jj_project()
            local id = review_ready(project)
            local before = head(project.root)

            -- Move trunk and rebase the card onto it
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)

            -- Land it with the interdiff to the working copy failing
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP, INTERDIFF_FAIL_AT = "--to @" }
            )
            testing.eq(code, 0, out)

            -- Note the carry in the done comment and reach Done
            local list = comments(project.home)
            carried_note(list[#list].body, before)
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test("land carries the check and reviews over the rebase it makes itself", function()
        -- Verify a card and note its commit
        local project = jj_project()
        local id = review_ready(project)
        local before = head(project.root)

        -- Move trunk and leave the rebase to land
        trunk_moves(project, { ["docs.txt"] = "docs\n" })

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Note the carry in the done comment and reach Done
        local list = comments(project.home)
        carried_note(list[#list].body, before)
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("land refuses when the recheck stretch loses the turn", function()
        -- Verify a card and rebase it past a trunk move
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Take the turn and open the board under the card
        must(dev(project, { "board", "turn", id }))
        local backend, restore = board_at(project.home)
        backend.root = project.root

        -- Make the recheck stretch report the turn lost
        local stretch = turn.stretch
        turn.stretch = function()
            return nil, "The turn was lost."
        end

        -- Land as the lander, then undo every override
        local previous = dev_os.getenv("DEV_AGENT") or ""
        dev_os.setenv("DEV_AGENT", "dotfiles/lander")
        local ok, result = pcall(cmd_board.run, "land", { id }, backend)
        dev_os.setenv("DEV_AGENT", previous)
        turn.stretch = stretch
        restore()
        assert(ok, result)

        -- Refuse with the turn's message, landing nothing
        testing.eq(result.code, 1, result.message)
        testing.ok(result.message:find("The turn was lost.", 1, true), result.message)
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
        testing.eq(turn_holder(project.home), nil)
    end)

    local CARRY_SCRIPT = table.concat({
        'local dev_command = require("@dev/command")',
        "return dev_command({",
        '    summary = "A test command",',
        '    args = { { name = "card", required = true } },',
        "    run = function(_, args, ctx)",
        "        ctx = { root = ctx.root, args = { args.card } }",
        'local board = require("@dev/board")',
        'local scm = require("@dev/scm")',
        "",
        "local found = assert(board.find(scm.workspace(ctx.root)))",
        "local card = assert(found:find_card(ctx.args[1]))",
        "local ok, why = card:carry_proof()",
        'print("carry: " .. tostring(ok) .. " " .. tostring(why))',
        "        return 0",
        "    end,",
        "})",
        "",
    }, "\n")

    local function carry_project()
        local project = jj_project()
        assert(fs.mkdir(project.root .. "/.dev/commands", { parents = true }))
        assert(fs.write(project.root .. "/.dev/commands/carry.luau", CARRY_SCRIPT), "write failed")
        return project
    end

    local function move_to_release(project, id)
        return dev(project, { "board", "move", id, support.COLUMN_NAME.RELEASE })
    end

    testing.test("carry_proof writes the records a rebased commit lacks", function()
        -- Verify a card and note its commit
        local project = carry_project()
        local id = review_ready(project)
        local before = head(project.root)

        -- Rebase it past a trunk move
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        testing.ok(head(project.root) ~= before, "the rebase must rewrite the commit")

        -- Refuse the move to Release for want of records at the new commit
        local out, code = move_to_release(project, id)
        testing.eq(code, 1, out)
        testing.ok(out:find("No run of `dev board check`", 1, true), out)

        -- Carry the records over
        out = dev(project, { "carry", id })
        testing.ok(out:find("carry: true", 1, true), out)

        -- Count the records written at the new commit
        local records = 0
        for _, comment in ipairs(comments(project.home, id)) do
            if comment.body:find(head(project.root), 1, true) then
                records = records + 1
            end
        end
        testing.eq(records, 3)
    end)

    testing.test("a carried card's move to Release names only its change not on trunk", function()
        -- Verify a card and rebase it past a trunk move
        local project = carry_project()
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Carry the records and count them
        local out = dev(project, { "carry", id })
        testing.ok(out:find("carry: true", 1, true), out)
        local written = #comments(project.home, id)

        -- Carry again and write nothing new
        out = dev(project, { "carry", id })
        testing.ok(out:find("carry: true", 1, true), out)
        testing.eq(#comments(project.home, id), written)

        -- Refuse the move to Release, naming the change not on trunk
        local moved, code = move_to_release(project, id)
        testing.eq(code, 1, moved)
        testing.eq(moved:find("No run of `dev board check`", 1, true), nil, moved)
        testing.ok(moved:find("not on trunk", 1, true), moved)
        testing.ok(column_of(project.home, id) ~= support.COLUMN_NAME.RELEASE)
    end)

    testing.test("a move to Done of a proven card not on trunk names dev board land", function()
        -- Verify a card whose change is not on trunk
        local project = jj_project()
        local id = verified_card(project)

        -- Try to move it to Done by hand and see the refusal
        local out, code = dev(project, { "board", "move", id, support.COLUMN_NAME.DONE })
        testing.eq(code, 1, out)
        testing.ok(out:find("Its change is not on trunk.", 1, true), out)
        testing.ok(out:find("Run `dev board land " .. id:sub(1, 8) .. "` first.", 1, true), out)

        -- Leave the card out of Done
        testing.ok(column_of(project.home, id) ~= support.COLUMN_NAME.DONE)
    end)

    for _, label in ipairs({ board.NO_CHANGE, board.TRUNK_BLOCKER }) do
        testing.test(
            "a " .. label .. " card moves to Done though its change is not on trunk",
            function()
                -- Verify a card whose change is not on trunk
                local project = jj_project()
                local id = verified_card(project)

                -- Give it the label that excuses that
                must(dev(project, { "board", "label", id, "+" .. label }, { DEV_AGENT = "" }))

                -- Move it to Done by hand and see it through
                local out, code = dev(project, { "board", "move", id, support.COLUMN_NAME.DONE })
                testing.eq(out:find("is not on trunk", 1, true), nil, out)
                testing.eq(code, 0, out)
                testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
            end
        )
    end

    testing.test("carry_proof writes nothing for a commit whose patch differs", function()
        -- Verify a card, then change its work so its patch differs
        local project = carry_project()
        local id = review_ready(project)
        assert(fs.write(project.root .. "/work.txt", "two\n"), "write failed")

        -- Rebase it past a trunk move and count its comments
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        local before = #comments(project.home, id)

        -- Carry and write nothing
        local out = dev(project, { "carry", id })
        testing.ok(out:find("carry: nil", 1, true), out)
        testing.eq(#comments(project.home, id), before)

        -- Refuse the move to Release
        local moved, code = move_to_release(project, id)
        testing.eq(code, 1, moved)
        testing.ok(column_of(project.home, id) ~= support.COLUMN_NAME.RELEASE)
    end)

    local function squashed_parent(project)
        -- Stack the change on a described parent with content
        stack_on_parent(project, { args = { "-m", "test: parent" }, body = "mid\n" })

        -- Verify the card and note its commit
        local id = verified_card(project)
        local checked_at = head(project.root)

        -- Squash the parent into the change
        jj(project.root, "squash", "--from", "@-", "--into", "@", "--use-destination-message")
        testing.ok(head(project.root) ~= checked_at, "the squash must rewrite the commit")
        return id, checked_at
    end

    testing.test("land carries the check across a squash that leaves the tree identical", function()
        -- Squash the parent into a verified card
        local project = jj_project()
        local id, checked_at = squashed_parent(project)

        -- Refuse for the reviews while the check carries over
        local out = refused(project, id, {
            "The check at commit " .. checked_at:sub(1, 12) .. " carries over",
            "The code review is of an earlier commit",
            "The style review is of an earlier commit",
        })
        testing.eq(out:find("No run of `dev board check`", 1, true), nil, out)

        -- Review it afresh and land it
        approve_reviews(project, id)
        local landed, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, landed)

        -- Note the carried check and reach Done
        local list = comments(project.home)
        carried_note(list[#list].body, checked_at, "The check was ")
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("land keeps the check stale after a squash that changes the tree", function()
        -- Squash the parent into a verified card
        local project = jj_project()
        local id = squashed_parent(project)

        -- Change the tree after the squash
        assert(fs.write(project.root .. "/extra.txt", "extra\n"), "write failed")

        -- Refuse for want of a check run and say nothing carries over
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
        local before = head(project.root)
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

        -- Check the carried check note and the five reads
        local list = comments(project.home)
        carried_note(list[#list].body, before)
        testing.eq(
            fs.read(reads),
            table.concat({ "fetch", "fetch", "fetch", "fetch", "fetch", "" }, "\n")
        )
    end)

    local function recheck_project(row)
        return jj_project(table.concat({
            "",
            "[board.land]",
            'recheck = ["' .. row .. '"]',
            "",
        }, "\n"))
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

    testing.test("land reruns the recheck rows when a binary file changes", function()
        -- Check a commit that holds a binary file, then change the file's bytes
        local project = jj_project()
        assert(fs.write(project.root .. "/blob.bin", "a\0one\0"), "write failed")
        local before = head(project.root)
        assert(fs.write(project.root .. "/blob.bin", "a\0two\0"), "write failed")
        testing.ok(head(project.root) ~= before, "the commit did not change")

        -- Recheck the new commit and expect the row to run and fail
        local ran = 0
        local problem = land.recheck_problem({
            root = project.root,
            commit = before,
            card = "abc12345",
            rows = { "false" },
            note = function()
                ran = ran + 1
            end,
        })
        testing.eq(ran, 1)
        testing.ok(problem and problem:find("recheck row failed", 1, true), tostring(problem))
    end)

    testing.test("land takes no turn while the recheck rows run", function()
        -- Set up a recheck row that copies the board while it runs
        local snapshot = support.tempdir() .. "/board.json"
        local project = recheck_project("bin/snap")
        local script = table.concat({
            "#!/bin/sh",
            'cp "' .. support.board_file(project.home, "mine") .. '" "$SNAPSHOT"',
            "",
        }, "\n")
        assert(fs.write(project.root .. "/bin/snap", script), "write failed")
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
        -- Start a row script that logs each run
        local script = support.tempdir() .. "/rows.sh"
        local project = recheck_project("sh " .. script)
        local lines = { "#!/bin/sh", "echo run >>" .. runs }

        -- Make the script move trunk when asked to
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

        -- Write the script and hand back the project
        assert(fs.write(script, table.concat(lines, "\n")), "write failed")
        return project
    end

    testing.test("land keeps a held turn and stretches it for the recheck", function()
        -- Set up a recheck row that copies the board while it runs
        local snapshot = support.tempdir() .. "/board.json"
        local project = recheck_project("bin/snap")
        local script = table.concat({
            "#!/bin/sh",
            'cp "' .. support.board_file(project.home, "mine") .. '" "$SNAPSHOT"',
            "",
        }, "\n")
        assert(fs.write(project.root .. "/bin/snap", script), "write failed")
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
        testing.eq(fs.read(runs), table.concat({ "run", "run", "" }, "\n"))

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

    testing.test("a failed recheck puts a hold back to its own lease", function()
        -- Hold the turn, then land onto a moved trunk with a failing recheck row
        local project = recheck_project("false")
        local id = review_ready(project)
        trunk_moves(project, { ["shared.txt"] = NEAR_EDIT })
        rebase_onto_trunk(project.root)
        must(dev(project, { "board", "turn", id }))
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)

        -- Check the kept hold expires within its own lease plus a minute
        local doc = assert(
            json.decode(assert(fs.read(support.board_file(project.home, "mine")))),
            "decode failed"
        )
        local claim
        for _, card in ipairs(doc.cards) do
            if card.name == turn.NAME then
                claim = card.claim
            end
        end
        testing.ok(type(claim) == "table", "the hold was not kept")
        testing.ok(
            claim.expires_at <= store.stamp(os.time() + turn.HOLD_SECONDS + 60),
            claim.expires_at
        )
    end)

    testing.test("land skips the recheck rows over unrelated trunk files", function()
        -- Set up a recheck row that leaves a marker and move trunk far from the patch
        local marker = support.tempdir() .. "/rechecked"
        local project = recheck_project("touch " .. marker)
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n", ["shared.txt"] = FIRST_EDIT })
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
        local config = table.concat({
            "[board]",
            'backend = "local"',
            'name = "mine"',
            "",
            "[board.land]",
            'recheck = ["false"]',
            "",
        }, "\n")
        assert(fs.write(project.root .. "/.dev/config.toml", config), "write failed")

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
        -- Verify a card and rebase it past a trunk move
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Land it through a stub whose push is rejected
        local out, code = dev(project, { "board", "land", id }, {
            LAND_CODE = "1",
            LAND_MSG = "push rejected: trunk moved",
        })

        -- Report the failed jj land and leave the card in Verify
        testing.eq(code, 1, out)
        testing.ok(out:find("`jj land` failed with this output.", 1, true), out)
        testing.ok(out:find("push rejected: trunk moved", 1, true), out)
        testing.eq(column_of(project.home), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("land does not carry a pass over a failed run at the rebased commit", function()
        -- Verify a card whose check fails once trunk adds the file, and rebase it
        local project = jj_project()
        local id = review_ready(project, "! test -e docs.txt")
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Run the check at the rebased commit and see it fail
        local out, code = dev(project, { "board", "check", id })
        testing.ok(code ~= 0, out)

        -- Refuse the land for the failed row
        refused(project, id, { "did not pass every row" })
    end)

    testing.test("land does not carry over an expect-fail record at the rebased commit", function()
        -- Verify a card and rebase it past a trunk move
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Record an expect-fail check at the rebased commit
        dev(project, { "board", "check", id, "--expect-fail" })

        -- Refuse the land for want of a passing run
        refused(project, id, { "No run of `dev board check` is recorded" })
    end)

    testing.test("land does not carry over an unreadable record at the rebased commit", function()
        -- Verify a card and rebase it past a trunk move
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Note an unreadable check record at the rebased commit
        local record = table.concat({
            "dev-check: commit=" .. head(project.root) .. " change=chg mode=run",
            "1 pass dev lint",
        }, "\n")
        local backend, restore = board_at(project.home)
        for _, card in ipairs(assert(backend:cards())) do
            if card.id:sub(1, #id) == id then
                assert(backend:note(card.id, record))
            end
        end
        restore()

        -- Refuse the land and ask for a fresh check
        refused(project, id, { "could not be read", "Run `dev board check` again." })
    end)

    testing.test("clean rebase carries the check", function()
        -- Verify a card and note its commit
        local project = jj_project()
        local id = review_ready(project)
        local before = head(project.root)

        -- Move trunk over the shared file's first line and rebase cleanly
        trunk_moves(project, { ["shared.txt"] = FIRST_EDIT })
        rebase_onto_trunk(project.root)
        testing.ok(head(project.root) ~= before, "the rebase must rewrite the commit")

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Note the carry in the done comment and reach Done
        local list = comments(project.home)
        carried_note(list[#list].body, before)
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
        -- Verify a card and give a child workspace a clashing file
        local project = jj_project()
        local id = review_ready(project)
        local dir = child_workspace(project, "kid", { ["docs.txt"] = "child docs\n" })
        trunk_moves(project, { ["docs.txt"] = "docs\n" })

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Name the workspace it left alone
        local left = "Left the workspace kid at " .. dir .. " alone: its commit has conflicts"
        testing.ok(out:find(left, 1, true), out)
        testing.eq(out:find("Moved the workspace kid", 1, true), nil, out)
    end)

    testing.test("a rebase that leaves a conflict does not carry the check", function()
        -- Verify a card
        local project = jj_project()
        local id = review_ready(project)

        -- Rebase it onto a trunk edit that clashes with its own
        trunk_moves(project, { ["shared.txt"] = LAST_CLASH })
        rebase_onto_trunk(project.root)

        -- Refuse because the commit holds conflicts
        refused(project, id, {
            "The working-copy commit has conflicts",
            "run `dev board check` again",
        })
    end)

    testing.test(
        "land names only the unticked outcome after a rebase that the carry accepts",
        function()
            -- Put the shared file on trunk and rebase onto it
            local project = jj_project()
            trunk_moves(project, { ["shared.txt"] = SHARED })
            rebase_onto_trunk(project.root)

            -- Change the file and bring a card to Verify with its reviews and check
            assert(fs.write(project.root .. "/shared.txt", LAST_EDIT), "write failed")
            local id = new_card(project)
            to_verify(project, id)
            approve_reviews(project, id)
            must(dev(project, { "board", "check", id }))

            -- Move trunk and rebase again
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)

            -- Refuse for the unticked outcomes alone
            local out = refused(project, id, { "3 of 3 outcomes are unticked" })
            testing.eq(out:find("review of", 1, true), nil, out)
            testing.eq(out:find("No run of `dev board check`", 1, true), nil, out)
        end
    )

    testing.test("land names the column beside the carry after an accepted rebase", function()
        -- Verify a card and move it back to In Progress
        local project = jj_project()
        local id = review_ready(project)
        must(dev(project, { "board", "move", id, support.Column.PROGRESS }))

        -- Move trunk and rebase onto it
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Refuse naming the column, not the carry
        local out = refused(project, id, { "only a card in" })
        testing.eq(out:find("earlier commit", 1, true), nil, out)
        testing.eq(out:find("No run of `dev board check`", 1, true), nil, out)
    end)

    testing.test("land carries over a rebase past a changed former shared path", function()
        -- Verify a card and move trunk over a path it shares
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["lib/core.txt"] = "core\n" })
        rebase_onto_trunk(project.root)

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Reach Done
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("land refuses the carry when jj cannot compare the checked commit", function()
        -- Verify a card
        local project = jj_project()
        local id = review_ready(project)

        -- Move trunk and rebase onto it
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Refuse when the interdiff fails
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
            -- Verify a change over a described parent and note its commit
            local project = jj_project()
            stack_on_parent(project, { args = { "-m", "feat: parent" }, body = "mid\n" })
            local id = verified_card(project)
            local before = head(project.root)

            -- Land the parent on trunk rewritten
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            jj(project.root, "rebase", "-s", "@-", "-d", "master")
            jj(project.root, "bookmark", "set", "master", "-r", "@-")
            jj(project.root, "git", "push", "--remote", "origin", "--bookmark", "master")
            testing.ok(head(project.root) ~= before, "the rebase must rewrite the child")

            -- Land the child through the stub
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)

            -- Note the carry in the done comment and reach Done
            local list = comments(project.home)
            carried_note(list[#list].body, before)
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test(
        "land refuses a rebase that changes the patch and names the checked commit",
        function()
            -- Verify a card and note its commit
            local project = jj_project()
            local id = review_ready(project)
            local before = head(project.root)

            -- Change the patch, then rebase onto a trunk edit
            assert(fs.write(project.root .. "/shared.txt", LAST_OTHER), "write failed")
            trunk_moves(project, { ["shared.txt"] = FIRST_EDIT })
            rebase_onto_trunk(project.root)

            -- Refuse, naming the checked commit
            refused(project, id, {
                "This commit differs from the checked commit " .. before:sub(1, 12),
            })
        end
    )

    testing.test(
        "land refuses the carry when the checked commit sat off trunk's ancestry",
        function()
            -- Put the shared file on trunk and start a side commit off it
            local project = jj_project()
            trunk_moves(project, { ["shared.txt"] = SHARED })
            jj(project.root, "new", "master", "-m", "side")
            assert(fs.write(project.root .. "/side.txt", "side\n"), "write failed")

            -- Start the work on the side commit and change the shared file
            jj(project.root, "new", "-m", "feat: work")
            assert(fs.write(project.root .. "/shared.txt", LAST_EDIT), "write failed")

            -- Verify the card, move trunk and rebase onto it
            local id = verified_card(project)
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)

            -- Refuse, since the checked commit is off trunk's ancestry
            refused(project, id, { "does not sit on a single ancestor of trunk" })
        end
    )

    testing.test("land refuses a carry from a checked commit of another change", function()
        -- Bring a card to Verify with its outcomes ticked
        local project = jj_project()
        local id = new_card(project)
        to_verify(project, id)
        tick_all(project, id)

        -- Build records at the trunk commit, which is of another change
        local trunk = jj(project.root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
        local change = jj(project.root, "log", "-r", "@", "--no-graph", "-T", "change_id")
        local at = { commit = trunk, change = change }
        local records = {
            check.record(at, { { result = check.Result.PASS, run_id = "-", run = "true" } }, false),
            review.record(review.Kind.CODE, "rev", at, review.Verdict.CLEAN),
            review.record(review.Kind.STYLE, "rev", at, review.Verdict.CLEAN),
        }

        -- Note them on the card
        local backend, restore = board_at(project.home)
        for _, card in ipairs(assert(backend:cards())) do
            if card.id:sub(1, #id) == id then
                for _, body in ipairs(records) do
                    assert(backend:note(card.id, body))
                end
            end
        end
        restore()

        -- Refuse and leave the card as it was
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
        -- Put the shared file on trunk and rebase onto it
        local project = opts.project
        trunk_moves(project, { ["shared.txt"] = SHARED })
        rebase_onto_trunk(project.root)

        -- Add a card with its outcomes ticked
        assert(fs.write(project.root .. "/shared.txt", LAST_EDIT), "write failed")
        local id = new_card(project)
        to_verify(project, id)
        tick_all(project, id)

        -- Review and check a first commit
        local older = reviewed_and_checked({ project = project, id = id })

        -- Change the file and check a second commit
        assert(fs.write(project.root .. "/shared.txt", LAST_OTHER), "write failed")
        local newer = reviewed_and_checked({ project = project, id = id })

        -- Make the final edit and rebase past a trunk move
        assert(fs.write(project.root .. "/shared.txt", opts.final_shared), "write failed")
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)
        return id, older, newer
    end

    local function carry_commits(final_shared)
        local project = jj_project()
        local id, older, newer = two_checked_commits({
            project = project,
            final_shared = final_shared,
        })
        return project, id, older, newer
    end

    testing.test("land carries from an older checked commit when the newest one differs", function()
        -- Build a card checked at two commits and rebased past a trunk move
        local project, id, older = carry_commits(LAST_EDIT)

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Note the carry from the older checked commit
        local list = comments(project.home)
        carried_note(list[#list].body, older)
    end)

    testing.test("a commit with two passing runs still carries", function()
        -- Put the shared file on trunk and rebase onto it
        local project = jj_project()
        trunk_moves(project, { ["shared.txt"] = SHARED })
        rebase_onto_trunk(project.root)

        -- Add a card with its outcomes ticked
        assert(fs.write(project.root .. "/shared.txt", LAST_EDIT), "write failed")
        local id = new_card(project)
        to_verify(project, id)
        tick_all(project, id)

        -- Check the first commit twice
        local older = reviewed_and_checked({ project = project, id = id })
        must(dev(project, { "board", "check", id }))

        -- Change the file and check a second commit
        assert(fs.write(project.root .. "/shared.txt", LAST_OTHER), "write failed")
        reviewed_and_checked({ project = project, id = id })

        -- Restore the first patch, move trunk and rebase onto it
        assert(fs.write(project.root .. "/shared.txt", LAST_EDIT), "write failed")
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Note the carry from the first commit
        local list = comments(project.home)
        carried_note(list[#list].body, older)
    end)

    testing.test(
        "land carries a checked commit whose reviews sit at an earlier identical patch",
        function()
            -- Bring a card to Verify with its reviews
            local project = jj_project()
            local id = new_card(project)
            to_verify(project, id)
            tick_all(project, id)
            approve_reviews(project, id)

            -- Re-describe the commit and check it afresh
            jj(project.root, "describe", "-m", "feat: work again")
            must(dev(project, { "board", "check", id }))
            local at_check = head(project.root)

            -- Move trunk and rebase onto it
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)

            -- Land it through the stub
            local out, code = dev(
                project,
                { "board", "land", id },
                { LAND_TRUNK = LAND_TRUNK_KEEP }
            )
            testing.eq(code, 0, out)

            -- Note the carry from the checked commit
            local list = comments(project.home)
            carried_note(list[#list].body, at_check)
        end
    )

    local function seats_at(commit)
        return {
            seat(review.Kind.CODE, review.SeatVerdict.APPROVED, commit),
            seat(review.Kind.STYLE, review.SeatVerdict.APPROVED, commit),
            seat(review.Kind.RECHECK, review.SeatVerdict.APPROVED, commit),
        }
    end

    local function stale_line(name, answered, landing)
        return "The reviewer seat "
            .. name
            .. " approved commit "
            .. land.short(answered)
            .. ", not the commit "
            .. land.short(landing)
            .. " that would land."
    end

    testing.test("a seat that answered an earlier commit with an empty interdiff is met", function()
        local project = jj_project()
        local answered = head(project.root)
        jj(project.root, "describe", "-m", "feat: work again")
        local landing = head(project.root)
        local seats = seats_at(answered)
        testing.eq(land.seats_problem(seats, landing, seat_opts()), {
            stale_line(review.Kind.CODE, answered, landing),
            stale_line(review.Kind.STYLE, answered, landing),
            stale_line(review.Kind.RECHECK, answered, landing),
        })
        local opts = { comments = {}, root = project.root }
        testing.eq(land.seats_problem(seats, landing, opts), {})
        local changes = seat(review.Kind.CODE, review.SeatVerdict.CHANGES_NEEDED, answered)
        testing.eq(land.seats_problem({ changes }, landing, opts), {
            "The reviewer seat " .. review.Kind.CODE .. " asks for changes.",
        })
    end)

    testing.test("a seat at an earlier commit with a changed patch is refused", function()
        local project = jj_project()
        local answered = head(project.root)
        assert(fs.write(project.root .. "/more.txt", "more\n"), "write failed")
        local landing = head(project.root)
        testing.ok(landing ~= answered)
        local opts = { comments = {}, root = project.root }
        testing.eq(land.seats_problem(seats_at(answered), landing, opts), {
            stale_line(review.Kind.CODE, answered, landing),
            stale_line(review.Kind.STYLE, answered, landing),
            stale_line(review.Kind.RECHECK, answered, landing),
        })
    end)

    local function checked_past_reviews(project)
        -- Bring a card to Verify with its reviews
        local id = new_card(project)
        to_verify(project, id)
        tick_all(project, id)
        approve_reviews(project, id)

        -- Change a file and check the new commit
        assert(fs.write(project.root .. "/other.txt", "other\n"), "write failed")
        must(dev(project, { "board", "check", id }))

        -- Hand back the card and the commit checked
        return id, head(project.root)
    end

    testing.test(
        "land carries only the check of a commit whose reviews sit at a different patch",
        function()
            -- Check a commit past its reviews
            local project = jj_project()
            local id, at_check = checked_past_reviews(project)

            -- Move trunk and rebase onto it
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)

            -- Refuse for the reviews while the check carries
            local out = refused(project, id, {
                "The check at commit " .. at_check:sub(1, 12) .. " carries over",
                "The code review is of an earlier commit",
            })
            testing.eq(out:find("No run of `dev board check`", 1, true), nil, out)
        end
    )

    testing.test("land carries a check from a commit with no reviews", function()
        -- Check a commit past its reviews
        local project = jj_project()
        local id, at_check = checked_past_reviews(project)

        -- Move trunk and rebase onto it
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Recheck both kinds
        for _, of in ipairs({ "code", "style" }) do
            must(record_review(project, id, { kind = "recheck", of = of, by = "re-" .. of }))
        end

        -- Land it and note the carry from the checked commit
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.ok(code == 0, out)
        local list = comments(project.home)
        carried_note(list[#list].body, at_check)
    end)

    testing.test("land refuses a check with no reviews across a changed patch", function()
        -- Check a commit past its reviews
        local project = jj_project()
        local id = checked_past_reviews(project)

        -- Change the patch, move trunk and rebase onto it
        assert(fs.write(project.root .. "/more.txt", "more\n"), "write failed")
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Refuse for want of a run, with nothing carried over
        local out = refused(project, id, { "No run of `dev board check`" })
        testing.eq(out:find("carried over", 1, true), nil, out)
    end)

    testing.test("land names the newest checked commit when no candidate carries", function()
        local project, id, older, newer = carry_commits(LAST_ODD)
        local out = refused(project, id, { "differs from the checked commit " .. newer:sub(1, 12) })
        testing.eq(out:find(older:sub(1, 12), 1, true), nil, out)
    end)

    testing.test("land refuses at once when jj cannot read the newest checked commit", function()
        local project, id, older, newer = carry_commits(LAST_EDIT)
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
            local project, id, older, newer = carry_commits(LAST_EDIT)
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
            local project, id, older, newer = carry_commits(LAST_EDIT)
            local out = refused(project, id, { case.message }, { [case.switch] = older })
            testing.eq(out:find("carried over", 1, true), nil, out)
            testing.eq(out:find(newer:sub(1, 12), 1, true), nil, out)
        end)
    end

    testing.test("land names the older candidate when its interdiff read fails", function()
        local project, id, older = carry_commits(LAST_ODD)
        refused(
            project,
            id,
            { "The `jj` command could not compare the checked commit " .. older:sub(1, 12) },
            { INTERDIFF_FAIL_AT = older }
        )
    end)

    testing.test("land refuses a rebase of a commit that differs from the checked one", function()
        -- Verify a card and note its commit
        local project = jj_project()
        local id = review_ready(project)
        local before = head(project.root)

        -- Change the patch, move trunk and rebase onto it
        assert(fs.write(project.root .. "/shared.txt", LAST_OTHER), "write failed")
        trunk_moves(project, { ["docs.txt"] = "docs\n" })
        rebase_onto_trunk(project.root)

        -- Refuse, naming the checked commit
        refused(project, id, { "differs from the checked commit " .. before:sub(1, 12) })
    end)

    testing.test(
        "land refuses a duplicate of the checked change under another change id",
        function()
            -- Verify a card
            local project = jj_project()
            local id = review_ready(project)

            -- Duplicate the change and edit the copy
            jj(project.root, "duplicate", "@")
            local copy =
                jj(project.root, "log", "-r", "children(@-) ~ @", "--no-graph", "-T", "change_id")
            jj(project.root, "edit", copy)

            -- Refuse since the copy has no reviews
            local out = refused(project, id, { "No code review of change" })
            testing.eq(out:find("carried over", 1, true), nil, out)
        end
    )

    testing.test(
        "land carries only the check when a review was never recorded at the checked commit",
        function()
            -- Put the shared file on trunk and rebase onto it
            local project = jj_project()
            trunk_moves(project, { ["shared.txt"] = SHARED })
            rebase_onto_trunk(project.root)

            -- Record one review and a check, leaving the style review out
            local id = new_card(project)
            to_verify(project, id)
            must(record_review(project, id))
            must(dev(project, { "board", "check", id }))
            local at_check = head(project.root)
            tick_all(project, id)

            -- Move trunk and rebase again
            trunk_moves(project, { ["docs.txt"] = "docs\n" })
            rebase_onto_trunk(project.root)

            -- Refuse once for the style review, with the check carried
            local out = refused(project, id, { "No style review of change" })
            testing.ok(
                out:find("The check at commit " .. at_check:sub(1, 12) .. " carries over", 1, true),
                out
            )
            local _, repeats = out:gsub("No style review of change", "")
            testing.eq(repeats, 1, out)
        end
    )

    testing.test("land refuses a working copy that holds conflicts", function()
        -- Bring a card to Verify and note its change
        local project = jj_project()
        local id = new_card(project)
        to_verify(project, id)
        local first = jj(project.root, "log", "-r", "@", "--no-graph", "-T", "change_id")

        -- Rebase a clashing change onto it
        jj(project.root, "new", "master", "-m", "feat: other")
        assert(fs.write(project.root .. "/work.txt", "two\n"), "write failed")
        jj(project.root, "rebase", "-r", "@", "-d", first)

        -- Refuse for the conflicts
        refused(project, id, {
            "The working-copy commit has conflicts",
            "run `dev board check` again",
        })
    end)

    testing.test("land refuses a card labelled needs:human", function()
        -- Move a card to Blocked
        local project = jj_project()
        local id = new_card(project)
        must(dev(project, { "board", "move", id, support.Column.BLOCKED }))

        -- Label it needs:human on the board
        local doc = board_doc(project.home)
        for _, card in ipairs(doc.cards) do
            if card.id:sub(1, #id) == id then
                card.labels = { board.NEEDS_HUMAN }
            end
        end
        assert(fs.write(support.board_file(project.home, "mine"), assert(json.encode(doc))))

        -- Refuse, naming the owner
        refused(project, id, { "is labelled needs:human", "waits on the owner" })
    end)

    testing.test("land refuses when the fetch from the remote of record fails", function()
        -- Verify a card
        local project = jj_project()
        local id = verified_card(project)

        -- Point the remote of record at nothing
        jj(project.root, "git", "remote", "set-url", "origin", project.root .. "/missing-remote")

        -- Refuse for the failed fetch
        refused(project, id, { "Trunk cannot be compared", "The fetch from origin failed" })
    end)

    testing.test("land retries a refused ssh signature once", function()
        -- Verify a card and name a file that counts refusals
        local project = jj_project()
        local id = review_ready(project)
        local count = support.tempdir() .. "/count.log"

        -- Land it through a stub that refuses the first fetch
        local out, code = dev(
            project,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, FETCH_REFUSALS = "1", FETCH_COUNT = count }
        )
        testing.eq(code, 0, out)

        -- See one refusal and a landing after the retry
        testing.eq(fs.read(count), "1\n")
        testing.ok(out:find("landed " .. id, 1, true), out)
    end)

    testing.test("land names the hardware key after a second refusal", function()
        -- Verify a card and name a file that counts refusals
        local project = jj_project()
        local id = review_ready(project)
        local count = support.tempdir() .. "/count.log"

        -- Refuse for the hardware key once a stub refuses every fetch
        refused(project, id, {
            "The fetch from origin failed",
            "Touch the hardware key",
            "run `dev board land` again.",
        }, { FETCH_REFUSALS = "5", FETCH_COUNT = count })

        -- See exactly two attempts
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
        -- Make a project to land in
        local project = jj_project()

        -- Serve a card whose comments time out
        local backend = fake_backend(project.root)
        function backend:comments()
            return nil, "Board unavailable: comments timed out"
        end

        -- Land the card and name the outage
        local result = land_as_lander(backend)
        testing.eq(result.code, 1)
        testing.eq(result.message, "Board unavailable: comments timed out.")

        -- Write no note
        testing.eq(backend.notes, {})
    end)

    testing.test("land refuses when the board's cards cannot be read", function()
        -- Make a project to land in
        local project = jj_project()

        -- Serve a board whose cards time out
        local backend = fake_backend(project.root)
        function backend:cards()
            return nil, "Board unavailable: cards timed out"
        end

        -- Land the card and name the outage
        local result = land_as_lander(backend)
        testing.eq(result.code, 1)
        testing.eq(result.message, "Board unavailable: cards timed out.")

        -- Write no note
        testing.eq(backend.notes, {})
    end)

    testing.test("land names outcomes that cannot be read and does not land", function()
        -- Make a project to land in
        local project = jj_project()

        -- Serve a card whose outcomes cannot be read
        local backend = fake_backend(project.root, { outcomes_unreadable = true })

        -- Land the card and name the reasons
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

        -- Write no note
        testing.eq(backend.notes, {})
    end)

    testing.test("land names a renamed Done column for unreadable outcomes", function()
        -- Serve a card with unreadable outcomes and a renamed Done column
        local project = jj_project()
        local backend = fake_backend(project.root, { outcomes_unreadable = true })
        backend.column_map = { done = "Shipped" }

        -- Land the card and name the renamed column
        local result = land_as_lander(backend)
        testing.eq(result.code, 1)
        testing.ok(
            result.message:find("cannot move to Shipped. Its outcomes", 1, true),
            result.message
        )
    end)

    testing.test("land names a renamed Done column for unticked outcomes", function()
        -- Serve a card with an unticked outcome and a renamed Done column
        local project = jj_project()
        local backend = fake_backend(project.root, {
            outcomes = { { id = "o1", name = "It works", done = false } },
        })
        backend.column_map = { done = "Shipped" }

        -- Land the card and name the renamed column
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
        -- Verify a card and push trunk
        local project = jj_project()
        local id = verified_card(project)
        push_trunk(project)

        -- Refuse once the stub fails the rebase
        local FAIL_AT = { REBASE = "rebase" }
        refused(project, id, { "The rebase onto trunk failed" }, { LOG_FAIL_AT = FAIL_AT.REBASE })

        -- Leave the card in Verify and free the turn
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test(
        "land refuses a rebase of its own that leaves conflicts and frees the turn",
        function()
            -- Verify a card and move trunk over a line its patch changes
            local project = jj_project()
            local id = review_ready(project)
            trunk_moves(project, { ["shared.txt"] = LAST_CLASH })

            -- Refuse for the conflicts
            refused(project, id, { "The working-copy commit has conflicts" })

            -- Leave the card in Verify and free the turn
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
        -- Serve a card and leave only sh on the path
        local project = jj_project()
        local backend = fake_backend(project.root)
        local original = dev_os.getenv("PATH")
        local bare = support.tempdir()
        must(dev_os.run({ "ln", "-s", assert(dev_os.which("sh")), bare .. "/sh" }))
        dev_os.setenv("PATH", bare)

        -- Land the card and restore the path
        local ok, result = pcall(land_as_lander, backend)
        dev_os.setenv("PATH", original)
        assert(ok, result)

        -- Refuse naming the worktree and write no note
        testing.eq(result.code, 1)
        testing.ok(
            result.message:find("could not read the worktree of " .. project.root, 1, true),
            result.message
        )
        testing.eq(backend.notes, {})
    end)

    local function land_through_stub(project, id, wrap, opts)
        -- Wrap the backend and build the environment of a lander
        opts = opts or {}
        local backend, restore = board_at(project.home)
        backend.root = project.root
        wrap(backend)
        local set = {
            PATH = project.root .. "/bin:" .. dev_os.getenv("PATH"),
            LAND_LOG = project.log,
            LAND_MSG = "stub land",
            REAL_JJ = dev_os.which("jj"),
            DEV_AGENT = "dotfiles/lander",
            JJ_USER = IDENT.JJ_USER,
            JJ_EMAIL = IDENT.JJ_EMAIL,
        }
        if opts.env then
            for name, value in pairs(opts.env) do
                set[name] = value
            end
        end

        -- Set the environment, remembering what it held
        local saved = {}
        for name, value in pairs(set) do
            saved[name] = dev_os.getenv(name) or ""
            dev_os.setenv(name, value)
        end

        -- Land the cards, from the project root when asked
        local ids = type(id) == "table" and id or { id }
        local ok, result = pcall(function()
            if not opts.in_root then
                return cmd_board.run("land", ids, backend)
            end
            local origin = assert(fs.realpath("."))
            assert(dev_os.chdir(project.root), "chdir failed")
            local landed, outcome = pcall(cmd_board.run, "land", ids, backend)
            dev_os.chdir(origin)
            assert(landed, outcome)
            return outcome
        end)

        -- Restore the environment and the board
        for name, value in pairs(saved) do
            dev_os.setenv(name, value)
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
            -- Verify a card
            local project = jj_project()
            local id = verified_card(project)

            -- Land it with a board that drops the color of a landed card
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

            -- Name the failed move and its causes
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
            -- Make an epic and approve it in Verify
            local project = jj_project()
            local id = new_card(project)
            must(dev(project, { "board", "epic", id }))
            to_verify(project, id)
            approve(project, id)

            -- Land it with a board that cannot read the family afterwards
            local result = land_through_stub(project, id, function(backend)
                local family = backend.family
                function backend:family(...)
                    if has_landed(project) then
                        return nil, "Board unavailable: family timed out"
                    end
                    return family(self, ...)
                end
            end)

            -- Name the failed move and the outage
            testing.eq(result.code, 1, result.message)
            testing.ok(result.message:find("The move to Done failed.", 1, true), result.message)
            testing.ok(
                result.message:find("Board unavailable: family timed out.", 1, true),
                result.message
            )
        end
    )

    local function two_cards(project)
        -- Verify the first card
        local first = verified_card(project)

        -- Bring the second card to Verify under its own workspace
        local second = second_card(project)
        to_verify(project, second)
        jj(project.root, "workspace", "rename", second)
        approve(project, second)

        -- Name the first card's workspace again
        jj(project.root, "workspace", "rename", first)
        return first, second
    end

    testing.test(
        "land exits 1 and names the stop when the landing stopped without a word",
        function()
            -- Verify a card and make the landing stop without output
            local project = jj_project()
            local id = verified_card(project)
            local held = wiring.land_held
            wiring.land_held = function()
                return { output = "" }
            end

            -- Land it and restore the wiring
            local ok, result = pcall(land_through_stub, project, id, function() end)
            wiring.land_held = held
            assert(ok, result)

            -- Name the stop and the card
            testing.eq(result.code, 1, result.output)
            testing.ok(result.message:find("landing stopped", 1, true), result.message)
            testing.ok(result.message:find(id:sub(1, board.MIN_PREFIX), 1, true), result.message)
        end
    )

    testing.test("land retries after trunk moved and closes both cards", function()
        -- Verify two cards and move trunk during the first attempt
        local project = jj_project()
        local first, second = two_cards(project)
        local held = wiring.land_held
        local attempts = 0
        wiring.land_held = function(opts)
            attempts = attempts + 1
            if attempts == 1 then
                trunk_moves(project, { ["docs.txt"] = "docs\n" })
            end
            return held(opts)
        end

        -- Land both cards and restore the wiring
        local ok, result = pcall(land_through_stub, project, { first, second }, function() end, {
            env = { LAND_TRUNK = LAND_TRUNK_KEEP },
            in_root = true,
        })
        wiring.land_held = held
        assert(ok, result)
        testing.ok(result.code == nil, result.message)
        testing.eq(attempts, 2)

        -- Settle each card in Done with its landed note
        for _, id in ipairs({ first, second }) do
            local list = comments(project.home, id)
            testing.eq(list[#list].kind, KIND_DONE)
            testing.ok(list[#list].body:find("Landed commit", 1, true), list[#list].body)
            testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
        end
    end)

    testing.test("land reports a companion whose done note fails and the push stands", function()
        -- Verify two cards
        local project = jj_project()
        local first, second = two_cards(project)

        -- Land both with a board that fails the second note
        local result = land_through_stub(project, { first, second }, function(backend)
            local note = backend.note
            function backend:note(id, ...)
                if has_landed(project) and id:sub(1, #second) == second then
                    return nil, "board unavailable: note timed out"
                end
                return note(self, id, ...)
            end
        end, { env = { LAND_TRUNK = LAND_TRUNK_KEEP } })

        -- Name the missing note
        testing.eq(result.code, 1, result.message)
        testing.ok(
            result.message:find(
                "The done note was NOT written on card " .. second:sub(1, board.MIN_PREFIX),
                1,
                true
            ),
            result.message
        )
        testing.ok(
            result.message:find("Board unavailable: note timed out.", 1, true),
            result.message
        )

        -- Let the push stand and move only the first card
        testing.ok(has_landed(project), "the land never ran")
        testing.eq(column_of(project.home, first), support.COLUMN_NAME.DONE)
        testing.eq(column_of(project.home, second), board.DEFAULT_NAMES.verify)
    end)

    testing.test(
        "a landed commit whose done note was not written is named and exits non-zero",
        function()
            -- Verify a card and note its commit
            local project = jj_project()
            local id = verified_card(project)
            local commit = head(project.root)

            -- Land it with a board file that breaks
            local out, code = dev(project, { "board", "land", id }, {
                LAND_TRUNK = LAND_TRUNK_KEEP,
                BREAK_BOARD = support.board_file(project.home, "mine"),
            })
            testing.eq(code, 1, out)

            -- Name the landed commit and the missing note
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
        -- Verify a card and push its change to trunk
        local project = jj_project()
        local id = verified_card(project)
        local commit = head(project.root)
        reached_trunk(project)

        -- Rerun land and settle without landing again
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 0, out)
        testing.ok(out:find("settled " .. id, 1, true), out)
        testing.ok(out:find("at commit " .. commit:sub(1, 12), 1, true), out)
        testing.eq(landed_calls(project.log), "")
        testing.eq(trunk_commit(project), commit)

        -- Note the landing on the card and move it to Done
        local list = comments(project.home, id)
        local last = list[#list]
        testing.eq(last.kind, KIND_DONE)
        testing.ok(last.body:find("Landed commit " .. commit:sub(1, 12), 1, true), last.body)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
    end)

    testing.test("a rerun of land names a check that did not pass at the landed commit", function()
        -- Bring a card to Verify with a check that fails
        local project = jj_project()
        local id = new_card(project)
        must(dev(project, { "board", "checks", id, "false" }))
        to_verify(project, id)
        approve_reviews(project, id)
        local _, failed = dev(project, { "board", "check", id })
        testing.ok(failed ~= 0, "the check must fail")
        tick_all(project, id)

        -- Push its change to trunk and rerun land
        reached_trunk(project)
        local out, code = dev(project, { "board", "land", id })

        -- Name the failing check and keep the card in Verify
        testing.eq(code, 1, out)
        testing.ok(out:find("its board half cannot finish", 1, true), out)
        testing.ok(out:find("did not pass every row", 1, true), out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("a rerun of land names the reviews a landed change lacks", function()
        -- Check a card in Verify without reviews and push its change to trunk
        local project = jj_project()
        local id = new_card(project)
        to_verify(project, id)
        must(dev(project, { "board", "check", id }))
        tick_all(project, id)
        reached_trunk(project)

        -- Rerun land and name the missing reviews
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("its board half cannot finish", 1, true), out)
        testing.ok(out:find("review", 1, true), out)

        -- Land nothing and keep the card in Verify
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("a rerun of land names a missing check run on a card in Verify", function()
        -- Review a card in Verify without a check and push its change to trunk
        local project = jj_project()
        local id = new_card(project)
        to_verify(project, id)
        approve_reviews(project, id)
        tick_all(project, id)
        reached_trunk(project)

        -- Rerun land and name the missing run
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("No run of `dev board check` is recorded on the card", 1, true), out)

        -- Land nothing and keep the card in Verify
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("land names trunk when a settle finds the checked change missing there", function()
        -- Verify a card and move the working copy off its change
        local project = jj_project()
        local id = verified_card(project)
        jj(project.root, "new")

        -- Rerun land and name trunk as the place the change is missing
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("The working-copy commit is empty", 1, true), out)
        testing.ok(out:find("Trunk does not hold the change checked at commit", 1, true), out)

        -- Land nothing
        testing.eq(landed_calls(project.log), "")
    end)

    testing.test("a rerun of land leaves a card whose change is not on trunk in Verify", function()
        -- Verify a card and move the working copy off its change
        local project = jj_project()
        local id = verified_card(project)
        jj(project.root, "new")

        -- Rerun land and name the empty working copy
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("The working-copy commit is empty", 1, true), out)

        -- Land nothing and keep the card in Verify
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    testing.test(
        "a fetch that fails after the land falls back to the commit from before it",
        function()
            -- Verify a card and note its commit
            local project = jj_project()
            local id = verified_card(project)
            local before = head(project.root)

            -- Land it through a stub that rewrites the commit and fails the fetch
            local out, code = dev(project, { "board", "land", id }, {
                LAND_TRUNK = LAND_TRUNK_REWRITE,
                FETCH_FAIL = "1",
            })
            testing.eq(code, 0, out)
            local after =
                jj(project.root, "log", "-r", "master@origin", "--no-graph", "-T", "commit_id")
            testing.ok(before ~= after, "the stub must rewrite the commit")

            -- Name the commit from before the land
            testing.ok(out:find("at commit " .. before:sub(1, 12), 1, true), out)
            testing.ok(out:find("trunk could not be read", 1, true), out)
            testing.eq(out:find(after:sub(1, 12), 1, true), nil, out)

            -- Note it as possibly different and reach Done
            local list = comments(project.home)
            local last = list[#list]
            testing.eq(last.kind, KIND_DONE)
            testing.ok(last.body:find(before:sub(1, 12), 1, true), last.body)
            testing.ok(last.body:find("may differ", 1, true), last.body)
            testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
        end
    )

    testing.test("a landed card whose move to Done fails is named and exits non-zero", function()
        -- Add a child card under an epic
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

        -- Approve the epic in Verify and take the turn
        to_verify(project, id)
        approve(project, id)
        must(dev(project, { "board", "turn", id }))
        local commit = head(project.root)

        -- Land it with the child still open
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

        -- Note the landing yet leave the card in Verify
        local list = comments(project.home, id)
        testing.eq(list[#list].kind, KIND_DONE)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    local function in_verify(project)
        local id = new_card(project)
        to_verify(project, id)
        return id
    end

    testing.test("a check gives back the landing turn the card holds", function()
        -- Take the landing turn for a card in Verify
        local project = jj_project()
        local id = in_verify(project)
        local out, code = dev(project, { "board", "turn", id })
        testing.eq(code, 0, out)
        testing.ok(out:find("Holding the landing turn for " .. id, 1, true), out)
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")

        -- Check the card and see the turn given back
        approve_reviews(project, id)
        out, code = dev(project, { "board", "check", id })
        testing.eq(code, 0, out)
        testing.ok(
            out:find(
                "A check never holds the landing turn. It was given back, and dev board land takes it again.",
                1,
                true
            ),
            out
        )
        testing.eq(turn_holder(project.home), nil)

        -- Land the card, which takes the turn again
        tick_all(project, id)
        out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test("a check with no hold on the card prints nothing about the turn", function()
        local project = jj_project()
        local id = in_verify(project)
        approve_reviews(project, id)
        local out, code = dev(project, { "board", "check", id })
        testing.eq(code, 0, out)
        testing.eq(out:find("landing turn", 1, true), nil)
    end)

    testing.test("a second runner is told who holds the turn and since when", function()
        -- Take the turn for a card in Verify
        local project = jj_project()
        local id = in_verify(project)
        must(dev(project, { "board", "turn", id }))

        -- Ask for it as another runner and name the holder
        local out, code = dev(
            project,
            { "board", "turn", id, "--wait", "0" },
            { DEV_AGENT = "dotfiles/other" }
        )
        testing.eq(code, 1, out)
        testing.ok(out:find("held by dotfiles/lander since 20", 1, true), out)

        -- Renew the hold as the holder
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
        -- Let another runner take the turn
        local project = jj_project()
        local id = in_verify(project)
        must(dev(project, { "board", "turn", id }, { DEV_AGENT = "dotfiles/other" }))

        -- Wait for the turn until the wait runs out
        local out, code = dev(project, { "board", "turn", id, "--wait", "1" })
        testing.eq(code, 1, out)

        -- Name the other holder and leave the turn with it
        testing.ok(out:find("cannot take the landing turn", 1, true), out)
        testing.ok(out:find("held by dotfiles/other since", 1, true), out)
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/other")
    end)

    testing.test("land lands under a live claim whose hold note is stale", function()
        -- Hold the turn on an approved card and let the hold note lapse
        local project = jj_project()
        local id = in_verify(project)
        approve(project, id)
        must(dev(project, { "board", "turn", id, "--hold", "1" }))
        lapse_hold(project)

        -- Renew the claim on the turn card
        local backend, restore = board_at(project.home)
        local cards = assert(backend:cards())
        for _, card in ipairs(cards) do
            if card.name == turn.NAME then
                assert(backend:claim(card.id, "dotfiles/lander", { ttl = 600, lease = true }))
            end
        end
        restore()

        -- Land the card under the live claim
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test("land refuses a hold that ran out and lands nothing", function()
        -- Hold the turn on an approved card and let the hold lapse
        local project = jj_project()
        local id = in_verify(project)
        approve(project, id)
        must(dev(project, { "board", "turn", id, "--hold", "1" }))
        lapse_hold(project)

        -- Refuse the land
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 1, out)
        testing.ok(out:find("ran out or was taken by another", 1, true), out)

        -- Land nothing and keep the card in Verify
        testing.eq(landed_calls(project.log), "")
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("land refuses a hold another runner took after it ran out", function()
        -- Hold the turn on an approved card and let the hold lapse
        local project = jj_project()
        local id = in_verify(project)
        approve(project, id)
        must(dev(project, { "board", "turn", id, "--hold", "1" }))
        lapse_hold(project)

        -- Let another runner take the turn
        must(dev(project, { "board", "turn", id }, { DEV_AGENT = "dotfiles/other" }))

        -- Refuse the land and leave the turn with the other runner
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 1, out)
        testing.ok(out:find("ran out or was taken by another", 1, true), out)
        testing.eq(landed_calls(project.log), "")
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/other")
    end)

    local function lost_hold_taken_by_other(project, id)
        must(dev(project, { "board", "turn", id, "--hold", LOST_HOLD_SECONDS }))
        lapse_hold(project)
        must(dev(project, { "board", "turn", id }, { DEV_AGENT = "dotfiles/other" }))
    end

    local function land_waiting(project, id, seconds)
        -- Act as the lander on the board
        local backend, restore = board_at(project.home)
        backend.root = project.root
        local previous = dev_os.getenv("DEV_AGENT") or ""
        dev_os.setenv("DEV_AGENT", "dotfiles/lander")

        -- Land with a wait
        local ok, result = pcall(cmd_board.run, "land", { id, "--wait", seconds }, backend)

        -- Restore the agent and the board
        dev_os.setenv("DEV_AGENT", previous)
        restore()
        assert(ok, result)
        return result
    end

    testing.test("land --wait waits out another holder after its own hold ran out", function()
        -- Lose the hold to another runner
        local project = jj_project()
        local id = verified_card(project)
        lost_hold_taken_by_other(project, id)

        -- Fake the clock so each nap advances it
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

        -- Land with a short wait and restore the clock
        local result = land_waiting(project, id, SHORT_WAIT_SECONDS)
        dev_os.nap = nap
        store.now = now

        -- Name the other holder after the wait ran out
        testing.eq(result.code, 1, result.message)
        testing.ok(result.message:find("held by dotfiles/other since", 1, true), result.message)
        testing.eq(result.message:find("ran out or was taken", 1, true), nil)
        testing.ok(naps > 0, "the wait never slept")
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/other")
    end)

    testing.test("land --wait takes the turn once the other holder lets go", function()
        -- Lose the hold to another runner
        local project = jj_project()
        local id = verified_card(project)
        lost_hold_taken_by_other(project, id)

        -- Release it and block the card during the first nap
        local nap = dev_os.nap
        dev_os.nap = function()
            dev_os.nap = nap
            local other = { DEV_AGENT = "dotfiles/other" }
            must(dev(project, { "board", "turn", id, "--release" }, other))
            must(dev(project, { "board", "move", id, support.Column.BLOCKED }))
        end

        -- Land with a long wait
        local result = land_waiting(project, id, LONG_WAIT_SECONDS)
        dev_os.nap = nap

        -- Refuse the blocked card after taking and freeing the turn
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
        -- Claim a card as the builder and shorten the claim
        local project = jj_project()
        local id = new_card(project)
        local builder = { DEV_AGENT = "dotfiles/builder" }
        must(dev(project, { "board", "move", id, support.Column.PROGRESS }, builder))
        local short = shortened_claim(project, id)
        local fence = claim_of(project.home, id).fence

        -- Check the card as the builder
        local out, code = dev(project, { "board", "check", id }, builder)
        testing.eq(code, 0, out)
        testing.eq(out:find("not renewed", 1, true), nil, out)

        -- Keep the fence and push the expiry out
        local claim = claim_of(project.home, id)
        testing.eq(claim.fence, fence)
        testing.ok(claim.expires_at > short, claim.expires_at)
    end)

    testing.test("a check by another name renews no claim", function()
        -- Claim a card as the builder and shorten the claim
        local project = jj_project()
        local id = new_card(project)
        local builder = { DEV_AGENT = "dotfiles/builder" }
        must(dev(project, { "board", "move", id, support.Column.PROGRESS }, builder))
        local short = shortened_claim(project, id)

        -- Check the card as another runner
        local out, code = dev(project, { "board", "check", id }, { DEV_AGENT = "dotfiles/other" })
        testing.eq(code, 0, out)

        -- Leave the expiry as it was
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
        -- Take a verified card and shorten the claim
        local project = jj_project()
        local id = verified_card(project)
        must(dev(project, { "board", "take", id }))
        local short = shortened_claim(project, id)

        -- Land it through a stub that fails
        local out, code = dev(project, { "board", "land", id }, { LAND_CODE = "1" })
        testing.eq(code, 1, out)
        testing.eq(out:find("not renewed", 1, true), nil, out)

        -- Push the expiry out
        testing.ok(claim_of(project.home, id).expires_at > short, out)
    end)

    testing.test("a review record leaves the claimant's claim as it was", function()
        -- Claim a card as the builder and shorten the claim
        local project = jj_project()
        local id = new_card(project)
        local builder = { DEV_AGENT = "dotfiles/builder" }
        must(dev(project, { "board", "move", id, support.Column.PROGRESS }, builder))
        local short = shortened_claim(project, id)
        local fence = claim_of(project.home, id).fence

        -- Record a review by another name
        local out, code = record_review(project, id, { by = "dotfiles/code-examiner/x" })
        testing.eq(code, 0, out)

        -- Leave the claim untouched
        local claim = claim_of(project.home, id)
        testing.eq(claim.fence, fence)
        testing.eq(claim.expires_at, short)
    end)

    testing.test("a move by the claimant renews its claim", function()
        -- Claim a card as the builder, note it and shorten the claim
        local project = jj_project()
        local id = new_card(project)
        local builder = { DEV_AGENT = "dotfiles/builder" }
        must(dev(project, { "board", "move", id, support.Column.PROGRESS }, builder))
        must(dev(project, { "board", "note", id, "built and tried" }, builder))
        local short = shortened_claim(project, id)
        local fence = claim_of(project.home, id).fence

        -- Move the card as the builder
        local out, code = dev(project, { "board", "move", id, support.Column.BLOCKED }, builder)
        testing.eq(code, 0, out)

        -- Keep the fence and push the expiry out
        local claim = claim_of(project.home, id)
        testing.eq(claim.fence, fence)
        testing.ok(claim.expires_at > short, claim.expires_at)
    end)

    local function lander_asked(home)
        -- Poll the turn card for the lander's ask
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

        -- Hand back the board and the answer
        restore()
        return found
    end

    testing.test("land --wait lands once the other holder gives the turn back", function()
        -- Lose the hold to another runner and start a land that waits
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

        -- See the land queue behind the holder
        testing.ok(lander_asked(project.home), "the land never joined the line")
        testing.eq(running.finished(), false)

        -- Release the turn and see the land finish
        must(dev(project, { "board", "turn", id, "--release" }, { DEV_AGENT = "dotfiles/other" }))
        local output, status = running.wait()
        testing.eq(status, 0, output)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
        testing.eq(turn_holder(project.home), nil)
    end)

    testing.test("a refused landing keeps the hold until it is released", function()
        -- Take the turn on a card without reviews
        local project = jj_project()
        local id = in_verify(project)
        tick_all(project, id)
        must(dev(project, { "board", "turn", id }))

        -- Refuse the land and keep the hold
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)
        testing.ok(out:find("No code review", 1, true), out)
        testing.ok(out:find("turn you hold for " .. id .. " stays held", 1, true), out)
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")

        -- Release the hold, then fail to release it again
        out, code = dev(project, { "board", "turn", id, "--release" })
        testing.eq(code, 0, out)
        testing.eq(turn_holder(project.home), nil)
        _, code = dev(project, { "board", "turn", id, "--release" })
        testing.eq(code, 1)
    end)

    testing.test("land leaves no owner on the landed card", function()
        for _, deploys in ipairs({ "", DEPLOYS_CONFIG }) do
            -- Verify a card and claim it as the lander
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

            -- Land it and see the claim gone
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
        -- Take the turn on a card without reviews
        local project = jj_project()
        local id = in_verify(project)
        tick_all(project, id)
        must(dev(project, { "board", "turn", id }))

        -- Refuse the land
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)

        -- Keep the hold and the card in Verify
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)
    end)

    testing.test("a landing refused before the turn is read says the hold is kept", function()
        -- Take the turn on a card in Verify
        local project = jj_project()
        local id = in_verify(project)
        must(dev(project, { "board", "turn", id }))

        -- Refuse the land before the turn is read
        local out, code = dev(project, { "board", "land", id })
        testing.eq(code, 1, out)

        -- Say the hold is kept
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
            -- Hold the turn on an approved card and let the hold lapse
            local project = jj_project()
            local id = in_verify(project)
            approve(project, id)
            must(dev(project, { "board", "turn", id, "--hold", "1" }))
            lapse_hold(project)

            -- Release the lapsed hold
            local out, code = dev(project, { "board", "turn", id, "--release" })
            testing.eq(code, 0, out)
            testing.ok(out:find("was already gone", 1, true), out)

            -- Land the card with a fresh turn
            out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
            testing.eq(code, 0, out)
            testing.eq(column_of(project.home, id), support.COLUMN_NAME.DONE)
        end
    )

    testing.test("turn refuses a card that is already in Done", function()
        -- Land an approved card
        local project = jj_project()
        local id = in_verify(project)
        approve(project, id)
        must(dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP }))

        -- Refuse a turn on the card in Done
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
        -- Let another runner hold the turn on a verified card
        local project = jj_project()
        local id = lander_ready(project)
        local held = hold_turn(project.home, "other", "cccc3333")
        local backend, restore = board_at(project.home)
        backend.root = project.root

        -- Release it and take it for the card during the first nap
        local nap = dev_os.nap
        dev_os.nap = function()
            dev_os.nap = nap
            release_turn(project.home, held)
            must(dev(project, { "board", "turn", id, "--hold", "60" }))
            must(dev(project, { "board", "move", id, support.Column.BLOCKED }))
        end

        -- Land with a wait as the lander, then restore the fakes
        local previous = dev_os.getenv("DEV_AGENT") or ""
        dev_os.setenv("DEV_AGENT", "dotfiles/lander")
        local ok, result = pcall(cmd_board.run, "land", { id, "--wait", "30" }, backend)
        dev_os.setenv("DEV_AGENT", previous)
        dev_os.nap = nap
        restore()
        assert(ok, result)

        -- Refuse the blocked card and keep the hold
        testing.eq(result.code, 1)
        testing.ok(result.message:find("cannot land", 1, true), result.message)
        testing.ok(result.message:find("stays held", 1, true), result.message)
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")

        -- Release the hold
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
        local previous = dev_os.getenv("DEV_AGENT") or ""
        dev_os.setenv("DEV_AGENT", "dotfiles/lander")
        local ok, result =
            pcall(cmd_board.run, "turn", { id, "--hold", tostring(TURN_CAP_SECONDS) }, backend)
        dev_os.setenv("DEV_AGENT", previous)
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
        -- Take the turn on a verified card
        local project = jj_project()
        local id = verified_card(project)
        must(dev(project, { "board", "turn", id }))

        -- Land it through a stub that fails
        local out, code = dev(
            project,
            { "board", "land", id },
            { LAND_CODE = "1", LAND_MSG = "boom" }
        )
        testing.eq(code, 1, out)
        testing.ok(out:find("boom", 1, true), out)
        testing.ok(out:find("turn you hold for " .. id .. " stays held", 1, true), out)

        -- Keep the hold and the card in Verify
        testing.eq(assert(turn_holder(project.home)).name, "dotfiles/lander")
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.VERIFY)
    end)

    testing.test("another check does not block a land", function()
        -- Add a second card
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

        -- Give it a check that runs until told to stop
        local scripts = support.tempdir()
        local started, stop = scripts .. "/started", scripts .. "/stop"
        local slow = scripts .. "/slow.sh"
        assert(
            fs.write(
                slow,
                table.concat({
                    "touch " .. started,
                    "n=0",
                    "while [ ! -e "
                        .. stop
                        .. " ] && [ $n -lt "
                        .. CHECK_STOP_SECONDS * 10
                        .. " ]; do",
                    "    sleep 0.1",
                    "    n=$((n + 1))",
                    "done",
                    "",
                }, "\n")
            ),
            "write failed"
        )
        must(dev(project, { "board", "checks", other, "sh " .. slow }))

        -- Start that check in another workspace and wait for it to begin
        local elsewhere = support.tempdir() .. "/other"
        jj(project.root, "workspace", "add", "--name", other, elsewhere)
        assert(fs.write(elsewhere .. "/edited", "x"), "write failed")
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

        -- Land the first card while that check still runs
        local landed, code = dev(project, { "board", "land", landing, "--wait", "0" }, {
            LAND_TRUNK = LAND_TRUNK_KEEP,
        })
        testing.eq(code, 0, landed)
        testing.eq(column_of(project.home, landing), support.COLUMN_NAME.DONE)
        testing.eq(running.finished(), false)

        -- Stop the check and see it finish
        assert(fs.write(stop, ""), "write failed")
        local output, status = running.wait()
        testing.eq(status, 0, output)
    end)

    local function rebased_and_checked(project, id)
        rebase_onto_trunk(project.root)
        must(dev(project, { "board", "check", id }))
    end

    testing.test("a clean rebase keeps its reviews", function()
        -- Verify a card and rebase it onto a trunk move
        local project = jj_project()
        local id = review_ready(project)
        local before = head(project.root)
        trunk_moves(project, { ["lib/extra.txt"] = "extra\n" })
        rebased_and_checked(project, id)
        testing.ok(head(project.root) ~= before, "the rebase must rewrite the commit")

        -- Land it through the stub
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)

        -- Carry nothing over and reach Done
        local list = comments(project.home)
        testing.eq(list[#list].kind, KIND_DONE)
        testing.eq(list[#list].body:find("carried over", 1, true), nil, list[#list].body)
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("a rebase over edits to the same file keeps its reviews", function()
        -- Verify a card and rebase it onto an edit of the shared file
        local project = jj_project()
        local id = review_ready(project)
        trunk_moves(project, { ["shared.txt"] = FIRST_EDIT })
        rebased_and_checked(project, id)

        -- Land it and reach Done
        local out, code = dev(project, { "board", "land", id }, { LAND_TRUNK = LAND_TRUNK_KEEP })
        testing.eq(code, 0, out)
        testing.eq(column_of(project.home), support.COLUMN_NAME.DONE)
    end)

    testing.test("a changed patch still needs a recheck", function()
        -- Verify a card and change its patch
        local project = jj_project()
        local id = review_ready(project)
        assert(fs.write(project.root .. "/shared.txt", LAST_OTHER), "write failed")

        -- Rebase it onto a trunk move
        trunk_moves(project, { ["lib/extra.txt"] = "extra\n" })
        rebased_and_checked(project, id)

        -- Refuse for the reviews of an earlier commit
        refused(project, id, {
            "The code review is of an earlier commit",
            "The style review is of an earlier commit",
        })
    end)

    testing.test("a needs-work review of the same patch still refuses", function()
        -- Verify a card and add a needs-work review
        local project = jj_project()
        local id = review_ready(project)
        must(record_review(project, id, { by = "rev2", verdict = "needs-work" }))

        -- Rebase it onto a trunk move
        trunk_moves(project, { ["lib/extra.txt"] = "extra\n" })
        rebased_and_checked(project, id)

        -- Refuse for that review
        refused(project, id, { "The code review by rev2", "says needs-work" })
    end)

    local function central_project(extra)
        -- Add a card and rename the default workspace away
        local project = jj_project(extra)
        local id = new_card(project)
        jj(project.root, "workspace", "rename", "default")

        -- Give the card a central workspace with a described change and a bookmark
        local base = assert(fs.realpath(support.tempdir()))
        local path = base .. "/proj/" .. id
        assert(fs.mkdir(base .. "/proj", { parents = true }), "mkdir failed")
        jj(project.root, "workspace", "add", "--name", id, "-r", "master", path)
        assert(fs.write(path .. "/work.txt", "two\n"), "write failed")
        jj(path, "describe", "-m", "feat: work")
        jj(path, "bookmark", "create", id, "-r", "@")

        -- Bring the card to Verify from inside it
        local inside = at_root(project, path)
        to_verify(inside, id, { DEV_WS_ROOT = base })
        approve(inside, id)
        return project, id, path, base, inside
    end

    testing.test("land removes the workspace and bookmark in a jj project", function()
        -- Verify a card in its central workspace
        local project, id, path, base, inside = central_project()

        -- Land it from inside
        local out, code = dev(
            inside,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.ok(out:find("Deleted bookmark " .. id, 1, true), out)
        testing.ok(out:find("Moved " .. path, 1, true), out)

        -- Remove the workspace and the bookmark
        testing.eq(fs.exists(path), false)
        testing.eq(
            jj(project.root, "bookmark", "list", "-T", 'name ++ "\\n"'):find(id, 1, true),
            nil
        )
        testing.eq(jj(project.root, "workspace", "list"):find(id .. ":", 1, true), nil)
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
    end)

    testing.test("no-change move to Done removes a real jj workspace", function()
        -- Add a card and give it a central workspace with a bookmark
        local project = jj_project()
        local id = new_card(project)
        jj(project.root, "workspace", "rename", "default")
        local base = assert(fs.realpath(support.tempdir()))
        local path = base .. "/proj/" .. id
        assert(fs.mkdir(base .. "/proj", { parents = true }), "mkdir failed")
        jj(project.root, "workspace", "add", "--name", id, "-r", "master", path)
        jj(path, "bookmark", "create", id, "-r", "@")

        -- Bring it to Review with its outcomes ticked and label it no-change
        local inside = at_root(project, path)
        to_review(inside, id, { DEV_WS_ROOT = base })
        tick_all(inside, id, { extra = { DEV_WS_ROOT = base } })
        must(dev(inside, { "board", "label", id, "+" .. board.NO_CHANGE }, { DEV_AGENT = "" }))

        -- Move it to Done from inside
        local out, code = dev(
            inside,
            { "board", "move", id, support.COLUMN_NAME.DONE },
            { DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.ok(out:find("Moved " .. path, 1, true), out)

        -- Remove the workspace and the bookmark
        testing.eq(fs.exists(path), false)
        testing.eq(
            jj(project.root, "bookmark", "list", "-T", 'name ++ "\\n"'):find(id, 1, true),
            nil
        )
        testing.eq(jj(project.root, "workspace", "list"):find(id .. ":", 1, true), nil)
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
    end)

    local function follow_script(project)
        local script = project.root .. "/.dev/commands/follow.sh"
        assert(fs.mkdir(fs.dirname(script), { parents = true }))
        local text = table.concat({ "#!/bin/sh", 'echo "followed $PWD"', "" }, "\n")
        assert(fs.write(script, text), "write failed")
        must(dev_os.run({ "chmod", "755", script }))
    end

    testing.test("land.runs.the.project.follow.script.on.a.board.with.no.release.column", function()
        -- Verify a card in its central workspace and add a follow script
        local project, id, _, base, inside = central_project()
        follow_script(project)

        -- Land it from inside
        local out, code = dev(
            inside,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)

        -- See the script run in the main checkout
        testing.ok(out:find("followed " .. project.root, 1, true), out)
    end)

    testing.test("land.leaves.a.main.checkout.with.edits.alone.and.says.why", function()
        -- Verify a card in its central workspace
        local project, id, _, base, inside = central_project()

        -- Land it from inside while the main checkout has edits
        local out, code = dev(
            inside,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)

        -- Say why the checkout was left alone and reach Done
        testing.ok(
            out:find(project.root .. " was left alone: it has uncommitted changes.", 1, true),
            out
        )
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
    end)

    testing.test("land.skips.follow.on.a.board.with.a.release.column", function()
        -- Verify a card on a board with a release column and add a follow script
        local project, id, _, base, inside = central_project(DEPLOYS_CONFIG)
        follow_script(project)

        -- Land it from inside
        local out, code = dev(
            inside,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)

        -- Run no script and move the card to Release
        testing.eq(out:find("followed", 1, true), nil, out)
        testing.eq(column_of(project.home, id), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("land moves the workspace off the landed change and removes it", function()
        -- Verify a card in its central workspace
        local project, id, path, base, inside = central_project()

        -- Land it from inside
        local out, code = dev(
            inside,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.ok(out:find("Moved " .. path, 1, true), out)
        testing.ok(out:find("Run the next command from another folder.", 1, true), out)

        -- Remove the workspace and reach Done
        testing.eq(fs.exists(path), false)
        testing.eq(jj(project.root, "workspace", "list"):find(id .. ":", 1, true), nil)
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
    end)

    testing.test(
        "clean up refreshes a stale jj workspace and removes it with its bookmark",
        function()
            -- Land the workspace's change on trunk and rewrite it elsewhere
            local project, id, path, base = central_project()
            jj(path, "bookmark", "set", "master", "-r", "@")
            jj(path, "git", "push", "--remote", "origin", "--bookmark", "master")
            jj(path, "new")
            jj(project.root, "--ignore-working-copy", "rebase", "-r", id .. "@", "-d", "root()")

            -- Confirm the workspace is stale
            local _, status = dev_os.capture(
                { "jj", "--no-pager", "-R", path, "status" },
                { stderr = "null", env = IDENT }
            )
            testing.ok(status ~= 0, "the workspace is not stale")

            -- Clean it up under the workspace root
            dev_os.setenv("DEV_WS_ROOT", base)
            local lines = cmd_board.clean_up(path, id)
            dev_os.setenv("DEV_WS_ROOT", "")

            -- Delete the bookmark and the workspace without keeping any
            testing.ok(lines:find("Deleted bookmark " .. id, 1, true), lines)
            testing.ok(not lines:find("Kept", 1, true), lines)
            testing.eq(fs.exists(path), false)
            testing.eq(
                jj(project.root, "bookmark", "list", "-T", 'name ++ "\\n"'):find(id, 1, true),
                nil
            )
        end
    )

    testing.test("clean up names the workspace path and the jj message when it keeps it", function()
        -- Put a jj on the path that refuses to forget a workspace
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

        -- Land the workspace's change on trunk
        jj(path, "bookmark", "set", "master", "-r", "@")
        jj(path, "git", "push", "--remote", "origin", "--bookmark", "master")

        -- Clean it up under the doctored path, then restore the environment
        local original = dev_os.getenv("PATH")
        dev_os.setenv("DEV_WS_ROOT", base)
        dev_os.setenv("PATH", bin .. ":" .. original)
        local lines = cmd_board.clean_up(path, id)
        dev_os.setenv("PATH", original)
        dev_os.setenv("DEV_WS_ROOT", "")

        -- Name the path and the jj message of the kept workspace
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
        -- Verify a card in its central workspace
        local project, id, path, base, inside = central_project()

        -- Land it through a stub that leaves a stray file behind
        local out, code = dev(inside, { "board", "land", id }, {
            LAND_TRUNK = LAND_TRUNK_KEEP,
            LAND_NEW = "1",
            LAND_STRAY = "stray.txt",
            DEV_WS_ROOT = base,
        })
        testing.eq(code, 0, out)

        -- Keep the workspace with its file
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
        -- Verify a card in its central workspace
        local project, id, path, base, inside = central_project()

        -- Land it from inside
        local out, code = dev(
            inside,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)
        testing.ok(out:find("Run the next command from another folder.", 1, true), out)

        -- Note the landing, reach Done and remove the workspace
        local list = comments(project.home, id)
        testing.eq(list[#list].kind, board.NoteKind.DONE)
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
        testing.eq(fs.exists(path), false)
    end)

    testing.test("land keeps a workspace outside the central root and says why", function()
        -- Verify a card and name a workspace root it does not sit in
        local project = jj_project()
        local id = verified_card(project)
        local base = assert(fs.realpath(support.tempdir()))

        -- Land it
        local out, code = dev(
            project,
            { "board", "land", id },
            { LAND_TRUNK = LAND_TRUNK_KEEP, LAND_NEW = "1", DEV_WS_ROOT = base }
        )
        testing.eq(code, 0, out)

        -- Keep the workspace and say why
        testing.ok(
            out:find("Kept the workspace. " .. project.root .. " is outside " .. base, 1, true),
            out
        )
        testing.eq(fs.exists(project.root), true)
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
    end)
end

testing.test("land removes the worktree and branch in a git project", function()
    -- Make a repo with a card worktree under the workspace root
    local base = assert(fs.realpath(support.tempdir()))
    local root = assert(fs.realpath(support.tempdir()))
    support.git(root, "init", "-q", "-b", "master")
    support.git(root, "commit", "-q", "--allow-empty", "-m", "base")
    local path = base .. "/" .. fs.basename(root) .. "/card"
    assert(fs.mkdir(base .. "/" .. fs.basename(root), { parents = true }), "mkdir failed")
    support.git(root, "worktree", "add", "-q", "-b", "card", path)
    dev_os.setenv("DEV_WS_ROOT", base)

    -- Refuse to delete a branch that a worktree still holds
    local deleted, why = vcs.delete_branch(root, vcs.GIT, "card")
    testing.eq(deleted, nil)
    testing.ok(why:find("card", 1, true), why)

    -- Remove the worktree to the trash, then delete its branch once
    local result = ws.remove(root, "card", { inside = true })
    testing.eq(result.ok, true, result.message)
    local trash = base .. "/.trash/" .. fs.basename(root) .. "/card-"
    testing.ok(result.message:find("Moved " .. path .. " to " .. trash, 1, true), result.message)
    testing.eq(fs.exists(path), false)
    testing.eq(vcs.delete_branch(root, vcs.GIT, "card"), true)
    testing.eq(vcs.delete_branch(root, vcs.GIT, "card"), false)

    -- Clean up a fresh worktree of the same card in one step
    assert(fs.remove(base .. "/.trash", { recursive = true }))
    support.git(root, "worktree", "add", "-q", "-b", "card", path)
    local lines = cmd_board.clean_up(path, "card")
    testing.ok(lines:find("Moved " .. path, 1, true), lines)
    testing.ok(lines:find("Deleted branch card", 1, true), lines)
    testing.eq(fs.exists(path), false)
    dev_os.setenv("DEV_WS_ROOT", "")
end)

testing.test("land cleanup leaves a stray file named like the card in place", function()
    -- Make a repo with a stray file where the card worktree would sit
    local base = assert(fs.realpath(support.tempdir()))
    local root = assert(fs.realpath(support.tempdir()))
    support.git(root, "init", "-q", "-b", "master")
    support.git(root, "commit", "-q", "--allow-empty", "-m", "base")
    local folder = base .. "/" .. fs.basename(root)
    assert(fs.mkdir(folder, { parents = true }), "mkdir failed")
    local stray = folder .. "/card"
    assert(fs.write(stray, "x"), "write failed")

    -- Clean up the card under the workspace root
    dev_os.setenv("DEV_WS_ROOT", base)
    local lines = cmd_board.clean_up(root, "card")
    dev_os.setenv("DEV_WS_ROOT", "")

    -- Check the cleanup kept the file and said so
    testing.ok(lines:find("Kept the workspace.", 1, true), lines)
    testing.eq(fs.exists(stray), true)
end)

local function git_dev(project, args, extra)
    -- Start from the fixed git identity
    local env = {}
    for name, value in pairs(support.GIT_IDENT) do
        env[name] = value
    end

    -- Let the caller's variables win
    for name, value in pairs(extra or {}) do
        env[name] = value
    end

    -- Run dev under that environment
    return dev(project, args, env)
end

local function git_project(extra)
    -- Make a project whose origin is a bare repo
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

    -- Push a base commit that holds a card
    project.id = new_card(project)
    support.git(root, "add", "-A")
    support.git(root, "commit", "-q", "-m", "base")
    support.git(root, "push", "-q", "origin", "master")

    -- Commit the card's work on a branch
    support.git(root, "checkout", "-q", "-b", "work")
    assert(fs.write(root .. "/work.txt", "one\n"), "write failed")
    support.git(root, "add", "-A")
    support.git(root, "commit", "-q", "-m", "feat: work")
    return project
end

local function git_approve(project)
    -- Send the card to review as its builder
    local id = project.id
    local builder = { DEV_AGENT = "dotfiles/builder" }
    must(support.to_review(function(args)
        return git_dev(project, args, builder)
    end, id))
    tick_all(project, id, { run = git_dev })

    -- Record the reviews the card needs
    for _, kind in ipairs({ "code", "style" }) do
        must(record_review(project, id, { kind = kind, rev = "HEAD", run = git_dev }))
    end

    -- Run the checks and let the card advance to verify
    must(git_dev(project, { "board", "check", id }))
    tick_all(project, id, { run = git_dev })
end

local function git_trunk_moves(project, name, text)
    -- Clone the remote
    local clone = assert(fs.realpath(support.tempdir())) .. "/clone"
    must(dev_os.run({ "git", "clone", "-q", project.bare, clone }, { stdout = "null" }))

    -- Commit a file to the clone
    assert(fs.write(clone .. "/" .. name, text), "write failed")
    support.git(clone, "add", "-A")
    support.git(clone, "commit", "-q", "-m", "trunk moves")

    -- Push it to trunk
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
        -- Approve a card whose commit already reached trunk
        local project = git_project()
        local id = project.id
        git_approve(project)
        local landed = git_rev(project.root, "HEAD")
        support.git(project.root, "push", "-q", "origin", "HEAD:master")

        -- Land it again
        local out, code = git_dev(project, { "board", "land", id })
        testing.eq(code, 0, out)
        testing.ok(out:find("settled " .. id, 1, true), out)
        testing.eq(git_remote_master(project), landed)

        -- Check the card is done with a note naming the commit
        local list = comments(project.home, id)
        local note = list[#list]
        testing.eq(note.kind, board.NoteKind.DONE)
        testing.ok(note.body:find("Landed commit " .. landed:sub(1, 12), 1, true), note.body)
        testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
    end
)

testing.test("land.git.lands rebases a card onto fetched trunk and pushes it", function()
    -- Approve a card, then move trunk past its base
    local project = git_project()
    local id = project.id
    git_approve(project)
    git_trunk_moves(project, "other.txt", "other\n")
    local trunk = git_remote_master(project)

    -- Land it and check it sits on the new trunk
    local out, code = git_dev(project, { "board", "land", id })
    testing.eq(code, 0, out)
    testing.ok(out:find("landed " .. id, 1, true), out)
    local landed = git_rev(project.root, "HEAD")
    testing.eq(git_remote_master(project), landed)
    testing.eq(git_rev(project.root, "HEAD~1"), trunk)

    -- Check the card is done with a note naming the commit
    local list = comments(project.home, id)
    local note = list[#list]
    testing.eq(note.kind, board.NoteKind.DONE)
    testing.ok(note.body:find("Landed commit " .. landed:sub(1, 12), 1, true), note.body)
    testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
end)

testing.test("land.git.recheck reruns trunk's rows when the change empties its own", function()
    -- Narrow the change's own config so it empties the recheck rows
    local marker = support.tempdir() .. "/rechecked"
    local project = git_project(table.concat({
        "",
        "[board.land]",
        'recheck = ["touch ' .. marker .. '"]',
        "",
    }, "\n"))
    local id = project.id
    assert(fs.write(project.root .. "/.dev/config.toml", NARROWED), "write failed")
    support.git(project.root, "add", "-A")
    support.git(project.root, "commit", "-q", "--amend", "--no-edit")
    git_approve(project)

    -- Move trunk to a config that holds the recheck row
    git_trunk_moves(
        project,
        ".dev/config.toml",
        table.concat({
            "[board]",
            'backend = "local"',
            'name = "mine"',
            "# t",
            "[board.land]",
            'recheck = ["touch ' .. marker .. '"]',
            "",
        }, "\n")
    )

    -- Land and check trunk's row ran
    local out, code = git_dev(project, { "board", "land", id })
    testing.eq(code, 0, out)
    testing.ok(fs.is_file(marker), "trunk's recheck row never ran")
end)

testing.test("land.git.recheck skips the rows when the patch is unchanged", function()
    -- Approve a card in a project with a recheck row, then move trunk
    local marker = support.tempdir() .. "/rechecked"
    local project = git_project(table.concat({
        "",
        "[board.land]",
        'recheck = ["touch ' .. marker .. '"]',
        "",
    }, "\n"))
    local id = project.id
    git_approve(project)
    git_trunk_moves(project, "other.txt", "other\n")

    -- Land it and check the row never ran
    local out, code = git_dev(project, { "board", "land", id })
    testing.eq(code, 0, out)
    testing.ok(not fs.is_file(marker), "the recheck row ran")
    testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
end)

testing.test("land.git.refused names a failed fetch or rebase and keeps the card", function()
    -- Approve a card, then move trunk to clash with its file
    local project = git_project()
    local id = project.id
    git_approve(project)
    local before = git_rev(project.root, "HEAD")
    git_trunk_moves(project, "work.txt", "other\n")
    local trunk = git_remote_master(project)

    -- Check a failed rebase refuses and leaves card and trunk alone
    local out, code = git_dev(project, { "board", "land", id })
    testing.eq(code, 1, out)
    testing.ok(out:find("The rebase onto trunk failed", 1, true), out)
    testing.eq(git_rev(project.root, "HEAD"), before)
    testing.eq(git_remote_master(project), trunk)
    testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)

    -- Check a failed fetch refuses and leaves card and trunk alone
    support.git(project.root, "remote", "set-url", "origin", project.bare .. "/missing")
    out, code = git_dev(project, { "board", "land", id })
    testing.eq(code, 1, out)
    testing.ok(out:find("The fetch from origin failed", 1, true), out)
    testing.eq(git_remote_master(project), trunk)
    testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.verify)
end)

local function linked_worktree(prepare)
    -- Free the work branch in the main checkout
    local project = git_project()
    local id = project.id
    local main = project.root
    support.git(main, "checkout", "-q", "master")

    -- Put the card in a linked worktree, and let the caller adjust it
    local base = assert(fs.realpath(support.tempdir()))
    local folder = base .. "/" .. fs.basename(main)
    local path = folder .. "/" .. id
    assert(fs.mkdir(folder, { parents = true }), "mkdir failed")
    support.git(main, "worktree", "add", "-q", "-b", id, path, "work")
    if prepare then
        prepare(main, folder, path)
    end

    -- Approve the card from inside the worktree
    local tree = at_root(project, path)
    tree.id = id
    git_approve(tree)
    return project, tree, base, path
end

testing.test("land.git.worktree lands a linked worktree and removes it", function()
    -- Approve a card that lives in a linked worktree
    local project, tree, base, path = linked_worktree()
    local id = project.id
    local landed = git_rev(path, "HEAD")

    -- Land it from inside the worktree
    local out, code = git_dev(tree, { "board", "land", id }, { DEV_WS_ROOT = base })
    testing.eq(code, 0, out)

    -- Check the worktree and branch are gone and trunk holds the commit
    testing.ok(out:find("Moved " .. path, 1, true), out)
    testing.ok(out:find("Deleted branch " .. id, 1, true), out)
    testing.eq(fs.exists(path), false)
    testing.eq(git_remote_master(project), landed)
    testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
end)

testing.test("no-change move to Done removes a real git worktree", function()
    -- Put a card with no change in a linked worktree
    local project = git_project()
    local id = project.id
    local main = project.root
    support.git(main, "checkout", "-q", "master")
    local base = assert(fs.realpath(support.tempdir()))
    local folder = base .. "/" .. fs.basename(main)
    local path = folder .. "/" .. id
    assert(fs.mkdir(folder, { parents = true }), "mkdir failed")
    support.git(main, "worktree", "add", "-q", "-b", id, path, "master")
    local tree = at_root(project, path)

    -- Send the card to review and label it as needing no change
    must(support.to_review(function(args)
        return git_dev(tree, args, { DEV_AGENT = "dotfiles/builder", DEV_WS_ROOT = base })
    end, id))
    tick_all(tree, id, { run = git_dev, extra = { DEV_WS_ROOT = base } })
    must(git_dev(tree, { "board", "label", id, "+" .. board.NO_CHANGE }, { DEV_AGENT = "" }))

    -- Move it to Done
    local out, code = git_dev(
        tree,
        { "board", "move", id, support.COLUMN_NAME.DONE },
        { DEV_WS_ROOT = base }
    )

    -- Check the worktree and branch are gone
    testing.eq(code, 0, out)
    testing.ok(out:find("Moved " .. path, 1, true), out)
    testing.eq(fs.exists(path), false)
    local branches = dev_os.capture({ "git", "-C", main, "branch", "--list", id })
    testing.eq(branches:find(id, 1, true), nil, branches)
    testing.eq(column_of(project.home, id), board.DEFAULT_NAMES.done)
end)

local function land_kept_worktree(prepare)
    -- Approve a card in a prepared linked worktree
    local project, tree, base, path = linked_worktree(prepare)
    local id = project.id
    local landed = git_rev(path, "HEAD")

    -- Land it from inside the worktree
    local out, code = git_dev(tree, { "board", "land", id }, { DEV_WS_ROOT = base })

    -- Check the card landed and the worktree stayed
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
    -- Land a card beside a sibling worktree whose folder is gone
    local sibling
    local out = land_kept_worktree(function(main, folder)
        sibling = folder .. "/sibling"
        support.git(main, "worktree", "add", "-q", "-b", "sibling", sibling, "work")
        assert(fs.remove(sibling, { recursive = true }))
    end)

    -- Check the output says why the workspace was kept
    local reason = "Git worktree prune would also drop the record of "
        .. sibling
        .. ", which git marks prunable. Run git worktree prune first."
    testing.ok(out:find("Kept the workspace. " .. reason, 1, true), out)
end)

testing.test("land.template.drift names drift the commit does not touch", function()
    -- Report drift in two template files and one the commit touches
    local output = table.concat({
        "lint failed",
        "differs: .dev/lint.lua",
        "  missing: .dev/lintset.lua",
        "differs: mine.lua",
        "",
    }, "\n")

    -- Ask for advice on the drift
    local advice = land.template_drift(output, { "mine.lua" })

    -- Check the advice names the two untouched files and the sync command
    testing.ok(advice:find(".dev/lint.lua, .dev/lintset.lua", 1, true), advice)
    testing.ok(advice:find("run `dev sync`", 1, true), advice)
    testing.eq(advice:find("mine.lua", 1, true), nil, advice)
end)

testing.test("land.template.drift says nothing when the commit caused the drift", function()
    testing.eq(land.template_drift("differs: a.lua\n", { "a.lua" }), nil)
    testing.eq(land.template_drift("push rejected\n", {}), nil)
end)

testing.test("land.template.drift matches the path before a sync line's suffix", function()
    -- Check a touched path with a suffix raises no advice
    local readme = 'differs: .dev/README.md above "marker"\n'
    testing.eq(land.template_drift(readme, { ".dev/README.md" }), nil)

    -- Add a second drifting line the commit does not touch
    local advice = land.template_drift(readme .. "differs: [workspace.lints] block in x\n", {})

    -- Check the advice names both paths without the suffix
    testing.ok(advice:find(".dev/README.md, [workspace.lints]", 1, true), advice)
    testing.eq(advice:find("above", 1, true), nil, advice)
end)
