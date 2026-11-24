local dev_command = require("@dev/command")
local dev_os = require("@dev/os")
local forge = require("@dev/forge")
local text = require("@dev/text")
local vcs = require("@dev/vcs")

---Branch names that count as the trunk, in the order dev prefers them
local TRUNK_NAMES = { "master", "main" }
local ARCHIVE = "refs/archive/"
local ANONYMOUS_HEADS = "heads(mutable() ~ empty()) ~ bookmarks() ~ remote_bookmarks()"
local HEAD_TEMPLATE =
    'commit_id ++ "\\t" ++ change_id.short(12) ++ "\\t" ++ description.first_line() ++ "\\n"'
local ID_TEMPLATE = 'commit_id ++ "\\t" ++ change_id.short(12) ++ "\\n"'
local SHORT_SHA = 12

---@class dev.cmd.branch.Repo
---@field root string absolute path of the project root
---@field backend dev.vcs.Backend the project's backend
---@field git string[] the git command prefix that runs on the project's store
---@field dir string? the git store under `.jj`, nil on a git project
---@field remotes string[] every remote the project has
---@field record string? the remote of record
---@field verdicts table<string, boolean> whether a tip is landed, by commit
---@field trunk_ids table<string, table<string, boolean>> the patch-ids of the trunk, by merge base

---@class dev.cmd.branch.Trunk
---@field ref string the full ref of the trunk branch
---@field sha string the commit the trunk points at
---@field name string `master` or `main`

---@class dev.cmd.branch
local M = {}

local function lines_of(out)
    local lines = {}
    for line in out:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    return lines
end

local function git(repo, ...)
    return dev_os.capture(vcs.with(repo.git, ...), { stderr = "null" })
end

local function open(ctx)
    local backend, err = vcs.require(ctx.root)
    if not backend then
        dev_command.die(text.sentence(err))
    end
    local repo = {
        root = ctx.root,
        backend = backend,
        git = { "git", "-C", ctx.root },
        verdicts = {},
        trunk_ids = {},
    }
    if backend == vcs.JJ then
        local base = vcs.base(ctx.root, backend, { quiet = true })
        local dir = text.trim(
            dev_os.capture(
                vcs.with(base, "--ignore-working-copy", "git", "root"),
                { stderr = "null" }
            )
        )
        if dir == "" then
            dev_command.die("The jj repo in " .. ctx.root .. " has no git store.")
        end
        repo.dir = dir
        repo.git = { "git", "--git-dir=" .. dir }
    end
    local found, _, remotes = forge.resolve(ctx.root)
    repo.remotes = found and found.remotes or remotes or {}
    repo.record = found and found.remote
    return repo
end

local function commit_of(repo, ref)
    local out, code = git(repo, "rev-parse", "-q", "--verify", ref .. "^{commit}")
    if code ~= 0 then
        return nil
    end
    return text.trim(out)
end

---List the refs under a prefix with the commit each points at.
local function refs_under(repo, prefix)
    local out, code = git(repo, "for-each-ref", "--format=%(refname)\t%(objectname)", prefix)
    local found = {}
    for _, line in ipairs(code == 0 and lines_of(out) or {}) do
        local name, sha = line:match("^" .. prefix:gsub("%p", "%%%0") .. "/(%S+)\t(%x+)$")
        if name and name ~= "HEAD" then
            found[#found + 1] = { name = name, sha = sha }
        end
    end
    return found
end

local function find_ref(list, name)
    for _, ref in ipairs(list) do
        if ref.name == name then
            return ref
        end
    end
    return nil
end

---Find the trunk the branches are compared with, the remote of record's before the local one.
---@param repo dev.cmd.branch.Repo the project
---@return dev.cmd.branch.Trunk trunk exits the command when the project has none
local function trunk_of(repo)
    local remote = repo.record
    for _, want in ipairs(remote and TRUNK_NAMES or {}) do
        local ref = "refs/remotes/" .. remote .. "/" .. want
        local sha = commit_of(repo, ref)
        if sha then
            return { ref = ref, sha = sha, name = want }
        end
    end
    for _, want in ipairs(TRUNK_NAMES) do
        local sha = commit_of(repo, "refs/heads/" .. want)
        if sha then
            return { ref = "refs/heads/" .. want, sha = sha, name = want }
        end
    end
    dev_command.die("The project has no master or main branch to compare with.")
end

local function patch_ids(repo, range)
    local log, log_code =
        git(repo, "log", "--no-merges", "--no-ext-diff", "--no-color", "-p", range, "--")
    if log_code ~= 0 then
        return nil
    end
    local out, code =
        dev_os.capture_input(vcs.with(repo.git, "patch-id", "--stable"), log, { stderr = "null" })
    if code ~= 0 then
        return nil
    end
    local ids = {}
    for _, line in ipairs(lines_of(out)) do
        ids[#ids + 1] = line:match("^(%x+)")
    end
    return ids
end

---Tell whether every commit of `trunk..tip` has its patch-id among the trunk's own.
---
---A squash or a rebase gives a landed commit a new hash and the same patch-id, so the
---comparison needs no shared history beyond the merge base.
---@param repo dev.cmd.branch.Repo the project
---@param trunk dev.cmd.branch.Trunk the trunk from `trunk_of`
---@param tip string the commit a branch points at
---@return boolean landed whether nothing on the branch is missing from the trunk
local function landed(repo, trunk, tip)
    if repo.verdicts[tip] ~= nil then
        return repo.verdicts[tip]
    end
    local range = trunk.sha .. ".." .. tip
    local mine = patch_ids(repo, range)
    local merges = tonumber(text.trim(git(repo, "rev-list", "--merges", "--count", range))) or 1
    local verdict = mine ~= nil and #mine == 0 and merges == 0
    local base, code = git(repo, "merge-base", trunk.sha, tip)
    if mine and not verdict and merges == 0 and code == 0 then
        base = text.trim(base)
        if not repo.trunk_ids[base] then
            local ids = patch_ids(repo, base .. ".." .. trunk.sha)
            local set = ids and {}
            for _, id in ipairs(ids or {}) do
                set[id] = true
            end
            repo.trunk_ids[base] = set or false
        end
        local set = repo.trunk_ids[base]
        verdict = set ~= false
        for _, id in ipairs(mine) do
            verdict = verdict and set[id] == true
        end
    end
    repo.verdicts[tip] = verdict
    return verdict
end

local function state_of(repo, trunk, sha)
    return landed(repo, trunk, sha) and "landed" or "unlanded"
end

local function indent(out)
    out = out:gsub("\n+$", "")
    if out ~= "" then
        dev_command.say("    " .. (out:gsub("\n", "\n    ")))
    end
end

local function remote_refs(repo, remote, pattern)
    local out, code = git(repo, "ls-remote", remote, pattern)
    local found = {}
    for _, line in ipairs(code == 0 and lines_of(out) or {}) do
        local sha, ref = line:match("^(%x+)%s+(%S+)$")
        if sha then
            found[#found + 1] = { name = ref, sha = sha }
        end
    end
    return found, code == 0
end

local function archives_of(repo, remote, name)
    local found = {}
    for _, ref in ipairs(remote_refs(repo, remote, ARCHIVE .. "*/" .. name)) do
        if ref.name:match("^refs/archive/[^/]+/(.+)$") == name then
            found[#found + 1] = ref
        end
    end
    return found
end

local function archived(repo, name, sha)
    if #repo.remotes == 0 then
        return false
    end
    for _, remote in ipairs(repo.remotes) do
        local held = false
        for _, ref in ipairs(archives_of(repo, remote, name)) do
            local _, code = git(repo, "merge-base", "--is-ancestor", sha, ref.sha)
            held = held or ref.sha == sha or code == 0
        end
        if not held then
            return false
        end
    end
    return true
end

---List local branches, remote branches and anonymous jj heads, each marked landed or unlanded.
---@param ctx dev.Ctx the command's context, with no arguments
---@return integer code 0
function M.ls(ctx)
    local repo = open(ctx)
    local trunk = trunk_of(repo)
    dev_command.say("trunk " .. trunk.ref:gsub("^refs/%a+/", ""))
    local function section(title, rows)
        if #rows > 0 then
            dev_command.say(title .. "\n" .. table.concat(rows, "\n"))
        end
    end
    local rows = {}
    for _, ref in ipairs(refs_under(repo, "refs/heads")) do
        rows[#rows + 1] = string.format("  %-30s %s", ref.name, state_of(repo, trunk, ref.sha))
    end
    section("local", rows)
    for _, remote in ipairs(repo.remotes) do
        rows = {}
        for _, ref in ipairs(refs_under(repo, "refs/remotes/" .. remote)) do
            rows[#rows + 1] = string.format("  %-30s %s", ref.name, state_of(repo, trunk, ref.sha))
        end
        section("remote " .. remote, rows)
    end
    rows = {}
    if repo.backend == vcs.JJ then
        local base = vcs.base(repo.root, vcs.JJ, { quiet = true })
        local out, code = dev_os.capture(
            vcs.with(base, "log", "--no-graph", "-r", ANONYMOUS_HEADS, "-T", HEAD_TEMPLATE),
            { stderr = "null" }
        )
        for _, line in ipairs(code == 0 and lines_of(out) or {}) do
            local sha, change, subject = line:match("^(%x+)\t(%w+)\t(.*)$")
            if sha then
                rows[#rows + 1] =
                    string.format("  %-30s %-9s %s", change, state_of(repo, trunk, sha), subject)
            end
        end
    end
    section("anonymous", rows)
    return 0
end

local function resolve(repo, rev)
    local named = text.contains(vcs.branches(repo.root, repo.backend), rev)
    if repo.backend == vcs.GIT then
        local sha = commit_of(repo, rev)
        if not sha then
            dev_command.die("There is no revision " .. rev .. ".")
        end
        return sha, named and rev or sha:sub(1, SHORT_SHA)
    end
    local base = vcs.base(repo.root, vcs.JJ, { quiet = true })
    local out, code = dev_os.capture(
        vcs.with(base, "log", "--no-graph", "-r", rev, "-T", ID_TEMPLATE),
        { stderr = "stdout" }
    )
    if code ~= 0 then
        dev_command.die(text.sentence(text.trim(out)))
    end
    local rows = lines_of(out)
    if #rows ~= 1 then
        dev_command.die(rev .. " names " .. #rows .. " commits, and archive takes one.")
    end
    local sha, change = rows[1]:match("^(%x+)\t(%w+)$")
    return sha, named and rev or change
end

---Push a revision to `refs/archive/DATE/NAME` on every remote, or on the one `--to` names,
---and confirm each remote it pushed to holds it.
---@param rev string the revision to archive
---@param only string? the one remote `--to` names, nil for every remote
---@param ctx dev.Ctx the command's context
---@return integer code 0, or 1 when a push failed or a remote lacks the ref afterwards
function M.archive(rev, only, ctx)
    local repo = open(ctx)
    if #repo.remotes == 0 then
        dev_command.die("The project has no remote to archive to.")
    end
    local remotes = repo.remotes
    if only then
        if not text.contains(repo.remotes, only) then
            dev_command.die("There is no remote " .. only .. " to archive to.")
        end
        remotes = { only }
    end
    local sha, name = resolve(repo, rev)
    local ref = ARCHIVE .. os.date("%Y-%m-%d") .. "/" .. name
    local status = 0
    for _, remote in ipairs(remotes) do
        local argv = vcs.git_push(remote, { `{sha}:{ref}` }, { git_dir = repo.dir })
        dev_command.show(ctx, argv)
        local out, code = dev_os.capture(argv, { cwd = ctx.root, stderr = "stdout" })
        if code ~= 0 then
            dev_command.say("The push of " .. ref .. " to " .. remote .. " failed.")
            indent(out)
        end
    end
    for _, remote in ipairs(remotes) do
        local held = remote_refs(repo, remote, ref)[1]
        if held and held.sha == sha then
            dev_command.say(
                "Archived " .. sha:sub(1, SHORT_SHA) .. " as " .. ref .. " on " .. remote .. "."
            )
        else
            dev_command.say("The remote " .. remote .. " lacks " .. ref .. ".")
            status = 1
        end
    end
    return status
end

---Delete a branch locally and on every remote when it is landed by content or archived.
---@param name string the branch to delete
---@param ctx dev.Ctx the command's context
---@return integer code 0, or 1 when a delete failed
function M.prune(name, ctx)
    local repo = open(ctx)
    local trunk = trunk_of(repo)
    if name == trunk.name then
        dev_command.die("Dev refuses to prune the trunk " .. name .. ".")
    end
    local tips = {}
    local mine = find_ref(refs_under(repo, "refs/heads"), name)
    if mine then
        tips[#tips + 1] = { label = "local " .. name, sha = mine.sha }
    end
    for _, remote in ipairs(repo.remotes) do
        local theirs = find_ref(refs_under(repo, "refs/remotes/" .. remote), name)
        if theirs then
            tips[#tips + 1] = { label = remote .. "/" .. name, sha = theirs.sha, remote = remote }
        end
    end
    if #tips == 0 then
        dev_command.die("There is no branch " .. name .. ", locally or on a remote.")
    end
    local unsafe = {}
    for _, tip in ipairs(tips) do
        local rows, read = {}, true
        if tip.remote then
            rows, read = remote_refs(repo, tip.remote, "refs/heads/" .. name)
        end
        if not read then
            unsafe[#unsafe + 1] = tip.label .. " cannot be read on its remote"
        elseif rows[1] and rows[1].sha ~= tip.sha then
            unsafe[#unsafe + 1] = tip.label .. " moved since the last fetch"
        elseif not landed(repo, trunk, tip.sha) and not archived(repo, name, tip.sha) then
            unsafe[#unsafe + 1] = tip.label
        end
    end
    if #unsafe > 0 then
        dev_command.die(
            "Branch "
                .. name
                .. " is neither landed by content nor archived, or it moved since the last fetch ("
                .. table.concat(unsafe, ", ")
                .. "). Run dev branch archive "
                .. name
                .. " first. Nothing was deleted."
        )
    end
    local status = 0
    for _, tip in ipairs(tips) do
        if tip.remote then
            local argv = vcs.git_push(
                tip.remote,
                { ":refs/heads/" .. name },
                { git_dir = repo.dir }
            )
            dev_command.show(ctx, argv)
            local out, code = dev_os.capture(argv, { cwd = ctx.root, stderr = "stdout" })
            if code == 0 then
                dev_command.say("Deleted " .. tip.label .. ".")
            else
                dev_command.say("The delete of " .. tip.label .. " failed.")
                indent(out)
                status = 1
            end
        end
    end
    if repo.backend == vcs.JJ then
        local base = vcs.base(repo.root, vcs.JJ, { quiet = true })
        dev_os.capture(vcs.with(base, "git", "import"), { stderr = "null" })
    end
    if mine and status == 0 then
        local deleted, why = vcs.delete_branch(repo.root, repo.backend, name)
        if deleted ~= nil then
            dev_command.say("Deleted local " .. name .. ".")
        else
            dev_command.say("The delete of local " .. name .. " failed.")
            indent(why or "There is no such branch.")
            status = 1
        end
    end
    return status
end

return M
