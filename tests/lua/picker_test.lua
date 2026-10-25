local t = require("testing")
local text = require("dev.text")
local ui = require("dev.ui")
local picker = require("dev.ui.picker")
local term = require("dev.term")

local Key = term.Key
local plain = ui.context({ color = false, interactive = true, width = 80 })

local function items()
    return {
        { value = "one", cells = { "One", "first" } },
        { value = "two", cells = { "Two", "second" } },
        { value = "three", cells = { "Three", "third" } },
    }
end

local function press(model, keys)
    local last
    for _, name in ipairs(keys) do
        last = model:key(name)
    end
    return last
end

t.test("down then enter picks the second item", function()
    local model = picker.new(items(), { title = "Pick" })
    t.eq(press(model, { Key.DOWN, Key.ENTER }), picker.Outcome.PICK)
    t.eq(model:result(), "two")
end)

t.test("up from the first item stays on the first", function()
    local model = picker.new(items(), { title = "Pick" })
    press(model, { Key.UP, Key.ENTER })
    t.eq(model:result(), "one")
end)

t.test("initial puts the cursor on that value", function()
    local model = picker.new(items(), { title = "Pick", initial = "three" })
    press(model, { Key.ENTER })
    t.eq(model:result(), "three")
end)

t.test("down skips a disabled item", function()
    local list = items()
    list[2].disabled = "needs 8 GiB more"
    local model = picker.new(list, { title = "Pick" })
    press(model, { Key.DOWN, Key.ENTER })
    t.eq(model:result(), "three")
end)

t.test("a disabled first item is skipped and a lone disabled item cannot be picked", function()
    local list = items()
    list[1].disabled = "needs 8 GiB more"
    local model = picker.new(list, { title = "Pick" })
    press(model, { Key.ENTER })
    t.eq(model:result(), "two")
    list = { { value = "x", cells = { "X" }, disabled = "no" } }
    model = picker.new(list, { title = "Pick" })
    t.eq(model:key(Key.ENTER), nil)
    t.eq(model:result(), nil)
end)

t.test("esc, q and ctrl-c cancel with no result", function()
    for _, name in ipairs({ Key.ESC, "q", Key.CTRL_C }) do
        local model = picker.new(items(), { title = "Pick" })
        t.eq(model:key(name), picker.Outcome.CANCEL)
        t.eq(model:result(), nil)
    end
end)

t.test("multi mode: space then a then enter returns every value", function()
    local model = picker.new(items(), { title = "Pick", multi = true })
    press(model, { Key.SPACE, "a", Key.ENTER })
    t.eq(model:result(), { "one", "two", "three" })
end)

t.test("multi mode: a twice clears every box", function()
    local model = picker.new(items(), { title = "Pick", multi = true })
    press(model, { "a", "a", Key.ENTER })
    t.eq(model:result(), {})
end)

t.test("multi mode: a leaves disabled items unchecked", function()
    local list = items()
    list[2].disabled = "no"
    local model = picker.new(list, { title = "Pick", multi = true })
    press(model, { "a", Key.ENTER })
    t.eq(model:result(), { "one", "three" })
end)

t.test("a toggle flips its value in the result", function()
    local toggles = { { key = "d", value = "--dry-run", label = "Dry run" } }
    local model = picker.new(items(), { title = "Pick", toggles = toggles })
    press(model, { "d", Key.ENTER })
    t.eq(model:result(), { values = "one", toggles = { "--dry-run" } })
    model = picker.new(items(), { title = "Pick", toggles = toggles })
    press(model, { "d", "d", Key.ENTER })
    t.eq(model:result(), { values = "one", toggles = {} })
end)

t.test("a toggle that starts on is on in the result", function()
    local toggles = { { key = "d", value = "--dry-run", label = "Dry run", on = true } }
    local model = picker.new(items(), { title = "Pick", toggles = toggles })
    press(model, { Key.ENTER })
    t.eq(model:result().toggles, { "--dry-run" })
end)

t.test("lines stay within the width", function()
    local ctx = ui.context({ color = false, interactive = true, width = 30 })
    local list = items()
    list[1].cells = { "A-very-long-name-with-é", "and a long description" }
    list[2].disabled = "needs 8 GiB more than this box has"
    local toggles = { { key = "d", value = "--dry-run", label = "Dry run with a long label" } }
    local model =
        picker.new(list, { title = "Pick a box", note = "a long note here", toggles = toggles })
    for _, line in ipairs(model:lines(ctx)) do
        t.ok(text.width(line) <= 30, line)
    end
end)

t.test("the last line is the hint", function()
    local lines = picker.new(items(), { title = "Pick" }):lines(plain)
    t.eq(lines[#lines], "↑/↓ move · enter pick · esc cancel")
end)

t.test("the title is bold with a dim note and the cursor row has the cursor", function()
    local ctx = ui.context({ color = true, interactive = true, width = 80 })
    local lines = picker.new(items(), { title = "Pick", note = "note" }):lines(ctx)
    t.eq(lines[1], "\27[1mPick\27[0m \27[2mnote\27[0m")
    t.ok(lines[2]:find("❯", 1, true))
    t.ok(not lines[3]:find("❯", 1, true))
end)

t.test("a disabled row shows its reason", function()
    local list = items()
    list[2].disabled = "needs 8 GiB more"
    local lines = picker.new(list, { title = "Pick" }):lines(plain)
    t.ok(lines[3]:find("needs 8 GiB more", 1, true))
end)

t.test("multi rows show boxes and the toggle line shows its key", function()
    local toggles = { { key = "d", value = "--dry-run", label = "Dry run" } }
    local model = picker.new(items(), { title = "Pick", multi = true, toggles = toggles })
    press(model, { Key.SPACE })
    local lines = model:lines(plain)
    t.ok(lines[2]:find("[x]", 1, true))
    t.ok(lines[3]:find("[ ]", 1, true))
    t.eq(lines[#lines - 1], "[ ] d Dry run")
end)

t.test("run with auto returns the only enabled item without drawing", function()
    local list = items()
    list[1].disabled = "no"
    list[3].disabled = "no"
    t.eq(picker.run(plain, list, { title = "Pick", auto = true }), "two")
    t.eq(picker.run(plain, list, { title = "Pick", auto = true, multi = true }), { "two" })
end)
