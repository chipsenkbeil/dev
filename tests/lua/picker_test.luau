local testing = require("@dev/testing")
local text = require("@dev/text")
local ui = require("@dev/ui")
local picker = require("@dev/ui/picker")
local term = require("@dev/term")

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

testing.test("down then enter picks the second item", function()
    local model = picker.new(items(), { title = "Pick" })
    testing.eq(press(model, { Key.DOWN, Key.ENTER }), picker.Outcome.PICK)
    testing.eq(model:result(), "two")
end)

testing.test("up from the first item stays on the first", function()
    local model = picker.new(items(), { title = "Pick" })
    press(model, { Key.UP, Key.ENTER })
    testing.eq(model:result(), "one")
end)

testing.test("initial puts the cursor on that value", function()
    local model = picker.new(items(), { title = "Pick", initial = "three" })
    press(model, { Key.ENTER })
    testing.eq(model:result(), "three")
end)

testing.test("down skips a disabled item", function()
    local list = items()
    list[2].disabled = "needs 8 GiB more"
    local model = picker.new(list, { title = "Pick" })
    press(model, { Key.DOWN, Key.ENTER })
    testing.eq(model:result(), "three")
end)

testing.test(
    "a disabled first item is skipped and a lone disabled item cannot be picked",
    function()
        local list = items()
        list[1].disabled = "needs 8 GiB more"
        local model = picker.new(list, { title = "Pick" })
        press(model, { Key.ENTER })
        testing.eq(model:result(), "two")
        list = { { value = "x", cells = { "X" }, disabled = "no" } }
        model = picker.new(list, { title = "Pick" })
        testing.eq(model:key(Key.ENTER), nil)
        testing.eq(model:result(), nil)
    end
)

testing.test("esc, q and ctrl-c cancel with no result", function()
    for _, name in ipairs({ Key.ESC, "q", Key.CTRL_C }) do
        local model = picker.new(items(), { title = "Pick" })
        testing.eq(model:key(name), picker.Outcome.CANCEL)
        testing.eq(model:result(), nil)
    end
end)

testing.test("multi mode: space then a then enter returns every value", function()
    local model = picker.new(items(), { title = "Pick", multi = true })
    press(model, { Key.SPACE, "a", Key.ENTER })
    testing.eq(model:result(), { "one", "two", "three" })
end)

testing.test("multi mode: a twice clears every box", function()
    local model = picker.new(items(), { title = "Pick", multi = true })
    press(model, { "a", "a", Key.ENTER })
    testing.eq(model:result(), {})
end)

testing.test("multi mode: a leaves disabled items unchecked", function()
    local list = items()
    list[2].disabled = "no"
    local model = picker.new(list, { title = "Pick", multi = true })
    press(model, { "a", Key.ENTER })
    testing.eq(model:result(), { "one", "three" })
end)

testing.test("multi mode: a row marked checked starts checked", function()
    local list = items()
    list[1].checked = true
    list[3].checked = true
    local model = picker.new(list, { title = "Pick", multi = true })
    press(model, { Key.ENTER })
    testing.eq(model:result(), { "one", "three" })
end)

testing.test("a checked row is ignored outside multi mode and when disabled", function()
    -- Mark two rows checked, one of them disabled
    local list = items()
    list[1].checked = true
    list[2].checked = true
    list[2].disabled = "no"

    -- Expect only the enabled checked row in a multi picker's result
    local model = picker.new(list, { title = "Pick", multi = true })
    press(model, { Key.ENTER })
    testing.eq(model:result(), { "one" })

    -- Expect no checked rows to matter outside multi mode
    model = picker.new(items(), { title = "Pick" })
    press(model, { Key.ENTER })
    testing.eq(model:result(), "one")
end)

testing.test("required multi mode: enter waits until a row is checked", function()
    -- Start a picker that needs one row checked
    local model = picker.new(items(), { title = "Pick", multi = true, required = true })

    -- Expect enter to wait while nothing is checked
    testing.eq(press(model, { Key.ENTER }), nil)
    testing.eq(model:result(), nil)

    -- Expect enter to pick once a row is checked
    testing.eq(press(model, { Key.SPACE, Key.ENTER }), picker.Outcome.PICK)
    testing.eq(model:result(), { "one" })
end)

testing.test(
    "required multi mode: clearing every box blocks enter again, and q still cancels",
    function()
        -- Start a required picker with one row checked
        local list = items()
        list[1].checked = true
        local model = picker.new(list, { title = "Pick", multi = true, required = true })

        -- Expect unchecking that row to block enter
        testing.eq(press(model, { Key.SPACE, Key.ENTER }), nil)

        -- Expect q to cancel regardless
        testing.eq(press(model, { "q" }), picker.Outcome.CANCEL)
        testing.eq(model:result(), nil)
    end
)

testing.test("a toggle flips its value in the result", function()
    -- Offer a dry-run toggle
    local toggles = { { key = "d", value = "--dry-run", label = "Dry run" } }

    -- Expect one press to turn it on in the result
    local model = picker.new(items(), { title = "Pick", toggles = toggles })
    press(model, { "d", Key.ENTER })
    testing.eq(model:result(), { values = "one", toggles = { "--dry-run" } })

    -- Expect a second press to turn it off again
    model = picker.new(items(), { title = "Pick", toggles = toggles })
    press(model, { "d", "d", Key.ENTER })
    testing.eq(model:result(), { values = "one", toggles = {} })
end)

testing.test("a toggle that starts on is on in the result", function()
    local toggles = { { key = "d", value = "--dry-run", label = "Dry run", on = true } }
    local model = picker.new(items(), { title = "Pick", toggles = toggles })
    press(model, { Key.ENTER })
    testing.eq(model:result().toggles, { "--dry-run" })
end)

testing.test("lines stay within the width", function()
    -- Make a narrow screen and a list with long cells and a long disabled reason
    local ctx = ui.context({ color = false, interactive = true, width = 30 })
    local list = items()
    list[1].cells = { "A-very-long-name-with-é", "and a long description" }
    list[2].disabled = "needs 8 GiB more than this box has"

    -- Add a toggle with a long label and a long note
    local toggles = { { key = "d", value = "--dry-run", label = "Dry run with a long label" } }
    local model =
        picker.new(list, { title = "Pick a box", note = "a long note here", toggles = toggles })

    -- Expect every drawn line to fit the width
    for _, line in ipairs(model:lines(ctx)) do
        testing.ok(text.width(line) <= 30, line)
    end
end)

testing.test("the last line is the hint", function()
    local lines = picker.new(items(), { title = "Pick" }):lines(plain)
    testing.eq(lines[#lines], "↑/↓ move · enter pick · esc cancel")
end)

testing.test("the title is bold with a dim note and the cursor row has the cursor", function()
    local ctx = ui.context({ color = true, interactive = true, width = 80 })
    local lines = picker.new(items(), { title = "Pick", note = "note" }):lines(ctx)
    testing.eq(lines[1], "\27[1mPick\27[0m \27[2mnote\27[0m")
    testing.ok(lines[2]:find("❯", 1, true))
    testing.ok(not lines[3]:find("❯", 1, true))
end)

testing.test("a disabled row shows its reason", function()
    local list = items()
    list[2].disabled = "needs 8 GiB more"
    local lines = picker.new(list, { title = "Pick" }):lines(plain)
    testing.ok(lines[3]:find("needs 8 GiB more", 1, true))
end)

testing.test("multi rows show boxes and the toggle line shows its key", function()
    -- Make a multi picker with a toggle
    local toggles = { { key = "d", value = "--dry-run", label = "Dry run" } }
    local model = picker.new(items(), { title = "Pick", multi = true, toggles = toggles })

    -- Check the first row
    press(model, { Key.SPACE })

    -- Expect boxes on the rows and the toggle's key on its line
    local lines = model:lines(plain)
    testing.ok(lines[2]:find("[x]", 1, true))
    testing.ok(lines[3]:find("[ ]", 1, true))
    testing.eq(lines[#lines - 1], "[ ] d Dry run")
end)

testing.test("run with auto returns the only enabled item without drawing", function()
    local list = items()
    list[1].disabled = "no"
    list[3].disabled = "no"
    testing.eq(picker.run(plain, list, { title = "Pick", auto = true }), "two")
    testing.eq(picker.run(plain, list, { title = "Pick", auto = true, multi = true }), { "two" })
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

testing.test("a list that fits draws with no indicator whatever the height", function()
    local lines = picker.new(items(), { title = "Pick" }):lines(tall(5))
    testing.eq(#lines, 5)
    for _, line in ipairs(lines) do
        testing.ok(not line:find("more", 1, true), line)
    end
end)

testing.test("a tall list never draws more lines than the height", function()
    local model = picker.new(many(30), { title = "Pick" })
    for _ = 1, 40 do
        testing.ok(#model:lines(tall(10)) <= 10)
        model:key(Key.DOWN)
    end
end)

testing.test("a tall list keeps the cursor row in the window as it moves", function()
    -- Start a tall list at the top
    local model = picker.new(many(30), { title = "Pick" })

    -- Expect the cursor row to stay in view moving down
    for _ = 1, 12 do
        model:key(Key.DOWN)
        testing.ok(cursor_row(model:lines(tall(10))), "cursor row missing")
    end

    -- Expect it to stay in view moving back up
    for _ = 1, 12 do
        model:key(Key.UP)
        testing.ok(cursor_row(model:lines(tall(10))), "cursor row missing")
    end
end)

testing.test("the first draw of a tall list shows only a down indicator", function()
    local lines = picker.new(many(30), { title = "Pick" }):lines(tall(10))
    testing.eq(lines[#lines - 1], "↓ 23 more")
    for _, line in ipairs(lines) do
        testing.ok(not line:find("^↑ %d+ more"), line)
    end
end)

testing.test("at the end of a tall list only an up indicator shows", function()
    -- Jump to the end of a tall list
    local model = picker.new(many(30), { title = "Pick" })
    press(model, { Key.END })

    -- Expect the window to end on the last row under an up indicator
    local lines = model:lines(tall(10))
    testing.eq(#lines, 10)
    testing.eq(lines[2], "↑ 23 more")
    testing.ok(lines[#lines - 1]:find("Row 30", 1, true))

    -- Expect no down indicator
    for _, line in ipairs(lines) do
        testing.ok(not line:find("^↓ %d+ more"), line)
    end
end)

testing.test("in the middle both indicators count the rows cut off", function()
    -- Move a tall list's cursor to the middle
    local model = picker.new(many(30), { title = "Pick" })
    for _ = 1, 12 do
        model:key(Key.DOWN)
    end

    -- Read the counts the two indicators show
    local lines = model:lines(tall(10))
    local up = tonumber(lines[2]:match("^↑ (%d+) more$"))
    local down = tonumber(lines[#lines - 1]:match("^↓ (%d+) more$"))

    -- Expect the counts and the visible rows to cover every row
    testing.eq(up + down + (#lines - 4), 30)
end)

testing.test("toggles take one line from the window", function()
    local toggles = { { key = "d", value = "--dry-run", label = "Dry run" } }
    local lines = picker.new(many(30), { title = "Pick", toggles = toggles }):lines(tall(10))
    testing.eq(#lines, 10)
    testing.eq(lines[#lines - 1], "[ ] d Dry run")
end)

testing.test("pgdn and pgup move by a window and home and end by the list", function()
    -- Expect a page down to move by one window
    local model = picker.new(many(30), { title = "Pick" })
    model:lines(tall(10))
    press(model, { Key.PGDN, Key.ENTER })
    testing.eq(model:result(), "v9")

    -- Expect a page up to come back to the first row
    model = picker.new(many(30), { title = "Pick" })
    model:lines(tall(10))
    press(model, { Key.PGDN, Key.PGUP, Key.ENTER })
    testing.eq(model:result(), "v1")

    -- Expect end to jump to the last row
    model = picker.new(many(30), { title = "Pick" })
    press(model, { Key.END, Key.ENTER })
    testing.eq(model:result(), "v30")

    -- Expect home to jump back to the first row
    model = picker.new(many(30), { title = "Pick" })
    press(model, { Key.END, Key.HOME, Key.ENTER })
    testing.eq(model:result(), "v1")
end)

testing.test("paging and the ends skip disabled rows", function()
    -- Disable the last row and the row a page down would land on
    local list = many(30)
    list[30].disabled = "no"
    list[9].disabled = "no"

    -- Expect end to land on the last enabled row
    local model = picker.new(list, { title = "Pick" })
    model:lines(tall(10))
    press(model, { Key.END, Key.ENTER })
    testing.eq(model:result(), "v29")

    -- Expect a page down to skip past the disabled row
    model = picker.new(list, { title = "Pick" })
    model:lines(tall(10))
    press(model, { Key.PGDN, Key.ENTER })
    testing.eq(model:result(), "v10")
end)

testing.test("paging goes past a run of disabled rows", function()
    -- Disable a run of rows after the first
    local list = many(30)
    for i = 2, 11 do
        list[i].disabled = "no"
    end

    -- Expect a page down to land past the run
    local model = picker.new(list, { title = "Pick" })
    model:lines(tall(10))
    press(model, { Key.PGDN, Key.ENTER })
    testing.eq(model:result(), "v12")

    -- Disable a run of rows before the last
    list = many(30)
    for i = 20, 29 do
        list[i].disabled = "no"
    end

    -- Expect a page up from the last row to land before the run
    model = picker.new(list, { title = "Pick", initial = "v30" })
    model:lines(tall(10))
    press(model, { Key.PGUP, Key.ENTER })
    testing.eq(model:result(), "v19")
end)

testing.test("paging and the ends stay put when the cursor row is the only enabled one", function()
    for _, key in ipairs({ Key.PGUP, Key.PGDN, Key.HOME, Key.END }) do
        local list = many(30)
        for i = 1, 30 do
            list[i].disabled = i ~= 15 and "no" or nil
        end
        local model = picker.new(list, { title = "Pick" })
        model:lines(tall(10))
        press(model, { key, Key.ENTER })
        testing.eq(model:result(), "v15")
    end
end)

testing.test("an empty list draws at any height without looping", function()
    for _, height in ipairs({ 0, 1, 10 }) do
        testing.eq(#picker.new({}, { title = "P" }):lines(tall(height)), 2)
    end
end)

testing.test("a tall list at a tiny height draws the 3-line minimum window", function()
    for _, height in ipairs({ 0, 1, 4 }) do
        local model = picker.new(many(30), { title = "P" })
        testing.eq(#model:lines(tall(height)), 5)
        press(model, { Key.END })
        testing.eq(#model:lines(tall(height)), 5)
    end
    local toggles = { { key = "d", value = "--dry-run", label = "Dry run" } }
    testing.eq(#picker.new(many(30), { title = "P", toggles = toggles }):lines(tall(0)), 6)
end)

testing.test("with no height every row is drawn", function()
    testing.eq(#picker.new(many(30), { title = "P" }):lines(plain), 32)
end)

testing.test("building a context never reads the height and with_height copies it", function()
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
    testing.eq(ctx.height, nil)
    testing.eq(ctx:with_height(7).height, 7)
    testing.eq(asked, 0)
end)
