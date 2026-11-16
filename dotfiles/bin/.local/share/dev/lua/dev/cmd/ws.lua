local cmd_board = require("dev.cmd.board")
local dev_os = require("dev.os")
local forge = require("dev.forge")
local fs = require("dev.fs")
local vcs = require("dev.vcs")
local verb = require("dev.verb")

---@class dev.cmd.ws
---@field handlers table<string, fun(ctx: dev.Ctx): integer> the handlers of the `ws` subcommands
---@field Refusal table<string, dev.cmd.ws.Refusal> the reasons a removal stops
local M = { handlers = {} }

local EMPTY_HEADS = "heads(mutable()) & empty()"
local IGNORE_WORKING_COPY = "--ignore-working-copy"
local STRAY_HEADS = "heads(mutable()) ~ empty()"
local HELD_BY_REF = " ~ bookmarks() ~ remote_bookmarks() ~ tags()"
local STALE_BOOKMARKS = "bookmarks() ~ ::trunk()"
local HEAD_TEMPLATE = 'commit_id ++ "\\t" ++ description.first_line() ++ "\\n"'
local BOOKMARK_TEMPLATE = 'if(remote, "", name ++ "\\n")'
local SHORT_ID = 12
local STAMP_FORMAT = "!%Y%m%dT%H%M%SZ"

---@enum dev.cmd.ws.Step
local Step = { GONE = "gone", DONE = "done", KEEP = "keep" }

local function sentence(text)
    text = text:gsub("^%l", string.upper)
    if not text:find("%.$") then
        text = text .. "."
    end
    return text
end

---@enum dev.cmd.ws.Refusal
local Refusal = {
    NO_VCS = "no_vcs",
    STILL_THERE = "still_there",
    NOT_FORGETTABLE = "not_forgettable",
    COMMAND_FAILED = "command_failed",
    OUTSIDE = "outside",
    NOT_WORKSPACE = "not_workspace",
    LINK = "link",
    RUNNING_HERE = "running_here",
    UNTRACKED = "untracked",
    NOT_FORGOTTEN = "not_forgotten",
    DIRTY = "dirty",
    UNREADABLE = "unreadable",
    LOCKED = "locked",
    PRUNE_DROPS = "prune_drops",
    LIST_FAILED = "list_failed",
    FILESYSTEM = "filesystem",
    KEPT = "kept",
}
M.Refusal = Refusal

---@class dev.cmd.ws.Reason
---@field reason dev.cmd.ws.Refusal why the workspace stayed
---@field path string? the folder the reason is about
---@field name string? the workspace's name
---@field base string? the central workspaces root, for an outside folder
---@field command string? the vcs command that failed
---@field code integer? the exit code of a failed jj or git, which dev passes on as its own
---@field detail string? the line, error or exit status the reason carries
---@field stayed string? the folder a failed move back left in the trash, with `detail` its error

---The sentence writer of each refusal.
local DESCRIPTIONS = {
    [Refusal.NO_VCS] = function(why)
        return why.path .. " is neither a jj nor a git project"
    end,
    [Refusal.STILL_THERE] = function(why)
        return why.path .. " still exists"
    end,
    [Refusal.NOT_FORGETTABLE] = function(why)
        return why.name .. " is not a jj workspace that can be forgotten"
    end,
    [Refusal.COMMAND_FAILED] = function(why)
        local text = "the " .. why.command .. " command exited " .. why.code
        if why.stayed then
            text = text .. ". The folder stayed at " .. why.stayed .. ": " .. why.detail
        end
        return text
    end,
    [Refusal.OUTSIDE] = function(why)
        return why.path .. " is outside " .. why.base
    end,
    [Refusal.NOT_WORKSPACE] = function(why)
        return why.path .. " is not a workspace folder"
    end,
    [Refusal.LINK] = function(why)
        return why.path .. " is a link, not removed"
    end,
    [Refusal.RUNNING_HERE] = function(why)
        return why.path .. " is the workspace dev runs in"
    end,
    [Refusal.UNTRACKED] = function(why)
        return why.path
            .. " is a jj folder that jj no longer tracks. Run `dev ws rm "
            .. why.name
            .. " --forgotten` to discard it."
    end,
    [Refusal.NOT_FORGOTTEN] = function(why)
        return why.path .. " is not a jj folder jj no longer lists. --forgotten does not apply."
    end,
    [Refusal.DIRTY] = function(why)
        return why.path .. " holds changes not in a commit"
    end,
    [Refusal.UNREADABLE] = function(why)
        local text = "cannot read the state of " .. why.path
        if why.detail then
            text = text .. ": " .. why.detail
        end
        return text
    end,
    [Refusal.LOCKED] = function(why)
        return why.path .. " is a locked git worktree. Run git worktree unlock first."
    end,
    [Refusal.PRUNE_DROPS] = function(why)
        return "git worktree prune would also drop the record of "
            .. why.path
            .. ", which git marks prunable. Run git worktree prune first."
    end,
    [Refusal.LIST_FAILED] = function(why)
        return "the git worktree list command exited " .. why.detail
    end,
    [Refusal.FILESYSTEM] = function(why)
        return why.detail
    end,
    [Refusal.KEPT] = function(why)
        return why.detail
    end,
}

---Write what stopped a workspace removal as sentences.
---@param why dev.cmd.ws.Reason the refusal, a `RemoveResult` included
---@return string text the full sentences a person reads
function M.describe(why)
    return sentence(DESCRIPTIONS[why.reason](why))
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
    return inside or fs.basename(vcs.main_root(root, vcs.backend(root)))
end

local function parse(ctx)
    local name = ctx.args[1]
    if name == nil then
        verb.usage_error(ctx, "needs a NAME")
    end
    if name:sub(1, 1) == "-" then
        verb.usage_error(ctx, "Unknown flag " .. name .. ".")
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
        argv = vcs.with(argv, IGNORE_WORKING_COPY, "git", "fetch", "--remote", found.remote)
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

---@class dev.cmd.ws.plan.Opts
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
    if vcs.backend(ctx.root) == vcs.JJ then
        local refresh = vcs.with(vcs.base(ctx.root, vcs.JJ), "workspace", "update-stale")
        verb.show(ctx, refresh)
        local refreshed = dev_os.run(refresh) or 1
        if refreshed ~= 0 then
            return refreshed
        end
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

local function first_line(text)
    for line in text:gmatch("[^\n]+") do
        if line:find("%S") then
            return line
        end
    end
    return nil
end

---Check that a workspace folder holds nothing outside a commit.
---@private
---@param backend dev.vcs.Backend? the backend of the workspace folder
---@param path string the workspace folder
---@return boolean clean whether the folder holds nothing outside a commit
---@return dev.cmd.ws.Reason? why what was found or why it could not be read
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
    local out, code = dev_os.capture(argv, { stderr = "stdout" })
    if code ~= 0 then
        return false, { reason = Refusal.UNREADABLE, path = path, detail = first_line(out) }
    end
    if out ~= "" then
        return false, { reason = Refusal.DIRTY, path = path }
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

---@class dev.cmd.ws.Process
---@field pid string the process id
---@field command string the process's command name

---Find the processes on Linux whose working directory is `dir` or under it.
---@private
---@param dir string the real path of the folder
---@return dev.cmd.ws.Process[] found the processes, in the order `find` lists them
function M.__processes_proc(dir)
    local argv = {
        "find",
        "/proc",
        "-mindepth",
        "2",
        "-maxdepth",
        "2",
        "-name",
        "cwd",
        "-printf",
        "%h\\t%l\\n",
    }
    local out = dev_os.capture(argv, { stderr = "null" })
    local found = {}
    for pid, cwd in out:gmatch("/proc/(%d+)\t([^\n]*)\n") do
        if cwd == dir or under(cwd, dir) then
            local comm = fs.read("/proc/" .. pid .. "/comm") or ""
            found[#found + 1] = { pid = pid, command = (comm:gsub("\n$", "")) }
        end
    end
    return found
end

---Find the processes on macOS whose working directory is `dir` or under it.
---@private
---@param dir string the real path of the folder
---@return dev.cmd.ws.Process[] found the processes, in the order `lsof` lists them
function M.__processes_lsof(dir)
    local out = dev_os.capture({ "lsof", "-a", "-d", "cwd", "-F", "pcn" }, { stderr = "null" })
    local found = {}
    local pid, command
    for kind, value in out:gmatch("(%a)([^\n]*)\n") do
        if kind == "p" then
            pid = value
        elseif kind == "c" then
            command = value
        elseif kind == "n" and (value == dir or under(value, dir)) then
            found[#found + 1] = { pid = pid, command = command }
        end
    end
    return found
end

local function processes_inside(dir)
    if fs.is_dir("/proc/self") then
        return M.__processes_proc(dir)
    end
    return M.__processes_lsof(dir)
end

---@class dev.cmd.ws.remove.Opts
---@field inside boolean? false when unset, skips only the refusal of the workspace dev runs in
---@field forgotten boolean? false when unset, removes a jj folder that jj does not list and refuses
---   any other
---@field show fun(argv: string[])? nil when unset, called with the command before it runs
---@field warn fun(line: string)? nil when unset, called with a line for each process inside the
---   folder before it moves
---@field missing string? nil when unset, the recorded folder that is already gone

---@class dev.cmd.ws.detach.Opts
---@field backend dev.vcs.Backend? the backend that forgets or removes, nil to do nothing
---@field path string the folder the workspace had
---@field show fun(argv: string[])? nil when unset, called with the command before it runs
---@field moved boolean? false when unset, true when the folder is already in the trash

---Prune the git worktree record a jj workspace leaves in a colocated repo.
---
---The record stays once the folder has moved, and `jj workspace add` with the same
---name then fails. The prune is best effort, as the workspace is already forgotten. It
---also drops any other record whose folder is gone.
---@param root string the folder jj runs in
---@param show fun(argv: string[])? nil when unset, called with the command before it runs
local function drop_git_record(root, show)
    local ask = vcs.with(vcs.base(root, vcs.JJ), "git", "root")
    local dir, code = dev_os.capture(ask, { stderr = "null" })
    dir = dir:gsub("%s+$", "")
    if code ~= 0 or not dir:find("/%.git$") then
        return
    end
    local argv = { "git", "--git-dir", dir, "worktree", "prune" }
    if show then
        show(argv)
    end
    dev_os.run(argv)
end

---Forget the workspace or prune the worktree record.
---@param root string the folder the vcs runs in
---@param name string the workspace's name
---@param opts dev.cmd.ws.detach.Opts what to detach and show
---@return boolean ok whether the record is gone
---@return dev.cmd.ws.Reason? why what stopped it, nil when it is gone
local function detach(root, name, opts)
    local argv
    if opts.backend == vcs.JJ then
        argv = vcs.with(vcs.base(root, vcs.JJ), "workspace", "forget", name)
    elseif opts.backend == vcs.GIT and opts.moved then
        argv = vcs.with(vcs.base(root, vcs.GIT), "worktree", "prune")
    elseif opts.backend == vcs.GIT then
        argv = vcs.with(vcs.base(root, vcs.GIT), "worktree", "remove", opts.path)
    end
    if argv ~= nil then
        if opts.show then
            opts.show(argv)
        end
        local code = dev_os.run(argv) or 1
        if code ~= 0 then
            return false, { reason = Refusal.COMMAND_FAILED, command = argv[1], code = code }
        end
    end
    if opts.backend == vcs.JJ then
        drop_git_record(root, opts.show)
    end
    return true
end

---@class dev.cmd.ws.RemoveResult: dev.cmd.ws.Reason
---@field ok boolean whether the workspace is gone
---@field message string? the move, set when the workspace is gone
---@field purged string[] one sentence for each trash entry purged

---Build the result of a removal that stopped.
---@param why dev.cmd.ws.Reason
---@return dev.cmd.ws.RemoveResult
local function refused(why)
    why.ok = false
    why.purged = {}
    return why
end

local function remove_missing(root, name, opts)
    local backend = vcs.backend(root)
    if backend ~= vcs.JJ and backend ~= vcs.GIT then
        return refused({ reason = Refusal.NO_VCS, path = root })
    end
    if fs.exists(opts.missing) then
        return refused({ reason = Refusal.STILL_THERE, path = opts.missing })
    end
    if backend == vcs.JJ and (name == "default" or forgotten(root, name)) then
        return refused({ reason = Refusal.NOT_FORGETTABLE, name = name })
    end
    local ok, why = detach(root, name, { backend = backend, path = opts.missing, show = opts.show })
    if not ok then
        return refused(why)
    end
    return { ok = true, message = "forgot " .. name, purged = {} }
end

local function purge(dir)
    local TRASH_SECS = 14 * 24 * 60 * 60
    local cutoff = os.date(STAMP_FORMAT, os.time() - TRASH_SECS)
    local purged = {}
    for _, entry in ipairs(fs.list(dir) or {}) do
        local stamp = entry:match("^.+%-(%d%d%d%d%d%d%d%dT%d%d%d%d%d%dZ)$")
        if stamp and stamp < cutoff then
            local path = fs.join(dir, entry)
            local removed, err = fs.remove(path, { recursive = true })
            if removed then
                purged[#purged + 1] = "Purged " .. path .. " from the trash."
            else
                purged[#purged + 1] = sentence("Could not purge " .. path .. ": " .. err)
            end
        end
    end
    return purged
end

---@class dev.cmd.ws.prune_blocker.Opts
---@field gone table<string, boolean>? paths of other worktrees whose prunable records may drop

---Name what would stop `git worktree prune` from dropping only the given worktrees.
---@param anchor string the project's main folder, where git runs
---@param paths string[] the worktree paths the prune is meant to drop
---@param opts dev.cmd.ws.prune_blocker.Opts the records that may drop with them
---@return dev.cmd.ws.Reason? why the reason, nil when nothing blocks
local function prune_blocker(anchor, paths, opts)
    local argv = vcs.with(vcs.base(anchor, vcs.GIT), "worktree", "list", "--porcelain")
    local out, code = dev_os.capture(argv, { stderr = "null" })
    if code ~= 0 then
        return { reason = Refusal.LIST_FAILED, detail = tostring(code) }
    end
    for block in (out .. "\n"):gmatch("(.-)\n\n") do
        local path = block:match("^worktree ([^\n]+)")
        if path and (path == paths[1] or path == paths[2]) then
            if block:find("\nlocked") then
                return { reason = Refusal.LOCKED, path = path }
            end
        elseif
            path
            and not (opts.gone and opts.gone[path])
            and block:find("\nprunable")
            and not block:find("\nlocked")
        then
            return { reason = Refusal.PRUNE_DROPS, path = path }
        end
    end
end

---@class dev.cmd.ws.move_to_trash.Opts
---@field trash string the trash folder of the project
---@field backend dev.vcs.Backend? the backend that forgets or prunes, nil to do nothing
---@field path string the folder the workspace has
---@field show fun(argv: string[])? nil when unset, called with the command before it runs

---Move a workspace folder to the trash and detach its record.
---@param anchor string
---@param name string
---@param opts dev.cmd.ws.move_to_trash.Opts
---@return dev.cmd.ws.RemoveResult
local function move_to_trash(anchor, name, opts)
    local target = fs.join(opts.trash, name .. "-" .. os.date(STAMP_FORMAT))
    local made, why = fs.mkdir(opts.trash, { parents = true })
    if not made then
        return refused({ reason = Refusal.FILESYSTEM, detail = why })
    end
    local moved, err = fs.move(opts.path, target)
    if not moved then
        return refused({ reason = Refusal.FILESYSTEM, detail = err })
    end
    local ok, stopped = detach(anchor, name, {
        backend = opts.backend,
        path = opts.path,
        show = opts.show,
        moved = true,
    })
    if not ok then
        local back, back_err = fs.move(target, opts.path)
        if not back then
            stopped.stayed = target
            stopped.detail = back_err
        end
        return refused(stopped)
    end
    return {
        ok = true,
        message = "Moved " .. opts.path .. " to " .. target .. ".",
        purged = purge(opts.trash),
    }
end

---Remove a workspace of the project at `root` and move its folder to the trash.
---
---The folder moves to `.trash/<repo>/<name>-<UTC stamp>` under the central
---workspaces root, ignored files included, before a jj workspace is forgotten
---or the git worktree record is pruned. If the forget or prune fails the folder moves back.
---A locked git worktree, or one whose project has another worktree with a gone
---folder, is refused before the move. The prune would skip the locked one or
---drop the other record.
---Trash entries whose stamp is over 14 days old are then purged. A `reason`
---names what stopped the removal, and `code` is set when jj or git itself failed.
---With `opts.missing` the folder is already gone, so the jj workspace is
---forgotten or the git worktree record is removed and nothing is moved.
---@param root string absolute path of the project root dev runs in
---@param name string the workspace folder's name
---@param opts dev.cmd.ws.remove.Opts? what to skip and show
---@return dev.cmd.ws.RemoveResult result
function M.remove(root, name, opts)
    local TRASH_DIR = ".trash"
    opts = opts or {}
    if opts.missing then
        return remove_missing(root, name, opts)
    end
    local base = workspace_root()
    local path = fs.join(base, repo_name(base, root), name)
    local real = fs.realpath(path)
    local real_base = fs.realpath(base)
    local real_root = fs.realpath(root)
    local stray = fs.is_file(path)
    if not fs.is_dir(path) and not stray then
        if opts.inside and real_base and real_root and not under(real_root, real_base) then
            return refused({ reason = Refusal.OUTSIDE, path = root, base = base })
        end
        return refused({ reason = Refusal.NOT_WORKSPACE, path = path })
    end
    if fs.is_link(path) or real == nil or real_base == nil then
        return refused({ reason = Refusal.LINK, path = path })
    end
    if not under(real, real_base) then
        return refused({ reason = Refusal.OUTSIDE, path = path, base = base })
    end
    if real == real_root and not opts.inside then
        return refused({ reason = Refusal.RUNNING_HERE, path = path })
    end
    local backend = not stray and vcs.backend(path) or nil
    local gone = backend == vcs.JJ and forgotten(root, name)
    if gone and not opts.forgotten then
        return refused({ reason = Refusal.UNTRACKED, path = path, name = name })
    end
    if opts.forgotten and not gone then
        return refused({ reason = Refusal.NOT_FORGOTTEN, path = path })
    end
    if not gone then
        local clean, why = M.__clean(backend, path)
        if not clean then
            return refused(why)
        end
    end
    local anchor = real == real_root and vcs.main_root(root, backend) or root
    if backend == vcs.GIT then
        local blocked = prune_blocker(anchor, { path, real }, {})
        if blocked then
            return refused(blocked)
        end
    end
    if opts.warn then
        for _, found in ipairs(processes_inside(real)) do
            local line = "Process %s (%s) is still inside %s."
            opts.warn(line:format(found.pid, found.command, path))
        end
    end
    return move_to_trash(anchor, name, {
        trash = fs.join(base, TRASH_DIR, repo_name(base, root)),
        backend = not gone and backend or nil,
        path = path,
        show = opts.show,
    })
end

---Remove a workspace of the current project and its folder.
---
---Only a folder directly under ROOT/<repo> is removed, never a link and never
---the workspace the command runs in. The folder moves to the trash, a jj
---workspace is forgotten, a git worktree record is pruned, and a folder with
---changes not in a commit is refused and left in place. A jj folder whose
---workspace jj no longer lists is refused unless `--forgotten` is given (it
---then moves to the trash). A plain file directly under ROOT/<repo> is moved.
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
    local result = M.remove(ctx.root, name, {
        forgotten = discard,
        show = function(argv)
            verb.show(ctx, argv)
        end,
        warn = verb.note,
    })
    if not result.ok then
        if result.code then
            return result.code
        end
        verb.die(M.describe(result))
    end
    print(result.message)
    for _, line in ipairs(result.purged) do
        verb.say(line)
    end
    return 0
end

local function counted(count, noun)
    return count .. " " .. noun .. (count == 1 and "" or "s")
end

local function jj_lines(root, ...)
    local argv = vcs.with(vcs.base(root, vcs.JJ, { quiet = true }), ...)
    local out, code = dev_os.capture(argv, { stderr = "null" })
    if code ~= 0 then
        verb.die(sentence("The jj command failed in " .. root))
    end
    local lines = {}
    for line in out:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    return lines
end

local function jj_workspaces(root)
    local found = {}
    for _, name in ipairs(jj_lines(root, "workspace", "list", "-T", 'name ++ "\\n"')) do
        if name ~= "default" then
            local argv = vcs.with(
                vcs.base(root, vcs.JJ, { quiet = true }),
                "workspace",
                "root",
                "--name",
                name
            )
            local out, code = dev_os.capture(argv, { stderr = "null" })
            if code == 0 and out ~= "" then
                found[#found + 1] = { name = name, path = (out:gsub("\n$", "")) }
            end
        end
    end
    return found
end

local function git_worktrees(root)
    local argv = vcs.with(vcs.base(root, vcs.GIT), "worktree", "list", "--porcelain")
    local out, code = dev_os.capture(argv, { stderr = "null" })
    if code ~= 0 then
        verb.die(sentence("git worktree list failed in " .. root))
    end
    local found = {}
    local seen = 0
    for line in out:gmatch("[^\n]+") do
        local path = line:match("^worktree (.+)$")
        if path then
            seen = seen + 1
            if seen > 1 then
                found[#found + 1] = { name = fs.basename(path), path = path }
            end
        end
    end
    return found
end

local function plan_workspaces(root, found, finished)
    local steps = {}
    local ordered = {}
    local here = fs.realpath(root)
    for _, space in ipairs(found) do
        local step = { name = space.name, path = space.path }
        if not fs.exists(space.path) then
            step.kind = Step.GONE
            ordered[#ordered + 1] = step
        elseif finished and finished[space.name] then
            local base = workspace_root()
            local own = fs.realpath(fs.join(base, repo_name(base, root), space.name))
            local there = fs.realpath(space.path)
            if own ~= nil and own == there then
                step.kind = there == here and Step.KEEP or Step.DONE
                step.note = "it is the workspace dev runs in"
                steps[#steps + 1] = step
            end
        end
    end
    for _, step in ipairs(steps) do
        ordered[#ordered + 1] = step
    end
    return ordered
end

local function workspace_line(label, step, opts)
    if step.kind == Step.GONE then
        return string.format(
            "%s %s %s. Its folder %s is gone.",
            opts.verb,
            label,
            step.name,
            step.path
        )
    end
    return string.format("%s %s %s. Its card is done.", opts.verb, label, step.name)
end

local function prune_workspaces(ctx, steps, opts)
    local label = opts.backend == vcs.JJ and "workspace" or "worktree"
    local past = opts.backend == vcs.JJ and "Forgot" or "Removed"
    local future = opts.backend == vcs.JJ and "Would forget" or "Would remove"
    local pruned, kept, failure = 0, 0, nil
    local freed = {}
    local gone = {}
    for _, step in ipairs(steps) do
        if step.kind == Step.GONE then
            gone[step.path] = true
        end
    end
    for _, step in ipairs(steps) do
        local ok, message, purged, why
        if step.kind == Step.KEEP then
            ok, why = false, { reason = Refusal.KEPT, detail = step.note }
        elseif opts.dry then
            ok = true
            if step.kind == Step.DONE and fs.is_link(step.path) then
                ok, why = false, { reason = Refusal.LINK, path = step.path }
            elseif step.kind == Step.DONE then
                ok, why = M.__clean(opts.backend, step.path)
                if ok and opts.backend == vcs.GIT then
                    why = prune_blocker(
                        ctx.root,
                        { step.path, fs.realpath(step.path) },
                        { gone = gone }
                    )
                    ok = why == nil
                end
            end
        else
            local result = M.remove(ctx.root, step.name, {
                missing = step.kind == Step.GONE and step.path or nil,
                show = function(argv)
                    verb.show(ctx, argv)
                end,
            })
            ok, message, purged, why = result.ok, result.message, result.purged, result
            failure = failure or result.code
        end
        if ok then
            pruned = pruned + 1
            if opts.dry then
                freed[#freed + 1] = step.name
            end
            local line = workspace_line(label, step, { verb = opts.dry and future or past })
            if step.kind == Step.DONE and not opts.dry then
                line = line .. " " .. message
            end
            verb.say(line)
            for _, purge_line in ipairs(purged or {}) do
                verb.say(purge_line)
            end
        else
            kept = kept + 1
            verb.say(string.format("Kept %s %s. %s", label, step.name, M.describe(why)))
        end
    end
    return pruned, kept, failure, freed
end

local function unheld_heads(heads, freed)
    local held = "working_copies()"
    for _, name in ipairs(freed) do
        held = held .. ' ~ "' .. name:gsub('[\\"]', "\\%0") .. '"@'
    end
    return heads .. " ~ (" .. held .. ")" .. HELD_BY_REF
end

local function jj_heads(root, revset)
    local found = {}
    for _, line in ipairs(jj_lines(root, "log", "-r", revset, "--no-graph", "-T", HEAD_TEMPLATE)) do
        local id, description = line:match("^(%x+)\t?(.*)$")
        if id then
            found[#found + 1] = { id = id, description = description }
        end
    end
    return found
end

local function head_text(head)
    local text = head.id:sub(1, SHORT_ID)
    if head.description ~= "" then
        text = text .. " (" .. head.description .. ")"
    end
    return text
end

local function abandon_heads(ctx, heads, opts)
    local dry = opts.dry
    if #heads == 0 then
        return 0
    end
    if not dry then
        local argv = vcs.with(vcs.base(ctx.root, vcs.JJ), "abandon")
        for _, head in ipairs(heads) do
            argv[#argv + 1] = head.id
        end
        verb.show(ctx, argv)
        local code = dev_os.run(argv) or 1
        if code ~= 0 then
            verb.say(sentence("Left the empty heads alone. The jj abandon command exited " .. code))
            return 0, code
        end
    end
    for _, head in ipairs(heads) do
        verb.say(
            sentence((dry and "Would abandon" or "Abandoned") .. " empty head " .. head_text(head))
        )
    end
    return #heads
end

local function list_strays(root, freed)
    local left = 0
    for _, head in ipairs(jj_heads(root, unheld_heads(STRAY_HEADS, freed))) do
        verb.say(sentence("Left non-empty head " .. head_text(head) .. " alone. Nothing holds it"))
        left = left + 1
    end
    for _, name in
        ipairs(jj_lines(root, "bookmark", "list", "-r", STALE_BOOKMARKS, "-T", BOOKMARK_TEMPLATE))
    do
        verb.say(sentence("Left bookmark " .. name .. " alone. It is not on trunk"))
        left = left + 1
    end
    return left
end

local function finished_cards(root)
    local finished, why = cmd_board.finished(root)
    if not finished then
        verb.say("Skipped the card test. " .. sentence(why))
    end
    return finished
end

---Forget the finished workspaces of the current project and abandon its empty heads.
---
---A jj workspace or git worktree is pruned when its folder is gone, or when
---its name is the short id of a done card on the project's board and its
---folder sits at the path `ws new` makes. A project with no readable board
---skips the card test and says so.
---
---The default workspace, the main worktree, the workspace dev runs in and any
---folder with changes not in a commit are never pruned. A jj project also
---abandons the empty heads that nothing holds and lists the rest.
---
---`--dry-run` prints the plan and removes nothing. Each action is one line and
---the last line counts them.
---@param ctx dev.Ctx the verb's context
---@return integer code the exit code
M.handlers["ws prune"] = function(ctx)
    local dry = false
    for i, arg in ipairs(ctx.args) do
        if arg == "--dry-run" then
            dry = true
            table.remove(ctx.args, i)
            break
        end
    end
    verb.no_args(ctx)

    local backend = vcs.backend(ctx.root)
    if backend ~= vcs.JJ and backend ~= vcs.GIT then
        verb.die(ctx.root .. " is not a jj or git project.")
    end

    local found = backend == vcs.JJ and jj_workspaces(ctx.root) or git_worktrees(ctx.root)
    local steps = plan_workspaces(ctx.root, found, finished_cards(ctx.root))
    local pruned, left, failure, freed =
        prune_workspaces(ctx, steps, { backend = backend, dry = dry })

    local abandoned = 0
    if backend == vcs.JJ then
        local code
        local empty = jj_heads(ctx.root, unheld_heads(EMPTY_HEADS, freed))
        abandoned, code = abandon_heads(ctx, empty, { dry = dry })
        failure = failure or code
        left = left + list_strays(ctx.root, freed)
    else
        verb.say("Git keeps no empty heads, so only worktrees are pruned.")
    end

    verb.say(
        string.format(
            "%s %s and %s. Left %s alone.",
            dry and "Would prune" or "Pruned",
            counted(pruned, backend == vcs.JJ and "workspace" or "worktree"),
            counted(abandoned, "head"),
            counted(left, "item")
        )
    )
    return failure or 0
end

return M
