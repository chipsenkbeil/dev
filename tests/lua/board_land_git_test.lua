local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local land = require("dev.board.land")
local support = require("support")
local templates = require("dev.templates")

local MODULE = "dotfiles/bin/.local/share/dev/lua/dev/fs.lua"

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
    local code = dev_os.run(argv, { stdout = "null", stderr = "null" })
    assert(code == 0, "git failed: " .. table.concat({ ... }, " "))
end

local function head(root)
    local out = dev_os.capture({ "git", "-C", root, "rev-parse", "HEAD" })
    return (out:gsub("\n$", ""))
end

local function write(root, path, text)
    local dir = (root .. "/" .. path):match("^(.*)/[^/]+$")
    assert(fs.mkdir(dir, { parents = true }), "mkdir failed")
    assert(fs.write(root .. "/" .. path, text), "write failed")
end

local function repo(files)
    local root = assert(fs.realpath(support.tempdir()))
    local code = dev_os.run({ "git", "init", "-q", "-b", "main", root }, { stdout = "null" })
    assert(code == 0, "git init failed")
    for path, text in pairs(files) do
        write(root, path, text)
    end
    write(root, "base.txt", "base\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "base")
    return root
end

local function review_of(kind, commit)
    return { body = "dev-review: kind=" .. kind .. " by=r commit=" .. commit .. " change=-" }
end

testing.test("git state refuses an empty or undescribed commit", function()
    local root = repo({})
    git(root, "commit", "-q", "--allow-empty", "-m", "empty one")
    local state, message = land.state(root)
    testing.eq(state, nil)
    testing.ok(message:find("is empty", 1, true), message)
    write(root, "f.txt", "f\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "--allow-empty-message", "-m", "")
    state, message = land.state(root)
    testing.eq(state, nil)
    testing.ok(message:find("no description", 1, true), message)
    git(root, "commit", "-q", "--amend", "-m", "feat: f")
    state = assert(land.state(root))
    testing.eq(state.commit, head(root))
end)

testing.test("git added and touched list renames at the new path", function()
    local lines = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n"
    local root = repo({ ["a.txt"] = "a\n", ["b.txt"] = lines, ["c.txt"] = "c\n" })
    git(root, "mv", "b.txt", "d.txt")
    git(root, "rm", "-q", "c.txt")
    write(root, "a.txt", "a2\n")
    write(root, "e.txt", "e\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: change")
    local commit = head(root)
    testing.eq(land.added(root, commit), { "d.txt", "e.txt" })
    testing.eq(land.touched(root, commit), { "a.txt", "c.txt", "d.txt", "e.txt" })
    git(root, "checkout", "-q", "-b", "side", "HEAD~1")
    write(root, "s.txt", "s\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "side")
    git(root, "checkout", "-q", "main")
    git(root, "merge", "-q", "--no-ff", "-m", "merge", "side")
    local merged = assert(land.touched(root, head(root)))
    testing.eq(merged, { "a.txt", "c.txt", "d.txt", "e.txt", "s.txt" })
end)

testing.test("git worktree guard refuses a worktree that is not the card", function()
    local root = repo({})
    testing.eq(land.workspace_problem(root, "abc12345"), nil)
    local base = assert(fs.realpath(support.tempdir()))
    git(root, "worktree", "add", "-q", "-b", "other", base .. "/other")
    local problem = land.workspace_problem(base .. "/other", "abc12345")
    testing.ok(problem and problem:find("other", 1, true), tostring(problem))
    testing.ok(problem:find("dev ws new abc12345", 1, true), problem)
    git(root, "worktree", "add", "-q", "-b", "abc12345", base .. "/card")
    testing.eq(land.workspace_problem(base .. "/card", "abc12345"), nil)
    git(root, "worktree", "add", "-q", "--detach", base .. "/loose")
    problem = land.workspace_problem(base .. "/loose", "abc12345")
    testing.ok(problem and problem:find("detached", 1, true), tostring(problem))
end)

testing.test("git reviews carry across an unchanged patch", function()
    local numbers = {}
    for i = 1, 30 do
        numbers[i] = "line " .. i
    end
    local body = table.concat(numbers, "\n") .. "\n"
    local root = repo({ ["f.txt"] = body })
    git(root, "checkout", "-q", "-b", "work")
    write(root, "f.txt", (body:gsub("line 15\n", "line fifteen\n")))
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: f")
    local first = head(root)
    git(root, "checkout", "-q", "main")
    write(root, "f.txt", "top\nmore\nlines\n" .. body)
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "trunk moves")
    git(root, "checkout", "-q", "-b", "moved")
    git(root, "cherry-pick", first)
    local state = { commit = head(root), change = "-" }
    local comments = { review_of("code", first), review_of("style", first) }
    testing.eq(land.missing_reviews(comments, state, root), {})
    testing.eq(land.refused_reviews(comments, state, root), {})
    write(root, "f.txt", "top\nmore\nlines\nchanged\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "--amend", "-m", "feat: f")
    state = { commit = head(root), change = "-" }
    testing.eq(#land.missing_reviews(comments, state, root), 2)
end)

testing.test("git reviews do not carry across an edit moved to repeated text", function()
    local half = "1\n2\n3\n4\n5\n6\n7\n"
    local root = repo({ ["f.txt"] = half .. half })
    git(root, "checkout", "-q", "-b", "first")
    write(root, "f.txt", "1\n2\n3\n4\n5\nX\n6\n7\n" .. half)
    git(root, "commit", "-q", "-a", "-m", "feat: first")
    local reviewed = head(root)
    git(root, "checkout", "-q", "main")
    git(root, "checkout", "-q", "-b", "second")
    write(root, "f.txt", half .. "1\n2\n3\n4\n5\nX\n6\n7\n")
    git(root, "commit", "-q", "-a", "-m", "feat: second")
    local state = { commit = head(root), change = "-" }
    local comments = { review_of("code", reviewed), review_of("style", reviewed) }
    testing.eq(#land.missing_reviews(comments, state, root), 2)
end)

testing.test("git template problem reads the template listing", function()
    local root = repo({})
    write(root, templates.BASE .. "/lint.lua", 'local fs = require("dev.fs")\n')
    write(root, MODULE, "return {}\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: template")
    local touched = assert(land.touched(root, head(root)))
    local problem = land.template_problem(root, touched)
    testing.ok(problem and problem:find(MODULE, 1, true), tostring(problem))
end)
