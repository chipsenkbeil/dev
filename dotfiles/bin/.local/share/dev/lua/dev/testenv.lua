local devos = require("dev.os")
local fs = require("dev.fs")

---@class dev.testenv
local M = {}

---@class dev.testenv.Fake
---@field code integer? exit status
---@field out string? text written to standard output
---@field err string? text written to standard error

---@class dev.testenv.VerbOpts
---@field env table<string, string> more environment variables

---Make a temporary directory for one test.
---@return string dir the new directory
function M.tempdir()
    return assert(fs.mktemp({ prefix = "test", dir = true }))
end

---Put an executable named `name` in `root/bin`.
---
---The command prints `out` and `err`, appends its arguments as one line to
---`root/bin/<name>.log` and exits with `code`.
---@param root string project directory
---@param name string command name
---@param spec dev.testenv.Fake? what the command prints and returns, `code` 0 and empty text when
---   nil
function M.fake(root, name, spec)
    local fields = { code = 0, out = "", err = "" }
    for key, value in pairs(spec or {}) do
        fields[key] = value
    end
    local bin = root .. "/bin"
    assert(fs.mkdir(bin, { parents = true }))
    local path = bin .. "/" .. name
    local script = table.concat({
        "#!/bin/sh",
        "printf '%s\\n' \"$*\" >> " .. devos.quote(path .. ".log"),
        "printf '%s' " .. devos.quote(fields.out),
        "printf '%s' " .. devos.quote(fields.err) .. " >&2",
        "exit " .. tostring(fields.code),
        "",
    }, "\n")
    assert(fs.write(path, script))
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
end

---List the argument lines a fake command logged.
---@param root string project directory
---@param name string command name
---@return string[] lines one line per call, in call order
function M.calls(root, name)
    local text = fs.read(root .. "/bin/" .. name .. ".log") or ""
    local lines = {}
    for line in text:gmatch("[^\n]*\n") do
        lines[#lines + 1] = line:sub(1, -2)
    end
    return lines
end

local function launcher()
    for template in package.path:gmatch("[^;]+") do
        local candidate = template:gsub("%?", "dev/cli")
        if fs.is_file(candidate) then
            local real = assert(fs.realpath(candidate))
            return (real:gsub("/lua/dev/cli%.lua$", "/main.lua"))
        end
    end
    error("dev.cli is not on package.path")
end

---Run the dev launcher in `root` with `root/bin` first on PATH.
---@param root string project directory
---@param words string[] command line after `dev`
---@param opts dev.testenv.VerbOpts? more environment, none when nil
---@return string out standard output
---@return integer? code dev's exit code
---@return string err standard error alone
function M.verb(root, words, opts)
    opts = opts or { env = {} }
    local argv = { "luajit", launcher() }
    for _, word in ipairs(words) do
        argv[#argv + 1] = word
    end
    local env = { PATH = root .. "/bin:" .. os.getenv("PATH") }
    for name, value in pairs(opts.env) do
        env[name] = value
    end
    local errfile = assert(fs.mktemp({ prefix = "stderr" }))
    local out, code = devos.capture(argv, { cwd = root, env = env, stderr = errfile })
    local err = fs.read(errfile) or ""
    fs.remove(errfile)
    return out, code, err
end

return M
