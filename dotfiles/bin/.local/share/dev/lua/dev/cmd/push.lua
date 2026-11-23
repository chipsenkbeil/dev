local dev_os = require("dev.os")
local forge = require("dev.forge")
local fs = require("dev.fs")
local text = require("dev.text")
local vcs = require("dev.vcs")
local dev_command = require("dev.command")

local REMOTE_NAMES = { "origin", "gerrit" }

---@class dev.cmd.push.Plan
---@field backend dev.vcs.Backend the project's backend
---@field ref string the trunk bookmark (jj) or the current branch (git)
---@field sha string? the commit a git push sends
---@field guard string? the `commit-guard` path a git push goes through
---@field remotes string[] the default target, the remote of record
---@field named string[] every remote `dev push` accepts by name
---@field forge dev.forge.Forge the forge and remote of record

---@class dev.cmd.push
local M = {}

local function guard_path()
    local self = os.getenv("DEV_SELF") or ""
    if self:sub(1, 1) ~= "/" then
        return nil,
            "DEV_SELF is not an absolute path. Dev refuses to push without the attribution check."
    end
    local guard = fs.dirname(self) .. "/commit-guard"
    if not fs.is_exec(guard) then
        return nil,
            "The guard commit-guard is missing at "
                .. guard
                .. ". Dev refuses to push without the attribution check."
    end
    return guard
end

M.guard_path = guard_path

---@class dev.cmd.push.Opts
---@field guard string the `commit-guard` path
---@field remote string the remote to push to
---@field sha string the commit to send
---@field ref string the branch to move

---Build the guarded git push of one commit to a branch on a remote.
---@param opts dev.cmd.push.Opts the guard, remote, commit and branch
---@return string[] argv the command line
function M.git_argv(opts)
    return { opts.guard, "push", "--", opts.remote, opts.sha .. ":refs/heads/" .. opts.ref }
end

local function resolve(root, tags_only)
    local backend, err = vcs.require(root)
    if not backend then
        return nil, err
    end
    local plan = { backend = backend }
    if backend == vcs.JJ then
        plan.ref = vcs.trunk(vcs.branches(root, backend))
        if not plan.ref and not tags_only then
            return nil, "no master or main bookmark in " .. root
        end
    else
        local branch, code =
            dev_os.capture({ "git", "-C", root, "symbolic-ref", "--short", "-q", "HEAD" })
        if code ~= 0 and not tags_only then
            return nil, "HEAD is detached in " .. root .. ", and a push needs a branch"
        end
        plan.ref = text.trim(branch)
        plan.sha = text.trim(dev_os.capture({ "git", "-C", root, "rev-parse", "HEAD" }))
        plan.guard, err = guard_path()
        if not plan.guard then
            return nil, err
        end
    end
    local remotes
    plan.forge, err, remotes = forge.resolve(root)
    remotes = plan.forge and plan.forge.remotes or remotes
    plan.named = {}
    for _, name in ipairs(REMOTE_NAMES) do
        if text.contains(remotes, name) then
            plan.named[#plan.named + 1] = name
        end
    end
    if #plan.named == 0 then
        return nil, "no origin or gerrit remote"
    end
    if not plan.forge then
        return nil, err
    end
    plan.remotes = { plan.forge.remote }
    if not text.contains(plan.named, plan.forge.remote) then
        plan.named[#plan.named + 1] = plan.forge.remote
    end
    return plan
end

local function argv_for(root, plan, remote)
    if plan.backend == vcs.JJ then
        return vcs.with(
            vcs.base(root, plan.backend, { quiet = true }),
            "git",
            "push",
            "--remote",
            remote,
            "-b",
            plan.ref
        )
    end
    return M.git_argv({ guard = plan.guard, remote = remote, sha = plan.sha, ref = plan.ref })
end

local function store_dir(root, plan)
    if plan.backend ~= vcs.JJ then
        return nil
    end
    local dir = dev_os.capture(vcs.with(vcs.base(root, plan.backend), "git", "root"))
    return text.trim(dir)
end

local function peeled(out, ref)
    local found
    for line in out:gmatch("[^\n]+") do
        local sha, name = line:match("^(%x+)%s+(%S+)$")
        if name == ref then
            found = sha
        elseif name == ref .. "^{}" then
            return sha
        end
    end
    return found
end

local function check_tags(git, tags, remotes)
    local shas = {}
    for _, tag in ipairs(tags) do
        local sha, code = dev_os.capture(
            vcs.with(git, "rev-parse", "-q", "--verify", "refs/tags/" .. tag .. "^{commit}"),
            { stderr = "null" }
        )
        if code ~= 0 then
            dev_command.die("There is no local tag " .. tag .. ". No tag was pushed.")
        end
        shas[tag] = text.trim(sha)
    end
    local todo = {}
    for _, remote in ipairs(remotes) do
        todo[remote] = {}
        for _, tag in ipairs(tags) do
            local ref = "refs/tags/" .. tag
            local out, code = dev_os.capture(
                vcs.with(git, "ls-remote", remote, ref, ref .. "^{}"),
                { stderr = "stdout" }
            )
            if code ~= 0 then
                dev_command.die(
                    "The tags of " .. remote .. " cannot be read. No tag was pushed.\n" .. out
                )
            end
            local held = peeled(out, ref)
            if held and held ~= shas[tag] then
                dev_command.die(
                    "The remote "
                        .. remote
                        .. " holds tag "
                        .. tag
                        .. " at "
                        .. held
                        .. ", not "
                        .. shas[tag]
                        .. ". Dev refuses to overwrite it and no tag was pushed."
                )
            end
            if not held then
                todo[remote][#todo[remote] + 1] = tag
            end
        end
    end
    return todo
end

local function push_tags(ctx, plan, tags, remotes)
    local guard, err = guard_path()
    if not guard then
        dev_command.die(text.sentence(err))
    end
    local dir = store_dir(ctx.root, plan)
    local git = dir and { "git", "--git-dir=" .. dir } or { "git", "-C", ctx.root }
    local todo = check_tags(git, tags, remotes)
    local status = 0
    for _, remote in ipairs(remotes) do
        for _, tag in ipairs(tags) do
            if not text.contains(todo[remote], tag) then
                dev_command.say("Tag " .. tag .. " is already on " .. remote .. ".")
            end
        end
        if #todo[remote] > 0 then
            local argv = { guard }
            if dir then
                argv = vcs.with(argv, "--git-dir", dir)
            end
            argv = vcs.with(argv, "push", "--", remote)
            for _, tag in ipairs(todo[remote]) do
                argv[#argv + 1] = "refs/tags/" .. tag .. ":refs/tags/" .. tag
            end
            dev_command.show(ctx, argv)
            local out, code = dev_os.capture(argv, { cwd = ctx.root, stderr = "stdout" })
            local shown = table.concat(todo[remote], " ")
            if code == 0 then
                dev_command.say("Pushed tags " .. shown .. " to " .. remote .. ".")
            else
                dev_command.say("The push of tags " .. shown .. " to " .. remote .. " failed.")
                status = 1
            end
            out = out:gsub("\n+$", "")
            if out ~= "" then
                io.write("    ", (out:gsub("\n", "\n    ")), "\n")
            end
        end
    end
    return status
end

---The command lines `dev help push` shows.
---@param root string absolute path of the project root
---@return string[] lines one command per line, or a single message line
function M.commands(root)
    local plan, err = resolve(root)
    if not plan then
        return { text.sentence(err) }
    end
    local lines = {}
    for _, remote in ipairs(plan.remotes) do
        lines[#lines + 1] = table.concat(argv_for(root, plan, remote), " ")
    end
    return lines
end

---Push the trunk to the remote of record, or to the remotes named.
---
---With `--tag NAME` it pushes only those tags, never overwriting one.
---
---It prints the forge, the remote and why, then one line per remote with the
---command's output indented under it. Any other flag is refused before this runs.
---@param ctx dev.Ctx the command's context, whose `args` are remote names and `--tag NAME` pairs
---@return integer code 0, or 1 when a push fails
function M.run(ctx)
    local tags, names = {}, {}
    local i = 1
    while i <= #ctx.args do
        if ctx.args[i] == "--tag" then
            if not ctx.args[i + 1] then
                dev_command.usage_error(ctx, "--tag needs a tag name")
            end
            if not text.contains(tags, ctx.args[i + 1]) then
                tags[#tags + 1] = ctx.args[i + 1]
            end
            i = i + 2
        else
            names[#names + 1] = ctx.args[i]
            i = i + 1
        end
    end
    local plan, err = resolve(ctx.root, #tags > 0)
    if not plan then
        dev_command.die(text.sentence(err))
    end
    local remotes = plan.remotes
    if #names > 0 then
        remotes = {}
        for _, name in ipairs(names) do
            if not text.contains(plan.named, name) then
                dev_command.usage_error(
                    ctx,
                    "no remote "
                        .. name
                        .. " to push to, the project has: "
                        .. table.concat(plan.named, " ")
                        .. " "
                )
            end
            remotes[#remotes + 1] = name
        end
    end
    io.write(
        "forge ",
        plan.forge.kind,
        ", remote of record ",
        plan.forge.remote,
        " (",
        plan.forge.why,
        ")\n"
    )
    if #tags > 0 then
        return push_tags(ctx, plan, tags, remotes)
    end
    local status = 0
    for _, remote in ipairs(remotes) do
        local argv = argv_for(ctx.root, plan, remote)
        dev_command.show(ctx, argv)
        local out, code = dev_os.capture(argv, { cwd = ctx.root, stderr = "stdout" })
        if code == 0 then
            dev_command.say("Pushed " .. plan.ref .. " to " .. remote .. ".")
        else
            dev_command.say("The push of " .. plan.ref .. " to " .. remote .. " failed.")
            status = 1
        end
        out = out:gsub("\n+$", "")
        if out ~= "" then
            io.write("    ", (out:gsub("\n", "\n    ")), "\n")
        end
    end
    return status
end

return M
