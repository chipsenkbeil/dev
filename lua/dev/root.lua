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
local TEMP_TEMPLATE = "/tmp/dev-tools.XXXXXX"

---@class dev.root
---@field Reason table<string, dev.root.Reason> the reasons `manifest_copy` names
---@field MAX_BYTES integer the largest manifest `manifest_copy` reads, in bytes
---@field MAX_LINE_BYTES integer the longest line `manifest_copy` accepts, in bytes
local M = { Reason = Reason, MAX_BYTES = MAX_BYTES, MAX_LINE_BYTES = MAX_LINE_BYTES }

---Say whether dev may run these command words as root.
---@param words string[] the command words, a command and its subcommand
---@return boolean allowed true for `tools install` and `tools check` only
function M.allowed(words)
    return words[1] == "tools" and (words[2] == "install" or words[2] == "check")
end

local function root_owned(stat)
    return stat ~= nil and stat.kind ~= fs.Kind.LINK and stat.uid == 0
end

local function check_strict(path)
    local stat = fs.stat(path)
    if not root_owned(stat) or bit.band(stat.mode, WRITABLE_BY_OTHERS) ~= 0 then
        return Reason.OWNERSHIP, path
    end
end

local function check_ancestor(path)
    local stat = fs.stat(path)
    local sticky = stat ~= nil and bit.band(stat.mode, STICKY) ~= 0
    if not root_owned(stat) or (bit.band(stat.mode, WRITABLE_BY_OTHERS) ~= 0 and not sticky) then
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
    local stat = dev_os.fstat(fd)
    if not stat then
        return nil, nil, Reason.OPEN, manifest
    end
    if stat.kind ~= fs.Kind.FILE then
        return nil, nil, Reason.NOT_REGULAR, manifest
    end
    if stat.uid ~= 0 or bit.band(stat.mode, WRITABLE_BY_OTHERS) ~= 0 then
        return nil, nil, Reason.OWNERSHIP, manifest
    end
    if stat.size > MAX_BYTES then
        return nil, nil, Reason.TOO_LARGE, manifest
    end
    local text = dev_os.read_fd(fd, MAX_BYTES + 1)
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

---Copy a manifest to a root-owned temporary file after checking it.
---
---The project, `.dev` and every directory above must be owned by root, not a
---link and not writable by group or others, except that a sticky ancestor may
---be writable. The manifest is then opened once without following a link, and
---every later check and the read use that descriptor.
---@param root string absolute path of the project
---@param manifest string absolute path of `.dev/tools.tsv`
---@return string? copy path of the copy, which the caller removes
---@return nil message always nil, which keeps the slot a lower layer's message would take
---@return dev.root.Reason? reason why the manifest was refused
---@return string? detail the manifest, the path that fails the ownership check, or the copy
function M.manifest_copy(root, manifest)
    local chain_reason, chain_detail = check_chain(root, manifest)
    if chain_reason then
        return nil, nil, chain_reason, chain_detail
    end
    local fd = dev_os.open_nofollow(manifest)
    if not fd then
        return nil, nil, Reason.OPEN, manifest
    end
    local text, _, reason, detail = read_manifest(fd, manifest)
    dev_os.close(fd)
    if not text then
        return nil, nil, reason, detail
    end
    local out, code = dev_os.capture({ "mktemp", TEMP_TEMPLATE })
    local copy = out:gsub("\n$", "")
    if code ~= 0 or copy == "" then
        return nil, nil, Reason.TEMP
    end
    if not fs.write(copy, text) then
        fs.remove(copy)
        return nil, nil, Reason.WRITE, copy
    end
    return copy
end

return M
