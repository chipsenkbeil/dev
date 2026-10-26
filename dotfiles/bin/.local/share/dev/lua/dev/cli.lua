local devos = require("dev.os")
local fs = require("dev.fs")
local project = require("dev.project")
local registry = require("dev.registry")
local remote = require("dev.remote")
local verb = require("dev.verb")

local stderr = io.stderr
local MAX_LEVEL = 2
local ROOT_REFUSAL = "dev: as root, dev runs only tools install and tools check\n"
local EXEC_FAILED = 126
local SHARE = (debug.getinfo(1, "S").source:match("^@(.*)/lua/dev/[^/]*$") or ".")
local PS4 = "+ ${BASH_SOURCE##*/}:${LINENO}: "
local LEGACY_ONLY = {
    help = true,
    __verbs = true,
    __subs = true,
    __flags = true,
    ["__check-topics"] = true,
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
---@field ci boolean whether `--ci` or `DEV_CI` asks for the pipeline job
---@field level integer the verbosity before the trace file is checked

local function parse(argv)
    local parsed = { args = {}, after = 0, ci = enabled(os.getenv("DEV_CI") or "") }
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
        elseif word == "--ci" then
            parsed.ci = true
        elseif word:find("^%-v+$") then
            count = count + #word - 1
        else
            parsed.args[#parsed.args + 1] = word
        end
    end
    parsed.level = level_of(count > 0 and tostring(count) or os.getenv("VERBOSE") or "")
    return parsed
end

local function goes_to_legacy(name, ci)
    return LEGACY_ONLY[name] and not (name == "help" and ci)
end

local function root_gate(args)
    if devos.getuid() ~= 0 then
        return
    end
    if not (args[1] == "tools" and (args[2] == "install" or args[2] == "check")) then
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
    os.exit(EXEC_FAILED)
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
            devos.defaults.env.PS4 = PS4
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

local function run_script(row, ctx, rest)
    local relative = row.script:sub(#ctx.root + 2)
    ctx.verbose = apply_level(ctx.verbose)
    if ctx.verbose == 0 then
        devos.defaults.unset = { "VERBOSE" }
    end
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

local function tail(list, from)
    local out = {}
    for i = from, #list do
        out[#out + 1] = list[i]
    end
    return out
end

local function help_requested(rest, after)
    return #rest > after and (rest[1] == "-h" or rest[1] == "--help")
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
    root_gate(parsed.args)
    local args = parsed.args
    local name = args[1] or "help"
    if name == "-h" or name == "--help" then
        name = "help"
    end
    if goes_to_legacy(name, parsed.ci) then
        legacy(argv)
    end
    local root = project.root()
    local reg = registry.load(root)
    local words, rest = { name }, tail(args, 2)
    local row = reg:find(words)
    if row and row.noun then
        local sub = rest[1] and reg:find({ name, rest[1] })
        if not sub or rest[1] == "help" or rest[1]:find("^__") then
            legacy(argv)
        end
        words[2] = rest[1]
        row, rest = sub, tail(rest, 2)
    end
    if name ~= "help" and help_requested(rest, parsed.after) then
        legacy(argv)
    end
    local ctx = {
        name = table.concat(words, " "),
        words = words,
        root = root,
        args = rest,
        vars = {},
        verbose = parsed.level,
    }
    if parsed.ci then
        remote.ci(ctx)
    end
    if row and row.script then
        run_script(row, ctx, rest)
    end
    legacy(argv)
end

return M
