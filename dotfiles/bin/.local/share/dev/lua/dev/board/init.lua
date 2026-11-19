local board = require("dev.board")
local verb = require("dev.verb")

---The standard board: the nine columns, the size palette and names without
---size words, laid out one step at a time. Each step adds or fixes what is
---missing, renames only In Review and never deletes. The default colour changes before the
---limit group, so a run that stops early can be repeated and still tell the old default.
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

---The labels a board highlights, with their colours.
---@type dev.board.Highlight[]
M.HIGHLIGHTS = {
    { label = board.NEEDS_HUMAN, color = "#b8461f" },
    { label = board.NEEDS_LEAD, color = "#2f6fab" },
    { label = board.NEEDS_PLANNER, color = "#7a5ab0" },
}

local DEFAULT_VALUE = "white"
local LIMIT_GROUP_CARDS = 4

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
---@return string? stripped the name without `(yellow)`, `(green)`, `(blue)`, `(red)` or
---   `(red, split)`
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

local function needs_admin(message)
    local NEEDS_ADMIN = "pomb answered 403"
    return message:lower():find(NEEDS_ADMIN, 1, true) ~= nil
end

local function advise(message)
    local ADMIN_HINT = ". This token may not change this board, so run `dev board init --admin`."
    if needs_admin(message) then
        return (message:gsub("%.$", "")) .. ADMIN_HINT
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
    local RENAMED_FROM = "In Review"
    local present = by_name(state.columns)
    local added = false
    local standard = state.stages.list
    local review = state.stages.review
    local from, to = RENAMED_FROM:lower(), review:lower()
    local old = present[from]
    if old and not present[to] and to ~= from then
        local ok, message = layout:rename_column(old.id, review)
        if not ok then
            return nil, message
        end
        say("renamed column " .. old.name .. " to " .. review)
        state.changes = state.changes + 1
        present[from] = nil
        old.name = review
        present[to] = old
    end
    local done_name = standard[#standard]
    for _, name in ipairs(standard) do
        if not present[name:lower()] then
            local ok, message = layout:add_column(name, name == done_name)
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
    for _, name in ipairs(standard) do
        if not present[name:lower()] then
            return nil, "the board still has no " .. name .. " column after adding it"
        end
    end
    local done = present[done_name:lower()]
    if not done.is_done then
        local ok, message = layout:mark_done(done.id)
        if not ok then
            return nil, message
        end
        say("marked " .. done.name .. " as the column of finished cards")
        state.changes = state.changes + 1
    end
    local blocked = present[state.stages.blocked:lower()]
    if blocked.is_blocked == nil then
        return nil,
            "This Pomb cannot mark a Blocked column yet, and `dev board ask` needs it. "
                .. "Update Pomb and run `dev board init` again."
    end
    if not blocked.is_blocked then
        local ok, message, changed = layout:mark_blocked(blocked.id)
        if not ok then
            return nil, message
        end
        if changed then
            say("marked " .. blocked.name .. " as the column of cards waiting on an answer")
            state.changes = state.changes + 1
        end
    end
    local stages = state.stages
    for _, stage in ipairs({
        { column = stages.ready, name = "ready" },
        { column = stages.progress, name = "in_progress" },
        { column = stages.review, name = "review" },
        { column = stages.verify, name = "verify" },
        { column = stages.release, name = "release" },
    }) do
        local column = present[stage.column:lower()]
        if column.outcomes_locked == false then
            local ok, message, changed = layout:lock_outcomes(column.id)
            if not ok then
                return nil, message
            end
            if changed then
                say("locked the outcomes of " .. column.name)
                state.changes = state.changes + 1
            end
        end
        if not column.stage then
            local ok, message, changed = layout:set_stage(column.id, stage.name)
            if not ok then
                return nil, message
            end
            if changed then
                say("set the " .. stage.name .. " stage on " .. column.name)
                state.changes = state.changes + 1
            end
        end
    end
    local want, used = {}, {}
    for _, name in ipairs(standard) do
        local column = present[name:lower()]
        want[#want + 1] = column
        used[column.id] = true
    end
    for _, column in ipairs(state.columns) do
        if not used[column.id] then
            want[#want + 1] = column
            state.warn(
                "Kept column "
                    .. quoted(column.name)
                    .. ", which is not part of the standard board."
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

local function roles_step(layout, state, say)
    local ROLES_UNCHANGED = "agent roles unchanged"
    local created, message, missing = layout:add_roles()
    if created == nil then
        if missing == "roles.unreadable" then
            state.warn(
                "Agent roles not checked, since the roles list could not be read: " .. message
            )
            return true
        end
        if missing == "roles.grant" then
            state.warn("The agent roles are left for `dev board init --admin`.")
            return true
        end
        return nil, message
    end
    if created == false then
        return true
    end
    if #created == 0 then
        say(ROLES_UNCHANGED)
        return true
    end
    say("created agent roles " .. table.concat(created, ", "))
    state.changes = state.changes + 1
    return true
end

local function checks_step(layout, state, say)
    if state.has_checks then
        return true
    end
    local ok, message = layout:add_checks_field()
    if not ok then
        return nil, message
    end
    say("added the checks field " .. board.CHECKS_FIELD)
    state.changes = state.changes + 1
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

local function limits_step(layout, state, say)
    local groups, message = layout:limit_groups()
    if groups == nil then
        return nil, message
    end
    if groups == false or #groups > 0 then
        return true
    end
    local stages = state.stages
    local ok
    ok, message =
        layout:add_limit_group({ stages.progress, stages.review, stages.verify }, LIMIT_GROUP_CARDS)
    if not ok then
        return nil, message
    end
    say(
        "created limit group "
            .. stages.progress
            .. ", "
            .. stages.review
            .. " and "
            .. stages.verify
            .. " at "
            .. LIMIT_GROUP_CARDS
    )
    state.changes = state.changes + 1
    return true
end

local function enabled_step(layout, state, say)
    local LEFT_ENABLED = "Left the colours enabled as they are, since this token may not change them. "
        .. "Run `dev board init --admin`."
    local wanted = {}
    for _, swatch in ipairs(M.PALETTE) do
        wanted[swatch.value] = true
    end
    for _, enable in ipairs({ true, false }) do
        for _, color in ipairs(state.colors) do
            if (wanted[color.value] == true) == enable and color.enabled ~= enable then
                local ok, message = layout:set_color(color.id, { enabled = enable })
                if not ok then
                    if needs_admin(message) then
                        state.warn(LEFT_ENABLED)
                        return true
                    end
                    return nil, message
                end
                color.enabled = enable
                say((enable and "enabled " or "disabled ") .. color.value)
                state.changes = state.changes + 1
            end
        end
    end
    return true
end

local function highlights_step(layout, state, say)
    local LEFT_HIGHLIGHTS = "Left the highlighted labels as they are, since this token may not change them. "
        .. "Run `dev board init --admin`."
    local added, message = layout:add_highlights(M.HIGHLIGHTS)
    if added == nil then
        if needs_admin(message) then
            state.warn(LEFT_HIGHLIGHTS)
            return true
        end
        return nil, message
    end
    for _, label in ipairs(added or {}) do
        say("highlighted " .. label)
        state.changes = state.changes + 1
    end
    return true
end

local function worn_step(_, state)
    local off = {}
    for _, color in ipairs(state.colors) do
        if color.enabled == false then
            off[color.id] = color.value
        end
    end
    for _, card in ipairs(state.cards) do
        local value = card.color_id and off[card.color_id]
        if value then
            state.warn(
                "Card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " wears the disabled colour "
                    .. value
                    .. " and was left as it is."
            )
        end
    end
    return true
end

local function strip_step(layout, state, say)
    local white = state.by_value[DEFAULT_VALUE].id
    for _, card in ipairs(state.cards) do
        local stripped, value = M.split_size(card.name)
        if stripped and stripped == "" then
            state.warn(
                "Kept card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. ", whose name is only a size word."
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

local function turn_step(layout, state, say)
    local card, message, existed = layout:add(board.TURN_NAME, state.stages.icebox, { once = true })
    if not card then
        return nil, message
    end
    if not existed then
        say("created the " .. quoted(board.TURN_NAME) .. " card")
        state.changes = state.changes + 1
    end
    return true
end

local function lanes_step(layout, state, say)
    -- Index the lanes the board has and the lanes the config lists
    local have = {}
    for _, lane in ipairs(state.lanes) do
        have[lane:lower()] = true
    end
    local listed = {}
    for _, lane in ipairs(state.wanted_lanes) do
        listed[lane:lower()] = true
    end

    -- Create each listed lane the board lacks
    for _, lane in ipairs(state.wanted_lanes) do
        if not have[lane:lower()] then
            local ok, message = layout:add_lane(lane)
            if not ok then
                return nil, message
            end
            have[lane:lower()] = true
            say("created lane " .. quoted(lane))
            state.changes = state.changes + 1
        end
    end

    -- Warn when the first lane falls outside the config list
    local first = state.lanes[1]
    if
        state.warn_first_lane
        and first
        and #state.wanted_lanes > 0
        and not listed[first:lower()]
    then
        state.warn(
            "The first lane "
                .. quoted(first)
                .. " is not in the [board] lanes list. "
                .. "Cards filed without --lane land in it. "
                .. "Delete or reorder it in the Pomb UI."
        )
    end
    return true
end

---@class dev.board.Opts
---@field stages? dev.board.Stages the column set to lay out, the standard names when nil
---@field lanes? string[] the lanes the board config lists, an empty list when nil
---@field warn_first_lane? boolean whether to warn when the first lane is unlisted, false when nil
---@field warn? fun(line: string) prints one warning line, standard error when nil

---Bring a board to the standard, saying each change as it is made.
---
---Missing lanes are made in list order, at the end of the lane order.
---@param layout dev.board.Layout the board to lay out
---@param name string the board's name
---@param say fun(line: string) prints one line
---@param opts dev.board.Opts? what to lay out and how, the defaults when nil
---@return integer? changes how many changes were made
---@return string? message why it stopped, with the changes made so far already said
function M.run(layout, name, say, opts)
    opts = opts or {}
    local state = {
        changes = 0,
        stages = opts.stages or board.stages(),
        wanted_lanes = opts.lanes or {},
        warn_first_lane = opts.warn_first_lane or false,
        warn = opts.warn or verb.note,
    }
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
    state.columns, state.colors, state.cards, state.has_checks =
        layout_state.columns, layout_state.colors, layout_state.cards, layout_state.has_checks
    state.lanes = layout_state.lanes or {}
    for _, step in ipairs({
        columns_step,
        roles_step,
        checks_step,
        palette_step,
        strip_step,
        enabled_step,
        default_step,
        limits_step,
        turn_step,
        worn_step,
        lanes_step,
        highlights_step,
    }) do
        local ok
        ok, message = step(layout, state, say)
        if not ok then
            return nil, advise(message)
        end
    end
    return state.changes
end

return M
