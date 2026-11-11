local dev_os = require("dev.os")
local fs = require("dev.fs")
local kinds = require("dev.pkg.kinds")
local lib = require("dev.pkg.lib")

local stdout, stderr = io.stdout, io.stderr
local Channel = kinds.Channel

local DEFAULT_BUILD_USER = "aurbuild"
local SUDOERS_DIR = "/etc/sudoers.d"
local AUR_URL = "https://aur.archlinux.org/"
local BUILD_PREREQUISITES = { "pacman", "-S", "--needed", "--noconfirm", "base-devel", "git" }
local GUARDED_BUILD =
    [[s=$1; trap 'rm -f -- "$s"; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null' EXIT INT TERM HUP
(umask 077; printf '%s\n' "$2" >"$s") && chmod 0440 "$s" || exit 1
shift 2
"$@" & pid=$!
wait "$pid"]]

---@class dev.pkg.pacman
local M = {}

---@class dev.pkg.pacman.Build
---@field opts dev.pkg.DriverOpts the flags
---@field tmp string the directory the AUR repo is cloned into

local function build_user()
    local user = os.getenv("AUR_BUILD_USER")
    return user ~= nil and user ~= "" and user or DEFAULT_BUILD_USER
end

local function aur_url(row)
    return AUR_URL .. row.package .. ".git"
end

---Print whether a tool is present, as a line starting `[x]`, `[~]` or `[ ]`.
---@param row dev.pkg.Row the tool
---@return integer code 0 when present
function M.check(row)
    return lib.report(row, {
        registered = function()
            return lib.succeeds({ "pacman", "-Q", "--", row.package })
        end,
    })
end

---Wrap a build so the sudoers drop-in exists only while it runs.
---
---The wrapper sets its trap, writes the drop-in with mode 0440, runs the build and removes the
---drop-in on exit and on `INT`, `TERM` and `HUP`, stopping the build too. The path and the line
---reach it as arguments, never inside its script.
---@param sudoers string the drop-in's path
---@param line string the drop-in's content
---@param build string[] the build command
---@return string[] argv the wrapped command
function M.guarded_build(sudoers, line, build)
    return { "sh", "-c", GUARDED_BUILD, "sh", sudoers, line, unpack(build) }
end

local function prepare_build_user(user, opts)
    if lib.succeeds({ "id", "-u", user }) then
        return true
    end
    if lib.run({ "useradd", "-m", "-s", "/bin/bash", user }, opts) ~= 0 then
        stderr:write("  ! could not create AUR build user ", user, "\n")
        return false
    end
    return true
end

local function build_as_root(row, build)
    local user = build_user()
    local url = aur_url(row)
    local dir = build.tmp .. "/" .. row.package
    if not prepare_build_user(user, build.opts) then
        return false
    end
    dev_os.run({ "chown", "-R", user, build.tmp })
    local clone = { "sudo", "-u", user, "git", "clone", "--depth", "1", url, dir }
    if lib.run(clone, build.opts) ~= 0 then
        stderr:write("  ! ", row.name, ": could not clone ", url, "\n")
        return false
    end
    fs.mkdir(SUDOERS_DIR, { parents = true })
    local guarded = M.guarded_build(
        SUDOERS_DIR .. "/99-" .. user,
        user .. " ALL=(root) NOPASSWD: /usr/bin/pacman",
        { "sudo", "-u", user, "makepkg", "-si", "--noconfirm" }
    )
    if lib.run(guarded, { log_file = build.opts.log_file, cwd = dir }) ~= 0 then
        stderr:write("  ! ", row.name, ": makepkg failed\n")
        return false
    end
    return true
end

local function build_as_user(row, build)
    local url = aur_url(row)
    local dir = build.tmp .. "/" .. row.package
    if lib.run({ "git", "clone", "--depth", "1", url, dir }, build.opts) ~= 0 then
        stderr:write("  ! ", row.name, ": could not clone ", url, "\n")
        return false
    end
    local makepkg = { "makepkg", "-si", "--noconfirm" }
    if lib.run(makepkg, { log_file = build.opts.log_file, cwd = dir }) ~= 0 then
        stderr:write("  ! ", row.name, ": makepkg failed\n")
        return false
    end
    return true
end

local function install_from_aur(row, opts)
    if lib.run(lib.privileged(BUILD_PREREQUISITES), opts) ~= 0 then
        stderr:write("  ! ", row.name, ": could not install AUR build prerequisites\n")
        return 1
    end
    local tmp = fs.mktemp({ dir = true })
    if not tmp then
        return 1
    end
    local build = { opts = opts, tmp = tmp }
    local built
    if dev_os.getuid() == 0 then
        built = build_as_root(row, build)
    else
        built = build_as_user(row, build)
    end
    fs.remove(tmp, { recursive = true })
    return built and 0 or 1
end

local function aur_plan(row)
    local as_root = dev_os.getuid() == 0 and ", as " .. build_user() or ""
    return {
        lib.privileged_line(BUILD_PREREQUISITES),
        "git clone --depth 1 " .. aur_url(row) .. " <tmp>",
        "makepkg -si --noconfirm   (in <tmp>" .. as_root .. ")",
    }
end

local function install_bare(row, opts, needed)
    local cmd = { "pacman", "-S", unpack(needed) }
    for _, word in ipairs({ "--noconfirm", "--", row.package }) do
        cmd[#cmd + 1] = word
    end
    if opts.dry_run then
        return lib.dry_run(row, { lib.privileged_line(cmd) })
    end
    stdout:write("  + installing ", row.name, "...\n")
    if lib.run(lib.privileged(cmd), opts) ~= 0 then
        return lib.failed(row, lib.privileged_line(cmd))
    end
    return 0
end

---Install a tool with pacman, or from the AUR with makepkg for an `aur:` cell.
---@param row dev.pkg.Row the tool
---@param opts dev.pkg.DriverOpts the flags
---@return integer code 0 on success
function M.install(row, opts)
    local needed = { "--needed" }
    if opts.force then
        needed = {}
    elseif lib.skip_on_path(row) then
        return 0
    elseif lib.succeeds({ "pacman", "-Q", row.package }) then
        return lib.skip(row, "already installed via pacman")
    end
    if row.channel == Channel.BARE then
        return install_bare(row, opts, needed)
    elseif row.channel == Channel.AUR then
        if opts.dry_run then
            return lib.dry_run(row, aur_plan(row))
        end
        stdout:write("  + installing ", row.name, " from the AUR...\n")
        return install_from_aur(row, opts)
    end
    stderr:write("  ! ", row.name, ': unknown pacman channel "', row.channel, '", skipping\n')
    return 1
end

return M
