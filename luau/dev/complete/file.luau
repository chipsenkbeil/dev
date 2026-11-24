local fs = require("dev.fs")

---@class dev.complete.file
local M = {}

---List the files and folders the word being typed can name, a folder ending in a slash.
---@param ctx dev.complete.Context the completion context
---@return dev.complete.Item[] items the paths, spelled as the word spells its folder
function M.candidates(ctx)
    local cur = ctx.cur
    local folder = cur:match("^(.*/)") or ""
    local real = folder
    if folder:sub(1, 2) == "~/" and ctx.home and ctx.home ~= "" then
        real = ctx.home .. folder:sub(2)
    end
    local dir = real == "" and "." or real
    local listing = fs.list(dir) or {}
    local items = {}
    for _, name in ipairs(listing) do
        if name:sub(1, 1) ~= "." or cur:match("[^/]*$"):sub(1, 1) == "." then
            local is_dir = fs.is_dir(dir .. "/" .. name)
            items[#items + 1] = { value = folder .. name .. (is_dir and "/" or "") }
        end
    end
    return items
end

return M
