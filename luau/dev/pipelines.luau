local config = require("dev.config")
local runtime = require("dev.runtime")

---@class dev.pipelines
local M = {}

local DIR = "init/"
local PLACEHOLDER = "TARGET"

local function text(name)
    return assert(runtime.asset(DIR .. name), "cannot read " .. DIR .. name)
end

---Read the ci target a project's jobs run on from the user config.
---@param rust boolean whether the project is a Rust one
---@return string? target the target, or nil when the user config does not set it
function M.target(rust)
    local target = config.user(rust and "ci.rust_target" or "ci.target")
    if type(target) ~= "string" or target == "" then
        return nil
    end
    return target
end

---Read the `.ci/jobs.lua` a project of a type starts with.
---@param rust boolean whether the project is a Rust one
---@param target string? the ci target the jobs run on, the placeholder when nil
---@return string text the pipeline
function M.jobs(rust, target)
    local body = text(rust and "jobs-rust.txt" or "jobs-base.txt")
    return (body:gsub("@TARGET@", function()
        return target or PLACEHOLDER
    end))
end

return M
