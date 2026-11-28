local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local runtime = require("@dev/runtime")
local fs = require("@dev/fs")
local check = require("@dev/board/check")
local land = require("@dev/board/land")
local support = require("./support")
local vcs = require("@dev/vcs")

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
    -- Refuse an empty commit
    local root = repo({})
    git(root, "commit", "-q", "--allow-empty", "-m", "empty one")
    local state, message = land.state(root)
    testing.eq(state, nil)
    testing.ok(message:find("is empty", 1, true), message)

    -- Refuse a commit with no description
    write(root, "f.txt", "f\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "--allow-empty-message", "-m", "")
    state, message = land.state(root)
    testing.eq(state, nil)
    testing.ok(message:find("no description", 1, true), message)

    -- Accept the commit once it has a description
    git(root, "commit", "-q", "--amend", "-m", "feat: f")
    state = assert(land.state(root))
    testing.eq(state.commit, head(root))
end)

testing.test("git added and touched list renames at the new path", function()
    -- Make a repo whose files are about to change
    local lines = table.concat({ "one", "two", "three", "four", "five", "six", "seven", "" }, "\n")
    local root = repo({ ["a.txt"] = "a\n", ["b.txt"] = lines, ["c.txt"] = "c\n" })

    -- Rename one file, delete one, edit one and add one in a single commit
    git(root, "mv", "b.txt", "d.txt")
    git(root, "rm", "-q", "c.txt")
    write(root, "a.txt", "a2\n")
    write(root, "e.txt", "e\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: change")

    -- Expect the rename to list at its new path
    local commit = head(root)
    testing.eq(land.added(root, commit), { "d.txt", "e.txt" })
    testing.eq(land.touched(root, commit), { "a.txt", "c.txt", "d.txt", "e.txt" })

    -- Merge a side branch and expect its file to count as touched
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
    -- Accept the main checkout
    local root = repo({})
    testing.eq(land.workspace_problem(root, "abc12345"), nil)

    -- Refuse a worktree on a branch other than the card's
    local base = assert(fs.realpath(support.tempdir()))
    git(root, "worktree", "add", "-q", "-b", "other", base .. "/other")
    local problem = land.workspace_problem(base .. "/other", "abc12345")
    testing.ok(problem and problem:find("other", 1, true), tostring(problem))
    testing.ok(problem:find("dev ws new abc12345", 1, true), problem)

    -- Accept a worktree on the card's branch
    git(root, "worktree", "add", "-q", "-b", "abc12345", base .. "/card")
    testing.eq(land.workspace_problem(base .. "/card", "abc12345"), nil)

    -- Refuse a detached worktree
    git(root, "worktree", "add", "-q", "--detach", base .. "/loose")
    problem = land.workspace_problem(base .. "/loose", "abc12345")
    testing.ok(problem and problem:find("detached", 1, true), tostring(problem))
end)

testing.test("git reviews carry across an unchanged patch", function()
    -- Commit a numbered file to trunk
    local numbers = {}
    for i = 1, 30 do
        numbers[i] = "line " .. i
    end
    numbers[#numbers + 1] = ""
    local body = table.concat(numbers, "\n")
    local root = repo({ ["f.txt"] = body })

    -- Commit an edit to one line on a work branch
    git(root, "checkout", "-q", "-b", "work")
    write(root, "f.txt", (body:gsub("line 15\n", "line fifteen\n")))
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: f")
    local first = head(root)

    -- Move trunk by adding lines on top, then replay the edit over it
    git(root, "checkout", "-q", "main")
    write(root, "f.txt", table.concat({ "top", "more", "lines", "" }, "\n") .. body)
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "trunk moves")
    git(root, "checkout", "-q", "-b", "moved")
    git(root, "cherry-pick", first)

    -- Expect the reviews of the original edit to carry
    local state = { commit = head(root), change = "-" }
    local comments = { review_of("code", first), review_of("style", first) }
    testing.eq(land.missing_reviews(comments, state, root), {})
    testing.eq(land.refused_reviews(comments, state, root), {})

    -- Change the patch and expect both reviews to go missing
    write(root, "f.txt", table.concat({ "top", "more", "lines", "changed", "" }, "\n"))
    git(root, "add", "-A")
    git(root, "commit", "-q", "--amend", "-m", "feat: f")
    state = { commit = head(root), change = "-" }
    testing.eq(#land.missing_reviews(comments, state, root), 2)
end)

testing.test("git reviews do not carry across an edit moved to repeated text", function()
    -- Commit a file whose text repeats
    local half = table.concat({ "1", "2", "3", "4", "5", "6", "7", "" }, "\n")
    local edited = table.concat({ "1", "2", "3", "4", "5", "X", "6", "7", "" }, "\n")
    local root = repo({ ["f.txt"] = half .. half })

    -- Review an edit made in the first half
    git(root, "checkout", "-q", "-b", "first")
    write(root, "f.txt", edited .. half)
    git(root, "commit", "-q", "-a", "-m", "feat: first")
    local reviewed = head(root)

    -- Make the same edit in the second half on another branch
    git(root, "checkout", "-q", "main")
    git(root, "checkout", "-q", "-b", "second")
    write(root, "f.txt", half .. edited)
    git(root, "commit", "-q", "-a", "-m", "feat: second")

    -- Expect the reviews not to carry
    local state = { commit = head(root), change = "-" }
    local comments = { review_of("code", reviewed), review_of("style", reviewed) }
    testing.eq(#land.missing_reviews(comments, state, root), 2)
end)

testing.test("git reviews carry a root commit with the same patch", function()
    -- Commit a file on a first orphan root
    local root = repo({})
    git(root, "checkout", "-q", "--orphan", "first")
    git(root, "rm", "-rq", "--cached", ".")
    write(root, "f.txt", "same\n")
    git(root, "add", "f.txt")
    git(root, "commit", "-q", "-m", "feat: f")
    local reviewed = head(root)

    -- Commit the same file on a second orphan root
    git(root, "checkout", "-q", "--orphan", "second")
    git(root, "rm", "-rq", "--cached", ".")
    git(root, "add", "f.txt")
    git(root, "commit", "-q", "-m", "feat: f")

    -- Expect the reviews of the first root to carry
    local state = { commit = head(root), change = "-" }
    local comments = { review_of("code", reviewed), review_of("style", reviewed) }
    testing.eq(land.missing_reviews(comments, state, root), {})
end)

testing.test("git reviews do not carry across a conflicting trunk edit", function()
    -- Review an edit to one line on a work branch
    local body = table.concat({ "1", "2", "3", "4", "5", "" }, "\n")
    local root = repo({ ["f.txt"] = body })
    git(root, "checkout", "-q", "-b", "work")
    write(root, "f.txt", table.concat({ "1", "2", "A", "4", "5", "" }, "\n"))
    git(root, "commit", "-q", "-a", "-m", "feat: f")
    local reviewed = head(root)

    -- Change the same line differently on trunk
    git(root, "checkout", "-q", "main")
    write(root, "f.txt", table.concat({ "1", "2", "B", "4", "5", "" }, "\n"))
    git(root, "commit", "-q", "-a", "-m", "trunk edits line three")

    -- Replay the reviewed edit over the conflicting trunk
    git(root, "checkout", "-q", "-b", "moved")
    write(root, "f.txt", table.concat({ "1", "2", "A", "4", "5", "" }, "\n"))
    git(root, "commit", "-q", "-a", "-m", "feat: f")

    -- Expect the reviews not to carry
    local state = { commit = head(root), change = "-" }
    local comments = { review_of("code", reviewed), review_of("style", reviewed) }
    testing.eq(#land.missing_reviews(comments, state, root), 2)
end)

testing.test("git template problem reads the template listing", function()
    -- Configure a template folder that syncs to other projects
    local root = repo({
        [".dev/config.toml"] = table.concat({
            "[sync]",
            'templates = ["tpl"]',
            'baked = ".dev/baked.txt"',
            "",
        }, "\n"),
    })

    -- Commit a Lua template that breaks the template rules
    write(root, "tpl/lint.lua", 'local fs = require("@dev/fs")\n')
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: template")

    -- Expect the problem to name the offending call
    local touched = assert(land.touched(root, head(root)))
    local problem = land.template_problem(root, touched)
    testing.ok(problem and problem:find("calls dev.fs", 1, true), tostring(problem))
end)

testing.test("git template problem refuses entries the landing commit adds", function()
    -- Configure a template folder and a baked list on trunk
    local root = repo({
        [".dev/config.toml"] = table.concat({
            "[sync]",
            'templates = ["tpl"]',
            'baked = ".dev/baked.txt"',
            "",
        }, "\n"),
        [".dev/baked.txt"] = "dev.fs\n",
    })

    -- Commit a template and the entry it calls together
    write(root, "tpl/lint.lua", 'local fs = require("@dev/fs")\nreturn fs.exists(1)\n')
    write(root, ".dev/baked.txt", "dev.fs\ndev.fs.exists\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: template")

    -- Expect the problem to name the entry only the commit lists
    local touched = assert(land.touched(root, head(root)))
    local problem = land.template_problem(root, touched)
    testing.ok(problem and problem:find("calls dev.fs.exists", 1, true), tostring(problem))
end)

local function rebuilt_config(rev)
    return table.concat({
        "[sync]",
        'templates = ["tpl"]',
        'baked = ".dev/baked.txt"',
        'baked_rev = "' .. rev .. '"',
        "",
    }, "\n")
end

testing.test("git template problem follows the sync.baked_rev rebuild", function()
    -- Land the baked entries first
    local root = repo({})
    write(root, ".dev/baked.txt", "dev.fs\ndev.fs.exists\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: dev change")
    local rebuilt = head(root)

    -- Point the config at that rebuild rev and commit the template
    write(root, ".dev/config.toml", rebuilt_config(rebuilt))
    write(root, "tpl/lint.lua", 'local fs = require("@dev/fs")\nreturn fs.exists(1)\n')
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: template")

    -- Expect no problem, and a problem for an unknown rev
    local touched = assert(land.touched(root, head(root)))
    testing.eq(land.template_problem(root, touched), nil)
    write(root, ".dev/config.toml", rebuilt_config("nowhere"))
    local problem = land.template_problem(root, touched)
    testing.ok(problem and problem:find("names is not a known commit", 1, true), tostring(problem))
end)

testing.test("git template problem skips a synced file that is not Lua", function()
    -- Configure a template folder that syncs to other projects
    local root = repo({
        [".dev/config.toml"] = table.concat({
            "[sync]",
            'templates = ["tpl"]',
            'baked = ".dev/baked.txt"',
            "",
        }, "\n"),
    })

    -- Commit a non-Lua template that holds Lua-looking text
    write(root, "tpl/README.md", 'local ui = require("@dev/ui")\n')
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "docs: template")

    -- Expect no problem for it
    local touched = assert(land.touched(root, head(root)))
    testing.eq(land.template_problem(root, touched), nil)
end)

local NUMBERED = {}
for i = 1, 30 do
    NUMBERED[i] = "line " .. i
end
NUMBERED[#NUMBERED + 1] = ""
local BODY = table.concat(NUMBERED, "\n")

local function with_origin(files)
    -- Start from a repo holding the files
    local root = repo(files)

    -- Make a bare repo to act as origin
    local bare = assert(fs.realpath(support.tempdir()))
    local code = dev_os.run({ "git", "init", "-q", "--bare", bare }, { stdout = "null" })
    assert(code == 0, "git init failed")

    -- Register it as origin and push trunk to it
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
    -- Start from a repo with an origin
    local root = with_origin({ ["f.txt"] = BODY })

    -- Check in an edit to one line on a work branch
    git(root, "checkout", "-q", "-b", "work")
    write(root, "f.txt", (BODY:gsub("line 15\n", "line fifteen\n")))
    git(root, "commit", "-q", "-a", "-m", "feat: f")
    local checked = head(root)

    -- Move trunk ahead of the work branch and push it
    git(root, "checkout", "-q", "main")
    write(root, "f.txt", "top\n" .. BODY)
    git(root, "commit", "-q", "-a", "-m", "trunk moves")
    git(root, "push", "-q", "origin", "main")
    return root, checked
end

testing.test("git trunk problem names a moved trunk", function()
    -- Commit on a work branch of a repo with an origin
    local root = with_origin({})
    git(root, "checkout", "-q", "-b", "work")
    write(root, "f.txt", "f\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: f")

    -- Expect no problem while trunk stands still
    testing.eq(land.trunk_problem(root), nil)

    -- Move trunk ahead and push it, then return to the work branch
    git(root, "checkout", "-q", "main")
    write(root, "g.txt", "g\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "trunk moves")
    git(root, "push", "-q", "origin", "main")
    git(root, "checkout", "-q", "work")

    -- Expect the problem to say trunk has moved
    local problem = land.trunk_problem(root)
    testing.ok(problem and problem:find("has moved", 1, true), tostring(problem))
end)

testing.test("git carry keeps a check across a rebase with an unchanged patch", function()
    -- Check in an edit, then move trunk beneath it
    local root, checked = checked_then_trunk_moves()

    -- Replay the checked edit onto the moved trunk unchanged
    git(root, "checkout", "-q", "-b", "moved")
    git(root, "cherry-pick", checked)

    -- Expect the check to carry to the replayed commit
    local commit, problem = land.carry(carry_opts(root, checked))
    testing.eq(commit, checked)
    testing.eq(problem, nil)
end)

testing.test("git carry refuses a changed patch or a moved parent", function()
    -- Check in an edit, then move trunk beneath it
    local root, checked = checked_then_trunk_moves()

    -- Replay the edit with an extra change to its patch
    git(root, "checkout", "-q", "-b", "moved")
    git(root, "cherry-pick", checked)
    write(root, "f.txt", "top\n" .. BODY .. "extra\n")
    git(root, "commit", "-q", "-a", "--amend", "-m", "feat: f")

    -- Expect the carry to refuse the changed patch
    local commit, problem = land.carry(carry_opts(root, checked))
    testing.eq(commit, nil)
    testing.ok(
        problem and problem:find("differs from the checked commit", 1, true),
        tostring(problem)
    )

    -- Expect the carry to refuse a parent that has moved
    git(root, "checkout", "-q", "-b", "stale", checked)
    git(root, "commit", "-q", "--allow-empty", "-m", "feat: stale")
    commit, problem = land.carry(carry_opts(root, checked))
    testing.eq(commit, nil)
    testing.ok(problem and problem:find("has moved", 1, true), tostring(problem))
end)

testing.test("git recheck skips rows on an unchanged patch", function()
    -- Check in an edit, then reword its commit
    local root = with_origin({})
    git(root, "checkout", "-q", "-b", "work")
    write(root, "f.txt", "f\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: f")
    local checked = head(root)
    git(root, "commit", "-q", "--amend", "-m", "feat: f again")

    -- Expect a shared parent to run no row
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

    -- Expect an unchanged patch over a moved trunk to run no row
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

    -- Change the patch and expect the recheck row to run and fail
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

testing.test("git recheck reruns rows when a binary file changes", function()
    -- Check in a binary file
    local root = with_origin({})
    git(root, "checkout", "-q", "-b", "work")
    write(root, "blob.bin", "a\0one\0")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: blob")
    local checked = head(root)

    -- Change the binary file in an amend
    write(root, "blob.bin", "a\0two\0")
    git(root, "commit", "-q", "-a", "--amend", "-m", "feat: blob")

    -- Recheck while counting the rows that run
    local ran = 0
    local problem = land.recheck_problem({
        root = root,
        commit = checked,
        card = "abc12345",
        rows = { "false" },
        note = function()
            ran = ran + 1
        end,
    })

    -- Expect the row to run once and fail
    testing.eq(ran, 1)
    testing.ok(problem and problem:find("recheck row failed", 1, true), tostring(problem))
end)

testing.test(
    "git recheck narrows a plain remote test row to the suites the change covers",
    function()
        -- Make a repo holding a module and its test file
        local root = with_origin({
            ["a/lua/m.lua"] = "return 1\n",
            ["tests/lua/m_test.lua"] = 'require("m")\n',
        })

        -- Check in an edit to the module, then amend it
        git(root, "checkout", "-q", "-b", "work")
        write(root, "a/lua/m.lua", "return 2\n")
        git(root, "commit", "-q", "-a", "-m", "feat: m")
        local checked = head(root)
        write(root, "a/lua/m.lua", "return 3\n")
        git(root, "commit", "-q", "-a", "--amend", "-m", "feat: m")

        -- Recheck with check.run recording the rows it is asked to run
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

        -- Expect the test row to narrow to the suite that covers the module
        testing.eq(problem, nil)
        testing.eq(ran[1].argv, { "dev", "--remote", "lint" })
        testing.eq(ran[2].run, "dev --remote test")
        testing.eq(ran[2].argv, { "dev", "--remote", "test", "--", "tests/lua/m_test.lua" })
    end
)

testing.test("git card_touched names both paths of a rename", function()
    -- Make a repo holding a module file
    local body = string.rep("line of the module\n", 20)
    local root = repo({ ["a/lua/old.lua"] = body, ["keep.txt"] = "k\n" })

    -- Rename the module in a commit
    git(root, "mv", "a/lua/old.lua", "a/lua/new.lua")
    git(root, "commit", "-q", "-m", "refactor: rename")

    -- Expect both the new and the old path
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
    -- Name the environment a landing needs
    local self = runtime.exe
    local set = {
        DEV_SELF = self,
        GIT_COMMITTER_NAME = "t",
        GIT_COMMITTER_EMAIL = "t@example.com",
        GIT_AUTHOR_NAME = "t",
        GIT_AUTHOR_EMAIL = "t@example.com",
    }

    -- Remember the old values and set the new ones
    local before = {}
    for name, value in pairs(set) do
        before[name] = dev_os.getenv(name) or ""
        dev_os.setenv(name, value)
    end

    -- Run the body, keeping its outcome for after the restore
    local ok, err = pcall(fn)

    -- Restore the old values, then rethrow a failure
    for name, value in pairs(before) do
        dev_os.setenv(name, value)
    end
    assert(ok, err)
end

local function remote_main(root)
    local out = dev_os.capture({ "git", "-C", root, "ls-remote", "origin", "refs/heads/main" })
    return out:match("^(%x+)")
end

local function work_behind_trunk()
    -- Commit work on a branch of a repo with an origin
    local root = with_origin({ ["f.txt"] = BODY })
    git(root, "checkout", "-q", "-b", "work")
    write(root, "w.txt", "w\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: work")

    -- Move trunk ahead of the work and push it
    git(root, "checkout", "-q", "main")
    write(root, "g.txt", "g\n")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "trunk moves")
    git(root, "push", "-q", "origin", "main")

    -- Leave the work branch checked out, behind trunk
    git(root, "checkout", "-q", "work")
    return root
end

testing.test("land.git.rebase moves a change onto fetched trunk and refuses the rest", function()
    landing_env(function()
        -- Rebase the change onto trunk, then find nothing left to move
        local root = work_behind_trunk()
        testing.eq(land.rebase(root), true)
        testing.eq(land.rebase(root), false)

        -- Expect the change to sit directly on remote trunk
        local parent = dev_os.capture({ "git", "-C", root, "rev-parse", "HEAD~1" })
        testing.eq(parent:match("^%x+"), remote_main(root))

        -- Stack another commit on the work branch
        write(root, "x.txt", "x\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "feat: stacked")

        -- Move trunk ahead again and return to the work branch
        git(root, "checkout", "-q", "main")
        write(root, "h.txt", "h\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "trunk moves again")
        git(root, "push", "-q", "origin", "main")
        git(root, "checkout", "-q", "work")

        -- Expect the rebase to refuse a stack with an unlanded parent
        local moved, why = land.rebase(root)
        testing.eq(moved, nil)
        testing.ok(why:find("unlanded parent", 1, true), tostring(why))
    end)
end)

testing.test("land.git.rebase names a conflict and leaves the branch where it was", function()
    landing_env(function()
        -- Commit an edit to a file on a work branch
        local root = with_origin({ ["f.txt"] = "one\n" })
        git(root, "checkout", "-q", "-b", "work")
        write(root, "f.txt", "work\n")
        git(root, "commit", "-q", "-a", "-m", "feat: work")
        local before = head(root)

        -- Change the same file differently on trunk and push it
        git(root, "checkout", "-q", "main")
        write(root, "f.txt", "trunk\n")
        git(root, "commit", "-q", "-a", "-m", "trunk moves")
        git(root, "push", "-q", "origin", "main")
        git(root, "checkout", "-q", "work")

        -- Expect the rebase to name the conflict
        local moved, why = land.rebase(root)
        testing.eq(moved, nil)
        testing.ok(why:find("The rebase onto trunk failed", 1, true), tostring(why))

        -- Expect the branch and worktree to be left untouched
        testing.eq(head(root), before)
        local status = dev_os.capture({ "git", "-C", root, "status", "--porcelain" })
        testing.eq(status, "")
    end)
end)

testing.test("land.git.rebase names a failed fetch", function()
    landing_env(function()
        -- Start from a work branch behind trunk
        local root = work_behind_trunk()

        -- Point origin at a repository that does not exist
        git(root, "remote", "set-url", "origin", root .. "/missing")

        -- Expect the rebase to name the failed fetch
        local moved, why = land.rebase(root)
        testing.eq(moved, nil)
        testing.ok(why:find("The fetch from origin failed", 1, true), tostring(why))
    end)
end)

testing.test("land.git.run pushes HEAD to trunk and refuses a rejected push", function()
    landing_env(function()
        -- Rebase a work branch onto trunk
        local root = work_behind_trunk()
        assert(land.rebase(root))
        local commit = head(root)

        -- Land it and expect trunk to hold the commit
        local landed, out = land.run(root)
        testing.eq(landed, true, out)
        testing.eq(remote_main(root), commit)
        testing.eq(land.trunk_commit(root, "-"), commit)

        -- Commit on a branch that is behind trunk
        git(root, "checkout", "-q", "-b", "stale", "HEAD~1")
        write(root, "s.txt", "s\n")
        git(root, "add", "-A")
        git(root, "commit", "-q", "-m", "feat: stale")

        -- Expect the push to be rejected and trunk to stay where it was
        landed, out = land.run(root)
        testing.eq(landed, false)
        testing.ok(out:find("rejected", 1, true), out)
        testing.eq(remote_main(root), commit)
        testing.eq(land.trunk_commit(root, "-"), nil)
    end)
end)

testing.test("land.git.run from a worktree on main leaves it on main", function()
    landing_env(function()
        -- Move the main checkout off main, so a worktree can hold it
        local root = with_origin({ ["f.txt"] = BODY })
        git(root, "checkout", "-q", "-b", "side")

        -- Check out main in a worktree and commit one change on it
        local worktree = assert(fs.realpath(support.tempdir())) .. "/wt"
        git(root, "worktree", "add", "-q", worktree, "main")
        write(worktree, "w.txt", "w\n")
        git(worktree, "add", "-A")
        git(worktree, "commit", "-q", "-m", "feat: work")
        local commit = head(worktree)

        -- Land from the worktree and expect trunk to hold the commit
        local landed, out, lines = land.run(worktree)
        testing.eq(landed, true, out)
        testing.eq(remote_main(root), commit)

        -- Expect no branch to be dropped, so the worktree stays on main
        testing.eq(#lines, 0)

        -- Expect the worktree to stay on main at the landed commit
        local ref = dev_os.capture({ "git", "-C", worktree, "symbolic-ref", "--short", "HEAD" })
        testing.eq((ref:gsub("\n$", "")), "main")
        testing.eq(head(worktree), commit)
    end)
end)

testing.test("land.git.run names a bad forge kind in a sentence", function()
    landing_env(function()
        -- Start from a work branch behind trunk and remember the forge setting
        local root = work_behind_trunk()
        local before = dev_os.getenv("JJ_FORGE") or ""

        -- Land with a bogus forge, restoring the setting afterwards
        dev_os.setenv("JJ_FORGE", "bogus")
        local ran, landed, out = pcall(land.run, root)
        dev_os.setenv("JJ_FORGE", before)
        assert(ran, landed)

        -- Expect one sentence that names what the forge must be
        testing.eq(landed, false)
        testing.ok(out:find("^Trunk cannot be pushed%. Forge must be gerrit"), out)
        testing.ok(out:find("%.$"), out)
    end)
end)

testing.test("trunk-config-forge-refusal reads as one sentence", function()
    landing_env(function()
        -- Start from a repo with an origin and remember the forge setting
        local root = with_origin({})
        local before = dev_os.getenv("JJ_FORGE") or ""

        -- Read the trunk config with a bogus forge, restoring the setting afterwards
        dev_os.setenv("JJ_FORGE", "bogus")
        local ran, text, problem = pcall(land.trunk_config, root)
        dev_os.setenv("JJ_FORGE", before)
        assert(ran, text)

        -- Expect a refusal that reads as one sentence
        testing.eq(text, nil)
        testing.ok(problem:find("^Trunk cannot be read%. %u"), problem)
        testing.ok(problem:find("%.$"), problem)
    end)
end)

testing.test("trunk-config-ref-refusal names the remote without a trunk branch", function()
    landing_env(function()
        -- Start from a repo with no origin yet
        local root = repo({})

        -- Add an origin that holds no branches
        local bare = assert(fs.realpath(support.tempdir()))
        local code = dev_os.run({ "git", "init", "-q", "--bare", bare }, { stdout = "null" })
        assert(code == 0, "git init failed")
        git(root, "remote", "add", "origin", bare)

        -- Expect the refusal to name the remote and the missing branches
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
        -- Rebase a work branch onto trunk and record its commit
        local root = work_behind_trunk()
        assert(land.rebase(root))
        local record = { commit = head(root), change = "-" }

        -- Expect trunk not to hold the commit yet
        testing.eq(land.settled_commit(root, record), nil)

        -- Land the commit and expect trunk to hold it
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
