local dev_os = require("@dev/os")

local CI_SECONDS = 3

---@class dev.complete.box
local M = {}

local function kinds_of(ctx)
    if ctx.flag == "run" then
        return { "runs" }
    end
    if ctx.words[1] == "connect" or ctx.words[2] == "connect" then
        return { "boxes", "connectables" }
    end
    return { "boxes" }
end

---List the ids the ci tool offers, or nothing when it is missing, slow or fails.
---@param ctx dev.complete.Context the completion context
---@return dev.complete.Item[] items a value and its label
function M.candidates(ctx)
    local items = {}
    if not dev_os.which("ci") then
        return items
    end
    for _, kind in ipairs(kinds_of(ctx)) do
        local out, code = dev_os.capture_timed({ "ci", "__complete", kind }, CI_SECONDS)
        if code == 0 then
            for line in out:gmatch("[^\n]+") do
                local value, desc = line:match("^([^\t]*)\t?(.*)$")
                items[#items + 1] = { value = value, desc = desc ~= "" and desc or nil }
            end
        end
    end
    return items
end

return M
