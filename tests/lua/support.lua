local devos = require("dev.os")
local fs = require("dev.fs")

---@class support
local M = {}

---Rewrite the relative entries of `package.path` against the current directory.
---@return string path a search path that works from any directory
function M.absolute_path()
    local cwd = devos.capture({ "pwd" }):gsub("\n$", "")
    return ((";" .. package.path):gsub(";%./", ";" .. cwd .. "/"):sub(2))
end

---Make a temporary directory.
---@return string dir the new directory
function M.tempdir()
    return assert(fs.mktemp({ prefix = "test", dir = true }))
end

---Read everything a temporary file holds.
---@param file file* a file from `io.tmpfile`
---@return string text the whole content
function M.drain(file)
    file:seek("set")
    return file:read("*a")
end

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/dotfiles/bin/.local/share/dev/main.lua"
local SELF = REPO .. "/dotfiles/bin/.local/bin/dev"
local STUB = '#!/bin/sh\necho "$(basename "$0") $* cwd=$PWD"\nexit "${STUB_CODE:-0}"\n'

---Make a project directory with a `.dev` directory and stub tools in `bin`.
---
---Each stub prints its name, its arguments and its directory, then exits with `STUB_CODE`.
---@param files table<string, string> file contents by path under the project
---@param tools string[]? the stubs to make, `make`, `npm`, `cargo` and `ast-grep` when nil
---@return string root the project's real path
function M.sandbox(files, tools)
    local root = assert(fs.realpath(M.tempdir()))
    assert(fs.mkdir(root .. "/.dev", { parents = true }))
    assert(fs.mkdir(root .. "/bin", { parents = true }))
    for name, text in pairs(files) do
        assert(fs.mkdir(fs.dirname(root .. "/" .. name), { parents = true }))
        assert(fs.write(root .. "/" .. name, text))
    end
    for _, tool in ipairs(tools or { "make", "npm", "cargo", "ast-grep" }) do
        assert(fs.write(root .. "/bin/" .. tool, STUB))
        assert(devos.run({ "chmod", "755", root .. "/bin/" .. tool }) == 0, "chmod failed")
    end
    return root
end

---@class support.DevOpts
---@field cwd string? where to run, the project root when nil
---@field code string? the exit code the stubs return
---@field env table<string, string>? more environment variables
---@field split boolean? keep standard error apart and return it as a third value

---Run `dev` on a project with its `bin` first on PATH.
---@param root string the project root from `sandbox`
---@param args string[] the command line after `dev`
---@param opts support.DevOpts? where to run and what to set
---@return string output standard output, with standard error merged in unless `opts.split` is set
---@return integer? code dev's exit code
---@return string? errors standard error alone, only when `opts.split` is set
function M.dev(root, args, opts)
    opts = opts or {}
    local argv = { "luajit", MAIN }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    local env =
        { DEV_SELF = SELF, DEV_BOARD_TOKEN = "", PATH = root .. "/bin:" .. os.getenv("PATH") }
    env.STUB_CODE = opts.code
    for name, value in pairs(opts.env or {}) do
        env[name] = value
    end
    local run = { cwd = opts.cwd or root, stderr = "stdout", env = env }
    local errors
    if opts.split then
        errors = assert(fs.mktemp({ prefix = "stderr" }))
        run.stderr = errors
    end
    local out, code
    if opts.input then
        out, code = devos.capture_input(argv, opts.input, run)
    else
        out, code = devos.capture(argv, run)
    end
    if errors then
        local text = fs.read(errors) or ""
        fs.remove(errors)
        return out, code, text
    end
    return out, code
end

---The fields JSON of a Pomb board that defines the four card fields.
M.FIELDS = '[{"id":"f1","key":"dev.checks","label":"Checks","kind":"table",'
    .. '"options":[],"columns":[],"required":true},'
    .. '{"id":"f2","key":"dev.allow","label":"Allow","kind":"multiselect",'
    .. '"options":["test-edits","ci-edits"],"columns":[],"required":false},'
    .. '{"id":"f3","key":"dev.tests","label":"Tests","kind":"multiline",'
    .. '"options":[],"columns":[],"required":false},'
    .. '{"id":"f4","key":"dev.files","label":"Files","kind":"multiline",'
    .. '"options":[],"columns":[],"required":false}]'

---The board column names, by constant.
---@type table<string, string>
M.COLUMN = {
    BACKLOG = "backlog",
    BLOCKED = "blocked",
    DONE = "done",
    ICEBOX = "icebox",
    PROGRESS = "progress",
    READY = "ready",
    RELEASE = "release",
    REVIEW = "review",
    VERIFY = "verify",
}

---The Pomb display name of a column, by constant.
---@type table<string, string>
M.COLUMN_NAME = {
    BACKLOG = "Backlog",
    BLOCKED = "Blocked",
    DONE = "Done",
    ICEBOX = "Icebox",
    PROGRESS = "In Progress",
    READY = "Ready",
    RELEASE = "Release",
    REVIEW = "Review",
    VERIFY = "Verify",
}

return M
