local dev_os = require("dev.os")
local fs = require("dev.fs")

---@class dev.standalone
local M = {}

local FOLDER = ".dev/standalone"
local DIR = FOLDER .. "/"
local HEADER = "^# standalone: runs on (.+), where dev is absent$"

M.WHERE = { "production server", "test sandbox", "GitHub Actions" }
M.LABEL = "standalone-ok"

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
    local text = dev_os.capture(argv, { cwd = root, stderr = "null" })
    local paths = {}
    for path in text:gmatch("[^\n]+") do
        paths[#paths + 1] = path
    end
    return paths
end

local function header_problem(root, path)
    local where = second_line(root, path):match(HEADER)
    if not where then
        return path .. ": line 2 must read: # standalone: runs on <where>, where dev is absent"
    end
    if not allowed(where) then
        return path .. ": where must be one of: " .. table.concat(M.WHERE, ", ")
    end
    return nil
end

---List the shell and standalone header problems of a project.
---@param root string absolute project root
---@return string[] problems sorted warning lines, empty when there are none
function M.problems(root)
    local lines = {}
    for _, path in ipairs(found(root, { "-name", "*.sh" })) do
        if path:sub(1, #DIR) ~= DIR and not path:match("^%.dev/__[^/]+$") then
            lines[#lines + 1] = path
                .. ": shell outside "
                .. FOLDER
                .. ", port it to Lua (dev help porting)"
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

---Pass each problem line of a project to a function, in order.
---@param root string absolute project root
---@param emit fun(line: string) called once for each problem line
function M.warn(root, emit)
    for _, line in ipairs(M.problems(root)) do
        emit(line)
    end
end

---Name why a landing that adds files may not land without the owner's label.
---@param added string[] the paths the landing commit adds
---@param labels string[] the labels of the card
---@return string? problem the refusal, nil when the landing may go ahead
function M.land_problem(added, labels)
    for _, label in ipairs(labels) do
        if label == M.LABEL then
            return nil
        end
    end
    for _, path in ipairs(added) do
        if path:sub(1, #DIR) == DIR then
            return "adds "
                .. path
                .. ", which needs the "
                .. M.LABEL
                .. " label that only the owner adds"
        end
    end
    return nil
end

---Name why the running agent may not add a label.
---@param label string the label being added
---@return string? problem the refusal, nil when the label may be added
function M.label_problem(label)
    if label == M.LABEL and (os.getenv("DEV_AGENT") or "") ~= "" then
        return "The "
            .. M.LABEL
            .. " label is added only by the owner. File a needs:human card instead."
    end
    return nil
end

return M
