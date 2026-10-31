local check = require("dev.board.check")
local devos = require("dev.os")
local forge = require("dev.forge")
local review = require("dev.board.review")
local vcs = require("dev.vcs")

---@class dev.board.land
local M = {}

local SHAPE_TEMPLATE = 'if(empty, "empty", "full") ++ " " ++ if(description == "", "bare", "named")'
local COMMIT_TEMPLATE = 'commit_id ++ "\\n"'
local COMMIT_CHARS = 12

---Shorten a commit id for a message.
---@param commit string the full commit id
---@return string short the first characters
function M.short(commit)
    return commit:sub(1, COMMIT_CHARS)
end

local function jj(root, ...)
    return vcs.with(vcs.base(root, vcs.JJ, { quiet = true }), ...)
end

local function count_lines(text)
    local n = 0
    for _ in text:gmatch("[^\n]+") do
        n = n + 1
    end
    return n
end

---Name the change a landing would carry.
---
---The working-copy commit must hold work, carry a description and have no conflicts.
---@param root string the project root, a jj project
---@return dev.board.check.State? state the commit and change
---@return string? message why the working copy cannot land
function M.state(root)
    local state, message = check.state(root)
    if not state then
        return nil, message
    end
    local out, code = devos.capture(
        jj(root, "log", "-r", "@", "--no-graph", "-T", SHAPE_TEMPLATE),
        { stderr = "null" }
    )
    local shape, naming = out:match("^(%a+) (%a+)\n?$")
    if code ~= 0 or not shape then
        return nil, "jj could not read the working-copy commit of " .. root
    end
    if shape == "empty" then
        return nil, "the working-copy commit is empty, so there is no change to land"
    end
    if naming == "bare" then
        return nil, "the working-copy commit has no description"
    end
    return state
end

---List what the recorded reviews still lack for a commit.
---
---A kind is met by a review of that kind at the commit, or by one of that kind on the
---change at an earlier commit plus a recheck at this commit.
---@param comments {body: string}[] the card's comments, oldest first
---@param state dev.board.check.State the commit that would land
---@return string[] missing one line per review that is absent
function M.missing_reviews(comments, state)
    local reviews = {}
    for _, comment in ipairs(comments) do
        local record = review.parse(comment.body)
        if record and record.change == state.change then
            reviews[#reviews + 1] = record
        end
    end
    local function has(kind, at)
        for _, record in ipairs(reviews) do
            if record.kind == kind and (not at or record.commit == at) then
                return true
            end
        end
        return false
    end
    local rechecked = has(review.KIND.RECHECK, state.commit)
    local missing = {}
    for _, kind in ipairs({ review.KIND.CODE, review.KIND.STYLE }) do
        if not has(kind, state.commit) then
            if not has(kind) then
                missing[#missing + 1] = string.format(
                    "no %s review of change %s; record one with dev board review --kind %s",
                    kind,
                    state.change,
                    kind
                )
            elseif not rechecked then
                missing[#missing + 1] = string.format(
                    "the %s review is of an earlier commit than %s; record a recheck with dev board review --kind recheck --rev @",
                    kind,
                    M.short(state.commit)
                )
            end
        end
    end
    return missing
end

---Say whether the newest run of the checks at a commit passed every row.
---
---A record made with `--expect-fail` never counts.
---@param comments {body: string}[] the card's comments, oldest first
---@param state dev.board.check.State the commit that would land
---@param rows string[] the card's checks rows
---@return string? problem what is missing, nil when every row passed
function M.checks_problem(comments, state, rows)
    if #rows == 0 then
        return "the card has no checks rows, so nothing proves the change"
    end
    local latest
    for _, comment in ipairs(comments) do
        local record = check.parse(comment.body)
        if record and record.commit == state.commit and record.mode == check.MODE.RUN then
            latest = record
        end
    end
    if not latest then
        return string.format(
            "no run of dev board check is recorded at commit %s; run it on this commit (a --expect-fail record does not count)",
            M.short(state.commit)
        )
    end
    if #latest.rows ~= #rows then
        return string.format(
            "the newest check run at commit %s has %d rows and the card has %d; run dev board check again",
            M.short(state.commit),
            #latest.rows,
            #rows
        )
    end
    local bad = {}
    for i, row in ipairs(latest.rows) do
        if row.run ~= rows[i] then
            return string.format(
                "the newest check run at commit %s ran %q as row %d and the card now holds %q; run dev board check again",
                M.short(state.commit),
                row.run,
                i,
                rows[i]
            )
        end
        if row.result ~= check.RESULT.PASS then
            bad[#bad + 1] = string.format("%d %s %s", i, row.result, row.run)
        end
    end
    if #bad > 0 then
        return string.format(
            "the newest check run at commit %s did not pass every row (%s)",
            M.short(state.commit),
            table.concat(bad, "; ")
        )
    end
end

---Fetch the remote of record and say whether the change still sits on trunk.
---@param root string the project root, a jj project
---@return string? problem what is wrong, nil when the change's parent is the current trunk
function M.trunk_problem(root)
    local found, why = forge.resolve(root)
    if not found then
        return "trunk cannot be compared: " .. why
    end
    local out, code =
        devos.capture(jj(root, "git", "fetch", "--remote", found.remote), { stderr = "stdout" })
    if code ~= 0 then
        return string.format(
            "trunk cannot be compared, the fetch from %s failed: %s",
            found.remote,
            out
        )
    end
    local parents =
        devos.capture(jj(root, "log", "-r", "@-", "--no-graph", "-T", COMMIT_TEMPLATE), {
            stderr = "null",
        })
    local on_trunk = devos.capture(
        jj(root, "log", "-r", "@- & trunk()", "--no-graph", "-T", COMMIT_TEMPLATE),
        { stderr = "null" }
    )
    if count_lines(parents) ~= 1 or on_trunk ~= parents then
        return "trunk has moved since the change was built, so rebase it onto trunk(), then record the reviews and run dev board check again"
    end
end

---Read the commit that holds a change on trunk, which `jj land` may have rewritten.
---@param root string the project root, a jj project
---@param change string the change id, which survives the rewrite
---@return string? commit the full commit id, nil when trunk does not hold exactly one commit of the change
function M.trunk_commit(root, change)
    local found = forge.resolve(root)
    if not found then
        return nil
    end
    local _, fetched =
        devos.capture(jj(root, "git", "fetch", "--remote", found.remote), { stderr = "null" })
    if fetched ~= 0 then
        return nil
    end
    local out, code = devos.capture(
        jj(root, "log", "-r", change .. " & ::trunk()", "--no-graph", "-T", COMMIT_TEMPLATE),
        { stderr = "null" }
    )
    if code ~= 0 then
        return nil
    end
    return out:match("^(%x+)\n$")
end

---Land the working-copy change with `jj land`.
---@param root string the project root, a jj project
---@return boolean ok true when jj land exited 0
---@return string output what jj land printed
function M.run(root)
    local out, code = devos.capture(
        vcs.with(vcs.base(root, vcs.JJ), "land", "--yes", "-r", "@"),
        { stderr = "stdout", cwd = root }
    )
    return code == 0, out
end

return M
