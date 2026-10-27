local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local project = require("dev.project")
local verb = require("dev.verb")

local stderr = io.stderr
local Kind = project.Kind

---@enum dev.cmd.types.Verb
local Verb = {
    LINT = "lint",
    FMT = "fmt",
    TEST = "test",
    BUILD = "build",
    RUN = "run",
    FETCH = "fetch",
}

---@class dev.cmd.types.Need
---@field [1] string the binary the step runs
---@field [2] string how to install it

---@class dev.cmd.types.Step
---@field argv string[] the command and its arguments
---@field cwd string? the directory to run in, the current one when nil
---@field needs dev.cmd.types.Need[]? binaries that must be on PATH before the step runs
---@field probe { argv: string[], warning: string }? a command that must succeed, else the warning is printed

---@class dev.cmd.types
---@field Verb table<string, dev.cmd.types.Verb> the verbs the project type decides
---@field VERBS table<string, boolean> the same verbs as a set of names
---@field handlers table<string, fun(ctx: dev.Ctx): integer> one handler per verb, for the registry's rows
local M = { Verb = Verb, VERBS = {}, handlers = {} }

local CARGO = { "cargo", "brew install rustup" }
local MAKE = { "make", "xcode-select --install" }

local function concat(base, extra)
    local out = {}
    for _, word in ipairs(base) do
        out[#out + 1] = word
    end
    for _, word in ipairs(extra) do
        out[#out + 1] = word
    end
    return out
end

local function shell_word(word)
    if word:find("^[%w_@%%+=:,./-]+$") then
        return word
    end
    return devos.quote(word)
end

local function has_make_target(root, target)
    local text = fs.read(root .. "/Makefile")
    if not text then
        return false
    end
    for line in text:gmatch("[^\n]+") do
        if line:find("^" .. target .. "%s*:") then
            return true
        end
    end
    return false
end

local function node_script(root, name)
    local text = fs.read(root .. "/package.json")
    local doc = text and json.decode(text)
    local scripts = type(doc) == "table" and doc.scripts
    if type(scripts) ~= "table" then
        return false
    end
    local value = scripts[name]
    return value ~= nil and value ~= false and value ~= json.null
end

local function make_steps(root, verb_name, args)
    if not has_make_target(root, verb_name) then
        return nil, "(none: no " .. verb_name .. " target in the Makefile)"
    end
    local argv = concat({ "make", "-C", root, verb_name }, args)
    return { { argv = argv, needs = { MAKE } } }
end

local function stylua_steps(root, args)
    local argv = concat({ "stylua" }, args)
    argv[#argv + 1] = root
    return { { argv = argv, needs = { { "stylua", "brew install stylua" } } } }
end

local function rust_steps(root, verb_name, args)
    local steps
    if verb_name == Verb.LINT then
        steps = {
            {
                argv = { "cargo", "+nightly", "fmt", "--check" },
                probe = {
                    argv = { "cargo", "+nightly", "fmt", "--version" },
                    warning = "nightly rustfmt not found. Install with: rustup toolchain install nightly --component rustfmt",
                },
            },
            {
                argv = {
                    "cargo",
                    "clippy",
                    "--all-targets",
                    "--all-features",
                    "--",
                    "-D",
                    "warnings",
                },
            },
        }
        if fs.is_file(root .. "/sgconfig.yml") then
            steps[#steps + 1] = {
                argv = { "ast-grep", "scan", "--globs", "!target/**" },
                cwd = root,
                needs = { { "ast-grep", "brew install ast-grep" } },
            }
        end
    elseif verb_name == Verb.FMT then
        steps = { { argv = concat({ "cargo", "+nightly", "fmt" }, args) } }
    elseif verb_name == Verb.TEST then
        steps = {
            {
                argv = concat({ "cargo", "nextest", "run", "--all-features" }, args),
                probe = {
                    argv = { "cargo", "nextest", "--version" },
                    warning = "cargo-nextest not found. Install with: cargo install cargo-nextest --locked",
                },
            },
            { argv = concat({ "cargo", "test", "--doc", "--all-features" }, args) },
        }
    elseif verb_name == Verb.BUILD then
        steps = { { argv = concat({ "cargo", "build", "--release" }, args) } }
    elseif verb_name == Verb.RUN then
        steps = { { argv = concat({ "cargo", "run", "--" }, args) } }
    elseif verb_name == Verb.FETCH then
        local offline = { "env", "CARGO_NET_OFFLINE=false", "cargo" }
        steps = { { argv = concat(offline, { "fetch", "--locked" }), cwd = root } }
        if fs.is_file(root .. "/deny.toml") then
            steps[#steps + 1] = {
                argv = concat(offline, { "deny", "fetch" }),
                cwd = root,
                probe = {
                    argv = { "cargo", "deny", "--version" },
                    warning = "cargo-deny not found. Install with: cargo install cargo-deny --locked",
                },
            }
        end
    end
    steps[1].needs = { CARGO }
    return steps
end

local function love2d_steps(root, verb_name, args)
    if verb_name == Verb.RUN then
        local argv = concat({ "love", root }, args)
        return { { argv = argv, needs = { { "love", "brew install --cask love" } } } }
    elseif verb_name == Verb.TEST or verb_name == Verb.LINT then
        return make_steps(root, verb_name, args)
    elseif verb_name == Verb.FMT then
        return stylua_steps(root, args)
    end
end

local function lua_steps(root, verb_name, args)
    if verb_name == Verb.FMT then
        return stylua_steps(root, args)
    end
    return make_steps(root, verb_name, args)
end

local function godot_steps(root, verb_name, args)
    if verb_name == Verb.RUN then
        local argv = concat({ "godot", "--path", root }, args)
        return { { argv = argv, needs = { { "godot", "brew install --cask godot" } } } }
    end
end

local function node_steps(root, verb_name, args)
    if not node_script(root, verb_name) then
        return nil, "(none: no " .. verb_name .. " script in package.json)"
    end
    local argv = { "npm", "--prefix", root, "run", verb_name }
    if #args > 0 then
        argv[#argv + 1] = "--"
    end
    return { { argv = concat(argv, args), needs = { { "npm", "brew install node" } } } }
end

local PLANS = {
    [Kind.RUST] = rust_steps,
    [Kind.LOVE2D] = love2d_steps,
    [Kind.LUA] = lua_steps,
    [Kind.GODOT] = godot_steps,
    [Kind.NODE] = node_steps,
    [Kind.MAKE] = make_steps,
}

local function plan(root, kind, verb_name, args)
    local build = PLANS[kind]
    local steps, none_line
    if build then
        steps, none_line = build(root, verb_name, args)
    end
    return steps, none_line or "(none: no built-in " .. verb_name .. " for " .. kind .. " projects)"
end

---List the command lines a built-in runs, as `dev help <verb>` prints them.
---@param root string the project root
---@param kind string the project type, `none` for an undetected one
---@param verb_name dev.cmd.types.Verb the verb
---@return string[] lines one command per line, or a single `(none: ...)` line
function M.commands(root, kind, verb_name)
    local steps, none_line = plan(root, kind, verb_name, {})
    if not steps then
        return { none_line }
    end
    local lines = {}
    for _, step in ipairs(steps) do
        local words = {}
        for i, word in ipairs(step.argv) do
            words[i] = shell_word(word)
        end
        lines[#lines + 1] = table.concat(words, " ")
    end
    return lines
end

local function unsupported(verb_name, kind)
    stderr:write(
        "dev: no built-in ",
        verb_name,
        " for ",
        kind,
        " projects, add .dev/",
        verb_name,
        ".sh\n"
    )
    return 1
end

local function probe_fails(step)
    local code = devos.run(step.probe.argv, { stdout = "null", stderr = "null" })
    if code == 0 then
        return false
    end
    stderr:write("WARNING: ", step.probe.warning, "\n")
    return true
end

---Run the standard sequence of a verb for the detected project type.
---
---The first command that fails ends the run with its exit code. A verb the
---type has no built-in for prints the usual message and returns 1.
---@param ctx dev.Ctx the verb's context, whose `args` reach the last command verbatim
---@param verb_name dev.cmd.types.Verb the verb
---@return integer code 0 when every command passed
function M.run(ctx, verb_name)
    local kind = project.detect_type(ctx.root)
    if not kind then
        return unsupported(verb_name, "undetected")
    end
    local steps = plan(ctx.root, kind, verb_name, ctx.args)
    if not steps then
        return unsupported(verb_name, kind)
    end
    for _, step in ipairs(steps) do
        for _, need in ipairs(step.needs or {}) do
            verb.need(need[1], need[2])
        end
        if step.probe and probe_fails(step) then
            return 1
        end
        verb.show(ctx, step.argv)
        local code = devos.run(step.argv, { cwd = step.cwd }) or 1
        if code ~= 0 then
            return code
        end
    end
    return 0
end

for _, name in pairs(Verb) do
    M.VERBS[name] = true
    M.handlers[name] = function(ctx)
        return M.run(ctx, name)
    end
end

return M
