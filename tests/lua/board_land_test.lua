local t = require("testing")
local check = require("dev.board.check")
local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local land = require("dev.board.land")
local review = require("dev.board.review")
local support = require("support")

local has_jj = devos.which("jj") ~= nil
local IDENT = { JJ_USER = "t", JJ_EMAIL = "t@example.com" }
local LAND_STUB = [[#!/bin/sh
for word in "$@"; do
    if [ "$word" = land ]; then
        echo "$*" >>"$LAND_LOG"
        echo "$LAND_MSG"
        exit "${LAND_CODE:-0}"
    fi
done
exec "$REAL_JJ" "$@"
]]
local COMMIT = ("a"):rep(40)
local OTHER = ("b"):rep(40)

local function setup()
    local root = support.sandbox(
        { [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "mine"\n' },
        {}
    )
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
        { run = "dev lint", result = "pass", code = 0, tail = "" },
        { run = "dev test", result = "fail", code = 1, tail = "" },
    }
    local record = check.parse(check.record(STATE, rows, true))
    t.eq(record.commit, COMMIT)
    t.eq(record.change, "chg")
    t.eq(record.mode, "expect-fail")
    t.eq(
        record.rows,
        { { run = "dev lint", result = "pass" }, { run = "dev test", result = "fail" } }
    )
    t.eq(check.parse("a note"), nil)
    t.eq(check.parse("dev-check: commit=zz change=c mode=run"), nil)
    t.eq(check.parse("dev-check: commit=aa change=c mode=run\n2 pass x"), nil)
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
    local pass = checked(COMMIT, "run", { "pass dev lint", "pass dev test" })
    t.eq(land.checks_problem({ pass }, STATE, rows), nil)
    t.ok(land.checks_problem({ pass }, STATE, {}):find("no checks rows", 1, true))
    t.ok(land.checks_problem({}, STATE, rows):find("no run of dev board check", 1, true))
    t.ok(
        land.checks_problem({ checked(OTHER, "run", { "pass a", "pass b" }) }, STATE, rows)
            :find("no run of dev board check", 1, true)
    )
    local expect = checked(COMMIT, "expect-fail", { "fail dev lint", "fail dev test" })
    t.ok(land.checks_problem({ expect }, STATE, rows):find("expect-fail", 1, true))
    local failed = checked(COMMIT, "run", { "pass dev lint", "fail dev test" })
    t.ok(land.checks_problem({ pass, failed }, STATE, rows):find("2 fail dev test", 1, true))
    t.eq(land.checks_problem({ failed, pass }, STATE, rows), nil)
    t.ok(land.checks_problem({ pass }, STATE, { "dev lint" }):find("has 2 rows", 1, true))
    t.ok(land.checks_problem({ pass }, STATE, { "dev lint", "dev x" }):find("dev x", 1, true))
    t.ok(
        land.checks_problem(
            { checked(COMMIT, "run", { "timeout dev lint" }) },
            STATE,
            { "dev lint" }
        )
    )
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

local function comments(home)
    local doc = assert(
        json.decode(assert(fs.read(home .. "/state/dev/boards/mine.json"), "read failed")),
        "decode failed"
    )
    return doc.cards[1].comments or {}
end

local function landed_calls(log)
    return fs.read(log) or ""
end

local function column_of(home)
    local doc = assert(
        json.decode(assert(fs.read(home .. "/state/dev/boards/mine.json"), "read failed")),
        "decode failed"
    )
    local card = doc.cards[1]
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

    local function jj_project()
        local root, home, log = setup()
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

    t.test("a card that meets every condition lands, gets a done note and reaches Done", function()
        local root, home, log = jj_project()
        local id = new_card(root, home, log)
        must(dev(root, home, log, { "board", "move", id, "review" }))
        approve(root, home, log, id)
        local commit = head(root)
        local out, code = dev(root, home, log, { "board", "land", id })
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

    t.test("land refuses when trunk has moved since the change was built", function()
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
        refused(root, home, log, id, { "trunk has moved" })
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
end
