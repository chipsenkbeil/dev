local devos = require("dev.os")
local forge = require("dev.forge")
local fs = require("dev.fs")
local text = require("dev.text")
local vcs = require("dev.vcs")
local verb = require("dev.verb")

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
            "DEV_SELF is not an absolute path, refusing to push without the attribution check"
    end
    local guard = fs.dirname(self) .. "/commit-guard"
    if not fs.is_exec(guard) then
        return nil,
            "commit-guard is missing at "
                .. guard
                .. ", refusing to push without the attribution check"
    end
    return guard
end

local function resolve(root)
    local backend, err = vcs.require(root)
    if not backend then
        return nil, err
    end
    local plan = { backend = backend }
    if backend == vcs.JJ then
        plan.ref = vcs.trunk(vcs.branches(root, backend))
        if not plan.ref then
            return nil, "no master or main bookmark in " .. root
        end
    else
        local branch, code =
            devos.capture({ "git", "-C", root, "symbolic-ref", "--short", "-q", "HEAD" })
        if code ~= 0 then
            return nil, "HEAD is detached in " .. root .. ", check out a branch to push"
        end
        plan.ref = text.trim(branch)
        plan.sha = text.trim(devos.capture({ "git", "-C", root, "rev-parse", "HEAD" }))
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
    return { plan.guard, "push", "--", remote, plan.sha .. ":refs/heads/" .. plan.ref }
end

---The command lines `dev help push` shows.
---@param root string absolute path of the project root
---@return string[] lines one command per line, or a single `(none: ...)` line
function M.commands(root)
    local plan, err = resolve(root)
    if not plan then
        return { "(none: " .. err .. ")" }
    end
    local lines = {}
    for _, remote in ipairs(plan.remotes) do
        lines[#lines + 1] = table.concat(argv_for(root, plan, remote), " ")
    end
    return lines
end

---Push the trunk to the remote of record, or to the remotes named.
---
---It prints the forge, the remote and why, then one line per remote with the
---command's output indented under it. A flag is refused before this runs.
---@param ctx dev.Ctx the verb's context, whose `args` are remote names
---@return integer code 0, or 1 when a push fails
function M.run(ctx)
    local plan, err = resolve(ctx.root)
    if not plan then
        verb.die("dev: " .. err)
    end
    local remotes = plan.remotes
    if #ctx.args > 0 then
        remotes = {}
        for _, name in ipairs(ctx.args) do
            if not text.contains(plan.named, name) then
                verb.usage_error(
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
    local status = 0
    for _, remote in ipairs(remotes) do
        local argv = argv_for(ctx.root, plan, remote)
        verb.show(ctx, argv)
        local out, code = devos.capture(argv, { cwd = ctx.root, stderr = "stdout" })
        if code == 0 then
            io.write(remote, ": pushed ", plan.ref, "\n")
        else
            io.write(remote, ": push of ", plan.ref, " failed\n")
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
