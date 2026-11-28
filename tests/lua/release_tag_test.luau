local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local testing = require("@dev/testing")
local toml = require("@dev/toml")
local support = require("./support")

local JJ_IDENT = { JJ_CONFIG = "/dev/null", JJ_USER = "t", JJ_EMAIL = "t@t" }
local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")

local function project()
    -- Copy the tag command into a project
    local files = {}
    for _, name in ipairs({ "DESCRIPTION", "tag.luau" }) do
        local path = ".dev/commands/release/" .. name
        files[path] = assert(fs.read(REPO .. "/" .. path))
    end
    local root = support.sandbox(files, {})

    -- Make a git repository that pushes to a bare remote
    local bare = support.tempdir()
    support.git(bare, "init", "-q", "--bare")
    support.git(root, "init", "-q", "-b", "master")
    support.git(root, "remote", "add", "origin", bare)

    -- Commit twice, tagging the first
    assert(fs.write(root .. "/a.txt", "one\n"))
    support.git(root, "add", "a.txt")
    support.git(root, "commit", "-q", "-m", "feat: one")
    local first = support.rev(root, "HEAD")
    assert(fs.write(root .. "/b.txt", "two\n"))
    support.git(root, "add", "b.txt")
    support.git(root, "commit", "-q", "-m", "feat: two")
    return root, bare, first, support.rev(root, "HEAD")
end

local function tag(root, words, env)
    local argv = { "release", "tag" }
    for _, word in ipairs(words or {}) do
        argv[#argv + 1] = word
    end
    return support.dev(root, argv, { env = env or support.GIT_IDENT })
end

local function remote_tags(bare)
    return dev_os.capture({ "git", "-C", bare, "tag", "--list" })
end

testing.test("tag sets and pushes the next patch on REV and skips a pre-release", function()
    local root, bare, first, second = project()
    support.git(root, "tag", "v0.1.2", first)
    support.git(root, "tag", "v0.1.12", first)
    support.git(root, "tag", "v0.1.13-pre.1", first)
    local out, code = tag(root, { second })
    testing.eq(code, 0, out)
    testing.ok(out:find("v0.1.13", 1, true), out)
    testing.eq(support.rev(root, "v0.1.13^{commit}"), second)
    testing.eq(support.rev(bare, "refs/tags/v0.1.13^{commit}"), second)
    testing.eq(remote_tags(bare), "v0.1.13\n")
end)

testing.test("tag defaults REV to HEAD under git", function()
    local root, bare, first, second = project()
    support.git(root, "tag", "v0.1.2", first)
    local out, code = tag(root)
    testing.eq(code, 0, out)
    testing.eq(support.rev(bare, "refs/tags/v0.1.3^{commit}"), second)
end)

testing.test("tag compares the parts of a version as numbers", function()
    local root, bare, first = project()
    support.git(root, "tag", "v0.1.9", first)
    support.git(root, "tag", "v0.1.10", first)
    support.git(root, "tag", "v0.0.99", first)
    local out, code = tag(root)
    testing.eq(code, 0, out)
    testing.eq(remote_tags(bare), "v0.1.11\n")
end)

testing.test("tag counts from a minor bump set by hand", function()
    local root, bare, first = project()
    support.git(root, "tag", "v0.1.9", first)
    support.git(root, "tag", "v0.2.0", first)
    local out, code = tag(root)
    testing.eq(code, 0, out)
    testing.eq(remote_tags(bare), "v0.2.1\n")
end)

testing.test("tag with no release tag exits 1 naming the first tag and pushes nothing", function()
    local root, bare, first = project()
    support.git(root, "tag", "v0.1.0-pre.1", first)
    support.git(root, "tag", "nightly", first)
    local out, code = tag(root)
    testing.eq(code, 1, out)
    testing.ok(out:find("Set the first one by hand", 1, true), out)
    testing.ok(out:find("git tag v0.1.0 REV", 1, true), out)
    testing.eq(remote_tags(bare), "")
end)

testing.test("tag refuses a revision it cannot find and pushes nothing", function()
    local root, bare, first = project()
    support.git(root, "tag", "v0.1.2", first)
    local out, code = tag(root, { "nosuchrev" })
    testing.eq(code, 1, out)
    testing.ok(out:find("The tag v0.1.3 could not be set on nosuchrev", 1, true), out)
    testing.eq(remote_tags(bare), "")
end)

testing.test("tag removes the local tag when the push fails so a rerun reuses it", function()
    local root, bare, first = project()
    support.git(root, "tag", "v0.1.2", first)
    support.git(root, "remote", "set-url", "origin", bare .. "/missing")
    local out, code = tag(root)
    testing.eq(code, 1, out)
    testing.ok(out:find("The push of v0.1.3 failed and the local tag was removed", 1, true), out)
    testing.eq(dev_os.capture({ "git", "-C", root, "tag", "--list" }), "v0.1.2\n")
end)

testing.test("the release checks end with the tag command", function()
    local config = assert(toml.parse(assert(fs.read(REPO .. "/.dev/config.toml"))))
    local rows = config.board.release.checks
    testing.eq(rows[#rows], "dev release tag")
    testing.eq(rows[1], "dev --remote lint")
    testing.eq(rows[2], "dev --remote test")
end)

if dev_os.which("jj") then
    local function jj_project()
        -- Turn the git project into a jj repository
        local root, bare = project()
        assert(fs.remove(root .. "/.git", { recursive = true }))
        local function jj(...)
            local out, code = dev_os.capture(
                { "jj", "--no-pager", "-R", root, ... },
                { stderr = "stdout", env = JJ_IDENT }
            )
            assert(code == 0, out)
            return (out:gsub("\n$", ""))
        end
        local made = dev_os.capture(
            { "jj", "git", "init", root },
            { stderr = "stdout", env = JJ_IDENT }
        )
        assert(fs.exists(root .. "/.jj"), made)
        jj("git", "remote", "add", "origin", bare)

        -- Describe a change and tag it
        assert(fs.write(root .. "/c.txt", "three\n"))
        jj("describe", "-m", "feat: three")
        jj("bookmark", "create", "master", "-r", "@")
        jj("tag", "set", "v0.1.2", "-r", "@")
        return root, bare, jj, jj("log", "--no-graph", "-r", "@", "-T", "commit_id")
    end

    testing.test("tag sets and pushes the next patch under jj", function()
        local root, bare, _, commit = jj_project()
        local out, code = tag(root, { "@" }, JJ_IDENT)
        testing.eq(code, 0, out)
        testing.eq(support.rev(bare, "refs/tags/v0.1.3^{commit}"), commit)
    end)

    testing.test("tag removes the local tag when the push fails under jj", function()
        local root, bare, jj = jj_project()
        jj("git", "remote", "set-url", "origin", bare .. "/missing")
        local out, code = tag(root, { "@" }, JJ_IDENT)
        testing.eq(code, 1, out)
        testing.ok(
            out:find("The push of v0.1.3 failed and the local tag was removed", 1, true),
            out
        )
        testing.eq(jj("tag", "list", "-T", 'name ++ "\\n"'), "v0.1.2")
    end)
end
