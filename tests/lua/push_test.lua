local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

dev_os.defaults.env = {
    GIT_CONFIG_GLOBAL = "/dev/null",
    GIT_CONFIG_NOSYSTEM = "1",
    JJ_CONFIG = "/dev/null",
}

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local GUARD = REPO .. "/dotfiles/bin/.local/bin/commit-guard"

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

local function guard_config(guard)
    return "[push]\nguard = " .. string.format("%q", guard) .. "\n"
end

testing.test("push.tag.refuses.a.commit.with.an.attribution.line", function()
    local root, remote = fixture()
    git(root, "commit", "-q", "--allow-empty", "-m", "two", "-m", "Co-Authored-By: x <x@y.z>")
    git(root, "tag", "v1")
    support.with_user_config(guard_config(GUARD), function()
        local out, code = support.dev(root, { "push", "--tag", "v1" })
        testing.eq(code, 1, out)
        testing.eq(out:find("commit-guard: refusing to push", 1, true) ~= nil, true, out)
    end)
    testing.eq(git(remote, "tag", "--list"), "")
    cleanup(root, remote)
end)

testing.test("push.runs.without.a.guard.when.push.guard.is.unset", function()
    local root, remote = fixture()
    git(root, "branch", "-M", "main")
    support.with_user_config("", function()
        local out, code = support.dev(root, { "-v", "push" })
        testing.eq(code, 0, out)
        local want = "+ git push -- origin " .. git(root, "rev-parse", "HEAD") .. ":refs/heads/main"
        testing.eq(out:find(want, 1, true) ~= nil, true, out)
        testing.eq(out:find("Pushed main to origin.", 1, true) ~= nil, true, out)
    end)
    testing.eq(git(remote, "rev-parse", "main"), git(root, "rev-parse", "HEAD"))
    cleanup(root, remote)
end)

testing.test("push.stops.when.the.configured.guard.fails", function()
    local root, remote = fixture()
    git(root, "branch", "-M", "main")
    local stub = support.tempdir() .. "/guard"
    assert(fs.write(stub, "#!/bin/sh\necho stopped by the stub >&2\nexit 7\n"))
    assert(dev_os.run({ "chmod", "755", stub }) == 0, "chmod failed")
    support.with_user_config(guard_config(stub), function()
        local out, code = support.dev(root, { "push" })
        testing.eq(code, 1, out)
        testing.eq(out:find("The push of main to origin failed.", 1, true) ~= nil, true, out)
        testing.eq(out:find("stopped by the stub", 1, true) ~= nil, true, out)
    end)
    local _, pushed = dev_os.capture({ "git", "-C", remote, "rev-parse", "-q", "--verify", "main" })
    testing.eq(pushed ~= 0, true)
    cleanup(root, remote)
end)

testing.test("push.refuses.a.guard.setting.that.is.not.a.program", function()
    local root, remote = fixture()
    git(root, "branch", "-M", "main")
    support.with_user_config("[push]\nguard = 3\n", function()
        local out, code = support.dev(root, { "push" })
        testing.eq(code, 1, out)
        local want = "The `push.guard` setting must be a program name or path."
        testing.eq(out:find(want, 1, true) ~= nil, true, out)
    end)
    cleanup(root, remote)
end)

testing.test("push.refuses.a.configured.guard.that.is.not.found", function()
    local root, remote = fixture()
    git(root, "branch", "-M", "main")
    support.with_user_config(guard_config("no-such-guard-program"), function()
        local out, code = support.dev(root, { "push" })
        testing.eq(code, 1, out)
        local want = "The push guard no-such-guard-program from `push.guard` is not an executable."
        testing.eq(out:find(want, 1, true) ~= nil, true, out)
    end)
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

    testing.test("push.tag.refuses.an.attributed.commit.in.a.jj.repo", function()
        local remote, root
        support.with_user_config(guard_config(GUARD), function()
            local out, code
            out, code, remote, root = jj_tag_push("one\n\nCo-Authored-By: x <x@y.z>")
            testing.eq(code, 1, out)
            testing.eq(out:find("commit-guard: refusing to push", 1, true) ~= nil, true, out)
        end)
        testing.eq(git(remote, "tag", "--list"), "")
        cleanup(root, remote)
    end)
end
