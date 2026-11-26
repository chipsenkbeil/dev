local command = require("@dev/command")
local config = require("@dev/config")
local dev_os = require("@dev/os")
local fetch = require("@dev/fetch")
local fs = require("@dev/fs")
local help = require("@dev/help")
local log = require("@dev/log")
local project = require("@dev/project")
local registry = require("@dev/registry")
local remote = require("@dev/remote")
local root = require("@dev/root")
local spec_check = require("@dev/spec")
local stack = require("@dev/stack")
local vcs = require("@dev/vcs")
local version = require("@dev/version")

local stderr = dev_os.stderr
local ROOT_REFUSAL = "As root, dev runs only `dev tools install` and `dev tools check`.\n"

---@class dev.cli
local M = {}

local function default_is_remote(project_root)
    local setting = config.prefer_user(project_root, "remote.default")
    if setting ~= nil and setting ~= "remote" and setting ~= "local" then
        command.die(
            'The `remote.default` setting must be "remote" or "local", not '
                .. tostring(setting)
                .. "."
        )
    end
    return setting ~= "local"
end

local function require_min_version(project_root)
    local wanted = config.get(project_root, "dev.min_version")
    if wanted == nil then
        return
    end
    local current = version.current()
    local order, _, bad = version.compare(current, wanted)
    if order == nil then
        command.die("The `dev.min_version` setting must be MAJOR.MINOR.PATCH, not " .. bad .. ".")
    end
    if order < 0 then
        command.die(
            "This project needs dev " .. wanted .. " or newer, and this dev is " .. current .. "."
        )
    end
end

local function remote_default(project_root, words, never_remote)
    if dev_os.getuid() == 0 or never_remote then
        return false
    end
    return default_is_remote(project_root) and remote.has_default_job(project_root, words)
end

local function fetches(parsed, project_root)
    if parsed.remote then
        return true
    end
    return not (parsed.local_flag or parsed.env_local or dev_os.getuid() == 0)
        and default_is_remote(project_root)
end

local function refuse_agent_local(project_root, words, never_remote)
    if (dev_os.getenv("DEV_AGENT") or "") == "" then
        return
    end
    if remote.refuses_agent_local(project_root, words, never_remote) then
        local name = table.concat(words, " ")
        stderr:write(
            "dev ",
            name,
            ": DEV_AGENT is set. Use `dev --remote ",
            name,
            "` instead, which runs it on ci.\n"
        )
        dev_os.exit(2)
    end
end

---Mutating commands the lead role never runs in the primary checkout, by command name
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

local function repo_guarded(project_root)
    local names = config.get(project_root, "agent.primary_guarded")
    local listed = {}
    if names == nil then
        return listed
    end
    local malformed = "The `agent.primary_guarded` setting in "
        .. project_root
        .. "/.dev/config.toml must be a list of command names."
    if type(names) ~= "table" then
        command.die(malformed)
    end
    for _, name in ipairs(names) do
        if type(name) ~= "string" then
            command.die(malformed)
        end
        listed[name] = true
    end
    return listed
end

local function requires_workspace(requires)
    for _, word in ipairs(requires) do
        if word == "workspace" then
            return true
        end
    end
    return false
end

local function refuse_agent_primary(project_root, words, requires)
    local agent = dev_os.getenv("DEV_AGENT") or ""
    if agent == "" then
        return
    end
    local role = agent:match("^[^/]*/([^/]*)")
    local name = table.concat(words, " ")
    local guarded, who
    if role == "lead" then
        guarded = LEAD_GUARDED[words[1]] or LEAD_GUARDED[name]
        who = "lead role"
    elseif role and command.WORKSPACE_ROLES[role] then
        guarded = requires_workspace(requires)
        who = "workspace role " .. role
    end
    local listed = repo_guarded(project_root)
    if not (guarded or listed[words[1]] or listed[name]) then
        return
    end
    local backend = vcs.backend(project_root)
    if not backend then
        return
    end
    local here = fs.realpath(project_root)
    local main = fs.realpath(vcs.main_root(project_root, backend))
    if not (here and here == main) then
        return
    end
    local reason
    if guarded then
        reason = "DEV_AGENT is the " .. who .. ", which never runs it in the primary checkout."
    else
        reason = "the repo's `agent.primary_guarded` lists it, and DEV_AGENT never runs "
            .. "it in the primary checkout."
    end
    stderr:write(
        "dev ",
        name,
        ": ",
        reason,
        " Use `dev -C WS ",
        name,
        "` from your own workspace.\n"
    )
    dev_os.exit(2)
end

local function root_gate(args)
    if dev_os.getuid() ~= 0 then
        return
    end
    if not root.allowed(args) then
        stderr:write(ROOT_REFUSAL)
        dev_os.exit(2)
    end
    if dev_os.name() ~= "Linux" then
        stderr:write("As root, dev runs only on Linux.\n")
        dev_os.exit(2)
    end
end

local function exec_or_exit(argv, opts)
    dev_os.defaults.show = false
    local _, message = dev_os.exec(argv, opts)
    stderr:write("The command `", argv[1], "` could not run: ", message, ".\n")
    dev_os.exit(dev_os.EXEC_FAILED)
end

local function tail(list, from)
    local out = {}
    for i = from, #list do
        out[#out + 1] = list[i]
    end
    return out
end

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

local function parent_usage_error(reg, words, message)
    stderr:write("dev ", table.concat(words, " "), ": ", message, "\n\n")
    help.parent(reg, words, { stderr = true })
    dev_os.exit(2)
end

---The words after the command words as the command's parser reads them, with `--` back in place
---when words follow it.
local function with_dashes(rest, after)
    if after == 0 then
        return rest
    end
    local out = {}
    local split = #rest - after
    for i = 1, split do
        out[#out + 1] = rest[i]
    end
    out[#out + 1] = "--"
    for i = split + 1, #rest do
        out[#out + 1] = rest[i]
    end
    return out
end

---Give the stripped verbosity words back to a command that opted out of the globals or declares
---its own `-v`, `-q` or `--quiet`, and return the level that is left.
---@param spec dev.Spec? the spec of the resolved command
---@param parsed dev.globals the global flags, whose `args` get the words back
---@return integer level the verbosity after the retake
local function retake_verbosity(spec, parsed)
    local level = log.verbosity()
    if not spec or #parsed.stripped == 0 then
        return level
    end
    local owned = {}
    for _, flag in ipairs(spec.flags or {}) do
        owned["--" .. flag.name] = true
        if flag.short then
            owned["-" .. flag.short] = true
        end
    end
    local entries, indexes = {}, {}
    for index, entry in ipairs(parsed.stripped) do
        local own = owned[entry.word] or (entry.word:find("^%-v+$") ~= nil and owned["-v"])
        if spec.globals == false or own then
            entries[#entries + 1] = entry
            indexes[#indexes + 1] = index
        end
    end
    if #indexes == 0 then
        return level
    end
    level = log.retake(indexes)
    local back = {}
    for i = #entries, 1, -1 do
        table.insert(parsed.args, entries[i].at, entries[i].word)
        back[entries[i].at] = true
    end
    return level, back
end

---The words after the command path once the retaken words are back in `args`.
---
---A retaken word may sit inside the path (`dev board -q land`), so the path is the first
---`path_length` words that were not retaken, and every other word is a command word.
---@param args string[] the words with the retaken ones put back
---@param back table<integer, boolean>? the positions of the retaken words
---@param path_length integer how many words name the command
---@return string[] rest the words after the command path
local function words_after_path(args, back, path_length)
    local rest, seen = {}, 0
    for index, word in ipairs(args) do
        if seen < path_length and not (back and back[index]) then
            seen = seen + 1
        else
            rest[#rest + 1] = word
        end
    end
    return rest
end

local function prepare(ctx)
    dev_os.defaults.env.DEV_ROOT = ctx.root
    if ctx.verbose >= 1 then
        dev_os.defaults.env.VERBOSE = tostring(ctx.verbose)
    else
        dev_os.defaults.unset = { "VERBOSE" }
    end
end

local function flag_environment(spec, opts)
    local unset = dev_os.defaults.unset or {}
    for _, flag in ipairs(spec.flags or {}) do
        local value = opts[(flag.name:gsub("-", "_"))]
        local text
        if type(value) == "table" then
            text = table.concat(value, "\n")
        elseif value == true then
            text = "1"
        elseif value ~= nil and value ~= false then
            text = tostring(value)
        end
        local key = "DEV_FLAG_" .. flag.name:upper():gsub("-", "_")
        dev_os.defaults.env[key] = text
        if text == nil then
            unset[#unset + 1] = key
        end
    end
    dev_os.defaults.unset = unset
end

---Return the spec a `.sh` command's words are checked against, open to any words when the
---script declares no `# arg:` line.
local function open_words_spec(spec)
    if #spec.args > 0 then
        return spec
    end
    local open = {}
    for key, value in pairs(spec) do
        open[key] = value
    end
    open.args = { { name = "words", list = true } }
    return open
end

local function positional_words(spec, args, passthrough)
    local words = {}
    for _, arg in ipairs(spec.args) do
        local value = args[arg.name]
        if type(value) == "table" then
            for _, word in ipairs(value) do
                words[#words + 1] = word
            end
        elseif value ~= nil then
            words[#words + 1] = value
        end
    end
    for _, word in ipairs(passthrough or {}) do
        words[#words + 1] = word
    end
    return words
end

local function run_shell(row, spec, ctx)
    local checked = open_words_spec(spec)
    local opts, args, passthrough = spec_check.parse(checked, ctx.argv)
    if not opts then
        ctx.usage = ctx.usage or command.usage_line(ctx.name, spec)
        command.usage_error(ctx, tostring(args))
    end
    prepare(ctx)
    flag_environment(spec, opts)
    local words = positional_words(checked, args, passthrough)
    local relative = registry.relative(row, ctx.root)
    if ctx.verbose >= 1 then
        stderr:write("+ ", relative, #words > 0 and " " or "", table.concat(words, " "), "\n")
    end
    local argv
    if row.lang == "ps1" then
        if dev_os.name() ~= "Windows" then
            command.die("A .ps1 command runs only on Windows.")
        end
        argv = { "pwsh", "-File", row.script }
    elseif log.xtrace() then
        argv = { "bash", "-x", row.script }
    else
        argv = { row.script }
    end
    for _, word in ipairs(words) do
        argv[#argv + 1] = word
    end
    exec_or_exit(argv)
end

local function run_as_root(parsed)
    local args = parsed.args
    local is_driver = args[1] == root.DRIVER
    local words = is_driver and { args[1] } or { args[1], args[2] }
    local rest = tail(args, #words + 1)
    local ctx = {
        name = table.concat(words, " "),
        words = words,
        root = project.root(),
        args = rest,
        argv = rest,
        passthrough = {},
        after = 0,
        dashed = false,
        vars = {},
        usage = root.usage(words),
        source = registry.Source.BUILTIN,
        verbose = (log.verbosity()),
    }
    local reg = registry.load(ctx.root):view(registry.Source.BUILTIN)
    local row = reg:find(words)
    if not (row and row.script) then
        help.usage_error(ctx, reg, "unknown command " .. ctx.name)
    end
    if parsed.remote then
        local never_remote = reg:declared(words)
        dev_os.exit(remote.run(ctx, words, tail(rest, math.max(1, #rest - parsed.after + 1)), {
            detach = parsed.detach,
            priority = parsed.priority,
            job_timeout = parsed.job_timeout,
            never_remote = never_remote == false,
        }))
    end
    prepare(ctx)
    return command.run(row.script, ctx, (reg:spec(row)))
end

local function check_flags(parsed)
    if parsed.conflict then
        stderr:write("The flags `--local` and `--remote` cannot be used together.\n")
        dev_os.exit(2)
    end
    if parsed.detach and not parsed.remote then
        stderr:write("The flag `--detach` needs `--remote`.\n")
        dev_os.exit(2)
    end
    if parsed.priority and not parsed.remote then
        stderr:write("The flag `--priority` needs `--remote`.\n")
        dev_os.exit(2)
    end
    if parsed.job_timeout and not parsed.remote then
        stderr:write("The flag `--job-timeout` needs `--remote`.\n")
        dev_os.exit(2)
    end
    if parsed.job_timeout == "" then
        stderr:write("The flag `--job-timeout` needs a duration.\n")
        dev_os.exit(2)
    end
end

---Walk a parent command's subcommands down to the row that runs.
local function descend(reg, words, rest, parsed)
    local row = reg:find(words)
    while row and row.parent do
        local first = rest[1]
        local sub
        if first and first ~= "help" and not is_help(first) then
            words[#words + 1] = first
            sub = reg:find(words)
            words[#words] = nil
        end
        if not sub then
            if not first then
                parent_usage_error(reg, words, "needs a subcommand")
            end
            if first == "help" or help_flag(rest, parsed.after) then
                dev_os.exit(help.parent(reg, words))
            end
            parent_usage_error(reg, words, "unknown subcommand " .. first)
        end
        words[#words + 1] = first
        row, rest = sub, tail(rest, 2)
    end
    return row, rest
end

---Run `dev` with the parsed global flags and return the exit code.
---
---The checks of the global flags, the root gate and the usage errors come first. A command found
---in the registry runs in this process when it is a `.luau` file and replaces dev when it is a
---`.sh` or `.ps1` file. A command the registry does not know is a usage error.
---@param parsed dev.globals the global flags and the words after them, from the core
---@return integer? code the exit code, nil for 0
function M.main(parsed)
    check_flags(parsed)
    if parsed.local_flag then
        dev_os.setenv("DEV_LOCAL", "1")
    end
    root_gate(parsed.args)
    if dev_os.getuid() == 0 then
        return run_as_root(parsed)
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
    require_min_version(project_root)
    local reg = registry.load(project_root)
    local source, bare = registry.split(name)
    if source then
        local found, reason = reg:find({ name })
        if not found then
            stderr:write(registry.sentence(reason), "\n")
            dev_os.exit(2)
        end
        if parsed.remote then
            stderr:write("The flag `--remote` does not take a command with a source prefix.\n")
            dev_os.exit(2)
        end
        reg, name = reg:view(source), bare
    end
    local words, rest = { name }, tail(args, 2)
    local row
    row, rest = descend(reg, words, rest, parsed)
    local level, back = retake_verbosity(row and row.script and (reg:spec(row)) or nil, parsed)
    if back then
        rest = words_after_path(parsed.args, back, #words)
    end
    local passthrough = parsed.after > 0 and tail(rest, #rest - parsed.after + 1) or {}
    local ctx = {
        name = table.concat(words, " "),
        words = words,
        root = project_root,
        args = rest,
        argv = with_dashes(rest, parsed.after),
        passthrough = passthrough,
        after = parsed.after,
        dashed = parsed.dashed,
        vars = {},
        source = row and row.source or nil,
        verbose = level,
    }
    local flag
    if name ~= "help" then
        flag = help_flag(rest, parsed.after)
    elseif is_help(rest[1]) then
        flag = rest[1]
    end
    local never_remote, requires = reg:declared(words)
    local spec, broken
    if row and row.script then
        spec, broken = reg:spec(row)
    end
    local fetch_job = spec and spec.fetch
    local patch_job = spec and spec.patch
    local runs_local = spec ~= nil
        and (spec.runs_local == true or fetch_job ~= nil or patch_job ~= nil)
    if flag and (not parsed.remote or patch_job) then
        return help.command(ctx, reg, { words = words, short = flag == "-h" })
    end
    if name == "help" and not parsed.remote and not (row and row.script) then
        return help.run(ctx, reg)
    end
    local refusal, notice = stack.refresh(project_root)
    if notice then
        stderr:write(notice, "\n")
    end
    if refusal then
        stderr:write(refusal, "\n")
        dev_os.exit(1)
    end
    if parsed.remote and not fetch_job and not patch_job then
        return remote.run(ctx, words, tail(rest, math.max(1, #rest - parsed.after + 1)), {
            detach = parsed.detach,
            priority = parsed.priority,
            job_timeout = parsed.job_timeout,
            never_remote = never_remote == false,
        })
    end
    if
        not (parsed.local_flag or parsed.env_local or on_remote_host or source or runs_local)
        and remote_default(project_root, words, never_remote == false)
    then
        return remote.run(ctx, words, rest, { detach = false, priority = false })
    end
    if not on_remote_host and not runs_local then
        refuse_agent_local(project_root, words, never_remote == false)
    end
    if not on_remote_host then
        refuse_agent_primary(project_root, words, requires)
    end
    if not (row and row.script) then
        help.usage_error(ctx, reg, "unknown command " .. name)
    end
    if not spec then
        command.die(command.load_failure(ctx.name, broken))
    end
    if patch_job and not on_remote_host and fetches(parsed, project_root) then
        return fetch.apply(project_root, patch_job)
    end
    if fetch_job and not on_remote_host and fetches(parsed, project_root) then
        dev_os.setenv(fetch.ENV, fetch.pull(project_root, fetch_job))
    end
    if row.lang == "luau" then
        prepare(ctx)
        dev_os.defaults.show = ctx.verbose >= 1
        return command.run(row.script, ctx, spec)
    end
    run_shell(row, spec, ctx)
end

return M
