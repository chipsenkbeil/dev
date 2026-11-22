local abandon = require("dev.cmd.abandon")
local board = require("dev.cmd.board")
local box = require("dev.cmd.box")
local ci = require("dev.cmd.ci")
local complete = require("dev.complete")
local config = require("dev.config")
local connect = require("dev.cmd.connect")
local follow = require("dev.cmd.follow")
local init = require("dev.cmd.init")
local land = require("dev.cmd.land")
local misc = require("dev.cmd.misc")
local pull = require("dev.cmd.pull")
local push = require("dev.cmd.push")
local sync = require("dev.cmd.sync")
local tools = require("dev.cmd.tools")
local types = require("dev.cmd.types")
local ws = require("dev.cmd.ws")
local dev_os = require("dev.os")
local fetch = require("dev.fetch")
local fs = require("dev.fs")
local help = require("dev.help")
local project = require("dev.project")
local registry = require("dev.registry")
local remote = require("dev.remote")
local root = require("dev.root")
local vcs = require("dev.vcs")
local verb = require("dev.verb")

local stderr = io.stderr
local INTERPRETER = arg and arg[-1]
local MAX_LEVEL = 2
local INTERRUPTED = dev_os.SIGNAL_EXIT_BASE + 2
local ROOT_REFUSAL = "As root, dev runs only `dev tools install` and `dev tools check`.\n"
local SHARE = project.share
local VCS_HANDLERS = {
    abandon = abandon.run,
    push = push.run,
    pull = pull.run,
    sync = sync.run,
    follow = follow.run,
    land = land.run,
}
local NOT_TAKEN = {
    push = function(arg)
        return arg:sub(1, 1) == "-" and arg ~= "--tag"
    end,
    pull = function()
        return true
    end,
    follow = function()
        return true
    end,
    sync = function(arg)
        return arg ~= "--check" and arg ~= "--yes" and arg ~= "-y"
    end,
}
local EXCLUSIVE = { sync = true }
local HIDDEN_HELPERS = {
    __verbs = complete.verbs,
    __subs = complete.subs,
    __flags = complete.flags,
    __args = complete.args,
    ["__topics check"] = complete.check_topics,
}

---@class dev.cli
local M = {}

local function level_of(value)
    if value == "" or value == "no" or value == "false" then
        return 0
    end
    if value:find("%D") then
        return 1
    end
    return math.min(tonumber(value), MAX_LEVEL)
end

local function enabled(value)
    return not (value == "" or value == "0" or value == "no" or value == "false")
end

---@class dev.cli.Parsed
---@field args string[] the arguments with the global flags removed
---@field after integer how many of them came after a `--`
---@field dashed boolean whether a `--` was typed, even with nothing after it
---@field remote boolean whether `--remote` or `DEV_REMOTE` asks for a remote run
---@field detach boolean whether `--detach` was given
---@field priority boolean whether `--priority` was given
---@field job_timeout string|nil the `--job-timeout` value, "" when the flag had none
---@field local_flag boolean whether `--local` was given
---@field env_local boolean whether `DEV_REMOTE` says 0, no or false
---@field conflict boolean whether `--local` and `--remote` were both given
---@field level integer the verbosity before the trace file is checked

local function parse(argv)
    local parsed = {
        args = {},
        after = 0,
        dashed = false,
        remote = enabled(os.getenv("DEV_REMOTE") or ""),
        detach = false,
        priority = false,
        conflict = false,
        local_flag = false,
        env_local = false,
    }
    local count, flag_remote, flag_local = 0, false, false
    local env = os.getenv("DEV_REMOTE") or ""
    parsed.env_local = env == "0" or env == "no" or env == "false"
    local awaiting = false
    for i, word in ipairs(argv) do
        local verbosity = registry.verbose_count(word)
        if awaiting and word:sub(1, 1) == "-" then
            awaiting = false
        end
        if awaiting then
            parsed.job_timeout = word
            awaiting = false
        elseif word == "--" then
            parsed.after = #argv - i
            parsed.dashed = true
            for j = i + 1, #argv do
                parsed.args[#parsed.args + 1] = argv[j]
            end
            break
        elseif verbosity then
            count = count + verbosity
        elseif word == "--remote" then
            parsed.remote = true
            flag_remote = true
        elseif word == "--local" then
            flag_local = true
        elseif word == "--detach" then
            parsed.detach = true
        elseif word == "--priority" then
            parsed.priority = true
        elseif word == "--job-timeout" then
            parsed.job_timeout = ""
            awaiting = true
        else
            parsed.args[#parsed.args + 1] = word
        end
    end
    parsed.conflict = flag_local and flag_remote
    parsed.local_flag = flag_local
    if flag_local then
        parsed.remote = false
    end
    parsed.level = level_of(count > 0 and tostring(count) or os.getenv("VERBOSE") or "")
    return parsed
end

local function default_is_remote(project_root)
    local setting = config.prefer_user(project_root, "remote.default")
    if setting ~= nil and setting ~= "remote" and setting ~= "local" then
        verb.die(
            'The `remote.default` setting must be "remote" or "local", not '
                .. tostring(setting)
                .. "."
        )
    end
    return setting ~= "local"
end

local function remote_default(project_root, words)
    if dev_os.getuid() == 0 or remote.machine_local(words) then
        return false
    end
    return default_is_remote(project_root) and remote.has_default_job(project_root, words)
end

local function runs_local(reg, row)
    local header = row and reg:header(row)
    return header ~= nil and (header.runs_local or header.fetch ~= nil or header.patch ~= nil)
end

local function fetch_spec(reg, row)
    local header = row and reg:header(row)
    return header and header.fetch
end

local function patch_spec(reg, row)
    local header = row and reg:header(row)
    return header and header.patch
end

local function fetches(parsed, project_root)
    if parsed.remote then
        return true
    end
    return not (parsed.local_flag or parsed.env_local or dev_os.getuid() == 0)
        and default_is_remote(project_root)
end

local function takes_positionals(reg, row)
    local header = row and reg:header(row)
    return header ~= nil and header.positional
end

local function refuse_agent_local(project_root, words)
    if (os.getenv("DEV_AGENT") or "") == "" then
        return
    end
    if remote.refuses_agent_local(project_root, words) then
        local command = table.concat(words, " ")
        stderr:write(
            "dev ",
            command,
            ": DEV_AGENT is set. Use `dev --remote ",
            command,
            "` instead, which runs it on ci.\n"
        )
        os.exit(2)
    end
end

---Agent roles that work in a workspace, never the primary checkout
local WORKSPACE_ROLES =
    { runner = true, implementer = true, planner = true, reviewer = true, verifier = true }

---Mutating verbs refused in the primary checkout, by verb name
local PRIMARY_GUARDED = {}
for _, name in ipairs({
    "install",
    "uninstall",
    "restow",
    "stow",
    "sync",
    "setup",
    "fmt",
    "init",
    "push",
    "pull",
    "follow",
    "land",
    "abandon",
    "clean",
    "purge",
    "skills",
    "tools install",
    "board land",
}) do
    PRIMARY_GUARDED[name] = true
end

---Mutating verbs the lead role never runs in the primary checkout, by verb name
local LEAD_GUARDED = {}
for _, name in ipairs({
    "land",
    "board land",
    "abandon",
    "clean",
    "purge",
    "fmt",
}) do
    LEAD_GUARDED[name] = true
end

local function refuse_agent_primary(project_root, words)
    local role = (os.getenv("DEV_AGENT") or ""):match("^[^/]*/([^/]*)")
    local guarded
    if role == "lead" then
        guarded = LEAD_GUARDED
    elseif role and WORKSPACE_ROLES[role] then
        guarded = PRIMARY_GUARDED
    else
        return
    end
    local command = table.concat(words, " ")
    if not (guarded[words[1]] or guarded[command]) then
        return
    end
    local backend = vcs.backend(project_root)
    if not backend then
        return
    end
    local here = fs.realpath(project_root)
    local main = fs.realpath(vcs.main_root(project_root, backend))
    if here and here == main then
        local who = guarded == LEAD_GUARDED and "lead role" or ("workspace role " .. role)
        stderr:write(
            "dev ",
            command,
            ": DEV_AGENT is the ",
            who,
            ", which never runs it in the primary checkout. Use `dev -C WS ",
            command,
            "` from your own workspace.\n"
        )
        os.exit(2)
    end
end

local function root_gate(args)
    if dev_os.getuid() ~= 0 then
        return
    end
    if not root.allowed(args) then
        stderr:write(ROOT_REFUSAL)
        os.exit(2)
    end
    if dev_os.name() ~= "Linux" then
        stderr:write("As root, dev runs only on Linux.\n")
        os.exit(2)
    end
end

local function exec_or_exit(argv, opts)
    dev_os.defaults.show = false
    local _, message = dev_os.exec(argv, opts)
    stderr:write("The command `", argv[1], "` could not run: ", message, ".\n")
    os.exit(dev_os.EXEC_FAILED)
end

local function apply_level(level)
    if level >= MAX_LEVEL then
        local trace = SHARE .. "/xtrace.bash"
        if fs.is_file(trace) then
            dev_os.defaults.env.BASH_ENV = trace
            dev_os.defaults.env.PS4 = project.PS4
        else
            stderr:write("The trace file ", trace, " is missing. Showing commands only.\n")
            level = 1
        end
    end
    if level >= 1 then
        dev_os.defaults.env.VERBOSE = tostring(level)
    end
    return level
end

local function split_vars(args)
    local plain, vars = {}, {}
    for _, word in ipairs(args) do
        local key, value = word:match("^(%u[^=]*)=(.*)$")
        if key then
            vars[key] = value
        else
            plain[#plain + 1] = word
        end
    end
    return plain, vars
end

local function prepare(ctx)
    ctx.verbose = apply_level(ctx.verbose)
    if ctx.verbose == 0 then
        dev_os.defaults.unset = { "VERBOSE" }
    end
end

local function run_script(row, ctx, rest)
    local relative = row.script:sub(#ctx.root + 2)
    prepare(ctx)
    if ctx.verbose >= 1 then
        stderr:write("+ ", relative, #rest > 0 and " " or "", table.concat(rest, " "), "\n")
    end
    if row.lang == "sh" then
        local argv = { row.script }
        for _, word in ipairs(rest) do
            argv[#argv + 1] = word
        end
        exec_or_exit(argv)
    end
    package.path = ctx.root .. "/.dev/lua/?.lua;" .. package.path
    dev_os.defaults.show = ctx.verbose >= 1
    local code = verb.run(row.script, ctx)
    os.exit(code)
end

local function builtin_handler(row)
    if row and row.kind == "builtin" and not row.noun and row.handler == "lua" then
        return types.handlers[row.name]
            or VCS_HANDLERS[row.name]
            or misc[row.name]
            or tools.handlers[row.name]
            or box.handlers[row.name]
            or ci.handlers[row.name]
            or board.handlers[row.name]
            or connect.handlers[row.name]
            or init.handlers[row.name]
            or ws.handlers[row.name]
    end
    return nil
end

local function tail(list, from)
    local out = {}
    for i = from, #list do
        out[#out + 1] = list[i]
    end
    return out
end

local UNDECLARED_HINT =
    ". Pass it after -- to reach the script, or add it to the script's # flags: line."

local function is_help(word)
    return word == "-h" or word == "--help"
end

local function help_flag(rest, after)
    for i = 1, #rest - after do
        if is_help(rest[i]) then
            return rest[i]
        end
    end
end

local function noun_usage_error(reg, words, message)
    stderr:write("dev ", table.concat(words, " "), ": ", message, "\n\n")
    help.noun(reg, words, { stderr = true })
    os.exit(2)
end

local function hidden_helper(args, project_root, reg)
    local name = args[1]
    if name == "__topics" then
        local sub = args[2]
        if sub ~= "check" then
            local message = sub and ("unknown subcommand " .. sub) or "needs a subcommand"
            stderr:write("dev __topics: ", message, "\n")
            os.exit(2)
        end
        name = "__topics check"
    end
    local run = HIDDEN_HELPERS[name]
    if run then
        local from = name == "__topics check" and 3 or 2
        local ctx = { name = name, words = { name }, root = project_root, args = tail(args, from) }
        os.exit(run(ctx, reg))
    end
end

local function refuse_untaken(ctx, reg)
    local not_taken = NOT_TAKEN[ctx.name]
    if not not_taken then
        return
    end
    for _, arg in ipairs(ctx.args) do
        if not_taken(arg) then
            help.bad_argument(ctx, reg, arg)
        end
    end
    local exclusive = EXCLUSIVE[ctx.name]
    if exclusive then
        local has_check, has_yes = false, false
        for _, arg in ipairs(ctx.args) do
            has_check = has_check or arg == "--check"
            has_yes = has_yes or arg == "--yes" or arg == "-y"
        end
        if has_check and has_yes then
            help.usage_error(ctx, reg, "sync takes --check or --yes, not both")
        end
    end
end

local function refuse_undeclared(reg, ctx, rest, after)
    local declared = {}
    for _, flag in ipairs(reg:flags(ctx.words)) do
        declared[flag] = true
    end
    for i = 1, #rest - after do
        local word = rest[i]
        local flag = word:match("^(%-%-?[^=]*)")
        if flag and word ~= "-" and not is_help(flag) and not declared[flag] then
            verb.usage_error(ctx, "Unknown flag " .. flag .. UNDECLARED_HINT)
        end
    end
end

local function run_as_root(parsed)
    local args = parsed.args
    local words = { args[1], args[2] }
    local rest = tail(args, 3)
    local ctx = {
        name = table.concat(words, " "),
        words = words,
        root = project.root(),
        args = rest,
        vars = {},
        verbose = parsed.level,
        interpreter = INTERPRETER,
    }
    if parsed.remote then
        os.exit(remote.run(ctx, words, tail(rest, math.max(1, #rest - parsed.after + 1)), {
            detach = parsed.detach,
            priority = parsed.priority,
            job_timeout = parsed.job_timeout,
        }))
    end
    prepare(ctx)
    os.exit(tools.handlers[ctx.name](ctx))
end

---Run `dev` with the command line and exit.
---
---Global flags, the root gate and the usage errors come first. A `.lua` verb
---runs in this process, a `.sh` verb replaces it, and a verb the registry does
---not know is a usage error.
---@param argv string[] the command line after `dev`
---@return nil
function M.main(argv)
    local parsed = parse(argv)
    if parsed.conflict then
        stderr:write("The flags `--local` and `--remote` cannot be used together.\n")
        os.exit(2)
    end
    if parsed.detach and not parsed.remote then
        stderr:write("The flag `--detach` needs `--remote`.\n")
        os.exit(2)
    end
    if parsed.priority and not parsed.remote then
        stderr:write("The flag `--priority` needs `--remote`.\n")
        os.exit(2)
    end
    if parsed.job_timeout and not parsed.remote then
        stderr:write("The flag `--job-timeout` needs `--remote`.\n")
        os.exit(2)
    end
    if parsed.job_timeout == "" then
        stderr:write("The flag `--job-timeout` needs a duration.\n")
        os.exit(2)
    end
    if parsed.local_flag then
        dev_os.setenv("DEV_LOCAL", "1")
    end
    root_gate(parsed.args)
    if dev_os.getuid() == 0 then
        run_as_root(parsed)
    end
    local on_remote_host = remote.is_remote_host()
    if on_remote_host then
        parsed.remote = false
    end
    local args = parsed.args
    local name = args[1] or "help"
    if is_help(name) then
        name = "help"
    end
    local project_root = project.root()
    local reg = registry.load(project_root)
    hidden_helper(args, project_root, reg)
    local words, rest = { name }, tail(args, 2)
    local row = reg:find(words)
    while row and row.noun do
        local first = rest[1]
        local sub
        if first and first ~= "help" and not first:find("^__") and not is_help(first) then
            words[#words + 1] = first
            sub = reg:find(words)
            words[#words] = nil
        end
        if not sub then
            if not first then
                noun_usage_error(reg, words, "needs a subcommand")
            end
            if first == "help" or help_flag(rest, parsed.after) then
                os.exit(help.noun(reg, words))
            end
            noun_usage_error(reg, words, "unknown subcommand " .. first)
        end
        words[#words + 1] = first
        row, rest = sub, tail(rest, 2)
    end
    local ctx = {
        name = table.concat(words, " "),
        words = words,
        root = project_root,
        args = rest,
        after = parsed.after,
        dashed = parsed.dashed,
        vars = {},
        verbose = parsed.level,
        interpreter = INTERPRETER,
    }
    local flag = name ~= "help" and help_flag(rest, parsed.after)
    local fetch_job = fetch_spec(reg, row)
    local patch_job = patch_spec(reg, row)
    if flag and (not parsed.remote or patch_job) then
        os.exit(help.verb(ctx, reg, { words = words, short = flag == "-h" }))
    end
    if name == "help" and not parsed.remote and not (row and row.script) then
        os.exit(help.run(ctx, reg))
    end
    if parsed.remote and not fetch_job and not patch_job then
        os.exit(remote.run(ctx, words, tail(rest, math.max(1, #rest - parsed.after + 1)), {
            detach = parsed.detach,
            priority = parsed.priority,
            job_timeout = parsed.job_timeout,
        }))
    end
    if
        not (parsed.local_flag or parsed.env_local or on_remote_host or runs_local(reg, row))
        and remote_default(project_root, words)
    then
        os.exit(remote.run(ctx, words, rest, { detach = false, priority = false }))
    end
    if not on_remote_host and not runs_local(reg, row) then
        refuse_agent_local(project_root, words)
    end
    if not on_remote_host then
        refuse_agent_primary(project_root, words)
    end
    if row and row.script then
        refuse_undeclared(reg, ctx, rest, parsed.after)
        if patch_job and not on_remote_host and fetches(parsed, project_root) then
            os.exit(fetch.apply(project_root, patch_job))
        end
        if fetch_job and not on_remote_host and fetches(parsed, project_root) then
            dev_os.setenv(fetch.ENV, fetch.pull(project_root, fetch_job))
        end
        if takes_positionals(reg, row) then
            ctx.args, ctx.vars = rest, {}
        else
            ctx.args, ctx.vars = split_vars(rest)
        end
        run_script(row, ctx, rest)
    end
    local handler = builtin_handler(row)
    if handler then
        refuse_untaken(ctx, reg)
        prepare(ctx)
        local code = handler(ctx, reg)
        os.exit(code)
    end
    help.usage_error(ctx, reg, "unknown verb " .. name)
end

---Run `fn`, mapping Lua's interrupt error to the exit status of a SIGINT.
---
---Any other error is raised again unchanged.
---@param fn fun(...): any the function to run
---@param ... any its arguments
---@return integer? code 130 when the user interrupted it, nil when it returned
function M.guard(fn, ...)
    local ok, err = xpcall(fn, function(message)
        if tostring(message):find("interrupted!", 1, true) then
            return INTERRUPTED
        end
        return message
    end, ...)
    dev_os.run_cleanups()
    if ok then
        return nil
    end
    if err == INTERRUPTED then
        return dev_os.interrupt_code()
    end
    error(err, 0)
end

return M
