local dev_os = require("dev.os")
local vcs = require("dev.vcs")

---The red notes a red ship leaves on its suspects, and the revert of a suspect's landed commit.
---@class dev.board.revert
---@field AFTER_SECONDS integer how long a suspect stays red before its commit is reverted
local M = {}

M.AFTER_SECONDS = 3600

---Why a revert did not apply
---@enum dev.board.revert.Reason
M.Reason = { CONFLICT = "conflict", FAILED = "failed" }

local CASE_SEPARATOR = "; "
local RED_PATTERN = "^Ship went red .*%(epoch (%d+)%)%.$"
local LANDED_PATTERNS = { "^Landed commit ", "^landed %x+ on ", "^Landed change " }

---Write the note a red ship leaves on a suspect card.
---@param commit string the short commit the ship tested
---@param now integer the epoch seconds
---@param cases string[]? the failing cases the ship printed
---@return string text the note
function M.red_text(commit, now, cases)
    local on = cases and #cases > 0 and (" on " .. table.concat(cases, CASE_SEPARATOR)) or ""
    return string.format(
        "Ship went red at commit %s%s with this card a suspect (epoch %d).",
        commit,
        on,
        now
    )
end

---Read the failing cases a red note lists.
---@param body string the note's text
---@return string[]? cases the cases, nil when the note lists none
function M.red_cases(body)
    local list = body:match("^Ship went red at commit %S+ on (.-) with this card a suspect")
    if not list then
        return nil
    end
    local cases = {}
    for case in (list .. CASE_SEPARATOR):gmatch("(.-)" .. CASE_SEPARATOR:gsub("%p", "%%%0")) do
        cases[#cases + 1] = case
    end
    return cases
end

local function landed(body)
    for _, pattern in ipairs(LANDED_PATTERNS) do
        if body:match(pattern) then
            return true
        end
    end
    return false
end

local function shares(listed, cases)
    if not listed then
        return true
    end
    for _, case in ipairs(listed) do
        for _, current in ipairs(cases) do
            if case == current then
                return true
            end
        end
    end
    return false
end

---Read when a card first went red on one of the current cases since its newest land note.
---@param comments {body: string}[] the card's comments, oldest first
---@param cases string[] the failing cases of this ship
---@return integer? since the epoch seconds of the first such red note, nil when it has none
function M.red_since(comments, cases)
    local since
    for _, comment in ipairs(comments) do
        local epoch = comment.body:match(RED_PATTERN)
        if landed(comment.body) then
            since = nil
        elseif epoch and not since and shares(M.red_cases(comment.body), cases) then
            since = tonumber(epoch)
        end
    end
    return since
end

---Read the landed commit of the newest revert note that no later land note follows.
---@param comments {body: string}[] the card's comments, oldest first
---@return string? commit the short landed commit that was reverted, nil when none is pending
function M.reverted(comments)
    local commit
    for _, comment in ipairs(comments) do
        if landed(comment.body) then
            commit = nil
        else
            commit = comment.body:match("^Reverted landed commit (%x+) after ") or commit
        end
    end
    return commit
end

local function last_line(text)
    local last = ""
    for line in text:gmatch("[^\n]+") do
        last = line
    end
    return last
end

---Put the reverse of a landed commit under the working copy, or on the checked-out branch in git.
---@param root string the project root
---@param commit string the landed commit
---@return boolean ok whether the revert applied cleanly
---@return string? reason one of `Reason` when it did not
---@return string? detail the last line the tool printed
function M.apply(root, commit)
    if vcs.backend(root) == vcs.GIT then
        local base = vcs.base(root, vcs.GIT)
        local out, code =
            dev_os.capture(vcs.with(base, "revert", "--no-edit", commit), { stderr = "stdout" })
        if code ~= 0 then
            local _, pending = dev_os.capture(
                vcs.with(base, "rev-parse", "-q", "--verify", "REVERT_HEAD"),
                { stderr = "null" }
            )
            dev_os.capture(vcs.with(base, "revert", "--abort"), { stderr = "null" })
            if pending == 0 then
                return false, M.Reason.CONFLICT
            end
            return false, M.Reason.FAILED, last_line(out)
        end
        return true
    end
    local base = vcs.base(root, vcs.JJ, { quiet = true })
    local out, code = dev_os.capture(
        vcs.with(base, "revert", "-r", commit, "--insert-before", "@"),
        { stderr = "stdout" }
    )
    if code ~= 0 then
        return false, M.Reason.FAILED, last_line(out)
    end
    local state = dev_os.capture(
        vcs.with(base, "log", "-r", "@-", "--no-graph", "-T", 'if(conflict, "conflict", "clean")'),
        { stderr = "null" }
    )
    if state ~= "clean" then
        dev_os.capture(vcs.with(base, "abandon", "@-"), { stderr = "null" })
        return false, M.Reason.CONFLICT
    end
    return true
end

---Order entries newest landed commit first, so a revert meets the later changes it undoes first.
---@param root string the project root
---@param entries {landed: string}[] the entries, each with its landed commit, a full id or a prefix
---@return {landed: string}[] ordered the same entries, or as given when the order cannot be read
function M.newest_first(root, entries)
    if #entries < 2 then
        return entries
    end
    local out, code
    if vcs.backend(root) == vcs.GIT then
        local base = vcs.base(root, vcs.GIT)
        out, code =
            dev_os.capture(vcs.with(base, "rev-list", "--topo-order", "HEAD"), { stderr = "null" })
    else
        local commits = {}
        for _, entry in ipairs(entries) do
            commits[#commits + 1] = entry.landed
        end
        local base = vcs.base(root, vcs.JJ, { quiet = true })
        out, code = dev_os.capture(
            vcs.with(
                base,
                "log",
                "-r",
                table.concat(commits, "|"),
                "--no-graph",
                "-T",
                'commit_id ++ "\n"'
            ),
            { stderr = "null" }
        )
    end
    if code ~= 0 then
        return entries
    end
    local walk = {}
    for commit in out:gmatch("%x+") do
        walk[#walk + 1] = commit
    end
    local function rank(entry)
        for at, commit in ipairs(walk) do
            if commit:sub(1, #entry.landed) == entry.landed then
                return at
            end
        end
        return math.huge
    end
    local given, ranked, ordered = {}, {}, {}
    for i, entry in ipairs(entries) do
        given[entry] = i
        ranked[entry] = rank(entry)
        ordered[i] = entry
    end
    table.sort(ordered, function(a, b)
        if ranked[a] ~= ranked[b] then
            return ranked[a] < ranked[b]
        end
        return given[a] < given[b]
    end)
    return ordered
end

return M
