local devos = require("dev.os")
local fs = require("dev.fs")
local toml = require("dev.toml")
local verb = require("dev.verb")

---Read dev's config files: `~/.config/dev/config.toml`, overridden key by key
---by `<project>/.dev/config.toml`.
---@class dev.config
local M = {}

---Parse one config file.
---@param path string the file
---@return table<string, any>? tree the parsed file, an empty table when it does not exist
---@return string? message `dev: <path>:<line>: <reason>` when it is malformed or unreadable
local function read(path)
    if not fs.exists(path) then
        return {}
    end
    local text, err = fs.read(path)
    if not text then
        return nil, "dev: " .. path .. ": " .. tostring(err)
    end
    local tree, message = toml.parse(text)
    if not tree then
        return nil, "dev: " .. path .. ":" .. message
    end
    return tree
end

local function lookup(tree, parts)
    local value = tree
    for _, part in ipairs(parts) do
        if type(value) ~= "table" then
            return nil
        end
        value = value[part]
    end
    return value
end

---Look up a dotted key such as `remote.runner`.
---
---The project file wins over the user file. A malformed file ends the process
---with `dev: <path>:<line>: <reason>` and exit 1. As root no file is read.
---@param root string the project root
---@param key string dotted key
---@return any? value the value, or nil when neither file sets it
function M.get(root, key)
    if devos.getuid() == 0 then
        return nil
    end
    local home = os.getenv("HOME")
    local paths = { root .. "/.dev/config.toml" }
    if home and home ~= "" then
        paths[#paths + 1] = home .. "/.config/dev/config.toml"
    end
    local parts = {}
    for part in key:gmatch("[^.]+") do
        parts[#parts + 1] = part
    end
    local trees = {}
    for index, path in ipairs(paths) do
        local tree, err = read(path)
        if not tree then
            verb.die(err)
        end
        trees[index] = tree
    end
    for _, tree in ipairs(trees) do
        local value = lookup(tree, parts)
        if value ~= nil then
            return value
        end
    end
    return nil
end

---Look up a dotted key in the user file alone.
---
---A project file cannot set it, which is how a key that names a server or a
---secret stays out of a repository's reach. A malformed file ends the process
---with `dev: <path>:<line>: <reason>` and exit 1. As root no file is read.
---@param key string dotted key
---@return any? value the value, or nil when the user file does not set it
function M.user(key)
    local home = os.getenv("HOME")
    if devos.getuid() == 0 or not home or home == "" then
        return nil
    end
    local tree, err = read(home .. "/.config/dev/config.toml")
    if not tree then
        verb.die(err)
    end
    local parts = {}
    for part in key:gmatch("[^.]+") do
        parts[#parts + 1] = part
    end
    return lookup(tree, parts)
end

return M
