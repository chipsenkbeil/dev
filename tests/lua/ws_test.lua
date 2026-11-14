local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local DONE_ID = "aaaaaaaa"
local OPEN_ID = "bbbbbbbb"

local JJ_STUB = [[#!/bin/sh
if [ "$1" = "--no-pager" ]; then shift; fi
if [ "$1" = root ]; then pwd; exit 0; fi
case "$*" in
    *" git root") echo .git; exit 0 ;;
    *" git remote list") printf '%s' "$REMOTES"; exit 0 ;;
    *" git fetch "*) echo "jj $*" >> "$LOG"; printf '%s' "$FETCH_OUT"; exit "${FETCH_CODE:-0}" ;;
esac
echo "jj $*" >> "$LOG"
mkdir -p "$(eval echo \$$#)"
]]
local GIT_STUB = [[#!/bin/sh
case "$*" in
    *"--show-toplevel"*) pwd; exit 0 ;;
    *"--git-common-dir"*) echo .git; exit 0 ;;
    *" remote") printf '%s' "$REMOTES"; exit 0 ;;
    *"config --get"*) exit 1 ;;
    *" fetch "*) echo "git $*" >> "$LOG"; printf '%s' "$FETCH_OUT"; exit "${FETCH_CODE:-0}" ;;
    *"for-each-ref"*) printf '%s' "$REFS"; exit 0 ;;
esac
echo "git $*" >> "$LOG"
mkdir -p "$(eval echo \$$#)"
]]
local NO_GIT = "#!/bin/sh\nexit 1\n"

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
    local root, path, env, log = setup("jj")
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    testing.eq(code, 0)
    testing.eq(out, path .. "\n")
    testing.eq(
        fs.read(log),
        "jj --color never -R "
            .. root
            .. " git fetch --remote origin\n"
            .. "jj -R "
            .. root
            .. " workspace add --name feat -r trunk() "
            .. path
            .. "\n"
    )
end)

testing.test("new in a jj project fetches the gerrit remote of record", function()
    local root, path, env, log = setup("jj")
    env.env.JJ_FORGE = "gerrit"
    env.env.REMOTES = "origin\ngerrit\n"
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    testing.eq(code, 0)
    testing.eq(out, path .. "\n")
    testing.eq(
        fs.read(log),
        "jj --color never -R "
            .. root
            .. " git fetch --remote gerrit\n"
            .. "jj -R "
            .. root
            .. " workspace add --name feat -r trunk() "
            .. path
            .. "\n"
    )
end)

testing.test("new in a jj project stops at a failed fetch with no workspace", function()
    local root, path, env, log = setup("jj")
    env.env.FETCH_CODE = "1"
    env.env.FETCH_OUT = "error: could not connect\n"
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(out, "The fetch from origin failed: error: could not connect.\n")
    testing.eq(fs.read(log), "jj --color never -R " .. root .. " git fetch --remote origin\n")
    testing.eq(fs.exists(path), false)
    testing.eq(fs.exists(fs.dirname(path)), false)
end)

testing.test("new in a jj project refuses a missing remote of record", function()
    local root, path, env, log = setup("jj")
    env.env.REMOTES = ""
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(
        out,
        "Trunk cannot be compared: the remote of record origin is not a remote of this project (detected: no gerrit remote and origin is not on github.com).\n"
    )
    testing.eq(fs.exists(log), false)
    testing.eq(fs.exists(path), false)
end)

testing.test("new in a git project adds a worktree on the fetched trunk", function()
    local root, path, env, log = setup("git")
    env.env.REFS = "origin/HEAD\norigin/feat\norigin/main\n"
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
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
    local root, path, env, log = setup("git")
    env.env.FETCH_CODE = "1"
    env.env.FETCH_OUT = "fatal: could not connect\n"
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(out, "The fetch from origin failed: fatal: could not connect.\n")
    testing.eq(fs.read(log), "git -C " .. root .. " fetch origin\n")
    testing.eq(fs.exists(path), false)
    testing.eq(fs.exists(fs.dirname(path)), false)
end)

testing.test("new in a git project refuses a remote with no trunk branch", function()
    local root, path, env, log = setup("git")
    env.env.REFS = "origin/dev\n"
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(out, "Origin has no master or main branch.\n")
    testing.eq(fs.read(log), "git -C " .. root .. " fetch origin\n")
    testing.eq(fs.exists(path), false)
end)

testing.test("new in a git project refuses a missing remote of record", function()
    local root, path, env, log = setup("git")
    env.env.REMOTES = ""
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(
        out,
        "Trunk cannot be compared: the remote of record origin is not a remote of this project (detected: no gerrit remote and origin is not on github.com).\n"
    )
    testing.eq(fs.exists(log), false)
    testing.eq(fs.exists(path), false)
end)

testing.test("new outside version control makes a plain folder", function()
    local root, path, env = setup("none")
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    testing.eq(code, 0)
    testing.eq(out, path .. "\n")
    testing.eq(fs.is_dir(path), true)
end)

testing.test("new outside a project refuses and makes no workspace", function()
    local root, _, env = setup("none")
    local bare = assert(fs.realpath(support.tempdir()))
    env.cwd = bare
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(out, bare .. " is not inside a project.\n")
    testing.eq(fs.exists(env.env.DEV_WS_ROOT), false)
end)

testing.test("new refuses a path that exists", function()
    local root, path, env, log = setup("jj")
    assert(fs.mkdir(path, { parents = true }))
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(out, path .. " already exists.\n")
    testing.eq(fs.exists(log), false)
end)

testing.test("DEV_WS_ROOT moves the root and the default is under HOME", function()
    local root, _, env = setup("none")
    local home = support.tempdir()
    env.env.DEV_WS_ROOT = ""
    env.env.HOME = home
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    testing.eq(code, 0)
    testing.eq(out, home .. "/.local/share/workspaces/" .. fs.basename(root) .. "/feat\n")
end)

testing.test("new needs one plain NAME", function()
    local root, _, env = setup("none")
    for _, case in ipairs({
        { { "ws", "new" }, "dev ws new: needs a NAME\n" },
        { { "ws", "new", "a", "b" }, "dev ws new: takes one NAME, got b\n" },
        { { "ws", "new", "a/b" }, "dev ws new: NAME is one folder name, got a/b\n" },
        { { "ws", "new", "-x" }, "dev ws new: unknown flag -x\n" },
    }) do
        local out, code = support.dev(root, case[1], env)
        testing.eq(code, 2)
        testing.eq(out, case[2])
    end
end)

testing.test(
    "new from a workspace inside the root names the repo by the folder below the root",
    function()
        local root, _, env = setup("none")
        local base = assert(fs.realpath(support.tempdir())) .. "/ws"
        local inside = base .. "/proj/first"
        assert(fs.mkdir(inside .. "/.dev", { parents = true }))
        assert(fs.mkdir(inside .. "/bin"))
        env.env.DEV_WS_ROOT = base
        env.env.PATH = root .. "/bin:" .. os.getenv("PATH")
        local out, code = support.dev(inside, { "ws", "new", "feat" }, env)
        testing.eq(code, 0)
        testing.eq(out, base .. "/proj/feat\n")
    end
)

local RM_JJ_STUB = [[#!/bin/sh
if [ "$1" = "--no-pager" ]; then shift; fi
case "$*" in
    root) pwd; exit 0 ;;
    *"workspace list"*) printf '%s\n' "$WORKSPACES"; exit 0 ;;
    *" log "*) printf '%s' "$DIRTY"; exit "${LOG_CODE:-0}" ;;
esac
echo "jj $*" >> "$LOG"
]]
local RM_GIT_STUB = [[#!/bin/sh
case "$*" in
    *"--show-toplevel"*) pwd; exit 0 ;;
    *"--git-common-dir"*) echo .git; exit 0 ;;
    *"status --porcelain"*) printf '%s' "$DIRTY"; exit 0 ;;
esac
echo "git $*" >> "$LOG"
for last; do :; done
rm -rf "$last"
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

testing.test("ls prints each workspace folder with its path", function()
    local root, path, env = setup("none")
    assert(fs.mkdir(path, { parents = true }))
    assert(fs.mkdir(fs.dirname(path) .. "/other"))
    assert(fs.write(fs.dirname(path) .. "/stray", "x"))
    local out, code = support.dev(root, { "ws", "ls" }, env)
    testing.eq(code, 0)
    testing.eq(out, "feat\t" .. path .. "\nother\t" .. fs.dirname(path) .. "/other\n")
end)

testing.test("ls prints nothing when the project has no workspaces", function()
    local root, _, env = setup("none")
    local out, code = support.dev(root, { "ws", "ls" }, env)
    testing.eq(code, 0)
    testing.eq(out, "")
end)

testing.test("ls takes no arguments", function()
    local root, _, env = setup("none")
    local out, code = support.dev(root, { "ws", "ls", "x" }, env)
    testing.eq(code, 2)
    testing.eq(out, "dev ws ls: takes no arguments, got x\n")
end)

testing.test("rm forgets a jj workspace and deletes its folder", function()
    local root, path, env, log = rm_setup("jj")
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 0)
    testing.eq(out, "removed " .. path .. "\n")
    testing.eq(fs.read(log), "jj -R " .. root .. " workspace forget feat\n")
    testing.eq(fs.exists(path), false)
end)

testing.test("ws rm refuses a forgotten folder without --forgotten", function()
    local root, path, env, log = rm_setup("jj")
    env.env.WORKSPACES = "default"
    env.env.LOG_CODE = "1"
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(
        out,
        path
            .. " is a jj folder jj no longer tracks. Run dev ws rm feat --forgotten to discard it.\n"
    )
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("ws rm --forgotten removes a forgotten folder", function()
    local root, path, env, log = rm_setup("jj")
    env.env.WORKSPACES = "default"
    env.env.LOG_CODE = "1"
    local out, code = support.dev(root, { "ws", "rm", "feat", "--forgotten" }, env)
    testing.eq(code, 0)
    testing.eq(out, "removed " .. path .. "\n")
    testing.eq(fs.exists(log), false)
    testing.eq(fs.exists(path), false)
end)

local NOT_FORGOTTEN = " is not a jj folder jj no longer lists. --forgotten does not apply.\n"

testing.test("ws rm --forgotten refuses a folder jj still lists", function()
    local root, path, env, log = rm_setup("jj")
    local out, code = support.dev(root, { "ws", "rm", "--forgotten", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(out, path .. NOT_FORGOTTEN)
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("ws rm --forgotten refuses a git worktree", function()
    local root, path, env, log = rm_setup("git")
    local out, code = support.dev(root, { "ws", "rm", "feat", "--forgotten" }, env)
    testing.eq(code, 1)
    testing.eq(out, path .. NOT_FORGOTTEN)
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("ws rm removes a stray file", function()
    local root, path, env, log = rm_setup("jj")
    local stray = fs.dirname(path) .. "/check.log"
    assert(fs.write(stray, "x"))
    local out, code = support.dev(root, { "ws", "rm", "check.log" }, env)
    testing.eq(code, 0)
    testing.eq(out, "removed " .. stray .. "\n")
    testing.eq(fs.exists(stray), false)
    testing.eq(fs.exists(log), false)
    testing.eq(fs.is_dir(path), true)
end)

testing.test("ws rm still refuses a folder with uncommitted changes", function()
    local root, path, env, log = rm_setup("jj")
    env.env.DIRTY = "changes"
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(out, path .. " holds changes not in a commit.\n")
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("rm removes a git worktree and its folder", function()
    local root, path, env, log = rm_setup("git")
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 0)
    testing.eq(out, "removed " .. path .. "\n")
    testing.eq(fs.read(log), "git -C " .. root .. " worktree remove " .. path .. "\n")
    testing.eq(fs.exists(path), false)
end)

testing.test("rm deletes a plain folder", function()
    local root, path, env, log = rm_setup("none")
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 0)
    testing.eq(out, "removed " .. path .. "\n")
    testing.eq(fs.exists(path), false)
    testing.eq(fs.exists(log), false)
end)

testing.test("rm refuses a jj workspace with changes and leaves it in place", function()
    local root, path, env, log = rm_setup("jj")
    env.env.DIRTY = "changes"
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(out, path .. " holds changes not in a commit.\n")
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("rm refuses a git worktree with changes and leaves it in place", function()
    local root, path, env, log = rm_setup("git")
    env.env.DIRTY = " M file\n"
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(out, path .. " holds changes not in a commit.\n")
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("rm leaves a workspace whose state cannot be read", function()
    local root, path, env, log = rm_setup("jj")
    env.env.LOG_CODE = "1"
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(out, "Cannot read the state of " .. path .. ".\n")
    testing.eq(fs.exists(path .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("rm leaves the folder when the version control command fails", function()
    local root, path, env = rm_setup("git")
    stub(
        root,
        "git",
        '#!/bin/sh\ncase "$*" in *--git-common-dir*) echo .git; exit 0;; *--show-toplevel*) pwd; exit 0;; *status*) exit 0;; esac\nexit 3\n'
    )
    local _, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 3)
    testing.eq(fs.exists(path .. "/file"), true)
end)

testing.test("rm refuses a missing workspace", function()
    local root, path, env = rm_setup("none")
    assert(fs.remove(path, { recursive = true }))
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(out, path .. " is not a workspace folder.\n")
end)

testing.test("rm refuses a link that points outside the root and deletes nothing", function()
    local root, path, env = rm_setup("none")
    local outside = assert(fs.realpath(support.tempdir()))
    assert(fs.write(outside .. "/precious", "x"))
    assert(fs.remove(path, { recursive = true }))
    assert(fs.symlink(outside, path))
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(out, path .. " is a link, not removed.\n")
    testing.eq(fs.exists(outside .. "/precious"), true)
    testing.eq(fs.is_link(path), true)
end)

testing.test("rm refuses a link inside the root as well", function()
    local root, path, env = rm_setup("none")
    local target = fs.dirname(path) .. "/real"
    assert(fs.mkdir(target))
    assert(fs.write(target .. "/keep", "x"))
    assert(fs.symlink(target, fs.dirname(path) .. "/alias"))
    local _, code = support.dev(root, { "ws", "rm", "alias" }, env)
    testing.eq(code, 1)
    testing.eq(fs.exists(target .. "/keep"), true)
end)

testing.test("rm refuses a NAME that is not one folder name", function()
    local root, path, env = rm_setup("none")
    for _, case in ipairs({
        { { "ws", "rm" }, "dev ws rm: needs a NAME\n" },
        { { "ws", "rm", ".." }, "dev ws rm: NAME is one folder name, got ..\n" },
        { { "ws", "rm", "" }, "dev ws rm: NAME is one folder name, got \n" },
        { { "ws", "rm", "../feat" }, "dev ws rm: NAME is one folder name, got ../feat\n" },
        { { "ws", "rm", "/etc" }, "dev ws rm: NAME is one folder name, got /etc\n" },
        { { "ws", "rm", "a", "b" }, "dev ws rm: takes one NAME, got b\n" },
        { { "ws", "rm", "-x" }, "dev ws rm: unknown flag -x\n" },
    }) do
        local out, code = support.dev(root, case[1], env)
        testing.eq(code, 2)
        testing.eq(out, case[2])
    end
    testing.eq(fs.exists(path .. "/file"), true)
end)

testing.test("rm refuses the workspace it runs in", function()
    local root, _, env = setup("none")
    local base = assert(fs.realpath(support.tempdir())) .. "/ws"
    local inside = base .. "/proj/first"
    assert(fs.mkdir(inside .. "/.dev", { parents = true }))
    assert(fs.mkdir(inside .. "/bin"))
    env.env.DEV_WS_ROOT = base
    env.env.PATH = root .. "/bin:" .. os.getenv("PATH")
    local out, code = support.dev(inside, { "ws", "rm", "first" }, env)
    testing.eq(code, 1)
    testing.eq(out, inside .. " is the workspace dev runs in.\n")
    testing.eq(fs.is_dir(inside), true)
end)

testing.test("rm refuses a repo folder that links outside the root", function()
    local root, path, env = rm_setup("none")
    local outside = assert(fs.realpath(support.tempdir()))
    assert(fs.mkdir(outside .. "/feat"))
    assert(fs.write(outside .. "/feat/precious", "x"))
    assert(fs.remove(fs.dirname(path), { recursive = true }))
    assert(fs.symlink(outside, fs.dirname(path)))
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    testing.eq(code, 1)
    testing.eq(out, path .. " is outside " .. env.env.DEV_WS_ROOT .. ".\n")
    testing.eq(fs.exists(outside .. "/feat/precious"), true)
end)

local PRUNE_JJ_STUB = [[#!/bin/sh
if [ "$1" = "--no-pager" ]; then shift; fi
case "$*" in
    root) pwd; exit 0 ;;
    *"workspace list"*) printf '%s\n' "$WORKSPACES"; exit 0 ;;
    *"workspace root --name "*)
        for last; do :; done
        printf '%s\n' "$ROOTS" | while read -r name path; do
            if [ "$name" = "$last" ]; then echo "$path"; fi
        done
        exit 0 ;;
    *"log -r @ "*)
        if [ -n "$ERROR" ]; then printf '%s\n' "$ERROR" >&2; exit 1; fi
        printf '%s' "$WARN" >&2; printf '%s' "$DIRTY"; exit 0 ;;
    *"& empty()"*) printf '%s' "$EMPTY"; exit 0 ;;
    *"~ empty()"*) printf '%s' "$STRAYS"; exit 0 ;;
    *"bookmark list"*) printf '%s' "$BOOKMARKS"; exit 0 ;;
esac
echo "jj $*" >> "$LOG"
if [ -n "$FAIL" ]; then exit 3; fi
]]
local PRUNE_GIT_STUB = [[#!/bin/sh
case "$*" in
    *"--show-toplevel"*) pwd; exit 0 ;;
    *"--git-common-dir"*) echo .git; exit 0 ;;
    *"worktree list"*) printf '%s' "$WORKTREES"; exit 0 ;;
    *"status --porcelain"*) printf '%s' "$DIRTY"; exit 0 ;;
esac
echo "git $*" >> "$LOG"
if [ -n "$FAIL" ]; then exit 3; fi
for last; do :; done
rm -rf "$last"
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

local function worktrees(root, ...)
    local blocks = { "worktree " .. root .. "\nHEAD x\nbranch refs/heads/master" }
    for _, path in ipairs({ ... }) do
        blocks[#blocks + 1] = "worktree " .. path .. "\nHEAD x\nbranch refs/heads/x"
    end
    return table.concat(blocks, "\n\n") .. "\n"
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
    env.env.BOOKMARKS = ""
    return root, dir, env, log
end

local function lines(...)
    return table.concat({ ... }, "\n") .. "\n"
end

local function folder(dir, name)
    local path = dir .. name
    assert(fs.mkdir(path .. "/.jj", { parents = true }))
    assert(fs.write(path .. "/file", "x"))
    return path
end

testing.test("prune forgets a jj workspace whose folder is gone", function()
    local root, dir, env, log = prune_setup("jj")
    env.env.WORKSPACES = "default\ngone1"
    env.env.ROOTS = "gone1 " .. dir .. "gone1"
    local out, code = support.dev(root, { "ws", "prune" }, env)
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Skipped the card test. This project has no board.",
            "Forgot workspace gone1. Its folder " .. dir .. "gone1 is gone.",
            "Pruned 1 workspace and 0 heads. Left 0 items alone."
        )
    )
    testing.eq(fs.read(log), "jj -R " .. root .. " workspace forget gone1\n")
end)

testing.test("prune forgets a jj workspace named for a done card", function()
    local root, dir, env, log = prune_setup("jj")
    seed_board(root, env, { { id = DONE_ID, done = true }, { id = OPEN_ID } })
    local done = folder(dir, DONE_ID)
    local open = folder(dir, OPEN_ID)
    env.env.WORKSPACES = table.concat({ "default", DONE_ID, OPEN_ID }, "\n")
    env.env.ROOTS = table.concat({ DONE_ID .. " " .. done, OPEN_ID .. " " .. open }, "\n")
    local out, code = support.dev(root, { "ws", "prune" }, env)
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Forgot workspace " .. DONE_ID .. ". Its card is done.",
            "Pruned 1 workspace and 0 heads. Left 0 items alone."
        )
    )
    testing.eq(fs.read(log), "jj -R " .. root .. " workspace forget " .. DONE_ID .. "\n")
    testing.eq(fs.exists(done), false)
    testing.eq(fs.exists(open .. "/file"), true)
end)

testing.test("prune abandons an empty jj head no workspace or bookmark holds", function()
    local root, _, env, log = prune_setup("jj")
    local first = ("a1"):rep(20)
    env.env.WORKSPACES = "default"
    env.env.ROOTS = ""
    env.env.EMPTY = lines(first .. "\t", "0123456789abcdef\tdeploy marker")
    local out, code = support.dev(root, { "ws", "prune" }, env)
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
    testing.eq(fs.read(log), "jj -R " .. root .. " abandon " .. first .. " 0123456789abcdef\n")
end)

testing.test("prune lists a non-empty jj head and a stale bookmark and changes nothing", function()
    local root, _, env, log = prune_setup("jj")
    env.env.WORKSPACES = "default"
    env.env.ROOTS = ""
    env.env.STRAYS = ("c"):rep(40) .. "\tsome work\n"
    env.env.BOOKMARKS = lines("feat-x", "old")
    local out, code = support.dev(root, { "ws", "prune" }, env)
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
    testing.eq(fs.exists(log), false)
end)

testing.test("prune never touches the default workspace or a dirty folder", function()
    local root, dir, env, log = prune_setup("jj")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local dirty = folder(dir, DONE_ID)
    env.env.WORKSPACES = table.concat({ "default", DONE_ID }, "\n")
    env.env.ROOTS =
        table.concat({ "default " .. dir .. "gone-default", DONE_ID .. " " .. dirty }, "\n")
    env.env.DIRTY = "changes"
    local out, code = support.dev(root, { "ws", "prune" }, env)
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Kept workspace " .. DONE_ID .. ". " .. dirty .. " holds changes not in a commit.",
            "Pruned 0 workspaces and 0 heads. Left 1 item alone."
        )
    )
    testing.eq(fs.exists(dirty .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune keeps a folder when jj refuses to snapshot a file", function()
    local root, dir, env, log = prune_setup("jj")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local big = folder(dir, DONE_ID)
    env.env.WORKSPACES = table.concat({ "default", DONE_ID }, "\n")
    env.env.ROOTS = DONE_ID .. " " .. big
    env.env.WARN = "Warning: Refused to snapshot some files"
    local out, code = support.dev(root, { "ws", "prune" }, env)
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Kept workspace " .. DONE_ID .. ". " .. big .. " holds changes not in a commit.",
            "Pruned 0 workspaces and 0 heads. Left 1 item alone."
        )
    )
    testing.eq(fs.exists(big .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune keeps an unreadable jj workspace and names its error", function()
    local root, dir, env, log = prune_setup("jj")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local broken = folder(dir, DONE_ID)
    env.env.WORKSPACES = table.concat({ "default", DONE_ID }, "\n")
    env.env.ROOTS = DONE_ID .. " " .. broken
    env.env.ERROR = table.concat({
        "Error: The working copy is stale",
        "Hint: Run `jj workspace update-stale` to update it",
    }, "\n")
    local out, code = support.dev(root, { "ws", "prune" }, env)
    testing.eq(code, 0, out)
    local kept = "Kept workspace "
        .. DONE_ID
        .. ". Cannot read the state of "
        .. broken
        .. ": Error: The working copy is stale."
    testing.eq(out, lines(kept, "Pruned 0 workspaces and 0 heads. Left 1 item alone."))
    testing.eq(fs.exists(broken .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune keeps a linked folder in a dry run and a real run", function()
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
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)
    testing.eq(code, 0, out)
    testing.eq(out, lines(kept, "Would prune 0 workspaces and 0 heads. Left 1 item alone."))
    out, code = support.dev(root, { "ws", "prune" }, env)
    testing.eq(code, 0, out)
    testing.eq(out, lines(kept, "Pruned 0 workspaces and 0 heads. Left 1 item alone."))
    testing.eq(fs.exists(target .. "/file"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune dry-run changes nothing", function()
    local root, dir, env, log = prune_setup("jj")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local done = folder(dir, DONE_ID)
    env.env.WORKSPACES = table.concat({ "default", "gone1", DONE_ID }, "\n")
    env.env.ROOTS = table.concat({ "gone1 " .. dir .. "gone1", DONE_ID .. " " .. done }, "\n")
    env.env.EMPTY = ("e"):rep(40) .. "\t\n"
    env.env.BOOKMARKS = lines("old")
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)
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
    testing.eq(fs.exists(log), false)
    testing.eq(fs.exists(done .. "/file"), true)
end)

testing.test("prune removes git worktrees whose folder is gone or named for a done card", function()
    local root, dir, env, log = prune_setup("git")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local done = dir .. DONE_ID
    assert(fs.mkdir(done, { parents = true }))
    assert(fs.write(done .. "/.git", "gitdir: elsewhere\n"))
    local gone = dir .. "gone1"
    env.env.WORKTREES = worktrees(root, gone, done)
    local out, code = support.dev(root, { "ws", "prune" }, env)
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Removed worktree gone1. Its folder " .. gone .. " is gone.",
            "Removed worktree " .. DONE_ID .. ". Its card is done.",
            "Git keeps no empty heads, so only worktrees are pruned.",
            "Pruned 2 worktrees and 0 heads. Left 0 items alone."
        )
    )
    testing.eq(
        fs.read(log),
        lines(
            "git -C " .. root .. " worktree remove " .. gone,
            "git -C " .. root .. " worktree remove " .. done
        )
    )
    testing.eq(fs.exists(done), false)
end)

testing.test("prune keeps a dirty git worktree of a done card", function()
    local root, dir, env, log = prune_setup("git")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local done = dir .. DONE_ID
    assert(fs.mkdir(done, { parents = true }))
    assert(fs.write(done .. "/.git", "gitdir: elsewhere\n"))
    env.env.WORKTREES = worktrees(root, done)
    env.env.DIRTY = " M file\n"
    local out, code = support.dev(root, { "ws", "prune" }, env)
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Kept worktree " .. DONE_ID .. ". " .. done .. " holds changes not in a commit.",
            "Git keeps no empty heads, so only worktrees are pruned.",
            "Pruned 0 worktrees and 0 heads. Left 1 item alone."
        )
    )
    testing.eq(fs.exists(done .. "/.git"), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune keeps the workspace it runs in", function()
    local root, _, env, log = prune_setup("jj")
    local base = assert(fs.realpath(support.tempdir())) .. "/ws"
    local inside = base .. "/proj/" .. DONE_ID
    assert(fs.mkdir(inside .. "/.dev", { parents = true }))
    assert(fs.mkdir(inside .. "/.jj"))
    env.env.DEV_WS_ROOT = base
    env.env.PATH = root .. "/bin:" .. os.getenv("PATH")
    seed_board(inside, env, { { id = DONE_ID, done = true } })
    env.env.WORKSPACES = table.concat({ "default", DONE_ID }, "\n")
    env.env.ROOTS = DONE_ID .. " " .. inside
    local out, code = support.dev(inside, { "ws", "prune" }, env)
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Kept workspace " .. DONE_ID .. ". It is the workspace dev runs in.",
            "Pruned 0 workspaces and 0 heads. Left 1 item alone."
        )
    )
    testing.eq(fs.is_dir(inside), true)
    testing.eq(fs.exists(log), false)
end)

testing.test("prune dry-run changes no git worktree", function()
    local root, dir, env, log = prune_setup("git")
    seed_board(root, env, { { id = DONE_ID, done = true } })
    local done = dir .. DONE_ID
    assert(fs.mkdir(done, { parents = true }))
    assert(fs.write(done .. "/.git", "gitdir: elsewhere\n"))
    local gone = dir .. "gone1"
    env.env.WORKTREES = worktrees(root, gone, done)
    local out, code = support.dev(root, { "ws", "prune", "--dry-run" }, env)
    testing.eq(code, 0, out)
    testing.eq(
        out,
        lines(
            "Would remove worktree gone1. Its folder " .. gone .. " is gone.",
            "Would remove worktree " .. DONE_ID .. ". Its card is done.",
            "Git keeps no empty heads, so only worktrees are pruned.",
            "Would prune 2 worktrees and 0 heads. Left 0 items alone."
        )
    )
    testing.eq(fs.exists(log), false)
    testing.eq(fs.exists(done .. "/.git"), true)
end)

testing.test("prune goes on after a failed removal and exits with its code", function()
    local root, dir, env = prune_setup("git")
    env.env.FAIL = "1"
    env.env.WORKTREES = worktrees(root, dir .. "gone1", dir .. "gone2")
    local out, code = support.dev(root, { "ws", "prune" }, env)
    testing.eq(code, 3, out)
    testing.eq(
        out,
        lines(
            "Skipped the card test. This project has no board.",
            "Kept worktree gone1. The git command exited 3.",
            "Kept worktree gone2. The git command exited 3.",
            "Git keeps no empty heads, so only worktrees are pruned.",
            "Pruned 0 worktrees and 0 heads. Left 2 items alone."
        )
    )
end)

testing.test("prune leaves the empty heads when the abandon fails", function()
    local root, _, env = prune_setup("jj")
    env.env.FAIL = "1"
    env.env.WORKSPACES = "default"
    env.env.ROOTS = ""
    env.env.EMPTY = ("d"):rep(40) .. "\t\n"
    local out, code = support.dev(root, { "ws", "prune" }, env)
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
