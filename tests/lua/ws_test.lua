local t = require("dev.testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

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
esac
echo "git $*" >> "$LOG"
mkdir -p "$(eval echo \$$#)"
]]
local NO_GIT = "#!/bin/sh\nexit 1\n"

local function stub(root, name, body)
    assert(fs.write(root .. "/bin/" .. name, body))
    assert(devos.run({ "chmod", "755", root .. "/bin/" .. name }) == 0, "chmod failed")
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

t.test("new in a jj project fetches the remote of record first", function()
    local root, path, env, log = setup("jj")
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    t.eq(code, 0)
    t.eq(out, path .. "\n")
    t.eq(
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

t.test("new in a jj project fetches the gerrit remote of record", function()
    local root, path, env, log = setup("jj")
    env.env.JJ_FORGE = "gerrit"
    env.env.REMOTES = "origin\ngerrit\n"
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    t.eq(code, 0)
    t.eq(out, path .. "\n")
    t.eq(
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

t.test("new in a jj project stops at a failed fetch with no workspace", function()
    local root, path, env, log = setup("jj")
    env.env.FETCH_CODE = "1"
    env.env.FETCH_OUT = "error: could not connect\n"
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    t.eq(code, 1)
    t.eq(out, "dev ws new: the fetch from origin failed: error: could not connect\n")
    t.eq(fs.read(log), "jj --color never -R " .. root .. " git fetch --remote origin\n")
    t.eq(fs.exists(path), false)
    t.eq(fs.exists(fs.dirname(path)), false)
end)

t.test("new in a jj project refuses a missing remote of record", function()
    local root, path, env, log = setup("jj")
    env.env.REMOTES = ""
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    t.eq(code, 1)
    t.eq(
        out,
        "dev ws new: trunk cannot be compared: the remote of record origin is not a remote of this project (detected: no gerrit remote and origin is not on github.com)\n"
    )
    t.eq(fs.exists(log), false)
    t.eq(fs.exists(path), false)
end)

t.test("new in a git project adds a worktree on a new branch", function()
    local root, path, env, log = setup("git")
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    t.eq(code, 0)
    t.eq(out, path .. "\n")
    t.eq(fs.read(log), "git -C " .. root .. " worktree add -b feat " .. path .. "\n")
end)

t.test("new outside version control makes a plain folder", function()
    local root, path, env = setup("none")
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    t.eq(code, 0)
    t.eq(out, path .. "\n")
    t.eq(fs.is_dir(path), true)
end)

t.test("new refuses a path that exists", function()
    local root, path, env, log = setup("jj")
    assert(fs.mkdir(path, { parents = true }))
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    t.eq(code, 1)
    t.eq(out, "dev ws new: " .. path .. " already exists\n")
    t.eq(fs.exists(log), false)
end)

t.test("DEV_WS_ROOT moves the root and the default is under HOME", function()
    local root, _, env = setup("none")
    local home = support.tempdir()
    env.env.DEV_WS_ROOT = ""
    env.env.HOME = home
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    t.eq(code, 0)
    t.eq(out, home .. "/.local/share/workspaces/" .. fs.basename(root) .. "/feat\n")
end)

t.test("new needs one plain NAME", function()
    local root, _, env = setup("none")
    for _, case in ipairs({
        { { "ws", "new" }, "dev ws new: needs a NAME\n" },
        { { "ws", "new", "a", "b" }, "dev ws new: takes one NAME, got b\n" },
        { { "ws", "new", "a/b" }, "dev ws new: NAME is one folder name, got a/b\n" },
        { { "ws", "new", "-x" }, "dev ws new: unknown flag -x\n" },
    }) do
        local out, code = support.dev(root, case[1], env)
        t.eq(code, 2)
        t.eq(out, case[2])
    end
end)

t.test(
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
        t.eq(code, 0)
        t.eq(out, base .. "/proj/feat\n")
    end
)

local RM_JJ_STUB = [[#!/bin/sh
if [ "$1" = "--no-pager" ]; then shift; fi
case "$*" in
    root) pwd; exit 0 ;;
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
    return root, path, env, log
end

t.test("ls prints each workspace folder with its path", function()
    local root, path, env = setup("none")
    assert(fs.mkdir(path, { parents = true }))
    assert(fs.mkdir(fs.dirname(path) .. "/other"))
    assert(fs.write(fs.dirname(path) .. "/stray", "x"))
    local out, code = support.dev(root, { "ws", "ls" }, env)
    t.eq(code, 0)
    t.eq(out, "feat\t" .. path .. "\nother\t" .. fs.dirname(path) .. "/other\n")
end)

t.test("ls prints nothing when the project has no workspaces", function()
    local root, _, env = setup("none")
    local out, code = support.dev(root, { "ws", "ls" }, env)
    t.eq(code, 0)
    t.eq(out, "")
end)

t.test("ls takes no arguments", function()
    local root, _, env = setup("none")
    local out, code = support.dev(root, { "ws", "ls", "x" }, env)
    t.eq(code, 2)
    t.eq(out, "dev ws ls: takes no arguments, got x\n")
end)

t.test("rm forgets a jj workspace and deletes its folder", function()
    local root, path, env, log = rm_setup("jj")
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    t.eq(code, 0)
    t.eq(out, "removed " .. path .. "\n")
    t.eq(fs.read(log), "jj -R " .. root .. " workspace forget feat\n")
    t.eq(fs.exists(path), false)
end)

t.test("rm removes a git worktree and its folder", function()
    local root, path, env, log = rm_setup("git")
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    t.eq(code, 0)
    t.eq(out, "removed " .. path .. "\n")
    t.eq(fs.read(log), "git -C " .. root .. " worktree remove " .. path .. "\n")
    t.eq(fs.exists(path), false)
end)

t.test("rm deletes a plain folder", function()
    local root, path, env, log = rm_setup("none")
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    t.eq(code, 0)
    t.eq(out, "removed " .. path .. "\n")
    t.eq(fs.exists(path), false)
    t.eq(fs.exists(log), false)
end)

t.test("rm refuses a jj workspace with changes and leaves it in place", function()
    local root, path, env, log = rm_setup("jj")
    env.env.DIRTY = "changes"
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    t.eq(code, 1)
    t.eq(out, "dev ws rm: " .. path .. " holds changes not in a commit\n")
    t.eq(fs.exists(path .. "/file"), true)
    t.eq(fs.exists(log), false)
end)

t.test("rm refuses a git worktree with changes and leaves it in place", function()
    local root, path, env, log = rm_setup("git")
    env.env.DIRTY = " M file\n"
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    t.eq(code, 1)
    t.eq(out, "dev ws rm: " .. path .. " holds changes not in a commit\n")
    t.eq(fs.exists(path .. "/file"), true)
    t.eq(fs.exists(log), false)
end)

t.test("rm leaves a workspace whose state cannot be read", function()
    local root, path, env, log = rm_setup("jj")
    env.env.LOG_CODE = "1"
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    t.eq(code, 1)
    t.eq(out, "dev ws rm: cannot read the state of " .. path .. "\n")
    t.eq(fs.exists(path .. "/file"), true)
    t.eq(fs.exists(log), false)
end)

t.test("rm leaves the folder when the version control command fails", function()
    local root, path, env = rm_setup("git")
    stub(
        root,
        "git",
        '#!/bin/sh\ncase "$*" in *--git-common-dir*) echo .git; exit 0;; *--show-toplevel*) pwd; exit 0;; *status*) exit 0;; esac\nexit 3\n'
    )
    local _, code = support.dev(root, { "ws", "rm", "feat" }, env)
    t.eq(code, 3)
    t.eq(fs.exists(path .. "/file"), true)
end)

t.test("rm refuses a missing workspace", function()
    local root, path, env = rm_setup("none")
    assert(fs.remove(path, { recursive = true }))
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    t.eq(code, 1)
    t.eq(out, "dev ws rm: " .. path .. " is not a workspace folder\n")
end)

t.test("rm refuses a link that points outside the root and deletes nothing", function()
    local root, path, env = rm_setup("none")
    local outside = assert(fs.realpath(support.tempdir()))
    assert(fs.write(outside .. "/precious", "x"))
    assert(fs.remove(path, { recursive = true }))
    assert(fs.symlink(outside, path))
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    t.eq(code, 1)
    t.eq(out, "dev ws rm: " .. path .. " is a link, not removed\n")
    t.eq(fs.exists(outside .. "/precious"), true)
    t.eq(fs.is_link(path), true)
end)

t.test("rm refuses a link inside the root as well", function()
    local root, path, env = rm_setup("none")
    local target = fs.dirname(path) .. "/real"
    assert(fs.mkdir(target))
    assert(fs.write(target .. "/keep", "x"))
    assert(fs.symlink(target, fs.dirname(path) .. "/alias"))
    local _, code = support.dev(root, { "ws", "rm", "alias" }, env)
    t.eq(code, 1)
    t.eq(fs.exists(target .. "/keep"), true)
end)

t.test("rm refuses a NAME that is not one folder name", function()
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
        t.eq(code, 2)
        t.eq(out, case[2])
    end
    t.eq(fs.exists(path .. "/file"), true)
end)

t.test("rm refuses the workspace it runs in", function()
    local root, _, env = setup("none")
    local base = assert(fs.realpath(support.tempdir())) .. "/ws"
    local inside = base .. "/proj/first"
    assert(fs.mkdir(inside .. "/.dev", { parents = true }))
    assert(fs.mkdir(inside .. "/bin"))
    env.env.DEV_WS_ROOT = base
    env.env.PATH = root .. "/bin:" .. os.getenv("PATH")
    local out, code = support.dev(inside, { "ws", "rm", "first" }, env)
    t.eq(code, 1)
    t.eq(out, "dev ws rm: " .. inside .. " is the workspace dev runs in\n")
    t.eq(fs.is_dir(inside), true)
end)

t.test("rm refuses a repo folder that links outside the root", function()
    local root, path, env = rm_setup("none")
    local outside = assert(fs.realpath(support.tempdir()))
    assert(fs.mkdir(outside .. "/feat"))
    assert(fs.write(outside .. "/feat/precious", "x"))
    assert(fs.remove(fs.dirname(path), { recursive = true }))
    assert(fs.symlink(outside, fs.dirname(path)))
    local out, code = support.dev(root, { "ws", "rm", "feat" }, env)
    t.eq(code, 1)
    t.eq(out, "dev ws rm: " .. path .. " is outside " .. env.env.DEV_WS_ROOT .. "\n")
    t.eq(fs.exists(outside .. "/feat/precious"), true)
end)
