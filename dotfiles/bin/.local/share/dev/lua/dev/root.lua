local dev_os = require("dev.os")
local fs = require("dev.fs")

local MAX_BYTES = 262144
local MAX_LINE_BYTES = 4096
local WRITABLE_BY_OTHERS = 18
local STICKY = 512
local OWNERSHIP = " must be owned by root and not writable by others"
local TEMP_TEMPLATE = "/tmp/dev-tools.XXXXXX"

---@class dev.root
local M = {}

---Say whether dev may run these command words as root.
---@param words string[] the command words, a verb and its subcommand
---@return boolean allowed true for `tools install` and `tools check` only
function M.allowed(words)
    return words[1] == "tools" and (words[2] == "install" or words[2] == "check")
end

local function refuse(manifest, reason)
    return "refusing " .. manifest .. " as root" .. reason
end

local function root_owned(stat)
    return stat ~= nil and stat.kind ~= fs.Kind.LINK and stat.uid == 0
end

local function check_strict(manifest, path)
    local stat = fs.stat(path)
    if not root_owned(stat) or bit.band(stat.mode, WRITABLE_BY_OTHERS) ~= 0 then
        return refuse(manifest, ": " .. path .. OWNERSHIP)
    end
end

local function check_ancestor(manifest, path)
    local stat = fs.stat(path)
    local sticky = stat ~= nil and bit.band(stat.mode, STICKY) ~= 0
    if not root_owned(stat) or (bit.band(stat.mode, WRITABLE_BY_OTHERS) ~= 0 and not sticky) then
        return refuse(manifest, ": " .. path .. OWNERSHIP)
    end
end

local function check_chain(root, manifest)
    local owned_paths = { manifest, root .. "/.dev", root }
    for _, path in ipairs(owned_paths) do
        local refusal = check_strict(manifest, path)
        if refusal then
            return refusal
        end
    end
    local dir = fs.dirname(root)
    while dir ~= "/" and dir ~= "." do
        local refusal = check_ancestor(manifest, dir)
        if refusal then
            return refusal
        end
        dir = fs.dirname(dir)
    end
    return check_ancestor(manifest, "/")
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
        return nil, "cannot open " .. manifest
    end
    if stat.kind ~= fs.Kind.FILE then
        return nil, refuse(manifest, ", it is not a regular file")
    end
    if stat.uid ~= 0 or bit.band(stat.mode, WRITABLE_BY_OTHERS) ~= 0 then
        return nil, refuse(manifest, ": " .. manifest .. OWNERSHIP)
    end
    if stat.size > MAX_BYTES then
        return nil, refuse(manifest, ": larger than 256 KiB")
    end
    local text = dev_os.read_fd(fd, MAX_BYTES + 1)
    if not text then
        return nil, "cannot open " .. manifest
    end
    if #text > MAX_BYTES then
        return nil, refuse(manifest, ": larger than 256 KiB")
    end
    if line_too_long(text) then
        return nil, refuse(manifest, ": a line is longer than 4096 bytes")
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
---@return string? message why the manifest was refused
function M.manifest_copy(root, manifest)
    local refusal = check_chain(root, manifest)
    if refusal then
        return nil, refusal
    end
    local fd = dev_os.open_nofollow(manifest)
    if not fd then
        return nil, "cannot open " .. manifest
    end
    local text, message = read_manifest(fd, manifest)
    dev_os.close(fd)
    if not text then
        return nil, message
    end
    local out, code = dev_os.capture({ "mktemp", TEMP_TEMPLATE })
    local copy = out:gsub("\n$", "")
    if code ~= 0 or copy == "" then
        return nil, "cannot make a temp file"
    end
    if not fs.write(copy, text) then
        fs.remove(copy)
        return nil, "cannot write " .. copy
    end
    return copy
end

return M
