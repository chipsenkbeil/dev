local dev_os = require("dev.os")
local runtime = require("dev.runtime")

runtime.dofile(arg[0]:match("^(.*)/fixtures/[^/]*$") .. "/boot.luau")

local picker = require("dev.ui.picker")
local ui = require("dev.ui")

local items = {}
for line in (dev_os.stdin:read("*a") or ""):gmatch("[^\n]+") do
    local value, label = line:match("^([^\t]*)\t(.*)$")
    items[#items + 1] = { value = value, cells = { dev_os.getenv("PICK_BREAK") and {} or label } }
end

local result = picker.run(ui.context({ interactive = true }), items, {
    title = "Pick",
    toggles = dev_os.getenv("PICK_BAD_TOGGLE") and { 5 } or nil,
})
if result == nil then
    dev_os.exit(1)
end
dev_os.stdout:write(result, "\n")
