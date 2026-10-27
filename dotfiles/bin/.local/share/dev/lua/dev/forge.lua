local text = require("dev.text")
local vcs = require("dev.vcs")

---@enum dev.forge.Kind
local Kind = { GERRIT = "gerrit", GITHUB = "github", PLAIN = "plain" }

---@class dev.forge.Forge
---@field kind dev.forge.Kind the forge
---@field remote string the remote of record
---@field why string where the choice came from
---@field remotes string[] every remote the project has

---@class dev.forge
---@field Kind table<string, dev.forge.Kind> the forges dev knows
local M = { Kind = Kind }

local KINDS = {}
for _, kind in pairs(Kind) do
    KINDS[kind] = true
end

---Find the forge and the remote of record.
---
---The kind is the first of the `JJ_FORGE` environment variable, `git config forge.kind`
---and detection. The remote is `git config forge.remote`, else `gerrit` for a gerrit
---forge, else `origin`, and it must be a remote of the project.
---@param root string absolute path of the project root
---@return dev.forge.Forge? forge nil on failure
---@return string? err why there is no forge
---@return string[]? remotes the project's remotes, when they were read before the failure
function M.resolve(root)
    local backend, err = vcs.require(root)
    if not backend then
        return nil, err
    end
    local remotes = vcs.remotes(root, backend)
    local kind = os.getenv("JJ_FORGE") or ""
    local why = ""
    if kind ~= "" then
        why = "JJ_FORGE=" .. kind
    else
        kind = vcs.config(root, backend, "forge.kind")
        if kind ~= "" then
            why = "git config forge.kind=" .. kind
        end
    end
    if kind == "" then
        if text.contains(remotes, "gerrit") then
            kind, why = Kind.GERRIT, "detected: the project has a gerrit remote"
        elseif vcs.config(root, backend, "remote.origin.url"):find("github.com", 1, true) then
            kind, why = Kind.GITHUB, "detected: origin is on github.com"
        else
            kind = Kind.PLAIN
            why = "detected: no gerrit remote and origin is not on github.com"
        end
    end
    if not KINDS[kind] then
        return nil,
            "forge must be gerrit, github or plain (got: " .. kind .. ", from " .. why .. ")",
            remotes
    end
    local remote = vcs.config(root, backend, "forge.remote")
    if remote ~= "" then
        why = why .. "; remote from git config forge.remote"
    elseif kind == Kind.GERRIT then
        remote = "gerrit"
    else
        remote = "origin"
    end
    if not text.contains(remotes, remote) then
        return nil,
            "the remote of record " .. remote .. " is not a remote of this project (" .. why .. ")",
            remotes
    end
    return { kind = kind, remote = remote, why = why, remotes = remotes }
end

return M
