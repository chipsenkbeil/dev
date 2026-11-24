local runtime = require("dev.runtime")

---@enum dev.version.Reason
local Reason = { UNREADABLE = "unreadable", MALFORMED = "malformed" }

---@class dev.version
---@field Reason table<string, dev.version.Reason> why a version could not be had
local M = { Reason = Reason }

local function parts(text)
    local major, minor, patch = tostring(text):match("^(%d+)%.(%d+)%.(%d+)$")
    if not major then
        return nil
    end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

---Read the version of this dev, which the binary carries.
---@return string version `MAJOR.MINOR.PATCH`
function M.current()
    return runtime.version
end

---Order two `MAJOR.MINOR.PATCH` strings.
---@param a string first version
---@param b string second version
---@return integer? order -1 when `a` is older than `b`, 0 when they match, 1 when newer
---@return dev.version.Reason? reason MALFORMED when `order` is nil
---@return string? detail the malformed argument
function M.compare(a, b)
    local left, right = parts(a), parts(b)
    if not left then
        return nil, M.Reason.MALFORMED, tostring(a)
    end
    if not right then
        return nil, M.Reason.MALFORMED, tostring(b)
    end
    for index = 1, 3 do
        if left[index] ~= right[index] then
            return left[index] < right[index] and -1 or 1
        end
    end
    return 0
end

return M
