local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local support = require("./support")

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
    -- Make a repo that knows each remote
    local root = dir()
    support.git(root, "init", "-q", "-b", "master")
    for name, remote in pairs(remotes) do
        support.git(root, "remote", "add", name, remote)
    end

    -- Push a first commit to the trunk
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
    -- Make a feature branch and a wip branch
    local origin = bare()
    local root = repo({ origin = origin })
    support.git(root, "checkout", "-q", "-b", "feature")
    commit(root, "f", "feature work")
    support.git(root, "checkout", "-q", "-b", "wip", "master")
    commit(root, "w", "wip work")

    -- Land the feature on the trunk by cherry-pick
    support.git(root, "checkout", "-q", "master")
    commit(root, "g", "other")
    support.git(root, "cherry-pick", "feature")
    support.git(root, "push", "-q", "origin", "master")

    -- List the branches
    local out, code = branch(root, "ls")
    testing.eq(code, 0, out)

    -- Mark the feature landed and the wip unlanded
    testing.eq(out:find("feature%s+landed") ~= nil, true, out)
    testing.eq(out:find("wip%s+unlanded") ~= nil, true, out)
    testing.eq(out:find("master%s+landed") ~= nil, true, out)

    -- Remove the repos
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
        -- Make a jj repo that knows the remote
        local root = dir()
        local made = dev_os.capture(
            { "jj", "git", "init", root },
            { stderr = "stdout", env = IDENT }
        )
        assert(fs.exists(root .. "/.jj"), made)
        jj(root, "git", "remote", "add", "origin", origin)

        -- Commit the trunk
        assert(fs.write(root .. "/a", "one\n"))
        jj(root, "commit", "-m", "one")
        jj(root, "bookmark", "create", "master", "-r", "@-")

        -- Leave a wip change off the trunk
        jj(root, "new", "master", "-m", "wip work")
        assert(fs.write(root .. "/w", "wip\n"))

        -- Start an empty change on the trunk
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
        -- List the branches of a jj repo with a wip head
        local origin = bare()
        local root = jj_repo(origin)
        local out, code = branch(root, "ls")
        testing.eq(code, 0, out)

        -- Show the head as anonymous and unlanded
        testing.eq(out:find("anonymous\n", 1, true) ~= nil, true, out)
        testing.eq(out:find(wip_head(root) .. "%s+unlanded%s+wip work") ~= nil, true, out)

        -- Remove the repos
        cleanup(root, origin)
    end)

    testing.test("branch.archive.names.a.change.id.in.jj", function()
        -- Archive the wip change by its change id
        local origin = bare()
        local root = jj_repo(origin)
        local change = wip_head(root)
        local out, code = branch(root, "archive", change)
        testing.eq(code, 0, out)

        -- Name the archive ref after the change id
        testing.eq(refs(origin, "refs/archive"), "refs/archive/" .. today .. "/" .. change .. "\n")

        -- Keep the change mutable
        jj(root, "describe", "-r", change, "-m", "still mutable")

        -- Remove the repos
        cleanup(root, origin)
    end)

    testing.test("branch.prune.deletes.a.pushed.jj.bookmark", function()
        -- Push a bookmark that sits on the trunk
        local origin = bare()
        local root = jj_repo(origin)
        jj(root, "bookmark", "create", "topic", "-r", "master")
        jj(root, "git", "push", "--remote", "origin", "--bookmark", "topic")

        -- Prune the bookmark
        local out, code = branch(root, "prune", "topic")
        testing.eq(code, 0, out)

        -- Delete it on the remote and locally
        testing.eq(refs(origin, "refs/heads"), "")
        testing.eq(jj(root, "bookmark", "list"):find("topic", 1, true), nil)

        -- Remove the repos
        cleanup(root, origin)
    end)
end

testing.test("branch.archive.pushes.to.every.remote.and.confirms", function()
    -- Make a topic branch in a repo with two remotes
    local origin, backup = bare(), bare()
    local root = repo({ origin = origin, backup = backup })
    support.git(root, "checkout", "-q", "-b", "topic")
    commit(root, "t", "topic work")

    -- Archive the branch to both remotes
    local out, code = branch(root, "archive", "topic")
    testing.eq(code, 0, out)
    local want = "refs/archive/" .. today .. "/topic\n"
    testing.eq(refs(origin, "refs/archive"), want)
    testing.eq(refs(backup, "refs/archive"), want)

    -- Break one remote and archive again
    support.git(root, "remote", "set-url", "backup", backup .. "/missing")
    local again, again_code = branch(root, "archive", "topic")

    -- Fail and name the remote that lacks the ref
    testing.eq(again_code, 1, again)
    testing.eq(
        again:find("The remote backup lacks " .. want:sub(1, -2), 1, true) ~= nil,
        true,
        again
    )

    -- Remove the repos
    cleanup(root, origin, backup)
end)

testing.test("branch.archive.to.pushes.only.the.named.remote", function()
    -- Make a topic branch in a repo with two remotes
    local origin, backup = bare(), bare()
    local root = repo({ origin = origin, backup = backup })
    support.git(root, "checkout", "-q", "-b", "topic")
    commit(root, "t", "topic work")

    -- Archive the branch to one remote
    local out, code = branch(root, "archive", "topic", "--to", "backup")
    testing.eq(code, 0, out)

    -- Leave the other remote without the ref
    testing.eq(refs(backup, "refs/archive"), "refs/archive/" .. today .. "/topic\n")
    testing.eq(refs(origin, "refs/archive"), "")

    -- Remove the repos
    cleanup(root, origin, backup)
end)

testing.test("branch.archive.to.refuses.an.unknown.remote", function()
    -- Make a topic branch in a repo with one remote
    local origin = bare()
    local root = repo({ origin = origin })
    support.git(root, "checkout", "-q", "-b", "topic")
    commit(root, "t", "topic work")

    -- Archive the branch to a remote that does not exist
    local out, code = branch(root, "archive", "topic", "--to", "nowhere")

    -- Refuse and name the remote
    testing.eq(code, 1, out)
    testing.eq(out:find("There is no remote nowhere to archive to.", 1, true) ~= nil, true, out)
    testing.eq(refs(origin, "refs/archive"), "")

    -- Remove the repos
    cleanup(root, origin)
end)

testing.test("branch.prune.refuses.an.unlanded.unarchived.branch", function()
    -- Push a wip branch that never landed
    local origin = bare()
    local root = repo({ origin = origin })
    support.git(root, "checkout", "-q", "-b", "wip")
    commit(root, "w", "wip work")
    support.git(root, "push", "-q", "origin", "wip")
    support.git(root, "checkout", "-q", "master")

    -- Refuse to prune it and keep it everywhere
    local out, code = branch(root, "prune", "wip")
    testing.eq(code, 1, out)
    testing.eq(out:find("neither landed by content nor archived", 1, true) ~= nil, true, out)
    testing.eq(refs(origin, "refs/heads"), "refs/heads/master\nrefs/heads/wip\n")
    testing.eq(refs(root, "refs/heads"), "refs/heads/master\nrefs/heads/wip\n")

    -- Archive it, then prune it
    local archived, archived_code = branch(root, "archive", "wip")
    testing.eq(archived_code, 0, archived)
    local pruned, pruned_code = branch(root, "prune", "wip")
    testing.eq(pruned_code, 0, pruned)
    testing.eq(refs(origin, "refs/heads"), "refs/heads/master\n")

    -- Remove the repos
    cleanup(root, origin)
end)

testing.test("branch.prune.deletes.a.landed.branch", function()
    -- Push a feature branch and land it on the trunk by cherry-pick
    local origin = bare()
    local root = repo({ origin = origin })
    support.git(root, "checkout", "-q", "-b", "feature")
    commit(root, "f", "feature work")
    support.git(root, "push", "-q", "origin", "feature")
    support.git(root, "checkout", "-q", "master")
    commit(root, "g", "other")
    support.git(root, "cherry-pick", "feature")
    support.git(root, "push", "-q", "origin", "master")

    -- Prune the landed branch everywhere
    local out, code = branch(root, "prune", "feature")
    testing.eq(code, 0, out)
    testing.eq(refs(origin, "refs/heads"), "refs/heads/master\n")
    testing.eq(refs(root, "refs/heads"), "refs/heads/master\n")

    -- Refuse to prune the trunk
    local trunk, trunk_code = branch(root, "prune", "master")
    testing.eq(trunk_code, 1, trunk)

    -- Remove the repos
    cleanup(root, origin)
end)

testing.test("branch prune shows only the command text when the local delete fails", function()
    local origin = bare()
    local root = repo({ origin = origin })
    support.git(root, "checkout", "-q", "-b", "feature")
    commit(root, "f", "feature work")
    support.git(root, "push", "-q", "origin", "feature")
    support.git(root, "checkout", "-q", "master")
    commit(root, "g", "other")
    support.git(root, "cherry-pick", "feature")
    support.git(root, "push", "-q", "origin", "master")
    support.git(root, "checkout", "-q", "feature")
    local out, code = branch(root, "prune", "feature")
    testing.eq(code, 1, out)
    local failure = out:match("The delete of local feature failed%.\n(.*)$")
    testing.eq(failure ~= nil, true, out)
    testing.eq(failure:find("^    [^\n]*feature") ~= nil, true, out)
    testing.eq(failure:find("There is no such branch", 1, true), nil, out)
    cleanup(root, origin)
end)

testing.test("branch.prune.refuses.a.remote.branch.that.moved.since.the.last.fetch", function()
    -- Push a feature branch and land it on the trunk by cherry-pick
    local origin = bare()
    local root = repo({ origin = origin })
    support.git(root, "checkout", "-q", "-b", "feature")
    commit(root, "f", "feature work")
    support.git(root, "push", "-q", "origin", "feature")
    support.git(root, "checkout", "-q", "master")
    support.git(root, "cherry-pick", "feature")
    support.git(root, "push", "-q", "origin", "master")

    -- Move the remote branch from a second clone
    local other = dir()
    support.git(other, "clone", "-q", origin, other .. "/clone")
    support.git(other .. "/clone", "checkout", "-q", "feature")
    commit(other .. "/clone", "x", "newer work")
    support.git(other .. "/clone", "push", "-q", "origin", "feature")

    -- Refuse to prune the moved branch and keep it
    local out, code = branch(root, "prune", "feature")
    testing.eq(code, 1, out)
    testing.eq(out:find("moved since the last fetch", 1, true) ~= nil, true, out)
    testing.eq(refs(origin, "refs/heads"), "refs/heads/feature\nrefs/heads/master\n")

    -- Remove the repos
    cleanup(root, origin, other)
end)

testing.test("branch.ls.marks.a.branch.with.a.merge.commit.as.unlanded", function()
    -- Make a side branch and a branch that merges it
    local origin = bare()
    local root = repo({ origin = origin })
    support.git(root, "checkout", "-q", "-b", "side")
    commit(root, "s", "side work")
    support.git(root, "checkout", "-q", "-b", "merged", "master")
    commit(root, "m", "main work")
    support.git(root, "merge", "-q", "--no-ff", "-m", "merge side", "side")

    -- Land the commits on the trunk by cherry-pick, not the merge
    support.git(root, "checkout", "-q", "master")
    support.git(root, "cherry-pick", "side", "merged^")
    support.git(root, "push", "-q", "origin", "master")

    -- List the branches
    local out, code = branch(root, "ls")
    testing.eq(code, 0, out)

    -- Mark the side branch landed and the merge unlanded
    testing.eq(out:find("side%s+landed") ~= nil, true, out)
    testing.eq(out:find("merged%s+unlanded") ~= nil, true, out)

    -- Remove the repos
    cleanup(root, origin)
end)
