local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local push = require("@dev/cmd/push")
local support = require("./support")

dev_os.defaults.env = {
    GIT_CONFIG_GLOBAL = "/dev/null",
    GIT_CONFIG_NOSYSTEM = "1",
    JJ_CONFIG = "/dev/null",
}

local function git(root, ...)
    local out, code = dev_os.capture(
        { "git", "-C", root, "-c", "user.name=t", "-c", "user.email=t@t", ... },
        {
            stderr = "stdout",
        }
    )
    assert(code == 0, out)
    return (out:gsub("\n$", ""))
end

local function fixture()
    local remote = assert(fs.realpath(support.tempdir()))
    git(remote, "init", "-q", "--bare")
    local root = assert(fs.realpath(support.tempdir()))
    git(root, "init", "-q")
    git(root, "remote", "add", "origin", remote)
    git(root, "commit", "-q", "--allow-empty", "-m", "one")
    return root, remote
end

local function cleanup(root, remote)
    fs.remove(root, { recursive = true })
    fs.remove(remote, { recursive = true })
end

testing.test("push.commands.names.a.stray.folder", function()
    local root = assert(fs.realpath(support.tempdir()))
    testing.eq(push.commands(root), { "Neither .jj nor .git found in " .. root .. "." })
    fs.remove(root, { recursive = true })
end)

testing.test("push.commands names a missing jj", function()
    local root = assert(fs.realpath(support.tempdir()))
    assert(fs.mkdir(root .. "/.jj"))
    local which = dev_os.which
    dev_os.which = function(tool)
        if tool == "jj" then
            return nil
        end
        return which(tool)
    end
    local ok, err = pcall(function()
        testing.eq(
            push.commands(root),
            { "The tool jj was not found. Install it with `brew install jj`." }
        )
    end)
    dev_os.which = which
    fs.remove(root, { recursive = true })
    assert(ok, err)
end)

testing.test("push refuses a detached head with two sentences", function()
    local root, remote = fixture()
    git(root, "checkout", "-q", "--detach")
    local message = `HEAD is detached in {root}. A push needs a branch.`
    testing.eq(push.commands(root), { message })
    local out, code = support.dev(root, { "push" })
    testing.eq(code, 1)
    testing.eq(out:find(message, 1, true) ~= nil, true, out)
    cleanup(root, remote)
end)

testing.test("push refuses a repo with no remote in a sentence", function()
    local root = assert(fs.realpath(support.tempdir()))
    git(root, "init", "-q")
    git(root, "commit", "-q", "--allow-empty", "-m", "one")
    testing.eq(push.commands(root), { "No origin or gerrit remote." })
    local out, code = support.dev(root, { "push" })
    testing.eq(code, 1)
    testing.eq(out:find("No origin or gerrit remote.", 1, true) ~= nil, true, out)
    fs.remove(root, { recursive = true })
end)

testing.test("push refuses a jj repo with no trunk bookmark in a sentence", function()
    local root = assert(fs.realpath(support.tempdir()))
    local out, code = dev_os.capture({ "jj", "--no-pager", "git", "init", root }, {
        stderr = "stdout",
    })
    assert(code == 0, out)
    local message = `No master or main bookmark in {root}.`
    testing.eq(push.commands(root), { message })
    local shown, status = support.dev(root, { "push" })
    testing.eq(status, 1)
    testing.eq(shown:find(message, 1, true) ~= nil, true, shown)
    fs.remove(root, { recursive = true })
end)

testing.test("push.tag.sends.each.tag.to.the.remote.of.record", function()
    local root, remote = fixture()
    git(root, "tag", "v1")
    git(root, "tag", "-a", "-m", "batch", "batch-1")
    local out, code = support.dev(root, { "push", "--tag", "v1", "--tag", "batch-1" })
    testing.eq(code, 0, out)
    testing.eq(out:find("Pushed tags v1 batch-1 to origin.", 1, true) ~= nil, true, out)
    local head = git(root, "rev-parse", "HEAD")
    testing.eq(git(remote, "rev-parse", "refs/tags/v1^{commit}"), head)
    testing.eq(git(remote, "rev-parse", "refs/tags/batch-1^{commit}"), head)
    local again, again_code = support.dev(root, { "push", "--tag", "v1", "--tag", "batch-1" })
    testing.eq(again_code, 0, again)
    testing.eq(again:find("Tag v1 is already on origin.", 1, true) ~= nil, true, again)
    testing.eq(again:find("Pushed tags", 1, true), nil, again)
    cleanup(root, remote)
end)

testing.test("push.tag.folds.a.repeated.tag.into.one.push", function()
    local root, remote = fixture()
    git(root, "tag", "v1")
    local out, code = support.dev(root, { "push", "--tag", "v1", "--tag", "v1" })
    testing.eq(code, 0, out)
    testing.eq(out:find("Pushed tags v1 to origin.", 1, true) ~= nil, true, out)
    testing.eq(git(remote, "rev-parse", "refs/tags/v1^{commit}"), git(root, "rev-parse", "HEAD"))
    cleanup(root, remote)
end)

testing.test("push.tag.refuses.a.missing.local.tag", function()
    local root, remote = fixture()
    git(root, "tag", "v1")
    local out, code = support.dev(root, { "push", "--tag", "v1", "--tag", "nosuch" })
    testing.eq(code, 1)
    local want = "There is no local tag nosuch. No tag was pushed."
    testing.eq(out:find(want, 1, true) ~= nil, true, out)
    testing.eq(git(remote, "tag", "--list"), "")
    cleanup(root, remote)
end)

testing.test("push.tag.refuses.a.tag.the.remote.holds.at.another.commit", function()
    local root, remote = fixture()
    git(root, "tag", "v1")
    local first = git(root, "rev-parse", "HEAD")
    local _, pushed = support.dev(root, { "push", "--tag", "v1" })
    testing.eq(pushed, 0)
    git(root, "commit", "-q", "--allow-empty", "-m", "two")
    git(root, "tag", "-f", "v1")
    git(root, "tag", "v2")
    local out, code = support.dev(root, { "push", "--tag", "v2", "--tag", "v1" })
    testing.eq(code, 1)
    testing.eq(out:find("origin holds tag v1 at " .. first, 1, true) ~= nil, true, out)
    testing.eq(git(remote, "rev-parse", "refs/tags/v1^{commit}"), first)
    testing.eq(git(remote, "tag", "--list", "v2"), "")
    cleanup(root, remote)
end)

testing.test("push.tag.works.on.a.detached.head", function()
    local root, remote = fixture()
    git(root, "tag", "v1")
    git(root, "checkout", "-q", "--detach")
    local out, code = support.dev(root, { "push", "--tag", "v1" })
    testing.eq(code, 0, out)
    testing.eq(git(remote, "rev-parse", "refs/tags/v1^{commit}"), git(root, "rev-parse", "HEAD"))
    cleanup(root, remote)
end)

local function jj_tag_push(message)
    local remote = assert(fs.realpath(support.tempdir()))
    git(remote, "init", "-q", "--bare")
    local root = assert(fs.realpath(support.tempdir()))
    local function jj(...)
        local out, code = dev_os.capture({ "jj", "--no-pager", "-R", root, ... }, {
            stderr = "stdout",
            env = { JJ_CONFIG = "/dev/null" },
        })
        assert(code == 0, out)
        return (out:gsub("\n$", ""))
    end
    local made = dev_os.run({ "jj", "git", "init", root }, {
        stdout = "null",
        stderr = "null",
        env = { JJ_CONFIG = "/dev/null" },
    })
    testing.eq(made, 0)
    jj("git", "remote", "add", "origin", remote)
    jj("--config", "user.name=t", "--config", "user.email=t@t", "commit", "-m", message)
    local sha = jj("log", "--no-graph", "-r", "@-", "-T", "commit_id")
    local _, tagged = dev_os.capture({ "git", "--git-dir=" .. jj("git", "root"), "tag", "v1", sha })
    testing.eq(tagged, 0)
    local out, code = support.dev(root, { "push", "--tag", "v1" })
    return out, code, remote, root, sha
end

if dev_os.which("jj") then
    testing.test("push.tag.works.in.a.jj.repo", function()
        local out, code, remote, root, sha = jj_tag_push("one")
        testing.eq(code, 0, out)
        testing.eq(git(remote, "rev-parse", "refs/tags/v1^{commit}"), sha)
        cleanup(root, remote)
    end)
end
