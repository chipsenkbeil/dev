local dev_os = require("dev.os")
local fs = require("dev.fs")
local text = require("dev.text")
local vcs = require("dev.vcs")
local verb = require("dev.verb")

local SHORT_CHARS = 12
local MAIN_WORKSPACE = "default"
local ROOT_MARK = "root"

---@class dev.cmd.follow
local M = {}

local function chomp(out)
    return (out:gsub("\n$", ""))
end

local function failed(main, command, out)
    local why = out and out ~= "" and ": " .. out or ""
    return text.sentence("the " .. command .. " command failed in " .. main .. why), 1
end

local function main_of_jj(root)
    local argv = vcs.with(
        vcs.base(root, vcs.JJ, { quiet = true }),
        "workspace",
        "root",
        "--name",
        MAIN_WORKSPACE
    )
    local out, code = dev_os.capture(argv, { stderr = "null" })
    if code ~= 0 or out == "" then
        return nil, "jj lists no workspace named " .. MAIN_WORKSPACE .. " for " .. root
    end
    return chomp(out)
end

local function main_of_git(root)
    local argv =
        vcs.with(vcs.base(root, vcs.GIT), "rev-parse", "--path-format=absolute", "--git-common-dir")
    local out, code = dev_os.capture(argv, { stderr = "null" })
    local main = code == 0 and chomp(out):match("^(.*)/%.git$")
    if not main then
        return nil, "git finds no main checkout for " .. root
    end
    return main
end

---Find the main checkout of the repository a folder belongs to.
---
---A folder with `.jj` answers to jj, whose main checkout is the workspace named `default`.
---Any other folder with `.git` answers to git, whose main checkout holds the common git folder.
---@param root string absolute path of a checkout, a jj workspace or a git worktree
---@return string? main the main checkout's absolute path
---@return string? err why there is none
function M.main(root)
    local backend, err = vcs.backend(root)
    if backend == vcs.JJ then
        return main_of_jj(root)
    end
    if backend == vcs.GIT then
        return main_of_git(root)
    end
    return nil, err
end

local function short(commit)
    return commit:sub(1, SHORT_CHARS)
end

local function runner(base)
    local function run(stderr, ...)
        local out, code = dev_os.capture(vcs.with(base, ...), { stderr = stderr })
        return chomp(out), code
    end
    return function(...)
        return run("stdout", ...)
    end, function(...)
        return run("null", ...)
    end
end

local function jj_follow(main)
    local base = vcs.base(main, vcs.JJ, { quiet = true })
    local jj, read = runner(base)
    local out, code = jj("workspace", "update-stale")
    if code ~= 0 then
        return failed(main, "jj workspace update-stale", out)
    end
    local empty
    empty, code = read("log", "-r", "@", "--no-graph", "-T", "empty")
    if code ~= 0 then
        return failed(main, "jj log")
    end
    if empty ~= "true" then
        return main .. " was left alone: it has uncommitted changes.", 0
    end
    if #vcs.remotes(main, vcs.JJ) > 0 then
        out, code = jj("git", "fetch", "--all-remotes")
        if code ~= 0 then
            return failed(main, "jj git fetch", out)
        end
    end
    local trunk
    trunk, code = read("log", "-r", "trunk()", "--no-graph", "-T", 'if(root, "root", commit_id)')
    if code ~= 0 or trunk == ROOT_MARK or trunk == "" then
        return "There is no trunk in " .. main .. ".", 1
    end
    local parent
    parent, code = read("log", "-r", "@-", "--no-graph", "-T", "commit_id")
    if code == 0 and parent ~= trunk then
        out, code = jj("new", "trunk()")
        if code ~= 0 then
            return failed(main, "jj new", out)
        end
    end
    return main .. " is on trunk " .. short(trunk) .. ".", 0
end

local function holds(list, word)
    for _, item in ipairs(list) do
        if item == word then
            return true
        end
    end
    return false
end

local function git_follow(main)
    local base = vcs.base(main, vcs.GIT)
    local git, read = runner(base)
    local dirty, code = read("status", "--porcelain", "--untracked-files=no")
    if code ~= 0 then
        return failed(main, "git status")
    end
    if dirty ~= "" then
        return main .. " was left alone: it has uncommitted changes.", 0
    end
    local trunk = vcs.trunk(vcs.branches(main, vcs.GIT))
    if not trunk then
        return main .. " has no master or main branch.", 1
    end
    local _, attached = read("symbolic-ref", "--quiet", "HEAD")
    local held = read("for-each-ref", "--contains", "HEAD", "--format=%(refname)", "refs/heads")
    if attached ~= 0 and held == "" then
        return main .. " was left alone: its detached HEAD holds commits no branch has.", 0
    end
    local out
    local remotes = vcs.remotes(main, vcs.GIT)
    if #remotes > 0 then
        out, code = git("fetch", "--all", "--quiet")
        if code ~= 0 then
            return failed(main, "git fetch", out)
        end
    end
    out, code = git("checkout", "--quiet", trunk)
    if code ~= 0 then
        return failed(main, "git checkout", out)
    end
    local remote = "origin"
    if #remotes > 0 and not holds(remotes, remote) then
        remote = remotes[1]
    end
    local upstream = remote .. "/" .. trunk
    local _, known = read("rev-parse", "--verify", "--quiet", "refs/remotes/" .. upstream)
    if known == 0 then
        out, code = git("merge", "--ff-only", "--quiet", upstream)
        if code ~= 0 then
            return failed(main, "git merge", out)
        end
    end
    local head
    head, code = read("rev-parse", "HEAD")
    if code ~= 0 then
        return failed(main, "git rev-parse")
    end
    return main .. " is on trunk " .. short(head) .. ".", 0
end

---Move a main checkout onto trunk.
---
---A checkout with uncommitted edits is left as it is. jj is used when the checkout has `.jj` and
---git otherwise.
---@param main string absolute path of the main checkout
---@return string line the one line saying what happened
---@return integer code 0 when the checkout moved, was current or was left alone, 1 on a failure
function M.follow(main)
    local backend, err = vcs.require(main)
    if not backend then
        return "Cannot follow " .. main .. ". " .. text.sentence(err), 1
    end
    if backend == vcs.JJ then
        return jj_follow(main)
    end
    return git_follow(main)
end

---List the command lines `dev help follow` shows.
---@param root string absolute path of the project root
---@return string[] lines one command per line, or a single message line
function M.commands(root)
    local main, err = M.main(root)
    if not main then
        return { text.sentence(err) }
    end
    if vcs.backend(main) == vcs.JJ then
        return { "jj -R " .. main .. " new trunk()" }
    end
    return {
        "git -C " .. main .. " checkout trunk",
        "git -C " .. main .. " merge --ff-only origin/trunk",
    }
end

---Move the repository's main checkout onto trunk.
---
---The folder the verb runs in may be the main checkout, a jj workspace or a git worktree.
---@param ctx dev.Ctx the verb's context
---@return integer code the exit code
function M.run(ctx)
    local main, err = M.main(ctx.root)
    if not main then
        verb.note(text.sentence(err))
        return 1
    end
    local line, code = M.follow(main)
    verb.say(line)
    return code
end

---Run `dev follow` for a main checkout through the launcher to let a project `.dev/follow`
---script replace the built-in.
---@param main string absolute path of the main checkout
---@return string line what it printed, or why it did not run
function M.launch(main)
    local launcher = os.getenv("DEV_SELF") or ""
    if launcher:sub(1, 1) ~= "/" or not fs.is_exec(launcher) then
        return "DEV_SELF is not the dev launcher. " .. main .. " was not moved."
    end
    local out = dev_os.capture({ launcher, "follow" }, { cwd = main, stderr = "stdout" })
    return text.trim(out)
end

return M
