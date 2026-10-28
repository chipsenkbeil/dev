local board = require("dev.board")

local NEEDS_ADMIN = "pomb answered 403"
local ADMIN_HINT = "; this token may not change this board, run dev board init --admin"

---The standard board: the seven columns, the size palette and names without
---size words, laid out one step at a time. Each step adds or fixes what is
---missing and never deletes or renames. The default colour changes last, so
---a run that stops early can be repeated and still tell the old default.
---@class dev.board.init
local M = {}

---@class dev.board.init.Swatch
---@field value string the colour's standard value
---@field label string the name a card's size goes by
---@field description string the legend text

---The five colours that carry a size, in size order, then White for no size.
---@type dev.board.init.Swatch[]
M.PALETTE = {
    { value = "yellow", label = "1 Pomodoro", description = "One pomodoro or less" },
    { value = "green", label = "2 Pomodori", description = "Two pomodori" },
    { value = "blue", label = "3 Pomodori", description = "Three pomodori" },
    { value = "red", label = ">3 Pomodori", description = "More than three, split it first" },
    { value = "white", label = "Unsized", description = "Never sized" },
}

local DEFAULT_VALUE = "white"

local SIZE_WORDS = {
    { text = "red, split", value = "red" },
    { text = "yellow", value = "yellow" },
    { text = "green", value = "green" },
    { text = "blue", value = "blue" },
    { text = "red", value = "red" },
}

local function quoted(text)
    return '"' .. text .. '"'
end

---Split a trailing size word off a card's name.
---@param name string the card's name
---@return string? stripped the name without `(yellow)`, `(green)`, `(blue)`, `(red)` or `(red, split)`
---@return string? value the standard colour value the word names
function M.split_size(name)
    local found, value
    local again = true
    while again do
        again = false
        for _, word in ipairs(SIZE_WORDS) do
            local stripped = name:match("^(.-)%s*%(" .. word.text .. "%)$")
            if stripped then
                name, found, again = stripped, stripped, true
                value = value or word.value
                break
            end
        end
    end
    return found, value
end

local function advise(message)
    if message:find(NEEDS_ADMIN, 1, true) then
        return message .. ADMIN_HINT
    end
    return message
end

local function by_name(columns)
    local found = {}
    for _, column in ipairs(columns) do
        local key = column.name:lower()
        found[key] = found[key] or column
    end
    return found
end

local function columns_step(layout, state, say)
    local present = by_name(state.columns)
    local added = false
    for _, name in ipairs(board.COLUMNS) do
        if not present[name:lower()] then
            local ok, message = layout:add_column(name, name == board.DONE)
            if not ok then
                return nil, message
            end
            say("added column " .. name)
            state.changes = state.changes + 1
            added = true
        end
    end
    if added then
        local fresh, message = layout:read()
        if not fresh then
            return nil, message
        end
        state.columns = fresh.columns
        present = by_name(state.columns)
    end
    for _, name in ipairs(board.COLUMNS) do
        if not present[name:lower()] then
            return nil, "the board still has no " .. name .. " column after adding it"
        end
    end
    local done = present[board.DONE:lower()]
    if not done.is_done then
        local ok, message = layout:mark_done(done.id)
        if not ok then
            return nil, message
        end
        say("marked " .. done.name .. " as the column of finished cards")
        state.changes = state.changes + 1
    end
    local want, used = {}, {}
    for _, name in ipairs(board.COLUMNS) do
        local column = present[name:lower()]
        want[#want + 1] = column
        used[column.id] = true
    end
    for _, column in ipairs(state.columns) do
        if not used[column.id] then
            want[#want + 1] = column
            say(
                "kept column " .. quoted(column.name) .. ", which is not part of the standard board"
            )
        end
    end
    local order = {}
    for index, column in ipairs(state.columns) do
        order[index] = column.id
    end
    for index, column in ipairs(want) do
        if order[index] ~= column.id then
            local ok, message = layout:move_column(column.id, index - 1)
            if not ok then
                return nil, message
            end
            for at, id in ipairs(order) do
                if id == column.id then
                    table.remove(order, at)
                    break
                end
            end
            table.insert(order, index, column.id)
            say("moved column " .. column.name .. " to position " .. (index - 1))
            state.changes = state.changes + 1
        end
    end
    return true
end

local function palette_step(layout, state, say)
    local by_value = {}
    for _, color in ipairs(state.colors) do
        by_value[color.value] = color
        if color.is_default then
            state.old_default = color.id
        end
    end
    for _, swatch in ipairs(M.PALETTE) do
        local color = by_value[swatch.value]
        if not color then
            return nil,
                "the board has no " .. swatch.value .. " colour, which only an admin can add"
        end
        local fields = {}
        if color.label ~= swatch.label then
            fields.label = swatch.label
        end
        if color.description ~= swatch.description then
            fields.description = swatch.description
        end
        if next(fields) then
            local ok, message = layout:set_color(color.id, fields)
            if not ok then
                return nil, message
            end
            say("named " .. swatch.value .. " " .. quoted(swatch.label))
            state.changes = state.changes + 1
        end
    end
    state.by_value = by_value
    return true
end

local function default_step(layout, state, say)
    local default = state.by_value[DEFAULT_VALUE]
    if not default.is_default then
        local ok, message = layout:set_color(default.id, { is_default = true })
        if not ok then
            return nil, message
        end
        say("made " .. default.value .. " the default colour")
        state.changes = state.changes + 1
    end
    return true
end

local function strip_step(layout, state, say)
    local white = state.by_value[DEFAULT_VALUE].id
    for _, card in ipairs(state.cards) do
        local stripped, value = M.split_size(card.name)
        if stripped and stripped == "" then
            say(
                "kept card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. ", whose name is only a size word"
            )
        elseif stripped then
            local fields = { name = stripped }
            local plain = card.color_id == nil
                or card.color_id == white
                or card.color_id == state.old_default
            local note = ""
            if plain then
                fields.color_id = state.by_value[value].id
                note = " and coloured it " .. value
            end
            local ok, message = layout:set_card(card.id, fields)
            if not ok then
                return nil, message
            end
            say(
                "renamed card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " to "
                    .. quoted(stripped)
                    .. note
            )
            state.changes = state.changes + 1
        end
    end
    return true
end

---Bring a board to the standard, saying each change as it is made.
---@param layout dev.board.Layout the board to lay out
---@param name string the board's name
---@param say fun(line: string) prints one line
---@return integer? changes how many changes were made
---@return string? message why it stopped, with the changes made so far already said
function M.run(layout, name, say)
    local state = { changes = 0 }
    local found, message = layout:find()
    if found == nil then
        return nil, advise(message)
    end
    if not found then
        local ok, template
        ok, template = layout:create()
        if not ok then
            return nil, advise(template)
        end
        say(
            "created board "
                .. name
                .. (template and (" from the " .. template .. " template") or " with no template")
        )
        state.changes = 1
    end
    local layout_state
    layout_state, message = layout:read()
    if not layout_state then
        return nil, advise(message)
    end
    state.columns, state.colors, state.cards =
        layout_state.columns, layout_state.colors, layout_state.cards
    for _, step in ipairs({ columns_step, palette_step, strip_step, default_step }) do
        local ok
        ok, message = step(layout, state, say)
        if not ok then
            return nil, advise(message)
        end
    end
    return state.changes
end

return M
