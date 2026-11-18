local dev_os = require("dev.os")
local fs = require("dev.fs")
local lib = require("dev.pkg.lib")
local note = require("dev.verb").note

local stdout = io.stdout

local LUA_SUFFIX = "%.lua$"
local URL = "^https?://"

---@class dev.pkg.script
local M = {}

---@class dev.pkg.script.Cell
---@field source string the script's path or URL
---@field args string[] the arguments after it

local function split(package)
    local source = package:match("^[^ ]*")
    local args = {}
    for word in package:sub(#source + 2):gmatch("[^ \t\n]+") do
        args[#args + 1] = word
    end
    return { source = source, args = args }
end

local function runner(cell, opts)
    if cell.source:find(LUA_SUFFIX) then
        return opts.interpreter, "luajit"
    end
    return "bash", "bash"
end

---@param run { force: boolean } whether the script is told to reinstall
local function script_env(cell, opts, run)
    local env = { PKG_FORCE = run.force and "1" or "0", PKG_RELEASES = opts.releases }
    if cell.source:find(LUA_SUFFIX) then
        env.LUA_PATH = opts.modules .. "/?.lua"
    end
    return env
end

local function tail(cell)
    return #cell.args > 0 and " " .. table.concat(cell.args, " ") or ""
end

local function command(exec, path, cell)
    local argv = { exec, path }
    for _, arg in ipairs(cell.args) do
        argv[#argv + 1] = arg
    end
    return argv
end

---Run a script row's script with `--check` and say whether it exits 0.
---
---A `.lua` source runs under luajit and any other under bash, with no input and no output.
---@param package string the cell's script path and arguments
---@param opts dev.pkg.driver.install.Opts the interpreter and module directory
---@return boolean present whether the script exited 0
function M.probe(package, opts)
    local cell = split(package)
    local exec = runner(cell, opts)
    local argv = command(exec, cell.source, cell)
    argv[#argv + 1] = "--check"
    return dev_os.run(argv, {
        env = script_env(cell, opts, { force = false }),
        stdin = "null",
        stdout = "null",
        stderr = "null",
    }) == 0
end

local function install_remote(row, opts, cell)
    local exec, shown = runner(cell, opts)
    local suffix = cell.source:find(LUA_SUFFIX) and "lua" or "sh"
    local target = "/tmp/" .. row.name .. "-install." .. suffix
    if opts.dry_run then
        return lib.dry_run(row, {
            "curl -fsSL "
                .. cell.source
                .. " -o "
                .. target
                .. " && "
                .. shown
                .. " "
                .. target
                .. tail(cell),
        })
    end
    if not dev_os.which("curl") then
        note("  ! " .. row.name .. ": curl is required to fetch " .. cell.source)
        return 1
    end
    stdout:write("  + installing ", row.name, " (script: ", cell.source, ")...\n")
    local tmp = fs.mktemp()
    if not tmp then
        return 1
    end
    if lib.run({ "curl", "-fsSL", cell.source, "-o", tmp }, opts) ~= 0 then
        note("  ! " .. row.name .. ": failed to download " .. cell.source)
        fs.remove(tmp)
        return 1
    end
    local code = lib.run(command(exec, tmp, cell), {
        log_file = opts.log_file,
        env = script_env(cell, opts, { force = opts.force }),
    })
    fs.remove(tmp)
    return code or 1
end

---Run a `script:` cell's script unless its binary is on PATH.
---
---A source ending in `.lua` runs under luajit with dev's modules on `package.path`, any other
---under bash. A URL is downloaded to a temp file first, never piped to a shell. The arguments
---split on blanks and are never glob-expanded.
---@param row dev.pkg.Row the tool, with the source and arguments as its package
---@param opts dev.pkg.driver.install.Opts the flags
---@return integer code 0 on success
function M.install(row, opts)
    if not opts.force and lib.skip_on_path(row) then
        return 0
    end
    local cell = split(row.package)
    if cell.source:find(URL) then
        return install_remote(row, opts, cell)
    end
    local exec, shown = runner(cell, opts)
    if opts.dry_run then
        return lib.dry_run(row, { shown .. " " .. cell.source .. tail(cell) })
    end
    stdout:write("  + installing ", row.name, " (script: ", cell.source, ")...\n")
    return lib.run(command(exec, cell.source, cell), {
        log_file = opts.log_file,
        env = script_env(cell, opts, { force = opts.force }),
    }) or 1
end

return M
