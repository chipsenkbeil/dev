local dev_os = require("dev.os")
local fs = require("dev.fs")
local http = require("dev.http")
local lib = require("dev.pkg.lib")
local note = require("dev.command").note
local runtime = require("dev.runtime")

local stdout = dev_os.stdout

local LUA_SUFFIX = "%.luau?$"
local URL = "^https?://"
local FILE_URL = "^file:///"
local DOWNLOAD_SECONDS = 300

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

---Pick the words that run a script, ahead of its path.
---
---A `.lua` or `.luau` source runs under dev's own `-l`, and any other source under bash.
---@param cell dev.pkg.script.Cell the script's source and arguments
---@return string[] exec the words ahead of the script's path
---@return string shown the same words as a dry run prints them
local function runner(cell)
    if cell.source:find(LUA_SUFFIX) then
        return { runtime.exe, "-l" }, "dev -l"
    end
    return { "bash" }, "bash"
end

---Build the environment a script runs in.
---@param opts dev.pkg.driver.install.Opts the flags, whose `releases` the script reads
---@param run { force: boolean } whether the script is told to reinstall
---@return table<string, string> env the variables the script gets
local function script_env(opts, run)
    return { PKG_FORCE = run.force and "1" or "0", PKG_RELEASES = opts.releases }
end

local function tail(cell)
    return #cell.args > 0 and " " .. table.concat(cell.args, " ") or ""
end

local function command(exec, path, cell)
    local argv = {}
    for _, word in ipairs(exec) do
        argv[#argv + 1] = word
    end
    argv[#argv + 1] = path
    for _, arg in ipairs(cell.args) do
        argv[#argv + 1] = arg
    end
    return argv
end

---Run a script row's script with `--check` and say whether it exits 0.
---
---It runs with no input and no output.
---@param package string the cell's script path and arguments
---@param opts dev.pkg.driver.install.Opts the flags
---@return boolean present whether the script exited 0
function M.probe(package, opts)
    local cell = split(package)
    local argv = command(runner(cell), cell.source, cell)
    argv[#argv + 1] = "--check"
    return dev_os.run(argv, {
        env = script_env(opts, { force = false }),
        stdin = "null",
        stdout = "null",
        stderr = "null",
    }) == 0
end

local function install_remote(row, opts, cell)
    local exec, shown = runner(cell)
    local suffix = cell.source:find(LUA_SUFFIX) and "lua" or "sh"
    local target = "/tmp/" .. row.name .. "-install." .. suffix
    if opts.dry_run then
        return lib.dry_run(row, {
            "download "
                .. cell.source
                .. " to "
                .. target
                .. " && "
                .. shown
                .. " "
                .. target
                .. tail(cell),
        })
    end
    stdout:write("  + installing ", row.name, " (script: ", cell.source, ")...\n")
    local tmp = fs.mktemp()
    if not tmp then
        return 1
    end
    local reply = http.download({ url = cell.source, path = tmp, timeout = DOWNLOAD_SECONDS })
    if not reply or reply.status < 200 or reply.status >= 300 then
        note("  ! " .. row.name .. ": failed to download " .. cell.source)
        fs.remove(tmp)
        return 1
    end
    local code = lib.run(command(exec, tmp, cell), {
        log_file = opts.log_file,
        env = script_env(opts, { force = opts.force }),
    })
    fs.remove(tmp)
    return code or 1
end

---Run a `script:` cell's script unless its binary is on PATH.
---
---A URL is downloaded to a temp file first, never piped to a shell. The arguments split on blanks
---and are never glob-expanded.
---@param row dev.pkg.Row the tool, with the source and arguments as its package
---@param opts dev.pkg.driver.install.Opts the flags
---@return integer code 0 on success
function M.install(row, opts)
    if not opts.force and lib.skip_on_path(row) then
        return 0
    end
    local cell = split(row.package)
    if cell.source:find(URL) or cell.source:find(FILE_URL) then
        return install_remote(row, opts, cell)
    end
    local exec, shown = runner(cell)
    if opts.dry_run then
        return lib.dry_run(row, { shown .. " " .. cell.source .. tail(cell) })
    end
    stdout:write("  + installing ", row.name, " (script: ", cell.source, ")...\n")
    return lib.run(command(exec, cell.source, cell), {
        log_file = opts.log_file,
        env = script_env(opts, { force = opts.force }),
    }) or 1
end

return M
