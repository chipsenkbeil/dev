local fs = require("dev.fs")
local project = require("dev.project")

---@class dev.pipelines
local M = {}

local DIR = project.share .. "/init/"

local function text(name)
    return assert(fs.read(DIR .. name), "cannot read " .. DIR .. name)
end

---Read the `.ci/jobs.lua` a project of a type starts with.
---@param rust boolean whether the project is a Rust one
---@return string text the pipeline
function M.jobs(rust)
    return text(rust and "jobs-rust.txt" or "jobs-base.txt")
end

return M
