dofile(arg[0]:match("^(.*)/fixtures/[^/]*$") .. "/boot.lua")

local picker = require("dev.ui.picker")
local ui = require("dev.ui")

local items = {}
for line in io.lines("/dev/stdin") do
    local value, label = line:match("^([^\t]*)\t(.*)$")
    items[#items + 1] = { value = value, cells = { os.getenv("PICK_BREAK") and {} or label } }
end

local result = picker.run(ui.context({ interactive = true }), items, {
    title = "Pick",
    toggles = os.getenv("PICK_BAD_TOGGLE") and { 5 } or nil,
})
if result == nil then
    os.exit(1)
end
io.write(result, "\n")
