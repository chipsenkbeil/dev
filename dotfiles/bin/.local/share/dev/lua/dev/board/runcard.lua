local board = require("dev.board")
local guards = require("dev.board.guards")
local runner = require("dev.board.runner")

local usage = guards.usage
local failure = guards.failure
local parse = guards.parse
local agent_name = guards.agent_name
local claimant = runner.claimant
local claim_card = runner.claim_card

---The run verb, which keeps a session's orders and resume steps on one run card.
---@class dev.board.runcard
local M = { END_FLAG = "--end", ORDERS_FLAG = "--orders" }

local RUN_NAME = "run "

---@class dev.board.runcard.Deps
---@field dispatch fun(sub: string, args: string[], backend: dev.board.Backend): dev.cmd.board.Result
---   runs a board subcommand
---@field add fun(backend: dev.board.Backend, args: string[]): dev.cmd.board.Result adds a card
---@field find_card fun(backend: dev.board.Backend, word: string): dev.board.Card?, dev.cmd.board.Result?
---   finds a card
---@field sentence fun(text: string): string capitalises and ends a sentence
---@field card_line fun(card: dev.board.Card): string names a card on one line
---@field name_chars integer the longest card name

local function run_card_for(cards, name)
    for _, card in ipairs(cards) do
        if board.labelled(card, board.RUN) and not card.done and card.name == RUN_NAME .. name then
            return card
        end
    end
end

---Quote each line of the orders and refuse orders that are empty or over the word limit.
---@param orders string the orders text
---@return string[]? quoted the quoted lines, nil when refused
---@return dev.cmd.board.Result? refused the usage error, set when quoted is nil
local function quote_orders(orders)
    local RUN_ORDERS_WORDS = 250
    local quoted, words = {}, 0
    for line in orders:gmatch("[^\r\n]+") do
        if line:find("%S") then
            quoted[#quoted + 1] = "> " .. line:match("^%s*(.-)%s*$")
        end
    end
    for _ in table.concat(quoted, " "):gmatch("%S+") do
        words = words + 1
    end
    if #quoted == 0 then
        return nil, usage("The " .. M.ORDERS_FLAG .. " flag needs the orders.")
    end
    if words > RUN_ORDERS_WORDS then
        return nil,
            usage(
                string.format(
                    "The orders are %d words and a run card holds at most %d. "
                        .. "Keep the rest in a file and name it in the orders.",
                    words,
                    RUN_ORDERS_WORDS
                )
            )
    end
    return quoted
end

local function start_run(backend, name, quoted, deps)
    local RUN_SIZE = "3"
    local RUN_CHECK = "dev board lint"
    local args = {
        RUN_NAME .. name,
        "--column",
        backend.stages.progress,
        "--size",
        RUN_SIZE,
        "--label",
        board.RUN,
        "--problem",
        "A run keeps its orders and resume steps on the board, so a session finds them after compaction.",
        "--out-of-scope",
        "The work on other cards; this card holds only the run's state.",
        "--done-when",
        "The orders below are carried out " .. board.JUDGEMENT,
        "--done-when",
        "Every card the run took is Done or released " .. board.JUDGEMENT,
        "--done-when",
        "Anything left over is a card on the board " .. board.JUDGEMENT,
        "--checks",
        RUN_CHECK,
    }
    for _, line in ipairs(quoted) do
        args[#args + 1] = "--change"
        args[#args + 1] = line
    end
    local added = deps.add(backend, args)
    if added.message then
        return added
    end
    local card, err = deps.find_card(backend, added.output:match("^added (%S+)"))
    if not card then
        return err
    end
    local taken, fence = claim_card(backend, card, name)
    if not fence then
        taken.message = deps.sentence(taken.message)
            .. " `dev board run` claims the new run card again."
        return taken
    end
    local shown = deps.dispatch("show", { card.id }, backend)
    if shown.message then
        return shown
    end
    return {
        output = "started " .. card.id:sub(1, board.MIN_PREFIX) .. "\n" .. shown.output,
        warnings = added.warnings,
    }
end

local function resume_run(backend, opts, deps)
    local cards, run, name = opts.cards, opts.run, opts.name
    local warnings = {}
    if not run.claimant then
        local taken, fence = claim_card(backend, run, name)
        if not fence then
            warnings[1] = taken.message
        end
    end
    local shown = deps.dispatch("show", { run.id }, backend)
    if shown.message then
        return shown
    end
    local held = {}
    for _, card in ipairs(cards) do
        if card.claimant == name and card.id ~= run.id and not card.done then
            held[#held + 1] = deps.card_line(card)
        end
    end
    local limit = runner.limit()
    local upcoming, message = backend:next(backend.stages.ready, { max_size = limit })
    if not upcoming and message then
        return failure(message)
    end
    return {
        output = table.concat({
            shown.output,
            "held by " .. name .. ":",
            #held > 0 and table.concat(held, "\n") or "nothing",
            "next:",
            upcoming and deps.card_line(upcoming) or "no ready cards",
        }, "\n"),
        warnings = warnings,
    }
end

---@class dev.board.runcard.Plan
---@field ending boolean whether the run ends
---@field quoted string[]? the quoted lines of the orders, nil unless the run starts
---@field name string the session's claimant name

---Check what a run needs before it reads or makes anything on a board.
---
---It refuses a flag mix, orders that are empty or over the word limit, a missing or too long
---session name.
---@param args string[] the run arguments
---@param name_chars integer the longest card name
---@return dev.board.runcard.Plan? plan the parsed run, nil when refused
---@return dev.cmd.board.Result? refused the usage error, set when plan is nil
function M.precheck(args, name_chars)
    local ending, rest = false, {}
    for _, arg in ipairs(args) do
        if arg == M.END_FLAG then
            ending = true
        else
            rest[#rest + 1] = arg
        end
    end
    local flags, words = parse(rest, { [M.ORDERS_FLAG] = true }, { [M.ORDERS_FLAG] = true })
    if not flags then
        return nil, words
    end
    if flags[M.ORDERS_FLAG] and #flags[M.ORDERS_FLAG] > 1 then
        return nil,
            usage("The " .. M.ORDERS_FLAG .. " flag takes one value, so give the orders once.")
    end
    local orders = flags[M.ORDERS_FLAG] and flags[M.ORDERS_FLAG][1]
    if #words > 0 then
        return nil, usage("Unknown argument " .. words[1] .. ".")
    end
    if ending and orders then
        return nil,
            usage("The " .. M.END_FLAG .. " and " .. M.ORDERS_FLAG .. " flags do not go together.")
    end
    local name, why = agent_name()
    if why then
        return nil, why
    end
    local session = os.getenv("CLAUDE_SESSION_ID")
    if not name and (not session or session == "") then
        return nil,
            usage("Run needs DEV_AGENT or CLAUDE_SESSION_ID, so the session keeps one name.")
    end
    name = claimant(name)
    if #RUN_NAME + #name > name_chars then
        return nil, usage("The session name is too long for a card name.")
    end
    local quoted
    if orders then
        local refused
        quoted, refused = quote_orders(orders)
        if not quoted then
            return nil, refused
        end
    end
    return { ending = ending, quoted = quoted, name = name }
end

---Start, resume or end the session's run card.
---@param backend dev.board.Backend the board
---@param args string[] the run arguments
---@param deps dev.board.runcard.Deps the board verbs and helpers the run calls
---@return dev.cmd.board.Result result the run's outcome
function M.run(backend, args, deps)
    local RUN_USAGE = "Start one with `dev board run --orders TEXT`."
    local plan, refused = M.precheck(args, deps.name_chars)
    if not plan then
        return refused
    end
    local name, ending = plan.name, plan.ending
    local cards, message = backend:cards()
    if not cards then
        return failure(message)
    end
    local run = run_card_for(cards, name)
    if plan.quoted then
        if run then
            return failure(
                name
                    .. " already has the run card "
                    .. run.id:sub(1, board.MIN_PREFIX)
                    .. ". Close it with `dev board run "
                    .. M.END_FLAG
                    .. "` first."
            )
        end
        return start_run(backend, name, plan.quoted, deps)
    end
    if not run then
        return failure("There is no open run card for " .. name .. ". " .. RUN_USAGE)
    end
    if ending then
        local closed = deps.dispatch("discard", { run.id, "--reason", "the run ended" }, backend)
        if closed.message then
            return closed
        end
        return { output = "ended " .. run.id:sub(1, board.MIN_PREFIX), warnings = closed.warnings }
    end
    return resume_run(backend, { cards = cards, run = run, name = name }, deps)
end

return M
