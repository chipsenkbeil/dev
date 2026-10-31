local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local has_jj = devos.which("jj") ~= nil
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
    local out = dev(root, home, { "board", "add", "Card", "--problem", "x" })
    return assert(out:match("added (%x+)"), out)
end

local function git_root()
    local root, home = setup()
    local function git(...)
        local argv =
            { "git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@example.com", ... }
        must(devos.run(argv, { stdout = "null" }))
    end
    must(devos.run({ "git", "init", "-q", root }, { stdout = "null" }))
    git("add", "-A")
    git("commit", "-q", "-m", "base")
    local head = devos.capture({ "git", "-C", root, "rev-parse", "HEAD" }):gsub("\n$", "")
    return root, home, head
end

local function comments(home)
    local doc = assert(json.decode(assert(fs.read(home .. "/state/dev/boards/mine.json"))))
    return doc.cards[1].comments or {}
end

t.test("review records the kind, the name and the commit in git", function()
    local root, home, head = git_root()
    local id = card_in(root, home)
    local out, code = dev(
        root,
        home,
        { "board", "review", id, "--kind", "code", "--by", "rev1", "--rev", "HEAD" }
    )
    t.eq(code, 0, out)
    t.ok(
        out:find(
            "recorded code review by rev1 on " .. id .. " at commit " .. head:sub(1, 12),
            1,
            true
        ),
        out
    )
    t.eq(comments(home)[1].body, "dev-review: kind=code by=rev1 commit=" .. head .. " change=-")
    t.eq(comments(home)[1].kind, "status")
end)

t.test("review refuses the claimant as the reviewer", function()
    local root, home = git_root()
    local id = card_in(root, home)
    must(dev(root, home, { "board", "take", id, "--as", "builder" }))
    local out, code = dev(
        root,
        home,
        { "board", "review", id, "--kind", "style", "--by", "builder", "--rev", "HEAD" }
    )
    t.eq(code, 1, out)
    t.ok(out:find("cannot review its own change", 1, true), out)
    t.eq(#comments(home), 0)
    out, code = dev(
        root,
        home,
        { "board", "review", id, "--kind", "style", "--by", "other", "--rev", "HEAD" }
    )
    t.eq(code, 0, out)
    t.eq(#comments(home), 1)
end)

t.test("review refuses an unknown kind, a missing flag and a rev that is not a commit", function()
    local root, home = git_root()
    local id = card_in(root, home)
    local out, code =
        dev(root, home, { "board", "review", id, "--kind", "lint", "--by", "r", "--rev", "HEAD" })
    t.eq(code, 2, out)
    t.ok(out:find("the kinds are code, style, recheck", 1, true), out)
    out, code = dev(root, home, { "board", "review", id, "--kind", "code", "--by", "r" })
    t.eq(code, 2, out)
    out, code =
        dev(root, home, { "board", "review", id, "--kind", "code", "--by", "a b", "--rev", "HEAD" })
    t.eq(code, 2, out)
    for _, rev in ipairs({ "nosuchrev", "--all", "", "HEAD^{tree}" }) do
        out, code =
            dev(root, home, { "board", "review", id, "--kind", "code", "--by", "r", "--rev", rev })
        t.eq(code, 1, out)
    end
    t.eq(#comments(home), 0)
end)

t.test("note cannot write, edit or delete the review prefix", function()
    local root, home = git_root()
    local id = card_in(root, home)
    local out, code = dev(root, home, { "board", "note", id, "  DEV-REVIEW: kind=code" })
    t.eq(code, 1, out)
    t.ok(out:find("dev board review writes", 1, true), out)
    must(dev(root, home, { "board", "review", id, "--kind", "code", "--by", "r", "--rev", "HEAD" }))
    local listing = dev(root, home, { "board", "notes", id })
    local first = assert(listing:match("^(%x+)"), listing)
    out, code = dev(root, home, { "board", "note", id, "--edit", first, "fine" })
    t.eq(code, 1, out)
    out, code = dev(root, home, { "board", "note", id, "--delete", first })
    t.eq(code, 1, out)
    must(dev(root, home, { "board", "note", id, "plain" }))
    listing = dev(root, home, { "board", "notes", id })
    local second = assert(listing:match("\n(%x+)"), listing)
    out, code = dev(root, home, { "board", "note", id, "--edit", second, "dev-review: forged" })
    t.eq(code, 1, out)
    t.eq(#comments(home), 2)
end)

t.test("a review that cannot be written is never reported as recorded", function()
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
    function backend:note()
        return nil, "curl exit 28"
    end
    local result = require("dev.cmd.board").run(
        "review",
        { "11111111", "--kind", "code", "--by", "r", "--rev", "HEAD" },
        backend
    )
    t.eq(result.output, nil)
    t.eq(result.code, 1)
    t.ok(result.message:find("was NOT recorded", 1, true), result.message)
    t.ok(result.message:find("curl exit 28", 1, true), result.message)
end)

if has_jj then
    local function jj(root, ...)
        local argv = { "jj", "--no-pager", "--color", "never", "-R", root, ... }
        local out, code = devos.capture(argv, { stderr = "null", env = IDENT })
        assert(code == 0, out)
        return out
    end

    t.test(
        "in jj review stores the change id and one commit, and refuses a revset of many",
        function()
            local root, home = setup()
            must(
                devos.run(
                    { "jj", "git", "init", root },
                    { stdout = "null", stderr = "null", env = IDENT }
                )
            )
            jj(root, "commit", "-m", "base")
            local id = card_in(root, home)
            local want =
                jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id ++ ' ' ++ change_id")
            local commit, change = want:match("^(%x+) (%a+)")
            local out, code = dev(
                root,
                home,
                { "board", "review", id, "--kind", "recheck", "--by", "r", "--rev", "@-" }
            )
            t.eq(code, 0, out)
            t.eq(
                comments(home)[1].body,
                "dev-review: kind=recheck by=r commit=" .. commit .. " change=" .. change
            )
            out, code = dev(
                root,
                home,
                { "board", "review", id, "--kind", "code", "--by", "r", "--rev", "all()" }
            )
            t.eq(code, 1, out)
            t.eq(#comments(home), 1)
        end
    )
end
