local t = require("dev.testing")
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

t.test("multi mode: a row marked checked starts checked", function()
    local list = items()
    list[1].checked = true
    list[3].checked = true
    local model = picker.new(list, { title = "Pick", multi = true })
    press(model, { Key.ENTER })
    t.eq(model:result(), { "one", "three" })
end)

t.test("a checked row is ignored outside multi mode and when disabled", function()
    local list = items()
    list[1].checked = true
    list[2].checked = true
    list[2].disabled = "no"
    local model = picker.new(list, { title = "Pick", multi = true })
    press(model, { Key.ENTER })
    t.eq(model:result(), { "one" })
    model = picker.new(items(), { title = "Pick" })
    press(model, { Key.ENTER })
    t.eq(model:result(), "one")
end)

t.test("required multi mode: enter waits until a row is checked", function()
    local model = picker.new(items(), { title = "Pick", multi = true, required = true })
    t.eq(press(model, { Key.ENTER }), nil)
    t.eq(model:result(), nil)
    t.eq(press(model, { Key.SPACE, Key.ENTER }), picker.Outcome.PICK)
    t.eq(model:result(), { "one" })
end)

t.test("required multi mode: clearing every box blocks enter again, and q still cancels", function()
    local list = items()
    list[1].checked = true
    local model = picker.new(list, { title = "Pick", multi = true, required = true })
    t.eq(press(model, { Key.SPACE, Key.ENTER }), nil)
    t.eq(press(model, { "q" }), picker.Outcome.CANCEL)
    t.eq(model:result(), nil)
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

local function many(n)
    local list = {}
    for i = 1, n do
        list[i] = { value = "v" .. i, cells = { "Row " .. i } }
    end
    return list
end

local function tall(height)
    return ui.context({ color = false, interactive = true, width = 80, height = height })
end

local function cursor_row(lines)
    for i, line in ipairs(lines) do
        if line:find("❯", 1, true) then
            return i
        end
    end
end

t.test("a list that fits draws with no indicator whatever the height", function()
    local lines = picker.new(items(), { title = "Pick" }):lines(tall(5))
    t.eq(#lines, 5)
    for _, line in ipairs(lines) do
        t.ok(not line:find("more", 1, true), line)
    end
end)

t.test("a tall list never draws more lines than the height", function()
    local model = picker.new(many(30), { title = "Pick" })
    for _ = 1, 40 do
        t.ok(#model:lines(tall(10)) <= 10)
        model:key(Key.DOWN)
    end
end)

t.test("a tall list keeps the cursor row in the window as it moves", function()
    local model = picker.new(many(30), { title = "Pick" })
    for _ = 1, 12 do
        model:key(Key.DOWN)
        t.ok(cursor_row(model:lines(tall(10))), "cursor row missing")
    end
    for _ = 1, 12 do
        model:key(Key.UP)
        t.ok(cursor_row(model:lines(tall(10))), "cursor row missing")
    end
end)

t.test("the first draw of a tall list shows only a down indicator", function()
    local lines = picker.new(many(30), { title = "Pick" }):lines(tall(10))
    t.eq(lines[#lines - 1], "↓ 23 more")
    for _, line in ipairs(lines) do
        t.ok(not line:find("^↑ %d+ more"), line)
    end
end)

t.test("at the end of a tall list only an up indicator shows", function()
    local model = picker.new(many(30), { title = "Pick" })
    press(model, { Key.END })
    local lines = model:lines(tall(10))
    t.eq(#lines, 10)
    t.eq(lines[2], "↑ 23 more")
    t.ok(lines[#lines - 1]:find("Row 30", 1, true))
    for _, line in ipairs(lines) do
        t.ok(not line:find("^↓ %d+ more"), line)
    end
end)

t.test("in the middle both indicators count the rows cut off", function()
    local model = picker.new(many(30), { title = "Pick" })
    for _ = 1, 12 do
        model:key(Key.DOWN)
    end
    local lines = model:lines(tall(10))
    local up = tonumber(lines[2]:match("^↑ (%d+) more$"))
    local down = tonumber(lines[#lines - 1]:match("^↓ (%d+) more$"))
    t.eq(up + down + (#lines - 4), 30)
end)

t.test("toggles take one line from the window", function()
    local toggles = { { key = "d", value = "--dry-run", label = "Dry run" } }
    local lines = picker.new(many(30), { title = "Pick", toggles = toggles }):lines(tall(10))
    t.eq(#lines, 10)
    t.eq(lines[#lines - 1], "[ ] d Dry run")
end)

t.test("pgdn and pgup move by a window and home and end by the list", function()
    local model = picker.new(many(30), { title = "Pick" })
    model:lines(tall(10))
    press(model, { Key.PGDN, Key.ENTER })
    t.eq(model:result(), "v9")
    model = picker.new(many(30), { title = "Pick" })
    model:lines(tall(10))
    press(model, { Key.PGDN, Key.PGUP, Key.ENTER })
    t.eq(model:result(), "v1")
    model = picker.new(many(30), { title = "Pick" })
    press(model, { Key.END, Key.ENTER })
    t.eq(model:result(), "v30")
    model = picker.new(many(30), { title = "Pick" })
    press(model, { Key.END, Key.HOME, Key.ENTER })
    t.eq(model:result(), "v1")
end)

t.test("paging and the ends skip disabled rows", function()
    local list = many(30)
    list[30].disabled = "no"
    list[9].disabled = "no"
    local model = picker.new(list, { title = "Pick" })
    model:lines(tall(10))
    press(model, { Key.END, Key.ENTER })
    t.eq(model:result(), "v29")
    model = picker.new(list, { title = "Pick" })
    model:lines(tall(10))
    press(model, { Key.PGDN, Key.ENTER })
    t.eq(model:result(), "v10")
end)

t.test("paging goes past a run of disabled rows", function()
    local list = many(30)
    for i = 2, 11 do
        list[i].disabled = "no"
    end
    local model = picker.new(list, { title = "Pick" })
    model:lines(tall(10))
    press(model, { Key.PGDN, Key.ENTER })
    t.eq(model:result(), "v12")
    list = many(30)
    for i = 20, 29 do
        list[i].disabled = "no"
    end
    model = picker.new(list, { title = "Pick", initial = "v30" })
    model:lines(tall(10))
    press(model, { Key.PGUP, Key.ENTER })
    t.eq(model:result(), "v19")
end)

t.test("paging and the ends stay put when the cursor row is the only enabled one", function()
    for _, key in ipairs({ Key.PGUP, Key.PGDN, Key.HOME, Key.END }) do
        local list = many(30)
        for i = 1, 30 do
            list[i].disabled = i ~= 15 and "no" or nil
        end
        local model = picker.new(list, { title = "Pick" })
        model:lines(tall(10))
        press(model, { key, Key.ENTER })
        t.eq(model:result(), "v15")
    end
end)

t.test("an empty list draws at any height without looping", function()
    for _, height in ipairs({ 0, 1, 10 }) do
        t.eq(#picker.new({}, { title = "P" }):lines(tall(height)), 2)
    end
end)

t.test("a tall list at a tiny height draws the 3-line minimum window", function()
    for _, height in ipairs({ 0, 1, 4 }) do
        local model = picker.new(many(30), { title = "P" })
        t.eq(#model:lines(tall(height)), 5)
        press(model, { Key.END })
        t.eq(#model:lines(tall(height)), 5)
    end
    local toggles = { { key = "d", value = "--dry-run", label = "Dry run" } }
    t.eq(#picker.new(many(30), { title = "P", toggles = toggles }):lines(tall(0)), 6)
end)

t.test("with no height every row is drawn", function()
    t.eq(#picker.new(many(30), { title = "P" }):lines(plain), 32)
end)

t.test("building a context never reads the height and with_height copies it", function()
    local asked = 0
    local ctx = ui.context({
        color = false,
        interactive = true,
        width = 80,
        size = function()
            asked = asked + 1
            return 10, 80
        end,
    })
    t.eq(ctx.height, nil)
    t.eq(ctx:with_height(7).height, 7)
    t.eq(asked, 0)
end)
