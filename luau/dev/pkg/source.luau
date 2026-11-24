local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local release = require("@dev/release")
local pins = require("@dev/pkg/release")

local stdout = dev_os.stdout

local DEFAULT_PINS = ".dev/releases.tsv"

---@class dev.pkg.source.Spec
---@field tool string the pin's name, also what the installer is called in messages
---@field binary string the command the build puts in the prefix's `bin`
---@field needs string[] the commands that must be on PATH
---@field build fun(prefix: string): string[][] the commands that build and install, run in the
---   source directory

---@class dev.pkg.source
local M = {}

local function prefix()
    local given = release.env("DEV_TOOLS_PREFIX", "")
    if given ~= "" then
        return given
    end
    local home = dev_os.getenv("HOME")
    if home == nil or home == "" then
        return nil
    end
    return fs.join(home, ".local")
end

local function installed(spec, dir)
    local path = fs.join(dir, "bin", spec.binary)
    if fs.is_exec(path) then
        return path
    end
    return dev_os.which(spec.binary)
end

local function install(spec, session)
    local dir = prefix()
    if not dir then
        session:die("No prefix. Set DEV_TOOLS_PREFIX or HOME.")
    end
    if release.env("PKG_FORCE", "0") ~= "1" then
        local found = installed(spec, dir)
        if found then
            stdout:write("  = ", spec.tool, " already installed (", found, "), skipping\n")
            return 0
        end
    end
    session:need("tar", table.unpack(spec.needs))
    local file = release.env("PKG_RELEASES", DEFAULT_PINS)
    local all, err = pins.read(file)
    if not all then
        session:die(err)
    end
    local pin = all[spec.tool]
    if not pin then
        session:die(`No pin named {spec.tool} in {file}.`)
    end
    local root
    if session.dry_run then
        local lines, source = pins.plan(pin)
        for _, line in ipairs(lines) do
            stdout:write("  + (dry-run): ", line, "\n")
        end
        root = fs.dirname(source)
    else
        stdout:write("  + building ", spec.tool, " ", pin.version, " into ", dir, "\n")
        local found, _, reason, detail = pins.fetch(pin, session:tmp())
        if not found then
            session:die(pins.refusal(pin, reason, detail))
        end
        root = fs.dirname(found)
    end
    for _, argv in ipairs(spec.build(dir)) do
        session:step(argv, root)
    end
    return 0
end

---Run a source installer: `--check`, or `[--dry-run]` and an install into the prefix.
---
---The prefix is `DEV_TOOLS_PREFIX`, else `~/.local`, and the pin comes from `PKG_RELEASES`, else
---`.dev/releases.tsv`. `--check` exits 0 when the binary is in the prefix or on PATH. An install
---does nothing when it is there, unless `PKG_FORCE` is 1, downloads and verifies the pin's
---archive before extracting it, then runs the spec's build commands in the source directory.
---@param spec dev.pkg.source.Spec the tool
---@param args string[] the command line
---@return integer code the exit code
function M.main(spec, args)
    if args[1] == "--check" then
        local dir = prefix()
        local found = (if dir then installed(spec, dir) else nil) or dev_os.which(spec.binary)
        return if found then 0 else 1
    end
    return release.main(spec.tool, args, function(session)
        return install(spec, session)
    end)
end

return M
