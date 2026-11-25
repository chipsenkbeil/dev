local testing = require("@dev/testing")
local board = require("@dev/board")
local tokenfile = require("@dev/board/tokenfile")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local json = require("@dev/json")
local pomb = require("@dev/board/pomb")
local support = require("./support")

local has_jj = dev_os.which("jj") ~= nil
local IDENT = { JJ_USER = "t", JJ_EMAIL = "t@example.com" }

local function setup()
    -- Make a repo that names a local board
    local root = support.sandbox({
        [".dev/config.toml"] = table.concat({
            "[board]",
            'backend = "local"',
            'name = "mine"',
            "",
        }, "\n"),
    }, {})

    -- Give it a home with an empty user config
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
    -- Create the board and drop the turn card it starts with
    must(dev(root, home, { "board", "init" }))
    support.drop_turn_card(support.board_file(home, "mine"))

    -- Spell out a ready card with every outcome to finish
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
        "--checks",
        support.READY_CHECKS[1],
    }
    for _, outcome in ipairs(support.READY_OUTCOMES) do
        args[#args + 1] = "--done-when"
        args[#args + 1] = outcome.name
    end

    -- Add it and return its id
    local out = dev(root, home, args)
    return assert(out:match("added (%x+)"), out)
end

local function git_root()
    -- Run git in the repo under a fixed identity
    local root, home = setup()
    local function git(...)
        local argv =
            { "git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@example.com", ... }
        must(dev_os.run(argv, { stdout = "null" }))
    end

    -- Commit the sandbox as the base
    must(dev_os.run({ "git", "init", "-q", root }, { stdout = "null" }))
    git("add", "-A")
    git("commit", "-q", "-m", "base")

    -- Name the commit the reviews will point at
    local head = dev_os.capture({ "git", "-C", root, "rev-parse", "HEAD" }):gsub("\n$", "")
    return root, home, head
end

local function comments(home)
    local doc = assert(json.decode(assert(fs.read(support.board_file(home, "mine")))))
    return doc.cards[1].comments or {}
end

testing.test("review records the kind, the name and the commit in git", function()
    -- Make a card in a git repo
    local root, home, head = git_root()
    local id = card_in(root, home)

    -- Review it by name at the head commit
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

    -- Say what was recorded and write the record on the card
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

testing.test("review in git ignores an expect-fail check record from a jj change", function()
    -- Make a card in a git repo and review it once
    local root, home = git_root()
    local id = card_in(root, home)
    local function review()
        return dev(root, home, {
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
    end
    local out, code = review()
    testing.eq(code, 0, out)

    -- Append an expect-fail check record that carries a jj change id
    local file = support.board_file(home, "mine")
    local doc = assert(json.decode(assert(fs.read(file))))
    local record = {}
    for key, value in pairs(doc.cards[1].comments[1]) do
        record[key] = value
    end
    record.body = string.format(
        table.concat({
            "dev-check: commit=%s change=abcdefgh mode=expect-fail rows=1 sum=ab5ba36a",
            "1 fail 28c702",
        }, "\n"),
        string.rep("a", 40)
    )
    table.insert(doc.cards[1].comments, record)
    assert(fs.write(file, assert(json.encode(doc))))

    -- Review again and expect git to ignore that record
    out, code = review()
    testing.eq(code, 0, out)
    testing.eq(#comments(home), 3)
end)

testing.test("review in git accepts a run check record from a jj change", function()
    -- Make a repo with a card and a way to review it
    local root, home = git_root()
    local id = card_in(root, home)
    local function review()
        return dev(root, home, {
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
    end

    -- Record a first review so the card holds a comment to copy
    local out, code = review()
    testing.eq(code, 0, out)

    -- Append a run check record that carries a jj change id
    local file = support.board_file(home, "mine")
    local doc = assert(json.decode(assert(fs.read(file))))
    local record = {}
    for key, value in pairs(doc.cards[1].comments[1]) do
        record[key] = value
    end
    record.body = string.format(
        table.concat({
            "dev-check: commit=%s change=abcdefgh mode=run rows=1 sum=ab5ba36a",
            "1 pass 28c702",
        }, "\n"),
        string.rep("a", 40)
    )
    table.insert(doc.cards[1].comments, record)
    assert(fs.write(file, assert(json.encode(doc))))

    -- Review again and expect git to accept the jj change id
    out, code = review()
    testing.eq(code, 0, out)
    testing.eq(#comments(home), 3)
end)

testing.test("review verdict is required, must be known and is written on the record", function()
    -- Refuse a review that has no verdict
    local root, home, head = git_root()
    local id = card_in(root, home)
    local out, code =
        dev(root, home, { "board", "review", id, "--kind", "code", "--by", "r", "--rev", "HEAD" })
    testing.eq(code, 2, out)

    -- Refuse an unknown verdict and name the known ones
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

    -- Write each known verdict on the record
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
    -- Take the card as the builder
    local root, home = git_root()
    local id = card_in(root, home)
    must(dev(root, home, { "board", "take", id, "--as", "dotfiles/builder" }))

    -- Refuse the builder as the reviewer
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

    -- Accept another reviewer
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
        -- Take the card twice and expect one claim note
        local root, home = git_root()
        local id = card_in(root, home)
        must(dev(root, home, { "board", "take", id, "--as", "dotfiles/builder" }))
        must(dev(root, home, { "board", "take", id, "--as", "dotfiles/builder" }))
        testing.eq(#comments(home), 1)
        testing.eq(comments(home)[1].body, "dev-claim: by=dotfiles/builder")

        -- Let the claim lapse
        local file = support.board_file(home, "mine")
        local doc = assert(json.decode(assert(fs.read(file))))
        doc.cards[1].claim.expires_at = "2000-01-01T00:00:00Z"
        assert(fs.write(file, assert(json.encode(doc))))

        -- Refuse the lapsed claimant as the reviewer of every kind
        for _, kind in ipairs({ "code", "style", "recheck" }) do
            local out, code = dev(
                root,
                home,
                support.with_of(kind, {
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
            )
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

        -- Accept another reviewer
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

        -- Refuse a note that forges a claim record
        out, code = dev(root, home, { "board", "note", id, "dev-claim: by=other" })
        testing.eq(code, 1, out)
        testing.ok(out:find("dev-claim:", 1, true), out)
    end
)

testing.test("review does not renew the claimants claim", function()
    -- Take the card as the builder
    local root, home = git_root()
    local id = card_in(root, home)
    must(dev(root, home, { "board", "take", id, "--as", "dotfiles/builder" }))

    -- Set the claim to expire far ahead
    local file = support.board_file(home, "mine")
    local doc = assert(json.decode(assert(fs.read(file))))
    local expires_at = "2999-01-01T00:00:00Z"
    doc.cards[1].claim.expires_at = expires_at
    assert(fs.write(file, assert(json.encode(doc))))

    -- Review as another reviewer
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
    testing.ok(not out:find("not renewed", 1, true), out)

    -- Leave the claim's expiry as it was
    doc = assert(json.decode(assert(fs.read(file))))
    testing.eq(doc.cards[1].claim.expires_at, expires_at)
end)

testing.test("note refuses a body that begins with the dev-tick prefix", function()
    local root, home = git_root()
    local id = card_in(root, home)
    local out, code = dev(root, home, { "board", "note", id, "dev-tick: by=other outcome=1" })
    testing.eq(code, 1, out)
    testing.ok(out:find("dev-tick:", 1, true), out)
    testing.eq(#comments(home), 0)
end)

testing.test("a tick writes a dev-tick record naming who ticked", function()
    local root, home = git_root()
    local id = card_in(root, home)
    must(dev(root, home, { "board", "outcome", id, "--tick", "1", "--as", "dotfiles/verifier" }))
    testing.eq(comments(home)[1].body, "dev-tick: by=dotfiles/verifier outcome=1")
end)

testing.test("a take with DEV_AGENT unset claims nothing, so no claimant reviews itself", function()
    -- Make a card in a git repo
    local root, home = git_root()
    local id = card_in(root, home)

    -- Take it from a session with a session id but no agent name
    local out, code = support.dev(root, { "board", "take", id }, {
        env = {
            HOME = home,
            XDG_STATE_HOME = home .. "/state",
            JJ_USER = "t",
            JJ_EMAIL = "t@example.com",
            DEV_AGENT = "",
            CLAUDE_SESSION_ID = "dotfiles/builder",
        },
    })

    -- Refuse the take and leave the card unclaimed
    testing.eq(code, 2, out)
    testing.ok(out:find("Set DEV_AGENT to <repo>/<role>[/<card>]", 1, true), out)
    testing.eq(#comments(home), 0)
end)

testing.test("review refuses an older default-named claimant when DEV_AGENT is unset", function()
    -- Make a card and a way to run dev as a named session
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

    -- Take the card as the builder
    must(support.dev(root, { "board", "take", id }, {
        env = {
            HOME = home,
            XDG_STATE_HOME = home .. "/state",
            JJ_USER = "t",
            JJ_EMAIL = "t@example.com",
            DEV_AGENT = "dotfiles/builder",
        },
    }))

    -- Rewrite the claimant to the older default name
    local host = dev_os.capture({ "hostname", "-s" }):gsub("%s+$", "")
    local old = "dev@" .. host .. ":builder"
    local path = support.board_file(home, "mine")
    local doc = assert(json.decode(assert(fs.read(path))))
    doc.cards[1].claim.claimant = old
    doc.cards[1].comments[1].body = "dev-claim: by=" .. old
    assert(fs.write(path, assert(json.encode(doc))))

    -- Refuse the builder's session as the reviewer of every kind
    for _, kind in ipairs({ "code", "style", "recheck" }) do
        local out, code = run(
            "builder",
            support.with_of(kind, {
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
        )
        testing.eq(code, 1, out)
        testing.ok(out:find("cannot review its own change", 1, true), out)
    end

    -- Accept another session as the reviewer
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

testing.test("review recheck needs of code or style, and of goes with no other kind", function()
    -- Make a card and a way to spell a review with or without --of
    local root, home = git_root()
    local id = card_in(root, home)
    local function review_args(kind, of)
        local args = {
            "board",
            "review",
            id,
            "--kind",
            kind,
            "--by",
            "r",
            "--rev",
            "HEAD",
            "--verdict",
            "clean",
        }
        if of then
            args[#args + 1] = "--of"
            args[#args + 1] = of
        end
        return args
    end

    -- Refuse a recheck that names no kind or the wrong one to recheck
    local out, code = dev(root, home, review_args("recheck"))
    testing.eq(code, 2, out)
    testing.ok(out:find("A recheck needs --of code|style", 1, true), out)
    out, code = dev(root, home, review_args("recheck", "recheck"))
    testing.eq(code, 2, out)

    -- Refuse --of on any other kind
    out, code = dev(root, home, review_args("code", "code"))
    testing.eq(code, 2, out)
    testing.ok(out:find("The --of flag goes only with --kind recheck", 1, true), out)
    testing.eq(#comments(home), 0)

    -- Accept a recheck of style
    out, code = dev(root, home, review_args("recheck", "style"))
    testing.eq(code, 0, out)
    testing.eq(#comments(home), 1)
end)

testing.test("review recheck record carries of and parse reads it back", function()
    -- Write a recheck record that names what it rechecks
    local review = require("@dev/board/review")
    local rev = { commit = "abc123", change = "chg" }
    local body = review.record("recheck", "r", rev, "clean", "style")
    testing.eq(
        body,
        "dev-review: kind=recheck by=r commit=abc123 change=chg of=style verdict=clean"
    )

    -- Read the record back
    local record = review.parse(body)
    testing.eq(record.of, "style")
    testing.eq(record.kind, "recheck")
    testing.eq(record.verdict, "clean")

    -- Read no target from a record that has none
    testing.eq(review.parse(review.record("code", "r", rev, "clean")).of, nil)
end)

testing.test(
    "review refuses an unknown kind, a missing flag and a rev that is not a commit",
    function()
        -- Refuse an unknown kind and name the known ones
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

        -- Refuse a missing flag and a reviewer name with a space
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

        -- Refuse a rev that is not a commit and write nothing
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
    -- Refuse a note that writes the review prefix
    local root, home = git_root()
    local id = card_in(root, home)
    local out, code = dev(root, home, { "board", "note", id, "  DEV-REVIEW: kind=code" })
    testing.eq(code, 1, out)
    testing.ok(out:find("`dev board review` writes", 1, true), out)

    -- Record a review and refuse to edit or delete its note
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

    -- Refuse to edit a plain note into a review record
    must(dev(root, home, { "board", "note", id, "plain" }))
    listing = dev(root, home, { "board", "notes", id })
    local second = assert(listing:match("\n(%x+)"), listing)
    out, code = dev(root, home, { "board", "note", id, "--edit", second, "dev-review: forged" })
    testing.eq(code, 1, out)
    testing.eq(#comments(home), 2)
end)

testing.test("a review that cannot be written is never reported as recorded", function()
    -- Fake a backend whose note write fails
    local root = git_root()
    local card = {
        id = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        name = "Card",
        column = support.COLUMN_NAME.PROGRESS,
        size = "unsized",
        labels = {},
        checks = {},
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
        return nil, "Curl exit 28."
    end

    -- Review the card against that backend
    local result = require("@dev/cmd/board").run(
        "review",
        { "11111111", "--kind", "code", "--by", "r", "--rev", "HEAD", "--verdict", "clean" },
        backend
    )

    -- Report the failure with no sign of a recorded review
    testing.eq(result.output, nil)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("was NOT recorded", 1, true), result.message)
    testing.ok(result.message:find("Curl exit 28", 1, true), result.message)
end)

local function seat_backend(root, refusal, reason)
    -- Describe one card in progress
    local card = {
        id = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        name = "Card",
        column = support.COLUMN_NAME.PROGRESS,
        size = "unsized",
        labels = {},
        checks = {},
        outcomes = {},
    }

    -- Serve that card from a backend that remembers every seat verdict and note
    local backend = { root = root, seats = {}, notes = {} }
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
    function backend:seat_verdict(id, seat, name, verdict, revision)
        self.seats[#self.seats + 1] =
            { id = id, seat = seat, name = name, verdict = verdict, revision = revision }
        if refusal then
            return nil, refusal, reason
        end
        return true
    end
    function backend:note(_, body)
        self.notes[#self.notes + 1] = body
        return true
    end
    return backend
end

local function review_as(backend, kind, verdict, by)
    return require("@dev/cmd/board").run(
        "review",
        { "11111111", "--kind", kind, "--by", by or "r", "--rev", "HEAD", "--verdict", verdict },
        backend
    )
end

testing.test("a clean or minor review sets the seat approved with the revision", function()
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

testing.test("a needs-work review sets the seat to changes needed", function()
    -- Fake a backend that accepts every seat verdict
    local root = git_root()
    local backend = seat_backend(root)

    -- Review the code as needing work
    local result = review_as(backend, "code", "needs-work")

    -- Set the seat to changes needed
    testing.eq(result.code, nil, result.message)
    testing.eq(backend.seats[1].seat, "code")
    testing.eq(backend.seats[1].verdict, "changes_needed")
end)

testing.test("a review reports a seat that Pomb refused", function()
    -- Fake a backend that refuses the seat as the owner's
    local root = git_root()
    local backend = seat_backend(
        root,
        "pomb answered 409: the task's owner cannot take a seat on it (owner_seat)"
    )

    -- Review the code against it
    local result = review_as(backend, "code", "clean")

    -- Record the review, warn once and write the note
    testing.eq(result.code, nil)
    testing.ok(result.output:find("recorded code review by r", 1, true), result.output)
    testing.eq(#result.warnings, 1)
    testing.ok(result.warnings[1]:find("owner_seat", 1, true), result.warnings[1])
    testing.ok(result.warnings[1]:find("seat of card", 1, true), result.warnings[1])
    testing.eq(#backend.notes, 1)
end)

local OWNER_SEAT = "pomb answered 409: the task's owner cannot take a seat on it (owner_seat)"
local MINT_HINT = "dev board token mint --role reviewer --as r"

local function owner_seat_warning(with_token, by)
    -- Point the token store at an empty state directory
    local previous_state = dev_os.getenv("XDG_STATE_HOME") or ""
    local previous_runtime = dev_os.getenv("XDG_RUNTIME_DIR") or ""
    dev_os.setenv("XDG_RUNTIME_DIR", "")
    dev_os.setenv("XDG_STATE_HOME", support.tempdir())
    local written = true
    if with_token then
        written = tokenfile.write(by or "r", "pomb_token0123456789", 0)
    end

    -- Review against a backend that refuses the seat as the owner's
    local root = git_root()
    local backend = seat_backend(root, OWNER_SEAT)
    local ran, result = pcall(review_as, backend, "code", "clean", by)
    dev_os.setenv("XDG_STATE_HOME", previous_state)
    dev_os.setenv("XDG_RUNTIME_DIR", previous_runtime)

    -- Hand back the single warning the review printed
    assert(written, "token file was not written")
    assert(ran, result)
    testing.eq(result.code, nil, result.message)
    testing.eq(#backend.notes, 1)
    testing.eq(#result.warnings, 1)
    return result.warnings[1]
end

testing.test("review names the missing reviewer token on an owner_seat refusal", function()
    local warning = owner_seat_warning(false)
    testing.ok(warning:find("No minted reviewer token file was found for r.", 1, true), warning)
    testing.ok(warning:find(MINT_HINT, 1, true), warning)
    testing.ok(warning:find("reviewer_token", 1, true), warning)
end)

testing.test("review names verifier_token in the missing token sentence for a verifier", function()
    local name = "dotfiles/verifier/bff0e010"
    local warning = owner_seat_warning(false, name)
    testing.ok(
        warning:find("No minted reviewer token file was found for " .. name, 1, true),
        warning
    )
    testing.ok(warning:find("`verifier_token`", 1, true), warning)
    testing.eq(warning:find("`reviewer_token`", 1, true), nil, warning)
end)

testing.test("review with a live token file adds no missing token sentence", function()
    local warning = owner_seat_warning(true)
    testing.ok(warning:find("owner_seat", 1, true), warning)
    testing.eq(warning:find("No minted reviewer token", 1, true), nil)
    testing.eq(warning:find(MINT_HINT, 1, true), nil)
end)

local function recheck_of(backend, of)
    return require("@dev/cmd/board").run("review", {
        "11111111",
        "--kind",
        "recheck",
        "--of",
        of,
        "--by",
        "r",
        "--rev",
        "HEAD",
        "--verdict",
        "clean",
    }, backend)
end

testing.test("a refused recheck with the seat held prints no warning", function()
    -- Fake a backend that refuses the seat as held
    local root = git_root()
    local backend = seat_backend(root, "pomb answered 409: the seat is taken (seat_held)")

    -- Recheck style against it
    local result = recheck_of(backend, "style")

    -- Print no warning and say only the card records the review
    testing.eq(result.code, nil, result.message)
    testing.eq(result.warnings, nil)
    testing.ok(
        result.output:find(
            "The recheck seat is already held, so only the card records this review.",
            1,
            true
        ),
        result.output
    )
    testing.eq(#backend.notes, 1)
end)

testing.test("a code review refused with the seat held warns", function()
    -- Fake a backend that refuses the seat as held
    local root = git_root()
    local backend = seat_backend(root, "pomb answered 409: the seat is taken (seat_held)")

    -- Review the code against it
    local result = review_as(backend, "code", "clean")

    -- Warn with the reset command and leave out the recheck sentence
    testing.eq(result.code, nil)
    testing.eq(#result.warnings, 1)
    testing.ok(result.warnings[1]:find("seat_held", 1, true), result.warnings[1])
    testing.ok(result.warnings[1]:find("dev board seat reset", 1, true), result.warnings[1])
    testing.eq(result.output:find("already held", 1, true), nil)
end)

testing.test("a refused recheck with the owner seat still warns", function()
    -- Fake a backend that refuses the seat as the owner's
    local root = git_root()
    local backend = seat_backend(
        root,
        "pomb answered 409: the task's owner cannot take a seat on it (owner_seat)"
    )

    -- Recheck code against it
    local result = recheck_of(backend, "code")

    -- Warn once with the refusal's code
    testing.eq(result.code, nil, result.message)
    testing.eq(#result.warnings, 1)
    testing.ok(result.warnings[1]:find("owner_seat", 1, true), result.warnings[1])
end)

testing.test("a review writes the missing seat warning from its reason", function()
    -- Fake a backend that cannot add the missing seat
    local root = git_root()
    local backend = seat_backend(root, "add refused", board.SeatReason.NO_SEAT)

    -- Review the code against it
    local result = review_as(backend, "code", "clean")

    -- Warn that the card has no seat and say how to take one
    testing.eq(result.code, nil)
    testing.eq(#result.warnings, 1)
    testing.ok(
        result.warnings[1]:find(
            "The card has no code seat and this token cannot add one (add refused).",
            1,
            true
        ),
        result.warnings[1]
    )
    testing.ok(result.warnings[1]:find("dev board take first.", 1, true), result.warnings[1])
end)

testing.test("a review still writes the dev-review comment", function()
    -- Fake a backend that accepts every seat verdict
    local root, _, head = git_root()
    local backend = seat_backend(root)

    -- Review the code against it
    local result = review_as(backend, "code", "clean")

    -- Write the review record as a note all the same
    testing.eq(result.code, nil, result.message)
    testing.eq(backend.notes, {
        "dev-review: kind=code by=r commit=" .. head .. " change=- verdict=clean",
    })
end)

local function pomb_seats(answers)
    local backend = assert(require("@dev/board/pomb").new({
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
    -- Add no seat when a 404 says the task is missing
    local other = { nil, "pomb answered 404", 404, { message = "task not found" } }
    local backend = pomb_seats({ other })
    local ok, message = backend:seat_verdict("t1", "code", "r", "approved", "abc")
    testing.eq(ok, nil)
    testing.eq(message, "pomb answered 404")
    testing.eq(#backend.calls, 1)

    -- Stop at a refusal and name its code
    backend = pomb_seats({ { nil, "pomb answered 409", 409, { code = "owner_seat" } } })
    ok, message = backend:seat_verdict("t1", "code", "r", "approved", "abc")
    testing.eq({ ok, message, #backend.calls }, { nil, "pomb answered 409 (owner_seat)", 1 })

    -- Stop when adding the missing seat fails
    backend = pomb_seats({ NO_SEAT, { nil, "add refused" } })
    local reason
    ok, message, reason = backend:seat_verdict("t1", "code", "r", "approved", "abc")
    testing.eq(
        { ok, message, reason, #backend.calls },
        { nil, "add refused", board.SeatReason.NO_SEAT, 2 }
    )

    -- Stop when the verdict post fails
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
            -- Make a jj repo with a base commit and a card
            local root, home = setup()
            must(
                dev_os.run(
                    { "jj", "git", "init", root },
                    { stdout = "null", stderr = "null", env = IDENT }
                )
            )
            jj(root, "commit", "-m", "base")
            local id = card_in(root, home)

            -- Look up the commit and change id of the base
            local want =
                jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id ++ ' ' ++ change_id")
            local commit, change = want:match("^(%x+) (%a+)")

            -- Review the base and expect the change id on the record
            local out, code = dev(root, home, {
                "board",
                "review",
                id,
                "--kind",
                "recheck",
                "--of",
                "code",
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
                    .. " of=code verdict=clean"
            )

            -- Refuse a revset of many commits and write nothing more
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
        local file = support.board_file(home, "mine")
        local doc = assert(json.decode(assert(fs.read(file))))
        local record = {}
        for key, value in pairs(doc.cards[1].comments[1]) do
            record[key] = value
        end
        record.body = string.format(
            table.concat({
                "dev-check: commit=%s change=%s mode=run rows=1 sum=ab5ba36a",
                "1 pass 28c702",
            }, "\n"),
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

    testing.test("review names dev board check when the card holds another change", function()
        -- Make a jj repo with a base commit, a card and a way to review a rev
        local root, home = setup()
        must(
            dev_os.run(
                { "jj", "git", "init", root },
                { stdout = "null", stderr = "null", env = IDENT }
            )
        )
        jj(root, "commit", "-m", "base")
        local id = card_in(root, home)
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

        -- Record a review of the base
        local out, code = review("@-")
        testing.eq(code, 0, out)

        -- Review the working change and expect a pointer to dev board check
        out, code = review("@")
        testing.eq(code, 1, out)
        testing.ok(out:find("`dev board check` at this commit", 1, true), out)
    end)
end

local SEATS_ID = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
local SEATS_FAR_ID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"

local SERVERS = {}

local function seats_root()
    local root = support.sandbox({
        ["boards.json"] = '[{"id":"board-1","name":"dotfiles","archived":false}]',
        ["detail.json"] = '{"id":"board-1","name":"dotfiles","swimlanes":[],"columns":'
            .. '[{"id":"col-icebox","name":"'
            .. support.COLUMN_NAME.ICEBOX
            .. '"}]}',
        ["colors.json"] = "[]",
        ["export.json"] = '{"tasks":[' .. support.pomb_export_task({
            id = SEATS_ID,
            name = "seat card",
            column_id = "col-icebox",
        }) .. "]}",
        ["comments.json"] = "[]",
    }, {})
    SERVERS[root] =
        support.pomb_server(root, SEATS_ID, "22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb", SEATS_ID)
    return root
end

local function on_seats(root, run)
    -- Remember the token variables to restore
    local names = { "DEV_BOARD_TOKEN" }
    local previous = {}
    for _, name in ipairs(names) do
        previous[name] = dev_os.getenv(name) or ""
    end

    -- Sync the server and run against a backend that holds a token
    support.pomb_sync(root)
    dev_os.setenv("DEV_BOARD_TOKEN", "pomb_SECRETtoken0123456789")
    local ok, err = pcall(function()
        run(assert(pomb.new({
            url = SERVERS[root].url,
            token = "pass:secrets/worker/token/pomb",
            name = "dotfiles",
        })))
    end)

    -- Put the token variables back and surface any failure
    for _, name in ipairs(names) do
        dev_os.setenv(name, previous[name])
    end
    assert(ok, err)
end

testing.test("seats returns the verdict and revision of each seat", function()
    -- Serve one decided seat and one idle seat
    local root = seats_root()
    assert(
        fs.write(
            root .. "/task.seats.json",
            '[{"name":"code","role":"reviewer","holder":"r","idle":false,'
                .. '"verdict":"approved","revision":"abc123"},'
                .. '{"name":"style","role":"reviewer","holder":null,"idle":true,'
                .. '"verdict":null,"revision":null}]'
        )
    )

    -- Read both seats and see each one's verdict and revision
    on_seats(root, function(backend)
        local seats = assert(backend:seats(SEATS_ID))
        testing.eq(#seats, 2)
        testing.eq(seats[1].name, "code")
        testing.eq(seats[1].role, "reviewer")
        testing.eq(seats[1].verdict, "approved")
        testing.eq(seats[1].revision, "abc123")
        testing.eq(seats[1].holder, "r")
        testing.eq(seats[2].name, "style")
        testing.eq(seats[2].verdict, nil)
        testing.eq(seats[2].revision, nil)
        testing.eq(seats[2].holder, nil)
    end)
end)

testing.test("seats returns an empty list for a task with no seats key", function()
    on_seats(seats_root(), function(backend)
        local seats = assert(backend:seats(SEATS_ID))
        testing.eq(#seats, 0)
    end)
end)

testing.test("seats returns the reason when the read fails", function()
    local root = seats_root()
    assert(fs.write(root .. "/far.json", '{"message":"gone"}'))
    assert(fs.write(root .. "/far_gone", ""))
    on_seats(root, function(backend)
        local seats, message = backend:seats(SEATS_FAR_ID)
        testing.eq(seats, nil)
        testing.ok(message and message:find("gone", 1, true), tostring(message))
    end)
end)

local HELD_CODE_SEAT = '[{"name":"code","role":"reviewer","holder":"r","idle":false,'
    .. '"verdict":"changes_needed","revision":"abc123"}]'

local function calls_of(root)
    local lines = {}
    for _, entry in ipairs(support.pomb_requests(SERVERS[root])) do
        lines[#lines + 1] = entry.target
    end
    return lines
end

local function first_index(lines, matches)
    for index, line in ipairs(lines) do
        if matches(line) then
            return index
        end
    end
    return nil
end

local function posted_to_seats(line)
    return line:sub(-#"/seats") == "/seats"
end

testing.test("a lead resets a held seat", function()
    -- Serve a held seat that asks for changes
    local root = seats_root()
    assert(fs.write(root .. "/task.seats.json", HELD_CODE_SEAT))

    -- Reset the seat, report who held it, and let another reviewer take it
    on_seats(root, function(backend)
        local done, message, missing, previous = backend:reset_seat(SEATS_ID, "code")
        testing.eq({ done, message, missing }, { true, nil, nil })
        testing.eq(previous.holder, "r")
        testing.eq(previous.verdict, "changes_needed")
        local took, why = backend:seat_verdict(SEATS_ID, "code", "r2", "approved", "def456")
        testing.eq(took, true, tostring(why))
    end)

    -- Check the calls dropped the seat, added it again and then took it
    local lines = calls_of(root)
    local dropped = first_index(lines, function(line)
        return line:sub(-#"/seats?name=code") == "/seats?name=code"
    end)
    local added = first_index(lines, posted_to_seats)
    local taken = first_index(lines, function(line)
        return line:sub(-#"/seats/take") == "/seats/take"
    end)
    testing.ok(
        dropped and added and taken and dropped < added and added < taken,
        table.concat(lines, "\n")
    )

    -- Check the drop went out as a DELETE
    local deleted = false
    for _, entry in ipairs(support.pomb_requests(SERVERS[root])) do
        deleted = deleted or entry.method == "DELETE"
    end
    testing.ok(deleted)
end)

testing.test("a reset without seats.manage is refused", function()
    -- Serve a held seat and refuse every drop
    local root = seats_root()
    assert(fs.write(root .. "/task.seats.json", HELD_CODE_SEAT))
    assert(fs.write(root .. "/seat_drop_refused", ""))

    -- Reset the seat and see the missing permission named
    on_seats(root, function(backend)
        local done, message, missing = backend:reset_seat(SEATS_ID, "code")
        testing.eq(done, nil)
        testing.ok(message ~= nil)
        testing.eq(missing, "seats.manage")
    end)

    -- Add no seat after the refused drop
    testing.eq(first_index(calls_of(root), posted_to_seats), nil)
end)
