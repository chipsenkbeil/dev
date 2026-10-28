local board = require("dev.cmd.board")
local box = require("dev.cmd.box")
local complete = require("dev.complete")
local connect = require("dev.cmd.connect")
local init = require("dev.cmd.init")
local misc = require("dev.cmd.misc")
local pull = require("dev.cmd.pull")
local push = require("dev.cmd.push")
local sync = require("dev.cmd.sync")
local tools = require("dev.cmd.tools")
local types = require("dev.cmd.types")
local devos = require("dev.os")
local fs = require("dev.fs")
local help = require("dev.help")
local project = require("dev.project")
local registry = require("dev.registry")
local remote = require("dev.remote")
local root = require("dev.root")
local verb = require("dev.verb")

local stderr = io.stderr
local INTERPRETER = arg and arg[-1]
local MAX_LEVEL = 2
local ROOT_REFUSAL = "dev: as root, dev runs only tools install and tools check\n"
local SHARE = project.share
local VCS_HANDLERS = { push = push.run, pull = pull.run, sync = sync.run }
local NOT_TAKEN = {
    push = function(arg)
        return arg:sub(1, 1) == "-"
    end,
    pull = function()
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
---@field remote boolean whether `--remote` or `DEV_REMOTE` asks for a remote run
---@field detach boolean whether `--detach` was given
---@field level integer the verbosity before the trace file is checked

local function parse(argv)
    local parsed =
        { args = {}, after = 0, remote = enabled(os.getenv("DEV_REMOTE") or ""), detach = false }
    local count = 0
    for i, word in ipairs(argv) do
        if word == "--" then
            parsed.after = #argv - i
            for j = i + 1, #argv do
                parsed.args[#parsed.args + 1] = argv[j]
            end
            break
        elseif word == "--verbose" then
            count = count + 1
        elseif word == "--remote" then
            parsed.remote = true
        elseif word == "--detach" then
            parsed.detach = true
        elseif word:find("^%-v+$") then
            count = count + #word - 1
        else
            parsed.args[#parsed.args + 1] = word
        end
    end
    parsed.level = level_of(count > 0 and tostring(count) or os.getenv("VERBOSE") or "")
    return parsed
end

local function root_gate(args)
    if devos.getuid() ~= 0 then
        return
    end
    if not root.allowed(args) then
        stderr:write(ROOT_REFUSAL)
        os.exit(2)
    end
    if devos.name() ~= "Linux" then
        stderr:write("dev: as root, dev runs only on Linux\n")
        os.exit(2)
    end
end

local function exec_or_exit(argv, opts)
    devos.defaults.show = false
    local _, message = devos.exec(argv, opts)
    stderr:write("dev: cannot run ", argv[1], ": ", message, "\n")
    os.exit(devos.EXEC_FAILED)
end

local function legacy(argv)
    local full = { "bash", SHARE .. "/legacy.bash" }
    for _, word in ipairs(argv) do
        full[#full + 1] = word
    end
    exec_or_exit(full, {
        env = { DEV_UID = tostring(devos.getuid()), DEV_OS = devos.name() },
    })
end

local function apply_level(level)
    if level >= MAX_LEVEL then
        local trace = SHARE .. "/xtrace.bash"
        if fs.is_file(trace) then
            devos.defaults.env.BASH_ENV = trace
            devos.defaults.env.PS4 = project.PS4
        else
            stderr:write("dev: trace file ", trace, " is missing, showing commands only\n")
            level = 1
        end
    end
    if level >= 1 then
        devos.defaults.env.VERBOSE = tostring(level)
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
        devos.defaults.unset = { "VERBOSE" }
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
    devos.defaults.show = ctx.verbose >= 1
    ctx.args, ctx.vars = split_vars(rest)
    os.exit(verb.run(row.script, ctx))
end

local function builtin_handler(row)
    if row and row.kind == "builtin" and not row.noun and row.handler == "lua" then
        return types.handlers[row.name]
            or VCS_HANDLERS[row.name]
            or misc[row.name]
            or tools.handlers[row.name]
            or box.handlers[row.name]
            or board.handlers[row.name]
            or connect.handlers[row.name]
            or init.handlers[row.name]
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
    "; pass it after -- to reach the script, or add it to the script's # flags: line"

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
            verb.usage_error(ctx, "unknown flag " .. flag .. UNDECLARED_HINT)
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
        os.exit(
            remote.run(ctx, words, tail(rest, math.max(1, #rest - parsed.after + 1)), parsed.detach)
        )
    end
    prepare(ctx)
    os.exit(tools.handlers[ctx.name](ctx))
end

---Run `dev` with the command line and exit.
---
---Global flags, the root gate and the usage errors come first. A `.lua` verb
---runs in this process, a `.sh` verb replaces it, and everything dev has not
---ported yet is handed to `legacy.bash` with the arguments as they came.
---@param argv string[] the command line after `dev`
---@return nil
function M.main(argv)
    local parsed = parse(argv)
    if parsed.detach and not parsed.remote then
        stderr:write("dev: --detach needs --remote\n")
        os.exit(2)
    end
    root_gate(parsed.args)
    if devos.getuid() == 0 then
        run_as_root(parsed)
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

        vars = {},
        verbose = parsed.level,
        interpreter = INTERPRETER,
    }
    local flag = name ~= "help" and help_flag(rest, parsed.after)
    if flag and not parsed.remote then
        os.exit(help.verb(ctx, reg, { words = words, short = flag == "-h" }))
    end
    if name == "help" and not parsed.remote and not (row and row.script) then
        os.exit(help.run(ctx, reg))
    end
    if parsed.remote then
        os.exit(
            remote.run(ctx, words, tail(rest, math.max(1, #rest - parsed.after + 1)), parsed.detach)
        )
    end
    if row and row.script then
        refuse_undeclared(reg, ctx, rest, parsed.after)
        run_script(row, ctx, rest)
    end
    local handler = builtin_handler(row)
    if handler then
        refuse_untaken(ctx, reg)
        prepare(ctx)
        os.exit(handler(ctx, reg))
    end
    legacy(argv)
end

return M
