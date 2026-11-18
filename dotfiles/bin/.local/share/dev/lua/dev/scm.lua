local dev_os = require("dev.os")
local fs = require("dev.fs")
local land = require("dev.board.land")
local vcs = require("dev.vcs")

---The source control API of dev: a workspace and what a verb does to it.
---@class dev.scm
local M = {}

---One checkout of a project, a jj workspace or a git worktree.
---@class dev.scm.Workspace
---@field root string the checkout's absolute path
local Workspace = {}
Workspace.__index = Workspace

---Open the checkout a verb works in.
---@param root string the checkout's absolute path
---@return dev.scm.Workspace workspace the checkout
function M.workspace(root)
    return setmetatable({ root = root }, Workspace)
end

---Name the checkout, which `dev ws new` makes equal to its directory.
---@return string name the directory's name
function Workspace:name()
    return fs.basename(self.root)
end

---Tell whether the checkout holds work that is not committed.
---
---In git that is any change `git status` lists. In jj the working copy is a commit, so it is any
---change in that commit.
---@return boolean dirty true when the checkout holds changes, false when it is clean or unreadable
function Workspace:is_dirty()
    local backend = vcs.backend(self.root)
    if backend == nil then
        return false
    end
    local base = vcs.base(self.root, backend, { quiet = true })
    local argv = vcs.with(base, "status", "--porcelain")
    if backend == vcs.JJ then
        argv = vcs.with(base, "diff", "--name-only", "-r", "@")
    end
    local out, code = dev_os.capture(argv, { stderr = "null", cwd = self.root })
    return code == 0 and out ~= ""
end

---List the files a commit touches.
---@param rev string the revset of one jj commit or the id of one git commit
---@return string[]? paths the sorted paths, nil when they could not be read
function Workspace:touched(rev)
    return land.touched(self.root, rev)
end

---Say whether a commit is an ancestor of a revision, or the revision itself.
---@param commit string the commit id
---@param rev string the revision
---@return boolean held true when the revision holds the commit
function Workspace:holds(commit, rev)
    return land.holds(self.root, commit, rev)
end

---Fetch the remote of record and rebase the change onto trunk when it sits elsewhere.
---@return boolean? rebased true when the change moved, false when it sat on trunk already
---@return string? problem why trunk could not be read or the rebase failed
function Workspace:rebase()
    return land.rebase(self.root)
end

---Land the working-copy change on trunk, with `jj land` or a push of the HEAD commit in git.
---@return boolean ok true when the land exited 0
---@return string output what the land printed
function Workspace:merge_into_trunk()
    return land.run(self.root)
end

return M
