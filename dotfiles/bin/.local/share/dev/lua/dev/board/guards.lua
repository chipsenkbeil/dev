local board = require("dev.board")
local check = require("dev.board.check")
local land = require("dev.board.land")

---The refusals and guards a board change runs before it acts.
---@class dev.board.guards
local M = {}

local USAGE = 2
local FAILURE = 1
local CLAIMANT_CHARS = 200
local AS_FLAG = "--as"

---Build a usage error result.
---@param message string what the caller got wrong
---@return dev.cmd.board.Result result the error with the usage code
local function usage(message)
    return { message = message, code = USAGE }
end

---Build a failure result.
---@param message string what went wrong
---@return dev.cmd.board.Result result the error with the failure code
local function failure(message)
    return { message = message, code = FAILURE }
end

---Mark a refusal as one a queue must not keep.
---@param result dev.cmd.board.Result the refusal
---@return dev.cmd.board.Result result the same refusal, marked unqueued
local function unqueued(result)
    result.unqueued = true
    return result
end

---Read the agent name from a flag or DEV_AGENT.
---@param flag string? the name given with the flag, nil to read DEV_AGENT
---@return string? name the name, nil when none is set
---@return dev.cmd.board.Result? err the usage error, set when the name is malformed
local function agent_name(flag)
    local name = flag
    if name == nil then
        name = os.getenv("DEV_AGENT")
    end
    if name == nil or (flag == nil and name == "") then
        return nil
    end
    if #name > CLAIMANT_CHARS or not name:find("^[%w._/-]+$") then
        return nil,
            usage(
                "an agent name is one word of letters, digits and . - _ / up to "
                    .. CLAIMANT_CHARS
                    .. " characters."
            )
    end
    return name
end

---Refuse a board that still has the In Review column and lacks a stage column.
---@param backend dev.board.Backend the board
---@return dev.cmd.board.Result? refusal naming `dev board init`, nil when the board needs no
---   migration
local function stage_refusal(backend)
    local rows = backend:columns()
    if type(rows) ~= "table" then
        return nil
    end
    local has = {}
    for _, row in ipairs(rows) do
        has[row.name:lower()] = true
    end
    if not has["in review"] then
        return nil
    end
    local roles = backend.roles or board.roles()
    for _, name in ipairs({ roles.review, roles.verify, roles.release }) do
        if not has[name:lower()] then
            return failure(
                "the board has an In Review column and no "
                    .. name
                    .. " column, so run dev board init to move the board to the stage columns."
            )
        end
    end
    return nil
end

---Refuse the first checks row that is not a plain command.
---@param runs string[] the rows as given
---@return dev.cmd.board.Result? refusal a usage error naming the row, nil when every row is plain
local function row_refusal(runs)
    for _, run in ipairs(runs) do
        local why = check.refusal(run)
        if why then
            return usage(why)
        end
    end
    return nil
end

---Refuse a verb run outside the jj workspace `dev ws new` names for the card.
---@param backend dev.board.Backend the board the command runs on
---@param short string the card's short id
---@return dev.cmd.board.Result? refusal a failure naming the workspace found, nil when the verb may
---   go on
local function workspace_refusal(backend, short)
    if not backend.root then
        return nil
    end
    local problem = land.workspace_problem(backend.root, short)
    if problem then
        return failure(problem)
    end
    return nil
end

---Open the Pomb board named `name` with this board's column map, root and roles.
---@param backend dev.board.Backend the board the command runs on
---@param name string the other board's name
---@return dev.board.Backend? home the named board, nil when it cannot be opened
---@return string? why the reason, set when home is nil
local function other_home(backend, name)
    local home, why = backend:other_board(name)
    if not home then
        return nil, why
    end
    local found, message = home:find()
    if found == nil then
        return nil, message
    end
    if not found then
        return nil, "pomb has no board named " .. name .. "."
    end
    home.column_map = backend.column_map
    home.root = backend.root
    home.roles = board.roles(backend.column_map, home:done_columns() or {})
    return home
end

---Move to the board named by a `--board NAME` right after the card, else keep this one.
---@param backend dev.board.Backend the board the command runs on
---@param args string[] the command's words, the card first
---@return dev.board.Backend? home the board to act on, nil when refused
---@return string[]? rest the words with `--board NAME` removed, nil when refused
---@return dev.cmd.board.Result? refused the usage error or failure, set when home is nil
local function on_board(backend, args)
    if args[2] ~= "--board" then
        return backend, args
    end
    if not args[3] then
        return nil, nil, usage("--board needs a board name.")
    end
    local home, why = other_home(backend, args[3])
    if not home then
        return nil, nil, failure(why)
    end
    return home, { args[1], unpack(args, 4) }
end

---Refuse a move of an epic with an open child into a WIP-limited or done column.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@param column string the column it moves to
---@param kids {done: integer, total: integer}? the epic's children from its task read
---@return dev.cmd.board.Result? err the refusal, nil when the move is allowed
local function children_refusal(backend, card, column, kids)
    local unfinished = board.open_children(kids)
    if unfinished == 0 or card.column == column then
        return nil
    end
    local rows, why = backend:columns()
    if not rows then
        return unqueued(failure(why))
    end
    for _, row in ipairs(rows) do
        local kind = row.is_done and "done" or row.wip_limit and "WIP-limited"
        if kind and row.name:lower() == column:lower() then
            return unqueued(
                failure(
                    string.format(
                        "%s is an epic and cannot enter %s, a %s column: %d of %d children are open.",
                        card.id:sub(1, board.MIN_PREFIX),
                        row.name,
                        kind,
                        unfinished,
                        kids.total
                    )
                )
            )
        end
    end
end

---Refuse a move into a column when Pomb sent the card's outcomes in a form dev cannot read.
---@param card dev.board.Card the card
---@param column string the column name the refusal names
---@return dev.cmd.board.Result? err the refusal, nil when the outcomes are readable
local function unreadable_refusal(card, column)
    if card.outcomes_unreadable then
        return failure(
            card.id:sub(1, board.MIN_PREFIX)
                .. " cannot move to "
                .. column
                .. ": its outcomes cannot be read from Pomb, so they cannot be checked."
        )
    end
end

---Refuse a move to Done that the card's outcomes do not allow.
---@param card dev.board.Card the card
---@param column string the board's Done column name the refusal names
---@return dev.cmd.board.Result? err the refusal, nil when every outcome is ticked
local function done_refusal(card, column)
    local id = card.id:sub(1, board.MIN_PREFIX)
    local unreadable = unreadable_refusal(card, column)
    if unreadable then
        return unqueued(unreadable)
    end
    local open = {}
    for i, outcome in ipairs(card.outcomes) do
        if not outcome.done then
            open[#open + 1] = i .. ". " .. outcome.name
        end
    end
    if #open == 0 then
        return nil
    end
    return unqueued(
        failure(
            string.format(
                "%s cannot move to %s: %d of %d outcomes are unticked (%s). The reviewer ticks them with dev board outcome CARD --tick N --as NAME, or dev board discard CARD drops it.",
                id,
                column,
                #open,
                #card.outcomes,
                table.concat(open, ", ")
            )
        )
    )
end

---Refuse a tick that the claimant or a missing name does not allow.
---@param card dev.board.Card the card
---@param flag string? the ticker name given with the flag
---@return dev.cmd.board.Result? err the refusal, nil when the tick may go on
---@return string? ticker the ticker name, set when the tick may go on
local function tick_refused(card, flag)
    if not card.claimant and not flag then
        return nil
    end
    local ticker, why = agent_name(flag)
    if why then
        return why
    end
    if not card.claimant then
        return nil, ticker
    end
    if not ticker then
        return usage(
            "ticking an outcome on a claimed card needs the ticker's name, with "
                .. AS_FLAG
                .. " NAME or DEV_AGENT."
        )
    end
    if ticker == card.claimant then
        return failure(
            card.id:sub(1, board.MIN_PREFIX)
                .. " is claimed by "
                .. ticker
                .. ", so its claimant cannot tick its outcomes."
        )
    end
    return nil, ticker
end

---Refuse a change by an agent that claimed the card now or before.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@param opts {what: string, as: string?} the change refused and the name given with the flag
---@return dev.cmd.board.Result? err the refusal, nil when no claimant is the caller
local function claimant_refused(backend, card, opts)
    local names = {}
    local given, env = opts.as, os.getenv("DEV_AGENT")
    if given and given:find("/", 1, true) then
        names[#names + 1] = given
    end
    if env and env:find("/", 1, true) then
        names[#names + 1] = env
    end
    if #names == 0 then
        return nil
    end
    local past, why = backend:comments(card.id)
    if not past then
        return failure(why)
    end
    for _, name in ipairs(names) do
        if name == card.claimant or board.worked(past, name) then
            return failure(
                card.id:sub(1, board.MIN_PREFIX)
                    .. (name == card.claimant and " is" or " was")
                    .. " claimed by "
                    .. name
                    .. ", so "
                    .. name
                    .. " cannot "
                    .. opts.what
                    .. ". Pass the change back with a note instead."
            )
        end
    end
end

---Check whether a name is the lead or carries no role.
---@param name string the agent name
---@return boolean lead true when the name may run lead-only verbs
local function is_lead(name)
    if not name:find("/", 1, true) then
        return true
    end
    return name:match("^[^/]*/([^/]*)") == "lead"
end

---Refuse a lead-only verb run under another agent name.
---@param action string? what the lead does, nil for deleting a card
---@return dev.cmd.board.Result? err the refusal, nil when the caller is a lead
local function delete_refusal(action)
    local name = os.getenv("DEV_AGENT") or ""
    if not is_lead(name) then
        return failure(
            "only the lead "
                .. (action or "deletes a card")
                .. ", and DEV_AGENT "
                .. name
                .. " is not a lead name, whose role segment is lead. Ask the lead"
                .. (action and "" or ", with the card and the reason")
                .. "."
        )
    end
end

M.USAGE = USAGE
M.FAILURE = FAILURE
M.CLAIMANT_CHARS = CLAIMANT_CHARS
M.AS_FLAG = AS_FLAG
M.usage = usage
M.failure = failure
M.unqueued = unqueued
M.agent_name = agent_name
M.stage_refusal = stage_refusal
M.row_refusal = row_refusal
M.workspace_refusal = workspace_refusal
M.other_home = other_home
M.on_board = on_board
M.children_refusal = children_refusal
M.unreadable_refusal = unreadable_refusal
M.done_refusal = done_refusal
M.tick_refused = tick_refused
M.claimant_refused = claimant_refused
M.is_lead = is_lead
M.delete_refusal = delete_refusal

return M
