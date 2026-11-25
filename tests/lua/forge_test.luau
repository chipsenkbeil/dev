local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local forge = require("@dev/forge")
local fs = require("@dev/fs")
local support = require("./support")
local vcs = require("@dev/vcs")

local has_jj = dev_os.which("jj") ~= nil

dev_os.defaults.env =
    { GIT_CONFIG_GLOBAL = "/dev/null", GIT_CONFIG_NOSYSTEM = "1", JJ_CONFIG = "/dev/null" }

local function ok(argv, opts)
    opts = opts or {}
    opts.stdout = "null"
    opts.stderr = "null"
    assert(dev_os.run(argv, opts) == 0, table.concat(argv, " "))
end

local function git(root, ...)
    ok({ "git", "-C", root, ... })
end

local function repo(remotes, config)
    -- Make a git repo
    local root = assert(fs.realpath(support.tempdir()))
    git(root, "init", "-q")

    -- Add each remote
    for _, remote in ipairs(remotes) do
        git(root, "remote", "add", remote[1], remote[2])
    end

    -- Set each config key
    for _, pair in ipairs(config or {}) do
        git(root, "config", pair[1], pair[2])
    end
    return root
end

local GITHUB = "git@github.com:o/r.git"
local LOCAL = "/srv/git/r.git"

local CASES = {
    {
        name = "a gerrit remote means gerrit, even with a github origin",
        remotes = { { "origin", GITHUB }, { "gerrit", "ssh://c@g:29418/r" } },
        want = { "gerrit", "gerrit", "detected: the project has a gerrit remote" },
    },
    {
        name = "a github origin without a gerrit remote means github on origin",
        remotes = { { "origin", GITHUB } },
        want = { "github", "origin", "detected: origin is on github.com" },
    },
    {
        name = "any other origin means plain",
        remotes = { { "origin", LOCAL } },
        want = {
            "plain",
            "origin",
            "detected: no gerrit remote and origin is not on github.com",
        },
    },
    {
        name = "forge.kind wins over detection",
        remotes = { { "origin", GITHUB } },
        config = { { "forge.kind", "plain" } },
        want = { "plain", "origin", "git config forge.kind=plain" },
    },
    {
        name = "forge.remote names the remote of record",
        remotes = { { "origin", LOCAL }, { "gerrit", LOCAL } },
        config = { { "forge.kind", "plain" }, { "forge.remote", "gerrit" } },
        want = {
            "plain",
            "gerrit",
            "git config forge.kind=plain; remote from git config forge.remote",
        },
    },
    {
        name = "no remote at all is not a remote of the project",
        remotes = {},
        err = "the remote of record origin is not a remote of this project "
            .. "(detected: no gerrit remote and origin is not on github.com)",
    },
    {
        name = "a gerrit forge without a gerrit remote fails",
        remotes = { { "origin", LOCAL } },
        config = { { "forge.kind", "gerrit" } },
        err = "the remote of record gerrit is not a remote of this project "
            .. "(git config forge.kind=gerrit)",
    },
    {
        name = "an unknown forge kind is named",
        remotes = { { "origin", LOCAL } },
        config = { { "forge.kind", "bogus" } },
        err = "forge must be gerrit, github or plain (got: bogus, from git config forge.kind=bogus)",
    },
}

for _, case in ipairs(CASES) do
    testing.test("git: " .. case.name, function()
        -- Make a repo with the remotes and config of the case
        local root = repo(case.remotes, case.config)

        -- Resolve its forge
        local got, err = forge.resolve(root)

        -- Name the forge and why, or the error
        if case.err then
            testing.eq(got, nil)
            testing.eq(err, case.err)
        else
            testing.eq({ got.kind, got.remote, got.why }, case.want)
        end

        -- Remove the repo
        fs.remove(root, { recursive = true })
    end)
end

testing.test("a directory with neither .jj nor .git has no forge", function()
    -- Make a directory with no repo
    local root = assert(fs.realpath(support.tempdir()))

    -- Resolve its forge and find none
    local got, err = forge.resolve(root)
    testing.eq(got, nil)
    testing.eq(err, vcs.Reason.NO_CHECKOUT)

    -- Remove the directory
    fs.remove(root, { recursive = true })
end)

if has_jj then
    local function jj_repo(remotes, config)
        -- Make a jj repo
        local root = assert(fs.realpath(support.tempdir()))
        ok({ "jj", "git", "init", root }, { env = { JJ_CONFIG = "/dev/null" } })

        -- Add each remote
        for _, remote in ipairs(remotes) do
            ok({ "jj", "--no-pager", "-R", root, "git", "remote", "add", remote[1], remote[2] })
        end

        -- Set each config key in the git store
        local store = dev_os.capture({ "jj", "--no-pager", "-R", root, "git", "root" })
        for _, pair in ipairs(config or {}) do
            ok({ "git", "--git-dir=" .. store:gsub("\n$", ""), "config", pair[1], pair[2] })
        end
        return root
    end

    testing.test("jj: a gerrit remote means gerrit", function()
        -- Make a jj repo with a github origin and a gerrit remote
        local root = jj_repo({ { "origin", GITHUB }, { "gerrit", "ssh://c@g:29418/r" } })

        -- Resolve its forge as gerrit
        local got = forge.resolve(root)
        testing.eq({ got.kind, got.remote }, { "gerrit", "gerrit" })

        -- Detect the jj backend and list both remotes
        testing.eq(vcs.backend(root), "jj")
        testing.eq(vcs.remotes(root, "jj"), { "gerrit", "origin" })

        -- Remove the repo
        fs.remove(root, { recursive = true })
    end)

    testing.test("jj: forge.kind is read from the git store under .jj", function()
        -- Make a jj repo whose git store says forge.kind is github
        local root = jj_repo({ { "origin", LOCAL } }, { { "forge.kind", "github" } })

        -- Resolve its forge from that key
        local got = forge.resolve(root)
        testing.eq(
            { got.kind, got.remote, got.why },
            { "github", "origin", "git config forge.kind=github" }
        )

        -- Remove the repo
        fs.remove(root, { recursive = true })
    end)
end

testing.test("trunk prefers master over main and is nil without either", function()
    testing.eq(vcs.trunk({ "main", "master" }), "master")
    testing.eq(vcs.trunk({ "dev", "main" }), "main")
    testing.eq(vcs.trunk({ "dev" }), nil)
end)

testing.test("git branches and remotes list what git has", function()
    -- Make a repo with one commit on main
    local root = repo({})
    git(
        root,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@t",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        "x"
    )
    git(root, "branch", "-M", "main")

    -- List the branch
    testing.eq(vcs.branches(root, "git"), { "main" })

    -- Add a remote and list it
    git(root, "remote", "add", "origin", LOCAL)
    testing.eq(vcs.remotes(root, "git"), { "origin" })

    -- Remove the repo
    fs.remove(root, { recursive = true })
end)

local SSH_STUB = table.concat({
    "#!/bin/sh",
    'echo "$*" >>"$STUB_LOG"',
    'case "$*" in',
    '*" query "*) cat "$STUB_QUERY" ;;',
    "esac",
    "",
}, "\n")

local OPEN_ROW = table.concat({
    '{"id":"I1","status":"NEW","currentPatchSet":{"number":2,"revision":"abc123"}}',
    '{"type":"stats","rowCount":1}',
    "",
}, "\n")

local function abandon_fixture(row)
    -- Make a repo with a gerrit remote
    local root = repo({ { "gerrit", "ssh://c@g.example:29418/proj/sub.git" } })

    -- Stand in for ssh with a stub
    local bin = root .. "/bin"
    assert(fs.mkdir(bin, { parents = true }))
    assert(fs.write(bin .. "/ssh", SSH_STUB))
    assert(dev_os.run({ "chmod", "755", bin .. "/ssh" }) == 0, "chmod failed")

    -- Have the stub answer the query with the row
    assert(fs.write(root .. "/query", row))
    local env = { STUB_LOG = root .. "/log", STUB_QUERY = root .. "/query" }
    return root, env
end

local function calls(root)
    return fs.read(root .. "/log") or ""
end

testing.test("abandon.sends.the.query.then.the.review.abandon", function()
    -- Abandon a change by its id
    local root, env = abandon_fixture(OPEN_ROW)
    local out, code = support.dev(root, { "abandon", "I1" }, { env = env })
    testing.eq(code, 0, out)

    -- Query it, then abandon its patch set
    local want = table.concat({
        "-o BatchMode=yes -p 29418 c@g.example gerrit query --format=JSON "
            .. "--current-patch-set project:proj/sub change:I1",
        "-o BatchMode=yes -p 29418 c@g.example gerrit review --abandon abc123",
        "",
    }, "\n")
    testing.eq(calls(root), want)

    -- Remove the repo
    fs.remove(root, { recursive = true })
end)

testing.test("abandon.queries.a.change.by.its.number", function()
    -- Abandon a change by its number
    local root, env = abandon_fixture(OPEN_ROW)
    local out, code = support.dev(root, { "abandon", "101" }, { env = env })
    testing.eq(code, 0, out)

    -- Query it by number, then abandon its patch set
    local want = table.concat({
        "-o BatchMode=yes -p 29418 c@g.example gerrit query --format=JSON "
            .. "--current-patch-set project:proj/sub change:101",
        "-o BatchMode=yes -p 29418 c@g.example gerrit review --abandon abc123",
        "",
    }, "\n")
    testing.eq(calls(root), want)

    -- Remove the repo
    fs.remove(root, { recursive = true })
end)

testing.test("abandon.sends.the.reason.as.the.message", function()
    -- Abandon a change with a reason that holds a quote
    local root, env = abandon_fixture(OPEN_ROW)
    local out, code = support.dev(
        root,
        { "abandon", "I1", "--reason", "it's stale" },
        { env = env }
    )
    testing.eq(code, 0, out)

    -- Send the reason shell-quoted as the message
    local want = [[gerrit review --abandon --message 'it'\''s stale' abc123]]
    testing.eq(calls(root):find(want, 1, true) ~= nil, true, calls(root))

    -- Remove the repo
    fs.remove(root, { recursive = true })
end)

testing.test("abandon.refuses.a.change.that.is.not.open", function()
    -- Offer a merged change and an unknown one
    local merged = OPEN_ROW:gsub("NEW", "MERGED")
    local cases = {
        { row = merged, want = "Change I1 is MERGED, not NEW." },
        { row = '{"type":"stats","rowCount":0}\n', want = "Gerrit has no change I1" },
    }

    -- Refuse each one and send no review
    for _, case in ipairs(cases) do
        local root, env = abandon_fixture(case.row)
        local out, code = support.dev(root, { "abandon", "I1" }, { env = env })
        testing.eq(code, 1, out)
        testing.eq(out:find(case.want, 1, true) ~= nil, true, out)
        testing.eq(calls(root):find("review", 1, true), nil, calls(root))
        fs.remove(root, { recursive = true })
    end
end)

testing.test("abandon.picks.the.open.row.among.several.branches", function()
    -- Offer a merged row before the open one
    local merged = '{"id":"I1","status":"MERGED","currentPatchSet":{"revision":"old000"}}\n'
    local root, env = abandon_fixture(merged .. OPEN_ROW)
    local out, code = support.dev(root, { "abandon", "I1" }, { env = env })
    testing.eq(code, 0, out)

    -- Abandon the patch set of the open row
    testing.eq(calls(root):find("--abandon abc123", 1, true) ~= nil, true, calls(root))

    -- Remove the repo
    fs.remove(root, { recursive = true })
end)

testing.test("abandon.refuses.a.forge.that.is.not.gerrit", function()
    -- Make the repo a plain forge
    local root, env = abandon_fixture(OPEN_ROW)
    git(root, "config", "forge.kind", "plain")
    git(root, "remote", "add", "origin", LOCAL)

    -- Abandon a change
    local out, code = support.dev(root, { "abandon", "I1" }, { env = env })

    -- Refuse and call nothing
    testing.eq(code, 1, out)
    testing.eq(out:find("only a gerrit change can be abandoned", 1, true) ~= nil, true, out)
    testing.eq(calls(root), "")

    -- Remove the repo
    fs.remove(root, { recursive = true })
end)
