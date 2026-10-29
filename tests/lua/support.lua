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

---Run `dev` on a project with its `bin` first on PATH.
---@param root string the project root from `sandbox`
---@param args string[] the command line after `dev`
---@param opts support.DevOpts? where to run and what to set
---@return string output standard output and error together
---@return integer? code dev's exit code
function M.dev(root, args, opts)
    opts = opts or {}
    local argv = { "luajit", MAIN }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    local env = { DEV_SELF = SELF, PATH = root .. "/bin:" .. os.getenv("PATH") }
    env.STUB_CODE = opts.code
    for name, value in pairs(opts.env or {}) do
        env[name] = value
    end
    local run = { cwd = opts.cwd or root, stderr = "stdout", env = env }
    if opts.input then
        return devos.capture_input(argv, opts.input, run)
    end
    return devos.capture(argv, run)
end

return M
