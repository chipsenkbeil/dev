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
    local out = dev(
        root,
        home,
        { "board", "add", "Card", "--problem", "x", "--size", "1", "--done-when", "a" }
    )
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
    testing.ok(out:find("the verdicts are clean, minor, needs-work", 1, true), out)
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
        testing.ok(out:find("the kinds are code, style, recheck", 1, true), out)
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
end
