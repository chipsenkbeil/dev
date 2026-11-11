local dev_os = require("dev.os")
local kinds = require("dev.pkg.kinds")

local stdout, stderr = io.stdout, io.stderr
local Channel, NO_PROBE_BINARY = kinds.Channel, kinds.NO_PROBE_BINARY

local PACKAGE_WORD = "^[A-Za-z0-9@._+][A-Za-z0-9@._+%-]*$"
local REPO_WORD = "^[A-Za-z0-9._][A-Za-z0-9._%-]*/[A-Za-z0-9._%-]+$"
local UNAVAILABLE_CELL = "-"

---@class dev.pkg.Cell
---@field channel string the part before the first colon of the head
---@field package string the package name, or a script's source and arguments
---@field repo string the `repo:` part
---@field bin string the `bin:` part

---@class dev.pkg.Row
---@field name string the tool's name
---@field binary string the command to probe, `-` for none
---@field package string the cell's package
---@field channel string the cell's channel
---@field repo string the cell's repo

---@class dev.pkg.DriverOpts
---@field dry_run boolean whether to print the commands without running them
---@field force boolean whether to reinstall what is present
---@field log_file string the file the commands' output is appended to, empty for the terminal
---@field interpreter string the luajit that runs the driver, which runs `.lua` scripts
---@field modules string absolute path of the directory holding dev's modules
---@field releases string path of the pins file `release:` rows read

---@class dev.pkg.lib
local M = {}

---Split a manager cell into its channel, package, repo and binary.
---@param cell string `[channel:]package[,repo:owner/project][,bin:override]`
---@return dev.pkg.Cell? parsed the parts, nil for the `-` cell that means not available here
function M.parse_cell(cell)
    if cell == UNAVAILABLE_CELL then
        return nil
    end
    local head = cell:match("^[^,]*")
    local parsed = { channel = Channel.BARE, package = head, repo = "", bin = "" }
    local colon = head:find(":", 1, true)
    if colon then
        parsed.channel = head:sub(1, colon - 1)
        parsed.package = head:sub(colon + 1)
    end
    for seg in cell:sub(#head + 2):gmatch("[^,]+") do
        if seg:sub(1, 5) == "repo:" then
            parsed.repo = seg:sub(6)
        elseif seg:sub(1, 4) == "bin:" then
            parsed.bin = seg:sub(5)
        end
    end
    return parsed
end

---Say whether a cell's package and repo are plain words that cannot become an option.
---@param parsed dev.pkg.Cell the parsed cell
---@return boolean valid true for a script cell, which is a path or URL, and for plain words
function M.valid_package(parsed)
    if parsed.channel == Channel.SCRIPT then
        return true
    end
    if not parsed.package:find(PACKAGE_WORD) then
        return false
    end
    return parsed.repo == "" or parsed.repo:find(REPO_WORD) ~= nil
end

local FAILURE_TAIL_LINES = 20

---@type { path: string, from: integer }?
local pending_failure

local function log_size(path)
    local file = io.open(path, "rb")
    if not file then
        return 0
    end
    local size = file:seek("end")
    file:close()
    return size
end

local function print_tail(path, from)
    local file = io.open(path, "rb")
    if not file then
        return
    end
    file:seek("set", from)
    local text = file:read("*a")
    file:close()
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    for i = math.max(1, #lines - FAILURE_TAIL_LINES + 1), #lines do
        stderr:write("      ", lines[i], "\n")
    end
end

---Run a command, appending its output to the log file when there is one.
---
---A failing command with a log file is remembered, and `flush_failure` prints the tail of its
---output.
---@param argv string[] the command and its arguments
---@param opts { log_file: string?, env: table<string,string>?, cwd: string? }? the log file,
---   environment and directory
---@return integer? code the command's exit status
function M.run(argv, opts)
    opts = opts or {}
    local run_opts = { env = opts.env, cwd = opts.cwd }
    local logged = opts.log_file and opts.log_file ~= ""
    local from = 0
    if logged then
        run_opts.stdout = opts.log_file
        run_opts.stderr = "stdout"
        from = log_size(opts.log_file)
    end
    local code = dev_os.run(argv, run_opts)
    pending_failure = nil
    if logged and code ~= 0 then
        pending_failure = { path = opts.log_file, from = from }
    end
    return code
end

---Print the last lines of the output of the most recent failed command, once.
function M.flush_failure()
    local failure = pending_failure
    pending_failure = nil
    if failure then
        print_tail(failure.path, failure.from)
    end
end

---Find the binary to probe on PATH.
---@param binary string the binary, `-` for none
---@return string? path where it is, nil when there is no binary or it is not on PATH
function M.on_path(binary)
    if binary == NO_PROBE_BINARY then
        return nil
    end
    return dev_os.which(binary)
end

---Say whether a command exits 0 with its output thrown away.
---@param argv string[] the command and its arguments
---@return boolean ok whether it exits 0
function M.succeeds(argv)
    return dev_os.run(argv, { stdin = "null", stdout = "null", stderr = "null" }) == 0
end

---Prefix a command with sudo unless this process is root.
---@param argv string[] the command and its arguments
---@return string[] argv the command, behind sudo for a user
function M.privileged(argv)
    if dev_os.getuid() == 0 then
        return argv
    end
    return { "sudo", unpack(argv) }
end

---Join a command into the text a dry run and a failure message print.
---@param argv string[] the command and its arguments
---@return string line the words joined by spaces
function M.line(argv)
    return table.concat(argv, " ")
end

---Join a privileged command, with the sudo prefix a user gets, into the text a dry run prints.
---
---Root gets no sudo, and its line starts with a space.
---@param argv string[] the command without sudo
---@return string line the words joined by spaces
function M.privileged_line(argv)
    if dev_os.getuid() == 0 then
        return " " .. M.line(argv)
    end
    return M.line(M.privileged(argv))
end

---@class dev.pkg.Probes
---@field registered fun(): boolean whether the manager's registry has the package
---@field elsewhere (fun(): string?)? where else the tool is, tried last

---Print a status line for a tool found on PATH or in the manager's registry.
---@param row dev.pkg.Row the tool
---@param probes dev.pkg.Probes how to find it beyond PATH
---@return integer code 0 when the tool is present
function M.report(row, probes)
    local path = M.on_path(row.binary)
    if path then
        stdout:write("[x] ", row.name, "\t(", path, ")\n")
        return 0
    end
    if probes.registered() then
        if row.binary == NO_PROBE_BINARY then
            stdout:write("[x] ", row.name, "\t(installed)\n")
        else
            stdout:write("[~] ", row.name, "\t(installed, not on PATH)\n")
        end
        return 0
    end
    path = probes.elsewhere and probes.elsewhere()
    if path then
        stdout:write("[x] ", row.name, "\t(", path, ")\n")
        return 0
    end
    stdout:write("[ ] ", row.name, "\n")
    return 1
end

---Print that a tool is skipped, and return the success code.
---@param row dev.pkg.Row the tool
---@param reason string why, such as `already on PATH`
---@return integer code 0
function M.skip(row, reason)
    stdout:write("  = ", row.name, " ", reason, ", skipping\n")
    return 0
end

---Skip a tool whose binary is on PATH.
---@param row dev.pkg.Row the tool
---@return boolean skipped whether it was on PATH and the skip line was printed
function M.skip_on_path(row)
    if M.on_path(row.binary) then
        M.skip(row, "already on PATH")
        return true
    end
    return false
end

---Print a dry run's plan for a tool, and return the success code.
---@param row dev.pkg.Row the tool
---@param lines string[] the commands the run would make
---@return integer code 0
function M.dry_run(row, lines)
    stdout:write("  + ", row.name, " (dry-run):\n")
    for _, line in ipairs(lines) do
        stdout:write("      ", line, "\n")
    end
    return 0
end

---Print that a command failed, and return the failure code.
---@param row dev.pkg.Row the tool
---@param line string the command as `line` printed it
---@return integer code 1
function M.failed(row, line)
    stderr:write("  ! ", row.name, ': "', line, '" failed\n')
    M.flush_failure()
    return 1
end

return M
