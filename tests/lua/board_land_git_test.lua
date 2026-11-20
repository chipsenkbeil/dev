local ffi = require("ffi")

local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local check = require("dev.board.check")
local land = require("dev.board.land")
local support = require("support")
local templates = require("dev.templates")
local vcs = require("dev.vcs")

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
    numbers[#numbers + 1] = ""
    local body = table.concat(numbers, "\n")
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
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: template")
    local touched = assert(land.touched(root, head(root)))
    local problem = land.template_problem(root, touched)
    testing.ok(problem and problem:find("calls dev.fs", 1, true), tostring(problem))
end)

local NUMBERED = {}
for i = 1, 30 do
    NUMBERED[i] = "line " .. i
end
NUMBERED[#NUMBERED + 1] = ""
local BODY = table.concat(NUMBERED, "\n")

local function with_origin(files)
    local root = repo(files)
    local bare = assert(fs.realpath(support.tempdir()))
    local code = dev_os.run({ "git", "init", "-q", "--bare", bare }, { stdout = "null" })
    assert(code == 0, "git init failed")
    git(root, "remote", "add", "origin", bare)
    git(root, "push", "-q", "origin", "main")
    return root
end

local function checked_record(commit)
    local rows = { { result = check.Result.PASS, run_id = "-", run = "dev lint" } }
    return { body = check.record({ commit = commit, change = "-" }, rows, false) }
end

local function carry_opts(root, checked)
    return {
        root = root,
        comments = {
            checked_record(checked),
            review_of("code", checked),
            review_of("style", checked),
        },
        state = { commit = head(root), change = "-" },
        rows = { "dev lint" },
    }
end

local function checked_then_trunk_moves()
    local root = with_origin({ ["f.txt"] = BODY })
    git(root, "checkout", "-q", "-b", "work")
    write(root, "f.txt", (BODY:gsub("line 15\n", "line fifteen\n")))
    git(root, "commit", "-q", "-a", "-m", "feat: f")
    local checked = head(root)
    git(root, "checkout", "-q", "main")
    write(root, "f.txt", "top\n" .. BODY)
    git(root, "commit", "-q", "-a", "-m", "trunk moves")
    git(root, "push", "-q", "origin", "main")
    return root, checked
end

testing.test("git trunk problem names a moved trunk", function()
    local root = with_origin({})
    git(root, "checkout", "-q", "-b", "work")
    write(root, "f.txt", "f\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: f")
    testing.eq(land.trunk_problem(root), nil)
    git(root, "checkout", "-q", "main")
    write(root, "g.txt", "g\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "trunk moves")
    git(root, "push", "-q", "origin", "main")
    git(root, "checkout", "-q", "work")
    local problem = land.trunk_problem(root)
    testing.ok(problem and problem:find("has moved", 1, true), tostring(problem))
end)

testing.test("git carry keeps a check across a rebase with an unchanged patch", function()
    local root, checked = checked_then_trunk_moves()
    git(root, "checkout", "-q", "-b", "moved")
    git(root, "cherry-pick", checked)
    local commit, problem = land.carry(carry_opts(root, checked))
    testing.eq(commit, checked)
    testing.eq(problem, nil)
end)

testing.test("git carry refuses a changed patch or a moved parent", function()
    local root, checked = checked_then_trunk_moves()
    git(root, "checkout", "-q", "-b", "moved")
    git(root, "cherry-pick", checked)
    write(root, "f.txt", "top\n" .. BODY .. "extra\n")
    git(root, "commit", "-q", "-a", "--amend", "-m", "feat: f")
    local commit, problem = land.carry(carry_opts(root, checked))
    testing.eq(commit, nil)
    testing.ok(
        problem and problem:find("differs from the checked commit", 1, true),
        tostring(problem)
    )
    git(root, "checkout", "-q", "-b", "stale", checked)
    git(root, "commit", "-q", "--allow-empty", "-m", "feat: stale")
    commit, problem = land.carry(carry_opts(root, checked))
    testing.eq(commit, nil)
    testing.ok(problem and problem:find("has moved", 1, true), tostring(problem))
end)

testing.test("git recheck skips rows on an unchanged patch", function()
    local root = with_origin({})
    git(root, "checkout", "-q", "-b", "work")
    write(root, "f.txt", "f\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: f")
    local checked = head(root)
    git(root, "commit", "-q", "--amend", "-m", "feat: f again")
    local problem = land.recheck_problem({
        root = root,
        commit = checked,
        card = "abc12345",
        rows = { "dev lint" },
        note = function()
            error("a shared parent runs no row")
        end,
    })
    testing.eq(problem, nil)
    local moved_root, first = checked_then_trunk_moves()
    git(moved_root, "checkout", "-q", "-b", "moved")
    git(moved_root, "cherry-pick", first)
    problem = land.recheck_problem({
        root = moved_root,
        commit = first,
        card = "abc12345",
        rows = { "false" },
        note = function()
            error("an unchanged patch over a moved trunk runs no row")
        end,
    })
    testing.eq(problem, nil)
    write(moved_root, "f.txt", "top\n" .. BODY .. "extra\n")
    git(moved_root, "commit", "-q", "-a", "--amend", "-m", "feat: f")
    problem = land.recheck_problem({
        root = moved_root,
        commit = first,
        card = "abc12345",
        rows = { "false" },
        note = function() end,
    })
    testing.ok(problem and problem:find("recheck row failed", 1, true), tostring(problem))
end)

testing.test(
    "git recheck narrows a plain remote test row to the suites the change covers",
    function()
        local root = with_origin({
            ["a/lua/m.lua"] = "return 1\n",
            ["tests/lua/m_test.lua"] = 'require("m")\n',
        })
        git(root, "checkout", "-q", "-b", "work")
        write(root, "a/lua/m.lua", "return 2\n")
        git(root, "commit", "-q", "-a", "-m", "feat: m")
        local checked = head(root)
        write(root, "a/lua/m.lua", "return 3\n")
        git(root, "commit", "-q", "-a", "--amend", "-m", "feat: m")
        local ran = {}
        local original = check.run
        check.run = function(opts)
            ran[#ran + 1] = { run = opts.run, argv = opts.argv }
            return { result = check.Result.PASS, run_id = "-", run = opts.run, tail = "" }
        end
        local problem = land.recheck_problem({
            root = root,
            commit = checked,
            card = "abc12345",
            rows = { "dev --remote lint", "dev --remote test" },
            note = function() end,
        })
        check.run = original
        testing.eq(problem, nil)
        testing.eq(ran[1].argv, { "dev", "--remote", "lint" })
        testing.eq(ran[2].run, "dev --remote test")
        testing.eq(ran[2].argv, { "dev", "--remote", "test", "--", "tests/lua/m_test.lua" })
    end
)

testing.test("git card_touched names both paths of a rename", function()
    local body = string.rep("line of the module\n", 20)
    local root = repo({ ["a/lua/old.lua"] = body, ["keep.txt"] = "k\n" })
    git(root, "mv", "a/lua/old.lua", "a/lua/new.lua")
    git(root, "commit", "-q", "-m", "refactor: rename")
    testing.eq(land.card_touched(root), { "a/lua/new.lua", "a/lua/old.lua" })
end)

testing.test("a malformed recheck row prints its reason with one period", function()
    local cases = {
        { row = " ", reason = "A checks row is blank." },
        { row = "a | b", reason = "A row runs as a plain command." },
    }
    for _, case in ipairs(cases) do
        local problem = land.recheck_problem({
            root = "unused",
            commit = "unused",
            card = "abc12345",
            rows = { case.row },
            note = function() end,
        })
        testing.ok(problem and problem:find(case.reason, 1, true), tostring(problem))
        testing.ok(not problem:find("..", 1, true), tostring(problem))
    end
end)

local function landing_env(fn)
    local self = dev_os.capture({ "pwd" }):gsub("\n$", "") .. "/dotfiles/bin/.local/bin/dev"
    local set = {
        DEV_SELF = self,
        GIT_COMMITTER_NAME = "t",
        GIT_COMMITTER_EMAIL = "t@example.com",
        GIT_AUTHOR_NAME = "t",
        GIT_AUTHOR_EMAIL = "t@example.com",
    }
    local before = {}
    for name, value in pairs(set) do
        before[name] = os.getenv(name) or ""
        ffi.C.setenv(name, value, 1)
    end
    local ok, err = pcall(fn)
    for name, value in pairs(before) do
        ffi.C.setenv(name, value, 1)
    end
    assert(ok, err)
end

local function remote_main(root)
    local out = dev_os.capture({ "git", "-C", root, "ls-remote", "origin", "refs/heads/main" })
    return out:match("^(%x+)")
end

local function work_behind_trunk()
    local root = with_origin({ ["f.txt"] = BODY })
    git(root, "checkout", "-q", "-b", "work")
    write(root, "w.txt", "w\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: work")
    git(root, "checkout", "-q", "main")
    write(root, "g.txt", "g\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "trunk moves")
    git(root, "push", "-q", "origin", "main")
    git(root, "checkout", "-q", "work")
    return root
end

testing.test("land.git.rebase moves a change onto fetched trunk and refuses the rest", function()
    landing_env(function()
        local root = work_behind_trunk()
        testing.eq(land.rebase(root), true)
        testing.eq(land.rebase(root), false)
        local parent = dev_os.capture({ "git", "-C", root, "rev-parse", "HEAD~1" })
        testing.eq(parent:match("^%x+"), remote_main(root))
        write(root, "x.txt", "x\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "feat: stacked")
        git(root, "checkout", "-q", "main")
        write(root, "h.txt", "h\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "trunk moves again")
        git(root, "push", "-q", "origin", "main")
        git(root, "checkout", "-q", "work")
        local moved, why = land.rebase(root)
        testing.eq(moved, nil)
        testing.ok(why:find("unlanded parent", 1, true), tostring(why))
    end)
end)

testing.test("land.git.rebase names a conflict and leaves the branch where it was", function()
    landing_env(function()
        local root = with_origin({ ["f.txt"] = "one\n" })
        git(root, "checkout", "-q", "-b", "work")
        write(root, "f.txt", "work\n")
        git(root, "commit", "-q", "-a", "-m", "feat: work")
        local before = head(root)
        git(root, "checkout", "-q", "main")
        write(root, "f.txt", "trunk\n")
        git(root, "commit", "-q", "-a", "-m", "trunk moves")
        git(root, "push", "-q", "origin", "main")
        git(root, "checkout", "-q", "work")
        local moved, why = land.rebase(root)
        testing.eq(moved, nil)
        testing.ok(why:find("The rebase onto trunk failed", 1, true), tostring(why))
        testing.eq(head(root), before)
        local status = dev_os.capture({ "git", "-C", root, "status", "--porcelain" })
        testing.eq(status, "")
    end)
end)

testing.test("land.git.rebase names a failed fetch", function()
    landing_env(function()
        local root = work_behind_trunk()
        git(root, "remote", "set-url", "origin", root .. "/missing")
        local moved, why = land.rebase(root)
        testing.eq(moved, nil)
        testing.ok(why:find("The fetch from origin failed", 1, true), tostring(why))
    end)
end)

testing.test("land.git.run pushes HEAD to trunk and refuses a rejected push", function()
    landing_env(function()
        local root = work_behind_trunk()
        assert(land.rebase(root))
        local commit = head(root)
        local landed, out = land.run(root)
        testing.eq(landed, true, out)
        testing.eq(remote_main(root), commit)
        testing.eq(land.trunk_commit(root, "-"), commit)
        git(root, "checkout", "-q", "-b", "stale", "HEAD~1")
        write(root, "s.txt", "s\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "feat: stale")
        landed, out = land.run(root)
        testing.eq(landed, false)
        testing.ok(out:find("rejected", 1, true), out)
        testing.eq(remote_main(root), commit)
        testing.eq(land.trunk_commit(root, "-"), nil)
    end)
end)

testing.test("land.git.run names a bad forge kind in a sentence", function()
    landing_env(function()
        local root = work_behind_trunk()
        local before = os.getenv("JJ_FORGE") or ""
        ffi.C.setenv("JJ_FORGE", "bogus", 1)
        local ran, landed, out = pcall(land.run, root)
        ffi.C.setenv("JJ_FORGE", before, 1)
        assert(ran, landed)
        testing.eq(landed, false)
        testing.ok(out:find("^Trunk cannot be pushed%. Forge must be gerrit"), out)
        testing.ok(out:find("%.$"), out)
    end)
end)

testing.test("trunk-config-forge-refusal reads as one sentence", function()
    landing_env(function()
        local root = with_origin({})
        local before = os.getenv("JJ_FORGE") or ""
        ffi.C.setenv("JJ_FORGE", "bogus", 1)
        local ran, text, problem = pcall(land.trunk_config, root)
        ffi.C.setenv("JJ_FORGE", before, 1)
        assert(ran, text)
        testing.eq(text, nil)
        testing.ok(problem:find("^Trunk cannot be read%. %u"), problem)
        testing.ok(problem:find("%.$"), problem)
    end)
end)

testing.test("trunk-config-ref-refusal names the remote without a trunk branch", function()
    landing_env(function()
        local root = repo({})
        local bare = assert(fs.realpath(support.tempdir()))
        local code = dev_os.run({ "git", "init", "-q", "--bare", bare }, { stdout = "null" })
        assert(code == 0, "git init failed")
        git(root, "remote", "add", "origin", bare)
        local text, problem = land.trunk_config(root)
        testing.eq(text, nil)
        testing.ok(
            problem:find(
                "^Trunk cannot be read%. The remote origin has no master or main branch%.$"
            ),
            problem
        )
    end)
end)

testing.test("land.git.settled_commit names a checked commit only once trunk holds it", function()
    landing_env(function()
        local root = work_behind_trunk()
        assert(land.rebase(root))
        local record = { commit = head(root), change = "-" }
        testing.eq(land.settled_commit(root, record), nil)
        local landed, out = land.run(root)
        testing.eq(landed, true, out)
        testing.eq(land.settled_commit(root, record), record.commit)
    end)
end)

if dev_os.which("jj") then
    testing.test("a git worktree of a colocated repo reads revisions as git", function()
        landing_env(function()
            -- Make a colocated jj and git repo with a pushed trunk
            local root = with_origin({ ["f.txt"] = BODY })
            local init = { stdout = "null", stderr = "null" }
            local code = dev_os.run({ "jj", "git", "init", "--colocate", root }, init)
            testing.eq(code, 0)
            local pushed = remote_main(root)

            -- Add a git worktree that holds one commit past trunk
            local worktree = assert(fs.realpath(support.tempdir())) .. "/wt"
            git(root, "worktree", "add", "-q", "-b", "wt", worktree)
            write(worktree, "w.txt", "w\n")
            git(worktree, "add", "-A")
            git(worktree, "commit", "-q", "-m", "feat: work")

            -- Expect the worktree root to read as git, not as the jj project
            testing.eq(vcs.backend(root), vcs.JJ)
            testing.eq(vcs.backend(worktree), vcs.GIT)

            -- Expect the pushed SHA to resolve and the ancestor check to answer from the worktree
            testing.eq(land.fetched_commit(worktree, pushed), pushed)
            testing.eq(land.holds(worktree, pushed, "HEAD"), true)
            testing.eq(land.holds(worktree, head(worktree), pushed), false)
        end)
    end)
end
