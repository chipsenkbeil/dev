local devos = require("dev.os")
local fs = require("dev.fs")

local stdout, stderr = io.stdout, io.stderr

local TAG = '"tag_name"%s*:%s*"([^"]*)"'
local ARCH_NAMES = { x86_64 = "x86_64", amd64 = "x86_64", aarch64 = "arm64", arm64 = "arm64" }
local OS_NAMES = { Linux = "linux", Darwin = "darwin" }
local LATEST_SECS = "30"
local STOPPED = "install stopped"

---@class dev.release.Session
---@field tool string the installer's name, as its messages show it
---@field dry_run boolean whether steps are printed instead of run
---@field version string the version asked for, empty for the latest
---@field private __tmp string? the scratch directory, made on first use
---@field private __message string? why the installer stopped
local Session = {}
Session.__index = Session

---@class dev.release
local M = {}

---Stop the installer with `  ! install-<tool>: <message>` and exit 1.
---@param message string why it stopped
function Session:die(message)
    self.__message = message
    error(STOPPED, 0)
end

---Stop unless every named binary is on PATH.
---@param ... string the binaries
function Session:need(...)
    for i = 1, select("#", ...) do
        local name = select(i, ...)
        if not devos.which(name) then
            self:die(name .. " required")
        end
    end
end

---Make the scratch directory on first use and return it. It is removed when the installer ends.
---@return string path the directory
function Session:tmp()
    if not self.__tmp then
        local path = fs.mktemp({ dir = true, prefix = "install-" .. self.tool })
        if not path then
            self:die("cannot make a temporary directory")
        end
        self.__tmp = path
    end
    return self.__tmp
end

---Run `argv`, or print it when the session is a dry run. A command that fails stops the installer.
---@param argv string[] the command
---@param cwd string? the directory to run it in
function Session:step(argv, cwd)
    if self.dry_run then
        local line = devos.command(argv)
        stdout:write(
            "  + (dry-run): ",
            cwd and ("cd " .. devos.quote(cwd) .. " && " .. line) or line,
            "\n"
        )
        return
    end
    local code = devos.run(argv, { cwd = cwd })
    if code ~= 0 then
        self:die(argv[1] .. " failed (exit " .. tostring(code) .. ")")
    end
end

---Name the release asset's platform for this machine.
---@param arches table<string, string> the asset's name for `x86_64` and `arm64`
---@return string os `linux` or `darwin`
---@return string arch the asset's architecture name
function Session:platform(arches)
    local system = devos.capture({ "uname", "-s" }):gsub("%s+$", "")
    local os_name = OS_NAMES[system]
    if not os_name then
        self:die("unsupported OS " .. system .. "; use brew on macOS or the AUR on Arch")
    end
    local machine = devos.capture({ "uname", "-m" }):gsub("%s+$", "")
    local arch = ARCH_NAMES[machine]
    if not arch then
        self:die("unsupported architecture " .. machine)
    end
    return os_name, arches[arch]
end

---Resolve the version to install, asking GitHub for the latest release when none was given.
---@param repo string the GitHub `owner/name`
---@return string tag the release tag
---@return string bare the tag without a leading `v`
function Session:resolve(repo)
    local tag = self.version
    if tag == "" then
        local url = "https://api.github.com/repos/" .. repo .. "/releases/latest"
        local body = devos.capture({ "curl", "-fsSL", "--max-time", LATEST_SECS, url })
        tag = body:match(TAG) or ""
        if tag == "" then
            self:die("could not determine the latest release tag")
        end
    end
    return tag, (tag:gsub("^v", ""))
end

---Tell whether `bin` runs and reports `version`.
---@param bin string path of the installed binary
---@param version string the bare version wanted
---@return boolean current whether it is already at that version
function Session:is_at(bin, version)
    if not fs.is_exec(bin) then
        return false
    end
    local out = devos.capture({ bin, "--version" }, { stderr = "null" })
    return out:gsub("%s+$", "") == version
end

---Read an environment variable, with `default` when it is unset or empty.
---@param name string the variable
---@param default string the value when it has none
---@return string value the variable or the default
function M.env(name, default)
    local value = os.getenv(name)
    if value == nil or value == "" then
        return default
    end
    return value
end

---Warn on standard error when `dir` is not on PATH.
---@param dir string the directory a binary went to
function M.warn_path(dir)
    for entry in (os.getenv("PATH") or ""):gmatch("[^:]+") do
        if entry == dir then
            return
        end
    end
    stderr:write("  ! ", dir, " is not on PATH\n")
end

---Run an installer: parse `[--dry-run] [version]`, call `body`, clean up and return the exit code.
---
---A `Session:die` or a failed step prints `  ! install-<tool>: <message>` and returns 1.
---@param tool string the installer's name
---@param args string[] the command line
---@param body fun(session: dev.release.Session): integer? the installer, returning an exit code or nothing for 0
---@return integer code the exit code
function M.main(tool, args, body)
    local first = 1
    local session = setmetatable({ tool = tool, dry_run = false, version = "" }, Session)
    if args[1] == "--dry-run" then
        session.dry_run = true
        first = 2
    end
    session.version = args[first] or ""
    local ok, result = pcall(body, session)
    if session.__tmp then
        fs.remove(session.__tmp, { recursive = true })
    end
    if ok then
        return result or 0
    end
    if result == STOPPED then
        stderr:write("  ! install-", tool, ": ", session.__message, "\n")
        return 1
    end
    error(result, 0)
end

return M
