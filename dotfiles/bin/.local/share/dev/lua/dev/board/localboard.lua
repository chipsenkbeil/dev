local board = require("dev.board")
local claims = require("dev.board.claims")
local json = require("dev.json")
local store = require("dev.board.store")

local present = json.present
local SECONDS_PER_MINUTE = 60
local COMMENT_ACTOR = "agent"
local COMMENT_KIND = "agent"
local NOT_YOURS = "that comment is not yours to change"
local INVERSE = {
    [board.LinkKind.BLOCKED_BY] = board.LinkKind.BLOCKS,
    [board.LinkKind.PARENT] = board.LinkKind.CHILD,
}
local SWATCH_VALUES = { "yellow", "green", "blue", "red", "white" }

---A board kept in one JSON file: the columns, the size palette and the cards
---with their comments and claims. Every change takes a lock beside the file,
---reads the file again, and renames a finished copy over it.
---@class dev.board.localboard
local M = {}

---@class dev.board.localboard.Doc
---@field name string the board's name
---@field columns {id: string, name: string, is_done: boolean}[] the columns in board order
---@field colors {id: string, value: string, label: string, description: string, is_default: boolean, enabled: boolean?}[] the palette
---@field cards table<integer, table<string, any>> the cards, each a table of the fields the file holds

---@class dev.board.localboard.Opts
---@field name string the board's name
---@field path string the file that holds the board
---@field private boolean? whether the file is state in the user's own directory, so only its owner may read it

---@class dev.board.localboard.Backend: dev.board.Backend, dev.board.Layout
---@field private __opts dev.board.localboard.Opts the board's name and file
local Backend = {}
Backend.__index = Backend

---Build a local backend.
---@param opts dev.board.localboard.Opts the board's name and file
---@return dev.board.Backend backend the backend
function M.new(opts)
    return setmetatable({ __opts = opts }, Backend)
end

local function missing(path)
    return "no local board at " .. path .. ", run dev board init"
end

function Backend:describe()
    return "local " .. self.__opts.name
end

local function encode(doc)
    local pieces = {}
    local function put(key, value)
        pieces[#pieces + 1] = "  " .. assert(json.encode(key)) .. ": " .. value
    end
    local cards = {}
    for _, card in ipairs(doc.cards) do
        cards[#cards + 1] = "    " .. assert(json.encode(card))
    end
    put("cards", #cards == 0 and "[]" or "[\n" .. table.concat(cards, ",\n") .. "\n  ]")
    local keys = {}
    for key in pairs(doc) do
        if key ~= "cards" then
            keys[#keys + 1] = key
        end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        put(key, assert(json.encode(doc[key])))
    end
    return "{\n" .. table.concat(pieces, ",\n") .. "\n}\n"
end

---@private
---Read the board file and check its shape.
---@return dev.board.localboard.Doc? doc the board file's document
---@return string? message why there is none
function Backend:__read()
    local doc, message = store.read(self.__opts.path)
    if not doc then
        return nil, message or missing(self.__opts.path)
    end
    if type(doc) ~= "table" or type(doc.cards) ~= "table" or type(doc.columns) ~= "table" then
        return nil, self.__opts.path .. " is not a board file"
    end
    doc.colors = doc.colors or {}
    doc.name = doc.name or self.__opts.name
    return doc
end

---@private
---Run a change under the lock and write the board back when it succeeds.
---@param fn fun(doc: dev.board.localboard.Doc): any?, string? the change, which returns its result or nil and a message
---@param opts {create: boolean?}? whether a missing file is made from an empty board
---@return any? result what the change returned
---@return string? message why it failed
function Backend:__update(fn, opts)
    local path = self.__opts.path
    local result, message = store.locked(path, self.__opts, function()
        local doc, why = self:__read()
        if not doc then
            if why ~= missing(path) or not (opts and opts.create) then
                return nil, why
            end
            doc = { name = self.__opts.name, columns = {}, colors = {}, cards = {} }
        end
        local value, problem = fn(doc)
        if value == nil then
            return nil, problem
        end
        local ok, err = store.write(path, encode(doc), self.__opts)
        if not ok then
            return nil, err
        end
        return value
    end)
    return result, message
end

local function find_by_id(list, id)
    for index, item in ipairs(list) do
        if item.id == id then
            return item, index
        end
    end
end

local function column_named(doc, name)
    for _, column in ipairs(doc.columns) do
        if column.name:lower() == name:lower() then
            return column
        end
    end
end

local function color_valued(doc, value)
    for _, color in ipairs(doc.colors) do
        if color.value == value then
            return color
        end
    end
end

local function live(claim)
    if type(claim) ~= "table" or type(claim.claimant) ~= "string" then
        return nil
    end
    if claim.expires_at <= store.stamp() then
        return nil
    end
    return claim
end

local function card_view(doc, card)
    local color = card.color_id and find_by_id(doc.colors, card.color_id)
    local column = find_by_id(doc.columns, card.column_id)
    local claim = live(card.claim)
    return {
        id = card.id,
        name = card.name,
        column = column and column.name or "?",
        done = column ~= nil and column.is_done == true,
        size = board.size(color and color.label),
        color = color and color.value or nil,
        labels = card.labels or {},
        description = card.description,
        checks = card.checks or {},
        allow = board.names(card.allow),
        tests = board.names(card.tests),
        files = board.names(card.files),
        outcomes = card.outcomes or {},
        claimant = claim and claim.claimant or nil,
    }
end

local function ordered(doc)
    local sorted = {}
    for _, column in ipairs(doc.columns) do
        for _, card in ipairs(doc.cards) do
            if card.column_id == column.id then
                sorted[#sorted + 1] = card
            end
        end
    end
    for _, card in ipairs(doc.cards) do
        if not find_by_id(doc.columns, card.column_id) then
            sorted[#sorted + 1] = card
        end
    end
    return sorted
end

local function fenced(card, fence)
    local claim = live(card.claim)
    if fence and claim and claim.fence ~= fence then
        return nil,
            "the claim on "
                .. card.id
                .. " is held by "
                .. claim.claimant
                .. " with fence "
                .. string.format("%d", claim.fence)
    end
    return true
end

local function card_of(doc, id, fence)
    local card = find_by_id(doc.cards, id)
    if not card then
        return nil, "the board has no card " .. id
    end
    local ok, message = fenced(card, fence)
    if not ok then
        return nil, message
    end
    return card
end

function Backend:cards()
    local doc, message = self:__read()
    if not doc then
        return nil, message
    end
    local cards = {}
    for _, card in ipairs(ordered(doc)) do
        cards[#cards + 1] = card_view(doc, card)
    end
    return cards
end

function Backend:card(id)
    local doc, message = self:__read()
    if not doc then
        return nil, message
    end
    local card = find_by_id(doc.cards, id)
    if not card then
        return nil, "the board has no card " .. id
    end
    return card_view(doc, card)
end

function Backend:entered()
    local doc, message = self:__read()
    if not doc then
        return nil, message
    end
    local times = {}
    for _, card in ipairs(doc.cards) do
        times[card.id] = present(card.entered_at)
    end
    return times
end

local function blockers(card)
    local found = {}
    for _, held in ipairs(card.links or {}) do
        if held.kind == board.LinkKind.BLOCKED_BY then
            found[#found + 1] = held.target_id
        end
    end
    return found
end

local function depends_on(doc, from, goal, seen)
    if from == goal then
        return true
    end
    if seen[from] then
        return false
    end
    seen[from] = true
    local card = find_by_id(doc.cards, from)
    for _, blocker in ipairs(card and blockers(card) or {}) do
        if depends_on(doc, blocker, goal, seen) then
            return true
        end
    end
    return false
end

local function umbrella_of(card)
    for _, held in ipairs(card.links or {}) do
        if held.kind == board.LinkKind.PARENT then
            return held.target_id
        end
    end
end

local function children_of(doc, id)
    local found = {}
    for _, other in ipairs(doc.cards) do
        if umbrella_of(other) == id then
            found[#found + 1] = other
        end
    end
    return found
end

local function is_blocked(doc, card)
    for _, blocker in ipairs(blockers(card)) do
        local held = find_by_id(doc.cards, blocker)
        local column = held and find_by_id(doc.columns, held.column_id)
        if held and not (column and column.is_done) then
            return true
        end
    end
    return false
end

function Backend:link(id, kind, other)
    return self:__update(function(doc)
        local card, message = card_of(doc, id)
        if not card then
            return nil, message
        end
        local target
        target, message = card_of(doc, other)
        if not target then
            return nil, message
        end
        if card == target then
            return nil, "a card cannot be linked to itself"
        end
        if kind == board.LinkKind.PARENT then
            local current = umbrella_of(card)
            if current == target.id then
                return true
            end
            if current then
                return nil, "the card already has an umbrella"
            end
            local step, seen = target, {}
            while step and not seen[step.id] do
                if step == card then
                    return nil,
                        "the link would make a cycle of umbrellas between " .. card.id:sub(
                            1,
                            board.MIN_PREFIX
                        ) .. " and " .. target.id:sub(1, board.MIN_PREFIX)
                end
                seen[step.id] = true
                local up = umbrella_of(step)
                step = up and find_by_id(doc.cards, up)
            end
        end
        local holder, held_kind, held_target = card, kind, target
        if kind == board.LinkKind.BLOCKS then
            holder, held_kind, held_target = target, board.LinkKind.BLOCKED_BY, card
        end
        if
            held_kind == board.LinkKind.BLOCKED_BY
            and depends_on(doc, held_target.id, holder.id, {})
        then
            return nil, "the link would make the cards wait on each other"
        end
        holder.links = holder.links or {}
        for _, existing in ipairs(holder.links) do
            if existing.kind == held_kind and existing.target_id == held_target.id then
                return true
            end
        end
        holder.links[#holder.links + 1] = {
            id = store.id(),
            kind = held_kind,
            target_id = held_target.id,
            created_at = store.stamp(),
        }
        return true
    end)
end

local function remove_link(holder, kind, target_id)
    for index, held in ipairs(holder.links or {}) do
        if held.kind == kind and held.target_id == target_id then
            table.remove(holder.links, index)
            return true
        end
    end
    return false
end

function Backend:unlink(id, kind, other)
    return self:__update(function(doc)
        local card, message = card_of(doc, id)
        if not card then
            return nil, message
        end
        local target
        target, message = card_of(doc, other)
        if not target then
            return nil, message
        end
        local holder, held_kind, held_target = card, kind, target
        if kind == board.LinkKind.BLOCKS then
            holder, held_kind, held_target = target, board.LinkKind.BLOCKED_BY, card
        end
        local removed = remove_link(holder, held_kind, held_target.id)
        if not removed and kind == board.LinkKind.RELATED then
            removed = remove_link(target, kind, card.id)
        end
        if not removed then
            return nil, "the card holds no " .. kind .. " link to " .. other
        end
        return true
    end)
end

function Backend:links(id)
    local doc, message = self:__read()
    if not doc then
        return nil, message
    end
    local card = find_by_id(doc.cards, id)
    if not card then
        return nil, "the board has no card " .. id
    end
    local found = {}
    local seen = {}
    for _, held in ipairs(card.links or {}) do
        found[#found + 1] = { kind = held.kind, id = held.target_id }
        seen[held.kind .. held.target_id] = true
    end
    for _, other in ipairs(doc.cards) do
        for _, held in ipairs(other.links or {}) do
            if held.target_id == id then
                local kind = INVERSE[held.kind] or held.kind
                if not seen[kind .. other.id] then
                    seen[kind .. other.id] = true
                    found[#found + 1] = { kind = kind, id = other.id }
                end
            end
        end
    end
    return found
end

function Backend:family(id)
    local doc, message = self:__read()
    if not doc then
        return nil, message
    end
    local card = find_by_id(doc.cards, id)
    if not card then
        return nil, "the board has no card " .. id
    end
    local family = {}
    local umbrella_id = umbrella_of(card)
    local umbrella = umbrella_id and find_by_id(doc.cards, umbrella_id)
    if umbrella then
        family.parent = { id = umbrella.id, name = umbrella.name }
    end
    local children = children_of(doc, id)
    if #children > 0 then
        local done = 0
        for _, child in ipairs(children) do
            local column = find_by_id(doc.columns, child.column_id)
            if column and column.is_done then
                done = done + 1
            end
        end
        family.children = { done = done, total = #children }
    end
    return family
end

function Backend:wait()
    return nil, "a local board has nothing to wait on"
end

function Backend:boards()
    return { self.__opts.name }
end

function Backend:columns(name)
    if name and name ~= self.__opts.name then
        return nil, "a local board knows only its own columns, so " .. name .. " is not reachable"
    end
    local doc, message = self:read()
    if not doc then
        return nil, message
    end
    local rows = {}
    for _, column in ipairs(doc.columns) do
        rows[#rows + 1] = { name = column.name, is_done = column.is_done }
    end
    return rows
end

function Backend:other_board(name)
    return nil, "a local board links only its own cards, so " .. name .. " is not reachable"
end

function Backend:add_checks_field()
    return true
end

function Backend:has_field()
    return true
end

function Backend:done_columns()
    local doc, message = self:__read()
    if not doc then
        return nil, message
    end
    local names = {}
    for _, column in ipairs(doc.columns) do
        if column.is_done == true then
            names[#names + 1] = column.name
        end
    end
    return names
end

function Backend:next(column, opts)
    local label = opts and opts.label
    local doc, message = self:__read()
    if not doc then
        return nil, message
    end
    local target = column_named(doc, column)
    if not target then
        return nil, "the board has no " .. column .. " column, run dev board init"
    end
    for _, card in ipairs(ordered(doc)) do
        if
            card.column_id == target.id
            and not live(card.claim)
            and not is_blocked(doc, card)
            and not board.labelled(card, board.NEEDS_HUMAN)
            and not board.labelled(card, board.RUN)
            and (not label or board.labelled(card, label))
        then
            local view = card_view(doc, card)
            if board.fits(view, opts and opts.max_size) then
                return view
            end
        end
    end
end

local function outcome_rows(names)
    local rows = {}
    for index, name in ipairs(names or {}) do
        rows[index] = { id = store.id(), name = name, done = false }
    end
    return rows
end

function Backend:add(name, column, opts)
    local added, message = self:__update(function(doc)
        local target = column_named(doc, column)
        if not target then
            return nil, "the board has no " .. column .. " column, run dev board init"
        end
        local color_id
        if opts and opts.color then
            local color = color_valued(doc, opts.color)
            if not color then
                return nil, "the board has no " .. opts.color .. " colour, run dev board init"
            end
            color_id = color.id
        else
            for _, color in ipairs(doc.colors) do
                if color.is_default then
                    color_id = color.id
                end
            end
        end
        local now = store.stamp()
        local card = {
            id = store.id(),
            name = name,
            description = opts and opts.description or nil,
            column_id = target.id,
            color_id = color_id,
            labels = opts and opts.labels or {},
            checks = opts and opts.checks or {},
            outcomes = outcome_rows(opts and opts.outcomes),
            comments = {},
            created_at = now,
            entered_at = now,
        }
        doc.cards[#doc.cards + 1] = card
        return card_view(doc, card)
    end)
    return added, message
end

function Backend:note(id, body, fence, opts)
    return self:__update(function(doc)
        local card, message = card_of(doc, id, fence)
        if not card then
            return nil, message
        end
        card.comments[#card.comments + 1] = {
            id = store.id(),
            who = COMMENT_ACTOR,
            at = store.stamp(),
            body = body,
            kind = opts and opts.kind or COMMENT_KIND,
            author = opts and opts.author,
        }
        return true
    end)
end

function Backend:comments(id)
    local doc, message = self:__read()
    if not doc then
        return nil, message
    end
    local card = find_by_id(doc.cards, id)
    if not card then
        return nil, "the board has no card " .. id
    end
    local found = {}
    for _, comment in ipairs(card.comments or {}) do
        found[#found + 1] = {
            id = comment.id,
            who = comment.who,
            actor = comment.who,
            at = comment.at,
            body = comment.body,
            kind = comment.kind,
            author = comment.author,
        }
    end
    return found
end

local function own_comment(doc, id, comment)
    local card = find_by_id(doc.cards, id)
    if not card then
        return nil, nil, "the board has no card " .. id
    end
    local found, index = find_by_id(card.comments or {}, comment)
    if not found then
        return nil, nil, "the card has no comment " .. comment
    end
    if found.who ~= COMMENT_ACTOR then
        return nil, nil, NOT_YOURS
    end
    return card, index
end

function Backend:edit_note(id, comment, body)
    return self:__update(function(doc)
        local card, index, message = own_comment(doc, id, comment)
        if not card then
            return nil, message
        end
        card.comments[index].body = body
        return true
    end)
end

function Backend:delete_note(id, comment)
    return self:__update(function(doc)
        local card, index, message = own_comment(doc, id, comment)
        if not card then
            return nil, message
        end
        table.remove(card.comments, index)
        return true
    end)
end

function Backend:move(id, column, opts)
    opts = opts or {}
    local position = opts.position or 0
    return self:__update(function(doc)
        local card, message = card_of(doc, id, opts.fence)
        if not card then
            return nil, message
        end
        local target = column_named(doc, column)
        if not target then
            return nil, "the board has no " .. column .. " column, run dev board init"
        end
        local _, index = find_by_id(doc.cards, id)
        table.remove(doc.cards, index)
        local seen, at = 0, #doc.cards + 1
        for i, other in ipairs(doc.cards) do
            if other.column_id == target.id then
                if seen == position then
                    at = i
                    break
                end
                seen = seen + 1
            end
        end
        table.insert(doc.cards, at, card)
        if card.column_id ~= target.id then
            card.column_id = target.id
            card.entered_at = store.stamp()
        end
        return true
    end)
end

function Backend:set_size(id, color, fence)
    return self:__update(function(doc)
        local card, message = card_of(doc, id, fence)
        if not card then
            return nil, message
        end
        local found = color_valued(doc, color)
        if not found then
            return nil, "the board has no " .. color .. " colour, run dev board init"
        end
        card.color_id = found.id
        return true
    end)
end

function Backend:set_description(id, text, fence)
    return self:__update(function(doc)
        local card, message = card_of(doc, id, fence)
        if not card then
            return nil, message
        end
        card.description = text
        return true
    end)
end

function Backend:set_name(id, name, fence)
    return self:__update(function(doc)
        local card, message = card_of(doc, id, fence)
        if not card then
            return nil, message
        end
        card.name = name
        return true
    end)
end

function Backend:set_checks(id, runs, fence)
    return self:set_field(id, board.CHECKS_FIELD, runs, fence)
end

local FIELD_KEYS = {
    [board.CHECKS_FIELD] = "checks",
    [board.ALLOW_FIELD] = "allow",
    [board.TESTS_FIELD] = "tests",
    [board.FILES_FIELD] = "files",
}

function Backend:set_field(id, key, value, fence)
    return self:__update(function(doc)
        local card, message = card_of(doc, id, fence)
        if not card then
            return nil, message
        end
        card[assert(FIELD_KEYS[key], key)] = value ~= json.null and value or nil
        return true
    end)
end

function Backend:set_labels(id, labels, fence)
    return self:__update(function(doc)
        local card, message = card_of(doc, id, fence)
        if not card then
            return nil, message
        end
        card.labels = labels
        return true
    end)
end

function Backend:add_outcome(id, text, fence)
    return self:__update(function(doc)
        local card, message = card_of(doc, id, fence)
        if not card then
            return nil, message
        end
        card.outcomes = card.outcomes or {}
        card.outcomes[#card.outcomes + 1] = { id = store.id(), name = text, done = false }
        return true
    end)
end

function Backend:set_outcome(id, outcome, fields, fence)
    return self:__update(function(doc)
        local card, message = card_of(doc, id, fence)
        if not card then
            return nil, message
        end
        local row = find_by_id(card.outcomes or {}, outcome)
        if not row then
            return nil, "the card has no outcome " .. outcome
        end
        if fields.name ~= nil then
            row.name = fields.name
        end
        if fields.done ~= nil then
            row.done = fields.done
        end
        return true
    end)
end

function Backend:delete_outcome(id, outcome, fence)
    return self:__update(function(doc)
        local card, message = card_of(doc, id, fence)
        if not card then
            return nil, message
        end
        for i, row in ipairs(card.outcomes or {}) do
            if row.id == outcome then
                table.remove(card.outcomes, i)
                return true
            end
        end
        return nil, "the card has no outcome " .. outcome
    end)
end

function Backend:claim(id, claimant, ttl, fence, opts)
    return self:__update(function(doc)
        local card = find_by_id(doc.cards, id)
        if not card then
            return nil, "the board has no card " .. id
        end
        local held = live(card.claim)
        if held and not (held.fence == fence and held.claimant == claimant) then
            return nil, id .. " is claimed by " .. held.claimant
        end
        local taken = held and held.fence or (card.last_fence or 0) + 1
        local size = card_view(doc, card).size
        local _, minutes = claims.cap(size)
        local seconds = opts and opts.lease and ttl or minutes * SECONDS_PER_MINUTE
        card.last_fence = taken
        card.claim = {
            claimant = claimant,
            fence = taken,
            expires_at = store.stamp(store.now() + seconds),
        }
        return taken
    end)
end

function Backend:release(id, fence)
    return self:__update(function(doc)
        local card = find_by_id(doc.cards, id)
        if not card then
            return nil, "the board has no card " .. id
        end
        if not card.claim or card.claim.fence ~= fence then
            return nil,
                "the claim on " .. id .. " is not held with fence " .. string.format("%d", fence)
        end
        card.claim = nil
        return true
    end)
end

function Backend:keepalive()
    return 0
end

function Backend:find()
    local doc, message = self:__read()
    if doc then
        return true
    end
    if message == missing(self.__opts.path) then
        return false
    end
    return nil, message
end

function Backend:create()
    local made, message = self:__update(function(doc)
        for _, value in ipairs(SWATCH_VALUES) do
            if not color_valued(doc, value) then
                doc.colors[#doc.colors + 1] = {
                    id = store.id(),
                    value = value,
                    label = value:sub(1, 1):upper() .. value:sub(2),
                    description = "",
                    is_default = false,
                }
            end
        end
        return true
    end, { create = true })
    return made, message
end

function Backend:read()
    local doc, message = self:__read()
    if not doc then
        return nil, message
    end
    local columns, colors, cards = {}, {}, {}
    for _, column in ipairs(doc.columns) do
        columns[#columns + 1] = {
            id = column.id,
            name = column.name,
            is_done = column.is_done == true,
        }
    end
    for _, color in ipairs(doc.colors) do
        colors[#colors + 1] = {
            id = color.id,
            value = color.value,
            label = color.label,
            description = color.description or "",
            is_default = color.is_default == true,
            enabled = color.enabled ~= false,
        }
    end
    for _, card in ipairs(doc.cards) do
        cards[#cards + 1] = { id = card.id, name = card.name, color_id = present(card.color_id) }
    end
    return { columns = columns, colors = colors, cards = cards, has_checks = true }
end

function Backend:add_column(name, is_done)
    return self:__update(function(doc)
        doc.columns[#doc.columns + 1] = { id = store.id(), name = name, is_done = is_done }
        return true
    end)
end

function Backend:move_column(id, position)
    return self:__update(function(doc)
        local column, index = find_by_id(doc.columns, id)
        if not column then
            return nil, "the board has no column " .. id
        end
        table.remove(doc.columns, index)
        table.insert(doc.columns, math.min(position + 1, #doc.columns + 1), column)
        return true
    end)
end

function Backend:mark_done(id)
    return self:__update(function(doc)
        local column = find_by_id(doc.columns, id)
        if not column then
            return nil, "the board has no column " .. id
        end
        for _, other in ipairs(doc.columns) do
            other.is_done = other.id == id
        end
        return true
    end)
end

function Backend:set_color(id, fields)
    return self:__update(function(doc)
        local color = find_by_id(doc.colors, id)
        if not color then
            return nil, "the board has no colour " .. id
        end
        if fields.is_default then
            for _, other in ipairs(doc.colors) do
                other.is_default = false
            end
        end
        for key, value in pairs(fields) do
            color[key] = value
        end
        return true
    end)
end

function Backend:set_card(id, fields)
    return self:__update(function(doc)
        local card = find_by_id(doc.cards, id)
        if not card then
            return nil, "the board has no card " .. id
        end
        for key, value in pairs(fields) do
            card[key] = value
        end
        return true
    end)
end

return M
