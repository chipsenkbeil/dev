local devos = require("dev.os")
local fs = require("dev.fs")

---@class dev.standalone
local M = {}

local DIR = ".dev/standalone/"

M.WHERE = { "production server", "test sandbox", "GitHub Actions" }
M.HEADER = "^# standalone: runs on (.+), where dev is absent$"

local function allowed(where)
    for _, name in ipairs(M.WHERE) do
        if name == where then
            return true
        end
    end
    return false
end

local function second_line(root, path)
    local text = fs.read(fs.join(root, path)) or ""
    local count = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        count = count + 1
        if count == 2 then
            return line
        end
    end
    return ""
end

local function found(root, args)
    local argv = { "find", ".dev", "-type", "f" }
    for _, arg in ipairs(args) do
        argv[#argv + 1] = arg
    end
    local text = devos.capture(argv, { cwd = root, stderr = "null" })
    local paths = {}
    for path in text:gmatch("[^\n]+") do
        paths[#paths + 1] = path
    end
    return paths
end

local function header_problem(root, path)
    local where = second_line(root, path):match(M.HEADER)
    if not where then
        return "WARNING: "
            .. path
            .. ": line 2 must read: # standalone: runs on <where>, where dev is absent"
    end
    if not allowed(where) then
        return "WARNING: " .. path .. ": where must be one of: " .. table.concat(M.WHERE, ", ")
    end
    return nil
end

---List the shell and standalone header problems of a project.
---@param root string absolute project root
---@return string[] problems sorted warning lines, empty when there are none
function M.problems(root)
    local lines = {}
    for _, path in ipairs(found(root, { "-name", "*.sh" })) do
        if path:sub(1, #DIR) ~= DIR then
            lines[#lines + 1] = "WARNING: "
                .. path
                .. ": shell outside .dev/standalone, port it to Lua (dev help porting)"
        end
    end
    for _, path in ipairs(found(root, {})) do
        if path:sub(1, #DIR) == DIR then
            lines[#lines + 1] = header_problem(root, path)
        end
    end
    table.sort(lines)
    return lines
end

return M
