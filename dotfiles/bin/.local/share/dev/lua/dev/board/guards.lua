local board = require("dev.board")
local check = require("dev.board.check")
local land = require("dev.board.land")
local dev_os = require("dev.os")
local vcs = require("dev.vcs")

---The refusals and guards a board change runs before it acts.
---@class dev.board.guards
local M = {}

local USAGE = 2
local FAILURE = 1
local CLAIMANT_CHARS = 200
local AS_FLAG = "--as"
local SWITCH = "switch"

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

---Split a verb's arguments into its flags and its words.
---@param args string[] the arguments after the verb
---@param takes table<string, string|boolean> the flags the verb knows, `switch` for a bare flag
---@param many table<string, boolean>? the flags that may repeat, each kept as a list
---@return table<string, string|boolean|string[]>? flags the flags given, nil on a usage error
---@return string[]|dev.cmd.board.Result words the words left, or the usage error
local function parse(args, takes, many)
    local flags, positional = {}, {}
    local i = 1
    while i <= #args do
        local arg = args[i]
        i = i + 1
        if takes[arg] == SWITCH then
            flags[arg] = true
        elseif takes[arg] then
            if i > #args then
                return nil, usage("The " .. arg .. " flag needs a value.")
            end
            if many and many[arg] then
                flags[arg] = flags[arg] or {}
                table.insert(flags[arg], args[i])
            else
                flags[arg] = args[i]
            end
            i = i + 1
        elseif #arg > 1 and arg:sub(1, 1) == "-" then
            return nil, usage("Unknown flag " .. arg .. ".")
        else
            positional[#positional + 1] = arg
        end
    end
    return flags, positional
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
                "An agent name is one word of letters, digits and . - _ / up to "
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
    local stages = backend.stages or board.stages()
    for _, name in ipairs({ stages.review, stages.verify, stages.release }) do
        if not has[name:lower()] then
            return failure(
                "The board has an In Review column and no "
                    .. name
                    .. " column. Run `dev board init` to move the board to the stage columns."
            )
        end
    end
    return nil
end

---Refuse the first checks row that is not a plain command.
---@param runs string[] the rows as given
---@param root string? the workspace the rows run in, nil to skip the PATH and path checks
---@return dev.cmd.board.Result? refusal a usage error naming the row, nil when every row is plain
local function row_refusal(runs, root)
    for _, run in ipairs(runs) do
        local why = check.refusal(run) or root and check.unrunnable(run, root)
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

---Open the Pomb board named `name` with this board's column map, root and stages.
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
        return nil, "Pomb has no board named " .. name .. "."
    end
    board.retarget(home, backend.column_map, backend.root, home:done_columns())
    return home
end

---Split a card word into the board it names and the card prefix.
---@param word string? the card word
---@return string? board the board name, nil when the word names no board
---@return string? prefix the card prefix after the board name
local function split_board(word)
    return (word or ""):match("^(.+):([^:]*)$")
end

---Move to the board named by a `BOARD:PREFIX` card word or a `--board NAME` right after the card.
---
---The card word in `rest` is the bare prefix. Without either, this board stays.
---@param backend dev.board.Backend the board the command runs on
---@param args string[] the command's words, the card first
---@return dev.board.Backend? home the board to act on, nil when refused
---@return string[]? rest the words with the board named off, nil when refused
---@return dev.cmd.board.Result? refused the usage error or failure, set when home is nil
local function on_board(backend, args)
    local named, prefix = split_board(args[1])
    if named then
        local home, why = other_home(backend, named)
        if not home then
            return nil, nil, failure(why)
        end
        return home, { prefix, unpack(args, 2) }
    end
    if args[2] ~= "--board" then
        return backend, args
    end
    if not args[3] then
        return nil, nil, usage("The `--board` flag needs a board name.")
    end
    local home, why = other_home(backend, args[3])
    if not home then
        return nil, nil, failure(why)
    end
    return home, { args[1], unpack(args, 4) }
end

---Refuse a card given as BOARD:PREFIX to a verb that only works on this board.
---@param word string? the card word
---@param verb string the verb's name
---@return dev.cmd.board.Result? refused the failure naming the board, nil when the card is on this board
local function foreign_refusal(word, verb)
    local named = split_board(word)
    if not named then
        return nil
    end
    return failure(
        "The verb "
            .. verb
            .. " works only on this board's cards, and "
            .. word
            .. " is on the board "
            .. named
            .. ". Run it from that board."
    )
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
                        "Card %s is an epic and cannot enter %s, a %s column. "
                            .. "%d of %d children are open.",
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
            "Card "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. " cannot move to "
                .. column
                .. ". Its outcomes cannot be read from Pomb. They cannot be checked."
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
    if board.children_closed(card.epic) then
        return nil
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
                "Card %s cannot move to %s. %d of %d outcomes are unticked (%s). "
                    .. "The reviewer ticks them with `dev board outcome CARD --tick N --as NAME`, "
                    .. "or `dev board discard CARD` drops it.",
                id,
                column,
                #open,
                #card.outcomes,
                table.concat(open, ", ")
            )
        )
    )
end

---Refuse a move into Review or Verify by a card that skipped the stage before it.
---@param stages dev.board.Stages the board's columns
---@param card dev.board.Card the card being moved
---@param column string the column it moves to
---@return dev.cmd.board.Result? err the refusal, nil when the move keeps the stage order
local function skipped_refusal(stages, card, column)
    if card.column == column then
        return nil
    end
    local first
    if column == stages.review then
        local claimed = card.column == stages.progress and card.claimant
        if claimed or card.column == stages.verify then
            return nil
        end
        first = stages.progress .. " under a claim"
    elseif column == stages.verify then
        if card.column == stages.review then
            return failure(
                string.format(
                    "Card %s cannot move to %s from %s. "
                        .. "The verifier's tick of its last open outcome moves it there.",
                    card.id:sub(1, board.MIN_PREFIX),
                    column,
                    card.column
                )
            )
        end
        first = stages.review
    else
        return nil
    end
    return failure(
        string.format(
            "Card %s cannot move to %s from %s. It must pass %s first.",
            card.id:sub(1, board.MIN_PREFIX),
            column,
            card.column,
            first
        )
    )
end

---@class dev.board.guards.proof_refusal.Opts
---@field state (fun(root: string): dev.board.check.State?, string?)? reads the commit to prove,
---   `land.state` when nil

---Refuse a move into Release or Done that the check, the reviews and the outcomes do not back.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card being moved
---@param column string the column it moves to
---@param opts dev.board.guards.proof_refusal.Opts? how to read the commit
---@return dev.cmd.board.Result? err the refusal, nil when the card is proven or the project has no
---   version control to prove it against
local function proof_refusal(backend, card, column, opts)
    local root = backend.root
    local read = opts and opts.state or root and vcs.backend(root) and land.state
    if not root or not read then
        return nil
    end
    local problems = {}
    local state, why = read(root)
    if state then
        local comments = backend:comments(card.id) or {}
        for _, line in ipairs(land.missing_reviews(comments, state, root)) do
            problems[#problems + 1] = line
        end
        for _, line in ipairs(land.refused_reviews(comments, state, root)) do
            problems[#problems + 1] = line
        end
        local unproven = land.checks_problem(comments, state, card.checks or {})
        if unproven then
            problems[#problems + 1] = unproven
        end
        if not (opts and opts.state) then
            problems[#problems + 1] = string.format(
                "Its change is not on trunk. Run `dev board land %s` first.",
                card.id:sub(1, board.MIN_PREFIX)
            )
        end
    else
        problems[1] = why
    end
    local open = done_refusal(card, column)
    if #problems == 0 then
        return open
    end
    local head = open and open.message
        or string.format("Card %s cannot move to %s.", card.id:sub(1, board.MIN_PREFIX), column)
    return failure(head .. " " .. table.concat(problems, " "))
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
            "Ticking an outcome on a claimed card needs the ticker's name. Pass it with `"
                .. AS_FLAG
                .. " NAME`, or set DEV_AGENT."
        )
    end
    if ticker == card.claimant then
        return failure(
            "Card "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. " is claimed by "
                .. ticker
                .. ". Its claimant cannot tick its outcomes."
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
                "Card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. (name == card.claimant and " is" or " was")
                    .. " claimed by "
                    .. name
                    .. ". "
                    .. name
                    .. " cannot "
                    .. opts.what
                    .. ". Pass the change back with a note instead."
            )
        end
    end
end

---Check whether a name is the lead or carries no role at a terminal.
---@param name string the agent name
---@param interactive boolean? whether stdin is a terminal, nil to read it
---@return boolean lead true when the name may run lead-only verbs
local function is_lead(name, interactive)
    if not name:find("/", 1, true) then
        if interactive == nil then
            return dev_os.isatty(0)
        end
        return interactive
    end
    return name:match("^[^/]*/([^/]*)") == "lead"
end

---@enum dev.board.guards.Refusal
local Refusal = { NOT_LEAD = "not_lead" }

---Refuse a lead-only verb run under another agent name.
---@return dev.board.guards.Refusal? reason `NOT_LEAD` when the caller is not a lead, nil otherwise
local function delete_refusal()
    if not is_lead(os.getenv("DEV_AGENT") or "") then
        return Refusal.NOT_LEAD
    end
end

M.USAGE = USAGE
M.FAILURE = FAILURE
M.CLAIMANT_CHARS = CLAIMANT_CHARS
M.AS_FLAG = AS_FLAG
M.usage = usage
M.parse = parse
M.SWITCH = SWITCH
M.failure = failure
M.unqueued = unqueued
M.agent_name = agent_name
M.stage_refusal = stage_refusal
M.row_refusal = row_refusal
---Say whether the commit a card's land note names is already on trunk.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@param opts {holds: (fun(root: string, commit: string, rev: string): boolean)?}? `holds` reads
---   the ancestry, `land.holds` when nil
---@return boolean landed true when trunk holds the landed commit
local function landed_on_trunk(backend, card, opts)
    local root = backend.root
    local holds = opts and opts.holds
    if not root or not (holds or vcs.backend(root)) then
        return false
    end
    local comments = backend:comments(card.id)
    local commit = comments and land.landed_commit(comments)
    if not commit then
        return false
    end
    return (holds or land.holds)(root, commit, vcs.backend(root) == vcs.GIT and "HEAD" or "trunk()")
end

M.landed_on_trunk = landed_on_trunk
M.workspace_refusal = workspace_refusal
M.other_home = other_home
M.on_board = on_board
M.foreign_refusal = foreign_refusal
M.children_refusal = children_refusal
M.unreadable_refusal = unreadable_refusal
M.done_refusal = done_refusal
M.skipped_refusal = skipped_refusal
M.proof_refusal = proof_refusal
M.tick_refused = tick_refused
M.claimant_refused = claimant_refused
M.is_lead = is_lead
M.delete_refusal = delete_refusal
M.Refusal = Refusal

return M
