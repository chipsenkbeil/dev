local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local scm = require("@dev/scm")
local support = require("./support")

local IDENT = support.GIT_IDENT
local JJ_IDENT = { JJ_USER = "t", JJ_EMAIL = "t@example.com" }
local git = support.git
local rev = support.rev

local TRAILER = "Change-Id: I0a1b2c3d4e5f60718293a4b5c6d7e8f901234567"
local COPY = "copy"
local NONE = "none"
local STUB = table.concat({
    [[#!/bin/sh]],
    [[real() {]],
    [[    "$REAL_JJ" --no-pager -R "$ROOT" "$@" >/dev/null 2>&1]],
    [[}]],
    [[for word in "$@"; do]],
    [[    if [ "$word" = land ]; then]],
    [[        cur=$("$REAL_JJ" --no-pager -R "$ROOT" log -r @ --no-graph -T commit_id)]],
    `        if [ "$LAND_MODE" = {COPY} ]; then`,
    [[            for orig in $("$REAL_JJ" --no-pager -R "$ROOT" log -r "master..$LAND_REV" --reversed --no-graph -T 'commit_id ++ " "'); do]],
    [[                msg=$("$REAL_JJ" --no-pager -R "$ROOT" log -r "$orig" --no-graph -T description)]],
    [[                real new master -m "$msg"]],
    [[                real restore --from "$orig"]],
    [[                real bookmark set master -r @]],
    [[            done]],
    [[            real git push --remote origin --bookmark master]],
    [[            real edit "$cur"]],
    [[        fi]],
    [[        exit 0]],
    [[    fi]],
    [[done]],
    [[exec "$REAL_JJ" "$@"]],
    "",
}, "\n")

local function git_project()
    -- Make a project and a bare remote
    local root = support.sandbox({ [".dev/config.toml"] = "" }, {})
    local bare = support.tempdir()
    assert(
        dev_os.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, { stdout = "null" })
            == 0
    )
    assert(dev_os.run({ "git", "init", "-q", "-b", "master", root }, { stdout = "null" }) == 0)
    git(root, "remote", "add", "origin", bare)

    -- Publish a base commit
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "base")
    git(root, "push", "-q", "origin", "master")

    -- Publish a work branch with a change
    git(root, "checkout", "-q", "-b", "work")
    assert(fs.write(root .. "/work.txt", "one\n"), "write failed")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: work")
    git(root, "push", "-q", "origin", "work")
    return root, bare
end

local function has_branch(dir, name)
    local out = dev_os.capture({ "git", "-C", dir, "branch", "--list", name })
    return out:match("%S") ~= nil
end

testing.test("land.drop.git.deletes.the.landed.local.and.remote.branch", function()
    -- Land the work branch
    local root, bare = git_project()
    local out, code = support.dev(root, { "land" }, { env = IDENT })
    testing.eq(code, 0, out)

    -- Check the output reports both deletions
    testing.ok(out:find("Deleted remote branch work", 1, true), out)
    testing.ok(out:find("Deleted branch work", 1, true), out)

    -- Check the branches are gone and trunk holds the work
    testing.eq(has_branch(bare, "work"), false)
    testing.eq(has_branch(root, "work"), false)
    testing.eq(rev(bare, "refs/heads/master"), rev(root, "HEAD"))
end)

testing.test("land.drop.git.keeps.the.branches.of.a.land.that.did.not.reach.trunk", function()
    -- Make the remote refuse every push
    local root, bare = git_project()
    local hook = bare .. "/hooks/pre-receive"
    assert(fs.mkdir(bare .. "/hooks", { parents = true }), "mkdir failed")
    assert(fs.write(hook, table.concat({ "#!/bin/sh", "exit 1", "" }, "\n")), "write failed")
    assert(dev_os.run({ "chmod", "755", hook }) == 0, "chmod failed")

    -- Land the work branch
    local base = rev(bare, "refs/heads/master")
    local _, code = support.dev(root, { "land" }, { env = IDENT })
    testing.eq(code, 1)

    -- Check trunk did not move and both branches stay
    testing.eq(rev(bare, "refs/heads/master"), base)
    testing.eq(has_branch(bare, "work"), true)
    testing.eq(has_branch(root, "work"), true)
end)

testing.test("land.drop.git.leaves.a.child.branch.on.the.landed.commit", function()
    -- Stack a child branch on the work branch
    local root = git_project()
    git(root, "checkout", "-q", "-b", "child")
    assert(fs.write(root .. "/child.txt", "child\n"), "write failed")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: child")
    git(root, "checkout", "-q", "work")

    -- Land the work branch
    local out, code = support.dev(root, { "land" }, { env = IDENT })
    testing.eq(code, 0, out)

    -- Check the child still sits on the landed commit
    local landed = rev(root, "origin/master")
    local held = dev_os.run({ "git", "-C", root, "merge-base", "--is-ancestor", landed, "child" })
    testing.eq(held, 0)
    testing.eq(has_branch(root, "child"), true)
end)

if dev_os.which("jj") then
    local function jj(root, ...)
        local argv = { "jj", "--no-pager", "--color", "never", "-R", root, ... }
        local out, code = dev_os.capture(argv, { stderr = "null", env = JJ_IDENT })
        assert(code == 0, out)
        return out
    end

    local function jj_project()
        -- Put the stub jj in a project
        local root = support.sandbox({ [".dev/config.toml"] = "" }, {})
        assert(fs.write(root .. "/bin/jj", STUB), "write failed")
        assert(dev_os.run({ "chmod", "755", root .. "/bin/jj" }) == 0, "chmod failed")

        -- Make a bare remote and a jj repository that pushes to it
        local bare = support.tempdir()
        local quiet = { stdout = "null" }
        assert(dev_os.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, quiet) == 0)
        local env = { stdout = "null", stderr = "null", env = JJ_IDENT }
        assert(dev_os.run({ "jj", "git", "init", root }, env) == 0, "jj init failed")
        jj(root, "git", "remote", "add", "origin", bare)

        -- Publish a base commit as master
        assert(fs.write(root .. "/seed.txt", "seed\n"), "write failed")
        jj(root, "commit", "-m", "base")
        jj(root, "bookmark", "create", "master", "-r", "@-")
        jj(root, "git", "push", "--remote", "origin", "--bookmark", "master")

        -- Describe a working change that carries a change id
        jj(root, "describe", "-m", table.concat({ "feat: work", "", TRAILER }, "\n"))
        assert(fs.write(root .. "/work.txt", "one\n"), "write failed")
        return root
    end

    local function land(root, mode, rev_name)
        -- Remember the environment
        local names = {
            "PATH",
            "REAL_JJ",
            "ROOT",
            "LAND_MODE",
            "LAND_REV",
            "JJ_USER",
            "JJ_EMAIL",
        }
        local before = {}
        for _, name in ipairs(names) do
            before[name] = dev_os.getenv(name) or ""
        end

        -- Point it at the stub jj and merge into trunk
        dev_os.setenv("REAL_JJ", dev_os.which("jj"))
        dev_os.setenv("PATH", root .. "/bin:" .. before.PATH)
        dev_os.setenv("ROOT", root)
        dev_os.setenv("JJ_USER", JJ_IDENT.JJ_USER)
        dev_os.setenv("JJ_EMAIL", JJ_IDENT.JJ_EMAIL)
        dev_os.setenv("LAND_MODE", mode)
        dev_os.setenv("LAND_REV", rev_name)
        local ok, out, dropped = scm.workspace(root):merge_into_trunk()

        -- Put the environment back and report what was dropped
        for _, name in ipairs(names) do
            dev_os.setenv(name, before[name])
        end
        assert(ok, out)
        return table.concat(dropped, "\n")
    end

    local function ids(root, revset)
        return jj(root, "log", "-r", revset, "--no-graph", "-T", 'commit_id ++ "\\n"')
    end

    testing.test("land.drop.jj.abandons.the.original.of.a.landed.change", function()
        -- Land the working change by copy
        local root = jj_project()
        local original = ids(root, "@"):gsub("\n", "")
        local lines = land(root, COPY, "@")
        testing.ok(lines:find("Abandoned change", 1, true), lines)

        -- Check the original is gone and trunk holds the copy
        testing.eq(ids(root, "all()"):find(original, 1, true), nil)
        testing.eq(ids(root, "description(substring:'feat: work') ~ ::trunk()"), "")
        testing.eq(ids(root, "@-"), ids(root, "trunk()"))

        -- Check the working copy is a fresh empty change
        testing.eq(ids(root, "@ & empty()") ~= "", true)
    end)

    testing.test("land.drop.jj.never.abandons.a.change.trunk.does.not.hold", function()
        local root = jj_project()
        local original = ids(root, "@")
        local lines = land(root, NONE, "@")
        testing.ok(lines:find("Kept change", 1, true), lines)
        testing.ok(lines:find("trunk does not hold", 1, true), lines)
        testing.eq(ids(root, "@"), original)
    end)

    testing.test("land.drop.jj.abandons.every.change.of.a.landed.stack", function()
        -- Stack a second change on the working one
        local root = jj_project()
        local second = "Change-Id: I1111111111111111111111111111111111111111"
        jj(root, "new", "-m", table.concat({ "feat: second", "", second }, "\n"))
        assert(fs.write(root .. "/second.txt", "two\n"), "write failed")

        -- Land the stack by copy
        local lines = land(root, COPY, "@")
        testing.eq(select(2, lines:gsub("Abandoned change", "")), 2, lines)

        -- Check both originals are gone and trunk holds the copies
        testing.eq(ids(root, "description(substring:'feat:') ~ ::trunk()"), "")
        testing.eq(ids(root, "heads(all() ~ ::trunk() ~ root())"), ids(root, "@"))
        testing.eq(ids(root, "@ & empty()") ~= "", true)
        testing.eq(ids(root, "@-"), ids(root, "trunk()"))
    end)

    testing.test("land.drop.jj.moves.an.unlanded.child.onto.the.trunk.copy", function()
        -- Stack a child on the working change
        local root = jj_project()
        jj(root, "new", "-m", "feat: child")
        assert(fs.write(root .. "/child.txt", "child\n"), "write failed")

        -- Land only the parent by copy
        local lines = land(root, COPY, "@-")
        testing.ok(lines:find("Abandoned change", 1, true), lines)
        testing.ok(lines:find("Kept change", 1, true), lines)

        -- Check the child now sits on the trunk copy
        testing.eq(ids(root, "description(substring:'feat: work') ~ ::trunk()"), "")
        testing.eq(ids(root, "@-"), ids(root, "trunk()"))
        testing.ok(ids(root, "description(substring:'feat: child')") ~= "")
    end)
end
