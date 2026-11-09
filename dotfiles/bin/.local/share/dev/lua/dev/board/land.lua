local check = require("dev.board.check")
local devos = require("dev.os")
local forge = require("dev.forge")
local fs = require("dev.fs")
local review = require("dev.board.review")
local templates = require("dev.templates")
local vcs = require("dev.vcs")

---@class dev.board.land
local M = {}

local SHAPE_TEMPLATE = 'if(empty, "empty", "full") ++ " " ++ if(description == "", "bare", "named")'
local COMMIT_TEMPLATE = 'commit_id ++ "\\n"'
local WORKSPACE_TEMPLATE = 'if(target.current_working_copy(), name ++ "\\n")'
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

local function jj_out(root, ...)
    local out, code = devos.capture(jj(root, ...), { stderr = "null" })
    if code ~= 0 then
        return nil
    end
    return out
end

local function interdiff(root, commit)
    return jj_out(root, "interdiff", "--from", commit, "--to", "@", "--name-only")
end

local function same_patch(root, state)
    local seen = {}
    return function(commit)
        if commit == state.commit then
            return true
        end
        if not root then
            return false
        end
        if seen[commit] == nil then
            seen[commit] = interdiff(root, commit) == ""
        end
        return seen[commit]
    end
end

local function count_lines(text)
    local n = 0
    for _ in text:gmatch("[^\n]+") do
        n = n + 1
    end
    return n
end

---Say whether the working copy sits in the workspace `dev ws new` names for a card.
---@param root string the project root
---@param short string the card's short id, which names its workspace
---@return string? problem why this is the wrong workspace, nil in a git project or the right one
function M.workspace_problem(root, short)
    if vcs.backend(root) ~= vcs.JJ then
        return nil
    end
    local out, code =
        devos.capture(jj(root, "workspace", "list", "-T", WORKSPACE_TEMPLATE), { stderr = "null" })
    if code ~= 0 then
        return "jj could not read the workspace of " .. root
    end
    local names = {}
    for name in out:gmatch("[^\n]+") do
        if name == short then
            return nil
        end
        names[#names + 1] = name
    end
    return string.format(
        "this is the workspace %s, not the one named for %s, so run dev ws new %s and work from there",
        table.concat(names, ", "),
        short,
        short
    )
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
---A kind is met by a review of that kind at the commit, by one at an earlier commit of the
---change whose patch is the same (an empty `jj interdiff`, read only when `root` is given), or
---by one of that kind on the change at another commit plus a recheck at this commit.
---@param comments {body: string}[] the card's comments, oldest first
---@param state dev.board.check.State the commit that would land
---@param root string? the project root, which lets an identical earlier patch count
---@return string[] missing one line per review that is absent
function M.missing_reviews(comments, state, root)
    local same = same_patch(root, state)
    local reviews = {}
    for _, comment in ipairs(comments) do
        local record = review.parse(comment.body)
        if record and record.change == state.change then
            reviews[#reviews + 1] = record
        end
    end
    local function has_kind(kind, matches)
        for _, record in ipairs(reviews) do
            if record.kind == kind and matches(record.commit) then
                return true
            end
        end
        return false
    end
    local function has_any(kind)
        return has_kind(kind, function()
            return true
        end)
    end
    local function has_here(kind)
        return has_kind(kind, same)
    end
    local rechecked = has_here(review.KIND.RECHECK)
    local missing = {}
    for _, kind in ipairs({ review.KIND.CODE, review.KIND.STYLE }) do
        if not has_here(kind) then
            if not has_any(kind) then
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

---List the reviews at a commit whose latest verdict of their kind is needs-work.
---@param comments {body: string}[] the card's comments, oldest first
---@param state dev.board.check.State the commit that would land
---@param root string? the project root, which lets a review of an identical earlier patch count
---@return string[] refused one line per kind, naming the reviewer
function M.refused_reviews(comments, state, root)
    local same = same_patch(root, state)
    local latest = {}
    for _, comment in ipairs(comments) do
        local record = review.parse(comment.body)
        if record and record.change == state.change and same(record.commit) then
            latest[record.kind] = record
        end
    end
    local refused = {}
    for _, kind in ipairs(review.KINDS) do
        local record = latest[kind]
        if record and record.verdict == review.VERDICT.NEEDS_WORK then
            refused[#refused + 1] = string.format(
                "the %s review by %s at commit %s says needs-work; fix it and record a new review",
                kind,
                record.by,
                M.short(state.commit)
            )
        end
    end
    return refused
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
    local latest, unreadable
    for _, comment in ipairs(comments) do
        local record = check.parse(comment.body)
        if record and record.commit == state.commit and record.mode == check.MODE.RUN then
            latest, unreadable = record, false
        elseif not record then
            local commit, mode = check.unreadable(comment.body)
            if commit == state.commit and mode ~= check.MODE.EXPECT_FAIL then
                latest, unreadable = nil, true
            end
        end
    end
    if not latest and unreadable then
        return string.format(
            "a check record exists at commit %s but could not be read, so it proves nothing; run dev board check again",
            M.short(state.commit)
        )
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

local function parent_on_trunk(root)
    local parents =
        devos.capture(jj(root, "log", "-r", "@-", "--no-graph", "-T", COMMIT_TEMPLATE), {
            stderr = "null",
        })
    local on_trunk = devos.capture(
        jj(root, "log", "-r", "@- & trunk()", "--no-graph", "-T", COMMIT_TEMPLATE),
        { stderr = "null" }
    )
    return count_lines(parents) == 1 and on_trunk == parents
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
    if not parent_on_trunk(root) then
        return "trunk has moved since the change was built, so rebase it onto trunk(), then record the reviews and run dev board check again"
    end
end

---Fetch the remote of record and rebase the working-copy change onto trunk when it sits elsewhere.
---@param root string the project root, a jj project
---@return boolean? rebased true when the change moved, false when it already sat on trunk
---@return string? problem why trunk could not be read or the rebase failed
function M.rebase(root)
    local found, why = forge.resolve(root)
    if not found then
        return nil, "trunk cannot be compared: " .. why
    end
    local out, code =
        devos.capture(jj(root, "git", "fetch", "--remote", found.remote), { stderr = "stdout" })
    if code ~= 0 then
        return nil,
            string.format(
                "trunk cannot be compared, the fetch from %s failed: %s",
                found.remote,
                out
            )
    end
    if parent_on_trunk(root) then
        return false
    end
    local stacked = devos.capture(
        jj(root, "log", "-r", "::@- ~ ::trunk()", "--no-graph", "-T", COMMIT_TEMPLATE),
        { stderr = "null" }
    )
    if stacked ~= "" then
        return nil, "the change sits on an unlanded parent, so land the parent first"
    end
    out, code = devos.capture(jj(root, "rebase", "-r", "@", "-d", "trunk()"), { stderr = "stdout" })
    if code ~= 0 then
        return nil, "the rebase onto trunk failed: " .. out
    end
    return true
end

local function file_set(out)
    local set = {}
    for line in out:gmatch("[^\n]+") do
        set[line] = true
    end
    return set
end

local function checked_commits(comments, state, rows)
    local found = {}
    for i = #comments, 1, -1 do
        local record = check.parse(comments[i].body)
        if
            record
            and record.mode == check.MODE.RUN
            and record.change == state.change
            and record.commit ~= state.commit
        then
            local at = { commit = record.commit, change = state.change }
            if
                not M.checks_problem(comments, at, rows)
                and #M.missing_reviews(comments, at) == 0
                and #M.refused_reviews(comments, at) == 0
            then
                found[#found + 1] = record.commit
            end
        end
    end
    return found
end

local function carry_problem(root, state, commit)
    local label = M.short(commit)
    local change = jj_out(root, "log", "-r", commit, "--no-graph", "-T", 'change_id ++ "\\n"')
    if change == nil then
        return string.format("jj could not read the checked commit %s", label), true
    end
    if change ~= state.change .. "\n" then
        return string.format(
            "the checked commit %s is not of change %s in this repo",
            label,
            state.change
        )
    end
    local base = jj_out(root, "log", "-r", commit .. "-", "--no-graph", "-T", COMMIT_TEMPLATE)
    if base == nil then
        return string.format("jj could not read the parent of the checked commit %s", label), true
    end
    local ancestor = count_lines(base) == 1
        and jj_out(root, "log", "-r", commit .. "- & ::@-", "--no-graph", "-T", COMMIT_TEMPLATE)
    if ancestor == nil then
        return string.format("jj could not read the ancestor of the checked commit %s", label), true
    end
    if ancestor ~= base then
        return string.format(
            "the checked commit %s does not sit on a single ancestor of trunk",
            label
        )
    end
    local differs = interdiff(root, commit)
    if differs == nil then
        return string.format("jj could not compare the checked commit %s with this one", label),
            true
    end
    if differs ~= "" then
        return string.format(
            "this commit differs from the checked commit %s; run dev board check again",
            label
        )
    end
end

local function sorted_paths(root, rev, template)
    local out = jj_out(root, "log", "-r", rev, "--no-graph", "-T", template)
    if not out then
        return nil
    end
    local paths = {}
    for path in pairs(file_set(out)) do
        paths[#paths + 1] = path
    end
    table.sort(paths)
    return paths
end

---List the files a commit adds, a moved or copied file counting at its new path.
---@param root string the project root, a jj project
---@param rev string the revset of one commit
---@return string[]? paths the sorted paths, nil when jj could not read them
function M.added(root, rev)
    local ADDED_TEMPLATE = 'self.diff().files().filter(|f| f.status() != "modified" && '
        .. 'f.status() != "removed").map(|f| f.target().path() ++ "\\n").join("")'
    return sorted_paths(root, rev, ADDED_TEMPLATE)
end

---List the files a commit touches, a moved or copied file counting at its new path.
---@param root string the project root, a jj project
---@param rev string the revset of one commit
---@return string[]? paths the sorted paths, nil when jj could not read them
function M.touched(root, rev)
    local TOUCHED_TEMPLATE = 'self.diff().files().map(|f| f.target().path() ++ "\\n").join("")'
    return sorted_paths(root, rev, TOUCHED_TEMPLATE)
end

---Name why a commit may not change a lint-set template file and a dev module the template requires.
---@param root string the project root, a jj project
---@param touched string[] the paths the landing commit touches
---@return string? problem the refusal, nil when the landing may go ahead
function M.template_problem(root, touched)
    local MODULE_DIR = "dotfiles/bin/.local/share/dev/lua/dev/"
    local base = templates.BASE .. "/"
    local changed_template = false
    local changed = {}
    for _, path in ipairs(touched) do
        changed[path] = true
        if path:sub(1, #base) == base then
            changed_template = true
        end
    end
    if not changed_template then
        return nil
    end
    local listed = jj_out(
        root,
        "file",
        "list",
        "-r",
        "@",
        "-T",
        'path ++ "\\n"',
        'root:"' .. templates.BASE .. '"'
    )
    if not listed then
        return "jj could not list the lint-set template files."
    end
    local modules = {}
    for path in listed:gmatch("[^\n]+") do
        for name in (fs.read(root .. "/" .. path) or ""):gmatch('require%("(dev%.[%w_.]+)"%)') do
            local module = MODULE_DIR .. name:sub(5):gsub("%.", "/") .. ".lua"
            if changed[module] then
                modules[module] = true
            end
        end
    end
    local names = {}
    for module in pairs(modules) do
        names[#names + 1] = module
    end
    if #names == 0 then
        return nil
    end
    table.sort(names)
    return "This commit changes the lint-set template and "
        .. table.concat(names, ", ")
        .. ", which the template requires. Land the dev change first,"
        .. " have infra rebake the ci images, then land the template change."
end

---@class dev.board.land.Opts
---@field root string the project root, a jj project
---@field comments {body: string}[] the card's comments, oldest first
---@field state dev.board.check.State the commit that would land
---@field rows string[] the card's checks rows

---Find a checked commit whose check and reviews a rebased commit may keep.
---
---The rule holds when all of these are true:
---
---1. The change id is the same as the checked commit's.
---2. The checked commit sits on one ancestor of trunk, and the landing commit's parent is trunk.
---3. The interdiff against the checked commit is empty.
---4. The rebase left no conflict, which `land.state` checks before this runs.
---
---The checked commits are those of the change with a passing run and their reviews. They are tried
---newest first, the first that passes every test carries, and a refusal names the newest one's
---reason, unless a jj read fails, which refuses at once naming that read. A commit with a check
---record of its own, readable or not, never carries.
---@param opts dev.board.land.Opts the project, the card's records and the landing commit
---@return string? commit the checked commit the records carry over from
---@return string? problem why it is refused, nil when it carries or no commit was checked
function M.carry(opts)
    local root, comments, state, rows = opts.root, opts.comments, opts.state, opts.rows
    for _, comment in ipairs(comments) do
        local own = check.parse(comment.body)
        if
            (own and own.commit == state.commit)
            or check.unreadable(comment.body) == state.commit
        then
            return nil
        end
    end
    local candidates = checked_commits(comments, state, rows)
    if #candidates == 0 then
        return nil
    end
    local moved = M.trunk_problem(root)
    if moved then
        return nil, moved
    end
    local newest_problem
    for _, commit in ipairs(candidates) do
        local problem, failed_read = carry_problem(root, state, commit)
        if not problem then
            return commit
        end
        if failed_read then
            return nil, problem
        end
        newest_problem = newest_problem or problem
    end
    return nil, newest_problem
end

---Read the commit that holds a change on trunk, which `jj land` may have rewritten.
---@param root string the project root, a jj project
---@param change string the change id, which survives the rewrite
---@return string? commit the full commit id, nil when trunk does not hold exactly one commit of the
---   change
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
        { stderr = "stdout", cwd = root, env = { DEV_BOARD_LAND = "1" } }
    )
    return code == 0, out
end

return M
