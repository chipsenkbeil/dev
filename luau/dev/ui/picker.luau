local term = require("@dev/term")
local text = require("@dev/text")
local ui = require("@dev/ui")

local Key = term.Key
local Style = ui.Style

---@class dev.ui.picker.Item
---@field value string handed back when the row is picked
---@field cells string[] column texts, lined up with the other rows
---@field disabled string? why the row cannot be picked
---@field checked boolean? whether the row starts checked in multi mode

---@class dev.ui.picker.Toggle
---@field key string key that flips it
---@field value string handed back in `toggles` while it is on
---@field label string text after the box
---@field on boolean? whether it starts on

---@class dev.ui.picker.Opts
---@field title string line above the rows
---@field note string? dim text after the title
---@field initial string? value of the row that starts under the cursor
---@field multi boolean? whether several rows can be checked
---@field required boolean? whether enter waits until a row is checked in multi mode
---@field auto boolean? skip the screen when exactly one row is enabled
---@field toggles dev.ui.picker.Toggle[]? on and off choices below the rows

---@class dev.ui.picker.Result
---@field values string|string[] the picked value, or the checked values in multi mode
---@field toggles string[] values of the toggles that are on

---@class dev.ui.picker.Outcome
---@field PICK string the user chose
---@field CANCEL string the user backed out

---@class dev.ui.picker
---@field Outcome dev.ui.picker.Outcome what `Model:key` returns once the user is done
local M = {
    Outcome = {
        PICK = "pick",
        CANCEL = "cancel",
    },
}

local Outcome = M.Outcome

---@class dev.ui.picker.Model
---@field private __items dev.ui.picker.Item[] rows in display order
---@field private __opts dev.ui.picker.Opts options the picker was made with
---@field private __multi boolean whether several rows can be checked
---@field private __checked table<integer, boolean> mapping of row index -> checked
---@field private __has_toggles boolean whether the options list toggles
---@field private __toggles dev.ui.picker.Toggle[] toggles with their current `on`
---@field private __cursor integer index of the row under the cursor
---@field private __top integer index of the first row in the window
---@field private __page integer rows `pgup` and `pgdn` move by
---@field private __outcome string? `Outcome` value once the user is done
local Model = {}
Model.__index = Model

local HINT = "↑/↓ move · enter pick · esc cancel"
local CURSOR = "❯"
local QUIT_KEY = "q"
local ALL_KEY = "a"
local ENTER_SCREEN = "\27[?1049h\27[?25l"
local LEAVE_SCREEN = "\27[?25h\27[?1049l"
local CLEAR = "\27[H\27[J"
local DEFAULT_PAGE = 10
local MIN_WINDOW = 3

local function first_enabled(items)
    for i, item in ipairs(items) do
        if not item.disabled then
            return i
        end
    end
    return 1
end

---Make a picker over `items`.
---@param items dev.ui.picker.Item[] rows in display order
---@param opts dev.ui.picker.Opts how to show and what to allow
---@return dev.ui.picker.Model model a picker with the cursor on the first enabled row
function M.new(items, opts)
    local model = setmetatable({
        __items = items,
        __opts = opts,
        __multi = opts.multi == true,
        __checked = {},
        __has_toggles = opts.toggles ~= nil,
        __toggles = {},
        __cursor = first_enabled(items),
        __top = 1,
        __page = DEFAULT_PAGE,
        __outcome = nil,
    }, Model)
    for i, item in ipairs(items) do
        if model.__multi and item.checked and not item.disabled then
            model.__checked[i] = true
        end
        if item.value == opts.initial and not item.disabled then
            model.__cursor = i
            break
        end
    end
    for i, toggle in ipairs(opts.toggles or {}) do
        model.__toggles[i] = {
            key = toggle.key,
            value = toggle.value,
            label = toggle.label,
            on = toggle.on == true,
        }
    end
    return model
end

---Pick row `index` as if the user had chosen it.
---@private
---@param index integer row to pick
function Model:__pick_only(index)
    self.__cursor = index
    self.__checked[index] = true
    self.__outcome = Outcome.PICK
end

---Move the cursor to the next enabled row in a direction.
---@private
---@param step integer -1 to move up, 1 to move down
function Model:__move(step)
    local at = self.__cursor + step
    while self.__items[at] do
        if not self.__items[at].disabled then
            self.__cursor = at
            return
        end
        at = at + step
    end
end

---Move the cursor to the first enabled row at or past `target` in a direction.
---
---With none before the end of the list, it takes the nearest enabled row between `target` and
---the cursor, and stays put when there is none.
---@private
---@param target integer row to aim for, cut to the list
---@param step integer 1 to look further down from there, -1 to look further up
function Model:__jump(target, step)
    local items = self.__items
    local from = math.max(1, math.min(#items, target))
    local at = from
    while items[at] and items[at].disabled do
        at = at + step
    end
    if not items[at] then
        at = from
        while items[at] and items[at].disabled and at ~= self.__cursor do
            at = at - step
        end
    end
    if items[at] and not items[at].disabled then
        self.__cursor = at
    end
end

---Check every enabled row, or clear them all when they are all checked.
---@private
function Model:__flip_all()
    local all = true
    for i, item in ipairs(self.__items) do
        all = all and (item.disabled or self.__checked[i] == true)
    end
    for i, item in ipairs(self.__items) do
        if not item.disabled then
            self.__checked[i] = not all
        end
    end
end

---Tell whether enter may finish, which a required multi picker allows once a row is checked.
---@private
---@return boolean ok false while a required multi picker has no row checked
function Model:__may_finish()
    if not (self.__multi and self.__opts.required) then
        return true
    end
    for i, item in ipairs(self.__items) do
        if self.__checked[i] and not item.disabled then
            return true
        end
    end
    return false
end

---Handle one key.
---
---Esc, q, ctrl-c and end of input cancel. Enter picks the row under the cursor unless it is
---disabled, or a required multi picker has no row checked.
---@param name string key name from `dev.term`
---@return string? outcome `Outcome` value once the user is done, nil while the picker goes on
function Model:key(name)
    if name == Key.ESC or name == QUIT_KEY or name == Key.CTRL_C or name == Key.EOF then
        self.__outcome = Outcome.CANCEL
        return Outcome.CANCEL
    end
    for _, toggle in ipairs(self.__toggles) do
        if name == toggle.key then
            toggle.on = not toggle.on
            return nil
        end
    end
    if name == Key.UP then
        self:__move(-1)
    elseif name == Key.DOWN then
        self:__move(1)
    elseif name == Key.PGUP then
        self:__jump(self.__cursor - self.__page, -1)
    elseif name == Key.PGDN then
        self:__jump(self.__cursor + self.__page, 1)
    elseif name == Key.HOME then
        self:__jump(1, -1)
    elseif name == Key.END then
        self:__jump(#self.__items, 1)
    elseif name == Key.SPACE and self.__multi then
        local item = self.__items[self.__cursor]
        if item and not item.disabled then
            self.__checked[self.__cursor] = not self.__checked[self.__cursor]
        end
    elseif name == ALL_KEY and self.__multi then
        self:__flip_all()
    elseif name == Key.ENTER then
        local item = self.__items[self.__cursor]
        if item and not item.disabled and self:__may_finish() then
            self.__outcome = Outcome.PICK
            return Outcome.PICK
        end
    end
    return nil
end

---Collect what the user picked.
---@return (string|string[]|dev.ui.picker.Result)? result nil unless the user picked; the picked
---   value or checked values, or a result table when the options list toggles
function Model:result()
    if self.__outcome ~= Outcome.PICK then
        return nil
    end
    local picked
    if self.__multi then
        picked = {}
        for i, item in ipairs(self.__items) do
            if self.__checked[i] then
                picked[#picked + 1] = item.value
            end
        end
    else
        picked = self.__items[self.__cursor].value
    end
    if not self.__has_toggles then
        return picked
    end
    local on = {}
    for _, toggle in ipairs(self.__toggles) do
        if toggle.on then
            on[#on + 1] = toggle.value
        end
    end
    return { values = picked, toggles = on }
end

---Measure the columns across all rows.
---@private
---@return integer[] widths width of each column
function Model:__widths()
    local widths = {}
    for _, item in ipairs(self.__items) do
        for c, cell in ipairs(item.cells) do
            widths[c] = math.max(widths[c] or 0, text.width(cell))
        end
    end
    return widths
end

---Draw one row.
---@private
---@param ctx dev.ui.Context drawing settings
---@param i integer index of the row to draw
---@param widths integer[] width of each column
---@return string row the row as shown, before it is cut to the width
function Model:__row(ctx, i, widths)
    local item = self.__items[i]
    local cells = {}
    for c, cell in ipairs(item.cells) do
        local pad = c < #item.cells and string.rep(" ", widths[c] - text.width(cell)) or ""
        cells[c] = cell .. pad
    end
    local row = table.concat(cells, text.GAP)
    local box = ""
    if self.__multi then
        box = self.__checked[i] and "[x] " or "[ ] "
    end
    local marker = i == self.__cursor and CURSOR or " "
    if item.disabled then
        return ui.paint(
            ctx,
            marker .. " " .. box .. row .. text.GAP .. "(" .. item.disabled .. ")",
            Style.DIM
        )
    end
    if i == self.__cursor then
        return ui.paint(ctx, marker, Style.CYAN) .. " " .. box .. row
    end
    return marker .. " " .. box .. row
end

---Find the last row shown for a window that starts at `top`.
---@private
---@param top integer index of the first row in the window
---@param window integer lines the window has, indicators included
---@return integer last index of the last row shown
function Model:__last_shown(top, window)
    local count = #self.__items
    local room = window - (top > 1 and 1 or 0)
    if top + room - 1 >= count then
        return count
    end
    return top + room - 2
end

---Slide the window so the cursor is in it.
---@private
---@param window integer lines the window has, indicators included
---@return integer last index of the last row shown
function Model:__scroll(window)
    local top = math.min(self.__top, self.__cursor)
    while self:__last_shown(top, window) < self.__cursor and top < self.__cursor do
        top = top + 1
    end
    self.__top = top
    return self:__last_shown(top, window)
end

---Draw the picker as lines, each cut to the context's width.
---
---When `ctx.height` is set and the rows do not fit, the rows shown are a window that follows the
---cursor, with a dim `↑ n more` and `↓ n more` line standing in for the rows cut off. The window
---is never under 3 lines, so below 5 rows (6 with toggles) the picker draws more than the height.
---With no `ctx.height` every row is drawn.
---@param ctx dev.ui.Context drawing settings
---@return string[] lines the title, the rows, the toggles when there are any, then the hint
function Model:lines(ctx)
    local out = {}
    local title = ui.paint(ctx, self.__opts.title, Style.BOLD)
    if self.__opts.note then
        title = title .. " " .. ui.paint(ctx, self.__opts.note, Style.DIM)
    end
    out[1] = text.fit(title, ctx.width)

    local widths = self:__widths()
    local count = #self.__items
    local first, last = 1, count
    local window = (ctx.height or 0) - 2 - (self.__has_toggles and 1 or 0)
    if ctx.height and count > 0 and count > window then
        window = math.max(window, MIN_WINDOW)
        self.__page = window
        last = self:__scroll(window)
        first = self.__top
    end
    if first > 1 then
        out[#out + 1] =
            text.fit(ui.paint(ctx, "↑ " .. (first - 1) .. " more", Style.DIM), ctx.width)
    end
    for i = first, last do
        out[#out + 1] = text.fit(self:__row(ctx, i, widths), ctx.width)
    end
    if last < count then
        out[#out + 1] =
            text.fit(ui.paint(ctx, "↓ " .. (count - last) .. " more", Style.DIM), ctx.width)
    end

    if self.__has_toggles then
        local parts = {}
        for i, toggle in ipairs(self.__toggles) do
            parts[i] = (toggle.on and "[x] " or "[ ] ") .. toggle.key .. " " .. toggle.label
        end
        out[#out + 1] = text.fit(table.concat(parts, text.GAP), ctx.width)
    end
    out[#out + 1] = text.fit(ui.paint(ctx, HINT, Style.DIM), ctx.width)
    return out
end

local function only_enabled(items)
    local found
    for i, item in ipairs(items) do
        if not item.disabled then
            if found then
                return nil
            end
            found = i
        end
    end
    return found
end

local function interact(ctx, model, screen)
    while true do
        local drawn = ctx.height and ctx or ctx:with_height((ctx.size()))
        term.write(screen.fd, CLEAR .. table.concat(model:lines(drawn), "\r\n"))
        if model:key(term.read_key(screen.fd)) then
            return model:result()
        end
    end
end

---Show the picker on the controlling terminal and wait for the user.
---
---The terminal is restored on every way out, including an error while drawing. With `auto` set
---and exactly one enabled row, we return that row at once and draw nothing.
---@param ctx dev.ui.Context drawing settings
---@param items dev.ui.picker.Item[] rows in display order
---@param opts dev.ui.picker.Opts how to show and what to allow
---@return (string|string[]|dev.ui.picker.Result)? result what `Model:result` gives, nil when the
---   user cancelled
function M.run(ctx, items, opts)
    local model = M.new(items, opts)
    local only = opts.auto and only_enabled(items)
    if only then
        model:__pick_only(only)
        return model:result()
    end
    local fd = assert(term.open_tty())
    local ok, restore = pcall(term.raw, fd)
    if not ok then
        term.close(fd)
        error(restore, 0)
    end
    term.write(fd, ENTER_SCREEN)
    local done, result = pcall(interact, ctx, model, { fd = fd })
    term.write(fd, LEAVE_SCREEN)
    restore()
    term.close(fd)
    if not done then
        error(result, 0)
    end
    return result
end

return M
