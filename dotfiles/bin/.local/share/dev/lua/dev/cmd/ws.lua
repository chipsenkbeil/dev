local dev_os = require("dev.os")
local forge = require("dev.forge")
local fs = require("dev.fs")
local vcs = require("dev.vcs")
local verb = require("dev.verb")

---@class dev.cmd.ws
---@field handlers table<string, fun(ctx: dev.Ctx): integer> the handlers of the `ws` subcommands
local M = { handlers = {} }

local function sentence(text)
    text = text:gsub("^%l", string.upper)
    if not text:find("%.$") then
        text = text .. "."
    end
    return text
end

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
    if name == "" or name:find("/", 1, true) or name == "." or name == ".." then
        verb.usage_error(ctx, "NAME is one folder name, got " .. name)
    end
    return name
end

local function remote_trunk(root, remote)
    local ref, err = vcs.remote_trunk(root, remote)
    if ref == nil then
        return nil, sentence(err)
    end
    return ref
end

local function fetch_trunk(ctx)
    local backend = vcs.backend(ctx.root)
    if backend ~= vcs.JJ and backend ~= vcs.GIT then
        return nil
    end
    local found, why = forge.resolve(ctx.root)
    if not found then
        return sentence("trunk cannot be compared: " .. why)
    end
    local argv = vcs.base(ctx.root, backend, { quiet = true })
    if backend == vcs.JJ then
        argv = vcs.with(argv, "git", "fetch", "--remote", found.remote)
    else
        argv = vcs.with(argv, "fetch", found.remote)
    end
    verb.show(ctx, argv)
    local out, code = dev_os.capture(argv, { stderr = "stdout" })
    if code ~= 0 then
        return sentence(
            string.format("the fetch from %s failed: %s", found.remote, (out:gsub("\n$", "")))
        )
    end
    if backend == vcs.GIT then
        local start, err = remote_trunk(ctx.root, found.remote)
        if start == nil then
            return err
        end
        return nil, start
    end
    return nil
end

---@class dev.cmd.ws.PlanOpts
---@field start string? nil when unset, the git start point of the worktree

local function plan(root, name, path, opts)
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
        if opts.start == nil then
            error("a git worktree needs a start point")
        end
        return vcs.with(
            vcs.base(root, backend),
            "worktree",
            "add",
            "--no-track",
            "-b",
            name,
            path,
            opts.start
        )
    end
    return nil
end

---Make a workspace for the current project under the central root.
---
---The path is `DEV_WS_ROOT`, else `~/.local/share/workspaces`, then the
---project's folder name, then NAME. A jj project gets a jj workspace on the
---trunk revision, a git project a worktree on a new branch NAME at the fetched
---trunk of the remote of record, and any other folder a plain directory. The
---path is printed on standard output.
---@param ctx dev.Ctx the verb's context
---@return integer code the exit code
M.handlers["ws new"] = function(ctx)
    local name = parse(ctx)
    local marked = false
    for _, marker in ipairs({ ".jj", ".git", ".dev" }) do
        marked = marked or fs.exists(ctx.root .. "/" .. marker)
    end
    if not marked then
        verb.die(ctx.root .. " is not inside a project.")
    end
    local base = workspace_root()
    local path = fs.join(base, repo_name(base, ctx.root), name)
    if fs.exists(path) then
        verb.die(path .. " already exists.")
    end
    local failure, start = fetch_trunk(ctx)
    if failure then
        verb.die(failure)
    end
    local made, why = fs.mkdir(fs.dirname(path), { parents = true })
    if not made then
        verb.die(sentence(why))
    end
    local argv = plan(ctx.root, name, path, { start = start })
    if argv == nil then
        made, why = fs.mkdir(path)
        if not made then
            verb.die(sentence(why))
        end
    else
        verb.show(ctx, argv)
        local code = dev_os.run(argv) or 1
        if code ~= 0 then
            return code
        end
    end
    print(path)
    return 0
end

---Check that a workspace folder holds nothing outside a commit.
---@private
---@param backend dev.vcs.Backend? the backend of the workspace folder
---@param path string the workspace folder
---@return boolean clean whether the folder holds nothing outside a commit
---@return string? why what was found or why it could not be read
function M.__clean(backend, path)
    if backend == nil then
        return true
    end
    local argv
    if backend == vcs.JJ then
        argv = vcs.with(
            vcs.base(path, backend, { quiet = true }),
            "log",
            "-r",
            "@",
            "--no-graph",
            "-T",
            'if(empty, "", "changes")'
        )
    else
        argv = vcs.with(vcs.base(path, backend), "status", "--porcelain")
    end
    local out, code = dev_os.capture(argv, { stderr = "null" })
    if code ~= 0 then
        return false, "cannot read the state of " .. path
    end
    if out ~= "" then
        return false, path .. " holds changes not in a commit"
    end
    return true
end

---List the current project's workspaces under the central root.
---
---Each line is the folder's name, a tab and its path. A project with no
---workspaces prints nothing.
---@param ctx dev.Ctx the verb's context
---@return integer code the exit code
M.handlers["ws ls"] = function(ctx)
    if ctx.args[1] ~= nil then
        verb.usage_error(ctx, "takes no arguments, got " .. ctx.args[1])
    end
    local base = workspace_root()
    local dir = fs.join(base, repo_name(base, ctx.root))
    for _, name in ipairs(fs.list(dir) or {}) do
        local path = fs.join(dir, name)
        if fs.is_dir(path) then
            print(name .. "\t" .. path)
        end
    end
    return 0
end

local function under(path, base)
    return path:sub(1, #base + 1) == base .. "/"
end

local function forgotten(root, name)
    local argv = vcs.with(
        vcs.base(root, vcs.JJ, { quiet = true }),
        "workspace",
        "list",
        "-T",
        'name ++ "\\n"'
    )
    local out, code = dev_os.capture(argv, { stderr = "null" })
    if code ~= 0 then
        return false
    end
    for line in out:gmatch("[^\n]+") do
        if line == name then
            return false
        end
    end
    return true
end

---@class dev.cmd.ws.RemoveOpts
---@field inside boolean? false when unset, skips only the refusal of the workspace dev runs in
---@field forgotten boolean? false when unset, removes a jj folder jj no longer lists and refuses any other
---@field show fun(argv: string[])? nil when unset, called with the command before it runs

---Remove a workspace of the project at `root` and its folder.
---
---A jj workspace is forgotten and a git worktree is removed. A message names
---what stopped the removal, and `code` is set when jj or git itself failed.
---@param root string absolute path of the project root dev runs in
---@param name string the workspace folder's name
---@param opts dev.cmd.ws.RemoveOpts? what to skip and show
---@return boolean ok whether the workspace is gone
---@return string? message the removal, or what kept the workspace
---@return integer? code the exit code of a failed jj or git
function M.remove(root, name, opts)
    opts = opts or {}
    local base = workspace_root()
    local path = fs.join(base, repo_name(base, root), name)
    local real = fs.realpath(path)
    local real_base = fs.realpath(base)
    local real_root = fs.realpath(root)
    local stray = fs.is_file(path)
    if not fs.is_dir(path) and not stray then
        if opts.inside and real_base and real_root and not under(real_root, real_base) then
            return false, root .. " is outside " .. base
        end
        return false, path .. " is not a workspace folder"
    end
    if fs.is_link(path) or real == nil or real_base == nil then
        return false, path .. " is a link, not removed"
    end
    if not under(real, real_base) then
        return false, path .. " is outside " .. base
    end
    if real == real_root and not opts.inside then
        return false, path .. " is the workspace dev runs in"
    end
    local backend = not stray and vcs.backend(path) or nil
    local gone = backend == vcs.JJ and forgotten(root, name)
    if gone and not opts.forgotten then
        return false,
            path
                .. " is a jj folder jj no longer tracks. Run dev ws rm "
                .. name
                .. " --forgotten to discard it."
    end
    if opts.forgotten and not gone then
        return false, path .. " is not a jj folder jj no longer lists. --forgotten does not apply."
    end
    if not gone then
        local clean, why = M.__clean(backend, path)
        if not clean then
            return false, why
        end
    end
    local argv
    if backend == vcs.JJ and not gone then
        argv = vcs.with(vcs.base(root, vcs.JJ), "workspace", "forget", name)
    elseif backend == vcs.GIT then
        argv = vcs.with(vcs.base(root, vcs.GIT), "worktree", "remove", path)
    end
    if argv ~= nil then
        if opts.show then
            opts.show(argv)
        end
        local code = dev_os.run(argv) or 1
        if code ~= 0 then
            return false, argv[1] .. " exited " .. code, code
        end
    end
    local removed, err = fs.remove(path, { recursive = true })
    if not removed then
        return false, err
    end
    return true, "removed " .. path
end

---Remove a workspace of the current project and its folder.
---
---Only a folder directly under ROOT/<repo> is removed, never a link and never
---the workspace the command runs in. A jj workspace is forgotten, a git
---worktree is removed, and a folder with changes not in a commit is refused
---and left in place. A jj folder whose workspace jj no longer lists is refused
---unless `--forgotten` is given, which deletes it. A plain file directly under
---ROOT/<repo> is deleted.
---@param ctx dev.Ctx the verb's context
---@return integer code the exit code
M.handlers["ws rm"] = function(ctx)
    local discard = false
    for i, arg in ipairs(ctx.args) do
        if arg == "--forgotten" then
            discard = true
            table.remove(ctx.args, i)
            break
        end
    end
    local name = parse(ctx)
    local ok, message, code = M.remove(ctx.root, name, {
        forgotten = discard,
        show = function(argv)
            verb.show(ctx, argv)
        end,
    })
    if not ok then
        if code then
            return code
        end
        verb.die(sentence(message))
    end
    print(message)
    return 0
end

return M
