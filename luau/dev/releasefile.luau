local dev_command = require("@dev/command")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local hash = require("@dev/hash")
local http = require("@dev/http")

local REPO = "chipsenkbeil/dev"
local CONNECT_TIMEOUT_SECONDS = 15
local MAX_TIME_SECONDS = 600

---The mode of a runnable file, 0755.
local EXECUTABLE_MODE = 493

local TRIPLES = {
    Linux = { x86_64 = "x86_64-unknown-linux-musl" },
    Darwin = { x86_64 = "x86_64-apple-darwin", aarch64 = "aarch64-apple-darwin" },
    freebsd = { x86_64 = "x86_64-unknown-freebsd" },
    Windows = { x86_64 = "x86_64-pc-windows-msvc" },
}

---@class dev.releasefile
---@field EXECUTABLE_MODE integer the mode of a runnable file
local M = { EXECUTABLE_MODE = EXECUTABLE_MODE }

local function set(name)
    local value = dev_os.getenv(name)
    if value == nil or value == "" then
        return nil
    end
    return value
end

local function repo()
    return set("GITHUB_REPOSITORY") or REPO
end

local function base_url(tag)
    return set("DEV_RELEASE_URL") or `https://github.com/{repo()}/releases/download/{tag}`
end

local function fetch(url, path)
    local reply = http.download({
        url = url,
        path = path,
        timeout = MAX_TIME_SECONDS,
        connect_timeout = CONNECT_TIMEOUT_SECONDS,
    })
    if reply == nil or reply.status < 200 or reply.status >= 300 then
        dev_command.die(`Could not download {url}.`)
    end
end

local function listed(sums, name)
    for line in (fs.read(sums) or ""):gmatch("[^\r\n]+") do
        local digest, file = line:match("^(%x+)%s+%*?(.+)$")
        if file == name then
            return digest:lower()
        end
    end
    dev_command.die(`SHA256SUMS does not list {name}.`)
end

---Give the address of the API call that names the latest release.
---@return string url `DEV_RELEASE_API` when set, else the GitHub latest release call
function M.api_url()
    return set("DEV_RELEASE_API") or `https://api.github.com/repos/{repo()}/releases/latest`
end

---Name the asset of a release that this machine runs.
---@param tag string the release tag
---@return string name the asset's file name
function M.asset_name(tag)
    local system, arch = dev_os.name(), dev_os.arch()
    local triple = TRIPLES[system] and TRIPLES[system][arch]
    if not triple then
        dev_command.die(`The release holds no binary for {system} on {arch}.`)
    end
    return `dev-{tag}-{triple}{if system == "Windows" then ".exe" else ""}`
end

---Download the asset of `tag` and `SHA256SUMS` into `dir`, and check the asset against its line.
---`DEV_RELEASE_URL` replaces the folder the files come from.
---@param tag string the release tag
---@param dir string an existing folder to hold both files
---@return string binary path of the checked asset
---@return string digest the checked hash
---@return string name the asset's file name
function M.download(tag, dir)
    local name = M.asset_name(tag)
    local base = base_url(tag)
    local binary, sums = `{dir}/{name}`, `{dir}/SHA256SUMS`
    fetch(`{base}/SHA256SUMS`, sums)
    fetch(`{base}/{name}`, binary)

    local want = listed(sums, name)
    local got = assert(hash.sha256_file(binary))
    if got ~= want then
        dev_command.die(
            `The asset {name} does not match SHA256SUMS: it lists {want}, the download is {got}.`
        )
    end
    return binary, got, name
end

---Make a downloaded asset runnable on this machine.
---@param binary string path of the asset
function M.make_runnable(binary)
    if dev_os.name() ~= "Windows" then
        assert(fs.chmod(binary, EXECUTABLE_MODE))
    end
end

---Run `binary` and return what it prints, stopping the command when it fails.
---@param binary string path of the binary
---@param argv string[] its arguments
---@param what string the step's name for the message
---@param cwd string? the folder to run it in
---@return string out the output without trailing white space
function M.run_binary(binary, argv, what, cwd)
    local out, code = dev_os.capture(
        { binary, table.unpack(argv) },
        { stderr = "stdout", cwd = cwd }
    )
    if code ~= 0 then
        dev_command.die(`The binary did not run {what}: {out}`)
    end
    return (out:gsub("%s+$", ""))
end

return M
