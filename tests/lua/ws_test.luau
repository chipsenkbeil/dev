local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local json = require("@dev/json")
local support = require("./support")
local cmd_ws = require("@dev/cmd/ws")

local DONE_ID = "aaaaaaaa"
local OPEN_ID = "bbbbbbbb"
local SLEEP_POLLS = 100
local SLEEP_POLL_SECONDS = 0.05
local IDENT = { JJ_USER = "t", JJ_EMAIL = "t@example.com" }

local JJ_STUB = [[#!/bin/sh
if [ "$1" = "--no-pager" ]; then shift; fi
if [ "$1" = root ]; then pwd; exit 0; fi
case "$*" in
    *" git root") echo "${GIT_ROOT:-.git}"; exit 0 ;;
    *" git remote list") printf '%s' "$REMOTES"; exit 0 ;;
    *" git fetch "*) echo "jj $*" >> "$LOG"; printf '%s' "$FETCH_OUT"; exit "${FETCH_CODE:-0}" ;;
    *" workspace update-stale") echo "jj $*" >> "$LOG"; exit 0 ;;
esac
echo "jj $*" >> "$LOG"
mkdir -p "$(eval echo \$$#)"
]]
local GIT_STUB = [[#!/bin/sh
case "$*" in
    *"--show-toplevel"*) pwd; exit 0 ;;
    *"--git-common-dir"*) echo "${COMMON_DIR:-$(pwd)/.git}"; exit 0 ;;
    *" remote") printf '%s' "$REMOTES"; exit 0 ;;
    *"config --get"*) exit 1 ;;
    *" fetch "*) echo "git $*" >> "$LOG"; printf '%s' "$FETCH_OUT"; exit "${FETCH_CODE:-0}" ;;
    *"for-each-ref"*) printf '%s' "$REFS"; exit 0 ;;
esac
echo "git $*" >> "$LOG"
mkdir -p "$(eval echo \$$#)"
]]
local NO_GIT = "#!/bin/sh\nexit 1\n"
local NO_REMOTE_MESSAGE = 'The trunk cannot be compared: "the remote of record origin '
    .. "is not a remote of this project (detected: no gerrit remote "
    .. 'and origin is not on github.com)".\n'

local function stub(root, name, body)
    assert(fs.write(root .. "/bin/" .. name, body))
    assert(dev_os.run({ "chmod", "755", root .. "/bin/" .. name }) == 0, "chmod failed")
end

local function setup(kind)
    local root = support.sandbox({}, {})
    local ws = support.tempdir()
    local log = ws .. "/log"
    if kind == "jj" then
        assert(fs.mkdir(root .. "/.jj"))
        stub(root, "jj", JJ_STUB)
        stub(root, "git", NO_GIT)
    elseif kind == "git" then
        assert(fs.mkdir(root .. "/.git"))
        stub(root, "git", GIT_STUB)
        stub(root, "jj", NO_GIT)
    else
        stub(root, "jj", NO_GIT)
        stub(root, "git", NO_GIT)
    end
    local env = {
        env = { DEV_WS_ROOT = ws .. "/ws", LOG = log, JJ_FORGE = "", REMOTES = "origin\n" },
    }
    return root, ws .. "/ws/" .. fs.basename(root) .. "/feat", env, log
end

testing.test("new in a jj project fetches the remote of record first", function()
    -- Stub jj with one remote
    local root, path, env, log = setup("jj")

    -- Create the workspace so the fetch of the remote of record runs first
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect the path printed and the fetch logged before the workspace add
    testing.eq(code, 0)
    testing.eq(out, path .. "\n")
    testing.eq(
        fs.read(log),
        "jj --color never -R "
            .. root
            .. " --ignore-working-copy git fetch --remote origin\n"
            .. "jj -R "
            .. root
            .. " workspace update-stale\n"
            .. "jj -R "
            .. root
            .. " workspace add --name feat -r trunk() "
            .. path
            .. "\n"
    )
end)

testing.test("new in a jj project fetches the gerrit remote of record", function()
    -- Make gerrit the remote of record
    local root, path, env, log = setup("jj")
    env.env.JJ_FORGE = "gerrit"
    env.env.REMOTES = "origin\ngerrit\n"

    -- Create the workspace so the fetch targets the gerrit remote
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect the fetch to name the gerrit remote
    testing.eq(code, 0)
    testing.eq(out, path .. "\n")
    testing.eq(
        fs.read(log),
        "jj --color never -R "
            .. root
            .. " --ignore-working-copy git fetch --remote gerrit\n"
            .. "jj -R "
            .. root
            .. " workspace update-stale\n"
            .. "jj -R "
            .. root
            .. " workspace add --name feat -r trunk() "
            .. path
            .. "\n"
    )
end)

testing.test("new in a jj project stops at a failed fetch with no workspace", function()
    -- Make the fetch fail
    local root, path, env, log = setup("jj")
    env.env.FETCH_CODE = "1"
    env.env.FETCH_OUT = "error: could not connect\n"

    -- Create the workspace while the fetch is set to fail
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect the failure reported and no workspace folder left behind
    testing.eq(code, 1)
    testing.eq(out, "The fetch from origin failed: error: could not connect.\n")
    testing.eq(
        fs.read(log),
        "jj --color never -R " .. root .. " --ignore-working-copy git fetch --remote origin\n"
    )
    testing.eq(fs.exists(path), false)
    testing.eq(fs.exists(fs.dirname(path)), false)
end)

local function real_jj(root, ...)
    return dev_os.capture(
        { "jj", "--no-pager", "--color", "never", "-R", root, ... },
        { stderr = "stdout", env = IDENT }
    )
end

if dev_os.which("jj") then
    testing.test("new from a stale jj workspace makes the workspace and exits 0", function()
        -- Make a real jj project with an empty remote
        local root = support.sandbox({}, {})
        local bare = support.tempdir()
        local bare_init = dev_os.run({ "git", "init", "--bare", "-q", bare }, { stdout = "null" })
        assert(bare_init == 0, "git init failed")
        local init = { stdout = "null", stderr = "null", env = IDENT }
        assert(dev_os.run({ "jj", "git", "init", root }, init) == 0, "jj git init failed")
        real_jj(root, "git", "remote", "add", "origin", bare)

        -- Track a file, add a second workspace and note the operation before the project moves on
        assert(fs.write(root .. "/first", "1"))
        local _, code = real_jj(root, "status")
        testing.eq(code, 0)
        local other = support.tempdir() .. "/other"
        _, code = real_jj(root, "workspace", "add", other)
        testing.eq(code, 0)
        local before =
            real_jj(root, "--ignore-working-copy", "op", "log", "--no-graph", "-n", "1", "-T", "id")

        -- Move the project on with a second tracked file, then restore the earlier operation
        _, code = real_jj(root, "new")
        testing.eq(code, 0)
        assert(fs.write(root .. "/second", "2"))
        _, code = real_jj(root, "status")
        testing.eq(code, 0)
        _, code = real_jj(other, "--ignore-working-copy", "op", "restore", before)
        testing.eq(code, 0)
        local status, status_code = real_jj(root, "status")
        testing.eq(status_code, 1, status)
        testing.ok(status:find("The working copy is stale", 1, true) ~= nil, status)

        -- Create the workspace from the stale project
        local ws = support.tempdir()
        local env = {
            env = {
                DEV_WS_ROOT = ws,
                JJ_FORGE = "",
                JJ_USER = IDENT.JJ_USER,
                JJ_EMAIL = IDENT.JJ_EMAIL,
            },
        }
        local out, new_code = support.dev(root, { "ws", "new", "feat" }, env)

        -- Expect the workspace made at its path and exit 0
        local path = ws .. "/" .. fs.basename(root) .. "/feat"
        testing.eq(new_code, 0, out)
        testing.ok(fs.exists(path .. "/.jj"), out)
    end)
end

testing.test("new in a jj project refuses a missing remote of record", function()
    -- Leave the project with no remotes
    local root, path, env, log = setup("jj")
    env.env.REMOTES = ""

    -- Create the workspace with no remote so the missing-remote check runs
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect a refusal before jj runs or any folder appears
    testing.eq(code, 1)
    testing.eq(out, NO_REMOTE_MESSAGE)
    testing.eq(fs.exists(log), false)
    testing.eq(fs.exists(path), false)
end)

testing.test("new in a git project adds a worktree on the fetched trunk", function()
    -- Offer main as the only trunk branch
    local root, path, env, log = setup("git")
    env.env.REFS = "origin/HEAD\norigin/feat\norigin/main\n"

    -- Create the workspace so the worktree branches from the offered main
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect a fetch, then a worktree branched from origin/main
    testing.eq(code, 0)
    testing.eq(out, path .. "\n")
    testing.eq(
        fs.read(log),
        table.concat({
            "git -C " .. root .. " fetch origin",
            "git -C " .. root .. " worktree add --no-track -b feat " .. path .. " origin/main",
            "",
        }, "\n")
    )
end)

testing.test("new in a git project stops at a failed fetch with no worktree", function()
    -- Make the fetch fail
    local root, path, env, log = setup("git")
    env.env.FETCH_CODE = "1"
    env.env.FETCH_OUT = "fatal: could not connect\n"

    -- Create the workspace while the git fetch is set to fail
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect the failure reported and no worktree folder left behind
    testing.eq(code, 1)
    testing.eq(out, "The fetch from origin failed: fatal: could not connect.\n")
    testing.eq(fs.read(log), "git -C " .. root .. " fetch origin\n")
    testing.eq(fs.exists(path), false)
    testing.eq(fs.exists(fs.dirname(path)), false)
end)

testing.test("new in a git project refuses a remote with no trunk branch", function()
    -- Offer only a branch that is not a trunk name
    local root, path, env, log = setup("git")
    env.env.REFS = "origin/dev\n"

    -- Create the workspace against a remote that offers no trunk branch
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect a refusal after the fetch and no worktree
    testing.eq(code, 1)
    testing.eq(
        out,
        'Could not name the trunk of the remote: "origin has no master or main branch".\n'
    )
    testing.eq(fs.read(log), "git -C " .. root .. " fetch origin\n")
    testing.eq(fs.exists(path), false)
end)

testing.test("new in a git project refuses a missing remote of record", function()
    -- Leave the project with no remotes
    local root, path, env, log = setup("git")
    env.env.REMOTES = ""

    -- Create the workspace with no remote so the refusal fires before git runs
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect a refusal before git runs or any folder appears
    testing.eq(code, 1)
    testing.eq(out, NO_REMOTE_MESSAGE)
    testing.eq(fs.exists(log), false)
    testing.eq(fs.exists(path), false)
end)

testing.test("new outside version control makes a plain folder", function()
    -- Stub both tools to fail so no version control is found
    local root, path, env = setup("none")

    -- Create the workspace where no version control is found
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect the path printed and a plain folder made
    testing.eq(code, 0)
    testing.eq(out, path .. "\n")
    testing.eq(fs.is_dir(path), true)
end)

testing.test("new outside a project refuses and makes no workspace", function()
    -- Run from a folder that is no project
    local root, _, env = setup("none")
    local bare = assert(fs.realpath(support.tempdir()))
    env.cwd = bare

    -- Create the workspace from a bare folder to check it is refused
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect a refusal and no workspace root created
    testing.eq(code, 1)
    testing.eq(out, bare .. " is not inside a project.\n")
    testing.eq(fs.exists(env.env.DEV_WS_ROOT), false)
end)

testing.test("ws new says it could not make the folder", function()
    -- Make the parent of the target a plain file
    local root, path, env, log = setup("jj")
    assert(fs.mkdir(fs.dirname(fs.dirname(path)), { parents = true }))
    assert(fs.write(fs.dirname(path), "not a folder"))

    -- Create the workspace under a parent that cannot be a folder
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect a sentence of ws that names the folder and quotes the mkdir message
    local prefix = "Could not make the folder " .. fs.dirname(path) .. '. The mkdir command said: "'
    testing.eq(code, 1)
    testing.eq(out:sub(1, #prefix), prefix)
    testing.eq(out:sub(-3), '".\n')
    testing.eq(fs.exists(log), true)
end)

testing.test("ws quotes a reason without a doubled period", function()
    -- A root can write into a read-only folder, so the failure cannot happen
    if dev_os.getuid() == 0 then
        return
    end

    -- Make the parent of the target read-only so the native mkdir fails
    local root, path, env = setup("jj")
    local parent = fs.dirname(fs.dirname(path))
    assert(fs.mkdir(parent, { parents = true }))
    assert(dev_os.run({ "chmod", "555", parent }) == 0, "chmod failed")

    -- Create the workspace under the read-only parent
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    assert(dev_os.run({ "chmod", "755", parent }) == 0, "chmod failed")

    -- Expect the sentence to close the quote with one period only
    testing.eq(code, 1)
    testing.eq(out:sub(1, 26), "Could not make the folder ")
    testing.eq(out:sub(-3), '".\n')
    testing.ok(not out:find("..", 1, true), out)
end)

testing.test("new refuses a path that exists", function()
    -- Make the workspace folder before the command does
    local root, path, env, log = setup("jj")
    assert(fs.mkdir(path, { parents = true }))

    -- Create the workspace over a folder that already exists
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect a refusal before jj runs
    testing.eq(code, 1)
    testing.eq(out, path .. " already exists.\n")
    testing.eq(fs.exists(log), false)
end)

local LIST_GIT_STUB = [[#!/bin/sh
case "$*" in
    *"worktree list"*) printf '%s' "$WORKTREES"; exit 0 ;;
esac
echo "git $*" >> "$LOG"
]]

local function record(path, note)
    return table.concat({
        "worktree " .. path,
        "HEAD x",
        "branch refs/heads/x",
        note,
        "",
        "",
    }, "\n")
end

local function stale_setup(others)
    local root, path, env, log = setup("jj")
    stub(root, "git", LIST_GIT_STUB)
    env.env.GIT_ROOT = root .. "/.git"
    env.env.WORKTREES = "worktree " .. root .. "\nHEAD x\n\n" .. record(path, "prunable gone")
    for _, other in ipairs(others) do
        env.env.WORKTREES = env.env.WORKTREES .. record(other, "prunable gone")
    end
    return root, path, env, log
end

testing.test("new prunes the stale git record of its own path", function()
    -- Leave the git record of a removed workspace behind
    local root, path, env, log = stale_setup({})

    -- Make the workspace again
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect the prune before the workspace add
    testing.eq(code, 0, out)
    local prune = "git --git-dir " .. root .. "/.git worktree prune\n"
    local add = "jj -R " .. root .. " workspace add --name feat -r trunk() " .. path .. "\n"
    testing.ok(fs.read(log):find(prune .. add, 1, true) ~= nil, fs.read(log))
end)

testing.test("new keeps the record of another removed workspace", function()
    -- Leave a second gone record beside the one for the path
    local root, path, env, log = stale_setup({ "/gone/other" })

    -- Make the workspace again
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect a refusal naming the other record and no prune or add
    testing.eq(code, 1)
    testing.ok(out:find("/gone/other", 1, true) ~= nil, out)
    testing.ok(fs.read(log):find("worktree prune", 1, true) == nil, fs.read(log))
    testing.eq(fs.exists(path), false)
end)

testing.test("new runs no prune when git holds no record of its path", function()
    -- List only a live worktree
    local root, _, env, log = stale_setup({})
    env.env.WORKTREES = "worktree " .. root .. "\nHEAD x\n\n"

    -- Make the workspace
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect no prune
    testing.eq(code, 0, out)
    testing.ok(fs.read(log):find("worktree prune", 1, true) == nil, fs.read(log))
end)

testing.test("DEV_WS_ROOT moves the root and the default is under HOME", function()
    -- Blank the override and point HOME at a fresh folder
    local root, _, env = setup("none")
    local home = support.tempdir()
    env.env.DEV_WS_ROOT = ""
    env.env.HOME = home

    -- Create the workspace with the root blanked to check the HOME default
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect the workspace under HOME's default root
    testing.eq(code, 0)
    testing.eq(out, home .. "/.local/share/workspaces/" .. fs.basename(root) .. "/feat\n")
end)

testing.test("new needs one plain NAME", function()
    local root, _, env = setup("none")
    for _, case in ipairs({
        { { "ws", "new" }, "dev ws new: The argument name is required.\n" },
        { { "ws", "new", "a", "b" }, "dev ws new: Unexpected argument b.\n" },
        { { "ws", "new", "a/b" }, "dev ws new: NAME is one folder name, got a/b\n" },
        { { "ws", "new", "-x" }, "dev ws new: Unknown flag -x.\n" },
    }) do
        local out, code = support.dev(root, case[1], env)
        testing.eq(code, 2)
        testing.eq(out:match("^[^\n]*\n"), case[2])
    end
end)

testing.test(
    "new from a workspace inside the root names the repo by the folder below the root",
    function()
        -- Build a workspace folder under the root with its own dev and bin
        local root, _, env = setup("none")
        local base = assert(fs.realpath(support.tempdir())) .. "/ws"
        local inside = base .. "/proj/first"
        assert(fs.mkdir(inside .. "/.dev", { parents = true }))
        assert(fs.mkdir(inside .. "/bin"))

        -- Point the root at it and the stubs onto PATH
        env.env.DEV_WS_ROOT = base
        env.env.PATH = root .. "/bin:" .. dev_os.getenv("PATH")

        -- Create the workspace from inside the root to check the repo name
        local out, code = support.dev(inside, { "ws", "new", "feat" }, env)

        -- Expect the new folder beside the old one under the same repo
        testing.eq(code, 0)
        testing.eq(out, base .. "/proj/feat\n")
    end
)

local RM_JJ_STUB = [[#!/bin/sh
if [ "$1" = "--no-pager" ]; then shift; fi
case "$*" in
    root) pwd; exit 0 ;;
    *"workspace list"*) printf '%s\n' "$WORKSPACES"; exit 0 ;;
    *" git root") printf '%s' "$GIT_ROOT"; exit 0 ;;
    *" workspace update-stale")
        if [ -n "$UPDATE_FAIL" ]; then echo "update failed" >&2; exit 1; fi
        rm -f "$STALE"; exit 0 ;;
    *" log "*)
        if [ -e "$STALE" ]; then echo "The working copy is stale" >&2; exit 1; fi
        case "$*" in *"@ ~ ::trunk()"*)
            if [ -n "$TEMPLATE_LOG" ]; then echo "$*" >> "$TEMPLATE_LOG"; fi
            if [ -n "$LANDED" ]; then exit 0; fi ;; esac
        printf '%s' "$DIRTY"; exit "${LOG_CODE:-0}" ;;
esac
echo "jj $*" >> "$LOG"
]]
local RM_GIT_STUB = [[#!/bin/sh
case "$*" in
    *"--show-toplevel"*) pwd; exit 0 ;;
    *"--git-common-dir"*) echo "${COMMON_DIR:-$(pwd)/.git}"; exit 0 ;;
    *"worktree list"*) if [ -n "$LIST_FAIL" ]; then exit 128; fi; printf '%s' "$WORKTREES"; exit 0 ;;
    *"status --porcelain"*) printf '%s' "$DIRTY"; exit 0 ;;
esac
echo "git $*" >> "$LOG"
if [ -n "$FAIL" ]; then exit 3; fi
]]

local function rm_setup(kind)
    local root, path, env, log = setup(kind)
    stub(root, "jj", kind == "jj" and RM_JJ_STUB or NO_GIT)
    stub(root, "git", kind == "git" and RM_GIT_STUB or NO_GIT)
    assert(fs.mkdir(path, { parents = true }))
    assert(fs.write(path .. "/file", "x"))
    if kind == "jj" then
        assert(fs.mkdir(path .. "/.jj"))
    elseif kind == "git" then
        assert(fs.write(path .. "/.git", "gitdir: elsewhere\n"))
    end
    env.env.DIRTY = ""
    env.env.WORKSPACES = "default\nfeat"
    return root, path, env, log
end

local function outside_caller(root, kind)
    local caller = root .. "-lead"
    if kind == "jj" then
        assert(fs.mkdir(root .. "/.jj/repo", { parents = true }))
        assert(fs.mkdir(caller .. "/.jj", { parents = true }))
        assert(fs.write(caller .. "/.jj/repo", "../../" .. fs.basename(root) .. "/.jj/repo\n"))
    else
        assert(fs.mkdir(caller, { parents = true }))
        assert(fs.write(caller .. "/.git", "gitdir: elsewhere\n"))
    end
    return caller
end

testing.test("new from a secondary jj workspace outside the root names the main folder", function()
    -- Call from a secondary workspace that sits outside the central root
    local root, path, env = setup("jj")
    env.cwd = outside_caller(root, "jj")

    -- Create the workspace so the repo name comes from the main folder
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect the new folder under the main folder's name, not the caller's
    testing.eq(code, 0, out)
    testing.eq(out, path .. "\n")
end)

testing.test("new from a git worktree outside the root names the main checkout", function()
    -- Call from a worktree that sits outside the central root
    local root, path, env = setup("git")
    env.env.REFS = "origin/main\n"
    env.env.COMMON_DIR = root .. "/.git"
    env.cwd = outside_caller(root, "git")

    -- Create the workspace so the repo name comes from the main checkout
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)

    -- Expect the new folder under the main checkout's name, not the worktree's
    testing.eq(code, 0, out)
    testing.eq(out, path .. "\n")
end)

testing.test("ls and rm from a secondary jj workspace find the main folder's workspaces", function()
    -- Call from a secondary workspace outside the root, with one workspace made
    local root, path, env = rm_setup("jj")
    env.cwd = outside_caller(root, "jj")

    -- List the workspaces and expect the one under the main folder
    local out, code = support.dev(root, { "ws", "ls" }, env)
    testing.eq(code, 0, out)
    testing.eq(out, "feat\t" .. path .. "\n")

    -- Remove it and expect the folder gone from the main folder
    out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 0, out)
    testing.eq(fs.exists(path), false)
end)

testing.test("ls prints each workspace folder with its path", function()
    -- Make one workspace, one other folder and one stray file
    local root, path, env = setup("none")
    assert(fs.mkdir(path, { parents = true }))
    assert(fs.mkdir(fs.dirname(path) .. "/other"))
    assert(fs.write(fs.dirname(path) .. "/stray", "x"))

    -- List the workspaces so the stray file is checked for skipping
    local out, code = support.dev(root, { "ws", "ls" }, env)

    -- Expect the two folders listed and the stray file skipped
    testing.eq(code, 0)
    testing.eq(out, "feat\t" .. path .. "\nother\t" .. fs.dirname(path) .. "/other\n")
end)

testing.test("ls prints nothing when the project has no workspaces", function()
    -- Leave the workspace root empty
    local root, _, env = setup("none")

    -- List the workspaces in an empty root to check nothing prints
    local out, code = support.dev(root, { "ws", "ls" }, env)

    -- Expect no output
    testing.eq(code, 0)
    testing.eq(out, "")
end)

testing.test("ls takes no arguments", function()
    -- Pass a stray argument
    local root, _, env = setup("none")

    -- List with a stray argument to check the usage error names it
    local out, code = support.dev(root, { "ws", "ls", "x" }, env)

    -- Expect a usage error naming it
    testing.eq(code, 2)
    testing.eq(
        out,
        "dev ws ls: Unknown argument x. This command takes no positional arguments.\nusage: dev ws ls\n"
    )
end)

local function trash_dir(env, root)
    return env.env.DEV_WS_ROOT .. "/.trash/" .. fs.basename(root)
end

local function trashed(env, root, name)
    local found = {}
    for _, entry in ipairs(fs.list(trash_dir(env, root)) or {}) do
        if entry:match("^" .. name .. "%-%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ$") then
            found[#found + 1] = entry
        end
    end
    testing.eq(#found, 1)
    return trash_dir(env, root) .. "/" .. found[1]
end

local function stamp_ago(days)
    return os.date("!%Y%m%dT%H%M%SZ", os.time() - days * 24 * 60 * 60)
end

testing.test("rm moves a jj folder to the trash with its ignored files", function()
    -- Add an ignored file to the workspace
    local root, path, env, log = rm_setup("jj")
    assert(fs.write(path .. "/.env", "secret"))

    -- Remove the jj workspace so its ignored file moves to the trash
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect the move reported and the workspace forgotten
    testing.eq(code, 0)
    local target = trashed(env, root, "feat")
    testing.eq(out, "Moved " .. path .. " to " .. target .. ".\n")
    testing.eq(fs.read(log), "jj -R " .. root .. " --ignore-working-copy workspace forget feat\n")

    -- Expect the folder gone from its place with the ignored file in the trash
    testing.eq(fs.exists(path), false)
    testing.eq(fs.read(target .. "/.env"), "secret")
end)

testing.test("rm of a colocated jj workspace prunes the git record", function()
    -- Colocate the jj repo with git and give git a stub that logs
    local root, path, env, log = rm_setup("jj")
    stub(root, "git", RM_GIT_STUB)
    env.env.GIT_ROOT = root .. "/.git"

    -- Remove the workspace so the git worktree record must go with it
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect the workspace forgotten and then the git record pruned
    testing.eq(code, 0, out)
    testing.eq(fs.exists(path), false)
    testing.eq(
        fs.read(log),
        "jj -R "
            .. root
            .. " --ignore-working-copy workspace forget feat\ngit --git-dir "
            .. root
            .. "/.git worktree prune\n"
    )
end)

testing.test("rm of a jj workspace that is not colocated runs no git", function()
    -- Point jj's git root at the store inside .jj
    local root, path, env, log = rm_setup("jj")
    stub(root, "git", RM_GIT_STUB)
    env.env.GIT_ROOT = root .. "/.jj/repo/store/git"

    -- Remove the workspace
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect only the forget in the log
    testing.eq(code, 0, out)
    testing.eq(fs.exists(path), false)
    testing.eq(fs.read(log), "jj -R " .. root .. " --ignore-working-copy workspace forget feat\n")
end)

testing.test("rm succeeds when the git prune of a colocated repo fails", function()
    -- Make the git stub fail every command
    local root, path, env = rm_setup("jj")
    stub(root, "git", RM_GIT_STUB)
    env.env.GIT_ROOT = root .. "/.git"
    env.env.FAIL = "1"

    -- Remove the workspace with the prune failing
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect the removal to finish all the same
    testing.eq(code, 0, out)
    testing.eq(fs.exists(path), false)
end)

testing.test("rm updates a stale jj workspace before it checks for changes", function()
    -- Make jj call the working copy stale until update-stale runs
    local root, path, env = rm_setup("jj")
    local flag = root .. "/stale-flag"
    assert(fs.write(flag, "x"))
    env.env.STALE = flag

    -- Remove the stale workspace with no manual jj step
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect the removal done and the stale flag cleared by update-stale
    testing.eq(code, 0, out)
    testing.eq(fs.exists(path), false)
    testing.eq(fs.exists(flag), false)
end)

testing.test("rm removes a jj workspace whose commit is on trunk", function()
    -- Report changes yet say the working-copy commit is on trunk
    local root, path, env = rm_setup("jj")
    env.env.DIRTY = "changes"
    env.env.LANDED = "1"

    -- Remove the workspace whose commit already landed
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect the removal done
    testing.eq(code, 0, out)
    testing.eq(fs.exists(path), false)
end)

testing.test("rm reads the description when it checks a jj workspace", function()
    -- Record the log template and answer clean as jj does for a described commit
    local root, path, env, log = rm_setup("jj")
    env.env.TEMPLATE_LOG = log .. ".template"

    -- Remove the workspace whose working-copy commit is described
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect the removal done and the template to test the description
    testing.eq(code, 0, out)
    testing.eq(fs.exists(path), false)
    local template = fs.read(log .. ".template")
    testing.ok(template:find('if(empty || description != "", "", "changes")', 1, true), template)
end)

testing.test("rm keeps a jj workspace whose update-stale fails", function()
    -- Make the refresh fail
    local root, path, env = rm_setup("jj")
    env.env.UPDATE_FAIL = "1"

    -- Remove the workspace with the refresh failing
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect a refusal naming the failure and the folder kept
    testing.eq(code, 1)
    testing.eq(out, "Cannot read the state of " .. path .. ": update failed.\n")
    testing.eq(fs.exists(path .. "/file"), true)
end)

testing.test("rm moves a git folder to the trash with its ignored files", function()
    -- Add an ignored file to the worktree
    local root, path, env, log = rm_setup("git")
    assert(fs.write(path .. "/.env", "secret"))

    -- Remove the git worktree so its ignored file moves to the trash
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect the move reported and the worktree record pruned
    testing.eq(code, 0)
    local target = trashed(env, root, "feat")
    testing.eq(out, "Moved " .. path .. " to " .. target .. ".\n")
    testing.eq(fs.read(log), "git -C " .. root .. " worktree prune\n")

    -- Expect the folder gone from its place with the ignored file in the trash
    testing.eq(fs.exists(path), false)
    testing.eq(fs.read(target .. "/.env"), "secret")
end)

testing.test("rm purges trash entries older than 14 days and keeps newer ones", function()
    -- Fill the trash with an old, a recent and an unstamped entry
    local root, path, env = rm_setup("jj")
    local dir = trash_dir(env, root)
    local old = dir .. "/old-" .. stamp_ago(15)
    local recent = dir .. "/recent-" .. stamp_ago(13)
    local unstamped = dir .. "/notes"
    for _, entry in ipairs({ old, recent, unstamped }) do
        assert(fs.mkdir(entry, { parents = true }))
        assert(fs.write(entry .. "/file", "x"))
    end

    -- Remove the folder so the trash entry past 14 days is purged
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect the move and the purge of the old entry reported
    testing.eq(code, 0)
    local target = trashed(env, root, "feat")
    testing.eq(
        out,
        "Moved " .. path .. " to " .. target .. ".\nPurged " .. old .. " from the trash.\n"
    )

    -- Expect only the old entry gone
    testing.eq(fs.exists(old), false)
    testing.eq(fs.exists(recent .. "/file"), true)
    testing.eq(fs.exists(unstamped .. "/file"), true)
end)

testing.test("rm puts a folder back when the forget fails", function()
    -- Make jj fail on the forget
    local root, path, env = rm_setup("jj")
    env.env.FAIL = "1"
    stub(root, "jj", RM_JJ_STUB .. 'if [ -n "$FAIL" ]; then exit 3; fi\n')

    -- Remove the folder while jj fails the forget so it is put back
    local _, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect jj's code, the folder back in place and the trash empty
    testing.eq(code, 3)
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(#fs.list(trash_dir(env, root)), 0)
end)

testing.test("rm puts a folder back when the git prune fails", function()
    -- Make git fail on the prune
    local root, path, env = rm_setup("git")
    env.env.FAIL = "1"

    -- Remove the folder while git fails the prune so it is put back
    local _, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect git's code, the folder back in place and the trash empty
    testing.eq(code, 3)
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(#fs.list(trash_dir(env, root)), 0)
end)

local function worktrees(root, ...)
    local blocks = { "worktree " .. root .. "\nHEAD x\nbranch refs/heads/master" }
    for _, path in ipairs({ ... }) do
        blocks[#blocks + 1] = "worktree " .. path .. "\nHEAD x\nbranch refs/heads/x"
    end
    return table.concat(blocks, "\n\n") .. "\n"
end

testing.test("rm refuses and says so when git worktree list fails", function()
    -- Make the worktree list fail
    local root, path, env, log = rm_setup("git")
    env.env.LIST_FAIL = "1"

    -- Remove the folder while the worktree list fails to check the refusal
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect a refusal naming git's code, with the folder kept and no git run
    testing.eq(code, 1)
    testing.eq(out, "The git worktree list command exited 128.\n")
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("rm refuses a locked git worktree and leaves its folder", function()
    -- Mark the worktree locked
    local root, path, env, log = rm_setup("git")
    env.env.WORKTREES = worktrees(root, path) .. "locked on a usb stick\n"

    -- Remove the folder of a locked worktree to check it is refused
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect a refusal naming the unlock, with the folder kept and no git run
    testing.eq(code, 1)
    testing.eq(out, path .. " is a locked git worktree. Run git worktree unlock first.\n")
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("rm keeps the record of another git worktree whose folder is gone", function()
    -- List a second worktree that git marks prunable
    local root, path, env, log = rm_setup("git")
    local gone = fs.dirname(path) .. "/gone1"
    env.env.WORKTREES = worktrees(root, path)
        .. table.concat({
            "",
            "worktree " .. gone,
            "HEAD x",
            "branch refs/heads/y",
            "prunable gitdir file points to non-existent location",
            "",
        }, "\n")

    -- Remove the folder while a gone sibling's record is at risk
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect a refusal that names the other record
    testing.eq(code, 1)
    testing.eq(
        out,
        "Git worktree prune would also drop the record of "
            .. gone
            .. ", which git marks prunable. Run git worktree prune first.\n"
    )

    -- Expect the folder kept and no git run
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("rm ignores another git worktree that is locked and gone", function()
    -- List a second worktree that is both locked and prunable
    local root, path, env, log = rm_setup("git")
    local gone = fs.dirname(path) .. "/gone1"
    env.env.WORKTREES = worktrees(root, path)
        .. table.concat({
            "",
            "worktree " .. gone,
            "HEAD x",
            "branch refs/heads/y",
            "locked usb stick",
            "prunable gitdir file points to non-existent location",
            "",
        }, "\n")

    -- Remove the folder with a locked and gone sibling to check the prune runs
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect the move to go through and the prune to run
    testing.eq(code, 0, out)
    testing.eq(out, "Moved " .. path .. " to " .. trashed(env, root, "feat") .. ".\n")
    testing.eq(fs.read(log), "git -C " .. root .. " worktree prune\n")
end)

testing.test("ls does not list the trash", function()
    -- Move a workspace to the trash
    local root, path, env = rm_setup("none")
    local _, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 0)
    testing.eq(fs.exists(trashed(env, root, "feat")), true)

    -- List the workspaces after a move to check the trash is left out
    local out = support.dev(root, { "ws", "ls" }, env)

    -- Expect an empty list and the folder gone from its place
    testing.eq(out, "")
    testing.eq(fs.exists(path), false)
end)

testing.test("ws rm refuses a forgotten folder without --forgotten", function()
    -- Make jj report no workspace for the folder
    local root, path, env, log = rm_setup("jj")
    env.env.WORKSPACES = "default"
    env.env.LOG_CODE = "1"

    -- Remove the forgotten folder without the flag to check it is refused
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect a refusal that names the flag
    testing.eq(code, 1)
    testing.eq(
        out,
        path
            .. " is a jj folder that jj no longer tracks. Run `dev ws rm feat "
            .. "--forgotten` to discard it.\n"
    )

    -- Expect the folder kept and no jj run
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("ws rm --forgotten moves a forgotten folder to the trash", function()
    -- Make jj report no workspace for the folder
    local root, path, env, log = rm_setup("jj")
    env.env.WORKSPACES = "default"
    env.env.LOG_CODE = "1"

    -- Remove the forgotten folder with the flag so it moves to the trash
    local out, code = support.dev(root, { "ws", "rm", "feat", "--forgotten" }, env)

    -- Expect the move reported, with no jj run and the folder gone from its place
    testing.eq(code, 0)
    testing.eq(out, "Moved " .. path .. " to " .. trashed(env, root, "feat") .. ".\n")
    testing.eq(fs.exists(log), false)
    testing.eq(fs.exists(path), false)
end)

local NOT_FORGOTTEN = " is not a jj folder jj no longer lists. --forgotten does not apply.\n"

testing.test("ws rm --forgotten refuses a folder jj still lists", function()
    -- Leave the workspace listed in jj
    local root, path, env, log = rm_setup("jj")

    -- Remove a folder jj still lists with the flag to check it is refused
    local out, code = support.dev(root, { "ws", "rm", "--forgotten", "feat" }, env)

    -- Expect a refusal with the folder kept and no jj run
    testing.eq(code, 1)
    testing.eq(out, path .. NOT_FORGOTTEN)
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("ws rm --forgotten refuses a git worktree", function()
    -- Use a git worktree, which the flag never covers
    local root, path, env, log = rm_setup("git")

    -- Remove a git worktree with the flag to check the flag never applies
    local out, code = support.dev(root, { "ws", "rm", "feat", "--forgotten" }, env)

    -- Expect a refusal with the folder kept and no git run
    testing.eq(code, 1)
    testing.eq(out, path .. NOT_FORGOTTEN)
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("ws rm moves a stray file to the trash", function()
    -- Drop a stray file beside the workspace
    local root, path, env, log = rm_setup("jj")
    local stray = fs.dirname(path) .. "/check.log"
    assert(fs.write(stray, "x"))

    -- Remove the stray file beside the workspace to check it moves to the trash
    local out, code = support.dev(root, { "ws", "rm", "check.log" }, env)

    -- Expect the file moved
    testing.eq(code, 0)
    testing.eq(out, "Moved " .. stray .. " to " .. trashed(env, root, "check.log") .. ".\n")
    testing.eq(fs.exists(stray), false)

    -- Expect no jj run and the workspace untouched
    testing.eq(fs.exists(log), false)
    testing.eq(fs.is_dir(path), true)
end)

testing.test("ws.remove refuses a stray file unless it is given stray = true", function()
    -- Drop a stray file under the repo's workspace folder
    local base = assert(fs.realpath(support.tempdir()))
    local root = assert(fs.realpath(support.tempdir()))
    local folder = base .. "/" .. fs.basename(root)
    assert(fs.mkdir(folder, { parents = true }))
    local stray = folder .. "/check.log"
    assert(fs.write(stray, "x"))
    dev_os.setenv("DEV_WS_ROOT", base)

    -- Remove it without the option, then with it
    local refused = cmd_ws.remove(root, "check.log")
    local kept = fs.exists(stray)
    local moved = cmd_ws.remove(root, "check.log", { stray = true })
    dev_os.setenv("DEV_WS_ROOT", "")

    -- Expect the first refused with the file kept and the second to move it
    testing.eq(refused.ok, false)
    testing.eq(refused.reason, cmd_ws.Refusal.NOT_WORKSPACE)
    testing.eq(kept, true)
    testing.eq(moved.ok, true, moved.message)
    testing.eq(fs.exists(stray), false)
end)

testing.test("ws rm still refuses a folder with uncommitted changes", function()
    -- Make jj report changes
    local root, path, env, log = rm_setup("jj")
    env.env.DIRTY = "changes"

    -- Remove the jj folder with changes to check it is refused
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect a refusal with the folder kept and no forget
    testing.eq(code, 1)
    testing.eq(out, path .. " holds changes not in a commit.\n")
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("rm moves a plain folder to the trash", function()
    -- Use a plain folder under no version control
    local root, path, env, log = rm_setup("none")

    -- Remove the plain folder so it moves to the trash with no vcs run
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect the move reported, the folder gone from its place and no vcs run
    testing.eq(code, 0)
    testing.eq(out, "Moved " .. path .. " to " .. trashed(env, root, "feat") .. ".\n")
    testing.eq(fs.exists(path), false)
    testing.eq(fs.exists(log), false)
end)

testing.test("rm refuses a jj workspace with changes and leaves it in place", function()
    -- Make jj report changes
    local root, path, env, log = rm_setup("jj")
    env.env.DIRTY = "changes"

    -- Remove the jj workspace with changes to check it stays in place
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect a refusal with the folder kept and no forget
    testing.eq(code, 1)
    testing.eq(out, path .. " holds changes not in a commit.\n")
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("rm refuses a git worktree with changes and leaves it in place", function()
    -- Make git report a modified file
    local root, path, env, log = rm_setup("git")
    env.env.DIRTY = " M file\n"

    -- Remove the git worktree with a modified file to check it is refused
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect a refusal with the folder kept and no prune
    testing.eq(code, 1)
    testing.eq(out, path .. " holds changes not in a commit.\n")
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("rm leaves a workspace whose state cannot be read", function()
    -- Make the jj state query fail
    local root, path, env, log = rm_setup("jj")
    env.env.LOG_CODE = "1"

    -- Remove the jj workspace whose state query fails to check it is kept
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect a refusal with the folder kept and no forget
    testing.eq(code, 1)
    testing.eq(out, "Cannot read the state of " .. path .. ".\n")
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("rm leaves the folder when the version control command fails", function()
    -- Replace git with a stub that fails every command but the probes
    local root, path, env = rm_setup("git")
    stub(
        root,
        "git",
        '#!/bin/sh\ncase "$*" in *--git-common-dir*) echo "$(pwd)/.git"; exit 0;; *--show-toplevel*) pwd; exit 0;; *status*) exit 0;; *worktree*list*) exit 0;; esac\nexit 3\n'
    )

    -- Remove the folder while git fails every command but the probes
    local _, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect git's code and the folder kept
    testing.eq(code, 3)
    testing.eq(fs.exists(path .. "/file"), true)
end)

testing.test("rm refuses a missing workspace", function()
    -- Delete the folder
    local root, path, env = rm_setup("none")
    assert(fs.remove(path, { recursive = true }))

    -- Remove a folder that is already gone to check the refusal names it
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect a refusal naming the path
    testing.eq(code, 1)
    testing.eq(out, path .. " is not a workspace folder.\n")
end)

testing.test("rm refuses a link that points outside the root and deletes nothing", function()
    -- Swap the folder for a link to a folder outside the root
    local root, path, env = rm_setup("none")
    local outside = assert(fs.realpath(support.tempdir()))
    assert(fs.write(outside .. "/precious", "x"))
    assert(fs.remove(path, { recursive = true }))
    assert(fs.symlink(outside, path))

    -- Remove the link to a folder outside the root to check nothing is deleted
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect a refusal with the target and the link both intact
    testing.eq(code, 1)
    testing.eq(out, path .. " is a link, not removed.\n")
    testing.eq(fs.exists(outside .. "/precious"), true)
    testing.eq(fs.is_link(path), true)
end)

testing.test("rm refuses a link inside the root as well", function()
    -- Add a link to a real folder inside the root
    local root, path, env = rm_setup("none")
    local target = fs.dirname(path) .. "/real"
    assert(fs.mkdir(target))
    assert(fs.write(target .. "/keep", "x"))
    assert(fs.symlink(target, fs.dirname(path) .. "/alias"))

    -- Remove the link inside the root to check the folder it points at is kept
    local _, code = support.dev(root, { "ws", "rm", "alias" }, env)

    -- Expect a refusal with the target kept
    testing.eq(code, 1)
    testing.eq(fs.exists(target .. "/keep"), true)
end)

testing.test("rm refuses a NAME that is not one folder name", function()
    -- Use a plain folder under no version control
    local root, path, env = rm_setup("none")

    -- Try each bad NAME in turn to check each gets a usage error
    for _, case in ipairs({
        { { "ws", "rm" }, "dev ws rm: The argument name is required.\n" },
        { { "ws", "rm", ".." }, "dev ws rm: NAME is one folder name, got ..\n" },
        { { "ws", "rm", "" }, "dev ws rm: NAME is one folder name, got \n" },
        { { "ws", "rm", "../feat" }, "dev ws rm: NAME is one folder name, got ../feat\n" },
        { { "ws", "rm", "/etc" }, "dev ws rm: NAME is one folder name, got /etc\n" },
        { { "ws", "rm", "a", "b" }, "dev ws rm: Unexpected argument b.\n" },
        { { "ws", "rm", "-x" }, "dev ws rm: Unknown flag -x.\n" },
    }) do
        local out, code = support.dev(root, case[1], env)
        testing.eq(code, 2)
        testing.eq(out:match("^[^\n]*\n"), case[2])
    end

    -- Expect the folder kept
    testing.eq(fs.exists(path .. "/file"), true)
end)

testing.test("rm refuses the workspace it runs in", function()
    -- Build a workspace folder under the root with its own dev and bin
    local root, _, env = setup("none")
    local base = assert(fs.realpath(support.tempdir())) .. "/ws"
    local inside = base .. "/proj/first"
    assert(fs.mkdir(inside .. "/.dev", { parents = true }))
    assert(fs.mkdir(inside .. "/bin"))

    -- Point the root at it and the stubs onto PATH
    env.env.DEV_WS_ROOT = base
    env.env.PATH = root .. "/bin:" .. dev_os.getenv("PATH")

    -- Remove the workspace dev runs in to check it is refused
    local out, code = support.dev(inside, { "ws", "rm", "first" }, env)

    -- Expect a refusal with the folder kept
    testing.eq(code, 1)
    testing.eq(out, inside .. " is the workspace dev runs in.\n")
    testing.eq(fs.is_dir(inside), true)
end)

testing.test("rm refuses a repo folder that links outside the root", function()
    -- Swap the repo folder for a link to a folder outside the root
    local root, path, env = rm_setup("none")
    local outside = assert(fs.realpath(support.tempdir()))
    assert(fs.mkdir(outside .. "/feat"))
    assert(fs.write(outside .. "/feat/precious", "x"))
    assert(fs.remove(fs.dirname(path), { recursive = true }))
    assert(fs.symlink(outside, fs.dirname(path)))

    -- Remove a folder whose repo links outside the root to check the target survives
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect a refusal with the outside file intact
    testing.eq(code, 1)
    testing.eq(out, path .. " is outside " .. env.env.DEV_WS_ROOT .. ".\n")
    testing.eq(fs.exists(outside .. "/feat/precious"), true)
end)

local PRUNE_JJ_STUB = [[#!/bin/sh
if [ "$1" = "--no-pager" ]; then shift; fi
case "$*" in
    root) pwd; exit 0 ;;
    *"workspace list"*) printf '%s\n' "$WORKSPACES"; exit 0 ;;
    *" git root") exit 0 ;;
    *" workspace update-stale") echo "update-stale" >> "${UPDATES:-/dev/null}"; exit 0 ;;
    *"workspace root --name "*)
        for last; do :; done
        printf '%s\n' "$ROOTS" | while read -r name path; do
            if [ "$name" = "$last" ]; then echo "$path"; fi
        done
        exit 0 ;;
    *"log -r @ "*)
        case "$*" in *--ignore-working-copy*)
            if [ -n "$STALE_READ" ]; then printf '%s' "$DIRTY"; exit 0; fi ;;
        esac
        if [ -n "$ERROR" ]; then printf '%s\n' "$ERROR" >&2; exit 1; fi
        printf '%s' "$WARN" >&2; printf '%s' "$DIRTY"; exit 0 ;;
    *"& empty()"*)
        case "$*" in *'~ "gone1"@'*) printf '%s' "$FREED_EMPTY"; exit 0 ;; esac
        printf '%s' "$EMPTY"; exit 0 ;;
    *"~ empty()"*)
        case "$*" in *'~ "gone1"@'*) printf '%s' "$FREED_STRAYS"; exit 0 ;; esac
        printf '%s' "$STRAYS"; exit 0 ;;
    *"bookmark list"*) printf '%s' "$BOOKMARKS"; exit 0 ;;
    *"change_id ++"*) printf '%s' "$HEAD_DESCRIPTION"; exit 0 ;;
    *"description(substring:\"Change-Id"*) printf '%s' "$TRUNK_MATCHES"; exit 0 ;;
    *"description(substring"*) printf '%s' "$TITLE_MATCHES"; exit 0 ;;
    *"::trunk()"*) printf '%s' "$TRUNK_MATCHES"; exit 0 ;;
    *interdiff*) printf '%s' "$INTERDIFF"; exit 0 ;;
esac
echo "jj $*" >> "$LOG"
if [ -n "$FAIL" ]; then exit 3; fi
]]
local PRUNE_GIT_STUB = [[#!/bin/sh
case "$*" in
    *"--show-toplevel"*) pwd; exit 0 ;;
    *"--git-common-dir"*) echo "$(pwd)/.git"; exit 0 ;;
    *"worktree list"*)
        if [ -n "$AFTER" ] && grep -q "worktree remove" "$LOG" 2>/dev/null; then
            printf '%s' "$AFTER"; exit 0
        fi
        printf '%s' "$WORKTREES"; exit 0 ;;
    *"status --porcelain"*) printf '%s' "$DIRTY"; exit 0 ;;
    *"for-each-ref"*) printf '%s' "$BRANCHES"; exit 0 ;;
esac
echo "git $*" >> "$LOG"
if [ -n "$FAIL" ]; then exit 3; fi
]]
local function seed_board(root, env, cards)
    assert(
        fs.write(
            root .. "/.dev/config.toml",
            '[board]\nbackend = "local"\nname = "mine"\npath = ".dev/board.json"\n'
        )
    )
    local home = support.tempdir()
    env.env.HOME = home
    env.env.XDG_STATE_HOME = home .. "/state"
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(fs.write(home .. "/.config/dev/config.toml", ""))
    local out, code = support.dev(root, { "board", "init" }, env)
    testing.eq(code, 0, out)
    local doc = assert(json.decode(assert(fs.read(root .. "/.dev/board.json"))))
    local done, open
    for _, column in ipairs(doc.columns) do
        if column.is_done then
            done = column.id
        elseif column.name == support.COLUMN_NAME.READY then
            open = column.id
        end
    end
    for i, card in ipairs(cards) do
        doc.cards[#doc.cards + 1] = {
            id = card.id .. "-1111-4aaa-8aaa-aaaaaaaaaaaa",
            name = "Card " .. i,
            column_id = card.done and done or open,
            position = i,
            labels = {},
            description = "",
        }
    end
    assert(fs.write(root .. "/.dev/board.json", assert(json.encode(doc))))
end

local function prune_setup(kind)
    local root, path, env, log = setup(kind)
    stub(root, "jj", kind == "jj" and PRUNE_JJ_STUB or NO_GIT)
    stub(root, "git", kind == "git" and PRUNE_GIT_STUB or NO_GIT)
    local dir = fs.dirname(path) .. "/"
    assert(fs.mkdir(dir, { parents = true }))
    env.env.DIRTY = ""
    env.env.EMPTY = ""
    env.env.STRAYS = ""
    env.env.FREED_EMPTY = ""
    env.env.FREED_STRAYS = ""
    env.env.BOOKMARKS = ""
    return root, dir, env, log
end

local function lines(...)
    local entries = { ... }
    entries[#entries + 1] = ""
    return table.concat(entries, "\n")
end

local function folder(dir, name)
    local path = dir .. name
    assert(fs.mkdir(path .. "/.jj", { parents = true }))
    assert(fs.write(path .. "/file", "x"))
    return path
end

testing.test("prune forgets a jj workspace whose folder is gone", function()
    -- List a workspace whose folder does not exist
    local root, dir, env, log = prune_setup("jj")
    env.env.WORKSPACES = "default\ngone1"
    env.env.ROOTS = "gone1 " .. dir .. "gone1"

    -- Prune so the workspace whose folder is gone is forgotten
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect the workspace reported forgotten
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Skipped the card test. This project has no board.",
            "Forgot workspace gone1. Its folder " .. dir .. "gone1 is gone.",
            "Pruned 1 workspace and 0 heads. Left 0 items alone."
        )
    )

    -- Expect one forget run in jj
    testing.eq(fs.read(log), "jj -R " .. root .. " --ignore-working-copy workspace forget gone1\n")
end)

testing.test("prune forgets a jj workspace named for a done card", function()
    -- Seed a board with one done and one open card and a folder for each
    local root, dir, env, log = prune_setup("jj")
    seed_board(root, env, { { id = DONE_ID, done = true }, { id = OPEN_ID } })
    local done = folder(dir, DONE_ID)
    local open = folder(dir, OPEN_ID)
    env.env.WORKSPACES = table.concat({ "default", DONE_ID, OPEN_ID }, "\n")
    env.env.ROOTS = table.concat({ DONE_ID .. " " .. done, OPEN_ID .. " " .. open }, "\n")

    -- Prune so only the done card's workspace is forgotten and trashed
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect only the done card's workspace forgotten and trashed
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Forgot workspace "
                .. DONE_ID
                .. ". Its card is done. Moved "
                .. done
                .. " to "
                .. trashed(env, root, DONE_ID)
                .. ".",
            "Left workspace " .. OPEN_ID .. " alone. Its name is not the id of a done card.",
            "Pruned 1 workspace and 0 heads. Left 1 item alone."
        )
    )
    testing.eq(
        fs.read(log),
        "jj -R " .. root .. " --ignore-working-copy workspace forget " .. DONE_ID .. "\n"
    )

    -- Expect the done folder gone and the open one kept
    testing.eq(fs.exists(done), false)
    testing.eq(fs.exists(open .. "/file"), true)
end)

testing.test("prune dry-run names a jj workspace that is not a done card as left alone", function()
    -- Seed a board with one open card and a folder for it
    local root, dir, env, log = prune_setup("jj")
    seed_board(root, env, { { id = OPEN_ID } })
    local open = folder(dir, OPEN_ID)
    env.env.WORKSPACES = table.concat({ "default", OPEN_ID }, "\n")
    env.env.ROOTS = OPEN_ID .. " " .. open

    -- Dry-run the prune over the open card's workspace
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

    -- Expect the workspace named as left alone and counted
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Left workspace " .. OPEN_ID .. " alone. Its name is not the id of a done card.",
            "Would prune 0 workspaces and 0 heads. Left 1 item alone."
        )
    )

    -- Expect no jj command and the folder kept
    testing.eq(fs.read(log) or "", "")
    testing.eq(fs.exists(open .. "/file"), true)
end)

testing.test("prune leaves a git worktree that is not a done card alone", function()
    -- Seed a board with one open card and a worktree folder for it
    local root, dir, env, log = prune_setup("git")
    seed_board(root, env, { { id = OPEN_ID } })
    local open = dir .. OPEN_ID
    assert(fs.mkdir(open, { parents = true }))
    assert(fs.write(open .. "/.git", "gitdir: elsewhere\n"))
    env.env.WORKTREES = worktrees(root, open)

    -- Prune so the open card's worktree is named and kept
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect the worktree named as left alone and nothing removed
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Left worktree " .. OPEN_ID .. " alone. Its name is not the id of a done card.",
            "Git keeps no empty heads.",
            "Pruned 0 worktrees and 0 heads. Left 1 item alone."
        )
    )
    testing.eq(fs.read(log) or "", "")
    testing.eq(fs.exists(open .. "/.git"), true)
end)

testing.test("prune abandons an empty jj head no workspace or bookmark holds", function()
    -- List two empty heads and no workspace but default
    local root, _, env, log = prune_setup("jj")
    local first = ("a1"):rep(20)
    env.env.WORKSPACES = "default"
    env.env.ROOTS = ""
    env.env.EMPTY = lines(first .. "\t", "0123456789abcdef\tdeploy marker")

    -- Prune so both empty heads that nothing holds are abandoned
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect both heads reported abandoned
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Skipped the card test. This project has no board.",
            "Abandoned empty head " .. first:sub(1, 12) .. ".",
            "Abandoned empty head 0123456789ab (deploy marker).",
            "Pruned 0 workspaces and 2 heads. Left 0 items alone."
        )
    )

    -- Expect one abandon run in jj naming both
    testing.eq(fs.read(log), "jj -R " .. root .. " abandon " .. first .. " 0123456789abcdef\n")
end)

testing.test("prune lists a non-empty jj head and a stale bookmark and changes nothing", function()
    -- List a non-empty head and two bookmarks off trunk
    local root, _, env, log = prune_setup("jj")
    env.env.WORKSPACES = "default"
    env.env.ROOTS = ""
    env.env.STRAYS = ("c"):rep(40) .. "\tsome work\n"
    env.env.BOOKMARKS = lines("feat-x", "old")

    -- Prune so the non-empty head and both bookmarks are left alone
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect all three items left alone
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Skipped the card test. This project has no board.",
            "Left non-empty head cccccccccccc (some work) alone. Nothing holds it.",
            "Left bookmark feat-x alone. It is not on trunk.",
            "Left bookmark old alone. It is not on trunk.",
            "Pruned 0 workspaces and 0 heads. Left 3 items alone."
        )
    )

    -- Expect no jj run
    testing.eq(fs.exists(log), false)
end)

testing.test("prune never touches the default workspace or a dirty folder", function()
    -- Seed a done card whose folder is dirty and a default workspace with a gone folder
    local root, dir, env, log = prune_setup("jj")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local dirty = folder(dir, DONE_ID)
    env.env.WORKSPACES = table.concat({ "default", DONE_ID }, "\n")
    env.env.ROOTS =
        table.concat({ "default " .. dir .. "gone-default", DONE_ID .. " " .. dirty }, "\n")
    env.env.DIRTY = "changes"

    -- Prune so the dirty folder is kept and the default is never named
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect the dirty folder kept and the default workspace unmentioned
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Kept workspace " .. DONE_ID .. ". " .. dirty .. " holds changes not in a commit.",
            "Pruned 0 workspaces and 0 heads. Left 1 item alone."
        )
    )

    -- Expect the folder intact and no jj run
    testing.eq(fs.exists(dirty .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune dry-run keeps a dirty jj folder", function()
    -- Seed a done card whose folder is dirty
    local root, dir, env, log = prune_setup("jj")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local dirty = folder(dir, DONE_ID)
    env.env.WORKSPACES = table.concat({ "default", DONE_ID }, "\n")
    env.env.ROOTS =
        table.concat({ "default " .. dir .. "gone-default", DONE_ID .. " " .. dirty }, "\n")
    env.env.DIRTY = "changes"

    -- Dry-run the prune over the dirty folder
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

    -- Expect the folder kept as in the real run, intact and with no jj run
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Kept workspace " .. DONE_ID .. ". " .. dirty .. " holds changes not in a commit.",
            "Would prune 0 workspaces and 0 heads. Left 1 item alone."
        )
    )
    testing.eq(fs.exists(dirty .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune keeps a folder when jj refuses to snapshot a file", function()
    -- Seed a done card and make jj warn that it refused a file
    local root, dir, env, log = prune_setup("jj")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local big = folder(dir, DONE_ID)
    env.env.WORKSPACES = table.concat({ "default", DONE_ID }, "\n")
    env.env.ROOTS = DONE_ID .. " " .. big
    env.env.WARN = "Warning: Refused to snapshot some files"

    -- Prune so the folder jj refused to snapshot is kept
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect the folder kept as holding changes
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Kept workspace " .. DONE_ID .. ". " .. big .. " holds changes not in a commit.",
            "Pruned 0 workspaces and 0 heads. Left 1 item alone."
        )
    )

    -- Expect the folder intact and no jj run
    testing.eq(fs.exists(big .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune keeps an unreadable jj workspace and names its error", function()
    -- Seed a done card and make the state query fail with a stale copy
    local root, dir, env, log = prune_setup("jj")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local broken = folder(dir, DONE_ID)
    env.env.WORKSPACES = table.concat({ "default", DONE_ID }, "\n")
    env.env.ROOTS = DONE_ID .. " " .. broken
    env.env.ERROR = table.concat({
        "Error: The working copy is stale",
        "Hint: Run `jj workspace update-stale` to update it",
    }, "\n")

    -- Prune so the stale workspace is kept with jj's first error line
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect the workspace kept with jj's first error line
    testing.eq(code, 0, out)
    local kept = "Kept workspace "
        .. DONE_ID
        .. ". Cannot read the state of "
        .. broken
        .. ": Error: The working copy is stale."
    testing.eq(out, lines(kept, "Pruned 0 workspaces and 0 heads. Left 1 item alone."))

    -- Expect the folder intact and no jj run
    testing.eq(fs.exists(broken .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune dry-run plans a stale jj workspace without refreshing it", function()
    -- Seed a done card whose workspace is stale but readable without a refresh
    local root, dir, env = prune_setup("jj")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local stale = folder(dir, DONE_ID)
    local updates = support.tempdir() .. "/updates"
    env.env.WORKSPACES = table.concat({ "default", DONE_ID }, "\n")
    env.env.ROOTS = DONE_ID .. " " .. stale
    env.env.ERROR = "Error: The working copy is stale"
    env.env.STALE_READ = "1"
    env.env.UPDATES = updates

    -- Dry-run the prune
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

    -- Expect the removal planned and no update-stale run
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Would forget workspace " .. DONE_ID .. ". Its card is done.",
            "Would prune 1 workspace and 0 heads. Left 0 items alone."
        )
    )
    testing.eq(fs.exists(updates), false)
end)

testing.test("prune keeps a linked folder in a dry run and a real run", function()
    -- Seed a done card whose folder is a link to a folder outside the root
    local root, dir, env, log = prune_setup("jj")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local target = assert(fs.realpath(support.tempdir()))
    assert(fs.write(target .. "/file", "x"))
    assert(fs.symlink(target, dir .. DONE_ID))
    env.env.WORKSPACES = table.concat({ "default", DONE_ID }, "\n")
    env.env.ROOTS = DONE_ID .. " " .. dir .. DONE_ID
    local kept = "Kept workspace "
        .. DONE_ID
        .. ". "
        .. dir
        .. DONE_ID
        .. " is a link, not removed."

    -- Run a dry run and expect the link kept
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)
    testing.eq(code, 0, out)
    testing.eq(out, lines(kept, "Would prune 0 workspaces and 0 heads. Left 1 item alone."))

    -- Run a real run and expect the link kept again
    out, code = support.dev(root, { "ws", "prune" }, env)
    testing.eq(code, 0, out)
    testing.eq(out, lines(kept, "Pruned 0 workspaces and 0 heads. Left 1 item alone."))

    -- Expect the target intact and no jj run
    testing.eq(fs.exists(target .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune dry-run changes nothing", function()
    -- Seed a gone workspace, a done card, an empty head and a stale bookmark
    local root, dir, env, log = prune_setup("jj")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local done = folder(dir, DONE_ID)
    env.env.WORKSPACES = table.concat({ "default", "gone1", DONE_ID }, "\n")
    env.env.ROOTS = table.concat({ "gone1 " .. dir .. "gone1", DONE_ID .. " " .. done }, "\n")
    env.env.EMPTY = ("e"):rep(40) .. "\t\n"
    env.env.FREED_EMPTY = env.env.EMPTY
    env.env.BOOKMARKS = lines("old")

    -- Dry-run the prune to see every action reported as a plan
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

    -- Expect every action worded as a plan
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Would forget workspace gone1. Its folder " .. dir .. "gone1 is gone.",
            "Would forget workspace " .. DONE_ID .. ". Its card is done.",
            "Would abandon empty head eeeeeeeeeeee.",
            "Left bookmark old alone. It is not on trunk.",
            "Would prune 2 workspaces and 1 head. Left 1 item alone."
        )
    )

    -- Expect no jj run and the done folder intact
    testing.eq(fs.exists(log), false)
    testing.eq(fs.exists(done .. "/file"), true)
end)

testing.test("prune dry-run abandons the empty head a forgotten jj workspace frees", function()
    -- List a gone workspace whose forget would free an empty head
    local root, dir, env, log = prune_setup("jj")
    env.env.WORKSPACES = table.concat({ "default", "gone1" }, "\n")
    env.env.ROOTS = "gone1 " .. dir .. "gone1"
    env.env.FREED_EMPTY = ("f"):rep(40) .. "\t\n"

    -- Dry-run the prune to see the abandon of the head the forget frees
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

    -- Expect both the forget and the abandon planned
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Skipped the card test. This project has no board.",
            "Would forget workspace gone1. Its folder " .. dir .. "gone1 is gone.",
            "Would abandon empty head ffffffffffff.",
            "Would prune 1 workspace and 1 head. Left 0 items alone."
        )
    )

    -- Expect no jj run
    testing.eq(fs.exists(log), false)
end)

testing.test("prune dry-run lists the non-empty head a forgotten jj workspace frees", function()
    -- List a gone workspace whose forget would free a non-empty head
    local root, dir, env, log = prune_setup("jj")
    env.env.WORKSPACES = table.concat({ "default", "gone1" }, "\n")
    env.env.ROOTS = "gone1 " .. dir .. "gone1"
    env.env.FREED_STRAYS = ("d"):rep(40) .. "\tchore: bump\n"

    -- Dry-run the prune to see the non-empty head the forget frees left alone
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

    -- Expect the forget planned and the head left alone
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Skipped the card test. This project has no board.",
            "Would forget workspace gone1. Its folder " .. dir .. "gone1 is gone.",
            "Left non-empty head dddddddddddd (chore: bump) alone. Nothing holds it.",
            "Would prune 1 workspace and 0 heads. Left 1 item alone."
        )
    )

    -- Expect no jj run
    testing.eq(fs.exists(log), false)
end)

testing.test("prune dry-run holds the heads of a jj workspace it does not forget", function()
    -- Keep the gone1 folder so jj still has the workspace, with heads it holds
    local root, dir, env, log = prune_setup("jj")
    local path = folder(dir, "gone1")
    env.env.WORKSPACES = table.concat({ "default", "gone1" }, "\n")
    env.env.ROOTS = "gone1 " .. path
    env.env.FREED_EMPTY = ("f"):rep(40) .. "\t\n"
    env.env.FREED_STRAYS = ("d"):rep(40) .. "\tchore: bump\n"

    -- Dry-run the prune to check the heads held by a kept workspace are not planned
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

    -- Expect nothing planned for the held heads
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Skipped the card test. This project has no board.",
            "Would prune 0 workspaces and 0 heads. Left 0 items alone."
        )
    )

    -- Expect no jj run
    testing.eq(fs.exists(log), false)
end)

testing.test("prune removes git worktrees whose folder is gone or named for a done card", function()
    -- Seed a done card with a worktree folder and list a second, gone worktree
    local root, dir, env, log = prune_setup("git")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local done = dir .. DONE_ID
    assert(fs.mkdir(done, { parents = true }))
    assert(fs.write(done .. "/.git", "gitdir: elsewhere\n"))
    local gone = dir .. "gone1"
    env.env.WORKTREES = worktrees(root, gone, done)

    -- Prune so the gone worktree and the done one are both removed
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect both worktrees reported removed
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Removed worktree gone1. Its folder " .. gone .. " is gone.",
            "Removed worktree "
                .. DONE_ID
                .. ". Its card is done. Moved "
                .. done
                .. " to "
                .. trashed(env, root, DONE_ID)
                .. ".",
            "Git keeps no empty heads.",
            "Pruned 2 worktrees and 0 heads. Left 0 items alone."
        )
    )

    -- Expect one remove for the gone worktree, then a prune, and the done folder trashed
    testing.eq(
        fs.read(log),
        lines(
            "git -C " .. root .. " worktree remove " .. gone,
            "git -C " .. root .. " worktree prune"
        )
    )
    testing.eq(fs.exists(done), false)
end)

testing.test("prune keeps a dirty git worktree of a done card", function()
    -- Seed a done card with a worktree folder and make git report changes
    local root, dir, env, log = prune_setup("git")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local done = dir .. DONE_ID
    assert(fs.mkdir(done, { parents = true }))
    assert(fs.write(done .. "/.git", "gitdir: elsewhere\n"))
    env.env.WORKTREES = worktrees(root, done)
    env.env.DIRTY = " M file\n"

    -- Prune so the dirty worktree of the done card is kept
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect the worktree kept as holding changes
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Kept worktree " .. DONE_ID .. ". " .. done .. " holds changes not in a commit.",
            "Git keeps no empty heads.",
            "Pruned 0 worktrees and 0 heads. Left 1 item alone."
        )
    )

    -- Expect the folder intact and no git run
    testing.eq(fs.exists(done .. "/.git"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune keeps a locked git worktree of a done card", function()
    -- Seed a done card with a worktree folder and mark the worktree locked
    local root, dir, env, log = prune_setup("git")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local done = dir .. DONE_ID
    assert(fs.mkdir(done, { parents = true }))
    assert(fs.write(done .. "/.git", "gitdir: elsewhere\n"))
    env.env.WORKTREES = worktrees(root, done) .. "locked\n"

    -- Prune so the locked worktree of the done card is kept with its hint
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect the worktree kept with the unlock hint
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Kept worktree "
                .. DONE_ID
                .. ". "
                .. done
                .. " is a locked git worktree. Run git worktree unlock first.",
            "Git keeps no empty heads.",
            "Pruned 0 worktrees and 0 heads. Left 1 item alone."
        )
    )

    -- Expect the folder intact and no git run
    testing.eq(fs.exists(done .. "/.git"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune removes a gone worktree before a done one listed ahead of it", function()
    -- List the done worktree first and let git drop the gone record after its remove
    local root, dir, env, log = prune_setup("git")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local done = dir .. DONE_ID
    assert(fs.mkdir(done, { parents = true }))
    assert(fs.write(done .. "/.git", "gitdir: elsewhere\n"))
    local gone = dir .. "gone1"
    env.env.WORKTREES = worktrees(root, done, gone) .. "prunable gone\n"
    env.env.AFTER = worktrees(root, done)

    -- Prune with the done worktree listed first to check the gone one goes first
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect the gone worktree reported first
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Removed worktree gone1. Its folder " .. gone .. " is gone.",
            "Removed worktree "
                .. DONE_ID
                .. ". Its card is done. Moved "
                .. done
                .. " to "
                .. trashed(env, root, DONE_ID)
                .. ".",
            "Git keeps no empty heads.",
            "Pruned 2 worktrees and 0 heads. Left 0 items alone."
        )
    )

    -- Expect the gone worktree removed before the final prune
    testing.eq(
        fs.read(log),
        lines(
            "git -C " .. root .. " worktree remove " .. gone,
            "git -C " .. root .. " worktree prune"
        )
    )
end)

testing.test("prune keeps the workspace it runs in", function()
    -- Build a workspace folder named for a done card
    local root, _, env, log = prune_setup("jj")
    local base = assert(fs.realpath(support.tempdir())) .. "/ws"
    local inside = base .. "/proj/" .. DONE_ID
    assert(fs.mkdir(inside .. "/.dev", { parents = true }))
    assert(fs.mkdir(inside .. "/.jj"))

    -- Point the root at it and seed the board inside it
    env.env.DEV_WS_ROOT = base
    env.env.PATH = root .. "/bin:" .. dev_os.getenv("PATH")
    seed_board(inside, env, { { id = DONE_ID, done = true } })
    env.env.WORKSPACES = table.concat({ "default", DONE_ID }, "\n")
    env.env.ROOTS = DONE_ID .. " " .. inside

    -- Prune from inside the workspace to check it is kept
    local out, code = support.dev(inside, { "ws", "prune" }, env)

    -- Expect it kept as the workspace dev runs in
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Kept workspace " .. DONE_ID .. ". It is the workspace dev runs in.",
            "Pruned 0 workspaces and 0 heads. Left 1 item alone."
        )
    )

    -- Expect the folder intact and no jj run
    testing.eq(fs.is_dir(inside), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune dry-run changes no git worktree", function()
    -- Seed a done card with a worktree folder and list a second, gone worktree
    local root, dir, env, log = prune_setup("git")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local done = dir .. DONE_ID
    assert(fs.mkdir(done, { parents = true }))
    assert(fs.write(done .. "/.git", "gitdir: elsewhere\n"))
    local gone = dir .. "gone1"
    env.env.WORKTREES = worktrees(root, gone, done)

    -- Dry-run the prune to check no git worktree is changed
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

    -- Expect both removals worded as a plan
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Would remove worktree gone1. Its folder " .. gone .. " is gone.",
            "Would remove worktree " .. DONE_ID .. ". Its card is done.",
            "Git keeps no empty heads.",
            "Would prune 2 worktrees and 0 heads. Left 0 items alone."
        )
    )

    -- Expect no git run and the done folder intact
    testing.eq(fs.exists(log), false)
    testing.eq(fs.exists(done .. "/.git"), true)
end)

testing.test("prune leaves a done card worktree outside the ws new folder alone", function()
    -- Seed a done card whose worktree sits in a folder other than the one ws new makes
    local root, dir, env, log = prune_setup("git")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local moved = dir .. "elsewhere/" .. DONE_ID
    assert(fs.mkdir(moved, { parents = true }))
    assert(fs.write(moved .. "/.git", "gitdir: elsewhere\n"))
    env.env.WORKTREES = worktrees(root, moved)

    -- Dry-run the prune to check the worktree is named and counted
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

    -- Expect a Left line with the folder reason and nothing removed
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Left worktree " .. DONE_ID .. " alone. Its folder is not where ws new puts it.",
            "Git keeps no empty heads.",
            "Would prune 0 worktrees and 0 heads. Left 1 item alone."
        )
    )
    testing.eq(fs.exists(log), false)
    testing.eq(fs.exists(moved .. "/.git"), true)
end)

testing.test("prune dry-run keeps a locked git worktree of a done card", function()
    -- Seed a done card with a worktree folder and mark the worktree locked
    local root, dir, env, log = prune_setup("git")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local done = dir .. DONE_ID
    assert(fs.mkdir(done, { parents = true }))
    assert(fs.write(done .. "/.git", "gitdir: elsewhere\n"))
    env.env.WORKTREES = worktrees(root, done) .. "locked\n"

    -- Dry-run the prune to check the locked done worktree is kept
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

    -- Expect the worktree kept with the unlock hint
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Kept worktree "
                .. DONE_ID
                .. ". "
                .. done
                .. " is a locked git worktree. Run git worktree unlock first.",
            "Git keeps no empty heads.",
            "Would prune 0 worktrees and 0 heads. Left 1 item alone."
        )
    )

    -- Expect no git run
    testing.eq(fs.exists(log), false)
end)

testing.test(
    "prune dry-run keeps a done worktree beside a prunable sibling with a folder",
    function()
        -- Seed a done card and list a sibling worktree that git marks prunable but has a folder
        local root, dir, env, log = prune_setup("git")
        seed_board(root, env, { { id = DONE_ID, done = true } })
        local done = dir .. DONE_ID
        assert(fs.mkdir(done, { parents = true }))
        assert(fs.write(done .. "/.git", "gitdir: elsewhere\n"))
        local sibling = dir .. "sibling"
        assert(fs.mkdir(sibling, { parents = true }))
        env.env.WORKTREES = worktrees(root, done, sibling) .. "prunable gitdir file is missing\n"

        -- Dry-run the prune to check the done worktree is kept beside its sibling
        local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

        -- Expect the done worktree kept because a prune would drop the sibling's record
        testing.eq(code, 0, out)
        testing.eq(
            out,
            lines(
                "Kept worktree "
                    .. DONE_ID
                    .. ". Git worktree prune would also drop the record of "
                    .. sibling
                    .. ", which git marks prunable. Run git worktree prune first.",
                "Left worktree sibling alone. Its name is not the id of a done card.",
                "Git keeps no empty heads.",
                "Would prune 0 worktrees and 0 heads. Left 2 items alone."
            )
        )

        -- Expect no git run
        testing.eq(fs.exists(log), false)
    end
)

testing.test("prune dry-run removes a done worktree beside a prunable gone one", function()
    -- Seed a done card and list a prunable worktree whose folder is gone
    local root, dir, env, log = prune_setup("git")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local done = dir .. DONE_ID
    assert(fs.mkdir(done, { parents = true }))
    assert(fs.write(done .. "/.git", "gitdir: elsewhere\n"))
    local gone = dir .. "gone1"
    env.env.WORKTREES = worktrees(root, done, gone) .. "prunable gone\n"

    -- Dry-run the prune to see both git removals planned
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

    -- Expect both removals worded as a plan
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Would remove worktree gone1. Its folder " .. gone .. " is gone.",
            "Would remove worktree " .. DONE_ID .. ". Its card is done.",
            "Git keeps no empty heads.",
            "Would prune 2 worktrees and 0 heads. Left 0 items alone."
        )
    )

    -- Expect no git run
    testing.eq(fs.exists(log), false)
end)

testing.test("prune goes on after a failed removal and exits with its code", function()
    -- Make every git removal fail on two gone worktrees
    local root, dir, env = prune_setup("git")
    env.env.FAIL = "1"
    env.env.WORKTREES = worktrees(root, dir .. "gone1", dir .. "gone2")

    -- Prune with every git removal failing to check both are kept
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect git's code and both worktrees reported kept
    testing.eq(code, 3, out)
    testing.eq(
        out,
        lines(
            "Skipped the card test. This project has no board.",
            "Kept worktree gone1. The git command exited 3.",
            "Kept worktree gone2. The git command exited 3.",
            "Git keeps no empty heads.",
            "Pruned 0 worktrees and 0 heads. Left 2 items alone."
        )
    )
end)

testing.test("prune leaves the empty heads when the abandon fails", function()
    -- List an empty head and make jj fail
    local root, _, env = prune_setup("jj")
    env.env.FAIL = "1"
    env.env.WORKSPACES = "default"
    env.env.ROOTS = ""
    env.env.EMPTY = ("d"):rep(40) .. "\t\n"

    -- Prune with the abandon failing to check the empty head is left alone
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect jj's code and the heads reported left alone
    testing.eq(code, 3, out)
    testing.eq(
        out,
        lines(
            "Skipped the card test. This project has no board.",
            "Left the empty heads alone. The jj abandon command exited 3.",
            "Pruned 0 workspaces and 0 heads. Left 0 items alone."
        )
    )
end)

---@class ws_test.start_sleep.Opts
---@field name string? sleep when nil, the command name the process runs under

local function start_sleep(dir, opts)
    local name = opts and opts.name or "sleep"
    local program = "sleep"

    -- Link sleep under the requested name
    if name ~= "sleep" then
        local bin = support.tempdir()
        local target = dev_os.capture({ "sh", "-c", "command -v sleep" }):gsub("%s", "")
        local linked = dev_os.run({ "ln", "-s", target, bin .. "/" .. name })
        assert(linked == 0, "ln cannot link sleep as " .. name)
        program = bin .. "/" .. name
    end

    -- Start the process in the folder
    local out = dev_os.capture(
        { "sh", "-c", program .. " 60 </dev/null >/dev/null 2>&1 & echo $!" },
        { cwd = dir }
    )
    local pid = out:gsub("%s", "")

    -- Wait until the forked shell has become the sleep
    for _ = 1, SLEEP_POLLS do
        local comm = dev_os.capture({ "ps", "-o", "comm=", "-p", pid }, { stderr = "null" })
        if comm:find(name .. "%s*$") then
            break
        end
        dev_os.nap(SLEEP_POLL_SECONDS)
    end
    return pid
end

local function alive(pid)
    return dev_os.run({ "kill", "-0", pid }, { stderr = "null" }) == 0
end

local function stop(pid)
    dev_os.run({ "kill", pid }, { stderr = "null" })
end

testing.test("rm prints the pid and command of a process inside the workspace", function()
    -- Start a sleep in the workspace folder
    local root, path, env = rm_setup("jj")
    env.split = true
    local pid = start_sleep(path)

    -- Remove the workspace while the sleep runs
    local out, code, errors = support.dev(root, { "ws", "rm", "feat" }, env)
    local running = alive(pid)
    stop(pid)

    -- Expect the warning, the removal and the sleep still running
    testing.eq(code, 0, out)
    testing.eq(errors, "Process " .. pid .. " (sleep) is still inside " .. path .. ".\n")
    testing.eq(fs.exists(path), false)
    testing.eq(running, true)
end)

testing.test("rm prints no process line for an ssh inside the workspace", function()
    -- Start a process named ssh in the workspace folder
    local root, path, env = rm_setup("jj")
    env.split = true
    local pid = start_sleep(path, { name = "ssh" })

    -- Remove the workspace while it runs
    local out, code, errors = support.dev(root, { "ws", "rm", "feat" }, env)
    stop(pid)

    -- Expect the removal and no warning
    testing.eq(code, 0, out)
    testing.eq(errors, "")
    testing.eq(fs.exists(path), false)
end)

testing.test("rm prints no process line when no process is inside the workspace", function()
    -- Remove a workspace nothing runs in
    local root, _, env = rm_setup("jj")
    env.split = true
    local out, code, errors = support.dev(root, { "ws", "rm", "feat" }, env)

    -- Expect no warning on standard error
    testing.eq(code, 0, out)
    testing.eq(errors, "")
end)

local function finds_the_sleep(find)
    -- Start a sleep in a folder and look it up there
    local dir = assert(fs.realpath(support.tempdir()), "tempdir has no real path")
    local pid = start_sleep(dir)
    local found = find(dir)
    stop(pid)

    -- Expect the sleep listed once
    testing.eq(found, { { pid = pid, command = "sleep" } })
end

local function adopt_env()
    local ws = assert(fs.realpath(support.tempdir()))
    local env = {
        env = {
            DEV_WS_ROOT = ws,
            JJ_FORGE = "",
            JJ_USER = IDENT.JJ_USER,
            JJ_EMAIL = IDENT.JJ_EMAIL,
        },
    }
    return env, ws
end

if dev_os.which("jj") then
    local function adopt_jj_project()
        local root = support.sandbox({}, {})
        local init = { stdout = "null", stderr = "null", env = IDENT }
        assert(dev_os.run({ "jj", "git", "init", root }, init) == 0, "jj git init failed")
        assert(fs.write(root .. "/base", "1"))
        local _, code = real_jj(root, "commit", "-m", "base")
        testing.eq(code, 0)
        local old = assert(fs.realpath(support.tempdir())) .. "/feat"
        _, code = real_jj(root, "workspace", "add", "--name", "feat", old)
        testing.eq(code, 0)
        local env, ws = adopt_env()
        return root, old, ws .. "/" .. fs.basename(root) .. "/feat", env
    end

    local function workspace_root(root, name)
        local out = real_jj(root, "workspace", "root", "--name", name)
        return (out:gsub("\n$", ""))
    end

    testing.test("adopt moves a clean jj workspace to the central root", function()
        -- Make a jj project with a workspace outside the root and note its parent commit
        local root, old, target, env = adopt_jj_project()
        local parent = real_jj(root, "log", "-r", "feat@-", "--no-graph", "-T", "commit_id")

        -- Adopt the workspace folder
        local out, code = support.dev(root, { "ws", "adopt", old }, env)

        -- Expect the workspace forgotten and added at the target on the same parent
        testing.eq(code, 0, out)
        testing.ok(out:find("Adopted feat at " .. target .. ". ", 1, true) ~= nil, out)
        testing.eq(fs.exists(target .. "/.jj"), true)
        testing.eq(workspace_root(root, "feat"), target)
        testing.eq(real_jj(root, "log", "-r", "feat@-", "--no-graph", "-T", "commit_id"), parent)

        -- Expect the old folder in the trash, not in its place
        testing.eq(fs.exists(old), false)
        testing.eq(fs.exists(trashed(env, root, "feat") .. "/.jj"), true)
    end)

    testing.test("adopt of a jj workspace on trunk adds it on its own commit", function()
        -- Commit a file in the workspace and make that commit the trunk
        local root, old, target, env = adopt_jj_project()
        assert(fs.write(old .. "/work", "1"))
        local _, code = real_jj(old, "bookmark", "create", "tip", "-r", "@")
        testing.eq(code, 0)
        _, code = real_jj(root, "config", "set", "--repo", 'revset-aliases."trunk()"', "tip")
        testing.eq(code, 0)
        local tip = real_jj(root, "log", "-r", "tip", "--no-graph", "-T", "commit_id")

        -- Adopt the workspace folder, with dev reading the config folder jj wrote the alias to
        env.env.XDG_CONFIG_HOME = dev_os.getenv("XDG_CONFIG_HOME")
        local out, adopt_code = support.dev(root, { "ws", "adopt", old }, env)

        -- Expect the new workspace on the trunk commit with the file checked out
        testing.eq(adopt_code, 0, out)
        testing.eq(real_jj(root, "log", "-r", "feat@-", "--no-graph", "-T", "commit_id"), tip)
        testing.eq(fs.read(target .. "/work"), "1")
    end)

    testing.test("adopt refuses a jj workspace with changes and moves nothing", function()
        -- Leave a file in the workspace outside any commit
        local root, old, target, env = adopt_jj_project()
        assert(fs.write(old .. "/draft", "x"))

        -- Adopt the workspace folder
        local out, code = support.dev(root, { "ws", "adopt", old }, env)

        -- Expect the refusal, the folder in place and no workspace at the target
        testing.eq(code, 1)
        testing.eq(out, old .. " holds changes not in a commit.\n")
        testing.eq(fs.read(old .. "/draft"), "x")
        testing.eq(fs.exists(target), false)
        testing.eq(workspace_root(root, "feat"), old)
    end)

    testing.test(
        "adopt refuses a jj workspace whose commit is described and moves nothing",
        function()
            -- Describe the working-copy commit that holds a file
            local root, old, target, env = adopt_jj_project()
            assert(fs.write(old .. "/draft", "x"))
            local _, code = real_jj(old, "describe", "-m", "work")
            testing.eq(code, 0)

            -- Adopt the workspace folder
            local out, adopt_code = support.dev(root, { "ws", "adopt", old }, env)

            -- Expect the refusal, the folder in place and no workspace at the target
            testing.eq(adopt_code, 1)
            testing.eq(out, old .. " holds changes not in a commit.\n")
            testing.eq(fs.read(old .. "/draft"), "x")
            testing.eq(fs.exists(target), false)
        end
    )

    testing.test("adopt refuses a target that exists and moves nothing", function()
        -- Make the target folder before the adopt
        local root, old, target, env = adopt_jj_project()
        assert(fs.mkdir(target, { parents = true }))

        -- Adopt the workspace folder
        local out, code = support.dev(root, { "ws", "adopt", old }, env)

        -- Expect the refusal with the workspace still at its old folder
        testing.eq(code, 1)
        testing.eq(out, target .. " already exists.\n")
        testing.eq(workspace_root(root, "feat"), old)
        testing.eq(fs.exists(old .. "/.jj"), true)
    end)

    testing.test("adopt names the forgotten workspace when the add fails", function()
        -- Put a jj on PATH that fails only for workspace add
        local root, old, _, env = adopt_jj_project()
        local bin = support.tempdir()
        local script = table.concat({
            "#!/bin/sh",
            'prev=""',
            'for word in "$@"; do',
            '    if [ "$prev" = workspace ] && [ "$word" = add ]; then',
            '        echo "add refused" >&2',
            "        exit 1",
            "    fi",
            '    prev="$word"',
            "done",
            "exec " .. assert(dev_os.which("jj")) .. ' "$@"',
            "",
        }, "\n")
        assert(fs.write(bin .. "/jj", script))
        assert(dev_os.run({ "chmod", "755", bin .. "/jj" }) == 0, "chmod failed")
        env.env.PATH = bin .. ":" .. dev_os.getenv("PATH")

        -- Adopt the workspace folder
        local out, code = support.dev(root, { "ws", "adopt", old }, env)

        -- Expect the refusal naming the forgotten workspace and the old folder in place
        testing.eq(code, 1, out)
        testing.ok(out:find("workspace feat is forgotten", 1, true) ~= nil, out)
        testing.eq(fs.exists(old .. "/.jj"), true)
    end)

    testing.test("adopt says where the workspace is when the trash move fails", function()
        -- Make the trash folder of the repo a regular file
        local root, old, target, env = adopt_jj_project()
        assert(fs.mkdir(env.env.DEV_WS_ROOT .. "/.trash", { parents = true }))
        assert(fs.write(trash_dir(env, root), "not a folder"))

        -- Adopt the workspace folder
        local out, code = support.dev(root, { "ws", "adopt", old }, env)

        -- Expect the new workspace at the target and the old folder kept
        testing.eq(code, 1, out)
        testing.ok(out:find("is now at " .. target, 1, true) ~= nil, out)
        testing.ok(out:find("its old folder stays at " .. old, 1, true) ~= nil, out)
        testing.eq(fs.exists(old .. "/.jj"), true)
        testing.eq(workspace_root(root, "feat"), target)
    end)

    testing.test("adopt refuses a workspace already under the root", function()
        -- Adopt the workspace once so it sits under the root
        local root, old, target, env = adopt_jj_project()
        local _, first = support.dev(root, { "ws", "adopt", old }, env)
        testing.eq(first, 0)

        -- Adopt it again
        local out, code = support.dev(root, { "ws", "adopt", target }, env)

        -- Expect the refusal and the workspace where it is
        testing.eq(code, 1)
        testing.eq(out, target .. " is already under " .. env.env.DEV_WS_ROOT .. ".\n")
        testing.eq(workspace_root(root, "feat"), target)
    end)

    testing.test("adopt refuses a folder that is not a workspace of the project", function()
        -- Pick a folder that no workspace of the project holds
        local root, _, _, env = adopt_jj_project()
        local stray = assert(fs.realpath(support.tempdir()))

        -- Adopt the stray folder and a path that does not exist
        local out, code = support.dev(root, { "ws", "adopt", stray }, env)
        local gone, gone_code = support.dev(root, { "ws", "adopt", stray .. "/none" }, env)

        -- Expect both refused and the stray folder left in place
        testing.eq(code, 1)
        testing.eq(out, stray .. " is not a workspace folder.\n")
        testing.eq(gone_code, 1)
        testing.eq(gone, stray .. "/none is not a workspace folder.\n")
        testing.eq(fs.is_dir(stray), true)
    end)
end

if dev_os.which("git") then
    testing.test("adopt moves a git worktree with git worktree move", function()
        -- Make a git project with a worktree outside the root and a change in it
        local root = support.sandbox({}, {})
        local quiet = { stdout = "null", stderr = "null" }
        assert(dev_os.run({ "git", "init", "-q", root }, quiet) == 0, "git init failed")
        local made = dev_os.run({
            "git",
            "-C",
            root,
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.com",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            "base",
        }, quiet)
        testing.eq(made, 0)
        local old = assert(fs.realpath(support.tempdir())) .. "/feat"
        local added = dev_os.run({ "git", "-C", root, "worktree", "add", "-q", "-b", "feat", old })
        testing.eq(added, 0)
        assert(fs.write(old .. "/draft", "x"))
        local env, ws = adopt_env()
        local target = ws .. "/" .. fs.basename(root) .. "/feat"

        -- Adopt the worktree folder
        local out, code = support.dev(root, { "ws", "adopt", old }, env)

        -- Expect the folder moved with its change and git listing the new path
        testing.eq(code, 0, out)
        testing.eq(out, "Moved " .. old .. " to " .. target .. ".\n")
        testing.eq(fs.read(target .. "/draft"), "x")
        testing.eq(fs.exists(old), false)
        local listed = dev_os.capture({ "git", "-C", root, "worktree", "list", "--porcelain" })
        testing.ok(listed:find("worktree " .. target, 1, true) ~= nil, listed)
    end)
end

testing.test("adopt needs one PATH", function()
    local root, _, env = setup("none")
    for _, case in ipairs({
        { { "ws", "adopt" }, "dev ws adopt: The argument path is required.\n" },
        { { "ws", "adopt", "a", "b" }, "dev ws adopt: Unexpected argument b.\n" },
        { { "ws", "adopt", "-x" }, "dev ws adopt: Unknown flag -x.\n" },
    }) do
        local out, code = support.dev(root, case[1], env)
        testing.eq(code, 2)
        testing.eq(out:match("^[^\n]*\n"), case[2])
    end
end)

testing.test("describe writes a sentence for every refusal", function()
    local why = {
        path = "/w/card",
        name = "card",
        base = "/w",
        command = "jj",
        code = 3,
        detail = "no such file",
    }
    local seen = 0
    for _, reason in pairs(cmd_ws.Refusal) do
        why.reason = reason
        local text = cmd_ws.describe(why)
        testing.ok(text:find("^[%u/]") and text:find("%.$"), reason .. ": " .. text)
        seen = seen + 1
    end
    testing.eq(seen, 19)
    testing.eq(
        cmd_ws.describe({ reason = cmd_ws.Refusal.LINK, path = "/w/card" }),
        "/w/card is a link, not removed."
    )
    testing.eq(
        cmd_ws.describe({ reason = cmd_ws.Refusal.COMMAND_FAILED, command = "git", code = 3 }),
        "The git command exited 3."
    )
end)

if fs.is_dir("/proc/self") then
    testing.test("the proc lookup finds a process by its working directory", function()
        finds_the_sleep(cmd_ws.__processes_proc)
    end)
end

if dev_os.which("lsof") then
    testing.test("the lsof lookup finds a process by its working directory", function()
        finds_the_sleep(cmd_ws.__processes_lsof)
    end)
end

if dev_os.which("jj") then
    local function foreign_workspace()
        local env, base = adopt_env()
        local root = support.sandbox({}, {})
        local init = { stdout = "null", stderr = "null", env = IDENT }
        assert(dev_os.run({ "jj", "git", "init", root }, init) == 0, "jj git init failed")
        assert(fs.write(root .. "/base", "1"))
        local _, code = real_jj(root, "commit", "-m", "base")
        testing.eq(code, 0)
        local path = base .. "/elsewhere/feat"
        assert(fs.mkdir(base .. "/elsewhere", { parents = true }))
        _, code = real_jj(root, "workspace", "add", "--name", "feat", "-r", "@-", path)
        testing.eq(code, 0)
        return root, path, env, base
    end

    testing.test("rm removes a jj workspace made under another repo folder name", function()
        local root, path, env, base = foreign_workspace()

        local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

        testing.eq(code, 0, out)
        testing.ok(
            out:find("Moved " .. path .. " to " .. base .. "/.trash/elsewhere/feat-", 1, true),
            out
        )
        testing.eq(fs.exists(path), false)
        testing.eq(real_jj(root, "workspace", "list"):find("feat:", 1, true), nil)
    end)

    local function sibling_workspace()
        local env, base = adopt_env()
        local main = base .. "/elsewhere/main"
        assert(fs.mkdir(main, { parents = true }))
        local init = { stdout = "null", stderr = "null", env = IDENT }
        assert(dev_os.run({ "jj", "git", "init", main }, init) == 0, "jj git init failed")
        assert(fs.write(main .. "/base", "1"))
        local _, code = real_jj(main, "commit", "-m", "base")
        testing.eq(code, 0)
        assert(fs.mkdir(base .. "/mine", { parents = true }))
        local sibling = base .. "/mine/lead"
        _, code = real_jj(main, "workspace", "add", "--name", "lead", "-r", "@-", sibling)
        testing.eq(code, 0)
        return main, sibling, env, base
    end

    testing.test("rm by name from a sibling workspace finds another repo folder", function()
        local main, sibling, env, base = sibling_workspace()
        local path = base .. "/elsewhere/feat"
        local _, code = real_jj(main, "workspace", "add", "--name", "feat", "-r", "@-", path)
        testing.eq(code, 0)

        local out, rm_code = support.dev(sibling, { "ws", "rm", "feat" }, env)

        testing.eq(rm_code, 0, out)
        testing.eq(fs.exists(path), false)
    end)

    testing.test("rm by name from a sibling workspace refuses a name jj does not list", function()
        local _, sibling, env, base = sibling_workspace()

        local out, rm_code = support.dev(sibling, { "ws", "rm", "nope" }, env)

        testing.eq(rm_code, 1, out)
        testing.eq(out, base .. "/mine/nope is not a workspace folder.\n")
    end)

    testing.test("rm forgets a jj workspace while the main checkout is stale", function()
        local root, path, env = foreign_workspace()
        local before =
            real_jj(root, "--ignore-working-copy", "op", "log", "--no-graph", "-n", "1", "-T", "id")
        local _, code = real_jj(root, "new")
        testing.eq(code, 0)
        assert(fs.write(root .. "/second", "2"))
        _, code = real_jj(root, "status")
        testing.eq(code, 0)
        _, code = real_jj(path, "--ignore-working-copy", "op", "restore", before)
        testing.eq(code, 0)
        local status = real_jj(root, "status")
        testing.ok(status:find("The working copy is stale", 1, true) ~= nil, status)

        local out, rm_code = support.dev(root, { "ws", "rm", "feat" }, env)

        testing.eq(rm_code, 0, out)
        testing.eq(fs.exists(path), false)
    end)

    testing.test("rm names the jj message and keeps the folder when the forget fails", function()
        local root, path, env = foreign_workspace()
        local bin = support.tempdir()
        local script = table.concat({
            "#!/bin/sh",
            'for word in "$@"; do',
            '    if [ "$word" = forget ]; then',
            '        echo "forget refused" >&2',
            "        exit 1",
            "    fi",
            "done",
            "exec " .. assert(dev_os.which("jj")) .. ' "$@"',
            "",
        }, "\n")
        assert(fs.write(bin .. "/jj", script))
        assert(dev_os.run({ "chmod", "755", bin .. "/jj" }) == 0, "chmod failed")
        env.env.PATH = bin .. ":" .. dev_os.getenv("PATH")

        local out, code = support.dev(root, { "ws", "rm", "feat" }, env)

        testing.eq(code, 1, out)
        testing.eq(out, "The jj command exited 1: forget refused.\n")
        testing.eq(fs.is_dir(path), true)
    end)

    local function refuses_listed(place)
        local root, _, env, base = foreign_workspace()
        local target = place(base) .. "/other"
        fs.mkdir(fs.dirname(target), { parents = true })
        local _, code = real_jj(root, "workspace", "add", "--name", "other", "-r", "@-", target)
        testing.eq(code, 0)

        local out, rm_code = support.dev(root, { "ws", "rm", "other" }, env)

        testing.eq(rm_code, 1, out)
        testing.eq(fs.is_dir(target), true)
        testing.ok(real_jj(root, "workspace", "list"):find("other:", 1, true) ~= nil)
    end

    testing.test("rm refuses a listed jj workspace at the wrong depth", function()
        refuses_listed(function(base)
            return base .. "/deep/er"
        end)
    end)

    testing.test("rm refuses a listed jj workspace outside the central root", function()
        refuses_listed(function()
            return assert(fs.realpath(support.tempdir())) .. "/x"
        end)
    end)

    testing.test("rm refuses a listed jj workspace through a link to outside the root", function()
        refuses_listed(function(base)
            local outside = assert(fs.realpath(support.tempdir()))
            assert(fs.symlink(outside, base .. "/linked"))
            return base .. "/linked"
        end)
    end)
end

if dev_os.which("jj") then
    local function head_ids(root, revset)
        local out = real_jj(root, "log", "-r", revset, "--no-graph", "-T", 'commit_id ++ "\\n"')
        return out
    end

    local function landed_project()
        local root = support.sandbox({}, {})
        local init = { stdout = "null", stderr = "null", env = IDENT }
        assert(dev_os.run({ "jj", "git", "init", root }, init) == 0, "jj git init failed")
        assert(fs.write(root .. "/base", "1"))
        real_jj(root, "commit", "-m", "base")
        local base = real_jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id")
        local function change(parent, message, file, text)
            real_jj(root, "new", parent, "-m", message)
            assert(fs.write(root .. "/" .. file, text))
            return (real_jj(root, "log", "-r", "@", "--no-graph", "-T", "commit_id"))
        end
        change(base, "feat: one\n\nChange-Id: I1111111111111111111111111111111111111111", "t1", "1")
        change("@", "feat: two", "t2", "2")
        real_jj(root, "bookmark", "create", "tip", "-r", "@")
        real_jj(root, "config", "set", "--repo", 'revset-aliases."trunk()"', "tip")
        local by_trailer = change(
            base,
            "feat: one, rewritten\n\nChange-Id: I1111111111111111111111111111111111111111",
            "other",
            "x"
        )
        local by_title = change(base, "feat: two", "t2", "2")
        local unlanded = change(base, "feat: three", "t3", "3")
        real_jj(root, "new", "tip")
        local env = adopt_env()
        env.env.XDG_CONFIG_HOME = dev_os.getenv("XDG_CONFIG_HOME")
        return root, env, { trailer = by_trailer, title = by_title, unlanded = unlanded }
    end

    testing.test("prune abandons a head whose change id or title and diff is on trunk", function()
        -- Hold a rewritten copy by Change-Id, one by title and diff, and one unlanded head
        local root, env, heads = landed_project()

        -- Prune so the landed heads go and the unlanded one stays
        local out, code = support.dev(root, { "ws", "prune" }, env)

        -- Expect both landed heads abandoned and the unlanded head listed and kept
        testing.eq(code, 0, out)
        testing.ok(out:find("Abandoned landed head " .. heads.trailer:sub(1, 12), 1, true), out)
        testing.ok(out:find("Abandoned landed head " .. heads.title:sub(1, 12), 1, true), out)
        testing.ok(out:find("Left non-empty head " .. heads.unlanded:sub(1, 12), 1, true), out)
        testing.ok(out:find("Pruned 0 workspaces and 2 heads. Left 1 item alone.", 1, true), out)
        testing.eq(head_ids(root, "all()"):find(heads.trailer, 1, true), nil)
        testing.eq(head_ids(root, "all()"):find(heads.title, 1, true), nil)
        testing.ok(head_ids(root, heads.unlanded):find(heads.unlanded, 1, true) ~= nil)
    end)

    testing.test("prune dry-run lists the landed heads and abandons none", function()
        -- Hold the same landed and unlanded heads
        local root, env, heads = landed_project()

        -- Plan the prune
        local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

        -- Expect the plan to name the landed heads and the heads left in place
        testing.eq(code, 0, out)
        testing.ok(out:find("Would abandon landed head " .. heads.trailer:sub(1, 12), 1, true), out)
        testing.ok(out:find("Would abandon landed head " .. heads.title:sub(1, 12), 1, true), out)
        testing.eq(out:find("Left non-empty head " .. heads.title:sub(1, 12), 1, true), nil)
        testing.ok(head_ids(root, heads.trailer):find(heads.trailer, 1, true) ~= nil)
        testing.ok(head_ids(root, heads.title):find(heads.title, 1, true) ~= nil)
    end)

    testing.test("prune leaves the landed heads and exits 1 when the abandon fails", function()
        -- Hold the landed heads and put a jj in front that refuses to abandon
        local root, env, heads = landed_project()
        local bin = support.tempdir()
        local script = table.concat({
            "#!/bin/sh",
            'for word in "$@"; do',
            '    if [ "$word" = abandon ]; then',
            '        echo "abandon refused" >&2',
            "        exit 1",
            "    fi",
            "done",
            "exec " .. assert(dev_os.which("jj")) .. ' "$@"',
            "",
        }, "\n")
        assert(fs.write(bin .. "/jj", script))
        assert(dev_os.run({ "chmod", "755", bin .. "/jj" }) == 0, "chmod failed")
        env.env.PATH = bin .. ":" .. dev_os.getenv("PATH")

        -- Prune so the abandon fails
        local out, code = support.dev(root, { "ws", "prune" }, env)

        -- Expect the failure code, the heads reported left alone and both still present
        testing.eq(code, 1, out)
        testing.ok(out:find("Left the landed heads alone.", 1, true), out)
        testing.ok(head_ids(root, heads.trailer):find(heads.trailer, 1, true) ~= nil)
        testing.ok(head_ids(root, heads.title):find(heads.title, 1, true) ~= nil)
    end)
end

local function branch_project()
    local root = support.sandbox({}, {})
    local code = dev_os.run({ "git", "init", "-q", "-b", "main", root }, { stdout = "null" })
    assert(code == 0, "git init failed")
    assert(fs.write(root .. "/base", "1"))
    support.git(root, "add", "-A")
    support.git(root, "commit", "-q", "-m", "base")
    support.git(root, "branch", "merged")
    support.git(root, "checkout", "-q", "-b", "unmerged")
    assert(fs.write(root .. "/work", "1"))
    support.git(root, "add", "-A")
    support.git(root, "commit", "-q", "-m", "feat: work")
    support.git(root, "checkout", "-q", "main")
    local env = adopt_env()
    return root, env
end

local function has_branch(root, name)
    local out = dev_os.capture({ "git", "-C", root, "branch", "--list", name })
    return out:match("%S") ~= nil
end

testing.test("prune deletes a git branch merged into trunk and keeps an unmerged one", function()
    -- Hold one branch on trunk and one with its own commit
    local root, env = branch_project()

    -- Prune so the merged branch is deleted
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect the merged branch gone and the unmerged one listed and kept
    testing.eq(code, 0, out)
    testing.ok(out:find("Deleted merged branch merged.", 1, true), out)
    testing.ok(out:find("Left branch unmerged alone. It is not on trunk.", 1, true), out)
    testing.ok(out:find("Pruned 0 worktrees and 1 head. Left 1 item alone.", 1, true), out)
    testing.eq(has_branch(root, "merged"), false)
    testing.eq(has_branch(root, "unmerged"), true)
    testing.eq(has_branch(root, "main"), true)
end)

testing.test("prune keeps a merged git branch a worktree has checked out", function()
    -- Hold a merged branch checked out in a live worktree
    local root, env = branch_project()
    local dir = support.tempdir() .. "/held"
    support.git(root, "worktree", "add", "-q", "-b", "held", dir, "main")

    -- Prune so the merged branch goes and the checked-out one stays
    local out, code = support.dev(root, { "ws", "prune" }, env)

    -- Expect no failure and the held branch listed as left alone
    testing.eq(code, 0, out)
    testing.ok(out:find("Left branch held alone. A worktree has it checked out.", 1, true), out)
    testing.eq(has_branch(root, "held"), true)
    testing.eq(has_branch(root, "merged"), false)
end)

testing.test("prune dry-run names the merged git branch and deletes nothing", function()
    -- Hold the same branches
    local root, env = branch_project()

    -- Plan the prune
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

    -- Expect the plan to name the branch while it stays
    testing.eq(code, 0, out)
    testing.ok(out:find("Would delete merged branch merged.", 1, true), out)
    testing.eq(has_branch(root, "merged"), true)
end)

if dev_os.which("jj") then
    local function gone_workspace(change)
        local env, base = adopt_env()
        local root = support.sandbox({}, {})
        local init = { stdout = "null", stderr = "null", env = IDENT }
        assert(dev_os.run({ "jj", "git", "init", root }, init) == 0, "jj git init failed")
        assert(fs.write(root .. "/base", "1"))
        local _, code = real_jj(root, "commit", "-m", "base")
        testing.eq(code, 0)
        local path = base .. "/elsewhere/gone"
        assert(fs.mkdir(base .. "/elsewhere", { parents = true }))
        _, code = real_jj(root, "workspace", "add", "--name", "gone", "-r", "@-", path)
        testing.eq(code, 0)
        if change then
            assert(fs.write(path .. "/work", "1"))
        end
        local head = real_jj(path, "log", "-r", "@", "--no-graph", "-T", "commit_id")
        assert(fs.remove(path, { recursive = true }))
        return root, path, env, head
    end

    local function all_ids(root)
        return real_jj(root, "log", "-r", "all()", "--no-graph", "-T", 'commit_id ++ "\\n"')
    end

    testing.test("prune keeps a gone jj workspace whose working copy holds changes", function()
        -- Lose the folder of a workspace that held an undescribed change
        local root, path, env, head = gone_workspace(true)

        -- Prune so the gone workspace is judged
        local out, code = support.dev(root, { "ws", "prune" }, env)

        -- Expect the workspace named and kept, with its working copy still there
        testing.eq(code, 0, out)
        local kept = "Kept workspace gone. " .. path .. " holds changes not in a commit"
        testing.ok(out:find(kept, 1, true), out)
        testing.ok(real_jj(root, "workspace", "list"):find("gone:", 1, true) ~= nil)
        testing.ok(all_ids(root):find(head, 1, true) ~= nil)
    end)

    testing.test("prune dry-run keeps a gone jj workspace that holds changes", function()
        -- Lose the folder of a workspace that held an undescribed change
        local root, path, env = gone_workspace(true)

        -- Plan the prune
        local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)

        -- Expect the plan to name the workspace as kept
        testing.eq(code, 0, out)
        local kept = "Kept workspace gone. " .. path .. " holds changes not in a commit"
        testing.ok(out:find(kept, 1, true), out)
        testing.ok(real_jj(root, "workspace", "list"):find("gone:", 1, true) ~= nil)
    end)

    testing.test("prune forgets an empty gone jj workspace and leaves no head", function()
        -- Lose the folder of a workspace whose working copy is empty
        local root, _, env, head = gone_workspace(false)

        -- Prune so the gone workspace is forgotten
        local out, code = support.dev(root, { "ws", "prune" }, env)

        -- Expect the workspace forgotten and its working-copy commit gone
        testing.eq(code, 0, out)
        testing.ok(out:find("Forgot workspace gone.", 1, true), out)
        testing.eq(real_jj(root, "workspace", "list"):find("gone:", 1, true), nil)
        testing.eq(all_ids(root):find(head, 1, true), nil)
    end)
end
