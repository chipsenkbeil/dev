local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local lib = require("@dev/pkg/lib")

local stdout = dev_os.stdout

---@class dev.pkg.cargo
local M = {}

local function installed_crate(package)
    local out, code = dev_os.capture({ "cargo", "install", "--list" }, { stderr = "null" })
    if code ~= 0 then
        return false
    end
    local prefix = package .. " "
    for line in out:gmatch("[^\n]+") do
        if line:sub(1, #prefix) == prefix then
            return true
        end
    end
    return false
end

local function find_binstall()
    if dev_os.which("cargo-binstall") then
        return "cargo-binstall"
    end
    local home = dev_os.getenv("HOME")
    local fallback = home and home .. "/.cargo/bin/cargo-binstall"
    if fallback and fs.is_exec(fallback) then
        return fallback
    end
end

local function command(row, opts)
    local binstall = find_binstall()
    local cmd = { "cargo", "install", "--locked" }
    if binstall then
        cmd = { binstall, "--no-confirm", "--disable-telemetry", "--locked" }
    end
    if opts.force then
        cmd[#cmd + 1] = "--force"
    end
    cmd[#cmd + 1] = row.package
    return cmd
end

local function ensure_toolchain(opts)
    if dev_os.which("rustup") and not lib.succeeds({ "rustup", "show", "active-toolchain" }) then
        stdout:write("  + rustup has no default toolchain, installing stable\n")
        return lib.run({ "rustup", "default", "stable" }, opts) == 0
    end
    return true
end

---Install a crate with cargo-binstall when there is one, else `cargo install --locked`.
---@param row dev.pkg.Row the tool
---@param opts dev.pkg.driver.install.Opts the flags
---@return integer code 0 on success
function M.install(row, opts)
    if not opts.force then
        if lib.skip_on_path(row) then
            return 0
        elseif installed_crate(row.package) then
            return lib.skip(row, "already installed via cargo")
        end
    end
    local cmd = command(row, opts)
    if opts.dry_run then
        return lib.dry_run(row, { lib.line(cmd) })
    end
    if not ensure_toolchain(opts) then
        return 1
    end
    stdout:write("  + installing ", row.name, " (cargo)...\n")
    return lib.run(cmd, opts) or 1
end

return M
