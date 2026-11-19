local check = require("dev.board.check")
local dev_os = require("dev.os")
local forge = require("dev.forge")
local fs = require("dev.fs")
local dev_remote = require("dev.remote")
local push = require("dev.cmd.push")
local review = require("dev.board.review")
local board_select = require("dev.board.select")
local templates = require("dev.templates")
local vcs = require("dev.vcs")

---@class dev.board.land
local M = {}

local SHAPE_TEMPLATE = 'if(empty, "empty", "full") ++ " " ++ if(description == "", "bare", "named")'
local COMMIT_TEMPLATE = 'commit_id ++ "\\n"'
local WORKSPACE_TEMPLATE = 'if(target.current_working_copy(), name ++ "\\n")'
local TRUNK_REVSET = "trunk()"
local BARE_LINK = 'empty() & description(exact:"") & ~merges()'
local COMMIT_CHARS = 12
local FETCH_SECONDS = 120
local FETCH_ATTEMPTS = 2
local FETCH_TIMEOUT_CODE = 124
local KEY_REFUSAL = "agent refused operation"

---Shorten a commit id for a message.
---@param commit string the full commit id
---@return string short the first characters
function M.short(commit)
    return commit:sub(1, COMMIT_CHARS)
end

local function sentence(text)
    text = text:gsub("^%l", string.upper)
    if not text:find("%.$") then
        text = text .. "."
    end
    return text
end

local function tool_name(root)
    if vcs.backend(root) == vcs.GIT then
        return vcs.LABEL[vcs.GIT]
    end
    return "The `jj` command"
end

local function jj(root, ...)
    return vcs.with(vcs.base(root, vcs.JJ, { quiet = true }), ...)
end

local function jj_out(root, ...)
    local out, code = dev_os.capture(jj(root, ...), { stderr = "null" })
    if code ~= 0 then
        return nil
    end
    return out
end

local function git_out(root, ...)
    local argv = vcs.with(vcs.base(root, vcs.GIT), ...)
    local out, code = dev_os.capture(argv, { stderr = "null" })
    if code ~= 0 then
        return nil
    end
    return out
end

local function interdiff(root, commit)
    return jj_out(root, "interdiff", "--from", commit, "--to", "@", "--name-only")
end

local function identical(root, commit, state)
    if vcs.backend(root) == vcs.GIT then
        local merged = git_out(
            root,
            "merge-tree",
            "--write-tree",
            "--merge-base=" .. commit .. "^",
            state.commit .. "^",
            commit
        )
        local tree = git_out(root, "rev-parse", state.commit .. "^{tree}")
        return merged ~= nil and tree ~= nil and merged:match("^%x+") == tree:match("^%x+")
    end
    return interdiff(root, commit) == ""
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
            seen[commit] = identical(root, commit, state)
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

local function worktree_problem(root, short)
    local dirs, code = dev_os.capture(
        vcs.with(
            vcs.base(root, vcs.GIT),
            "rev-parse",
            "--path-format=absolute",
            "--git-dir",
            "--git-common-dir"
        ),
        { stderr = "null" }
    )
    local dir, common = dirs:match("^([^\n]+)\n([^\n]+)\n?$")
    if code ~= 0 or not dir then
        return "Git could not read the worktree of " .. root .. "."
    end
    if dir == common then
        return nil
    end
    local out, branch_code = dev_os.capture(
        vcs.with(vcs.base(root, vcs.GIT), "symbolic-ref", "--short", "-q", "HEAD"),
        { stderr = "null" }
    )
    local branch = out:gsub("\n$", "")
    if branch_code == 0 and branch == short then
        return nil
    end
    local where = branch_code == 0 and ("the branch " .. branch) or "a detached HEAD"
    return string.format(
        "This is the worktree on %s, not the one named for %s. "
            .. "Run `dev ws new %s` and work from there.",
        where,
        short,
        short
    )
end

---Say whether the working copy sits in the workspace `dev ws new` names for a card.
---@param root string the project root
---@param short string the card's short id, which names its workspace
---@return string? problem why this is the wrong workspace, nil in the right one or a git checkout
---   that is not a linked worktree
function M.workspace_problem(root, short)
    local backend = vcs.backend(root)
    if backend == vcs.GIT then
        return worktree_problem(root, short)
    end
    if backend ~= vcs.JJ then
        return nil
    end
    local out, code =
        dev_os.capture(jj(root, "workspace", "list", "-T", WORKSPACE_TEMPLATE), { stderr = "null" })
    if code ~= 0 then
        return "The `jj` command could not read the workspace of " .. root .. "."
    end
    local names = {}
    for name in out:gmatch("[^\n]+") do
        if name == short then
            return nil
        end
        names[#names + 1] = name
    end
    return string.format(
        "This is the workspace %s, not the one named for %s. "
            .. "Run `dev ws new %s` and work from there.",
        table.concat(names, ", "),
        short,
        short
    )
end

---Name the change a landing would carry.
---
---The working-copy commit must hold work, carry a description and have no conflicts.
---@param root string the project root
---@return dev.board.check.State? state the commit and change
---@return string? message why the working copy cannot land
function M.state(root)
    local state, message = check.state(root)
    if not state then
        return nil, message
    end
    if vcs.backend(root) == vcs.GIT then
        local files = git_out(
            root,
            "diff-tree",
            "-m",
            "-r",
            "--root",
            "--no-commit-id",
            "--name-only",
            state.commit
        )
        local body = git_out(root, "log", "-1", "--format=%B", state.commit)
        if not files or not body then
            return nil, "Git could not read the HEAD commit of " .. root .. "."
        end
        if not files:match("%S") then
            return nil, "The working-copy commit is empty. There is no change to land."
        end
        if not body:match("%S") then
            return nil, "The working-copy commit has no description."
        end
        return state
    end
    local out, code = dev_os.capture(
        jj(root, "log", "-r", "@", "--no-graph", "-T", SHAPE_TEMPLATE),
        { stderr = "null" }
    )
    local shape, naming = out:match("^(%a+) (%a+)\n?$")
    if code ~= 0 or not shape then
        return nil, "The `jj` command could not read the working-copy commit of " .. root .. "."
    end
    if shape == "empty" then
        return nil, "The working-copy commit is empty. There is no change to land."
    end
    if naming == "bare" then
        return nil, "The working-copy commit has no description."
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
    local function has_kind(kind, matches, of)
        for _, record in ipairs(reviews) do
            if record.kind == kind and record.of == of and matches(record.commit) then
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
    local function has_here(kind, of)
        return has_kind(kind, same, of)
    end
    local missing = {}
    for _, kind in ipairs(review.OF_KINDS) do
        if not has_here(kind) then
            if not has_any(kind) then
                missing[#missing + 1] = string.format(
                    "No %s review of change %s. Record one with `dev board review --kind %s`.",
                    kind,
                    state.change,
                    kind
                )
            elseif not has_here(review.Kind.RECHECK, kind) then
                missing[#missing + 1] = string.format(
                    "The %s review is of an earlier commit than %s. "
                        .. "Record a recheck with `dev board review --kind recheck --of %s --rev @`.",
                    kind,
                    M.short(state.commit),
                    kind
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
            latest[record.kind .. "/" .. (record.of or "")] = record
        end
    end
    local refused = {}
    local slots = { review.Kind.CODE .. "/", review.Kind.STYLE .. "/" }
    for _, of in ipairs(review.OF_KINDS) do
        slots[#slots + 1] = review.Kind.RECHECK .. "/" .. of
    end
    for _, slot in ipairs(slots) do
        local record = latest[slot]
        if record and record.verdict == review.Verdict.NEEDS_WORK then
            refused[#refused + 1] = string.format(
                "The %s review by %s at commit %s says needs-work. Fix it and record a new review.",
                record.kind,
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
        return "The card has no checks rows. Nothing proves the change."
    end
    local latest, unreadable
    for _, comment in ipairs(comments) do
        local record = check.parse(comment.body)
        if record and record.commit == state.commit and record.mode == check.Mode.RUN then
            latest, unreadable = record, false
        elseif not record then
            local commit, mode = check.unreadable(comment.body)
            if commit == state.commit and mode ~= check.Mode.EXPECT_FAIL then
                latest, unreadable = nil, true
            end
        end
    end
    if not latest and unreadable then
        return string.format(
            "A check record exists at commit %s but could not be read. "
                .. "It proves nothing. Run `dev board check` again.",
            M.short(state.commit)
        )
    end
    if not latest then
        return string.format(
            "No run of `dev board check` is recorded at commit %s. "
                .. "Run it on this commit. A `--expect-fail` record does not count.",
            M.short(state.commit)
        )
    end
    if #latest.rows ~= #rows then
        return string.format(
            "The newest check run at commit %s has %d rows and the card has %d. "
                .. "Run `dev board check` again.",
            M.short(state.commit),
            #latest.rows,
            #rows
        )
    end
    if latest.sum ~= check.fingerprint(rows) then
        return string.format(
            "The checks rows changed since the newest check run at commit %s. "
                .. "Run `dev board check` again.",
            M.short(state.commit)
        )
    end
    local bad = {}
    for i, row in ipairs(latest.rows) do
        if row.result ~= check.Result.PASS then
            bad[#bad + 1] = string.format("Row %d, `%s`, ended with %s.", i, rows[i], row.result)
        end
    end
    if #bad > 0 then
        return string.format(
            "The newest check run at commit %s did not pass every row. %s",
            M.short(state.commit),
            table.concat(bad, " ")
        )
    end
end

---Fetch a remote, retrying once when the ssh agent refuses the signature.
---
---A fetch that runs past the limit returns code 124. After a timeout or a second refusal the
---output is led by what the owner must do.
---@param root string the project root, a jj project
---@param remote string the remote to fetch
---@return string output what the fetch wrote
---@return integer code the exit status of the last attempt
local function fetch(root, remote)
    local argv
    if vcs.backend(root) == vcs.GIT then
        argv = vcs.with(vcs.base(root, vcs.GIT), "fetch", remote)
    else
        argv = jj(root, "git", "fetch", "--remote", remote)
    end
    local seconds = tonumber(os.getenv("DEV_LAND_FETCH_SECONDS")) or FETCH_SECONDS
    local out, code, refused
    for _ = 1, FETCH_ATTEMPTS do
        out, code = dev_os.capture_timed(argv, seconds, { merge = true })
        refused = out:find(KEY_REFUSAL, 1, true) ~= nil
        if code == 0 or not refused then
            break
        end
    end
    if code == FETCH_TIMEOUT_CODE then
        local hint = "The fetch ran past %d seconds. The hardware key may be waiting for a touch. "
            .. "Touch it and run `dev board land` again.\n%s"
        return string.format(hint, seconds, out), code
    end
    if code ~= 0 and refused then
        local hint = "The ssh agent refused the signature twice. "
            .. "Touch the hardware key and run `dev board land` again.\n"
        return hint .. out, code
    end
    return out, code
end

local function parent_on_trunk(root)
    local parents =
        dev_os.capture(jj(root, "log", "-r", "@-", "--no-graph", "-T", COMMIT_TEMPLATE), {
            stderr = "null",
        })
    local on_trunk = dev_os.capture(
        jj(root, "log", "-r", "@- & trunk()", "--no-graph", "-T", COMMIT_TEMPLATE),
        { stderr = "null" }
    )
    return count_lines(parents) == 1 and on_trunk == parents
end

local function base_revset(commit)
    return string.format("heads((::%s-) ~ (%s))", commit, BARE_LINK)
end

local function git_parents(root, rev)
    local out = git_out(root, "rev-list", "--parents", "-n", "1", rev)
    if out == nil then
        return nil
    end
    local parents = {}
    for id in out:gmatch("%x+") do
        parents[#parents + 1] = id
    end
    table.remove(parents, 1)
    return parents
end

local function git_parent_on_trunk(root, remote)
    local ref, why = vcs.remote_trunk(root, remote)
    if not ref then
        return nil, "The remote " .. why .. "."
    end
    local trunk = git_out(root, "rev-parse", "--verify", ref .. "^{commit}")
    local parents = git_parents(root, "HEAD")
    if not trunk or not parents then
        return nil, "Git could not read the parent of the working-copy commit or " .. ref .. "."
    end
    return #parents == 1 and parents[1] == trunk:match("^%x+")
end

---Fetch the remote of record and say whether the change still sits on trunk.
---@param root string the project root
---@return string? problem what is wrong, nil when the change's parent is the current trunk
function M.trunk_problem(root)
    local found, why = forge.resolve(root)
    if not found then
        return "Trunk cannot be compared. " .. sentence(why)
    end
    local out, code = fetch(root, found.remote)
    if code ~= 0 then
        return string.format(
            "The fetch from %s failed. Trunk cannot be compared.\n%s",
            found.remote,
            out
        )
    end
    if vcs.backend(root) == vcs.GIT then
        local on_trunk, read_why = git_parent_on_trunk(root, found.remote)
        if on_trunk == nil then
            return "Trunk cannot be compared. " .. read_why
        end
        if not on_trunk then
            return "Trunk has moved since the change was built. Rebase it onto the remote trunk, "
                .. "then record the reviews and run `dev board check` again."
        end
        return nil
    end
    if not parent_on_trunk(root) then
        return "Trunk has moved since the change was built. "
            .. "Rebase it onto `trunk()`, then record the reviews and run `dev board check` again."
    end
end

local function git_rebase(root, remote)
    local on_trunk, why = git_parent_on_trunk(root, remote)
    if on_trunk == nil then
        return nil, "Trunk cannot be compared. " .. why
    end
    if on_trunk then
        return false
    end
    local ref = assert(vcs.remote_trunk(root, remote))
    local parents = git_parents(root, "HEAD")
    if not parents or #parents ~= 1 then
        return nil, "The HEAD commit is a merge or has no parent. Git cannot rebase it onto trunk."
    end
    local stacked = git_out(root, "rev-list", "--count", ref .. "..HEAD~1")
    if not stacked or stacked:match("^0%s*$") == nil then
        return nil, "The change sits on an unlanded parent. Land the parent first."
    end
    local out, code =
        dev_os.capture(vcs.with(vcs.base(root, vcs.GIT), "rebase", ref), { stderr = "stdout" })
    if code ~= 0 then
        dev_os.capture(vcs.with(vcs.base(root, vcs.GIT), "rebase", "--abort"), { stderr = "null" })
        return nil, "The rebase onto trunk failed. " .. out
    end
    return true
end

local function child_workspaces(root)
    local out = jj_out(
        root,
        "log",
        "-r",
        "descendants(@) ~ @",
        "--no-graph",
        "-T",
        'working_copies.map(|w| w.name() ++ "\\n").join("")'
    )
    if out == nil then
        return nil
    end
    local children, seen = {}, {}
    for printed in out:gmatch("[^\n]+") do
        local name = printed
        if printed:sub(1, 1) == '"' and printed:sub(-1) == '"' then
            name = printed:sub(2, -2):gsub("\\(.)", "%1")
        end
        local path = jj_out(root, "workspace", "root", "--name", name)
        if path == nil then
            return nil
        end
        if not seen[name] then
            seen[name] = true
            local child = { name = name, path = path:gsub("\n$", "") }
            jj_out(child.path, "log", "-r", "@", "--no-graph", "-T", "''")
            children[#children + 1] = child
        end
    end
    return children
end

local UPDATE_STALE = "Run `jj workspace update-stale` there."

local function update_child(root, child)
    local conflict = jj_out(
        root,
        "log",
        "-r",
        string.format('"%s"@', (child.name:gsub('[\\"]', "\\%0"))),
        "--no-graph",
        "-T",
        'conflict ++ "\\n"'
    )
    if conflict == nil or conflict:find("true", 1, true) then
        return string.format(
            "Left the workspace %s at %s alone: its commit has conflicts after the rebase. %s",
            child.name,
            child.path,
            UPDATE_STALE
        )
    end
    local out, code =
        dev_os.capture(jj(child.path, "workspace", "update-stale"), { stderr = "stdout" })
    if code ~= 0 then
        return string.format(
            "The workspace %s at %s could not be updated. %s %s",
            child.name,
            child.path,
            UPDATE_STALE,
            out
        )
    end
    return string.format(
        "Moved the workspace %s at %s onto the rebased commit.",
        child.name,
        child.path
    )
end

---Fetch the remote of record and rebase the working-copy change onto trunk when it sits elsewhere.
---
---The change's descendants move with it, and each workspace whose working copy sat on it is updated
---unless its commit has conflicts.
---@param root string the project root
---@return boolean? rebased true when the change moved, false when it already sat on trunk
---@return string? problem why trunk could not be read or the rebase failed
---@return string[]? notes one sentence for each workspace the rebase moved or left alone
function M.rebase(root)
    local UNLANDED = "::@- ~ ::trunk()"
    local found, why = forge.resolve(root)
    if not found then
        return nil, "Trunk cannot be compared. " .. sentence(why)
    end
    local out, code = fetch(root, found.remote)
    if code ~= 0 then
        return nil,
            string.format(
                "The fetch from %s failed. Trunk cannot be compared.\n%s",
                found.remote,
                out
            )
    end
    if vcs.backend(root) == vcs.GIT then
        return git_rebase(root, found.remote)
    end
    if parent_on_trunk(root) then
        return false
    end
    local stacked = dev_os.capture(
        jj(
            root,
            "log",
            "-r",
            string.format("(%s) ~ (%s)", UNLANDED, BARE_LINK),
            "--no-graph",
            "-T",
            COMMIT_TEMPLATE
        ),
        { stderr = "null" }
    )
    if stacked ~= "" then
        return nil, "The change sits on an unlanded parent. Land the parent first."
    end
    local bare = jj_out(
        root,
        "log",
        "-r",
        string.format("(%s) & (%s)", UNLANDED, BARE_LINK),
        "--no-graph",
        "-T",
        COMMIT_TEMPLATE
    )
    if bare == nil then
        return nil, "The `jj` command could not read the empty parents of the change."
    end
    local ids = {}
    for id in bare:gmatch("%x+") do
        ids[#ids + 1] = id
    end
    if #ids > 0 then
        out, code = dev_os.capture(jj(root, "abandon", unpack(ids)), { stderr = "stdout" })
        if code ~= 0 then
            return nil, "The empty parent could not be abandoned. " .. out
        end
    end
    local children = child_workspaces(root)
    if children == nil then
        return nil, "The `jj` command could not read the workspaces that sit on the change."
    end
    out, code =
        dev_os.capture(jj(root, "rebase", "-s", "@", "-d", "trunk()"), { stderr = "stdout" })
    if code ~= 0 then
        return nil, "The rebase onto trunk failed. " .. out
    end
    local notes = {}
    for _, child in ipairs(children) do
        notes[#notes + 1] = update_child(root, child)
    end
    return true, nil, notes
end

local function file_set(out)
    local set = {}
    for line in out:gmatch("[^\n]+") do
        set[line] = true
    end
    return set
end

---@class dev.board.land.uncarried_problem.Opts
---@field root string the project root
---@field comments {body: string}[] the card's comments, oldest first
---@field at {commit: string, change: string} the checked commit and the change id
---@field rows string[] the card's checks rows

---@param opts dev.board.land.uncarried_problem.Opts the checked commit and the card's records
---@return string? problem what the checked commit lacks, nil when it lacks nothing
local function uncarried_problem(opts)
    local problem = M.checks_problem(opts.comments, opts.at, opts.rows)
    if problem then
        return problem
    end
    local lacking = M.missing_reviews(opts.comments, opts.at, opts.root)
    if #lacking > 0 then
        return table.concat(lacking, " ")
    end
    local refused = M.refused_reviews(opts.comments, opts.at, opts.root)
    if #refused > 0 then
        return table.concat(refused, " ")
    end
end

local function checked_commits(root, comments, state, rows)
    local found, seen, why = {}, {}, nil
    for i = #comments, 1, -1 do
        local record = check.parse(comments[i].body)
        if
            record
            and record.mode == check.Mode.RUN
            and record.change == state.change
            and record.commit ~= state.commit
            and not seen[record.commit]
        then
            seen[record.commit] = true
            local at = { commit = record.commit, change = state.change }
            local problem = uncarried_problem({
                root = root,
                comments = comments,
                at = at,
                rows = rows,
            })
            if problem then
                why = why
                    or string.format(
                        "The check at commit %s cannot carry over to this commit. %s",
                        M.short(record.commit),
                        problem
                    )
            else
                found[#found + 1] = record.commit
            end
        end
    end
    return found, why
end

local function git_carry_problem(root, state, commit)
    local label = M.short(commit)
    local parents = git_parents(root, commit)
    if parents == nil then
        return string.format("Git could not read the checked commit %s.", label), true
    end
    local code = 1
    if #parents == 1 then
        local _, status = dev_os.capture(
            vcs.with(
                vcs.base(root, vcs.GIT),
                "merge-base",
                "--is-ancestor",
                parents[1],
                state.commit .. "^"
            ),
            { stderr = "null" }
        )
        code = status
    end
    if code ~= 0 and code ~= 1 then
        return string.format("Git could not read the ancestor of the checked commit %s.", label),
            true
    end
    if code == 1 then
        return string.format(
            "The checked commit %s does not sit on a single ancestor of trunk.",
            label
        )
    end
    if not identical(root, commit, state) then
        return string.format(
            "This commit differs from the checked commit %s. Run `dev board check` again.",
            label
        )
    end
end

local function parent_landed(root, base_rev)
    local change = jj_out(root, "log", "-r", base_rev, "--no-graph", "-T", 'change_id ++ "\\n"')
    local id = change and change:match("%S+")
    if not id then
        return nil
    end
    local landed = jj_out(
        root,
        "log",
        "-r",
        string.format("change_id(%s) & ::@-", id),
        "--no-graph",
        "-T",
        COMMIT_TEMPLATE
    )
    if landed == nil then
        return nil
    end
    return landed ~= ""
end

local function carry_problem(root, state, commit)
    if vcs.backend(root) == vcs.GIT then
        return git_carry_problem(root, state, commit)
    end
    local label = M.short(commit)
    local change = jj_out(root, "log", "-r", commit, "--no-graph", "-T", 'change_id ++ "\\n"')
    if change == nil then
        return string.format("The `jj` command could not read the checked commit %s.", label), true
    end
    if change ~= state.change .. "\n" then
        return string.format(
            "The checked commit %s is not of change %s in this repo.",
            label,
            state.change
        )
    end
    local base_rev = base_revset(commit)
    local base = jj_out(root, "log", "-r", base_rev, "--no-graph", "-T", COMMIT_TEMPLATE)
    if base == nil then
        return string.format(
            "The `jj` command could not read the parent of the checked commit %s.",
            label
        ),
            true
    end
    local ancestor = count_lines(base) == 1
        and jj_out(root, "log", "-r", base_rev .. " & ::@-", "--no-graph", "-T", COMMIT_TEMPLATE)
    if ancestor ~= nil and ancestor ~= base and count_lines(base) == 1 then
        local landed = parent_landed(root, base_rev)
        if landed == nil then
            ancestor = nil
        elseif landed then
            ancestor = base
        end
    end
    if ancestor == nil then
        return string.format(
            "The `jj` command could not read the ancestor of the checked commit %s.",
            label
        ),
            true
    end
    if ancestor ~= base then
        return string.format(
            "The checked commit %s does not sit on a single ancestor of trunk.",
            label
        )
    end
    local differs = interdiff(root, commit)
    if differs == nil then
        return string.format(
            "The `jj` command could not compare the checked commit %s with this one.",
            label
        ),
            true
    end
    if differs ~= "" then
        return string.format(
            "This commit differs from the checked commit %s. Run `dev board check` again.",
            label
        )
    end
end

local function sorted_set(set)
    local paths = {}
    for path in pairs(set) do
        paths[#paths + 1] = path
    end
    table.sort(paths)
    return paths
end

local function sorted_paths(root, rev, template)
    local out = jj_out(root, "log", "-r", rev, "--no-graph", "-T", template)
    if not out then
        return nil
    end
    return sorted_set(file_set(out))
end

local function git_paths(root, rev, opts)
    local only_added = opts.only_added
    local out = git_out(
        root,
        "diff-tree",
        "-m",
        "-r",
        "--root",
        "--no-commit-id",
        "-M",
        "--name-status",
        "-z",
        rev
    )
    if not out then
        return nil
    end
    local words = {}
    for word in out:gmatch("([^%z]+)") do
        words[#words + 1] = word
    end
    local set = {}
    local i = 1
    while i <= #words do
        local kind = words[i]:sub(1, 1)
        local moved = kind == "R" or kind == "C"
        local path = words[i + (moved and 2 or 1)]
        if path and (not only_added or (kind ~= "M" and kind ~= "T" and kind ~= "D")) then
            set[path] = true
            if moved and opts.with_sources then
                set[words[i + 1]] = true
            end
        end
        i = i + (moved and 3 or 2)
    end
    return sorted_set(set)
end

---List the files a commit adds, a moved or copied file counting at its new path.
---@param root string the project root
---@param rev string the revset of one jj commit or the id of one git commit
---@return string[]? paths the sorted paths, nil when the files could not be read
function M.added(root, rev)
    if vcs.backend(root) == vcs.GIT then
        return git_paths(root, rev, { only_added = true })
    end
    local ADDED_TEMPLATE = 'self.diff().files().filter(|f| f.status() != "modified" && '
        .. 'f.status() != "removed").map(|f| f.target().path() ++ "\\n").join("")'
    return sorted_paths(root, rev, ADDED_TEMPLATE)
end

---List the files the working-copy commit touches, a moved or copied file counting at both paths.
---@param root string the project root
---@return string[]? paths the sorted paths, nil when they could not be read
function M.card_touched(root)
    if vcs.backend(root) == vcs.GIT then
        return git_paths(root, "HEAD", { with_sources = true })
    end
    local template = 'self.diff().files().map(|f| f.source().path() ++ "\\n" ++ '
        .. 'f.target().path() ++ "\\n").join("")'
    return sorted_paths(root, "@", template)
end

---List the files a commit touches, a moved or copied file counting at its new path.
---@param root string the project root
---@param rev string the revset of one jj commit or the id of one git commit
---@return string[]? paths the sorted paths, nil when the files could not be read
function M.touched(root, rev)
    if vcs.backend(root) == vcs.GIT then
        return git_paths(root, rev, {})
    end
    local TOUCHED_TEMPLATE = 'self.diff().files().map(|f| f.target().path() ++ "\\n").join("")'
    return sorted_paths(root, rev, TOUCHED_TEMPLATE)
end

---Turn a path glob into a Lua pattern, where `**` crosses a slash and `*` and `?` stay inside one
---path segment.
---@param glob string the glob
---@return string pattern the anchored Lua pattern
local function glob_pattern(glob)
    local escaped = glob:gsub("[%^%$%(%)%%%.%[%]%+%-]", "%%%0")
    escaped = escaped:gsub("%*%*", "\0"):gsub("%*", "[^/]*"):gsub("%?", "[^/]"):gsub("%z", ".*")
    return "^" .. escaped .. "$"
end

---Say whether a landing commit touches a path that deploys.
---@param touched string[]? the paths the commit touches, nil when they could not be read
---@param globs string[] the `[board.land] deployed` globs
---@return boolean deploys true when a path matches a glob, or when the paths could not be read
function M.deploys(touched, globs)
    if not touched then
        return true
    end
    for _, path in ipairs(touched) do
        for _, glob in ipairs(globs) do
            if path:find(glob_pattern(glob)) then
                return true
            end
        end
    end
    return false
end

---Name why a lint-set template file may not call a dev function the baked dev lacks.
---@param root string the project root, a jj project
---@param touched string[] the paths the landing commit touches
---@return string? problem the refusal, nil when the landing may go ahead
function M.template_problem(root, touched)
    local base = templates.BASE .. "/"
    local changed_template = false
    for _, path in ipairs(touched) do
        if path:sub(1, #base) == base then
            changed_template = true
        end
    end
    if not changed_template then
        return nil
    end
    local backend = vcs.backend(root) or vcs.JJ
    local listed
    if backend == vcs.GIT then
        listed = git_out(root, "ls-tree", "-r", "-z", "--name-only", "HEAD", "--", templates.BASE)
        listed = listed and listed:gsub("%z", "\n")
    else
        listed = jj_out(
            root,
            "file",
            "list",
            "-r",
            "@",
            "-T",
            'path ++ "\\n"',
            'root:"' .. templates.BASE .. '"'
        )
    end
    if not listed then
        return tool_name(root) .. " could not list the lint-set template files."
    end
    local baked = {}
    for entry in (fs.read(root .. "/" .. templates.BAKED) or ""):gmatch("[^\n]+") do
        baked[entry] = true
    end
    local lacking = {}
    for path in listed:gmatch("[^\n]+") do
        for _, call in ipairs(templates.dev_calls(fs.read(root .. "/" .. path) or "")) do
            if not baked[call] then
                lacking[call] = true
            end
        end
    end
    local names = {}
    for call in pairs(lacking) do
        names[#names + 1] = call
    end
    if #names == 0 then
        return nil
    end
    table.sort(names)
    return "The lint-set template calls "
        .. table.concat(names, ", ")
        .. ", which "
        .. templates.BAKED
        .. " does not list as baked into ci's images. Land the dev change first,"
        .. " have infra rebake the ci images,"
        .. " then land the template change with the entries added to "
        .. templates.BAKED
        .. "."
end

---@class dev.board.land.Opts
---@field root string the project root, a jj project
---@field comments {body: string}[] the card's comments, oldest first
---@field state dev.board.check.State the commit that would land
---@field rows string[] the card's checks rows

local function rebase_carry(opts)
    local root, comments, state, rows = opts.root, opts.comments, opts.state, opts.rows
    local candidates, unmet = checked_commits(root, comments, state, rows)
    if #candidates == 0 then
        return nil, unmet
    end
    local moved = M.trunk_problem(root)
    if moved then
        return nil, moved, true
    end
    local newest_problem
    for _, commit in ipairs(candidates) do
        local problem, failed_read = carry_problem(root, state, commit)
        if not problem then
            return commit
        end
        if failed_read then
            return nil, problem, true
        end
        newest_problem = newest_problem or problem
    end
    return nil, newest_problem
end

local function same_tree(root, commit, state)
    if vcs.backend(root) == vcs.GIT then
        local old = git_out(root, "rev-parse", commit .. "^{tree}")
        local new = git_out(root, "rev-parse", state.commit .. "^{tree}")
        if old == nil or new == nil then
            return nil
        end
        return old == new
    end
    local out = jj_out(root, "diff", "--from", commit, "--to", "@", "--name-only")
    if out == nil then
        return nil
    end
    return out == ""
end

local function tree_carry(opts)
    local root, comments, state, rows = opts.root, opts.comments, opts.state, opts.rows
    local seen = {}
    for i = #comments, 1, -1 do
        local record = check.parse(comments[i].body)
        if
            record
            and record.mode == check.Mode.RUN
            and record.change == state.change
            and record.commit ~= state.commit
            and not seen[record.commit]
        then
            seen[record.commit] = true
            local at = { commit = record.commit, change = state.change }
            if not M.checks_problem(comments, at, rows) then
                local same = same_tree(root, record.commit, state)
                if same == nil then
                    return nil,
                        string.format(
                            "%s could not compare the checked commit %s with this one.",
                            tool_name(root),
                            M.short(record.commit)
                        )
                end
                if same then
                    return record.commit
                end
            end
        end
    end
end

---Find a checked commit whose check and reviews a rebased commit may keep.
---
---The rule holds when all of these are true:
---
---1. The change id is the same as the checked commit's.
---2. The checked commit sits on one ancestor of trunk, or on a parent that trunk now holds as a
---   rewrite of the same change, and the landing commit's parent is trunk.
---3. The interdiff against the checked commit is empty.
---4. The rebase left no conflict, which `land.state` checks before this runs.
---
---The checked commits are those of the change with a passing run and their reviews. They are tried
---newest first, the first that passes every test carries, and a refusal names the newest one's
---reason, unless a jj read fails, which refuses at once naming that read. A commit with a check
---record of its own, readable or not, never carries. When every checked commit lacks a passing
---check or a review, the problem names the newest one and what it lacks.
---
---A commit with a passing check, whatever its parent and reviews, also carries its check alone
---when its tree equals the landing commit's tree and the change id is the same, as after a squash
---of an unlanded parent into the change. The reviews do not carry then. The third value is true
---for that carry.
---@param opts dev.board.land.Opts the project, the card's records and the landing commit
---@return string? commit the checked commit the records carry over from
---@return string? problem why it is refused, nil when it carries or no commit was checked
---@return boolean? check_only true when only the check carries and the reviews stay stale
function M.carry(opts)
    local root, comments, state = opts.root, opts.comments, opts.state
    for _, comment in ipairs(comments) do
        local own = check.parse(comment.body)
        if
            (own and own.commit == state.commit)
            or check.unreadable(comment.body) == state.commit
        then
            return nil
        end
    end
    local commit, problem, stop = rebase_carry(opts)
    if commit or stop then
        return commit, problem
    end
    local same, read_problem = tree_carry(opts)
    if read_problem then
        return nil, read_problem
    end
    if same then
        local moved = M.trunk_problem(root)
        if moved then
            return nil, moved
        end
        return same, nil, true
    end
    return nil, problem
end

local CONFIG_PATH = ".dev/config.toml"

---Read the project config file as trunk holds it.
---@param root string the project root
---@return string? text the file's text, empty when trunk has no such file
---@return string? problem why trunk or its file could not be read
function M.trunk_config(root)
    if vcs.backend(root) == vcs.GIT then
        local found, why = forge.resolve(root)
        if not found then
            return nil, "Trunk cannot be read. " .. sentence(why)
        end
        local ref, ref_why = vcs.remote_trunk(root, found.remote)
        if not ref then
            return nil, "Trunk cannot be read. The remote " .. ref_why .. "."
        end
        local listed = git_out(root, "ls-tree", "--name-only", ref, "--", CONFIG_PATH)
        if listed == nil then
            return nil, "Git could not list " .. CONFIG_PATH .. " at " .. ref .. "."
        end
        if listed == "" then
            return ""
        end
        local text = git_out(root, "show", ref .. ":" .. CONFIG_PATH)
        if text == nil then
            return nil, "Git could not read " .. CONFIG_PATH .. " at " .. ref .. "."
        end
        return text
    end
    local listed = jj_out(root, "file", "list", "-r", TRUNK_REVSET, CONFIG_PATH)
    if listed == nil then
        return nil, "The `jj` command could not list " .. CONFIG_PATH .. " at trunk."
    end
    if listed == "" then
        return ""
    end
    local text = jj_out(root, "file", "show", "-r", TRUNK_REVSET, CONFIG_PATH)
    if text == nil then
        return nil, "The `jj` command could not read " .. CONFIG_PATH .. " at trunk."
    end
    return text
end

local function patch_text(root, commit)
    local out
    if vcs.backend(root) == vcs.GIT then
        out = git_out(
            root,
            "diff-tree",
            "-p",
            "--root",
            "--no-commit-id",
            "--no-color",
            "--no-ext-diff",
            "--binary",
            commit or "HEAD"
        )
    else
        out = jj_out(root, "diff", "--git", "--color", "never", "-r", commit or "@")
    end
    if out == nil then
        return nil
    end
    local lines = {}
    for line in out:gmatch("[^\n]*\n?") do
        if line ~= "" and not line:find("^@@") and not line:find("^index ") then
            lines[#lines + 1] = line
        end
    end
    return table.concat(lines)
end

---@class dev.board.land.recheck_problem.Opts
---@field root string the project root, a jj project
---@field commit string the checked commit the landing commit carries from
---@field card string the short id of the card that lands
---@field rows any the `[board.land] recheck` value
---@field note fun(text: string) says which row is about to run

---Rerun the configured recheck rows on the landing commit when its patch is not the checked one.
---
---The patch is the commit's diff with its context lines, read without the hunk headers and blob
---ids, so a rebase that moves the lines or lets trunk touch other files leaves it equal and runs
---no row. A row fails the landing when it does not pass, and the first failure stops the run.
---@param opts dev.board.land.recheck_problem.Opts the project, the carried commit and the
---   configured rows
---@return string? problem the refusal naming the failing row and its run id, nil when none ran or
---   every row passed
function M.recheck_problem(opts)
    local rows = opts.rows
    if rows == nil or (type(rows) == "table" and #rows == 0) then
        return nil
    end
    if type(rows) ~= "table" then
        return "The `recheck` setting of `[board.land]` must be a list of commands."
    end
    local argvs = {}
    for i, row in ipairs(rows) do
        if type(row) ~= "string" then
            return "The `recheck` setting of `[board.land]` has a row "
                .. i
                .. " that is not a string."
        end
        local argv, why = check.argv(row)
        if not argv then
            return "The `recheck` setting of `[board.land]` has a row "
                .. i
                .. " that cannot be run. "
                .. sentence(why)
        end
        argvs[i] = argv
    end
    local old, new = patch_text(opts.root, opts.commit), patch_text(opts.root, nil)
    if old == nil or new == nil then
        return string.format(
            "%s could not read the patch of the checked commit %s.",
            tool_name(opts.root),
            M.short(opts.commit)
        )
    end
    if old == new then
        return nil
    end
    local ran = {}
    for i, argv in ipairs(argvs) do
        local narrowed, count = board_select.narrow(opts.root, argv, function()
            return M.card_touched(opts.root)
        end)
        local narrowing = count > 0 and string.format(", narrowed to %d suites", count) or ""
        opts.note(
            string.format("Rechecking row %d of %d with `%s`%s.", i, #argvs, rows[i], narrowing)
        )
        ran[i] = check.run({
            root = opts.root,
            run = rows[i],
            argv = narrowed,
            seconds = check.DEFAULT_SECONDS,
            env = {
                [dev_remote.VERB_ENV] = dev_remote.Verb.CHECK,
                [dev_remote.CARD_ENV] = opts.card,
                [dev_remote.PRIORITY_ENV] = "1",
            },
        })
        if ran[i].result ~= check.Result.PASS then
            return string.format(
                "Trunk moved since the check at %s. "
                    .. "The recheck row failed. Nothing was pushed.\n%s\n%s",
                M.short(opts.commit),
                check.line(i, ran[i]),
                ran[i].tail
            )
        end
    end
end

---Read the commit a card's newest land note names.
---@param comments {body: string}[] the card's comments, oldest first
---@return string? commit the commit id, nil when the newest land note names none or there is none
function M.landed_commit(comments)
    local patterns = { "^Landed commit (%x+) ", "^landed (%x+) on [^%s/]+/main" }
    for i = #comments, 1, -1 do
        local body = comments[i].body
        for _, pattern in ipairs(patterns) do
            local commit = body:match(pattern)
            if commit then
                return commit
            end
        end
        if body:match("^Landed change ") then
            return nil
        end
    end
end

---Read the commit the working-copy commit sits on.
---@param root string the project root
---@return string? commit the full commit id, nil when it cannot be read or is not one commit
function M.base_commit(root)
    local out
    if vcs.backend(root) == vcs.GIT then
        out = git_out(root, "rev-parse", "HEAD^")
    else
        out = jj_out(root, "log", "-r", "@-", "--no-graph", "-T", COMMIT_TEMPLATE)
    end
    return out and out:match("^(%x+)\n$")
end

---Read the commit that holds a change on trunk, which `jj land` may have rewritten.
---@param root string the project root
---@param change string the change id, which survives the rewrite, ignored in git
---@return string? commit the full commit id, nil when trunk does not hold exactly one commit of the
---   change, or in git when the remote trunk does not hold HEAD
function M.trunk_commit(root, change)
    if vcs.backend(root) == vcs.GIT then
        local found = forge.resolve(root)
        if not found then
            return nil
        end
        local _, fetched = fetch(root, found.remote)
        local ref = fetched == 0 and vcs.remote_trunk(root, found.remote)
        local head = ref and git_out(root, "rev-parse", "HEAD")
        if not head or not git_out(root, "merge-base", "--is-ancestor", "HEAD", ref) then
            return nil
        end
        return head:match("^(%x+)\n$")
    end
    return M.fetched_commit(root, change .. " & ::trunk()")
end

---Read the one commit a revision names once the remote of record is fetched.
---@param root string the project root
---@param revset string the jj revset, or in git a revision where the default trunk revset names
---   the remote trunk
---@return string? commit the full commit id, nil when the fetch or the read failed or the revset
---   holds more than one commit
function M.fetched_commit(root, revset)
    local found = forge.resolve(root)
    if not found then
        return nil
    end
    local _, fetched = fetch(root, found.remote)
    if fetched ~= 0 then
        return nil
    end
    if vcs.backend(root) == vcs.GIT then
        local rev = revset
        if revset == TRUNK_REVSET then
            rev = vcs.remote_trunk(root, found.remote)
        end
        local read = rev and git_out(root, "rev-parse", "--verify", "-q", rev .. "^{commit}")
        return read and read:match("^(%x+)\n$")
    end
    local out, code = dev_os.capture(
        jj(root, "log", "-r", revset, "--no-graph", "-T", COMMIT_TEMPLATE),
        { stderr = "null" }
    )
    if code ~= 0 then
        return nil
    end
    return out:match("^(%x+)\n$")
end

---Say whether the working copy holds the tree of a commit and nothing else.
---@param root string the project root
---@param commit string the commit id
---@return boolean same true when the working-copy tree equals the commit's tree, false when it
---   differs or a read failed
function M.same_tree(root, commit)
    if vcs.backend(root) == vcs.GIT then
        local status = git_out(root, "status", "--porcelain")
        local head = git_out(root, "rev-parse", "HEAD^{tree}")
        local tree = git_out(root, "rev-parse", commit .. "^{tree}")
        return status == "" and head ~= nil and head == tree
    end
    return jj_out(root, "diff", "--from", commit, "--to", "@", "--name-only") == ""
end

---Say whether a commit is an ancestor of a revision, or the revision itself.
---@param root string the project root
---@param commit string the commit id, full or shortened
---@param rev string the jj revset naming one revision, or in git a revision
---@return boolean held true when the revision holds the commit
function M.holds(root, commit, rev)
    if vcs.backend(root) == vcs.GIT then
        return git_out(root, "merge-base", "--is-ancestor", commit, rev) ~= nil
    end
    local out = jj_out(
        root,
        "log",
        "-r",
        commit .. " & ::(" .. rev .. ")",
        "--no-graph",
        "-T",
        COMMIT_TEMPLATE
    )
    return out ~= nil and out:match("^%x+\n") ~= nil
end

local function git_run(root)
    local found, why = forge.resolve(root)
    if not found then
        return false, why
    end
    local ref, read_why = vcs.remote_trunk(root, found.remote)
    if not ref then
        return false, "The remote " .. read_why .. "."
    end
    local guard, guard_why = push.guard_path()
    if not guard then
        return false, guard_why
    end
    local head = git_out(root, "rev-parse", "HEAD")
    if not head then
        return false, "Git could not read the HEAD commit of " .. root .. "."
    end
    local branch = ref:sub(#found.remote + 2)
    local argv = push.git_argv({
        guard = guard,
        remote = found.remote,
        sha = head:match("^%x+"),
        ref = branch,
    })
    local out, code = dev_os.capture(argv, { stderr = "stdout", cwd = root })
    return code == 0, out
end

---Land the working-copy change with `jj land`, or push the HEAD commit to trunk in git.
---@param root string the project root
---@return boolean ok true when the land exited 0
---@return string output what the land printed
function M.run(root)
    if vcs.backend(root) == vcs.GIT then
        return git_run(root)
    end
    local out, code = dev_os.capture(
        vcs.with(vcs.base(root, vcs.JJ), "land", "--yes", "-r", "@"),
        { stderr = "stdout", cwd = root, env = { DEV_BOARD_LAND = "1" } }
    )
    return code == 0, out
end

return M
