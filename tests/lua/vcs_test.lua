local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")
local vcs = require("dev.vcs")

local function project(...)
    local root = assert(fs.realpath(support.tempdir()))
    for _, name in ipairs({ ... }) do
        assert(fs.mkdir(root .. "/" .. name))
    end
    return root
end

local function with_jj(opts, body)
    local which = dev_os.which
    dev_os.which = function(tool)
        if tool == "jj" then
            return opts.installed and "/bin/jj" or nil
        end
        return which(tool)
    end
    local ok, err = pcall(body)
    dev_os.which = which
    assert(ok, err)
end

testing.test("a colocated repo without jj uses git", function()
    local root = project(".jj", ".git")
    with_jj({ installed = false }, function()
        testing.eq(vcs.backend(root), vcs.GIT)
        testing.eq(vcs.require(root), vcs.GIT)
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("a colocated repo with jj uses jj", function()
    local root = project(".jj", ".git")
    with_jj({ installed = true }, function()
        testing.eq(vcs.backend(root), vcs.JJ)
        testing.eq(vcs.require(root), vcs.JJ)
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("a jj only repo without jj needs jj", function()
    local root = project(".jj")
    with_jj({ installed = false }, function()
        local backend, err = vcs.require(root)
        testing.eq(backend, nil)
        testing.eq(err, "Tool jj not found. Install it with brew install jj.")
    end)
    fs.remove(root, { recursive = true })
end)

local function run(argv)
    assert(dev_os.run(argv, { stdout = "null", stderr = "null" }) == 0, argv[1] .. " failed")
end

local function git_repo()
    local root = assert(fs.realpath(support.tempdir()))
    run({ "git", "-C", root, "init", "-q", "-b", "master" })
    assert(fs.write(root .. "/a.txt", "a\n"))
    run({ "git", "-C", root, "add", "a.txt" })
    run({
        "git",
        "-C",
        root,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.com",
        "commit",
        "-q",
        "-m",
        "base",
    })
    return root
end

testing.test("vcs.files lists a plain git repo", function()
    local root = git_repo()
    testing.eq(vcs.files(root, vcs.GIT), "a.txt\0")
    fs.remove(root, { recursive = true })
end)

testing.test("vcs.files lists a git worktree", function()
    local root = git_repo()
    local tree = assert(fs.realpath(support.tempdir())) .. "/tree"
    run({ "git", "-C", root, "worktree", "add", "-q", "-b", "card", tree })
    testing.eq(vcs.backend(tree), vcs.GIT)
    testing.eq(vcs.files(tree, vcs.GIT), "a.txt\0")
    fs.remove(root, { recursive = true })
    fs.remove(fs.dirname(tree), { recursive = true })
end)

testing.test("vcs.files lists a colocated repo with git when jj is absent", function()
    local root = git_repo()
    assert(fs.mkdir(root .. "/.jj"))
    with_jj({ installed = false }, function()
        local backend = vcs.require(root)
        testing.eq(backend, vcs.GIT)
        testing.eq(vcs.files(root, backend), "a.txt\0")
    end)
    fs.remove(root, { recursive = true })
end)

testing.test("vcs.files lists a jj repo with jj installed", function()
    if not dev_os.which("jj") then
        print("skip - jj is not installed")
        return
    end
    local root = assert(fs.realpath(support.tempdir()))
    run({ "jj", "git", "init", root })
    assert(fs.write(root .. "/a.txt", "a\n"))
    testing.eq(vcs.require(root), vcs.JJ)
    testing.eq(vcs.files(root, vcs.JJ), "a.txt\0")
    fs.remove(root, { recursive = true })
end)
