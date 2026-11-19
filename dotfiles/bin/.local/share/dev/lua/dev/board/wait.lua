local board = require("dev.board")
local box = require("dev.cmd.box")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local guards = require("dev.board.guards")
local pomb = require("dev.board.pomb")
local runner = require("dev.board.runner")
local store = require("dev.board.store")
local turn = require("dev.board.turn")
local verb = require("dev.verb")

local usage = guards.usage
local failure = guards.failure
local HUMAN_ACTOR = "human"

---The wait verb and the owner reads the other board verbs share.
---@class dev.board.wait
local M = { SETTLE_SECONDS = 60 }

local WaitFor = {
    READY = "ready",
    HUMAN = "human",
    LEAD = "lead",
    PLANNER = "planner",
    REVIEW = "review",
    VERIFY = "verify",
    RELEASE = "release",
}
WaitFor.STAGES = {
    [WaitFor.READY] = true,
    [WaitFor.REVIEW] = true,
    [WaitFor.VERIFY] = true,
    [WaitFor.RELEASE] = true,
}
local EventKind = {
    ADDED = "task_added",
    MOVED = "task_moved",
    UPDATED = "task_updated",
    COMMENTED = "comment_added",
}
---Event kinds a wait watches when it names no stage
local WAIT_KINDS = { EventKind.ADDED, EventKind.MOVED, EventKind.UPDATED, EventKind.COMMENTED }
---Event kinds each wait stage watches
local WAIT_FOR_KINDS = {
    [WaitFor.READY] = { EventKind.ADDED, EventKind.MOVED },
    [WaitFor.HUMAN] = { EventKind.MOVED, EventKind.COMMENTED },
    [WaitFor.LEAD] = { EventKind.ADDED, EventKind.MOVED, EventKind.UPDATED },
}
WAIT_FOR_KINDS[WaitFor.PLANNER] = WAIT_FOR_KINDS[WaitFor.LEAD]
for stage in pairs(WaitFor.STAGES) do
    WAIT_FOR_KINDS[stage] = WAIT_FOR_KINDS[WaitFor.READY]
end
local WAIT_RETRY_SECONDS = 30
local WAIT_LIMITED_MAX_SECONDS = 300
local WAIT_JITTER = 0.25
local WAIT_RETRIES = 10
local WAIT_TRIMMED = "events were trimmed, check the board"
local WAIT_LIMITED_NOTICE = "Pomb holds too many open waits for this token. Waiting for one to end."

---Check whether the newest comment on a card is the owner's.
---
---A card in Done never counts. Without `since`, a comment of any age counts.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@param since integer? the time in seconds since the epoch, only a comment newer than it counts
---@return boolean? answered whether the newest comment is the owner's, nil when they could not be
---   read
---@return string? why the reason the comments could not be read
function M.commented(backend, card, since)
    if card.done then
        return false
    end
    local list = backend:comments(card.id)
    if not list then
        return nil, "could not read the comments of " .. card.id .. " " .. card.name
    end
    local newest = list[#list]
    if newest == nil or newest.actor ~= HUMAN_ACTOR then
        return false
    end
    if since == nil then
        return true
    end
    local at = box.parse_time(newest.at)
    return at ~= nil and at > since
end

---Check whether `next` would skip an unclaimed card: a run card, an epic with an open child, or a
---card an open card blocks.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@return boolean? skipped, string? why nil with the reason when the board could not be read
function M.skipped_by_next(backend, card)
    if board.labelled(card, board.RUN) or board.open_children(card.epic) > 0 then
        return true
    end
    return backend:blocked(card.id)
end

---Name the file that holds a board's wait cursor.
---@param name string the board's name
---@return string path the cursor file's path stem
function M.cursor_path(name)
    return store.dir() .. "/" .. name:gsub("[^%w._-]", "_")
end

local function read_cursor(path)
    local text = fs.exists(path) and fs.read(path)
    text = text and text:gsub("%s+", "")
    return text ~= "" and text or nil
end

local function lead_cards(backend, stages, label)
    local cards, message = backend:cards()
    if not cards then
        return nil, message
    end
    local waiting = {}
    for _, card in ipairs(cards) do
        if
            card.column == stages.blocked
            and not card.claimant
            and runner.index_of(card.labels, label)
            and not runner.index_of(card.labels, board.NEEDS_HUMAN)
        then
            local skipped, why = M.skipped_by_next(backend, card)
            if skipped == nil then
                return nil, why
            end
            if not skipped then
                waiting[card.id] = true
            end
        end
    end
    return waiting
end

---Find the cards the owner commented on since the wait began.
---@param backend dev.board.Backend the board
---@param events dev.board.Event[] the events of one reply
---@param since integer the time in seconds since the epoch a comment must be newer than
---@param skip table<string, boolean> the ids of the cards already reported, which are not read again
---@return table<string, boolean>? spoke the ids of the cards, nil when the board could not be read
---@return string? why the reason the board could not be read
local function comments(backend, events, since, skip)
    local spoke = {}
    local cards
    for _, event in ipairs(events) do
        if
            event.kind == EventKind.COMMENTED
            and type(event.task_id) == "string"
            and not skip[event.task_id]
        then
            if not cards then
                local list, message = backend:cards()
                if not list then
                    return nil, message
                end
                cards = {}
                for _, card in ipairs(list) do
                    cards[card.id] = card
                end
            end
            local card = cards[event.task_id]
            if card then
                local found, why = M.commented(backend, card, since)
                if found == nil then
                    return nil, why
                end
                spoke[card.id] = found or nil
            end
        end
    end
    return spoke
end

---Collect the cards that sat in Blocked or Icebox and have left them or the board.
---
---Remove each departed card from `sat`, so it is reported once.
---@param backend dev.board.Backend the board
---@param sat table<string, string> the column of each card that sat in Blocked or Icebox
---@return string[]? lines one line per card that left, nil when the board could not be read
---@return string? why the reason the board could not be read
local function departed(backend, sat)
    local cards, message = backend:cards()
    if not cards then
        return nil, message
    end
    local now = {}
    for _, card in ipairs(cards) do
        now[card.id] = card.column
    end
    local lines = {}
    for id, from in pairs(sat) do
        if now[id] ~= from then
            sat[id] = nil
            lines[#lines + 1] = "moved " .. id:sub(1, board.MIN_PREFIX) .. " out of " .. from
        end
    end
    table.sort(lines)
    return lines
end

---Collect the cards that sit in Blocked or Icebox.
---@param backend dev.board.Backend the board
---@param stages dev.board.Stages the column names
---@return table<string, string>? sat the column of each card in Blocked or Icebox
---@return string? why the reason the board could not be read
local function sitting(backend, stages)
    local cards, message = backend:cards()
    if not cards then
        return nil, message
    end
    local sat = {}
    for _, card in ipairs(cards) do
        if card.column == stages.blocked or card.column == stages.icebox then
            sat[card.id] = card.column
        end
    end
    return sat
end

---Collect the unclaimed cards of a column.
---@param backend dev.board.Backend the board
---@param column string the column's name
---@return table<string, boolean>? waiting the ids of the unclaimed cards, nil when the board could
---   not be read
---@return string? why the reason the board could not be read
local function stage_cards(backend, column)
    local cards, message = backend:cards()
    if not cards then
        return nil, message
    end
    local waiting = {}
    for _, card in ipairs(cards) do
        if card.column == column and not card.claimant then
            waiting[card.id] = true
        end
    end
    return waiting
end

local function wait_line(event, opts)
    local only, stages, leads = opts.only, opts.stages, opts.leads
    local spoke = opts.spoke
    local id = event.task_id:sub(1, board.MIN_PREFIX)
    local added = event.kind == EventKind.ADDED
    if only == WaitFor.LEAD or only == WaitFor.PLANNER then
        if leads[event.task_id] then
            leads[event.task_id] = nil
            return id .. " is labelled " .. board.BLOCKED_LABELS[only] .. " in " .. stages.blocked
        end
    elseif only == WaitFor.HUMAN then
        if
            event.kind == EventKind.MOVED
            and event.from_column == stages.blocked
            and event.actor == HUMAN_ACTOR
            and event.at
            and event.at >= opts.started
        then
            return "moved " .. id .. " out of " .. stages.blocked
        end
        if event.kind == EventKind.COMMENTED and spoke[event.task_id] then
            spoke[event.task_id] = nil
            return "the owner commented on " .. id
        end
    elseif WaitFor.STAGES[only] then
        if
            event.column == stages[only]
            and (added or event.kind == EventKind.MOVED)
            and opts.stage[event.task_id]
        then
            return (added and "added " or "moved ") .. id .. " to " .. stages[only]
        end
    elseif added then
        return "added " .. id .. " to " .. tostring(event.column)
    elseif event.kind == EventKind.MOVED then
        return "moved " .. id .. " to " .. tostring(event.column or "another board")
    elseif event.kind == EventKind.UPDATED then
        return "updated " .. id
    elseif event.kind == EventKind.COMMENTED then
        return "commented on " .. id
    end
end

---@class dev.cmd.board.wait.Opts
---@field stem string the path the cursor files start with, one per `--for` mode
---@field nap fun(seconds: number)? sleeps between retries, `dev.os.nap` when nil
---@field random (fun(): number)? a number in [0, 1) that spreads the pause, entropy from the system
---   when nil
---@field notice fun(line: string)? prints the one line about too many open waits, standard error
---   when nil
---@field now (fun(): integer)? the clock in seconds since the epoch, `store.now` when nil

---Hold until the board changes in a way the caller asked for.
---
---The cursor is saved after every reply, and `--for human` saves it when it
---prints its held lines, so a restart misses nothing. A Pomb
---that cannot be asked is retried and fails once ten tries in a row run out. A
---refusal for too many open waits on the token is never a failure: the wait
---is reported once and retried with a pause that doubles from 30 seconds to
---5 minutes, spread by a random fraction so sessions do not retry together.
---A cursor Pomb no longer holds is replaced and reported as a notice, not an
---error.
---@param backend dev.board.Backend the Pomb board
---@param args string[] the arguments after `wait`
---@param opts dev.cmd.board.wait.Opts where the cursor lives and how to sleep
---@return dev.cmd.board.Result result the lines for the matching events, or a message and the exit
---   code
function M.wait(backend, args, opts)
    local flags, words = guards.parse(args, { ["--for"] = true })
    if not flags then
        return words
    end
    if #words > 0 then
        return usage("Takes no card.")
    end
    local only = flags["--for"]
    if only and not WAIT_FOR_KINDS[only] then
        return usage(
            "Unknown --for "
                .. only
                .. ". The choices are ready, review, verify, release, human, lead and planner."
        )
    end
    local stages = backend.stages or board.stages()
    local legacy = guards.stage_refusal(backend)
    if legacy then
        return legacy
    end
    local nap = opts.nap or dev_os.nap
    local random = opts.random or turn.entropy
    local notice = opts.notice or verb.note
    local limited = 0
    local told = false
    local clock = opts.now or store.now
    local started = clock()
    local held, touched, last = {}, {}, nil
    local sat
    if only == WaitFor.HUMAN then
        local why
        sat, why = sitting(backend, stages)
        if not sat then
            return failure(why)
        end
    end
    local path = opts.stem .. "." .. (only or "all") .. ".cursor"
    local cursor = read_cursor(path)
    local function flush(result)
        if #held == 0 then
            return result
        end
        if only == WaitFor.HUMAN then
            local saved, why = store.write(path, cursor .. "\n", { private = true })
            if not saved and not result.message then
                result = failure(why)
            end
        end
        local lines = table.concat(held, "\n")
        if result.message then
            return { message = lines .. "\n" .. result.message, code = result.code }
        end
        if result.output then
            lines = lines .. "\n" .. result.output
        end
        return { output = lines }
    end
    local failures = 0
    while true do
        local reply, message, oldest, refused = backend:wait(
            cursor,
            WAIT_FOR_KINDS[only] or WAIT_KINDS,
            last and math.max(1, M.SETTLE_SECONDS - (clock() - last))
        )
        local leads
        if reply and board.BLOCKED_LABELS[only] and #reply.events > 0 then
            local why
            leads, why = lead_cards(backend, stages, board.BLOCKED_LABELS[only])
            if not leads then
                if not pomb.unreachable(why, true) then
                    return failure(why)
                end
                reply, message = nil, why
            end
        end
        local spoke
        local unread = false
        if reply and only == WaitFor.HUMAN then
            local why
            spoke, why = comments(backend, reply.events, started, touched)
            if not spoke then
                reply, message, unread = nil, why, true
            end
        end
        if reply then
            failures = 0
            limited = 0
            if type(reply.cursor) ~= "string" then
                return flush(failure("Pomb answered without a cursor."))
            end
            local stage
            if WaitFor.STAGES[only] and #reply.events > 0 then
                local why
                stage, why = stage_cards(backend, stages[only])
                if not stage then
                    return failure(why)
                end
            end
            if only ~= WaitFor.HUMAN then
                local saved, why = store.write(path, reply.cursor .. "\n", { private = true })
                if not saved then
                    return flush(failure(why))
                end
            end
            cursor = reply.cursor
            local lines = {}
            local matched = false
            for _, event in ipairs(reply.events) do
                local line = type(event.task_id) == "string"
                    and wait_line(event, {
                        only = only,
                        stages = stages,
                        leads = leads,
                        spoke = spoke,
                        stage = stage,
                        started = started,
                    })
                if line then
                    matched = true
                    if only ~= WaitFor.HUMAN then
                        lines[#lines + 1] = line
                    elseif not touched[event.task_id] then
                        touched[event.task_id] = true
                        held[#held + 1] = line
                    end
                end
            end
            if #lines > 0 then
                return { output = table.concat(lines, "\n") }
            end
            if matched then
                last = clock()
            end
            if #held > 0 and not matched then
                if #reply.events == 0 or clock() - last >= M.SETTLE_SECONDS then
                    return flush({})
                end
            end
        elseif oldest then
            if only ~= WaitFor.HUMAN or #held == 0 then
                local saved, why = store.write(path, oldest .. "\n", { private = true })
                if not saved then
                    return flush(failure(why))
                end
            end
            if WaitFor.STAGES[only] then
                cursor = oldest
            elseif only ~= WaitFor.HUMAN then
                return flush({ output = WAIT_TRIMMED })
            else
                local gone, reason = departed(backend, sat)
                if not gone then
                    return flush(failure(reason))
                end
                for _, line in ipairs(gone) do
                    held[#held + 1] = line
                end
                cursor = oldest
                if #held > 0 then
                    return flush({ output = WAIT_TRIMMED })
                end
            end
        elseif refused then
            failures = 0
            if not told then
                told = true
                notice(WAIT_LIMITED_NOTICE)
            end
            local pause = math.min(WAIT_RETRY_SECONDS * 2 ^ limited, WAIT_LIMITED_MAX_SECONDS)
            limited = limited + 1
            nap(pause * (1 - WAIT_JITTER * random()))
        elseif unread or pomb.unreachable(message, true) then
            failures = failures + 1
            if failures >= WAIT_RETRIES then
                return flush(failure(message))
            end
            nap(WAIT_RETRY_SECONDS)
        else
            return flush(failure(message))
        end
    end
end

return M
