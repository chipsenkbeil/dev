local testing = require("dev.testing")
local dev_os = require("dev.os")
local runtime = require("dev.runtime")
local fs = require("dev.fs")
local scm = require("dev.scm")
local support = require("support")

local function git(root, ...)
    local argv = {
        "git",
        "-C",
        root,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.com",
        "-c",
        "commit.gpgsign=false",
        ...,
    }
    assert(dev_os.run(argv, { stdout = "null", stderr = "null" }) == 0, "git failed")
end

local function with_push_env(fn)
    local self = runtime.exe
    local before = dev_os.getenv("DEV_SELF") or ""
    dev_os.setenv("DEV_SELF", self)
    local ok, err = pcall(fn)
    dev_os.setenv("DEV_SELF", before)
    assert(ok, err)
end

local function head(root)
    return (dev_os.capture({ "git", "-C", root, "rev-parse", "HEAD" }):gsub("\n$", ""))
end

local function repo()
    local root = assert(fs.realpath(support.tempdir()))
    assert(
        dev_os.run({ "git", "init", "-q", "-b", "main", root }, { stdout = "null" }) == 0,
        "git init failed"
    )
    assert(fs.write(root .. "/base.txt", "base\n"), "write failed")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "base")
    return root
end

testing.test("scm.workspace.names.the.checkout.after.its.directory", function()
    local root = repo()
    testing.eq(scm.workspace(root):name(), root:match("[^/]+$"))
end)

testing.test("scm.workspace.is.dirty.only.while.the.checkout.holds.changes", function()
    local root = repo()
    local workspace = scm.workspace(root)
    testing.eq(workspace:is_dirty(), false)
    assert(fs.write(root .. "/new.txt", "new\n"), "write failed")
    testing.eq(workspace:is_dirty(), true)
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: new")
    testing.eq(workspace:is_dirty(), false)
end)

if dev_os.which("jj") then
    testing.test(
        "scm.workspace.in.jj.is.dirty.while.the.working.copy.commit.holds.changes",
        function()
            local root = assert(fs.realpath(support.tempdir()))
            local env = { JJ_USER = "t", JJ_EMAIL = "t@example.com" }
            local function jj(...)
                local argv = { "jj", "--no-pager", "-R", root, ... }
                local code = dev_os.run(argv, { stdout = "null", stderr = "null", env = env })
                assert(code == 0, "jj failed")
            end
            local init = { stdout = "null", stderr = "null", env = env }
            assert(dev_os.run({ "jj", "git", "init", root }, init) == 0, "jj init failed")
            local workspace = scm.workspace(root)
            testing.eq(workspace:is_dirty(), false)
            assert(fs.write(root .. "/new.txt", "new\n"), "write failed")
            testing.eq(workspace:is_dirty(), true)
            jj("commit", "-m", "feat: new")
            testing.eq(workspace:is_dirty(), false)
        end
    )
end

testing.test("scm.workspace.lists.the.files.a.commit.touches", function()
    local root = repo()
    assert(fs.write(root .. "/new.txt", "new\n"), "write failed")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: new")
    testing.eq(scm.workspace(root):touched(head(root)), { "new.txt" })
end)

testing.test("scm.workspace.says.which.revision.holds.a.commit", function()
    local root = repo()
    local base = head(root)
    assert(fs.write(root .. "/new.txt", "new\n"), "write failed")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: new")
    local workspace = scm.workspace(root)
    testing.eq(workspace:holds(base, "HEAD"), true)
    testing.eq(workspace:holds(head(root), base), false)
end)

testing.test("scm.workspace.merge.into.trunk.pushes.the.head.commit", function()
    local root = repo()
    local bare = assert(fs.realpath(support.tempdir()))
    local init = { stdout = "null" }
    assert(dev_os.run({ "git", "init", "-q", "--bare", bare }, init) == 0, "git init failed")
    git(root, "remote", "add", "origin", bare)
    git(root, "push", "-q", "origin", "main")
    assert(fs.write(root .. "/new.txt", "new\n"), "write failed")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: new")
    local ok, out
    with_push_env(function()
        ok, out = scm.workspace(root):merge_into_trunk()
    end)
    testing.eq(ok, true, out)
    local remote = dev_os.capture({ "git", "-C", root, "ls-remote", "origin", "refs/heads/main" })
    testing.eq(remote:match("^(%x+)"), head(root))
end)
