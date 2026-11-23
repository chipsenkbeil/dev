local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local IDENT = { JJ_CONFIG = "/dev/null", JJ_USER = "t", JJ_EMAIL = "t@t" }
local has_jj = dev_os.which("jj") ~= nil
local today = os.date("%Y-%m-%d")

local function dir()
    return assert(fs.realpath(support.tempdir()))
end

local function bare()
    local remote = dir()
    support.git(remote, "init", "-q", "--bare")
    return remote
end

local function commit(root, file, message)
    assert(fs.write(root .. "/" .. file, message .. "\n"))
    support.git(root, "add", file)
    support.git(root, "commit", "-q", "-m", message)
end

local function repo(remotes)
    local root = dir()
    support.git(root, "init", "-q", "-b", "master")
    for name, remote in pairs(remotes) do
        support.git(root, "remote", "add", name, remote)
    end
    commit(root, "a", "one")
    support.git(root, "push", "-q", "origin", "master")
    return root
end

local function cleanup(...)
    for _, path in ipairs({ ... }) do
        fs.remove(path, { recursive = true })
    end
end

local function branch(root, verb, ...)
    return support.dev(root, { "branch", verb, ... }, { env = IDENT })
end

local function refs(remote, prefix)
    return dev_os.capture({ "git", "-C", remote, "for-each-ref", "--format=%(refname)", prefix })
end

testing.test("branch.ls.marks.a.rebased.branch.as.landed", function()
    local origin = bare()
    local root = repo({ origin = origin })
    support.git(root, "checkout", "-q", "-b", "feature")
    commit(root, "f", "feature work")
    support.git(root, "checkout", "-q", "-b", "wip", "master")
    commit(root, "w", "wip work")
    support.git(root, "checkout", "-q", "master")
    commit(root, "g", "other")
    support.git(root, "cherry-pick", "feature")
    support.git(root, "push", "-q", "origin", "master")
    local out, code = branch(root, "ls")
    testing.eq(code, 0, out)
    testing.eq(out:find("feature%s+landed") ~= nil, true, out)
    testing.eq(out:find("wip%s+unlanded") ~= nil, true, out)
    testing.eq(out:find("master%s+landed") ~= nil, true, out)
    cleanup(root, origin)
end)

if has_jj then
    local function jj(root, ...)
        local out, code = dev_os.capture(
            { "jj", "--no-pager", "-R", root, ... },
            { stderr = "stdout", env = IDENT }
        )
        assert(code == 0, out)
        return (out:gsub("\n$", ""))
    end

    local function jj_repo(origin)
        local root = dir()
        local made = dev_os.capture(
            { "jj", "git", "init", root },
            { stderr = "stdout", env = IDENT }
        )
        assert(fs.exists(root .. "/.jj"), made)
        jj(root, "git", "remote", "add", "origin", origin)
        assert(fs.write(root .. "/a", "one\n"))
        jj(root, "commit", "-m", "one")
        jj(root, "bookmark", "create", "master", "-r", "@-")
        jj(root, "new", "master", "-m", "wip work")
        assert(fs.write(root .. "/w", "wip\n"))
        jj(root, "new", "master")
        return root
    end

    local function wip_head(root)
        return jj(
            root,
            "log",
            "--no-graph",
            "-r",
            'description(substring:"wip work")',
            "-T",
            "change_id.short(12)"
        )
    end

    testing.test("branch.ls.lists.an.unlanded.anonymous.jj.head", function()
        local origin = bare()
        local root = jj_repo(origin)
        local out, code = branch(root, "ls")
        testing.eq(code, 0, out)
        testing.eq(out:find("anonymous\n", 1, true) ~= nil, true, out)
        testing.eq(out:find(wip_head(root) .. "%s+unlanded%s+wip work") ~= nil, true, out)
        cleanup(root, origin)
    end)

    testing.test("branch.archive.names.a.change.id.in.jj", function()
        local origin = bare()
        local root = jj_repo(origin)
        local change = wip_head(root)
        local out, code = branch(root, "archive", change)
        testing.eq(code, 0, out)
        testing.eq(refs(origin, "refs/archive"), "refs/archive/" .. today .. "/" .. change .. "\n")
        jj(root, "describe", "-r", change, "-m", "still mutable")
        cleanup(root, origin)
    end)

    testing.test("branch.prune.deletes.a.pushed.jj.bookmark", function()
        local origin = bare()
        local root = jj_repo(origin)
        jj(root, "bookmark", "create", "topic", "-r", "master")
        jj(root, "git", "push", "--remote", "origin", "--bookmark", "topic")
        local out, code = branch(root, "prune", "topic")
        testing.eq(code, 0, out)
        testing.eq(refs(origin, "refs/heads"), "")
        testing.eq(jj(root, "bookmark", "list"):find("topic", 1, true), nil)
        cleanup(root, origin)
    end)
end

testing.test("branch.archive.pushes.to.every.remote.and.confirms", function()
    local origin, backup = bare(), bare()
    local root = repo({ origin = origin, backup = backup })
    support.git(root, "checkout", "-q", "-b", "topic")
    commit(root, "t", "topic work")
    local out, code = branch(root, "archive", "topic")
    testing.eq(code, 0, out)
    local want = "refs/archive/" .. today .. "/topic\n"
    testing.eq(refs(origin, "refs/archive"), want)
    testing.eq(refs(backup, "refs/archive"), want)
    support.git(root, "remote", "set-url", "backup", backup .. "/missing")
    local again, again_code = branch(root, "archive", "topic")
    testing.eq(again_code, 1, again)
    testing.eq(
        again:find("The remote backup lacks " .. want:sub(1, -2), 1, true) ~= nil,
        true,
        again
    )
    cleanup(root, origin, backup)
end)

testing.test("branch.prune.refuses.an.unlanded.unarchived.branch", function()
    local origin = bare()
    local root = repo({ origin = origin })
    support.git(root, "checkout", "-q", "-b", "wip")
    commit(root, "w", "wip work")
    support.git(root, "push", "-q", "origin", "wip")
    support.git(root, "checkout", "-q", "master")
    local out, code = branch(root, "prune", "wip")
    testing.eq(code, 1, out)
    testing.eq(out:find("neither landed by content nor archived", 1, true) ~= nil, true, out)
    testing.eq(refs(origin, "refs/heads"), "refs/heads/master\nrefs/heads/wip\n")
    testing.eq(refs(root, "refs/heads"), "refs/heads/master\nrefs/heads/wip\n")
    local archived, archived_code = branch(root, "archive", "wip")
    testing.eq(archived_code, 0, archived)
    local pruned, pruned_code = branch(root, "prune", "wip")
    testing.eq(pruned_code, 0, pruned)
    testing.eq(refs(origin, "refs/heads"), "refs/heads/master\n")
    cleanup(root, origin)
end)

testing.test("branch.prune.deletes.a.landed.branch", function()
    local origin = bare()
    local root = repo({ origin = origin })
    support.git(root, "checkout", "-q", "-b", "feature")
    commit(root, "f", "feature work")
    support.git(root, "push", "-q", "origin", "feature")
    support.git(root, "checkout", "-q", "master")
    commit(root, "g", "other")
    support.git(root, "cherry-pick", "feature")
    support.git(root, "push", "-q", "origin", "master")
    local out, code = branch(root, "prune", "feature")
    testing.eq(code, 0, out)
    testing.eq(refs(origin, "refs/heads"), "refs/heads/master\n")
    testing.eq(refs(root, "refs/heads"), "refs/heads/master\n")
    local trunk, trunk_code = branch(root, "prune", "master")
    testing.eq(trunk_code, 1, trunk)
    cleanup(root, origin)
end)

testing.test("branch.prune.refuses.a.remote.branch.that.moved.since.the.last.fetch", function()
    local origin = bare()
    local root = repo({ origin = origin })
    support.git(root, "checkout", "-q", "-b", "feature")
    commit(root, "f", "feature work")
    support.git(root, "push", "-q", "origin", "feature")
    support.git(root, "checkout", "-q", "master")
    support.git(root, "cherry-pick", "feature")
    support.git(root, "push", "-q", "origin", "master")
    local other = dir()
    support.git(other, "clone", "-q", origin, other .. "/clone")
    support.git(other .. "/clone", "checkout", "-q", "feature")
    commit(other .. "/clone", "x", "newer work")
    support.git(other .. "/clone", "push", "-q", "origin", "feature")
    local out, code = branch(root, "prune", "feature")
    testing.eq(code, 1, out)
    testing.eq(out:find("moved since the last fetch", 1, true) ~= nil, true, out)
    testing.eq(refs(origin, "refs/heads"), "refs/heads/feature\nrefs/heads/master\n")
    cleanup(root, origin, other)
end)

testing.test("branch.ls.marks.a.branch.with.a.merge.commit.as.unlanded", function()
    local origin = bare()
    local root = repo({ origin = origin })
    support.git(root, "checkout", "-q", "-b", "side")
    commit(root, "s", "side work")
    support.git(root, "checkout", "-q", "-b", "merged", "master")
    commit(root, "m", "main work")
    support.git(root, "merge", "-q", "--no-ff", "-m", "merge side", "side")
    support.git(root, "checkout", "-q", "master")
    support.git(root, "cherry-pick", "side", "merged^")
    support.git(root, "push", "-q", "origin", "master")
    local out, code = branch(root, "ls")
    testing.eq(code, 0, out)
    testing.eq(out:find("side%s+landed") ~= nil, true, out)
    testing.eq(out:find("merged%s+unlanded") ~= nil, true, out)
    cleanup(root, origin)
end)
