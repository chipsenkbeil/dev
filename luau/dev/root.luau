local dev_os = require("dev.os")
local fs = require("dev.fs")

---The reasons `manifest_copy` refuses a manifest
---@enum dev.root.Reason
local Reason = {
    OPEN = "open",
    NOT_REGULAR = "not_regular",
    OWNERSHIP = "ownership",
    TOO_LARGE = "too_large",
    LONG_LINE = "long_line",
    TEMP = "temp",
    WRITE = "write",
}

local MAX_BYTES = 262144
local MAX_LINE_BYTES = 4096
local WRITABLE_BY_OTHERS = 18
local STICKY = 512
local GROUP_OTHER_BITS = 63
local MANIFEST_NAME = "tools.tsv"
local PINS_NAME = "releases.tsv"
local TEMP_TEMPLATE = "/tmp/dev-tools.XXXXXX"

---@class dev.root
---@field Reason table<string, dev.root.Reason> the reasons `manifest_copy` names
---@field DRIVER string the name of the hidden package driver command
---@field MAX_BYTES integer the largest manifest `manifest_copy` reads, in bytes
---@field MAX_LINE_BYTES integer the longest line `manifest_copy` accepts, in bytes
local M = {
    DRIVER = "__pkg",
    Reason = Reason,
    MAX_BYTES = MAX_BYTES,
    MAX_LINE_BYTES = MAX_LINE_BYTES,
}

---Say whether dev may run these command words as root.
---@param words string[] the command words, a command and its subcommand
---@return boolean allowed true for `tools install`, `tools check` and the `__pkg` driver on a root-owned manifest
function M.allowed(words)
    if words[1] == M.DRIVER then
        return M.driver_manifest_ok(words)
    end
    return words[1] == "tools" and (words[2] == "install" or words[2] == "check")
end

---The usage line of each command root may run
local USAGE = {
    ["tools check"] = "usage: dev tools check [--group NAME]",
    ["tools install"] = "usage: dev tools install [--system or --user] [--group NAME] "
        .. "[--dry-run] [--force] [tool...]",
}

---Return the usage line a root run prints under a usage error.
---@param words string[] the command words, one of the two root may run
---@return string? line the accepted form, nil for any other command
function M.usage(words)
    return USAGE[table.concat(words, " ")]
end

local function root_owned(stat)
    return stat ~= nil and stat.kind ~= fs.Kind.LINK and stat.uid == 0
end

local function check_strict(path)
    local stat = fs.stat(path)
    if not root_owned(stat) or bit32.band(stat.mode, WRITABLE_BY_OTHERS) ~= 0 then
        return Reason.OWNERSHIP, path
    end
end

local function check_ancestor(path)
    local stat = fs.stat(path)
    local sticky = stat ~= nil and bit32.band(stat.mode, STICKY) ~= 0
    if not root_owned(stat) or (bit32.band(stat.mode, WRITABLE_BY_OTHERS) ~= 0 and not sticky) then
        return Reason.OWNERSHIP, path
    end
end

local function check_chain(root, manifest)
    local owned_paths = { manifest, root .. "/.dev", root }
    for _, path in ipairs(owned_paths) do
        local reason, detail = check_strict(path)
        if reason then
            return reason, detail
        end
    end
    local dir = fs.dirname(root)
    while dir ~= "/" and dir ~= "." do
        local reason, detail = check_ancestor(dir)
        if reason then
            return reason, detail
        end
        dir = fs.dirname(dir)
    end
    return check_ancestor("/")
end

---Say whether a file is root's, not a link and not writable by group or others.
---@param stat table? the file's `fs.stat` result
---@return boolean ok true for a file only root can have written
function M.owned_quietly(stat)
    return stat ~= nil
        and stat.kind ~= fs.Kind.LINK
        and stat.kind == fs.Kind.FILE
        and stat.uid == 0
        and bit32.band(stat.mode, WRITABLE_BY_OTHERS) == 0
end

---Say whether a `__pkg` call names a manifest that only root can have written.
---@param words string[] the words of the call, `__pkg` first
---@return boolean ok true when a check or install names a root-owned file no one else can write
function M.driver_manifest_ok(words)
    local manifest
    for i = 2, #words do
        if words[i] == "--log-file" then
            return false
        end
    end
    for i = 2, #words - 1 do
        if words[i] == "--manifest" then
            if manifest then
                return false
            end
            manifest = words[i + 1]
        end
    end
    if not manifest then
        return words[2] ~= "check" and words[2] ~= "install"
    end
    local folder = fs.dirname(manifest)
    local dir = fs.stat(folder)
    if
        not M.owned_quietly(fs.stat(manifest))
        or dir == nil
        or dir.kind ~= fs.Kind.DIR
        or dir.uid ~= 0
        or bit32.band(dir.mode, GROUP_OTHER_BITS) ~= 0
    then
        return false
    end
    local ancestor = fs.dirname(folder)
    while ancestor ~= "/" and ancestor ~= "." do
        if check_ancestor(ancestor) then
            return false
        end
        ancestor = fs.dirname(ancestor)
    end
    return check_ancestor("/") == nil
end

local function line_too_long(text)
    local from = 1
    while from <= #text do
        local stop = text:find("\n", from, true)
        if not stop then
            return #text - from + 1 > MAX_LINE_BYTES
        end
        if stop - from > MAX_LINE_BYTES then
            return true
        end
        from = stop + 1
    end
    return false
end

local function read_manifest(fd, manifest)
    local stat = fs.fstat(fd)
    if not stat then
        return nil, nil, Reason.OPEN, manifest
    end
    if stat.kind ~= fs.Kind.FILE then
        return nil, nil, Reason.NOT_REGULAR, manifest
    end
    if stat.uid ~= 0 or bit32.band(stat.mode, WRITABLE_BY_OTHERS) ~= 0 then
        return nil, nil, Reason.OWNERSHIP, manifest
    end
    if stat.size > MAX_BYTES then
        return nil, nil, Reason.TOO_LARGE, manifest
    end
    local text = fs.read_fd(fd, MAX_BYTES + 1)
    if not text then
        return nil, nil, Reason.OPEN, manifest
    end
    if #text > MAX_BYTES then
        return nil, nil, Reason.TOO_LARGE, manifest
    end
    if line_too_long(text) then
        return nil, nil, Reason.LONG_LINE, manifest
    end
    return text
end

---Copy a manifest and the pins file beside it into one private root-owned folder after checking them.
---
---The folder is made with mode 0700, so no one else can write beside the copy. The caller removes
---the folder, which is the parent of the returned path.
---
---The project, `.dev` and every directory above must be owned by root, not a
---link and not writable by group or others, except that a sticky ancestor may
---be writable. The manifest is then opened once without following a link, and
---every later check and the read use that descriptor.
---@param root string absolute path of the project
---@param manifest string absolute path of `.dev/tools.tsv`
---@return string? copy path of the manifest copy inside the private folder
---@return nil message always nil, which keeps the slot a lower layer's message would take
---@return dev.root.Reason? reason why the manifest was refused
---@return string? detail the manifest, the path that fails the ownership check, or the copy
function M.manifest_copy(root, manifest)
    local chain_reason, chain_detail = check_chain(root, manifest)
    if chain_reason then
        return nil, nil, chain_reason, chain_detail
    end
    local fd = fs.open_nofollow(manifest)
    if not fd then
        return nil, nil, Reason.OPEN, manifest
    end
    local text, _, reason, detail = read_manifest(fd, manifest)
    fs.close(fd)
    if not text then
        return nil, nil, reason, detail
    end
    local pins_path = fs.dirname(manifest) .. "/" .. PINS_NAME
    local pins
    if fs.stat(pins_path) then
        local pins_fd = fs.open_nofollow(pins_path)
        if not pins_fd then
            return nil, nil, Reason.OPEN, pins_path
        end
        pins, _, reason, detail = read_manifest(pins_fd, pins_path)
        fs.close(pins_fd)
        if not pins then
            return nil, nil, reason, detail
        end
    end
    local out, code = dev_os.capture({ "mktemp", "-d", TEMP_TEMPLATE })
    local private = out:gsub("\n$", "")
    if code ~= 0 or private == "" then
        return nil, nil, Reason.TEMP
    end
    local copy = private .. "/" .. MANIFEST_NAME
    if not fs.write(copy, text) or (pins and not fs.write(private .. "/" .. PINS_NAME, pins)) then
        fs.remove(private, { recursive = true })
        return nil, nil, Reason.WRITE, private
    end
    return copy
end

return M
