local dev_command = require("@dev/command")
local dev_os = require("@dev/os")
local dev_text = require("@dev/text")
local fs = require("@dev/fs")
local http = require("@dev/http")
local json = require("@dev/json")
local releasefile = require("@dev/releasefile")
local runtime = require("@dev/runtime")
local version = require("@dev/version")

local LATEST_SECONDS = 30

---@class dev.cmd.upgrade
local M = {}

---Tell whether `path` is a binary that cargo built, which lives under a `target` folder beside a
---`Cargo.toml`.
---@param path string the path of the binary, with `/` or `\` between names
---@param exists (fun(path: string): boolean)? how to tell a file exists, `fs.exists` by default
---@return boolean built whether the binary is a cargo build
function M.cargo_build(path, exists)
    exists = exists or fs.exists
    local dir = fs.dirname((path:gsub("\\", "/")))
    while dir ~= fs.dirname(dir) do
        local parent = fs.dirname(dir)
        if fs.basename(dir) == "target" and exists(`{parent}/Cargo.toml`) then
            return true
        end
        dir = parent
    end
    return false
end

---Tell whether the installed dev is at the latest release or newer.
---@param printed string what `dev --version` prints, such as `dev v0.2.0-pre.1`
---@param latest string the latest release version without a leading `v`
---@return boolean? current whether nothing newer exists, nil when a version is malformed
---@return string? reason why `current` is nil
function M.is_current(printed, latest)
    local installed = printed:gsub("^dev%s+", ""):gsub("^v", "")
    local core = installed:gsub("%-.*$", "")
    local order, _, detail = version.compare(core, latest)
    if not order then
        return nil, `Could not compare the version {detail} with {latest}.`
    end
    if order == 0 and installed ~= core then
        return false
    end
    return order >= 0
end

---Read the tag of the latest release that is not a pre-release.
---@return string tag the release tag
---@return string bare the tag without a leading `v`
local function latest()
    local url = releasefile.api_url()
    local reply = http.request({ method = "GET", url = url, timeout = LATEST_SECONDS })
    if reply == nil or reply.status < 200 or reply.status >= 300 then
        dev_command.die(`Could not read the latest release from {url}.`)
    end
    local doc = json.decode(reply.body)
    local tag = type(doc) == "table" and doc.tag_name
    if type(tag) ~= "string" then
        dev_command.die(`The reply from {url} names no release tag.`)
    end
    local bare = tag:gsub("^v", "")
    if not version.compare(bare, bare) then
        dev_command.die(`The latest release tag {tag} is not a MAJOR.MINOR.PATCH version.`)
    end
    return tag, bare
end

---Put `binary` in place of `exe`, keeping the old one as `exe.old` until the swap works.
---@param binary the checked new binary
---@param exe canonical path of the running binary
---@param move how to move a file, `fs.move` by default
---@return problem why the swap failed, nil when it worked
function M.swap(
    binary: string,
    exe: string,
    move: ((from: string, to: string) -> (boolean?, string?))?
): string?
    move = move or fs.move
    local staged, old = exe .. ".new", exe .. ".old"
    fs.remove(staged)
    fs.remove(old)
    local moved, why = move(binary, staged)
    if not moved then
        return dev_text.sentence(`Could not place the new binary beside {exe}: {why}`)
    end
    releasefile.make_runnable(staged)

    local aside, aside_why = move(exe, old)
    if not aside then
        fs.remove(staged)
        return dev_text.sentence(`Could not move {exe} aside: {aside_why}`)
    end
    local placed, placed_why = move(staged, exe)
    if not placed then
        local restored, restored_why = move(old, exe)
        fs.remove(staged)
        if not restored then
            return dev_text.sentence(
                `Could not replace {exe}: {placed_why}. Moving the old binary back failed too: {restored_why}. Restore it by hand from {old}`
            )
        end
        return dev_text.sentence(`Could not replace {exe}. The old binary stays: {placed_why}`)
    end
    fs.remove(old)
    return nil
end

---Replace the running binary with the latest release.
---@return integer code the exit code
function M.run()
    local exe = runtime.exe
    if exe == "" then
        dev_command.die("dev cannot tell where it is installed, so it will not replace itself.")
    end
    if M.cargo_build(exe) then
        dev_command.die(`{exe} is a cargo build, not an installed release binary.`)
    end

    local tag, bare = latest()
    local printed = dev_os.capture({ exe, "--version" }, { stderr = "null" }):gsub("%s+$", "")
    local current, reason = M.is_current(printed, bare)
    if current == nil then
        dev_command.die(reason)
    end
    if current then
        dev_command.say(`{printed} is current, the latest release is {tag}.`)
        return 0
    end

    local dir = assert(fs.mktemp({ prefix = "upgrade", dir = true }))
    dev_os.on_exit(function()
        fs.remove(dir, { recursive = true })
    end)
    local binary, got, name = releasefile.download(tag, dir)
    dev_command.say(`checksum {got}  {name}`)

    releasefile.make_runnable(binary)
    local new = releasefile.run_binary(binary, { "--version" }, "--version", dir)
    if new ~= "dev " .. tag then
        dev_command.die(`The binary prints {new} from --version, not dev {tag}.`)
    end

    local problem = M.swap(binary, exe)
    if problem then
        dev_command.die(problem)
    end
    dev_command.say(`{printed} upgraded to {new} at {exe}.`)
    return 0
end

return M
