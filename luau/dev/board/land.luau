local abandon = require("@dev/cmd/abandon")
local board = require("@dev/board")
local check = require("@dev/board/check")
local config = require("@dev/config")
local dev_command = require("@dev/command")
local dev_os = require("@dev/os")
local forge = require("@dev/forge")
local fs = require("@dev/fs")
local json = require("@dev/json")
local dev_remote = require("@dev/remote")
local review = require("@dev/board/review")
local board_select = require("@dev/board/select")
local vcs = require("@dev/vcs")

---@class dev.board.land
local M = {}

local SHAPE_TEMPLATE = 'if(empty, "empty", "full") ++ " " ++ if(description == "", "bare", "named")'
local COMMIT_TEMPLATE = 'commit_id ++ "\\n"'
local WORKSPACE_TEMPLATE = 'if(target.current_working_copy(), name ++ "\\n")'
local TRUNK_REVSET = "trunk()"
---The revset that names the trunk commit.
M.TRUNK_REVSET = TRUNK_REVSET
---What `state` says of a working copy that holds no change.
M.EMPTY = "The working-copy commit is empty. There is no change to land."
local BARE_LINK = 'empty() & description(exact:"") & ~merges()'
local COMMIT_CHARS = 12
local RUN_HISTORY = "1000"
local FETCH_SECONDS = 120
local FETCH_ATTEMPTS = 2
local FETCH_TIMEOUT_CODE = 124
local KEY_REFUSAL = "agent refused operation"

---Shorten a commit id for a message.
---@param commit string the full commit id
---@return string short the first characters
function M.short(commit: string): string
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

local function interdiff(root, commit, target)
    return jj_out(root, "interdiff", "--from", commit, "--to", target, "--name-only")
end

local function parent_tree(root, commit)
    local tree = git_out(root, "rev-parse", "--verify", "--quiet", commit .. "^^{tree}")
    if tree == nil then
        tree = git_out(root, "hash-object", "-t", "tree", "/dev/null")
    end
    return tree and tree:match("^%x+")
end

local function identical(root, commit, state)
    if vcs.backend(root) == vcs.GIT then
        local base = parent_tree(root, commit)
        local theirs = parent_tree(root, state.commit)
        if base == nil or theirs == nil then
            return false
        end
        local merged = git_out(
            root,
            "merge-tree",
            "--write-tree",
            "--merge-base=" .. base,
            theirs,
            commit .. "^{tree}"
        )
        local tree = git_out(root, "rev-parse", state.commit .. "^{tree}")
        return merged ~= nil and tree ~= nil and merged:match("^%x+") == tree:match("^%x+")
    end
    return interdiff(root, commit, state.commit) == ""
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
---@return string? message a `vcs.Reason`, or why the working copy cannot land
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
            return nil, M.EMPTY
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
        return nil, M.EMPTY
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
                        .. "Record a recheck with "
                        .. "`dev board review --kind recheck --of %s --rev @`.",
                    kind,
                    M.short(state.commit),
                    kind
                )
            end
        end
    end
    return missing
end

---Build the key of a review slot from its kind and the kind it rechecks.
---@param kind string a review kind
---@param of string? the kind a recheck covers
---@return string key
local function slot_key(kind, of)
    return kind .. "/" .. (of or "")
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
            latest[slot_key(record.kind, record.of)] = record
        end
    end
    local refused = {}
    local slots = { slot_key(review.Kind.CODE), slot_key(review.Kind.STYLE) }
    for _, of in ipairs(review.OF_KINDS) do
        slots[#slots + 1] = slot_key(review.Kind.RECHECK, of)
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

---@class dev.board.land.SharedReview
---@field kind string the review's kind
---@field by string the reviewer's name
---@field claimant string the name in the claim comment that shares the credential

---List the newest review of each kind, whoever recorded it, that sits on a claimant's credential.
---@param comments {body: string, who: string?}[] the card's comments, oldest first
---@param state dev.board.check.State the commit that would land
---@return dev.board.land.SharedReview[] shared one per newest review, in comment order
function M.shared_credentials(comments, state)
    local claimed = {}
    for _, comment in ipairs(comments) do
        local claimant = board.last_claimant({ comment })
        if claimant and comment.who then
            claimed[comment.who] = claimant
        end
    end
    local newest = {}
    for index, comment in ipairs(comments) do
        local record = review.parse(comment.body)
        if record and record.change == state.change then
            newest[slot_key(record.kind, record.of)] = index
        end
    end
    local shared = {}
    for index, comment in ipairs(comments) do
        local record = review.parse(comment.body)
        local claimant = record and comment.who and claimed[comment.who]
        if
            claimant
            and record.change == state.change
            and newest[slot_key(record.kind, record.of)] == index
        then
            shared[#shared + 1] = { kind = record.kind, by = record.by, claimant = claimant }
        end
    end
    return shared
end

---@class dev.board.land.Seat
---@field name string? the seat's name
---@field role string? the seat's role
---@field verdict string? the answer, nil before one
---@field revision string? the commit the answer is about
---@field idle boolean? true when nobody took the seat

---List the kinds whose newest recheck at a commit is clean or minor.
---@param comments {body: string}[] the card's comments, oldest first
---@param commit string the full commit id that would land
---@return table<string, boolean> met the kinds a recheck at the commit covers
---@return boolean refused true when the newest recheck of some kind at the commit says needs-work
local function rechecked_kinds(comments, commit)
    local newest = {}
    for _, comment in ipairs(comments) do
        local record = review.parse(comment.body)
        if
            record
            and record.kind == review.Kind.RECHECK
            and record.of
            and record.commit == commit
        then
            newest[record.of] = record
        end
    end
    local met, refused = {}, false
    for kind, record in pairs(newest) do
        if record.verdict == review.Verdict.CLEAN or record.verdict == review.Verdict.MINOR then
            met[kind] = true
        elseif record.verdict == review.Verdict.NEEDS_WORK then
            refused = true
        end
    end
    return met, refused
end

---@class dev.board.land.seats_problem.Opts
---@field carried string? an earlier commit whose reviews carry over to the commit
---@field comments {body: string}[] the card's comments, oldest first

---List the seats that do not approve the commit that would land.
---
---A seat of the code or style kind that approved or asked for changes at an earlier commit
---counts as met when a clean or minor recheck of its kind is recorded at the commit. A seat
---that asks for changes at the commit or at the carried one still refuses. The recheck seat
---counts as met when any clean or minor recheck is recorded at the commit, whoever recorded it,
---and no recheck at the commit says needs-work.
---@param seats dev.board.land.Seat[] the card's seats
---@param commit string the full commit id that would land
---@param opts dev.board.land.seats_problem.Opts the carried commit and the card's comments
---@return string[] problems one reason per seat, empty when every seat approved
function M.seats_problem(seats, commit, opts)
    local rechecked, refused = rechecked_kinds(opts.comments, commit)
    local problems = {}
    for _, seat in ipairs(seats) do
        local label = "reviewer seat " .. (seat.name or "?")
        local revision = seat.revision
        local stale = revision ~= nil and revision ~= commit and revision ~= opts.carried
        local covered = stale and rechecked[seat.name] == true
        if stale and seat.name == review.Kind.RECHECK and not refused then
            covered = next(rechecked) ~= nil
        end
        local reason
        if seat.verdict == review.SeatVerdict.CHANGES_NEEDED then
            if not covered then
                reason = string.format("The %s asks for changes.", label)
            end
        elseif seat.verdict ~= review.SeatVerdict.APPROVED then
            if seat.verdict ~= nil or not seat.idle then
                reason = string.format("The %s has not answered.", label)
            end
        elseif revision == nil or (stale and not covered) then
            reason = string.format(
                "The %s approved commit %s, not the commit %s that would land.",
                label,
                seat.revision and M.short(seat.revision) or "none",
                M.short(commit)
            )
        end
        problems[#problems + 1] = reason
    end
    return problems
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
        local result = row.result
        if result ~= check.Result.PASS and result ~= check.Result.NOT_RUN then
            bad[#bad + 1] = string.format("Row %d, `%s`, ended with %s.", i, rows[i], result)
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
    local seconds = tonumber(dev_os.getenv("DEV_LAND_FETCH_SECONDS")) or FETCH_SECONDS
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

local function parent_on_trunk(root, opts)
    local parents =
        dev_os.capture(jj(root, "log", "-r", "@-", "--no-graph", "-T", COMMIT_TEMPLATE), {
            stderr = "null",
        })
    local revset = opts and opts.behind_tip and "@- & ::trunk()" or "@- & trunk()"
    local on_trunk = dev_os.capture(
        jj(root, "log", "-r", revset, "--no-graph", "-T", COMMIT_TEMPLATE),
        { stderr = "null" }
    )
    return count_lines(parents) == 1 and on_trunk == parents
end

---Say that the change may be a stack, which land refuses.
---@param root string the project root
---@return string? note a sentence when the parent is off trunk, else nil
function M.stack_note(root)
    if vcs.backend(root) ~= vcs.JJ or parent_on_trunk(root, { behind_tip = true }) then
        return nil
    end
    local found = forge.resolve(root)
    if found then
        local _, code = fetch(root, found.remote)
        if code == 0 and parent_on_trunk(root, { behind_tip = true }) then
            return nil
        end
    end
    return "The parent of this change is not on trunk. "
        .. "Land refuses it when that parent is unlanded, so "
        .. "squash the commits into one change before the final check."
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
        return "Trunk cannot be compared. " .. dev_command.vcs_sentence(why, root)
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

local function ci_ps(root, ...)
    local argv = { "ci", "-C", root, "ps", ... }
    argv[#argv + 1] = "--json"
    local out, code = dev_os.capture(argv, { stderr = "null" })
    local doc = code == 0 and json.decode(out)
    return type(doc) == "table" and doc or nil
end

local function started_at(run)
    if type(run.created_at) == "number" then
        return run.created_at
    end
    return 0
end

local function newest_run(runs, digits)
    local newest
    for _, run in ipairs(runs) do
        local source = type(run) == "table" and run.source
        if type(source) == "string" and source:sub(-COMMIT_CHARS) == digits then
            if not newest or started_at(run) > started_at(newest) then
                newest = run
            end
        end
    end
    return newest
end

local function failed_jobs(root, run)
    local doc = ci_ps(root, run)
    local names = {}
    for _, job in ipairs(doc and type(doc.jobs) == "table" and doc.jobs or {}) do
        if type(job) == "table" and job.state == "failed" and type(job.job) == "string" then
            names[#names + 1] = job.job
        end
    end
    return names
end

---@class dev.board.land.change_run_problem.Opts
---@field require_run boolean? true to refuse a run still going

---Say whether the gerrit change run of the commit failed, or is still going when the project
---requires finished runs.
---
---Outside gerrit it finds nothing to refuse. None at all never refuses here, and the second value
---says so. The third value is true when a run of the commit exists, false when the lookup found
---none, and nil when nothing was looked up.
---@param root string the project root
---@param commit string the commit to land
---@param opts dev.board.land.change_run_problem.Opts? the optional refusals
---@return string? problem the refusal, nil when the run passed or none was found
---@return string? seen the line that says what was found instead, nil outside gerrit
---@return boolean? found whether a run of the commit exists, nil when nothing was looked up
function M.change_run_problem(root, commit, opts)
    local found = forge.resolve(root)
    if not found or found.kind ~= forge.Kind.GERRIT then
        return nil
    end
    local backend = vcs.backend(root)
    local url = backend and vcs.config(root, backend, "remote." .. found.remote .. ".url") or ""
    local _, _, project = abandon.parse_url(url)
    if not project then
        return nil,
            "No change run was looked up. The remote "
                .. found.remote
                .. " is not ssh://host/project."
    end
    local doc = ci_ps(root, "-a", "--repo", project, "-n", RUN_HISTORY)
    if not doc or type(doc.runs) ~= "table" then
        return nil, "No change run was looked up. `ci ps -a` failed."
    end
    local digits = commit:sub(1, COMMIT_CHARS)
    local newest = newest_run(doc.runs, digits)
    if not newest then
        return nil, "No change run of commit " .. digits .. " was found.", false
    end
    local going = newest.status == "running" or newest.status == "queued"
    if going and opts and opts.require_run then
        return string.format(
            "The change run %s of commit %s is still going. Wait for it to finish, or land with "
                .. "`--ignore-change-run REASON`.",
            newest.run,
            digits
        ),
            nil,
            true
    end
    if newest.status ~= "failed" then
        return nil,
            string.format(
                "The change run %s of commit %s is %s, so it does not stop the landing.",
                newest.run,
                digits,
                tostring(newest.status)
            ),
            true
    end
    local jobs = failed_jobs(root, newest.run)
    return string.format(
        "The change run %s of commit %s failed%s. Read it with `ci logs %s`, fix it and upload "
            .. "again, or land with `--ignore-change-run REASON`.",
        newest.run,
        digits,
        #jobs > 0 and (" in " .. table.concat(jobs, ", ")) or "",
        newest.run
    ),
        nil,
        true
end

---Say why a commit that a rebase rewrote may not land, from its gerrit change run.
---
---It judges the rebased commit as `change_run_problem` does with finished runs required, and also
---refuses when no run of it exists. The rebase left the run of the earlier commit behind.
---@param root string the project root
---@param commit string the rebased commit to land
---@return string? problem the refusal, nil when the run passed or nothing was looked up
---@return string? seen the line that says what was found instead, nil outside gerrit
function M.rebased_run_problem(root, commit)
    local problem, seen, found = M.change_run_problem(root, commit, { require_run = true })
    if problem or found ~= false then
        return problem, seen
    end
    return string.format(
        "The rebase moved the commit, and no change run of the rebased commit %s exists. Upload "
            .. "it with `jj submit` and wait for its run, or land with "
            .. "`--ignore-change-run REASON`.",
        commit:sub(1, COMMIT_CHARS)
    )
end

---Add the reason a failed change run was ignored to a done note.
---@param note string the done note
---@param ignore string? the reason given with `--ignore-change-run`
---@return string note the note, with the reason when one was given
function M.ignored_run_note(note, ignore)
    if not ignore then
        return note
    end
    local reason = ignore:gsub("%.$", "")
    return string.format("%s The change run check was skipped: %s.", note, reason)
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
        return nil, "Trunk cannot be compared. " .. dev_command.vcs_sentence(why, root)
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
        out, code = dev_os.capture(jj(root, "abandon", table.unpack(ids)), { stderr = "stdout" })
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
    local found, partial, seen, why = {}, {}, {}, nil
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
                if not M.checks_problem(comments, at, rows) then
                    partial[#partial + 1] = record.commit
                end
            else
                found[#found + 1] = record.commit
            end
        end
    end
    return found, partial, why
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
    local differs = interdiff(root, commit, state.commit)
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

---List the dev modules and functions a template file takes, skipping full-line comments.
---@param text string the template file's text
---@return string[] calls the sorted entries, each a module or a function
function M.dev_calls(text)
    local kept = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if not line:find("^%s*%-%-") then
            kept[#kept + 1] = line
        end
    end
    text = table.concat(kept, "\n")
    local found = {}
    local alias = {}
    for name, path in text:gmatch('local ([%a_][%w_]*) = require%("(@dev/[%w_/]+)"%)') do
        local module = path:sub(2):gsub("/", ".")
        alias[name] = module
        found[module] = true
    end
    for path, fn in text:gmatch('require%("(@dev/[%w_/]+)"%)%.([%a_][%w_]*)') do
        local module = path:sub(2):gsub("/", ".")
        found[module] = true
        found[module .. "." .. fn] = true
    end
    local at = 1
    while true do
        local first, last, name, fn = text:find("([%a_][%w_]*)%.([%a_][%w_]*)", at)
        if not first then
            break
        end
        local before = first > 1 and text:sub(first - 1, first - 1) or ""
        if alias[name] and before ~= "." then
            found[alias[name] .. "." .. fn] = true
        end
        at = last + 1
    end
    local out = {}
    for entry in pairs(found) do
        out[#out + 1] = entry
    end
    table.sort(out)
    return out
end

---Read the path prefixes the project's `sync.templates` setting names.
---@param root string the project root
---@return string[]? prefixes the prefixes, nil when the setting is unset or malformed
function M.sync_templates(root)
    local value = config.get(root, "sync.templates")
    if type(value) ~= "table" or #value == 0 then
        return nil
    end
    for _, prefix in ipairs(value) do
        if type(prefix) ~= "string" then
            return nil
        end
    end
    return value
end

---Tell whether a path starts with one of the synced template prefixes.
---@param prefixes string[] the `sync.templates` prefixes
---@param path string the repo-relative path
---@return boolean synced true when a prefix starts the path
function M.is_synced_template(prefixes, path)
    for _, prefix in ipairs(prefixes) do
        if path:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

---Name why a synced Lua template file may not call a dev function the baked dev lacks.
---@param root string the project root, a jj project
---@param touched string[] the paths the landing commit touches
---@return string? problem the refusal, nil when the landing may go ahead
function M.template_problem(root, touched)
    local prefixes = M.sync_templates(root)
    local baked_file = config.get(root, "sync.baked")
    if not prefixes or type(baked_file) ~= "string" then
        return nil
    end
    local changed_template = false
    for _, path in ipairs(touched) do
        if path:find("%.lua$") and M.is_synced_template(prefixes, path) then
            changed_template = true
        end
    end
    if not changed_template then
        return nil
    end
    local backend = vcs.backend(root) or vcs.JJ
    local listed = ""
    for _, prefix in ipairs(prefixes) do
        local part
        if backend == vcs.GIT then
            part = git_out(root, "ls-tree", "-r", "-z", "--name-only", "HEAD", "--", prefix)
            part = part and part:gsub("%z", "\n")
        else
            part = jj_out(
                root,
                "file",
                "list",
                "-r",
                "@",
                "-T",
                'path ++ "\\n"',
                'root:"' .. prefix .. '"'
            )
        end
        if not part then
            return tool_name(root) .. " could not list the lint-set template files."
        end
        listed = listed .. part .. "\n"
    end
    local baked = {}
    for entry in (fs.read(root .. "/" .. baked_file) or ""):gmatch("[^\n]+") do
        baked[entry] = true
    end
    local lacking = {}
    for path in listed:gmatch("[^\n]+") do
        if path:find("%.lua$") then
            for _, call in ipairs(M.dev_calls(fs.read(root .. "/" .. path) or "")) do
                if not baked[call] then
                    lacking[call] = true
                end
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
        .. baked_file
        .. " does not list as baked into ci's images. Land the dev change first,"
        .. " rebuild the ci images,"
        .. " then land the template change with the entries added to "
        .. baked_file
        .. "."
end

---@class dev.board.land.Opts
---@field root string the project root, a jj project
---@field comments {body: string}[] the card's comments, oldest first
---@field state dev.board.check.State the commit that would land
---@field rows string[] the card's checks rows

local function rebase_carry(opts)
    local root, comments, state, rows = opts.root, opts.comments, opts.state, opts.rows
    local candidates, partial, unmet = checked_commits(root, comments, state, rows)
    if #candidates == 0 and #partial == 0 then
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
    for _, commit in ipairs(partial) do
        local problem, failed_read = carry_problem(root, state, commit)
        if not problem then
            return commit, nil, nil, true
        end
        if failed_read then
            return nil, problem, true
        end
    end
    if #candidates == 0 then
        return nil, unmet
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
---A commit with a passing check but no reviews of its own carries its check alone under the same
---rules, tried after every commit that holds both. The reviews then count only as the landing
---commit's own records and interdiff-identical ones.
---
---A commit with a passing check, whatever its parent and reviews, also carries its check alone
---when its tree equals the landing commit's tree and the change id is the same, as after a squash
---of an unlanded parent into the change. The reviews do not carry then. The third value is true
---for either carry.
---@param opts dev.board.land.Opts the project, the card's records and the landing commit
---@return string? commit the checked commit the records carry over from
---@return string? problem why it is refused, nil when it carries or no commit was checked
---@return boolean? check_only true when only the check carries and the reviews stay stale
function M.carry(opts)
    local root, comments, state = opts.root, opts.comments, opts.state
    for _, comment in ipairs(comments) do
        local own = check.parse(comment.body)
        local commit, mode = check.unreadable(comment.body)
        local finished = own and own.mode ~= check.Mode.PARTIAL
        if
            (finished and own.commit == state.commit)
            or (commit == state.commit and mode ~= check.Mode.PARTIAL)
        then
            return nil
        end
    end
    local commit, problem, stop, check_only = rebase_carry(opts)
    if commit or stop then
        return commit, problem, check_only
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
            return nil, "Trunk cannot be read. " .. dev_command.vcs_sentence(why, root)
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
    local index
    for line in out:gmatch("[^\n]*\n?") do
        if line:find("^diff ") then
            index = nil
        end
        if line:find("^index ") then
            index = line
        elseif line:find("^Binary files") and index then
            lines[#lines + 1] = index
            lines[#lines + 1] = line
            index = nil
        elseif line ~= "" and not line:find("^@@") then
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
---ids, except the blob ids of a binary file, so a rebase that moves the lines or lets trunk touch
---other files leaves it equal and runs no row. A row fails the landing when it does not pass, and
---the first failure stops the run.
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
            seconds = check.row_seconds(opts.root),
            env = {
                [dev_remote.COMMAND_ENV] = dev_remote.Command.CHECK,
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

---Say whether a revision holds a revert of a landed commit, found by the line `This reverts commit`.
---@param root string the project root
---@param landed string the landed commit, full or shortened
---@param rev string the jj revset naming one revision, or in git a revision
---@return boolean held true when a commit in the revision's history names the landed commit
function M.reverts(root, landed, rev)
    local text = "This reverts commit " .. landed
    if vcs.backend(root) == vcs.GIT then
        local out = git_out(root, "log", rev, "-F", "--grep=" .. text, "--format=%H", "-n1")
        return out ~= nil and out:match("^%x+\n") ~= nil
    end
    local out = jj_out(
        root,
        "log",
        "-r",
        "::(" .. rev .. ') & description(substring:"' .. text .. '")',
        "--no-graph",
        "-T",
        COMMIT_TEMPLATE
    )
    return out ~= nil and out:match("^%x+\n") ~= nil
end

---Read the commit on the remote trunk that a check record's change landed as.
---@param root string the project root
---@param record dev.board.check.Record the card's newest run record
---@return string? commit the full commit id, nil when trunk does not hold the change or a read
---   failed
function M.settled_commit(root, record)
    if vcs.backend(root) ~= vcs.GIT then
        return M.trunk_commit(root, record.change)
    end
    local found = forge.resolve(root)
    if not found then
        return nil
    end
    local ref = vcs.remote_trunk(root, found.remote)
    if not ref or not git_out(root, "merge-base", "--is-ancestor", record.commit, ref) then
        return nil
    end
    return record.commit
end

local function git_run(root)
    local found, why = forge.resolve(root)
    if not found then
        return false, "Trunk cannot be pushed. " .. dev_command.vcs_sentence(why, root)
    end
    local ref, read_why = vcs.remote_trunk(root, found.remote)
    if not ref then
        return false, "The remote " .. read_why .. "."
    end
    local head = git_out(root, "rev-parse", "HEAD")
    if not head then
        return false, "Git could not read the HEAD commit of " .. root .. "."
    end
    local branch = ref:sub(#found.remote + 2)
    local sha = head:match("^%x+")
    local argv = vcs.git_push(found.remote, { `{sha}:refs/heads/{branch}` })
    local out, code = dev_os.capture(argv, { stderr = "stdout", cwd = root })
    return code == 0, out
end

---Name the sync drift a failed land printed that the landing commit did not cause.
---
---`dev sync --check` prints `differs: PATH` or `missing: PATH` for each drifted file. A path the
---commit does not touch drifted because a synced template changed, so the advice says to sync.
---@param output string what the failed land printed
---@param touched string[] the paths the landing commit touches
---@return string? advice the sentence to append, nil when no printed drift is the template's
function M.template_drift(output, touched)
    local mine = {}
    for _, path in ipairs(touched) do
        mine[path] = true
    end
    local found = {}
    for line in output:gmatch("[^\n]+") do
        local path = line:match("^%s*differs: (%S+)") or line:match("^%s*missing: (%S+)")
        if path and not mine[path] then
            found[#found + 1] = path
        end
    end
    if #found == 0 then
        return nil
    end
    table.sort(found)
    return string.format(
        "This drift is not from the card, which does not touch %s. "
            .. "A synced template changed, so run `dev sync`, land that as its own card, "
            .. "and land this card again.",
        table.concat(found, ", ")
    )
end

---@class dev.board.land.Candidate
---@field commit string the local commit id
---@field change string the jj change id
---@field trailer string? the Gerrit Change-Id trailer of the description

local function jj_candidates(root)
    local out = jj_out(
        root,
        "log",
        "-r",
        "::@ ~ ::trunk()",
        "--no-graph",
        "-T",
        '"@@ " ++ commit_id ++ " " ++ change_id ++ "\\n" ++ description ++ "\\n"'
    )
    if out == nil then
        return nil
    end
    local found = {}
    for line in out:gmatch("[^\n]*") do
        local commit, change = line:match("^@@ (%x+) (%S+)$")
        if commit then
            table.insert(found, 1, { commit = commit, change = change })
        elseif found[1] then
            local trailer = line:match("^Change%-Id: (I%x+)%s*$")
            if trailer then
                found[1].trailer = found[1].trailer or trailer
            end
        end
    end
    return found
end

local function candidate_name(candidate)
    return "change "
        .. candidate.change:sub(1, COMMIT_CHARS)
        .. " (commit "
        .. M.short(candidate.commit)
        .. ")"
end

local function trunk_copy(root, candidate)
    local matcher = string.format("change_id(%s)", candidate.change)
    if candidate.trailer then
        matcher = string.format('description(substring:"Change-Id: %s")', candidate.trailer)
    end
    local out =
        jj_out(root, "log", "-r", matcher .. " & ::trunk()", "--no-graph", "-T", COMMIT_TEMPLATE)
    return out and out:match("^(%x+)")
end

local function jj_ids(root, revset)
    local out = jj_out(root, "log", "-r", revset, "--no-graph", "-T", COMMIT_TEMPLATE)
    local ids = {}
    for id in (out or ""):gmatch("%x+") do
        ids[#ids + 1] = id
    end
    return ids
end

---@class dev.board.land.Drop
---@field candidate dev.board.land.Candidate the landed change to abandon
---@field copy string the trunk commit that holds the change
---@field excluded string the revset suffix that leaves the other landed changes out of its children
---@field lines string[] the lines to print, which the drop appends to

local function rebase_children(root, drop, children)
    local name, copy, lines = candidate_name(drop.candidate), drop.copy, drop.lines
    local out, code =
        dev_os.capture(jj(root, "rebase", "-s", children, "-d", copy), { stderr = "stdout" })
    if code ~= 0 then
        lines[#lines + 1] = `Kept {name}. The rebase of its unlanded children failed. `
            .. out:gsub("\n$", "")
        return false
    end
    local conflicts = out:match("New conflicts appeared[^\n]*\n(.*)")
    local line = "Rebased the unlanded children of "
        .. name
        .. " onto trunk commit "
        .. M.short(copy)
        .. "."
    if conflicts then
        line = line .. " Their conflicts stay recorded in:\n" .. conflicts:gsub("\n$", "")
    end
    lines[#lines + 1] = line
    return true
end

local function abandon_landed(root, drop)
    local change, copy, lines = drop.candidate.change, drop.copy, drop.lines
    local name = candidate_name(drop.candidate)
    if #jj_ids(root, change .. " & (working_copies() ~ @)") > 0 then
        lines[#lines + 1] = `Kept {name}, which another workspace holds.`
        return
    end
    local children = "children(" .. change .. ")" .. drop.excluded
    if #jj_ids(root, children) > 0 and not rebase_children(root, drop, children) then
        return
    end
    if #jj_ids(root, change .. " & @") > 0 then
        local _, code = dev_os.capture(jj(root, "new", copy), { stderr = "null" })
        if code ~= 0 then
            lines[#lines + 1] = `Kept {name}. A fresh working copy on trunk failed.`
            return
        end
    end
    local out, code = dev_os.capture(jj(root, "abandon", change), { stderr = "stdout" })
    if code ~= 0 then
        lines[#lines + 1] = `Kept {name}. The abandon failed. ` .. out:gsub("\n$", "")
        return
    end
    lines[#lines + 1] = `Abandoned {name}, landed on trunk as {M.short(copy)}.`
end

local function drop_jj(root, candidates, lines)
    local landed, changes = {}, {}
    for _, candidate in ipairs(candidates) do
        local copy = trunk_copy(root, candidate)
        if copy == nil then
            lines[#lines + 1] = `Kept {candidate_name(candidate)}, which trunk does not hold.`
        elseif #jj_ids(root, candidate.change .. " ~ ::trunk()") > 0 then
            landed[#landed + 1] = { candidate = candidate, copy = copy }
            changes[#changes + 1] = candidate.change
        end
    end
    local excluded = if #changes > 0 then ` ~ ({table.concat(changes, " | ")})` else ""
    for _, drop in ipairs(landed) do
        drop.excluded = excluded
        drop.lines = lines
        abandon_landed(root, drop)
    end
end

local function git_branch(root)
    local out = git_out(root, "symbolic-ref", "--short", "-q", "HEAD")
    return out and out:match("^(%S+)")
end

local function drop_remote_branch(root, remote, branch, lines)
    local out, code =
        dev_os.capture(vcs.git_push(remote, { ":" .. branch }), { stderr = "stdout", cwd = root })
    if code == 0 then
        lines[#lines + 1] = `Deleted remote branch {branch}.`
    else
        lines[#lines + 1] = "Kept remote branch " .. branch .. ". " .. out:gsub("\n$", "")
    end
end

local function drop_git(root, branch, lines)
    local found = forge.resolve(root)
    local ref = found and vcs.remote_trunk(root, found.remote)
    if not found or not ref or not M.trunk_commit(root, "-") then
        return
    end
    if ref:sub(#found.remote + 2) == branch then
        return
    end
    local remote_ref = "refs/remotes/" .. found.remote .. "/" .. branch
    if
        git_out(root, "rev-parse", "--verify", "-q", remote_ref)
        and git_out(root, "merge-base", "--is-ancestor", remote_ref, ref)
    then
        drop_remote_branch(root, found.remote, branch, lines)
    end
    if not git_out(root, "show-ref", "--verify", "-q", "refs/heads/" .. branch) then
        return
    end
    if not git_out(root, "merge-base", "--is-ancestor", "refs/heads/" .. branch, ref) then
        lines[#lines + 1] = "Kept branch " .. branch .. ", which trunk does not hold."
        return
    end
    if git_branch(root) == branch then
        git_out(root, "switch", "--detach", "-q")
    end
    local deleted, why = vcs.delete_branch(root, vcs.GIT, branch)
    if deleted then
        lines[#lines + 1] = `Deleted branch {branch}.`
    elseif deleted == nil then
        lines[#lines + 1] = "Kept branch " .. branch .. ". " .. why
    end
end

---Land the working-copy change with `jj land`, or push the HEAD commit to trunk in git.
---
---Once trunk is fetched and holds a candidate's Change-Id, the local original goes: in jj the
---change is abandoned after its unlanded children move onto the trunk copy, and in git the landed
---branch is deleted here and on the remote. A candidate that trunk does not hold stays.
---@param root string the project root
---@return boolean ok true when the land exited 0
---@return string output what the land printed
---@return string[] dropped one line for each change abandoned, branch deleted or candidate kept
function M.run(root)
    local in_git = vcs.backend(root) == vcs.GIT
    local candidates = not in_git and jj_candidates(root)
    local branch = in_git and git_branch(root)
    local ok, out
    if in_git then
        ok, out = git_run(root)
    else
        local printed, code = dev_os.capture(
            vcs.with(vcs.base(root, vcs.JJ), "land", "--yes", "-r", "@"),
            { stderr = "stdout", cwd = root, env = { DEV_BOARD_LAND = "1" } }
        )
        ok, out = code == 0, printed
    end
    local lines = {}
    if not ok then
        return false, out, lines
    end
    if in_git and branch then
        drop_git(root, branch, lines)
    elseif candidates and #candidates > 0 then
        local found = forge.resolve(root)
        local fetched = found and select(2, fetch(root, found.remote))
        if fetched == 0 then
            drop_jj(root, candidates, lines)
        else
            lines[#lines + 1] = "Kept the local changes. Trunk could not be fetched to confirm."
        end
    end
    return true, out, lines
end

return M
