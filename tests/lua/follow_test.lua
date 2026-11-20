local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local ENV = {
    GIT_CONFIG_GLOBAL = "/dev/null",
    GIT_CONFIG_NOSYSTEM = "1",
    JJ_CONFIG = "/dev/null",
    JJ_USER = "t",
    JJ_EMAIL = "t@example.com",
}
dev_os.defaults.env = ENV

local function git(root, ...)
    local out, code = dev_os.capture(
        { "git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@t", ... },
        { stderr = "stdout" }
    )
    assert(code == 0, out)
    return (out:gsub("\n$", ""))
end

local function jj(root, ...)
    local out, code = dev_os.capture(
        { "jj", "--no-pager", "--color", "never", "-R", root, ... },
        { stderr = "stdout" }
    )
    assert(code == 0, out)
    return (out:gsub("\n$", ""))
end

local function follow(root)
    return support.dev(root, { "follow" }, { env = ENV })
end

local function dir()
    return assert(fs.realpath(support.tempdir()))
end

local function bare()
    local remote = dir()
    git(remote, "init", "-q", "--bare", "-b", "master")
    return remote
end

local function advance(remote)
    local parent = dir()
    local other = parent .. "/other"
    git(parent, "clone", "-q", remote, other)
    assert(fs.write(other .. "/next.txt", "next\n"))
    git(other, "add", "next.txt")
    git(other, "commit", "-q", "-m", "next")
    git(other, "push", "-q", "origin", "master")
    return git(other, "rev-parse", "HEAD")
end

local function git_main()
    local remote = bare()
    local root = dir()
    git(root, "init", "-q", "-b", "master")
    git(root, "remote", "add", "origin", remote)
    assert(fs.write(root .. "/seed.txt", "seed\n"))
    git(root, "add", "seed.txt")
    git(root, "commit", "-q", "-m", "seed")
    git(root, "push", "-q", "origin", "master")
    return root, remote
end

local function jj_main()
    local remote = bare()
    local root = dir()
    local made = dev_os.run({ "jj", "git", "init", root }, { stdout = "null", stderr = "null" })
    assert(made == 0, "jj git init failed")
    jj(root, "git", "remote", "add", "origin", remote)
    assert(fs.write(root .. "/seed.txt", "seed\n"))
    jj(root, "commit", "-m", "base")
    jj(root, "bookmark", "create", "master", "-r", "@-")
    jj(root, "git", "push", "--remote", "origin", "--bookmark", "master")
    return root, remote
end

local function cleanup(...)
    for _, path in ipairs({ ... }) do
        fs.remove(path, { recursive = true })
    end
end

testing.test("follow.git.moves.a.stale.clean.checkout.onto.trunk", function()
    local root, remote = git_main()
    git(root, "checkout", "-q", "-b", "side")
    local head = advance(remote)
    local out, code = follow(root)
    testing.eq(code, 0, out)
    testing.ok(out:find(root .. " is on trunk " .. head:sub(1, 12), 1, true), out)
    testing.eq(git(root, "rev-parse", "--abbrev-ref", "HEAD"), "master")
    testing.eq(git(root, "rev-parse", "HEAD"), head)
    testing.eq(fs.exists(root .. "/next.txt"), true)
    cleanup(root, remote)
end)

testing.test("follow.git.leaves.a.checkout.with.uncommitted.edits.alone", function()
    local root, remote = git_main()
    git(root, "checkout", "-q", "-b", "side")
    local before = git(root, "rev-parse", "HEAD")
    advance(remote)
    assert(fs.write(root .. "/seed.txt", "edited\n"))
    local out, code = follow(root)
    testing.eq(code, 0, out)
    testing.ok(out:find(root .. " was left alone: it has uncommitted changes.", 1, true), out)
    testing.eq(git(root, "rev-parse", "--abbrev-ref", "HEAD"), "side")
    testing.eq(git(root, "rev-parse", "HEAD"), before)
    testing.eq(fs.read(root .. "/seed.txt"), "edited\n")
    cleanup(root, remote)
end)

testing.test("follow.git.moves.the.main.checkout.from.a.worktree", function()
    local root, remote = git_main()
    local worktree = dir() .. "/card"
    git(root, "worktree", "add", "-q", "-b", "card", worktree)
    local head = advance(remote)
    local out, code = follow(worktree)
    testing.eq(code, 0, out)
    testing.ok(out:find(root .. " is on trunk " .. head:sub(1, 12), 1, true), out)
    testing.eq(git(root, "rev-parse", "HEAD"), head)
    testing.eq(git(worktree, "rev-parse", "--abbrev-ref", "HEAD"), "card")
    cleanup(root, remote, worktree)
end)

testing.test("follow.git.leaves.a.detached.head.that.no.branch.holds.alone", function()
    local root, remote = git_main()
    git(root, "checkout", "-q", "--detach")
    git(root, "commit", "-q", "--allow-empty", "-m", "loose")
    local loose = git(root, "rev-parse", "HEAD")
    advance(remote)
    local out, code = follow(root)
    testing.eq(code, 0, out)
    testing.ok(out:find(root .. " was left alone: its detached HEAD holds commits", 1, true), out)
    testing.eq(git(root, "rev-parse", "HEAD"), loose)
    cleanup(root, remote)
end)

testing.test("follow.jj.moves.a.stale.clean.checkout.onto.trunk", function()
    local root, remote = jj_main()
    local head = advance(remote)
    local out, code = follow(root)
    testing.eq(code, 0, out)
    testing.ok(out:find(root .. " is on trunk " .. head:sub(1, 12), 1, true), out)
    testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), head)
    testing.eq(jj(root, "log", "-r", "@", "--no-graph", "-T", "empty"), "true")
    testing.eq(fs.exists(root .. "/next.txt"), true)
    cleanup(root, remote)
end)

testing.test("follow.jj.moves.onto.the.commit.in.DEV_FOLLOW_REV.not.trunk", function()
    local root, remote = jj_main()
    local base = jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
    advance(remote)
    local out, code = support.dev(root, { "follow" }, { env = { DEV_FOLLOW_REV = base } })
    testing.eq(code, 0, out)
    testing.ok(out:find(root .. " is on " .. base:sub(1, 12), 1, true), out)
    testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), base)
    testing.eq(fs.exists(root .. "/next.txt"), false)
    cleanup(root, remote)
end)

testing.test("follow.git.moves.onto.the.commit.in.DEV_FOLLOW_REV.not.trunk", function()
    local root, remote = git_main()
    local base = git(root, "rev-parse", "HEAD")
    advance(remote)
    local out, code = support.dev(root, { "follow" }, { env = { DEV_FOLLOW_REV = base } })
    testing.eq(code, 0, out)
    testing.ok(out:find(root .. " is on " .. base:sub(1, 12), 1, true), out)
    testing.eq(git(root, "rev-parse", "HEAD"), base)
    testing.eq(fs.exists(root .. "/next.txt"), false)
    cleanup(root, remote)
end)

testing.test("follow.refuses.a.DEV_FOLLOW_REV.that.is.not.a.commit.id", function()
    local root, remote = git_main()
    local out, code = support.dev(root, { "follow" }, { env = { DEV_FOLLOW_REV = "master" } })
    testing.eq(code, 2, out)
    cleanup(root, remote)
end)

testing.test("follow.jj.leaves.a.checkout.with.uncommitted.edits.alone", function()
    local root, remote = jj_main()
    local before = jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
    advance(remote)
    assert(fs.write(root .. "/seed.txt", "edited\n"))
    local out, code = follow(root)
    testing.eq(code, 0, out)
    testing.ok(out:find(root .. " was left alone: it has uncommitted changes.", 1, true), out)
    testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), before)
    testing.eq(fs.read(root .. "/seed.txt"), "edited\n")
    cleanup(root, remote)
end)

testing.test("follow.jj.leaves.an.empty.checkout.on.unlanded.changes.alone", function()
    local root, remote = jj_main()
    assert(fs.write(root .. "/local.txt", "local\n"))
    jj(root, "commit", "-m", "local")
    local before = jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
    advance(remote)
    local out, code = follow(root)
    testing.eq(code, 0, out)
    testing.ok(
        out:find(root .. " was left alone: it sits on changes that are not on trunk.", 1, true),
        out
    )
    testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), before)
    testing.eq(fs.exists(root .. "/next.txt"), false)
    cleanup(root, remote)
end)

testing.test("follow.jj.leaves.an.unlanded.checkout.alone.under.DEV_FOLLOW_REV", function()
    local root, remote = jj_main()
    local base = jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
    assert(fs.write(root .. "/local.txt", "local\n"))
    jj(root, "commit", "-m", "local")
    local before = jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
    local out, code = support.dev(root, { "follow" }, { env = { DEV_FOLLOW_REV = base } })
    testing.eq(code, 0, out)
    testing.ok(out:find("it sits on changes that are not on trunk.", 1, true), out)
    testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), before)
    cleanup(root, remote)
end)

testing.test("follow.jj.moves.an.empty.checkout.on.an.older.trunk.commit", function()
    local root, remote = jj_main()
    local old = jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
    local head = advance(remote)
    local out, code = follow(root)
    testing.eq(code, 0, out)
    testing.ok(out:find(root .. " is on trunk " .. head:sub(1, 12), 1, true), out)
    testing.ok(old ~= head, old)
    testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), head)
    cleanup(root, remote)
end)

testing.test("follow.jj.moves.the.main.checkout.from.a.workspace", function()
    local root, remote = jj_main()
    local workspace = dir() .. "/card"
    jj(root, "workspace", "add", "--name", "card", workspace)
    local head = advance(remote)
    local out, code = follow(workspace)
    testing.eq(code, 0, out)
    testing.ok(out:find(root .. " is on trunk " .. head:sub(1, 12), 1, true), out)
    testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), head)
    cleanup(root, remote, workspace)
end)

testing.test("follow.names.a.jj.repo.with.no.default.workspace", function()
    local root, remote = jj_main()
    jj(root, "workspace", "rename", "other")
    local out, code = follow(root)
    testing.eq(code, 1, out)
    testing.ok(
        out:find("The jj repository at " .. root .. " has no workspace named default.", 1, true),
        out
    )
    cleanup(root, remote)
end)

testing.test("follow.names.a.git.checkout.with.no.main.folder", function()
    local root = dir()
    local store = dir()
    git(root, "init", "-q", "--separate-git-dir", store .. "/store", root)
    local out, code = follow(root)
    testing.eq(code, 1, out)
    testing.ok(out:find("The git repository at " .. root .. " has no main checkout.", 1, true), out)
    cleanup(root, store)
end)

testing.test("follow.project.script.replaces.the.built.in", function()
    local root = support.sandbox({
        [".dev/follow.sh"] = "#!/bin/sh\necho mine\n",
    }, {})
    assert(dev_os.run({ "chmod", "755", root .. "/.dev/follow.sh" }) == 0, "chmod failed")
    local out, code = follow(root)
    testing.eq(code, 0, out)
    testing.eq(out, "mine\n")
    cleanup(root)
end)
