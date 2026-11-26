local cmd_board = require("@dev/cmd/board")
local dev_os = require("@dev/os")
local forge = require("@dev/forge")
local fs = require("@dev/fs")
local stack = require("@dev/stack")
local dev_text = require("@dev/text")
local vcs = require("@dev/vcs")
local dev_command = require("@dev/command")

---@class dev.cmd.ws
---@field Refusal table<string, dev.cmd.ws.Refusal> the reasons a removal stops
local M = {}

---@class dev.cmd.ws.rm.Opts
---@field forgotten boolean? whether a folder jj no longer lists may go to the trash

---@class dev.cmd.ws.prune.Opts
---@field dry_run boolean? whether to print the plan and remove nothing

local EMPTY_HEADS = "heads(mutable()) & empty()"
local IGNORE_WORKING_COPY = "--ignore-working-copy"
local STRAY_HEADS = "heads(mutable()) ~ empty()"
local HELD_BY_REF = " ~ bookmarks() ~ remote_bookmarks() ~ tags()"
local STALE_BOOKMARKS = "bookmarks() ~ ::trunk()"
local HEAD_TEMPLATE = 'commit_id ++ "\\t" ++ description.first_line() ++ "\\n"'
local BOOKMARK_TEMPLATE = 'if(remote, "", name ++ "\\n")'
local SHORT_ID = 12
local MAX_TITLE_MATCHES = 5
local MAX_LANDED_ROUNDS = 20
local STAMP_FORMAT = "!%Y%m%dT%H%M%SZ"
local TRASH_DIR = ".trash"
local ADOPT_PARENTS = "coalesce(@ & ::trunk(), @-)"

---@enum dev.cmd.ws.Step
local Step = { GONE = "gone", DONE = "done", KEEP = "keep" }

---@enum dev.cmd.ws.Leave
local Leave = { ELSEWHERE = "elsewhere" }

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
    ADOPTED = "adopted",
    EXISTS = "exists",
}
M.Refusal = Refusal

---@class dev.cmd.ws.Reason
---@field reason dev.cmd.ws.Refusal why the workspace stayed
---@field path string? the folder the reason is about
---@field name string? the workspace's name
---@field base string? the central workspaces root, for an outside folder
---@field command string? the vcs command that failed
---@field output string? the first line the failed command printed
---@field code integer? the exit code of a failed jj or git, which dev passes on as its own
---@field detail string? the line, error or exit status the reason carries
---@field stayed string? the folder a failed command left behind, with `detail` what to know of it

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
        if why.output then
            text = text .. ": " .. why.output
        end
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
    [Refusal.ADOPTED] = function(why)
        return why.path .. " is already under " .. why.base
    end,
    [Refusal.EXISTS] = function(why)
        return why.path .. " already exists"
    end,
}

---Write what stopped a workspace removal as sentences.
---@param why dev.cmd.ws.Reason the refusal, a `RemoveResult` included
---@return string text the full sentences a person reads
function M.describe(why)
    return sentence(DESCRIPTIONS[why.reason](why))
end

local function workspace_root()
    local env = dev_os.getenv("DEV_WS_ROOT")
    if env and env ~= "" then
        return env
    end
    return (dev_os.getenv("HOME") or "") .. "/.local/share/workspaces"
end

local function repo_name(base, root)
    local inside = root:match("^" .. base:gsub("%p", "%%%0") .. "/([^/]+)")
    return inside or fs.basename(vcs.main_root(root, vcs.backend(root)))
end

local function folder_name(ctx, name)
    if name == "" or name:find("/", 1, true) or name == "." or name == ".." then
        dev_command.usage_error(ctx, "NAME is one folder name, got " .. name)
    end
    return name
end

---Drop one trailing period from a reason so a sentence can quote it.
---@param reason string the reason a step failed
---@return string reason the reason with no trailing period
local function quoted_reason(reason)
    return (reason:gsub("%.$", ""))
end

local function remote_trunk(root, remote)
    local ref, err = vcs.remote_trunk(root, remote)
    if ref == nil then
        return nil,
            string.format('Could not name the trunk of the remote: "%s".', quoted_reason(err))
    end
    return ref
end

local function fetch_trunk(root, show)
    local backend = vcs.backend(root)
    if backend ~= vcs.JJ and backend ~= vcs.GIT then
        return nil
    end
    local found, why = forge.resolve(root)
    if not found then
        return string.format(
            'The trunk cannot be compared: "%s".',
            quoted_reason(dev_command.vcs_sentence(why, root))
        )
    end
    local argv = vcs.base(root, backend, { quiet = true })
    if backend == vcs.JJ then
        argv = vcs.with(argv, IGNORE_WORKING_COPY, "git", "fetch", "--remote", found.remote)
    else
        argv = vcs.with(argv, "fetch", found.remote)
    end
    show(argv)
    local out, code = dev_os.capture(argv, { stderr = "stdout" })
    if code ~= 0 then
        return sentence(
            string.format("the fetch from %s failed: %s", found.remote, (out:gsub("\n$", "")))
        )
    end
    if backend == vcs.GIT then
        local start, err = remote_trunk(root, found.remote)
        if start == nil then
            return err
        end
        return nil, start
    end
    return nil
end

---@class dev.cmd.ws.Record
---@field path string the worktree folder
---@field locked boolean whether git marks the worktree locked
---@field prunable boolean whether git marks the worktree prunable

---Read the records of `git worktree list --porcelain` output.
---@param out string the porcelain output
---@return dev.cmd.ws.Record[] records one per worktree block that names a folder
local function worktree_records(out)
    local records = {}
    for block in (out .. "\n"):gmatch("(.-)\n\n") do
        local path = block:match("^worktree ([^\n]+)")
        if path then
            records[#records + 1] = {
                path = path,
                locked = block:find("\nlocked") ~= nil,
                prunable = block:find("\nprunable") ~= nil,
            }
        end
    end
    return records
end

---Find the git folder a jj project is colocated with.
---@param root string the folder jj runs in
---@return string? dir nil when the project is not colocated with git
local function colocated_git_dir(root)
    local ask = vcs.with(vcs.base(root, vcs.JJ), "git", "root")
    local dir, code = dev_os.capture(ask, { stderr = "null" })
    dir = dir:gsub("%s+$", "")
    if code ~= 0 or not dir:find("/%.git$") then
        return nil
    end
    return dir
end

---Prune the stale git worktree record of a workspace path about to be made again.
---
---The prune drops every prunable record, so another gone record refuses it.
---@param root string the folder jj runs in
---@param path string the workspace folder about to be made
---@param show fun(argv: string[])? nil when unset, called with the command before it runs
---@return string? failure nil when nothing stopped it, else a sentence
local function drop_own_record(root, path, show)
    local dir = colocated_git_dir(root)
    if dir == nil then
        return nil
    end
    local list = { "git", "--git-dir", dir, "worktree", "list", "--porcelain" }
    local out, code = dev_os.capture(list, { stderr = "null" })
    if code ~= 0 then
        return nil
    end
    local mine, other = false, nil
    for _, record in ipairs(worktree_records(out)) do
        if record.prunable and not record.locked then
            if record.path == path then
                mine = true
            else
                other = other or record.path
            end
        end
    end
    if not mine then
        return nil
    end
    if other then
        return M.describe({ reason = Refusal.PRUNE_DROPS, path = other })
    end
    local argv = { "git", "--git-dir", dir, "worktree", "prune" }
    if show then
        show(argv)
    end
    if (dev_os.run(argv) or 1) ~= 0 then
        return sentence("git worktree prune failed")
    end
    return nil
end

---@class dev.cmd.ws.plan.Opts
---@field start string? nil when unset, the git start point of the worktree
---@field rev string? nil when unset, the jj revision the workspace starts on, else trunk

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
            opts.rev or "trunk()",
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

---Build the sentence that says a folder could not be made.
---@param folder string the folder that failed
---@param reason string what mkdir said
---@return string sentence the message
local function mkdir_failure(folder, reason)
    return string.format(
        'Could not make the folder %s. The mkdir command said: "%s".',
        folder,
        quoted_reason(reason)
    )
end

---Make a workspace for the current project under the central root.
---
---The path is `DEV_WS_ROOT`, else `~/.local/share/workspaces`, then the
---project's folder name, then NAME. A jj project gets a jj workspace on the
---trunk revision, a git project a worktree on a new branch NAME at the fetched
---trunk of the remote of record, and any other folder a plain directory. The
---path is printed on standard output.
---@param opts {} the parsed flags
---@param args { name: string } the parsed arguments
---@param ctx dev.Ctx the command's context
---@return integer code the exit code
function M.new(opts, args, ctx)
    local name = folder_name(ctx, args.name)
    local path, message, code = M.make(ctx.root, name, function(argv)
        dev_command.show(ctx, argv)
    end)
    if message then
        dev_command.die(message)
    end
    if code then
        return code
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

---@class dev.cmd.ws.make.Opts
---@field on string? nil when unset, the name of the workspace whose change the new one starts on

---Make the workspace NAME of the project at `root`, as `dev ws new` does, and print nothing.
---
---With `opts.on` the workspace starts on the change of that workspace instead of trunk: a jj
---workspace on a new change above its working copy, a git worktree on a new branch off its
---branch. The workspace records what it sits on, so `stack.refresh` can keep it current.
---@param root string absolute path of the project root
---@param name string the workspace folder's name
---@param show fun(argv: string[]) called with each command before it runs
---@param opts dev.cmd.ws.make.Opts? where the workspace starts
---@return string? path the workspace folder, nil when it was not made
---@return string? message the sentence that says why it was not made
---@return integer? code the exit code of the jj or git command that failed, with no message
function M.make(root, name, show, opts)
    local on = opts and opts.on
    local under_tip
    if on then
        local under_path = M.path(root, on)
        if not under_path then
            return nil, "Workspace " .. on .. " does not exist, so there is no change to start on."
        end
        if vcs.backend(root) == vcs.JJ then
            dev_os.capture(
                vcs.with(
                    vcs.base(under_path, vcs.JJ, { quiet = true }),
                    "workspace",
                    "update-stale"
                ),
                { stderr = "null" }
            )
            dev_os.capture(
                vcs.with(
                    vcs.base(under_path, vcs.JJ, { quiet = true }),
                    "log",
                    "-r",
                    "@",
                    "--no-graph",
                    "-T",
                    "''"
                ),
                { stderr = "null" }
            )
        end
        if vcs.backend(root) == vcs.GIT then
            under_tip = stack.tip(root, on)
            if not under_tip then
                return nil,
                    "The branch " .. on .. " does not exist, so there is nothing to start on."
            end
        end
    end
    local marked = false
    for _, marker in ipairs({ ".jj", ".git", ".dev" }) do
        marked = marked or fs.exists(root .. "/" .. marker)
    end
    if not marked then
        return nil, root .. " is not inside a project."
    end
    local base = workspace_root()
    local path = fs.join(base, repo_name(base, root), name)
    if fs.exists(path) then
        return nil, path .. " already exists."
    end
    local failure, start = fetch_trunk(root, show)
    if failure then
        return nil, failure
    end
    local made, why = fs.mkdir(fs.dirname(path), { parents = true })
    if not made then
        return nil, mkdir_failure(fs.dirname(path), why)
    end
    if vcs.backend(root) == vcs.JJ then
        local refresh = vcs.with(vcs.base(root, vcs.JJ), "workspace", "update-stale")
        show(refresh)
        local refreshed = dev_os.run(refresh) or 1
        if refreshed ~= 0 then
            return nil, nil, refreshed
        end
        local stuck = drop_own_record(root, path, show)
        if stuck then
            return nil, stuck
        end
    end
    local rev
    if on then
        rev = string.format('"%s"@', (on:gsub('[\\"]', "\\%0")))
        start = on
    end
    local argv = plan(root, name, path, { start = start, rev = rev })
    if argv == nil then
        made, why = fs.mkdir(path)
        if not made then
            return nil, mkdir_failure(path, why)
        end
    else
        show(argv)
        local code = dev_os.run(argv) or 1
        if code ~= 0 then
            return nil, nil, code
        end
    end
    if on then
        stack.write(path, { on = on, tip = under_tip })
    end
    return path
end

---@class dev.cmd.ws.clean.Opts
---@field refresh boolean? false when unset, true to update a stale jj workspace before the check
---@field stale_ok boolean? false when unset, true to read a stale jj workspace without updating it
---@field described_ok boolean? false when unset, true to count a described working-copy commit as committed

---Check that a workspace folder holds nothing outside a commit.
---
---A jj workspace whose working-copy commit is already on trunk holds nothing outside a commit.
---With `described_ok`, a working-copy commit that carries a description counts as committed too.
---@private
---@param backend dev.vcs.Backend? the backend of the workspace folder
---@param path string the workspace folder
---@param opts dev.cmd.ws.clean.Opts? whether to refresh a stale workspace first or read it as it is
---@return boolean clean whether the folder holds nothing outside a commit
---@return dev.cmd.ws.Reason? why what was found or why it could not be read
function M.__clean(backend, path, opts)
    if backend == nil then
        return true
    end
    local argv, retry
    if backend == vcs.JJ then
        local base = vcs.base(path, backend, { quiet = true })
        if opts and opts.refresh then
            local text, status =
                dev_os.capture(vcs.with(base, "workspace", "update-stale"), { stderr = "stdout" })
            if status ~= 0 then
                return false,
                    { reason = Refusal.UNREADABLE, path = path, detail = first_line(text) }
            end
        end
        local template = 'if(empty, "", "changes")'
        if opts and opts.described_ok then
            template = 'if(empty || description != "", "", "changes")'
        end
        local log = { "log", "-r", "@ ~ ::trunk()", "--no-graph", "-T", template }
        argv = vcs.with(base, table.unpack(log))
        if opts and opts.stale_ok then
            retry = vcs.with(base, "--ignore-working-copy", table.unpack(log))
        end
    else
        argv = vcs.with(vcs.base(path, backend), "status", "--porcelain")
    end
    local out, code = dev_os.capture(argv, { stderr = "stdout" })
    if code ~= 0 and retry and out:find("stale", 1, true) then
        out, code = dev_os.capture(retry, { stderr = "stdout" })
    end
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
---@param opts {} the parsed flags
---@param args {} the parsed arguments
---@param ctx dev.Ctx the command's context
---@return integer code the exit code
function M.ls(opts, args, ctx)
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
    local found
    if fs.is_dir("/proc/self") then
        found = M.__processes_proc(dir)
    else
        found = M.__processes_lsof(dir)
    end
    local kept = {}
    for _, process in ipairs(found) do
        if process.command ~= "ssh" then
            kept[#kept + 1] = process
        end
    end
    return kept
end

---@class dev.cmd.ws.remove.Opts
---@field inside boolean? false when unset, skips only the refusal of the workspace dev runs in and
---   moves a jj workspace's `@` off a change already on trunk
---@field forgotten boolean? false when unset, removes a jj folder that jj does not list and refuses
---   any other
---@field show fun(argv: string[])? nil when unset, called with the command before it runs
---@field warn fun(line: string)? nil when unset, called with a line for each process inside the
---   folder before it moves
---@field missing string? nil when unset, the recorded folder that is already gone
---@field stray boolean? false when unset, refuses a plain file as not a workspace and otherwise
---   moves it to the trash

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
    local dir = colocated_git_dir(root)
    if dir == nil then
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
        argv =
            vcs.with(vcs.base(root, vcs.JJ), "--ignore-working-copy", "workspace", "forget", name)
    elseif opts.backend == vcs.GIT and opts.moved then
        argv = vcs.with(vcs.base(root, vcs.GIT), "worktree", "prune")
    elseif opts.backend == vcs.GIT then
        argv = vcs.with(vcs.base(root, vcs.GIT), "worktree", "remove", opts.path)
    end
    if argv ~= nil then
        if opts.show then
            opts.show(argv)
        end
        local out, code = dev_os.capture(argv, { stderr = "stdout" })
        if code ~= 0 then
            return false,
                {
                    reason = Refusal.COMMAND_FAILED,
                    command = argv[1],
                    code = code or 1,
                    path = opts.path,
                    output = (out or ""):match("Error: [^\n]+") or first_line(out or ""),
                }
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

local function listed_folder(root, name, real_base)
    if vcs.backend(root) ~= vcs.JJ or real_base == nil then
        return nil
    end
    local argv = vcs.with(
        vcs.base(root, vcs.JJ, { quiet = true }),
        "--ignore-working-copy",
        "workspace",
        "root",
        "--name",
        name
    )
    local out, code = dev_os.capture(argv, { stderr = "null" })
    if code ~= 0 then
        return nil
    end
    local listed = out:gsub("\n$", "")
    local real = fs.realpath(listed)
    if real and fs.is_dir(real) and fs.dirname(fs.dirname(real)) == real_base then
        return listed
    end
    return nil
end

---Find the folder of the workspace NAME of the project at `root`.
---@param root string absolute path of the project root
---@param name string the workspace folder's name
---@return string? path the folder, nil when the project has no such workspace
function M.path(root, name)
    local base = workspace_root()
    local path = fs.join(base, repo_name(base, root), name)
    if fs.is_dir(path) then
        return path
    end
    return listed_folder(root, name, fs.realpath(base))
end

---Name what a workspace holds that has not landed.
---
---A jj workspace holds its non-empty commits above trunk, its working copy included. A git
---worktree holds the commits of its branch that no other branch or remote branch reaches, and a
---line for the files its status lists. An empty list means the workspace holds no work.
---@param path string the workspace folder
---@return string[]? work one line per commit or change, nil when the workspace cannot be read
---@return string? why what stopped the read
function M.work(path)
    local backend = vcs.backend(path)
    local work = {}
    if backend == vcs.JJ then
        local base = vcs.base(path, backend, { quiet = true })
        local text, status =
            dev_os.capture(vcs.with(base, "workspace", "update-stale"), { stderr = "stdout" })
        if status ~= 0 then
            return nil, first_line(text) or "jj could not refresh the workspace"
        end
        local argv = vcs.with(
            base,
            "log",
            "-r",
            "::@ ~ ::trunk() ~ empty()",
            "--no-graph",
            "-T",
            'commit_id.short(12) ++ " " ++ description.first_line() ++ "\\n"'
        )
        local out, code = dev_os.capture(argv, { stderr = "stdout" })
        if code ~= 0 then
            return nil, first_line(out) or "jj could not list the commits"
        end
        for line in out:gmatch("[^\n]+") do
            work[#work + 1] = line
        end
        return work
    end
    if backend ~= vcs.GIT then
        return work
    end
    local base = vcs.base(path, backend)
    local status_out, status_code =
        dev_os.capture(vcs.with(base, "status", "--porcelain"), { stderr = "stdout" })
    if status_code ~= 0 then
        return nil, first_line(status_out) or "git could not read the status"
    end
    local log = vcs.with(base, "log", "--format=%h %s", "HEAD", "--not")
    local found = forge.resolve(path)
    local remote_ref = vcs.remote_trunk(path, found and found.remote or "origin")
    for _, ref in ipairs({ "refs/heads/master", "refs/heads/main", remote_ref }) do
        local _, known = dev_os.capture(
            vcs.with(base, "rev-parse", "--verify", "--quiet", ref .. "^{commit}"),
            { stderr = "null" }
        )
        if known == 0 then
            log = vcs.with(log, ref)
        end
    end
    local out, code = dev_os.capture(log, { stderr = "stdout" })
    if code ~= 0 then
        return nil, first_line(out) or "git could not list the commits"
    end
    for line in out:gmatch("[^\n]+") do
        work[#work + 1] = line
    end
    if status_out ~= "" then
        work[#work + 1] = "uncommitted changes"
    end
    return work
end

local function leave_landed(path)
    local base = vcs.base(path, vcs.JJ, { quiet = true })
    local landed =
        vcs.with(base, "log", "-r", "(@ & ::trunk()) ~ empty()", "--no-graph", "-T", '"landed"')
    local out, code = dev_os.capture(landed, { stderr = "null" })
    if code == 0 and out ~= "" then
        dev_os.capture(vcs.with(base, "new", "trunk()"), { stderr = "null" })
    end
end

---Read the working copy of a jj workspace whose folder is gone.
---@param root string the folder jj runs in
---@param name string the workspace's name
---@param path string the missing folder
---@return boolean held whether the working copy holds changes, or could not be read
---@return dev.cmd.ws.Reason? why the refusal, set when held
local function unsaved_missing(root, name, path)
    local escaped = name:gsub('[\\"]', "\\%0")
    local argv = vcs.with(
        vcs.base(root, vcs.JJ, { quiet = true }),
        "--ignore-working-copy",
        "log",
        "-r",
        `"{escaped}"@ ~ ::trunk()`,
        "--no-graph",
        "-T",
        'if(empty || description != "", "", "changes")'
    )
    local out, code = dev_os.capture(argv, { stderr = "stdout" })
    if code ~= 0 then
        return true, { reason = Refusal.UNREADABLE, path = path, detail = first_line(out) }
    end
    if out ~= "" then
        return true, { reason = Refusal.DIRTY, path = path }
    end
    return false
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
    if backend == vcs.JJ then
        local held, why = unsaved_missing(root, name, opts.missing)
        if held then
            return refused(why)
        end
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
                purged[#purged + 1] = string.format(
                    'Could not purge %s. The rm command said: "%s".',
                    path,
                    quoted_reason(err)
                )
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
    for _, record in ipairs(worktree_records(out)) do
        local path = record.path
        if path == paths[1] or path == paths[2] then
            if record.locked then
                return { reason = Refusal.LOCKED, path = path }
            end
        elseif not (opts.gone and opts.gone[path]) and record.prunable and not record.locked then
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
    local moved, err, why_moved = fs.move(opts.path, target)
    if not moved then
        if why_moved == fs.Reason.EXISTS then
            err = "The trash path " .. target .. " already exists."
        end
        return refused({ reason = Refusal.FILESYSTEM, detail = err })
    end
    local ok, stopped = detach(anchor, name, {
        backend = opts.backend,
        path = opts.path,
        show = opts.show,
        moved = true,
    })
    if not ok then
        local back, back_err, why_back = fs.move(target, opts.path)
        if not back then
            if why_back == fs.Reason.EXISTS then
                back_err = opts.path .. " already exists again."
            end
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
    opts = opts or {}
    if opts.missing then
        return remove_missing(root, name, opts)
    end
    local base = workspace_root()
    local real_base = fs.realpath(base)
    local path = fs.join(base, repo_name(base, root), name)
    if not fs.is_dir(path) and not fs.is_file(path) then
        path = listed_folder(root, name, real_base) or path
    end
    local real = fs.realpath(path)
    local real_root = fs.realpath(root)
    local stray = opts.stray and fs.is_file(path)
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
    if opts.inside and backend == vcs.JJ and not gone and real == real_root then
        leave_landed(path)
    end
    if not gone then
        local clean, why = M.__clean(backend, path, { refresh = true, described_ok = true })
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
        trash = fs.join(base, TRASH_DIR, fs.basename(fs.dirname(path))),
        backend = not gone and backend or nil,
        path = path,
        show = opts.show,
    })
end

---Remove a workspace of the current project and its folder.
---
---Only a folder directly under ROOT/<repo>, or a jj workspace that jj lists
---directly under another folder of ROOT, is removed, never a link and never
---the workspace the command runs in. The folder moves to the trash, a jj
---workspace is forgotten, a git worktree record is pruned, and a folder with
---changes not in a commit is refused and left in place. A jj folder whose
---workspace jj no longer lists is refused unless `--forgotten` is given (it
---then moves to the trash). A plain file directly under ROOT/<repo> is moved.
---@param opts dev.cmd.ws.rm.Opts the parsed flags
---@param args { name: string } the parsed arguments
---@param ctx dev.Ctx the command's context
---@return integer code the exit code
function M.rm(opts, args, ctx)
    local name = folder_name(ctx, args.name)
    local result = M.remove(ctx.root, name, {
        forgotten = opts.forgotten == true,
        stray = true,
        show = function(argv)
            dev_command.show(ctx, argv)
        end,
        warn = dev_command.note,
    })
    if not result.ok then
        if result.code then
            dev_command.note(M.describe(result))
            return result.code
        end
        dev_command.die(M.describe(result))
    end
    print(result.message)
    for _, line in ipairs(result.purged) do
        dev_command.say(line)
    end
    return 0
end

local function jj_lines(root, ...)
    local argv = vcs.with(vcs.base(root, vcs.JJ, { quiet = true }), ...)
    local out, code = dev_os.capture(argv, { stderr = "null" })
    if code ~= 0 then
        dev_command.die(sentence("The jj command failed in " .. root))
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
        dev_command.die(sentence("git worktree list failed in " .. root))
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
    local leftover = {}
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
            else
                step.why = Leave.ELSEWHERE
                leftover[#leftover + 1] = step
            end
        elseif finished then
            leftover[#leftover + 1] = step
        end
    end
    for _, step in ipairs(steps) do
        ordered[#ordered + 1] = step
    end
    return ordered, leftover
end

local function leave_workspaces(label, leftover)
    for _, step in ipairs(leftover) do
        dev_command.say(
            sentence(
                "Left "
                    .. label
                    .. " "
                    .. step.name
                    .. " alone. "
                    .. (
                        step.why == Leave.ELSEWHERE and "Its folder is not where ws new puts it"
                        or "Its name is not the id of a done card"
                    )
            )
        )
    end
    return #leftover
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
            elseif step.kind == Step.GONE and opts.backend == vcs.JJ then
                local held
                held, why = unsaved_missing(ctx.root, step.name, step.path)
                ok = not held
            elseif step.kind == Step.DONE then
                ok, why =
                    M.__clean(opts.backend, step.path, { stale_ok = true, described_ok = true })
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
                    dev_command.show(ctx, argv)
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
            dev_command.say(line)
            for _, purge_line in ipairs(purged or {}) do
                dev_command.say(purge_line)
            end
        else
            kept = kept + 1
            dev_command.say(string.format("Kept %s %s. %s", label, step.name, M.describe(why)))
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
    local kind = opts.kind or "empty"
    if #heads == 0 then
        return 0
    end
    if not dry then
        local argv = vcs.with(vcs.base(ctx.root, vcs.JJ), "abandon")
        for _, head in ipairs(heads) do
            argv[#argv + 1] = head.id
        end
        dev_command.show(ctx, argv)
        local code = dev_os.run(argv) or 1
        if code ~= 0 then
            dev_command.say(
                sentence(`Left the {kind} heads alone. The jj abandon command exited {code}`)
            )
            return 0, code
        end
    end
    for _, head in ipairs(heads) do
        dev_command.say(
            sentence(`{dry and "Would abandon" or "Abandoned"} {kind} head {head_text(head)}`)
        )
    end
    return #heads
end

local function jj_capture(root, ...)
    local argv = vcs.with(vcs.base(root, vcs.JJ, { quiet = true }), ...)
    local out, code = dev_os.capture(argv, { stderr = "null" })
    if code ~= 0 then
        return nil
    end
    return out
end

local function quoted(text)
    local escaped = text:gsub('[\\"]', "\\%0")
    return `"{escaped}"`
end

local function same_title_on_trunk(root, head)
    local found = jj_capture(
        root,
        "log",
        "-r",
        `description(substring:{quoted(head.description)}) & ::trunk()`,
        "--no-graph",
        "-T",
        HEAD_TEMPLATE
    )
    local tried = 0
    for line in (found or ""):gmatch("[^\n]+") do
        local id, title = line:match("^(%x+)\t(.*)$")
        if id and title == head.description and tried < MAX_TITLE_MATCHES then
            tried += 1
            local diff = jj_capture(root, "interdiff", "--from", id, "--to", head.id, "--summary")
            if diff == "" then
                return true
            end
        end
    end
    return false
end

local function head_landed(root, head)
    local out = jj_capture(
        root,
        "log",
        "-r",
        head.id,
        "--no-graph",
        "-T",
        'change_id ++ "\\n" ++ description'
    )
    local change = out and out:match("^(%S+)\n")
    if change then
        local trailer = out:match("\nChange%-Id: (I%x+)")
        local revset = change
        if trailer then
            revset = `({change} | description(substring:"Change-Id: {trailer}"))`
        end
        local on_trunk = jj_capture(
            root,
            "log",
            "-r",
            `{revset} & ::trunk()`,
            "--no-graph",
            "-T",
            'commit_id ++ "\\n"'
        )
        if on_trunk and on_trunk:match("%x") then
            return true
        end
    end
    return head.description ~= "" and same_title_on_trunk(root, head)
end

local function landed_heads(root, freed)
    local landed = {}
    for _, head in ipairs(jj_heads(root, unheld_heads(STRAY_HEADS, freed))) do
        if head_landed(root, head) then
            landed[#landed + 1] = head
        end
    end
    return landed
end

local function abandon_landed_heads(ctx, freed, opts)
    local total, code, planned = 0, nil, {}
    for _ = 1, opts.dry and 1 or MAX_LANDED_ROUNDS do
        local landed = landed_heads(ctx.root, freed)
        if #landed == 0 then
            break
        end
        local count
        count, code = abandon_heads(ctx, landed, { dry = opts.dry, kind = "landed" })
        total += count
        for _, head in ipairs(landed) do
            planned[head.id] = true
        end
        if code then
            break
        end
    end
    return total, code, planned
end

local function list_strays(root, freed, planned)
    local left = 0
    for _, head in ipairs(jj_heads(root, unheld_heads(STRAY_HEADS, freed))) do
        if not planned[head.id] then
            dev_command.say(
                sentence("Left non-empty head " .. head_text(head) .. " alone. Nothing holds it")
            )
            left += 1
        end
    end
    for _, name in
        ipairs(jj_lines(root, "bookmark", "list", "-r", STALE_BOOKMARKS, "-T", BOOKMARK_TEMPLATE))
    do
        dev_command.say(sentence("Left bookmark " .. name .. " alone. It is not on trunk"))
        left += 1
    end
    return left
end

local function git_trunk_refs(root, trunk)
    local base = vcs.base(root, vcs.GIT, { quiet = true })
    local refs = { `refs/heads/{trunk}` }
    local out = dev_os.capture(
        vcs.with(base, "for-each-ref", "--format=%(refname)", "refs/remotes"),
        { stderr = "null" }
    )
    for ref in (out or ""):gmatch("[^\n]+") do
        if ref:match(`^refs/remotes/[^/]+/{trunk}$`) then
            refs[#refs + 1] = ref
        end
    end
    return refs
end

local function on_trunk(base, branch, refs)
    for _, ref in ipairs(refs) do
        local argv = vcs.with(base, "merge-base", "--is-ancestor", `refs/heads/{branch}`, ref)
        if dev_os.run(argv, { stdout = "null", stderr = "null" }) == 0 then
            return true
        end
    end
    return false
end

local function checked_out_branches(root)
    local base = vcs.base(root, vcs.GIT, { quiet = true })
    local out =
        dev_os.capture(vcs.with(base, "worktree", "list", "--porcelain"), { stderr = "null" })
    local held = {}
    for branch in ("\n" .. (out or "")):gmatch("\nbranch refs/heads/([^\n]+)") do
        held[branch] = true
    end
    return held
end

local function delete_merged_branches(ctx, opts)
    local trunk = vcs.trunk(vcs.branches(ctx.root, vcs.GIT))
    if not trunk then
        return 0, 0, nil
    end
    local refs = git_trunk_refs(ctx.root, trunk)
    local base = vcs.base(ctx.root, vcs.GIT, { quiet = true })
    local held = checked_out_branches(ctx.root)
    local deleted, unmerged, failure = 0, 0, nil
    for _, branch in ipairs(vcs.branches(ctx.root, vcs.GIT)) do
        if branch == trunk then
            continue
        end
        if held[branch] then
            dev_command.say(sentence(`Left branch {branch} alone. A worktree has it checked out`))
            unmerged += 1
            continue
        end
        if not on_trunk(base, branch, refs) then
            dev_command.say(sentence(`Left branch {branch} alone. It is not on trunk`))
            unmerged += 1
            continue
        end
        local ok, why = true, nil
        if not opts.dry then
            ok, why = vcs.delete_branch(ctx.root, vcs.GIT, branch)
        end
        if ok then
            dev_command.say(
                sentence(`{opts.dry and "Would delete" or "Deleted"} merged branch {branch}`)
            )
            deleted += 1
        else
            dev_command.say(
                sentence(`Left branch {branch} alone. {why or "Git did not delete it"}`)
            )
            unmerged += 1
            failure = failure or 1
        end
    end
    return deleted, unmerged, failure
end

local function finished_cards(root)
    local finished, why = cmd_board.finished(root)
    if not finished then
        dev_command.say(string.format("Skipped the card test. %s", sentence(why)))
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
---@param opts dev.cmd.ws.prune.Opts the parsed flags
---@param args {} the parsed arguments
---@param ctx dev.Ctx the command's context
---@return integer code the exit code
function M.prune(opts, args, ctx)
    local dry = opts.dry_run == true

    local backend = vcs.backend(ctx.root)
    if backend ~= vcs.JJ and backend ~= vcs.GIT then
        dev_command.die(ctx.root .. " is not a jj or git project.")
    end

    local found = backend == vcs.JJ and jj_workspaces(ctx.root) or git_worktrees(ctx.root)
    local steps, leftover = plan_workspaces(ctx.root, found, finished_cards(ctx.root))
    local pruned, left, failure, freed =
        prune_workspaces(ctx, steps, { backend = backend, dry = dry })
    left = left + leave_workspaces(backend == vcs.JJ and "workspace" or "worktree", leftover)

    local abandoned = 0
    if backend == vcs.JJ then
        local code, landed, planned
        local empty = jj_heads(ctx.root, unheld_heads(EMPTY_HEADS, freed))
        abandoned, code = abandon_heads(ctx, empty, { dry = dry })
        failure = failure or code
        landed, code, planned = abandon_landed_heads(ctx, freed, { dry = dry })
        abandoned += landed
        failure = failure or code
        left += list_strays(ctx.root, freed, planned)
    else
        dev_command.say("Git keeps no empty heads.")
        local deleted, unmerged, code = delete_merged_branches(ctx, { dry = dry })
        abandoned = deleted
        left += unmerged
        failure = failure or code
    end

    dev_command.say(
        string.format(
            "%s %s and %s. Left %s alone.",
            dry and "Would prune" or "Pruned",
            dev_text.count(pruned, backend == vcs.JJ and "workspace" or "worktree"),
            dev_text.count(abandoned, "head"),
            dev_text.count(left, "item")
        )
    )
    return failure or 0
end

---@class dev.cmd.ws.adopt.Opts
---@field show fun(argv: string[])? nil when unset, called with the command before it runs

local function run_shown(argv, opts)
    if opts.show then
        opts.show(argv)
    end
    return dev_os.run(argv) or 1
end

local function adopt_parents(path)
    local argv = vcs.with(
        vcs.base(path, vcs.JJ, { quiet = true }),
        "log",
        "-r",
        ADOPT_PARENTS,
        "--no-graph",
        "-T",
        'commit_id ++ "\\n"'
    )
    local out, code = dev_os.capture(argv, { stderr = "stdout" })
    if code ~= 0 or out == "" then
        return nil, { reason = Refusal.UNREADABLE, path = path, detail = first_line(out) }
    end
    local ids = {}
    for id in out:gmatch("%x+") do
        ids[#ids + 1] = id
    end
    return ids
end

local function adopt_jj(root, space, target, opts)
    local clean, why = M.__clean(vcs.JJ, space.path, { refresh = true })
    if not clean then
        return refused(why)
    end
    local parents, unread = adopt_parents(space.path)
    if parents == nil then
        return refused(unread)
    end
    local forget = vcs.with(vcs.base(root, vcs.JJ), "workspace", "forget", space.name)
    local code = run_shown(forget, opts)
    if code ~= 0 then
        return refused({ reason = Refusal.COMMAND_FAILED, command = forget[1], code = code })
    end
    local add = vcs.with(vcs.base(root, vcs.JJ), "workspace", "add", "--name", space.name)
    for _, id in ipairs(parents) do
        add = vcs.with(add, "-r", id)
    end
    code = run_shown(vcs.with(add, target), opts)
    if code ~= 0 then
        return refused({
            reason = Refusal.COMMAND_FAILED,
            command = add[1],
            code = code,
            stayed = space.path,
            detail = "workspace " .. space.name .. " is forgotten",
        })
    end
    return nil
end

---Move a workspace folder of the project at `root` into the central root.
---
---A jj workspace with nothing outside a commit is forgotten and added again at
---`<root>/<repo>/<name>` on the same parent commit, as jj cannot relocate one.
---Its old folder then moves to the trash. A git worktree moves with
---`git worktree move`. Nothing moves when the folder is not one of the
---project's workspaces, is already under the central root, is the folder dev
---runs in, would land on a path that exists, or holds a jj change outside a commit.
---@param root string absolute path of the project root dev runs in
---@param path string the workspace folder to adopt
---@param opts dev.cmd.ws.adopt.Opts? what to show
---@return dev.cmd.ws.RemoveResult result
function M.adopt(root, path, opts)
    opts = opts or {}
    local backend = vcs.backend(root)
    if backend ~= vcs.JJ and backend ~= vcs.GIT then
        return refused({ reason = Refusal.NO_VCS, path = root })
    end
    local base = workspace_root()
    local real = fs.realpath(path)
    if real == nil or not fs.is_dir(real) or fs.is_link(path) then
        return refused({ reason = Refusal.NOT_WORKSPACE, path = path })
    end
    local real_base = fs.realpath(base)
    if real_base and under(real, real_base) then
        return refused({ reason = Refusal.ADOPTED, path = path, base = base })
    end
    if real == fs.realpath(root) then
        return refused({ reason = Refusal.RUNNING_HERE, path = path })
    end
    local space
    for _, found in ipairs(backend == vcs.JJ and jj_workspaces(root) or git_worktrees(root)) do
        if fs.realpath(found.path) == real then
            space = { name = found.name, path = real }
        end
    end
    if space == nil then
        return refused({ reason = Refusal.NOT_WORKSPACE, path = path })
    end
    local repo = repo_name(base, root)
    local target = fs.join(base, repo, space.name)
    if fs.exists(target) then
        return refused({ reason = Refusal.EXISTS, path = target })
    end
    local made, why = fs.mkdir(fs.dirname(target), { parents = true })
    if not made then
        return refused({ reason = Refusal.FILESYSTEM, detail = why })
    end
    if backend == vcs.GIT then
        local move = vcs.with(vcs.base(root, vcs.GIT), "worktree", "move", real, target)
        local code = run_shown(move, opts)
        if code ~= 0 then
            return refused({ reason = Refusal.COMMAND_FAILED, command = move[1], code = code })
        end
        return { ok = true, message = "Moved " .. path .. " to " .. target .. ".", purged = {} }
    end
    local failed = adopt_jj(root, space, target, opts)
    if failed then
        return failed
    end
    local trashed = move_to_trash(root, space.name, {
        trash = fs.join(base, TRASH_DIR, repo),
        path = real,
    })
    if trashed.ok then
        trashed.message = "Adopted " .. space.name .. " at " .. target .. ". " .. trashed.message
    else
        trashed.detail = string.format(
            "workspace %s is now at %s and its old folder stays at %s: %s",
            space.name,
            target,
            real,
            trashed.detail
        )
    end
    return trashed
end

---Move a workspace folder of the current project into the central root.
---
---A clean jj workspace is forgotten and added again under ROOT/<repo> on the
---same parent commit, and its old folder goes to the trash. A git worktree
---moves with `git worktree move`. A folder that is not a workspace of this
---project, one already under the root, one with changes not in a commit, and
---a target that exists are refused and left in place.
---@param opts {} the parsed flags
---@param args { path: string } the parsed arguments
---@param ctx dev.Ctx the command's context
---@return integer code the exit code
function M.adopt_path(opts, args, ctx)
    local result = M.adopt(ctx.root, args.path, {
        show = function(argv)
            dev_command.show(ctx, argv)
        end,
    })
    if not result.ok then
        if result.code and not result.stayed then
            return result.code
        end
        dev_command.die(M.describe(result))
    end
    dev_command.say(result.message)
    for _, line in ipairs(result.purged) do
        dev_command.say(line)
    end
    return 0
end

return M
