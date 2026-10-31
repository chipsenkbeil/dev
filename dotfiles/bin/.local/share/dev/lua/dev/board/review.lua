local board = require("dev.board")
local devos = require("dev.os")
local vcs = require("dev.vcs")

---@class dev.board.review
local M = {}

---The review kinds `review --kind` accepts, in the order help lists them.
M.KINDS = { "code", "style", "recheck" }

local JJ_TEMPLATE = 'commit_id ++ " " ++ change_id ++ "\\n"'
local NO_CHANGE = "-"

---@class dev.board.review.Rev
---@field commit string the full commit id
---@field change string the change id in a jj project, `-` in a git one

local function jj_rev(root, rev)
    local base = vcs.base(root, vcs.JJ, { quiet = true })
    local out, code = devos.capture(
        vcs.with(base, "log", "-r", rev, "--no-graph", "-T", JJ_TEMPLATE),
        { stderr = "null" }
    )
    local commit, change = out:match("^(%x+) (%a+)\n$")
    if code ~= 0 or not commit then
        return nil, string.format("%q does not name exactly one commit in %s", rev, root)
    end
    return { commit = commit, change = change }
end

local function git_rev(root, rev)
    local base = vcs.base(root, vcs.GIT)
    local out, code = devos.capture(
        vcs.with(base, "rev-parse", "--verify", "--quiet", rev .. "^{commit}"),
        { stderr = "null" }
    )
    local commit = out:match("^(%x+)\n$")
    if code ~= 0 or not commit then
        return nil, string.format("%q does not name a commit in %s", rev, root)
    end
    return { commit = commit, change = NO_CHANGE }
end

---Resolve a revision to the one commit it names.
---@param root string the project root
---@param rev string a jj revset or a git revision
---@return dev.board.review.Rev? resolved the commit and change ids
---@return string? message why the revision is not one commit
function M.resolve(root, rev)
    if rev == "" or rev:find("^%-") or rev:find("%c") then
        return nil, string.format("%q is not a revision", rev)
    end
    local backend, message = vcs.require(root)
    if not backend then
        return nil, message
    end
    if backend == vcs.JJ then
        return jj_rev(root, rev)
    end
    return git_rev(root, rev)
end

---Write the comment that records a review.
---@param kind string one of `KINDS`
---@param by string the reviewer's name
---@param rev dev.board.review.Rev the commit reviewed
---@return string text the comment body, which is one line that begins with the reserved prefix
function M.record(kind, by, rev)
    return string.format(
        "%s kind=%s by=%s commit=%s change=%s",
        board.REVIEW_PREFIX,
        kind,
        by,
        rev.commit,
        rev.change
    )
end

return M
