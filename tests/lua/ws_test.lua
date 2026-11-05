local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local JJ_STUB = [[#!/bin/sh
if [ "$1" = "--no-pager" ]; then shift; fi
if [ "$1" = root ]; then pwd; exit 0; fi
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
    local env = { env = { DEV_WS_ROOT = ws .. "/ws", LOG = log } }
    return root, ws .. "/ws/" .. fs.basename(root) .. "/feat", env, log
end

t.test("new in a jj project adds a jj workspace on the trunk revision", function()
    local root, path, env, log = setup("jj")
    local out, code = support.dev(root, { "ws", "new", "feat" }, env)
    t.eq(code, 0)
    t.eq(out, path .. "\n")
    t.eq(fs.read(log), "jj -R " .. root .. " workspace add --name feat -r trunk() " .. path .. "\n")
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
