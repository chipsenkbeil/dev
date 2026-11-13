local dev_os = require("dev.os")
local text = require("dev.text")
local vcs = require("dev.vcs")
local verb = require("dev.verb")

---@class dev.cmd.pull
local M = {}

local function resolve(root)
    local backend, err = vcs.require(root)
    if not backend then
        return nil, err
    end
    local base = vcs.base(root, backend)
    if backend == vcs.JJ then
        local has_sync = dev_os.run(
            vcs.with(base, "config", "get", "aliases.sync"),
            { stdout = "null", stderr = "null" }
        ) == 0
        if has_sync then
            return { vcs.with(base, "sync") }
        end
        return {
            vcs.with(base, "git", "fetch", "--all-remotes"),
            vcs.with(base, "rebase", "-o", "trunk()", "--skip-emptied"),
        }
    end
    local branch, code = dev_os.capture(vcs.with(base, "symbolic-ref", "--short", "-q", "HEAD"))
    if code ~= 0 then
        return nil, "HEAD is detached in " .. root .. ", and a pull needs a branch"
    end
    local dirty = dev_os.capture(vcs.with(base, "status", "--porcelain", "--untracked-files=no"))
    if dirty ~= "" then
        return nil, root .. " has uncommitted changes, commit or stash them before pulling"
    end
    return { vcs.with(base, "pull", "--rebase", "origin", text.trim(branch)) }
end

---The command lines `dev help pull` shows.
---@param root string absolute path of the project root
---@return string[] lines one command per line, or a single `(none: ...)` line
function M.commands(root)
    local steps, err = resolve(root)
    if not steps then
        return { "(none: " .. err .. ")" }
    end
    local lines = {}
    for _, argv in ipairs(steps) do
        lines[#lines + 1] = table.concat(argv, " ")
    end
    return lines
end

---Fetch the remote and rebase local work onto it.
---
---The first command that fails ends the run with its exit code. An argument
---is refused before this runs.
---@param ctx dev.Ctx the verb's context
---@return integer code the exit code
function M.run(ctx)
    local steps, err = resolve(ctx.root)
    if not steps then
        verb.die(text.sentence(err))
    end
    for _, argv in ipairs(steps) do
        verb.show(ctx, argv)
        local code = dev_os.run(argv) or 1
        if code ~= 0 then
            return code
        end
    end
    return 0
end

return M
