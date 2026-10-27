local t = require("testing")
local devos = require("dev.os")
local forge = require("dev.forge")
local fs = require("dev.fs")
local support = require("support")
local vcs = require("dev.vcs")

local has_jj = devos.which("jj") ~= nil

local function ok(argv, opts)
    opts = opts or {}
    opts.stdout = "null"
    opts.stderr = "null"
    assert(devos.run(argv, opts) == 0, table.concat(argv, " "))
end

local function git(root, ...)
    ok({ "git", "-C", root, ... })
end

local function repo(remotes, config)
    local root = assert(fs.realpath(support.tempdir()))
    git(root, "init", "-q")
    for _, remote in ipairs(remotes) do
        git(root, "remote", "add", remote[1], remote[2])
    end
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
    t.test("git: " .. case.name, function()
        local root = repo(case.remotes, case.config)
        local got, err = forge.resolve(root)
        if case.err then
            t.eq(got, nil)
            t.eq(err, case.err)
        else
            t.eq({ got.kind, got.remote, got.why }, case.want)
        end
        fs.remove(root, { recursive = true })
    end)
end

t.test("a directory with neither .jj nor .git has no forge", function()
    local root = assert(fs.realpath(support.tempdir()))
    local got, err = forge.resolve(root)
    t.eq(got, nil)
    t.eq(err, "neither .jj nor .git found in " .. root)
    fs.remove(root, { recursive = true })
end)

if has_jj then
    local function jj_repo(remotes, config)
        local root = assert(fs.realpath(support.tempdir()))
        ok({ "jj", "git", "init", root }, { env = { JJ_CONFIG = "/dev/null" } })
        for _, remote in ipairs(remotes) do
            ok({ "jj", "--no-pager", "-R", root, "git", "remote", "add", remote[1], remote[2] })
        end
        local store = devos.capture({ "jj", "--no-pager", "-R", root, "git", "root" })
        for _, pair in ipairs(config or {}) do
            ok({ "git", "--git-dir=" .. store:gsub("\n$", ""), "config", pair[1], pair[2] })
        end
        return root
    end

    t.test("jj: a gerrit remote means gerrit", function()
        local root = jj_repo({ { "origin", GITHUB }, { "gerrit", "ssh://c@g:29418/r" } })
        local got = forge.resolve(root)
        t.eq({ got.kind, got.remote }, { "gerrit", "gerrit" })
        t.eq(vcs.backend(root), "jj")
        t.eq(vcs.remotes(root, "jj"), { "gerrit", "origin" })
        fs.remove(root, { recursive = true })
    end)

    t.test("jj: forge.kind is read from the git store under .jj", function()
        local root = jj_repo({ { "origin", LOCAL } }, { { "forge.kind", "github" } })
        local got = forge.resolve(root)
        t.eq(
            { got.kind, got.remote, got.why },
            { "github", "origin", "git config forge.kind=github" }
        )
        fs.remove(root, { recursive = true })
    end)
end

t.test("the guard path is refused when DEV_SELF is not absolute", function()
    local root = repo({ { "origin", LOCAL } })
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
    for _, self in ipairs({ "", "dev" }) do
        local out, code = support.dev(root, { "push" }, { env = { DEV_SELF = self } })
        t.eq(code, 1)
        t.eq(
            out,
            "dev: DEV_SELF is not an absolute path, refusing to push without the attribution check\n"
        )
    end
    fs.remove(root, { recursive = true })
end)

t.test("trunk prefers master over main and is nil without either", function()
    t.eq(vcs.trunk({ "main", "master" }), "master")
    t.eq(vcs.trunk({ "dev", "main" }), "main")
    t.eq(vcs.trunk({ "dev" }), nil)
end)

t.test("git branches and remotes list what git has", function()
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
    t.eq(vcs.branches(root, "git"), { "main" })
    git(root, "remote", "add", "origin", LOCAL)
    t.eq(vcs.remotes(root, "git"), { "origin" })
    fs.remove(root, { recursive = true })
end)
