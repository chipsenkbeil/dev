local board = require("@dev/board")
local dev_os = require("@dev/os")
local vcs = require("@dev/vcs")

---@class dev.board.review
local M = {}

---The names of the review kinds.
---@enum dev.board.review.Kind
M.Kind = { CODE = "code", STYLE = "style", RECHECK = "recheck" }

---The review kinds `review --kind` accepts, in the order help lists them.
M.KINDS = { M.Kind.CODE, M.Kind.STYLE, M.Kind.RECHECK }

---The flag that names the review a recheck rechecks.
M.OF_FLAG = "--of"

---The kinds a recheck can name with `--of`.
M.OF_KINDS = { M.Kind.CODE, M.Kind.STYLE }

---The names of the verdicts `review --verdict` accepts.
---@enum dev.board.review.Verdict
M.Verdict = { CLEAN = "clean", MINOR = "minor", NEEDS_WORK = "needs-work" }

---The flag that carries the verdict.
M.VERDICT_FLAG = "--verdict"

---The verdicts in the order help lists them.
M.VERDICTS = { M.Verdict.CLEAN, M.Verdict.MINOR, M.Verdict.NEEDS_WORK }

---The verdicts a Pomb seat holds.
---@enum dev.board.review.SeatVerdict
M.SeatVerdict = { APPROVED = "approved", CHANGES_NEEDED = "changes_needed" }

---The seat verdict each review verdict records.
M.SEAT_VERDICTS = {
    [M.Verdict.CLEAN] = M.SeatVerdict.APPROVED,
    [M.Verdict.MINOR] = M.SeatVerdict.APPROVED,
    [M.Verdict.NEEDS_WORK] = M.SeatVerdict.CHANGES_NEEDED,
}

local JJ_TEMPLATE = 'commit_id ++ " " ++ change_id ++ "\\n"'
---The change id a git commit carries, since git has no change ids.
M.NO_CHANGE = "-"

---@class dev.board.review.Rev
---@field commit string the full commit id
---@field change string the change id in a jj project, `-` in a git one

local function jj_rev(root, rev)
    local base = vcs.base(root, vcs.JJ, { quiet = true })
    local out, code = dev_os.capture(
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
    local out, code = dev_os.capture(
        vcs.with(base, "rev-parse", "--verify", "--quiet", rev .. "^{commit}"),
        { stderr = "null" }
    )
    local commit = out:match("^(%x+)\n$")
    if code ~= 0 or not commit then
        return nil, string.format("%q does not name a commit in %s", rev, root)
    end
    return { commit = commit, change = M.NO_CHANGE }
end

---Resolve a revision to the one commit it names.
---@param root string the project root
---@param rev string a jj revset or a git revision
---@return dev.board.review.Rev? resolved the commit and change ids
---@return string? message why the revision is not one commit
function M.resolve(root, rev: string)
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
---@param verdict string one of `VERDICTS`
---@param of string? the kind a recheck rechecks, one of `OF_KINDS`
---@return string text the comment body, which is one line that begins with the reserved prefix
function M.record(kind, by, rev, verdict, of)
    return string.format(
        "%s kind=%s by=%s commit=%s change=%s%s verdict=%s",
        board.REVIEW_PREFIX,
        kind,
        by,
        rev.commit,
        rev.change,
        of and (" of=" .. of) or "",
        verdict
    )
end

---@class dev.board.review.Record
---@field kind string one of `KINDS`
---@field by string the reviewer's name
---@field commit string the full commit id reviewed
---@field change string the change id, `-` in a git project
---@field verdict string? one of `VERDICTS`, nil in a record written before verdicts
---@field of string? the kind a recheck rechecks, nil on any other record

---Read a comment that `record` wrote.
---@param body string the comment body
---@return dev.board.review.Record? record nil when the body is not a record
function M.parse(body)
    local of
    body = body:gsub(" of=(%S+)", function(value)
        of = value
        return ""
    end, 1)
    local prefix, kind, by, commit, change, verdict =
        body:match("^(%S+) kind=(%S+) by=(%S+) commit=(%x+) change=(%S+) verdict=(%S+)$")
    if not prefix then
        prefix, kind, by, commit, change =
            body:match("^(%S+) kind=(%S+) by=(%S+) commit=(%x+) change=(%S+)$")
    end
    if prefix ~= board.REVIEW_PREFIX then
        return nil
    end
    return { kind = kind, by = by, commit = commit, change = change, verdict = verdict, of = of }
end

return M
