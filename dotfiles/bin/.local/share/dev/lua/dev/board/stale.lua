local board = require("dev.board")
local board_wait = require("dev.board.wait")
local clock = require("dev.board.clock")
local box = require("dev.cmd.box")
local fs = require("dev.fs")
local guards = require("dev.board.guards")
local runner = require("dev.board.runner")
local store = require("dev.board.store")

local usage = guards.usage
local failure = guards.failure
local parse = guards.parse
local index_of = require("dev.text").index_of

---The stale verb, which lists the cards that sat too long where they are.
---@class dev.board.stale
local M = {}

local STALE_DAYS = 7
local ICEBOX_DAYS = 30
local LEAD_HOURS = 1
local FLIGHT_HOURS = 24
local ANSWERED_NOTE = " (answered, waiting for your move)"
---Todo file names under the project root
local TODO_FILES = { "TODO.md", "docs/TODO.md" }

local function append(lines, more)
    for _, line in ipairs(more) do
        lines[#lines + 1] = line
    end
end

local function warning(text)
    local bare = text:gsub("%.$", "")
    return bare:sub(1, 1):upper() .. bare:sub(2) .. "."
end

local function stale_rows(cards)
    local rows = {}
    for _, card in ipairs(cards) do
        rows[#rows + 1] = {
            card.id:sub(1, board.MIN_PREFIX),
            card.column,
            card.hours and card.hours .. "h" or card.days .. "d",
            card.size,
            card.name .. (card.answered and ANSWERED_NOTE or ""),
        }
    end
    return board.table_lines(rows)
end

local function whole_limit(flag, value, opts)
    if not value then
        return opts.default
    end
    local limit = value:find("^%d+$") and tonumber(value)
    if not limit or limit < 1 then
        return nil,
            usage(
                "The "
                    .. flag
                    .. " flag needs a whole number of "
                    .. opts.unit
                    .. ", 1 or more: "
                    .. value
                    .. "."
            )
    end
    return limit
end

local function icebox_latest(backend, card, stamp, limit, now)
    local latest = stamp and box.parse_time(stamp)
    if not latest then
        return nil, warning("could not date " .. card.id .. " " .. card.name)
    end
    if (now - latest) / box.SECONDS_PER_DAY < limit then
        return nil
    end
    local list = backend:comments(card.id)
    if not list then
        return nil, warning("could not read the comments of " .. card.id .. " " .. card.name)
    end
    for _, comment in ipairs(list) do
        local at = box.parse_time(comment.at)
        if not at then
            return nil, warning("could not read the comments of " .. card.id .. " " .. card.name)
        end
        latest = math.max(latest, at)
    end
    return latest
end

local function icebox_rows(backend, cards, entered, limit, now)
    local found, undated = {}, {}
    for _, card in ipairs(cards) do
        if
            card.column == backend.stages.icebox
            and index_of(card.labels, board.NEEDS_HUMAN) == nil
            and not board.is_turn_card(card)
        then
            local latest, skipped = icebox_latest(backend, card, entered[card.id], limit, now)
            if skipped then
                undated[#undated + 1] = skipped
            elseif latest then
                local days = math.floor((now - latest) / box.SECONDS_PER_DAY)
                if days >= limit then
                    found[#found + 1] = {
                        id = card.id,
                        column = card.column,
                        size = card.size,
                        name = card.name,
                        days = days,
                        at = latest,
                    }
                end
            end
        end
    end
    table.sort(undated)
    table.sort(found, function(a, b)
        if a.at ~= b.at then
            return a.at < b.at
        end
        return a.id < b.id
    end)
    return found, undated
end

local function flight_rows(backend, cards, entered, limit, now)
    local stages = backend.stages
    local flying = { [stages.progress] = true, [stages.review] = true, [stages.verify] = true }
    local days = limit * box.SECONDS_PER_HOUR / box.SECONDS_PER_DAY
    local found = {}
    for _, card in ipairs(cards) do
        if flying[card.column] and not card.claimant and not card.done then
            local latest = icebox_latest(backend, card, entered[card.id], days, now)
            if latest then
                local hours = math.floor((now - latest) / box.SECONDS_PER_HOUR)
                if hours >= limit then
                    found[#found + 1] = {
                        id = card.id,
                        column = card.column,
                        size = card.size,
                        name = card.name,
                        hours = hours,
                        at = latest,
                    }
                end
            end
        end
    end
    table.sort(found, function(a, b)
        if a.at ~= b.at then
            return a.at < b.at
        end
        return a.id < b.id
    end)
    return found
end

local function started_rows(backend, cards, entered, now)
    local stages = backend.stages
    local started = { [stages.progress] = true, [stages.review] = true }
    local waiting = { [stages.backlog] = true, [stages.ready] = true }
    local found, warnings, others = {}, {}, {}
    for _, card in ipairs(cards) do
        local list
        if waiting[card.column] and not card.done then
            local why
            list, why = backend:links(card.id)
            if not list then
                warnings[#warnings + 1] = warning(
                    "could not read the links of "
                        .. card.id
                        .. " "
                        .. card.name
                        .. ": "
                        .. tostring(why)
                )
            end
        end
        for _, link in ipairs(list or {}) do
            if link.kind == "blocked_by" and link.board then
                local target = link.board .. ":" .. link.id:sub(1, board.MIN_PREFIX)
                local other = others[link.board]
                if other == nil then
                    local opened, message = backend:other_board(link.board)
                    other = opened or { failed = message }
                    others[link.board] = other
                end
                local blocker, message
                if not other.failed then
                    blocker, message = other:card(link.id)
                end
                if other.failed or not blocker then
                    warnings[#warnings + 1] = warning(
                        "could not read blocker "
                            .. target
                            .. " of "
                            .. card.id
                            .. " "
                            .. card.name
                            .. ": "
                            .. tostring(other.failed or message)
                    )
                elseif started[blocker.column] then
                    local at = entered[card.id] and box.parse_time(entered[card.id]) or now
                    found[#found + 1] = {
                        id = card.id,
                        column = card.column,
                        size = card.size,
                        name = card.name
                            .. " (blocked by "
                            .. target
                            .. " in "
                            .. blocker.column
                            .. ")",
                        days = math.floor((now - at) / box.SECONDS_PER_DAY),
                        at = at,
                    }
                end
            end
        end
    end
    return found, warnings
end

---List the cards that sat too long in a column, and the other things a board should clear.
---@param backend dev.board.Backend the board
---@param args string[] the stale arguments
---@param now integer? the time in seconds since the epoch, the clock when nil
---@return dev.cmd.board.Result result the report
function M.stale(backend, args, now)
    local flags, extra = parse(args, {
        ["--days"] = true,
        ["--icebox-days"] = true,
        ["--lead-hours"] = true,
        ["--flight-hours"] = true,
    })
    if not flags then
        return extra
    end
    if #extra > 0 then
        return usage("Unknown argument " .. extra[1] .. ".")
    end
    local limit, refusal =
        whole_limit("--days", flags["--days"], { default = STALE_DAYS, unit = "days" })
    if not limit then
        return refusal
    end
    local icebox_limit
    icebox_limit, refusal = whole_limit(
        "--icebox-days",
        flags["--icebox-days"],
        { default = ICEBOX_DAYS, unit = "days" }
    )
    if not icebox_limit then
        return refusal
    end
    local lead_limit
    lead_limit, refusal = whole_limit(
        "--lead-hours",
        flags["--lead-hours"],
        { default = LEAD_HOURS, unit = runner.limits.HOURS }
    )
    if not lead_limit then
        return refusal
    end
    local flight_limit
    flight_limit, refusal = whole_limit(
        "--flight-hours",
        flags["--flight-hours"],
        { default = FLIGHT_HOURS, unit = runner.limits.HOURS }
    )
    if not flight_limit then
        return refusal
    end
    local cards, message = backend:cards()
    if not cards then
        return failure(message)
    end
    local entered
    entered, message = backend:entered()
    if not entered then
        return failure(message)
    end
    now = now or store.now()
    local stages = backend.stages
    local found, owner, moved, undated, unsized, commented = {}, {}, {}, {}, {}, {}
    local lead, planner, nobody = {}, {}, {}
    local candidates = {}
    for _, card in ipairs(cards) do
        if
            card.column == stages.blocked
            and not card.done
            and not index_of(card.labels, board.NEEDS_HUMAN)
            and not index_of(card.labels, board.NEEDS_LEAD)
            and not index_of(card.labels, board.NEEDS_PLANNER)
        then
            local at = entered[card.id] and box.parse_time(entered[card.id])
            if not at then
                undated[#undated + 1] = warning("could not date " .. card.id .. " " .. card.name)
            else
                nobody[#nobody + 1] = {
                    id = card.id,
                    column = card.column,
                    size = card.size,
                    name = card.name,
                    days = math.floor((now - at) / box.SECONDS_PER_DAY),
                    at = at,
                }
            end
        end
        local asks = index_of(card.labels, board.NEEDS_LEAD) and lead
            or index_of(card.labels, board.NEEDS_PLANNER) and planner
        if
            card.column == stages.blocked
            and not card.done
            and asks
            and not index_of(card.labels, board.NEEDS_HUMAN)
        then
            local at = entered[card.id] and box.parse_time(entered[card.id])
            if not at then
                undated[#undated + 1] = warning("could not date " .. card.id .. " " .. card.name)
            else
                local hours = math.floor((now - at) / box.SECONDS_PER_HOUR)
                if hours >= lead_limit then
                    local skipped = false
                    if not card.claimant then
                        local why
                        skipped, why = board_wait.skipped_by_next(backend, card)
                        if skipped == nil then
                            return failure(why)
                        end
                    end
                    if not skipped then
                        asks[#asks + 1] = {
                            id = card.id,
                            column = card.column,
                            size = card.size,
                            name = card.name,
                            hours = hours,
                            at = at,
                        }
                    end
                end
            end
        end
        if card.column ~= stages.icebox and board.has_color(card, board.SIZES.unsized) then
            unsized[#unsized + 1] = card
        end
        local mine = index_of(card.labels, board.NEEDS_HUMAN) ~= nil
        local held = mine and (card.column == stages.blocked or card.column == stages.icebox)
        if not held then
            candidates[#candidates + 1] = card
        end
        if mine or (not card.done and stages.stale[card.column]) then
            local stamp = entered[card.id]
            if not stamp then
                undated[#undated + 1] = warning("could not date " .. card.id .. " " .. card.name)
            else
                local at = box.parse_time(stamp)
                if not at then
                    return failure(
                        "Pomb sent a column time dev cannot read for card " .. card.id .. "."
                    )
                end
                local days = math.floor((now - at) / box.SECONDS_PER_DAY)
                if mine or days >= limit then
                    local item = {
                        id = card.id,
                        column = card.column,
                        size = card.size,
                        name = card.name,
                        days = days,
                        at = at,
                    }
                    local into = found
                    if held then
                        local answered, why = board_wait.commented(backend, card)
                        if answered == nil then
                            undated[#undated + 1] = warning(why)
                        else
                            item.answered = answered
                        end
                        into = owner
                    elseif mine then
                        into = moved
                    end
                    into[#into + 1] = item
                end
            end
        end
    end
    local function oldest(a, b)
        if a.at ~= b.at then
            return a.at < b.at
        end
        return a.id < b.id
    end
    table.sort(found, oldest)
    table.sort(owner, oldest)
    table.sort(moved, oldest)
    table.sort(lead, oldest)
    table.sort(planner, oldest)
    table.sort(nobody, oldest)
    local listed = {}
    for _, list in ipairs({ found, moved, lead, planner }) do
        for _, item in ipairs(list) do
            listed[item.id] = true
        end
    end
    for _, card in ipairs(candidates) do
        if not listed[card.id] then
            local spoke, why = board_wait.commented(backend, card)
            if spoke == nil then
                if card.column ~= stages.icebox then
                    undated[#undated + 1] = warning(why)
                end
            elseif spoke then
                local at = entered[card.id] and box.parse_time(entered[card.id]) or now
                commented[#commented + 1] = {
                    id = card.id,
                    column = card.column,
                    size = card.size,
                    name = card.name,
                    days = math.floor((now - at) / box.SECONDS_PER_DAY),
                    at = at,
                }
            end
        end
    end
    table.sort(undated)
    table.sort(commented, oldest)
    local lines = {}
    if #found == 0 then
        lines[1] = "No stale cards."
    else
        append(lines, stale_rows(found))
    end
    if #owner > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "for the owner (" .. board.NEEDS_HUMAN .. "):"
        append(lines, stale_rows(owner))
    end
    if #lead > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "for a lead (" .. board.NEEDS_LEAD .. "):"
        append(lines, stale_rows(lead))
    end
    if #planner > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "for a planner (" .. board.NEEDS_PLANNER .. "):"
        append(lines, stale_rows(planner))
    end
    if #nobody > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "asks nobody, add a needs label:"
        append(lines, stale_rows(nobody))
    end
    if #moved > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "moved by the owner, remove " .. board.NEEDS_HUMAN .. ":"
        append(lines, stale_rows(moved))
    end
    if #commented > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "newest comment is the owner's:"
        append(lines, stale_rows(commented))
    end
    if #unsized > 0 then
        local rows = {}
        for _, card in ipairs(unsized) do
            rows[#rows + 1] = { card.id:sub(1, board.MIN_PREFIX), card.column, card.name }
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "unsized outside " .. stages.icebox .. ":"
        append(lines, board.table_lines(rows))
    end
    local todo = {}
    for _, name in ipairs(TODO_FILES) do
        if backend.root and fs.is_file(backend.root .. "/" .. name) then
            todo[#todo + 1] = name
        end
    end
    if #todo > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "todo files, move their items onto cards:"
        append(lines, todo)
    end
    if #undated > 0 then
        lines[#lines + 1] = ""
        append(lines, undated)
    end
    local flying = flight_rows(backend, cards, entered, flight_limit, now)
    local quiet = {}
    for _, item in ipairs(flying) do
        if not listed[item.id] then
            quiet[#quiet + 1] = item
        end
    end
    if #quiet > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "in flight, no claim and quiet for " .. flight_limit .. " hours:"
        append(lines, stale_rows(quiet))
    end
    local begun, begun_warnings = started_rows(backend, cards, entered, now)
    table.sort(begun, oldest)
    if #begun > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "blocker started on another board:"
        append(lines, stale_rows(begun))
    end
    if #begun_warnings > 0 then
        lines[#lines + 1] = ""
        append(lines, begun_warnings)
    end
    local ticking, clock_warnings = clock.sweep(backend, cards, now)
    if #ticking > 0 then
        local rows = {}
        for _, item in ipairs(ticking) do
            rows[#rows + 1] =
                { item.id:sub(1, board.MIN_PREFIX), item.role, item.minutes .. " min", item.name }
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "clocks running:"
        append(lines, board.table_lines(rows))
    end
    if #clock_warnings > 0 then
        lines[#lines + 1] = ""
        for _, text in ipairs(clock_warnings) do
            lines[#lines + 1] = warning(text)
        end
    end
    local function umbrella_rows()
        local running = { [stages.progress] = true, [stages.review] = true, [stages.verify] = true }
        local backlog, why_started = {}, {}
        for _, card in ipairs(cards) do
            if card.column == stages.backlog and not card.done then
                backlog[card.id] = card
                if card.epic and card.epic.done > 0 then
                    why_started[card.id] = card.epic.done
                        .. " of "
                        .. card.epic.total
                        .. " children done"
                end
            end
        end
        local warnings = {}
        for _, card in ipairs(cards) do
            if running[card.column] and not card.done then
                local family, why = backend:family(card.id)
                if not family then
                    warnings[#warnings + 1] = warning(
                        "could not read the epic of "
                            .. card.id
                            .. " "
                            .. card.name
                            .. ": "
                            .. tostring(why)
                    )
                elseif family.parent and backlog[family.parent.id] then
                    local parent_id = family.parent.id
                    why_started[parent_id] = why_started[parent_id]
                        or "child " .. card.id:sub(1, board.MIN_PREFIX) .. " in " .. card.column
                end
            end
        end
        local rows = {}
        for id, reason in pairs(why_started) do
            local card = backlog[id]
            local at = entered[id] and box.parse_time(entered[id]) or now
            rows[#rows + 1] = {
                id = id,
                column = card.column,
                size = card.size,
                name = card.name .. " (" .. reason .. ")",
                days = math.floor((now - at) / box.SECONDS_PER_DAY),
                at = at,
            }
        end
        return rows, warnings
    end
    local umbrellas, umbrella_warnings = umbrella_rows()
    table.sort(umbrellas, oldest)
    if #umbrellas > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "umbrella in Backlog, a child started:"
        append(lines, stale_rows(umbrellas))
    end
    if #umbrella_warnings > 0 then
        lines[#lines + 1] = ""
        append(lines, umbrella_warnings)
    end
    local closable = {}
    for _, card in ipairs(cards) do
        if not card.done and board.children_closed(card.epic) then
            local at = entered[card.id] and box.parse_time(entered[card.id]) or now
            closable[#closable + 1] = {
                id = card.id,
                column = card.column,
                size = card.size,
                name = card.name,
                days = math.floor((now - at) / box.SECONDS_PER_DAY),
                at = at,
            }
        end
    end
    table.sort(closable, oldest)
    if #closable > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "epic with every child Done, ready to close:"
        append(lines, stale_rows(closable))
    end
    local iced, iced_undated = icebox_rows(backend, cards, entered, icebox_limit, now)
    if #iced > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "icebox, untouched for " .. icebox_limit .. " days:"
        append(lines, stale_rows(iced))
    end
    if #iced_undated > 0 then
        lines[#lines + 1] = ""
        append(lines, iced_undated)
    end
    return { output = table.concat(lines, "\n") }
end

return M
