local builtins = require("dev.builtins")
local devos = require("dev.os")
local fs = require("dev.fs")
local help = require("dev.help")
local project = require("dev.project")
local root = require("dev.root")
local verb = require("dev.verb")

local stderr = io.stderr
local ROOT_ENV = {
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME=/root",
    "LANG=C.UTF-8",
}
local REMOVE_COPY =
    "copy=$1; shift; trap 'rm -f -- \"$copy\"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; \"$@\""

local Scope = require("dev.pkg.kinds").Scope

---@class dev.cmd.tools
---@field handlers table<string, fun(ctx: dev.Ctx, reg: dev.Registry?): integer> the handlers of `tools install` and `tools check`, the registry being nil as root
local M = { handlers = {} }

local function usage_error(ctx, reg, message)
    stderr:write("dev ", ctx.name, ": ", message, "\n")
    if not reg then
        for _, row in ipairs(builtins) do
            if table.concat(row.words, " ") == ctx.name and row.usage then
                stderr:write("usage: ", row.usage, "\n")
            end
        end
    end
    os.exit(2)
end

local function bad_argument(ctx, reg, arg)
    if reg then
        help.bad_argument(ctx, reg, arg)
    end
    local kind = arg:sub(1, 1) == "-" and "flag" or "argument"
    usage_error(ctx, reg, "unknown " .. kind .. " " .. arg)
end

local function fail(message)
    verb.note("dev: " .. message)
    return 1
end

local function exec(argv, opts)
    local _, message = devos.exec(argv, opts)
    verb.note("dev: cannot run " .. argv[1] .. ": " .. message)
    return devos.EXEC_FAILED
end

local function root_env(ctx)
    local env = { unpack(ROOT_ENV) }
    local level = ctx.verbose
    local trace = project.share .. "/xtrace.bash"
    if level >= 2 and not fs.is_file(trace) then
        level = 1
    end
    if level >= 1 then
        env[#env + 1] = "VERBOSE=" .. level
    end
    if level >= 2 then
        env[#env + 1] = "BASH_ENV=" .. trace
        env[#env + 1] = "PS4=" .. project.PS4
    end
    return env
end

local function interpreter(ctx, is_root)
    local path = ctx.interpreter
    if path and path:sub(1, 1) == "/" then
        return path
    end
    if not is_root then
        return "luajit"
    end
end

local function run_driver(ctx, sub, manifest, args)
    local pkg = project.dotfiles_root() .. "/dotfiles/bin/.local/share/dev/pkg.lua"
    if not fs.is_file(pkg) then
        return fail("no " .. pkg .. " (set DOTFILES to the dotfiles repo)")
    end
    local is_root = devos.getuid() == 0
    local luajit = interpreter(ctx, is_root)
    if not is_root then
        local argv = { luajit, pkg, sub, "--manifest", manifest, unpack(args) }
        verb.show(ctx, argv)
        return exec(argv, { cwd = ctx.root })
    end
    local copy, message = root.manifest_copy(ctx.root, manifest)
    if not copy then
        return fail(message)
    end
    if not luajit then
        fs.remove(copy)
        return fail("cannot find the absolute path of the luajit that runs dev")
    end
    local driver = { "env", "-i", unpack(root_env(ctx)) }
    for _, word in ipairs({ luajit, pkg, sub, "--manifest", copy, unpack(args) }) do
        driver[#driver + 1] = word
    end
    verb.show(ctx, driver)
    local argv = { "sh", "-c", REMOVE_COPY, "sh", copy }
    for _, word in ipairs(driver) do
        argv[#argv + 1] = word
    end
    local code = devos.run(argv, { cwd = ctx.root })
    fs.remove(copy)
    return code or devos.EXEC_FAILED
end

local function manifest_path(ctx)
    local manifest = ctx.root .. "/.dev/tools.tsv"
    if fs.is_file(manifest) then
        return manifest
    end
    print("no .dev/tools.tsv")
end

local function parse_install(ctx, reg)
    local parsed = { opts = {}, tools = {} }
    local args, i = ctx.args, 1
    while i <= #args do
        local arg = args[i]
        i = i + 1
        if arg == "--dry-run" or arg == "--force" then
            parsed.opts[#parsed.opts + 1] = arg
        elseif arg == "--group" then
            if i > #args then
                usage_error(ctx, reg, "--group needs a name")
            end
            parsed.opts[#parsed.opts + 1] = "--group"
            parsed.opts[#parsed.opts + 1] = args[i]
            i = i + 1
        elseif arg == "--system" or arg == "--user" then
            local scope = arg == "--system" and Scope.SYSTEM or Scope.USER
            if parsed.scope and parsed.scope ~= scope then
                usage_error(ctx, reg, "--system and --user cannot be combined")
            end
            parsed.scope = scope
        elseif arg:sub(1, 1) == "-" then
            usage_error(ctx, reg, "unknown flag " .. arg)
        else
            parsed.tools[#parsed.tools + 1] = arg
        end
    end
    return parsed
end

---Install the manifest's tools, through the package driver.
---@param ctx dev.Ctx the verb's context
---@param reg dev.Registry? the project's registry, nil as root
---@return integer code the driver's exit code, or 0 with no manifest
M.handlers["tools install"] = function(ctx, reg)
    local parsed = parse_install(ctx, reg)
    local manifest = manifest_path(ctx)
    if not manifest then
        return 0
    end
    local is_root = devos.getuid() == 0
    if not parsed.scope and is_root then
        usage_error(ctx, reg, "as root, pass --system")
    end
    if parsed.scope == Scope.SYSTEM and not is_root and devos.name() ~= "Darwin" then
        return fail("tools install --system installs packages and needs root, run it as root")
    end
    if parsed.scope == Scope.USER and is_root then
        return fail("tools install --user installs into the user's home and refuses to run as root")
    end
    local args = parsed.opts
    if parsed.scope then
        args[#args + 1] = "--scope"
        args[#args + 1] = parsed.scope
    end
    for _, name in ipairs(parsed.tools) do
        args[#args + 1] = name
    end
    return run_driver(ctx, "install", manifest, args)
end

---Report which of the manifest's tools are on PATH.
---@param ctx dev.Ctx the verb's context
---@param reg dev.Registry? the project's registry, nil as root
---@return integer code the driver's exit code, or 0 with no manifest
M.handlers["tools check"] = function(ctx, reg)
    local args, i = {}, 1
    while i <= #ctx.args do
        if ctx.args[i] ~= "--group" then
            bad_argument(ctx, reg, ctx.args[i])
        end
        if i == #ctx.args then
            usage_error(ctx, reg, "--group needs a name")
        end
        args[#args + 1] = "--group"
        args[#args + 1] = ctx.args[i + 1]
        i = i + 2
    end
    local manifest = manifest_path(ctx)
    if not manifest then
        return 0
    end
    return run_driver(ctx, "check", manifest, args)
end

return M
