local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local runtime = require("@dev/runtime")
local spec_check = require("@dev/spec")
local dev_text = require("@dev/text")
local vcs = require("@dev/vcs")

local stderr = dev_os.stderr
local stdout = dev_os.stdout
local INTERRUPTED = "interrupted!"
local REFUSAL = {
    __tostring = function(refusal)
        return refusal.reason
    end,
}

---@class dev.Ctx
---@field name string the command as typed, a parent command and its subcommand joined by a space
---@field words string[] the command words
---@field root string absolute path of the project root
---@field argv string[] the words after the command words, unparsed, with `--` kept when words
---   follow it
---@field vars table<string, string> the `KEY=value` words, whose key starts with an uppercase
---   letter, for a global or project command that is not `positional`
---@field passthrough string[] the words after `--` when the spec sets `passthrough`, else empty
---@field usage string? the line a usage error prints under its message
---@field source string? `builtin`, `global` or `project`
---@field after integer? how many words of `argv` follow a `--`, 0 when none was typed
---@field dashed boolean? whether a `--` was typed, even with nothing after it
---@field verbose 0|1|2|3|4 the verbosity after the flags and `VERBOSE`

---@class dev.spec.Flag
---@field name string the name after `--`
---@field short string? the one letter after `-`
---@field kind "string"|"number"|"boolean"? what the flag takes, `string` when nil
---@field help string? the line `dev help` shows
---@field default any? the value when the flag is absent
---@field repeatable boolean? whether the flag may repeat and gathers a list
---@field required boolean? whether the flag must be given
---@field choices string[]? the words a string flag may take
---@field complete (string|string[]|fun(): string[])? where completion gets values

---@class dev.spec.Arg
---@field name string the key in `args`
---@field help string? the line `dev help` shows
---@field required boolean? whether the arg must be given
---@field list boolean? whether the arg takes the rest, for the last arg only
---@field complete (string|string[]|fun(): string[])? where completion gets values

---@class dev.Spec
---@field summary string? the one line `dev help` shows
---@field group string? the heading in `dev help`
---@field hidden boolean? whether `dev help` shows it only for `-a`
---@field remote boolean? false when the command never runs on a remote runner
---@field runs_local boolean? whether the command runs here even when remote is the default
---@field requires string[]? the preconditions, `workspace` the only one known
---@field positional boolean? whether `KEY=value` words stay arguments
---@field fetch {job: string, file: string}? the ci job whose file the command fetches first
---@field patch {job: string, file: string}? the ci job whose patch the command applies
---@field flags dev.spec.Flag[]? the flags in help order
---@field args dev.spec.Arg[]? the positional arguments in order
---@field globals boolean? false when the command takes no global flag after its name
---@field pass_unknown boolean? whether flags and words the spec does not declare go, in typed
---   order, to the trailing list arg
---@field passthrough boolean? whether words after `--` reach `ctx.passthrough`
---@field long string? the markdown `dev help` prints for a shell command
---@field see_also string[]? the help pages `dev help` points at
---@field run fun(opts: table<string, any>, args: table<string, any>, ctx: dev.Ctx): integer? runs the command

---@class dev.command
local M = {
    ---Agent roles that work in a workspace, never the primary checkout
    WORKSPACE_ROLES = {
        runner = true,
        implementer = true,
        planner = true,
        reviewer = true,
        verifier = true,
    },
}

---Name the role of the caller's `DEV_AGENT`, the middle part of `repo/role/card`.
---@return nil when `DEV_AGENT` is unset or names no role
function M.agent_role(): string?
    return (dev_os.getenv("DEV_AGENT") or ""):match("^[^/]*/([^/]*)")
end

local PLACEHOLDERS = { string = "NAME", integer = "N", number = "N" }

---Return the usage line of a command, drawn from its spec.
---@param name string the command words joined by spaces
---@param spec dev.Spec the command's spec
---@return string line `usage: dev NAME [--flag] [--flag VALUE] <arg> [arg...]`
function M.usage_line(name, spec)
    local parts = { "usage: dev " .. name }
    for _, flag in ipairs(spec.flags or {}) do
        local label = "--" .. flag.name
        if flag.kind and flag.kind ~= "boolean" then
            label = label .. " " .. (PLACEHOLDERS[flag.kind] or flag.kind:upper())
        end
        parts[#parts + 1] = "[" .. label .. "]"
    end
    for _, arg in ipairs(spec.args or {}) do
        local label = arg.name .. (arg.list and "..." or "")
        parts[#parts + 1] = arg.required and "<" .. label .. ">" or "[" .. label .. "]"
    end
    return table.concat(parts, " ")
end

---Print `dev <name>: <msg>` and exit 2, with the context's `usage` line under it when it has one.
---@param ctx dev.Ctx the command's context
---@param msg string what is wrong with the arguments
function M.usage_error(ctx, msg)
    stderr:write("dev ", ctx.name, ": ", msg, "\n")
    if ctx.usage then
        stderr:write(ctx.usage, "\n")
    end
    dev_os.exit(2)
end

---Refuse any positional argument, for a command that takes no positional arguments.
---@param ctx dev.Ctx the command's context
function M.no_args(ctx)
    local arg = (ctx.argv or ctx.args or {})[1]
    if arg == nil then
        return
    end
    if arg:sub(1, 1) == "-" then
        M.usage_error(ctx, "Unknown flag " .. arg .. ".")
    end
    M.usage_error(
        ctx,
        "Unknown argument " .. arg .. ". This command takes no positional arguments."
    )
end

---Write `msg` and a newline to standard output.
---@param msg string the whole message
function M.say(msg)
    stdout:write(msg, "\n")
end

---Write a captured text to standard output without its one trailing newline, and nothing for an
---empty text.
---@param text string the captured command output
function M.relay(text)
    if text == "" then
        return
    end
    M.say((text:gsub("\n$", "")))
end

---Write `msg` and a newline to standard error.
---@param msg string the whole message
function M.note(msg)
    stderr:write(msg, "\n")
end

---Write the sentence for the error of `vcs.require`, `vcs.backend` or `forge.resolve`.
---@param err string a `vcs.Reason`, or another error that becomes a sentence as it is
---@param root string absolute path of the project root
---@return string sentence the message to show
function M.vcs_sentence(err, root)
    if err == vcs.Reason.NO_CHECKOUT then
        return "Neither .jj nor .git found in " .. root .. "."
    end
    if err == vcs.Reason.NO_JJ then
        return "The tool jj was not found. Install it with `brew install jj`."
    end
    return dev_text.sentence(err)
end

---The sentence that says a command did not load, with the reason it gave.
---@param name string the command name
---@param reason any the reason the load gave
---@return string message the full sentence
function M.load_failure(name, reason)
    return "The command " .. name .. " did not load: " .. (tostring(reason):gsub("%.$", "")) .. "."
end

---Print `msg` and exit 1.
---@param msg string the whole message
function M.die(msg)
    M.note(msg)
    dev_os.exit(1)
end

---Print the command on standard error as `+ command` when `ctx.verbose` is 1 or more.
---@param ctx dev.Ctx the command's context
---@param argv string[] the command and its arguments, joined with spaces
function M.show(ctx, argv)
    if ctx.verbose >= 1 then
        M.note("+ " .. table.concat(argv, " "))
    end
end

---Exit 1 with one line when `binary` is not on PATH.
---@param binary string the program the command needs
---@param install string how to install it, as the warning shows
function M.need(binary, install)
    if not dev_os.which(binary) then
        M.note("Tool " .. binary .. " not found. Install it with " .. install .. ".")
        dev_os.exit(1)
    end
end

---Split the `KEY=value` words, whose key starts with an uppercase letter, from the other words.
---
---The words after a `--` stay where they are.
---@param words string[] the words after the command words
---@return string[] plain the other words, in order
---@return table<string, string> vars the `KEY=value` words by key
function M.split_vars(words)
    local plain, vars = {}, {}
    local dashed = false
    for _, word in ipairs(words) do
        local key, value
        if not dashed then
            dashed = word == "--"
            key, value = word:match("^(%u[^=]*)=(.*)$")
        end
        if key then
            vars[key] = value
        else
            plain[#plain + 1] = word
        end
    end
    return plain, vars
end

local function read_source(path, embedded)
    if embedded then
        local text = runtime.asset(path)
        if not text then
            return nil, "the embedded file " .. path .. " is missing"
        end
        return text
    end
    local text, reason = fs.read(path)
    if not text then
        return nil, "cannot read " .. path .. (reason and (": " .. tostring(reason)) or "")
    end
    return text
end

local function strip_position(text, path)
    local head, rest = text:match("^([^\n]-):%d+: (.*)$")
    if head and (head == path or head:sub(1, 3) == "...") then
        return rest
    end
    return text
end

---Load a `.luau` command file and return its checked spec.
---
---The chunk runs in a fresh environment that reads the globals, so a command file keeps its names
---to itself. The file must return a spec table with a `run` function.
---@param path string the file, or the embedded asset path for a builtin command
---@param embedded boolean? whether `path` is an embedded asset
---@return dev.Spec? spec the checked spec
---@return string? reason what is wrong, with no position of the chunk
function M.load(path, embedded)
    local source, why = read_source(path, embedded)
    if not source then
        return nil, why
    end
    local env = setmetatable({}, { __index = _G })
    local chunk, message = runtime.load(source, "@" .. path, env)
    if not chunk then
        return nil, strip_position(tostring(message), path)
    end
    local ok, result = pcall(chunk)
    if not ok then
        if getmetatable(result) == REFUSAL then
            return nil, result.reason, result.code
        end
        return nil, strip_position(tostring(result), path)
    end
    if type(result) ~= "table" then
        return nil, "the file returned " .. tostring(result) .. ", not a command spec"
    end
    local checked, reason, code = spec_check.validate(result)
    if not checked then
        return nil, reason, code
    end
    if type(result.run) ~= "function" then
        return nil, "the command spec has no `run` function"
    end
    return result
end

---Run a `.luau` command in this process.
---
---A file that fails to load, an error the command raises and a command that returns anything but
---an integer all end the run with a message and no traceback. Words that do not fit the spec end
---it with a usage message and exit 2.
---@param path string the `.luau` file, or its embedded asset path when `ctx.source` is `builtin`
---@param ctx dev.Ctx the context the command gets
---@param loaded dev.Spec? the spec the registry loaded already
---@return integer code the command's exit code modulo 256 as a shell takes it, 0 when it returns
---   nothing
function M.run(path, ctx, loaded)
    local spec, reason = loaded, nil
    if not spec then
        spec, reason = M.load(path, ctx.source == "builtin")
    end
    if not spec then
        if tostring(reason):find(INTERRUPTED, 1, true) then
            return dev_os.interrupt_code()
        end
        M.note(M.load_failure(ctx.name, reason))
        return 1
    end
    local words = ctx.argv or {}
    if ctx.source ~= "builtin" and not spec.positional then
        words, ctx.vars = M.split_vars(words)
    end
    ctx.vars = ctx.vars or {}
    local opts, args, passthrough = spec_check.parse(spec, words)
    ctx.usage = ctx.usage or M.usage_line(ctx.name, spec)
    if not opts then
        M.usage_error(ctx, tostring(args))
    end
    ctx.passthrough = passthrough or {}
    local ok, result = pcall(spec.run, opts, args, ctx)
    if not ok then
        local text = tostring(result)
        if text:find(INTERRUPTED, 1, true) then
            return dev_os.interrupt_code()
        end
        M.note(strip_position(text, path))
        return 1
    end
    if result == nil then
        return 0
    end
    if type(result) ~= "number" or result % 1 ~= 0 then
        M.note("The script returned " .. tostring(result) .. ", not an exit code.")
        return 1
    end
    return result % 256
end

setmetatable(M, {
    __call = function(_, spec)
        local checked, reason, code = spec_check.validate(spec)
        if not checked then
            error(setmetatable({ reason = reason, code = code }, REFUSAL), 0)
        end
        return checked
    end,
})

return M
