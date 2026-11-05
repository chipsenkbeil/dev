local devos = require("dev.os")
local fs = require("dev.fs")
local vcs = require("dev.vcs")
local verb = require("dev.verb")

---@class dev.cmd.ws
---@field handlers table<string, fun(ctx: dev.Ctx): integer> the handlers of the `ws` subcommands
local M = { handlers = {} }

local function workspace_root()
    local env = os.getenv("DEV_WS_ROOT")
    if env and env ~= "" then
        return env
    end
    return (os.getenv("HOME") or "") .. "/.local/share/workspaces"
end

local function repo_name(base, root)
    local inside = root:match("^" .. base:gsub("%p", "%%%0") .. "/([^/]+)")
    return inside or fs.basename(root)
end

local function parse(ctx)
    local name = ctx.args[1]
    if name == nil then
        verb.usage_error(ctx, "needs a NAME")
    end
    if name:sub(1, 1) == "-" then
        verb.usage_error(ctx, "unknown flag " .. name)
    end
    if ctx.args[2] ~= nil then
        verb.usage_error(ctx, "takes one NAME, got " .. ctx.args[2])
    end
    if name:find("/", 1, true) or name == "." or name == ".." then
        verb.usage_error(ctx, "NAME is one folder name, got " .. name)
    end
    return name
end

local function plan(root, name, path)
    local backend = vcs.backend(root)
    if backend == vcs.JJ then
        return vcs.with(
            vcs.base(root, backend),
            "workspace",
            "add",
            "--name",
            name,
            "-r",
            "trunk()",
            path
        )
    end
    if backend == vcs.GIT then
        return vcs.with(vcs.base(root, backend), "worktree", "add", "-b", name, path)
    end
    return nil
end

---Make a workspace for the current project under the central root.
---
---The path is `DEV_WS_ROOT`, else `~/.local/share/workspaces`, then the
---project's folder name, then NAME. A jj project gets a jj workspace on the
---trunk revision, a git project a worktree on a new branch NAME, and any other
---folder a plain directory. The path is printed on standard output.
---@param ctx dev.Ctx the verb's context
---@return integer code the exit code
M.handlers["ws new"] = function(ctx)
    local name = parse(ctx)
    local base = workspace_root()
    local path = fs.join(base, repo_name(base, ctx.root), name)
    if fs.exists(path) then
        verb.die("dev ws new: " .. path .. " already exists")
    end
    local made, why = fs.mkdir(fs.dirname(path), { parents = true })
    if not made then
        verb.die("dev ws new: " .. why)
    end
    local argv = plan(ctx.root, name, path)
    if argv == nil then
        made, why = fs.mkdir(path)
        if not made then
            verb.die("dev ws new: " .. why)
        end
    else
        verb.show(ctx, argv)
        local code = devos.run(argv) or 1
        if code ~= 0 then
            return code
        end
    end
    print(path)
    return 0
end

return M
