local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local has_jj = dev_os.which("jj") ~= nil
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
        DEV_AGENT = "",
    }
    return support.dev(root, args, { env = env, cwd = cwd })
end

local function must(first, second)
    local code = type(first) == "number" and first or second
    assert(code == 0, tostring(first))
end

local function card_in(root, home)
    must(dev(root, home, { "board", "init" }))
    support.drop_turn_card(home .. "/state/dev/boards/mine.json")
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
        "--checks",
        "dev test",
    })
    return assert(out:match("added (%x+)"), out)
end

local function git_root()
    local root, home = setup()
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

testing.test("review records the kind, the name and the commit in git", function()
    local root, home, head = git_root()
    local id = card_in(root, home)
    local out, code = dev(root, home, {
        "board",
        "review",
        id,
        "--kind",
        "code",
        "--by",
        "rev1",
        "--rev",
        "HEAD",
        "--verdict",
        "clean",
    })
    testing.eq(code, 0, out)
    testing.ok(
        out:find(
            "recorded code review by rev1 on " .. id .. " at commit " .. head:sub(1, 12),
            1,
            true
        ),
        out
    )
    testing.eq(
        comments(home)[1].body,
        "dev-review: kind=code by=rev1 commit=" .. head .. " change=- verdict=clean"
    )
    testing.eq(comments(home)[1].kind, "status")
end)

testing.test("review verdict is required, must be known and is written on the record", function()
    local root, home, head = git_root()
    local id = card_in(root, home)
    local out, code =
        dev(root, home, { "board", "review", id, "--kind", "code", "--by", "r", "--rev", "HEAD" })
    testing.eq(code, 2, out)
    out, code = dev(root, home, {
        "board",
        "review",
        id,
        "--kind",
        "code",
        "--by",
        "r",
        "--rev",
        "HEAD",
        "--verdict",
        "bad",
    })
    testing.eq(code, 2, out)
    testing.ok(out:find("The verdicts are clean, minor, needs-work", 1, true), out)
    testing.eq(#comments(home), 0)
    for i, verdict in ipairs({ "clean", "minor", "needs-work" }) do
        out, code = dev(root, home, {
            "board",
            "review",
            id,
            "--kind",
            "code",
            "--by",
            "r",
            "--rev",
            "HEAD",
            "--verdict",
            verdict,
        })
        testing.eq(code, 0, out)
        testing.eq(
            comments(home)[i].body,
            "dev-review: kind=code by=r commit=" .. head .. " change=- verdict=" .. verdict
        )
    end
end)

testing.test("review refuses the claimant as the reviewer", function()
    local root, home = git_root()
    local id = card_in(root, home)
    must(dev(root, home, { "board", "take", id, "--as", "dotfiles/builder" }))
    local out, code = dev(root, home, {
        "board",
        "review",
        id,
        "--kind",
        "style",
        "--by",
        "dotfiles/builder",
        "--rev",
        "HEAD",
        "--verdict",
        "clean",
    })
    testing.eq(code, 1, out)
    testing.ok(out:find("cannot review its own change", 1, true), out)
    testing.eq(#comments(home), 1)
    out, code = dev(root, home, {
        "board",
        "review",
        id,
        "--kind",
        "style",
        "--by",
        "dotfiles/other",
        "--rev",
        "HEAD",
        "--verdict",
        "clean",
    })
    testing.eq(code, 0, out)
    testing.eq(#comments(home), 2)
end)

testing.test(
    "review refuses a claimant whose claim lapsed, and a take writes one claim note",
    function()
        local root, home = git_root()
        local id = card_in(root, home)
        must(dev(root, home, { "board", "take", id, "--as", "dotfiles/builder" }))
        must(dev(root, home, { "board", "take", id, "--as", "dotfiles/builder" }))
        testing.eq(#comments(home), 1)
        testing.eq(comments(home)[1].body, "dev-claim: by=dotfiles/builder")
        local file = home .. "/state/dev/boards/mine.json"
        local doc = assert(json.decode(assert(fs.read(file))))
        doc.cards[1].claim.expires_at = "2000-01-01T00:00:00Z"
        assert(fs.write(file, assert(json.encode(doc))))
        for _, kind in ipairs({ "code", "style", "recheck" }) do
            local out, code = dev(root, home, {
                "board",
                "review",
                id,
                "--kind",
                kind,
                "--by",
                "dotfiles/builder",
                "--rev",
                "HEAD",
                "--verdict",
                "clean",
            })
            testing.eq(code, 1, out)
            testing.ok(
                out:find(
                    "was claimed by dotfiles/builder. dotfiles/builder cannot review its own change",
                    1,
                    true
                ),
                out
            )
        end
        testing.eq(#comments(home), 1)
        local out, code = dev(root, home, {
            "board",
            "review",
            id,
            "--kind",
            "code",
            "--by",
            "dotfiles/other",
            "--rev",
            "HEAD",
            "--verdict",
            "clean",
        })
        testing.eq(code, 0, out)
        out, code = dev(root, home, { "board", "note", id, "dev-claim: by=other" })
        testing.eq(code, 1, out)
        testing.ok(out:find("dev-claim:", 1, true), out)
    end
)

testing.test("review refuses a default-named claimant when DEV_AGENT is unset", function()
    local root, home = git_root()
    local id = card_in(root, home)
    local function run(session, args)
        return support.dev(root, args, {
            env = {
                HOME = home,
                XDG_STATE_HOME = home .. "/state",
                JJ_USER = "t",
                JJ_EMAIL = "t@example.com",
                DEV_AGENT = "",
                CLAUDE_SESSION_ID = session,
            },
        })
    end
    must(run("dotfiles/builder", { "board", "take", id }))
    for _, kind in ipairs({ "code", "style", "recheck" }) do
        local out, code = run("dotfiles/builder", {
            "board",
            "review",
            id,
            "--kind",
            kind,
            "--by",
            "dotfiles/other",
            "--rev",
            "HEAD",
            "--verdict",
            "clean",
        })
        testing.eq(code, 1, out)
        testing.ok(out:find("cannot review its own change", 1, true), out)
    end
    testing.eq(#comments(home), 1)
    local out, code = run("reviewer", {
        "board",
        "review",
        id,
        "--kind",
        "code",
        "--by",
        "dotfiles/other",
        "--rev",
        "HEAD",
        "--verdict",
        "clean",
    })
    testing.eq(code, 0, out)
    testing.eq(#comments(home), 2)
end)

testing.test(
    "review refuses an unknown kind, a missing flag and a rev that is not a commit",
    function()
        local root, home = git_root()
        local id = card_in(root, home)
        local out, code = dev(root, home, {
            "board",
            "review",
            id,
            "--kind",
            "lint",
            "--by",
            "r",
            "--rev",
            "HEAD",
            "--verdict",
            "clean",
        })
        testing.eq(code, 2, out)
        testing.ok(out:find("The kinds are code, style, recheck", 1, true), out)
        out, code = dev(root, home, { "board", "review", id, "--kind", "code", "--by", "r" })
        testing.eq(code, 2, out)
        out, code = dev(root, home, {
            "board",
            "review",
            id,
            "--kind",
            "code",
            "--by",
            "a b",
            "--rev",
            "HEAD",
            "--verdict",
            "clean",
        })
        testing.eq(code, 2, out)
        for _, rev in ipairs({ "nosuchrev", "--all", "", "HEAD^{tree}" }) do
            out, code = dev(root, home, {
                "board",
                "review",
                id,
                "--kind",
                "code",
                "--by",
                "r",
                "--rev",
                rev,
                "--verdict",
                "clean",
            })
            testing.eq(code, 1, out)
        end
        testing.eq(#comments(home), 0)
    end
)

testing.test("note cannot write, edit or delete the review prefix", function()
    local root, home = git_root()
    local id = card_in(root, home)
    local out, code = dev(root, home, { "board", "note", id, "  DEV-REVIEW: kind=code" })
    testing.eq(code, 1, out)
    testing.ok(out:find("`dev board review` writes", 1, true), out)
    must(dev(root, home, {
        "board",
        "review",
        id,
        "--kind",
        "code",
        "--by",
        "r",
        "--rev",
        "HEAD",
        "--verdict",
        "clean",
    }))
    local listing = dev(root, home, { "board", "notes", id })
    local first = assert(listing:match("^(%x+)"), listing)
    out, code = dev(root, home, { "board", "note", id, "--edit", first, "fine" })
    testing.eq(code, 1, out)
    out, code = dev(root, home, { "board", "note", id, "--delete", first })
    testing.eq(code, 1, out)
    must(dev(root, home, { "board", "note", id, "plain" }))
    listing = dev(root, home, { "board", "notes", id })
    local second = assert(listing:match("\n(%x+)"), listing)
    out, code = dev(root, home, { "board", "note", id, "--edit", second, "dev-review: forged" })
    testing.eq(code, 1, out)
    testing.eq(#comments(home), 2)
end)

testing.test("a review that cannot be written is never reported as recorded", function()
    local root = git_root()
    local card = {
        id = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        name = "Card",
        column = "In Progress",
        size = "unsized",
        labels = {},
        checks = {},
        outcomes = {},
    }
    local backend = { root = root }
    function backend:done_columns()
        return { "Done" }
    end
    function backend:cards()
        return { card }
    end
    function backend:comments()
        return {}
    end
    function backend:note()
        return nil, "curl exit 28"
    end
    local result = require("dev.cmd.board").run(
        "review",
        { "11111111", "--kind", "code", "--by", "r", "--rev", "HEAD", "--verdict", "clean" },
        backend
    )
    testing.eq(result.output, nil)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("was NOT recorded", 1, true), result.message)
    testing.ok(result.message:find("Curl exit 28", 1, true), result.message)
end)

local function seat_backend(root, refusal)
    local card = {
        id = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        name = "Card",
        column = support.COLUMN_NAME.PROGRESS,
        size = "unsized",
        labels = {},
        checks = {},
        outcomes = {},
    }
    local backend = { root = root, seats = {}, notes = {} }
    function backend:done_columns()
        return { support.COLUMN_NAME.DONE }
    end
    function backend:cards()
        return { card }
    end
    function backend:comments()
        return {}
    end
    function backend:seat_verdict(id, seat, name, verdict, revision)
        self.seats[#self.seats + 1] =
            { id = id, seat = seat, name = name, verdict = verdict, revision = revision }
        if refusal then
            return nil, refusal
        end
        return true
    end
    function backend:note(_, body)
        self.notes[#self.notes + 1] = body
        return true
    end
    return backend
end

local function review_as(backend, kind, verdict)
    return require("dev.cmd.board").run(
        "review",
        { "11111111", "--kind", kind, "--by", "r", "--rev", "HEAD", "--verdict", verdict },
        backend
    )
end

testing.test("board_review_clean_sets_seat_approved_with_revision", function()
    local root, _, head = git_root()
    for _, verdict in ipairs({ "clean", "minor" }) do
        local backend = seat_backend(root)
        local result = review_as(backend, "style", verdict)
        testing.eq(result.code, nil, result.message)
        testing.eq(#backend.seats, 1)
        testing.eq(backend.seats[1].seat, "style")
        testing.eq(backend.seats[1].name, "r")
        testing.eq(backend.seats[1].verdict, "approved")
        testing.eq(backend.seats[1].revision, head)
    end
end)

testing.test("board_review_needs_work_sets_changes_needed", function()
    local root = git_root()
    local backend = seat_backend(root)
    local result = review_as(backend, "code", "needs-work")
    testing.eq(result.code, nil, result.message)
    testing.eq(backend.seats[1].seat, "code")
    testing.eq(backend.seats[1].verdict, "changes_needed")
end)

testing.test("board_review_reports_a_refused_seat", function()
    local root = git_root()
    local backend = seat_backend(
        root,
        "pomb answered 409: the task's owner cannot take a seat on it (owner_seat)"
    )
    local result = review_as(backend, "code", "clean")
    testing.eq(result.code, nil)
    testing.ok(result.output:find("recorded code review by r", 1, true), result.output)
    testing.eq(#result.warnings, 1)
    testing.ok(result.warnings[1]:find("owner_seat", 1, true), result.warnings[1])
    testing.ok(result.warnings[1]:find("seat of card", 1, true), result.warnings[1])
    testing.eq(#backend.notes, 1)
end)

testing.test("board_review_still_writes_dev_review_comment", function()
    local root, _, head = git_root()
    local backend = seat_backend(root)
    local result = review_as(backend, "code", "clean")
    testing.eq(result.code, nil, result.message)
    testing.eq(backend.notes, {
        "dev-review: kind=code by=r commit=" .. head .. " change=- verdict=clean",
    })
end)

local function pomb_seats(answers)
    local backend = assert(require("dev.board.pomb").new({
        url = "https://pomb.example",
        token = "pass:x",
        name = "mine",
    }))
    backend.calls = {}
    function backend:__load()
        return true
    end
    function backend:__request(method, path, body)
        self.calls[#self.calls + 1] = { method, path, body }
        local answer = table.remove(answers, 1) or { true }
        return answer[1], answer[2], answer[3], answer[4]
    end
    return backend
end

local NO_SEAT = { nil, "pomb answered 404", 404, { message = "the task has no such seat" } }

testing.test("seat_verdict takes the seat then posts the verdict and revision", function()
    local backend = pomb_seats({})
    testing.eq(backend:seat_verdict("t1", "code", "r", "approved", "abc"), true)
    testing.eq(backend.calls, {
        { "POST", "/api/tasks/t1/seats/take", { seat = "code", name = "r" } },
        {
            "POST",
            "/api/tasks/t1/seats/verdict",
            { seat = "code", name = "r", verdict = "approved", revision = "abc" },
        },
    })
end)

testing.test("seat_verdict adds a missing seat and takes it again", function()
    local backend = pomb_seats({ NO_SEAT })
    testing.eq(backend:seat_verdict("t1", "style", "r", "changes_needed", "abc"), true)
    testing.eq(#backend.calls, 4)
    testing.eq(backend.calls[2], {
        "POST",
        "/api/tasks/t1/seats",
        { name = "style", role = "reviewer" },
    })
    testing.eq(backend.calls[3][2], "/api/tasks/t1/seats/take")
    testing.eq(backend.calls[4][3].verdict, "changes_needed")
end)

testing.test("seat_verdict adds no seat for another 404 and stops at each refusal", function()
    local other = { nil, "pomb answered 404", 404, { message = "task not found" } }
    local backend = pomb_seats({ other })
    local ok, message = backend:seat_verdict("t1", "code", "r", "approved", "abc")
    testing.eq(ok, nil)
    testing.eq(message, "pomb answered 404")
    testing.eq(#backend.calls, 1)

    backend = pomb_seats({ { nil, "pomb answered 409", 409, { code = "owner_seat" } } })
    ok, message = backend:seat_verdict("t1", "code", "r", "approved", "abc")
    testing.eq({ ok, message, #backend.calls }, { nil, "pomb answered 409 (owner_seat)", 1 })

    backend = pomb_seats({ NO_SEAT, { nil, "add refused" } })
    ok, message = backend:seat_verdict("t1", "code", "r", "approved", "abc")
    testing.eq({ ok, message, #backend.calls }, { nil, "add refused", 2 })

    backend = pomb_seats({ { true }, { nil, "verdict refused" } })
    ok, message = backend:seat_verdict("t1", "code", "r", "approved", "abc")
    testing.eq({ ok, message, #backend.calls }, { nil, "verdict refused", 2 })
end)

if has_jj then
    local function jj(root, ...)
        local argv = { "jj", "--no-pager", "--color", "never", "-R", root, ... }
        local out, code = dev_os.capture(argv, { stderr = "null", env = IDENT })
        assert(code == 0, out)
        return out
    end

    testing.test(
        "in jj review stores the change id and one commit, and refuses a revset of many",
        function()
            local root, home = setup()
            must(
                dev_os.run(
                    { "jj", "git", "init", root },
                    { stdout = "null", stderr = "null", env = IDENT }
                )
            )
            jj(root, "commit", "-m", "base")
            local id = card_in(root, home)
            local want =
                jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id ++ ' ' ++ change_id")
            local commit, change = want:match("^(%x+) (%a+)")
            local out, code = dev(root, home, {
                "board",
                "review",
                id,
                "--kind",
                "recheck",
                "--by",
                "r",
                "--rev",
                "@-",
                "--verdict",
                "clean",
            })
            testing.eq(code, 0, out)
            testing.eq(
                comments(home)[1].body,
                "dev-review: kind=recheck by=r commit="
                    .. commit
                    .. " change="
                    .. change
                    .. " verdict=clean"
            )
            out, code = dev(root, home, {
                "board",
                "review",
                id,
                "--kind",
                "code",
                "--by",
                "r",
                "--rev",
                "all()",
                "--verdict",
                "clean",
            })
            testing.eq(code, 1, out)
            testing.eq(#comments(home), 1)
        end
    )

    testing.test("in jj review refuses another change than the recorded one", function()
        -- Make two changes and record a first review of the older one
        local root, home = setup()
        must(
            dev_os.run(
                { "jj", "git", "init", root },
                { stdout = "null", stderr = "null", env = IDENT }
            )
        )
        jj(root, "commit", "-m", "base")
        local id = card_in(root, home)
        local function change_of(rev)
            local out = jj(root, "log", "-r", rev, "--no-graph", "-T", "change_id")
            return out:match("^(%a+)")
        end
        local function review(rev)
            return dev(root, home, {
                "board",
                "review",
                id,
                "--kind",
                "code",
                "--by",
                "r",
                "--rev",
                rev,
                "--verdict",
                "clean",
            })
        end
        local out, code = review("@-")
        testing.eq(code, 0, out)

        -- Review the other change and expect a refusal that names both
        out, code = review("@")
        testing.eq(code, 1, out)
        testing.ok(out:find(change_of("@-"), 1, true), out)
        testing.ok(out:find(change_of("@"), 1, true), out)
        testing.ok(out:find("from the change's workspace", 1, true), out)
        testing.eq(#comments(home), 1)

        -- Review the recorded change again and expect it to record
        out, code = review("@-")
        testing.eq(code, 0, out)
        testing.eq(#comments(home), 2)

        -- Add a newer check record for the other change and expect it to rule
        local file = home .. "/state/dev/boards/mine.json"
        local doc = assert(json.decode(assert(fs.read(file))))
        local record = {}
        for key, value in pairs(doc.cards[1].comments[1]) do
            record[key] = value
        end
        record.body = string.format(
            "dev-check: commit=%s change=%s mode=run rows=1 sum=ab5ba36a\n1 pass 28c702",
            string.rep("a", 40),
            change_of("@")
        )
        table.insert(doc.cards[1].comments, record)
        assert(fs.write(file, assert(json.encode(doc))))
        out, code = review("@-")
        testing.eq(code, 1, out)
        testing.ok(out:find("is change " .. change_of("@-"), 1, true), out)
        out, code = review("@")
        testing.eq(code, 0, out)
    end)
end
