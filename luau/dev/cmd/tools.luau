local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local runtime = require("@dev/runtime")
local root = require("@dev/root")
local dev_command = require("@dev/command")

local ROOT_ENV = {
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME=/root",
    "LANG=C.UTF-8",
}
local REMOVE_COPY =
    "copy=$1; shift; trap 'rm -rf -- \"${copy%/*}\"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; \"$@\""

local Scope = require("@dev/pkg/kinds").Scope

---@class dev.cmd.tools
local M = {}

local function fail(message)
    dev_command.note(message)
    return 1
end

local function exec(argv, opts)
    local _, message = dev_os.exec(argv, opts)
    dev_command.note("Cannot run " .. argv[1] .. ". " .. message)
    return dev_os.EXEC_FAILED
end

local function root_env(ctx)
    local env = table.move(ROOT_ENV, 1, #ROOT_ENV, 1, {})
    if ctx.verbose >= 1 then
        env[#env + 1] = "VERBOSE=" .. ctx.verbose
    end
    return env
end

---Write why a manifest was refused as root.
---@param reason dev.root.Reason the reason `root.manifest_copy` named
---@param manifest string absolute path of the manifest
---@param detail string? the path that fails the ownership check, or the copy
---@return string message the sentence
local function manifest_refusal(reason, manifest, detail)
    local Reason = root.Reason
    local refusing = "Refusing " .. manifest .. " as root. "
    if reason == Reason.OPEN then
        return "Cannot open " .. manifest .. "."
    elseif reason == Reason.NOT_REGULAR then
        return refusing .. "It is not a regular file."
    elseif reason == Reason.OWNERSHIP then
        return refusing
            .. "The path "
            .. tostring(detail)
            .. " must be owned by root and not writable by others."
    elseif reason == Reason.TOO_LARGE then
        return refusing .. "It is larger than " .. root.MAX_BYTES / 1024 .. " KiB."
    elseif reason == Reason.LONG_LINE then
        return refusing .. "A line is longer than " .. root.MAX_LINE_BYTES .. " bytes."
    elseif reason == Reason.TEMP then
        return "Cannot make a temp file."
    elseif reason == Reason.WRITE then
        return "Cannot write " .. tostring(detail) .. "."
    end
    return refusing .. "It failed for a reason dev does not know."
end

local WRITABLE_BY_GROUP_OR_OTHERS = 18

---Name the first of a binary and its folder that root must not run, nil when both are safe.
---
---A safe path is owned by root and writable by neither its group nor others.
---@param exe string absolute path of the binary
---@return string? path the path that fails the check
function M.unsafe_binary(exe)
    for _, path in ipairs({ exe, fs.dirname(exe) }) do
        local stat = fs.stat(path)
        if
            stat == nil
            or stat.uid ~= 0
            or bit32.band(stat.mode, WRITABLE_BY_GROUP_OR_OTHERS) ~= 0
        then
            return path
        end
    end
end

local function run_driver(ctx, sub, manifest, args)
    local is_root = dev_os.getuid() == 0
    local exe = runtime.exe
    if not is_root then
        local argv = { exe, root.DRIVER, sub, "--manifest", manifest }
        for _, word in ipairs(args) do
            argv[#argv + 1] = word
        end
        dev_command.show(ctx, argv)
        return exec(argv, { cwd = ctx.root })
    end
    local unsafe = M.unsafe_binary(exe)
    if unsafe then
        return fail(
            "Refusing "
                .. exe
                .. " as root. The path "
                .. unsafe
                .. " must be owned by root and not writable by its group or others."
        )
    end
    local copy, _, reason, detail = root.manifest_copy(ctx.root, manifest)
    if not copy then
        return fail(manifest_refusal(reason, manifest, detail))
    end
    local driver = { "env", "-i" }
    for _, word in ipairs(root_env(ctx)) do
        driver[#driver + 1] = word
    end
    for _, word in ipairs({ exe, root.DRIVER, sub, "--manifest", copy }) do
        driver[#driver + 1] = word
    end
    for _, word in ipairs(args) do
        driver[#driver + 1] = word
    end
    dev_command.show(ctx, driver)
    local argv = { "sh", "-c", REMOVE_COPY, "sh", copy }
    for _, word in ipairs(driver) do
        argv[#argv + 1] = word
    end
    local code = dev_os.run(argv, { cwd = ctx.root })
    fs.remove(fs.dirname(copy), { recursive = true })
    return code or dev_os.EXEC_FAILED
end

local function manifest_path(ctx)
    local manifest = ctx.root .. "/.dev/tools.tsv"
    if fs.is_file(manifest) then
        return manifest
    end
    print("no .dev/tools.tsv")
end

---@class dev.cmd.tools.install.Opts
---@field dry_run boolean? whether to print the commands without running them
---@field force boolean? whether to reinstall what is already present
---@field group string? keep only the rows listing this group
---@field system boolean? whether to install the system packages, as root
---@field user boolean? whether to install into the user's home

---Install the manifest's tools, through the package driver.
---@param opts dev.cmd.tools.install.Opts the flags
---@param tools string[] the tools to install, empty for every tool of the manifest
---@param ctx dev.Ctx the command's context
---@return integer code the driver's exit code, or 0 with no manifest
function M.install(opts, tools, ctx)
    if opts.system and opts.user then
        dev_command.usage_error(ctx, "--system and --user cannot be combined")
    end
    local scope = (opts.system and Scope.SYSTEM) or (opts.user and Scope.USER) or nil
    local manifest = manifest_path(ctx)
    if not manifest then
        return 0
    end
    local is_root = dev_os.getuid() == 0
    if not scope and is_root then
        dev_command.usage_error(ctx, "as root, pass --system")
    end
    if scope == Scope.SYSTEM and not is_root and dev_os.name() ~= "Darwin" then
        return fail("tools install --system installs packages and needs root, run it as root")
    end
    if scope == Scope.USER and is_root then
        return fail("tools install --user installs into the user's home and refuses to run as root")
    end
    local args = {}
    if opts.dry_run then
        args[#args + 1] = "--dry-run"
    end
    if opts.force then
        args[#args + 1] = "--force"
    end
    if opts.group then
        args[#args + 1] = "--group"
        args[#args + 1] = opts.group
    end
    if scope then
        args[#args + 1] = "--scope"
        args[#args + 1] = scope
    end
    for _, name in ipairs(tools) do
        args[#args + 1] = name
    end
    return run_driver(ctx, "install", manifest, args)
end

---Report which of the manifest's tools are on PATH.
---@param opts { group: string? } the flags
---@param ctx dev.Ctx the command's context
---@return integer code the driver's exit code, or 0 with no manifest
function M.check(opts, ctx)
    local args = {}
    if opts.group then
        args[#args + 1] = "--group"
        args[#args + 1] = opts.group
    end
    local manifest = manifest_path(ctx)
    if not manifest then
        return 0
    end
    return run_driver(ctx, "check", manifest, args)
end

return M
