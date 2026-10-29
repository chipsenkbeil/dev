local devos = require("dev.os")
local fs = require("dev.fs")
local kinds = require("dev.pkg.kinds")
local manifest = require("dev.pkg.manifest")
local lib = require("dev.pkg.lib")
local release = require("dev.pkg.release")
local script = require("dev.pkg.script")

local stdout, stderr = io.stdout, io.stderr
local Channel, Scope, NO_PROBE_BINARY = kinds.Channel, kinds.Scope, kinds.NO_PROBE_BINARY
local parse_cell, valid_package = lib.parse_cell, lib.valid_package

local USAGE = "usage: pkg.lua check [--manifest FILE] [--group NAME]\n"
    .. "       pkg.lua install [--manifest FILE] [--dry-run] [--force] [--group NAME]"
    .. " [--scope system|user] [--log-file FILE] [name...]\n"
local SHELL_SPECIAL = "[ \t\n!\"$&'()*;<>?%[\\%]^`{|}]"

---@class dev.pkg.Opts
---@field manifest string path of the manifest
---@field interpreter string the luajit that runs the driver, which runs `.lua` scripts
---@field modules string absolute path of the directory holding dev's modules
---@field group string? keep only the rows listing this group, an unknown group when empty
---@field scope dev.pkg.Scope? install only the rows of this scope
---@field dry_run boolean whether to print the commands without running them
---@field force boolean whether to reinstall what is already present
---@field log_file string the file the drivers append their commands' output to, empty for the terminal
---@field names string[] install only these tools, every tool when empty

---@class dev.pkg.InstallState
---@field opts dev.pkg.Opts the run's options
---@field manager dev.pkg.Manager the primary manager of this OS
---@field failed string[] the names of the rows that failed
---@field third_party string[] the rows skipped for a system run

---@class dev.pkg
local M = {}

local function shell_quote(text)
    if text == "" then
        return "''"
    end
    if text:find("[%c\127]") then
        local escaped = text:gsub("[\\']", "\\%0"):gsub("[%c\127]", function(char)
            if char == "\n" then
                return "\\n"
            elseif char == "\t" then
                return "\\t"
            end
            return string.format("\\%03o", char:byte())
        end)
        return "$'" .. escaped .. "'"
    end
    local quoted = text:gsub(SHELL_SPECIAL, "\\%0")
    if quoted:find("^[#~]") then
        quoted = "\\" .. quoted
    end
    return quoted
end

local function printable(name)
    return (name:gsub("%z", "\\0"))
end

local function refusal(row, parsed)
    for _, text in ipairs({ row.name, row.binary, row.cell }) do
        if text:find("\0", 1, true) then
            return shell_quote(row.name .. " " .. row.binary .. " " .. row.cell)
        end
    end
    if not valid_package(parsed) then
        return shell_quote(parsed.package .. " " .. parsed.repo)
    end
end

local function detect_manager()
    local system = devos.capture({ "uname" }):gsub("\n+$", "")
    if system == "Darwin" then
        return kinds.Manager.BREW
    elseif system == "Linux" then
        for _, candidate in ipairs(kinds.LINUX_MANAGERS) do
            if devos.which(candidate.binary) then
                return candidate.manager
            end
        end
    end
end

local function load_rows(opts, manager)
    local text = fs.read(opts.manifest)
    local rows = text and manifest.parse(text)
    local column = rows and manifest.column(rows, manager)
    if not column then
        stderr:write(
            'error: manager column "',
            manager,
            '" not found in ',
            opts.manifest,
            " header\n"
        )
        return nil
    end
    return rows, column
end

local function select_rows(rows, select_opts)
    local selected, err = manifest.select(rows, select_opts)
    if not selected then
        stderr:write(err, "\n")
    end
    return selected
end

local function driver_opts(opts)
    return {
        dry_run = opts.dry_run,
        force = opts.force,
        log_file = opts.log_file,
        interpreter = opts.interpreter,
        modules = opts.modules,
        releases = fs.join(fs.dirname(opts.manifest), "releases.tsv"),
    }
end

local function load_driver(name)
    if kinds.DRIVERS[name] then
        return require("dev.pkg." .. name)
    end
    stderr:write("error: no driver ", name, "\n")
end

local function check_script_row(opts, name, package)
    if package:find("^https?://") then
        stdout:write("[?] ", name, "\t(remote script, no probe)\n")
        return true
    elseif devos.getuid() == 0 then
        stdout:write("[?] ", name, "\t(script row, never run as root)\n")
        return true
    elseif script.probe(package, driver_opts(opts)) then
        stdout:write("[x] ", name, "\t(script --check)\n")
        return true
    end
    stdout:write("[ ] ", name, "\n")
    return false
end

local function check_row(opts, driver, row)
    local parsed = parse_cell(row.cell)
    if not parsed then
        return true
    end
    local name = printable(row.name)
    local refused = refusal(row, parsed)
    if refused then
        stdout:write(
            "[ ] ",
            name,
            "\t(refusing the package or repo ",
            refused,
            " in the manifest)\n"
        )
        return false
    end
    local binary = parsed.bin ~= "" and parsed.bin or row.binary
    if parsed.channel == Channel.SCRIPT and binary == NO_PROBE_BINARY then
        return check_script_row(opts, name, parsed.package)
    end
    if parsed.channel == Channel.RELEASE then
        driver = release
    end
    return driver.check({
        name = row.name,
        binary = binary,
        package = parsed.package,
        channel = parsed.channel,
        repo = parsed.repo,
    }) == 0
end

---Report which of the manifest's tools are present.
---@param opts dev.pkg.Opts the manifest, the drivers' directory and the group
---@return integer code 0 with every tool present, 1 with one missing or the manifest unusable, 2 for an unknown group
function M.check(opts)
    local manager = detect_manager()
    if not manager then
        stderr:write("error: no supported package manager detected on this OS\n")
        return 1
    end
    local driver = load_driver(manager)
    if not driver then
        return 1
    end
    local rows, column = load_rows(opts, manager)
    if not rows then
        return 1
    end
    local selected = select_rows(rows, { column = column, group = opts.group })
    if not selected then
        return 1
    end
    if opts.group ~= nil and (opts.group == "" or #selected == 0) then
        stderr:write("unknown group: ", opts.group, "\n")
        return 2
    end
    local missing = false
    for _, row in ipairs(selected) do
        missing = not check_row(opts, driver, row) or missing
    end
    return missing and 1 or 0
end

local function names_of(rows)
    local names = {}
    for _, row in ipairs(rows) do
        names[row.name] = true
    end
    return names
end

local function wants(names, name)
    if #names == 0 then
        return true
    end
    for _, wanted in ipairs(names) do
        if wanted == name then
            return true
        end
    end
    return false
end

local function skipped_by_scope(scope, row_scope)
    return (scope == Scope.SYSTEM and row_scope == Scope.USER)
        or (scope == Scope.USER and row_scope ~= Scope.USER)
end

local function install_row(state, row)
    local opts = state.opts
    local parsed = parse_cell(row.cell)
    if not parsed then
        return
    end
    local row_scope, handler = kinds.route(parsed.channel, state.manager)
    if skipped_by_scope(opts.scope, row_scope) then
        return
    end
    local name = printable(row.name)
    if opts.scope == Scope.SYSTEM and row_scope == Scope.THIRD_PARTY then
        state.third_party[#state.third_party + 1] = name .. " (" .. parsed.channel .. ":)"
        return
    end
    local refused = refusal(row, parsed)
    if refused then
        stderr:write("  ! ", name, ": refusing the package or repo ", refused, " in the manifest\n")
        state.failed[#state.failed + 1] = name
        return
    end
    local driver = load_driver(handler)
    if not driver then
        state.failed[#state.failed + 1] = name
        return
    end
    local status = driver.install({
        name = row.name,
        binary = parsed.bin ~= "" and parsed.bin or row.binary,
        package = parsed.package,
        channel = parsed.channel,
        repo = parsed.repo,
    }, driver_opts(opts))
    if status ~= 0 then
        state.failed[#state.failed + 1] = name
    end
end

---Install the manifest's tools.
---@param opts dev.pkg.Opts the manifest, the drivers' directory, the group, the scope and the flags
---@return integer code 0 on success, 1 with a failed tool or an unusable manifest, 2 for an unknown group or tool
function M.install(opts)
    local manager = detect_manager()
    if not manager then
        stderr:write("error: no supported package manager detected on this OS\n")
        return 1
    end
    local all_rows, column = load_rows(opts, manager)
    if not all_rows then
        return 1
    end
    local all = select_rows(all_rows, { column = column })
    if not all then
        return 1
    end
    local rows = all
    if opts.group ~= nil then
        rows = {}
        if opts.group ~= "" then
            rows = select_rows(all_rows, { column = column, group = opts.group })
        end
        if not rows or #rows == 0 then
            stderr:write("unknown group: ", opts.group, "\n")
            return 2
        end
    end
    if #rows == 0 then
        return 0
    end
    local in_rows, in_all = names_of(rows), names_of(all)
    for _, name in ipairs(opts.names) do
        if not in_rows[name] then
            if in_all[name] then
                stderr:write("tool ", name, " is not in group ", opts.group, "\n")
            else
                stderr:write("unknown tool: ", name, "\n")
            end
            return 2
        end
    end

    local state = { opts = opts, manager = manager, failed = {}, third_party = {} }
    for _, row in ipairs(rows) do
        if wants(opts.names, row.name) then
            install_row(state, row)
        end
    end
    if #state.third_party > 0 then
        stdout:write(
            "skipped third-party rows (built into the image, not installed with root): ",
            table.concat(state.third_party, " "),
            "\n"
        )
    end
    if #state.failed > 0 then
        stderr:write("install failed: ", table.concat(state.failed, " "), "\n")
        return 1
    end
    return 0
end

local function need_value(args, i)
    if i + 1 > #args then
        stderr:write(args[i], " needs a value\n")
        return false
    end
    return true
end

local function parse_check(args, opts)
    local i = 1
    while i <= #args do
        if args[i] == "--manifest" or args[i] == "--group" then
            if not need_value(args, i) then
                return false
            end
            opts[args[i] == "--manifest" and "manifest" or "group"] = args[i + 1]
            i = i + 2
        else
            stderr:write("unknown arg: ", args[i], "\n")
            return false
        end
    end
    return true
end

local function parse_install(args, opts)
    local i = 1
    while i <= #args do
        local arg = args[i]
        if arg == "--dry-run" then
            opts.dry_run = true
            i = i + 1
        elseif arg == "--force" then
            opts.force = true
            i = i + 1
        elseif
            arg == "--manifest"
            or arg == "--group"
            or arg == "--scope"
            or arg == "--log-file"
        then
            if not need_value(args, i) then
                return false
            end
            local value = args[i + 1]
            if arg == "--scope" and value ~= Scope.SYSTEM and value ~= Scope.USER then
                stderr:write("--scope takes system or user, got ", value, "\n")
                return false
            end
            local key = arg:sub(3):gsub("%-", "_")
            opts[key] = value
            i = i + 2
        elseif arg:sub(1, 1) == "-" then
            stderr:write("unknown arg: ", arg, "\n")
            return false
        else
            opts.names[#opts.names + 1] = arg
            i = i + 1
        end
    end
    if opts.force and #opts.names == 0 then
        stderr:write("--force needs at least one tool name\n")
        return false
    end
    return true
end

---Run `check` or `install` from a command line.
---@param argv string[] the arguments after the program name, starting with the subcommand
---@param defaults { interpreter: string, modules: string, manifest: string } the luajit that runs the driver, dev's module directory and the manifest used without `--manifest`
---@return integer code the exit code
function M.main(argv, defaults)
    local sub = argv[1]
    local args = { unpack(argv, 2) }
    local opts = {
        manifest = defaults.manifest,
        interpreter = defaults.interpreter,
        modules = defaults.modules,
        dry_run = false,
        force = false,
        log_file = "",
        names = {},
    }
    if sub == nil or sub == "" or sub == "-h" or sub == "--help" then
        stdout:write(USAGE)
        return 0
    elseif sub == "check" then
        return parse_check(args, opts) and M.check(opts) or 2
    elseif sub == "install" then
        return parse_install(args, opts) and M.install(opts) or 2
    end
    stderr:write("unknown subcommand: ", sub, "\n")
    stdout:write(USAGE)
    return 2
end

return M
