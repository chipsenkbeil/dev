local board = require("dev.board")
local check = require("dev.board.check")
local claims = require("dev.board.claims")
local config = require("dev.config")
local dev_os = require("dev.os")
local guards = require("dev.board.guards")
local land = require("dev.board.land")
local remote = require("dev.remote")
local render = require("dev.board.render")
local standalone = require("dev.standalone")
local store = require("dev.board.store")
local turn = require("dev.board.turn")
local verb = require("dev.verb")

---The parsing, refusals and turn waits behind the `board` check and land verbs.
---@class dev.board.wiring
local M = {}

local usage = guards.usage
local failure = guards.failure
local EXPECT_FAIL_FLAG = "--expect-fail"
local TIMEOUT_FLAG = "--timeout"

---Parse the flags and the card word of `board check`.
---@param args string[] the arguments
---@return dev.board.wiring.CheckFlags? opts the parsed flags, nil on a usage error
---@return dev.cmd.board.Result? err the usage error
local function check_options(args)
    local opts = { expect_fail = false, seconds = check.DEFAULT_SECONDS, words = {} }
    local i = 1
    while i <= #args do
        local arg = args[i]
        if arg == EXPECT_FAIL_FLAG then
            opts.expect_fail = true
        elseif arg == TIMEOUT_FLAG then
            i = i + 1
            local value = args[i] and args[i]:match("^%d+$")
            local seconds = value and tonumber(value)
            if not seconds or seconds < 1 or seconds > check.MAX_SECONDS then
                return nil,
                    usage(
                        TIMEOUT_FLAG
                            .. " needs a whole number of seconds from 1 to "
                            .. check.MAX_SECONDS
                    )
            end
            opts.seconds = seconds
        elseif #arg > 1 and arg:sub(1, 1) == "-" then
            return nil, usage("unknown flag " .. arg)
        else
            opts.words[#opts.words + 1] = arg
        end
        i = i + 1
    end
    if #opts.words ~= 1 then
        return nil, usage("needs a card")
    end
    return opts
end

---Render the rows as lines with each failing row's tail under it.
---@param rows dev.board.check.Row[] the rows that ran
---@return string[] lines the lines
local function check_lines(rows)
    local lines = {}
    for i, row in ipairs(rows) do
        lines[#lines + 1] = check.line(i, row)
        if row.result ~= check.RESULT.PASS and row.tail ~= "" then
            for line in row.tail:gmatch("[^\n]+") do
                lines[#lines + 1] = "    " .. line
            end
        end
    end
    return lines
end

---@class dev.board.wiring.CheckFlags
---@field expect_fail boolean whether every row should fail
---@field seconds integer the longest each row may run
---@field words string[] the words that are not flags

---@class dev.board.wiring.CheckRowsOpts
---@field backend dev.board.Backend the board backend
---@field card dev.board.Card the card whose rows run
---@field before dev.board.check.State the commit the rows run on
---@field argvs string[][] one command per row
---@field options dev.board.wiring.CheckFlags the parsed flags

---Run the card's rows and record the result.
---@param opts dev.board.wiring.CheckRowsOpts the card, its commit and the commands
---@return dev.cmd.board.Result result the check's outcome
local function check_rows(opts)
    local backend, card, before, argvs, flags =
        opts.backend, opts.card, opts.before, opts.argvs, opts.options
    local short = card.id:sub(1, board.MIN_PREFIX)
    local message
    local rows = {}
    for i, argv in ipairs(argvs) do
        verb.note(string.format("running %d of %d: %s", i, #argvs, card.checks[i]))
        rows[i] = check.run({
            root = backend.root,
            run = card.checks[i],
            argv = argv,
            seconds = flags.seconds,
            expect_fail = flags.expect_fail,
            env = {
                [remote.VERB_ENV] = remote.VERB.CHECK,
                [remote.CARD_ENV] = short,
            },
            on_run_id = function(run_id)
                verb.note(string.format("row %d run %s", i, run_id))
            end,
        })
        if rows[i].refused then
            return failure(
                string.format(
                    "The ci hub refused row %d (%s). Nothing was recorded on %s. The hub said: %s",
                    i,
                    card.checks[i],
                    short,
                    rows[i].refused
                )
            )
        end
    end
    local lines = check_lines(rows)
    local after = check.state(backend.root)
    if not after or after.commit ~= before.commit then
        return failure(
            string.format(
                "the working copy changed while the checks ran (commit %s, then %s), so the result belongs to no commit and was NOT recorded on %s\n%s",
                land.short(before.commit),
                after and land.short(after.commit) or "unknown",
                short,
                table.concat(lines, "\n")
            )
        )
    end
    local held = claims.read(card.id)
    local ok
    ok, message = backend:note(
        card.id,
        check.record(before, rows, flags.expect_fail),
        held and held.fence,
        { kind = "status" }
    )
    if not ok then
        return failure(
            string.format(
                "the result was NOT recorded on %s (%s); the board may or may not hold it, so read dev board notes before trusting or repeating it\n%s",
                short,
                message,
                table.concat(lines, "\n")
            )
        )
    end
    local passed, good, errors = check.summarize(rows, flags.expect_fail)
    local verdict = string.format(
        "recorded on %s at commit %s: %d of %s passed",
        short,
        land.short(before.commit),
        passed,
        render.count_text(#rows, "row")
    )
    if flags.expect_fail and passed > 0 then
        verdict = verdict
            .. "; with --expect-fail every row should fail, so the passing ones prove nothing"
    end
    if flags.expect_fail and errors > 0 then
        verdict = verdict
            .. ". With --expect-fail a row that never started proves nothing. Fix the row."
    end
    lines[#lines + 1] = verdict
    if not good then
        return failure(table.concat(lines, "\n"))
    end
    return { output = table.concat(lines, "\n") }
end

---@class dev.board.wiring.LandWho
---@field name string the caller's agent name
---@field comments {body: string}[] the card's comments, oldest first

---List what keeps the card from landing under the caller.
---@param backend dev.board.Backend the board backend
---@param card dev.board.Card the card
---@param who dev.board.wiring.LandWho the caller and the card's comments
---@return string[] problems the reasons, empty when none apply
local function card_problems(backend, card, who)
    local problems = {}
    local roles = backend.roles
    if card.column ~= roles.verify then
        problems[#problems + 1] = "it is in "
            .. card.column
            .. ", and only a card in "
            .. roles.verify
            .. " lands"
    end
    if card.claimant and card.claimant ~= who.name then
        problems[#problems + 1] = "it is claimed by "
            .. card.claimant
            .. ", and only that claimant lands it, not "
            .. who.name
    end
    local open = guards.done_refusal(card, roles:done_column())
    if open then
        problems[#problems + 1] = open.message
    end
    return problems
end

---List what keeps the card from landing, from its column to the trunk and the reviews.
---@param backend dev.board.Backend the board backend
---@param card dev.board.Card the card
---@param who dev.board.wiring.LandWho the caller and the card's comments
---@return string[] problems the reasons, empty when none apply
---@return dev.board.check.State? state the commit to land, nil when it could not be read
---@return string? carried the commit whose check and reviews carry over, nil when none do
local function land_problems(backend, card, who)
    local problems = card_problems(backend, card, who)
    local state, message = land.state(backend.root)
    if not state then
        problems[#problems + 1] = message
        return problems
    end
    local added = land.added(backend.root, state.commit)
    local standalone_problem = "jj could not list the files the commit adds."
    if added then
        standalone_problem = standalone.land_problem(added, card.labels)
    end
    if standalone_problem then
        problems[#problems + 1] = standalone_problem
    end
    local touched = land.touched(backend.root, state.commit)
    local template_problem = "jj could not list the files the commit touches."
    if touched then
        template_problem = land.template_problem(backend.root, touched)
    end
    if template_problem then
        problems[#problems + 1] = template_problem
    end
    local lacking = land.missing_reviews(who.comments, state)
    local unproven = land.checks_problem(who.comments, state, card.checks)
    local carried, carry_why
    if #lacking > 0 then
        carried, carry_why = land.carry({
            root = backend.root,
            comments = who.comments,
            state = state,
            rows = card.checks,
        })
        if carried then
            lacking, unproven = {}, nil
        else
            lacking = land.missing_reviews(who.comments, state, backend.root)
            if carry_why then
                problems[#problems + 1] = carry_why
            end
        end
    end
    local refused = land.refused_reviews(who.comments, state, backend.root)
    for _, missing in ipairs(lacking) do
        problems[#problems + 1] = missing
    end
    for _, line in ipairs(refused) do
        problems[#problems + 1] = line
    end
    if unproven then
        problems[#problems + 1] = unproven
    end
    if #problems == 0 and not carried then
        local moved = land.trunk_problem(backend.root)
        if moved then
            problems[#problems + 1] = moved
        end
    end
    return problems, state, carried
end

---@class dev.board.wiring.TurnOpts
---@field backend dev.board.Backend the board backend
---@field name string the caller's agent name
---@field id string the full id of the card that lands
---@field short string the short id of the card that lands
---@field wait integer the seconds to keep asking
---@field take dev.board.turn.TakeOpts? a hold and the lease it asks for

---Ask for the landing turn until it is free or the wait ends.
---@param opts dev.board.wiring.TurnOpts the board, the asker and the wait
---@return dev.board.turn.Turn? hold the turn, nil when it stayed taken
---@return string? message why it was not taken
local function await_turn(opts)
    local deadline = store.now() + opts.wait
    local asker = { name = opts.name, card = opts.short, seconds = opts.wait }
    if opts.wait > 0 then
        local ok, why = turn.ask(opts.backend, asker)
        if not ok then
            return nil, why
        end
    end
    local poll = turn.poller()
    while true do
        if opts.wait > 0 then
            local current = opts.backend:card(opts.id)
            if current and current.done then
                turn.leave(opts.backend, opts.name, opts.short)
                return nil, opts.short .. " is done, so there is nothing to wait for"
            end
        end
        local hold, message, place = turn.take(opts.backend, opts.name, opts.short, opts.take)
        if hold or opts.wait == 0 then
            return hold, message
        end
        local kept = not opts.take and turn.held(opts.backend, opts.name, opts.short)
        if kept then
            return kept
        end
        local left = deadline - store.now()
        if left <= 0 then
            turn.leave(opts.backend, opts.name, opts.short)
            return nil, message
        end
        dev_os.nap(math.min(poll:pace(place), left))
    end
end

---@class dev.board.wiring.HeldOpts
---@field backend dev.board.Backend the board backend
---@field card dev.board.Card the card that lands
---@field name string the caller's agent name
---@field hold dev.board.turn.Turn the landing turn in hand
---@field move fun(backend: dev.board.Backend, args: string[]): dev.cmd.board.Result moves the card to its column
---@field clean_up fun(root: string, short: string): string removes the card's bookmark and workspace

---Land the card while the turn is held.
---@param opts dev.board.wiring.HeldOpts the card and the turn in hand
---@return dev.cmd.board.Result result the landing's outcome
local function land_held(opts)
    local backend, card, name, hold = opts.backend, opts.card, opts.name, opts.hold
    local short = card.id:sub(1, board.MIN_PREFIX)
    local message
    local current = card_problems(backend, card, { name = name, comments = {} })
    if #current > 0 then
        return failure(short .. " cannot land:\n  - " .. table.concat(current, "\n  - "))
    end
    local state_ok, bad = land.state(backend.root)
    if not state_ok then
        return failure(short .. " cannot land:\n  - " .. bad)
    end
    local rebased, why = land.rebase(backend.root)
    if rebased == nil then
        return failure(short .. " cannot land: " .. why)
    end
    local fresh
    fresh, message = backend:comments(card.id)
    if not fresh then
        return failure(message)
    end
    local rebase_note = rebased and "\n  (the change was rebased onto trunk under the landing turn)"
        or ""
    local problems, state, carried = land_problems(backend, card, { name = name, comments = fresh })
    if #problems > 0 then
        return failure(
            short .. " cannot land:\n  - " .. table.concat(problems, "\n  - ") .. rebase_note
        )
    end
    local unchecked = carried
        and land.recheck_problem({
            root = backend.root,
            commit = carried,
            card = short,
            rows = config.get(backend.root, "board.land.recheck"),
            note = verb.note,
        })
    if unchecked then
        return failure(short .. " cannot land:\n  - " .. unchecked .. rebase_note)
    end
    local renewed
    renewed, message = turn.renew(backend, hold)
    if not renewed then
        local lost = failure(short .. " cannot land: " .. message)
        lost.lost = true
        return lost
    end
    local landed, output = land.run(backend.root)
    if not landed then
        return failure(
            short .. " stays in " .. card.column .. ", jj land failed:\n" .. output:gsub("\n$", "")
        )
    end
    local on_trunk = land.trunk_commit(backend.root, state.change)
    local commit = land.short(on_trunk or state.commit)
    local held = claims.read(card.id)
    local text
    if on_trunk then
        text = string.format(
            "Landed commit %s (change %s) on trunk, run by %s.",
            commit,
            state.change,
            name
        )
    else
        text = string.format(
            "Landed change %s, run by %s. Trunk could not be read after the land, so %s is the commit from before it and may differ from the one on trunk.",
            state.change,
            name,
            commit
        )
    end
    if carried then
        text = string.format(
            "%s The check and reviews were carried over from commit %s: the change id is the same, the interdiff is empty, and the rebase left no conflict.",
            text,
            land.short(carried)
        )
    end
    local deploys = config.get(backend.root, "board.land.deploys") == true
    local target = deploys and backend.roles.release or backend.roles:done_column()
    if deploys then
        text = text .. " It waits in " .. target .. " for the deploy."
    end
    local noted
    noted, message = backend:note(card.id, text, held and held.fence, { kind = "done" })
    if not noted then
        local refused = failure(
            string.format(
                "landed commit %s, but the done note was NOT written on %s (%s) and the card was not moved; write the note and move it to %s by hand",
                commit,
                short,
                message,
                target
            )
        )
        refused.landed = true
        return refused
    end
    local moved = opts.move(backend, { card.id, target })
    if moved.code then
        local refused = failure(
            string.format(
                "landed commit %s and noted it on %s, but the move to %s failed: %s",
                commit,
                short,
                target,
                moved.message
            )
        )
        refused.landed = true
        return refused
    end
    local left = backend:card(card.id)
    if left and left.claimant then
        claims.stop(card.id)
        local released, stuck = backend:release(card.id, held and held.fence)
        if not released then
            verb.note("dev: landed, but the claim was not released: " .. stuck)
        end
    end
    return {
        output = string.format(
            "landed %s at commit %s%s and moved it to %s",
            short,
            commit,
            on_trunk and ""
                or " (the commit from before the land, which may differ: trunk could not be read)",
            target
        ) .. opts.clean_up(backend.root, short),
    }
end

---Tell the caller its landing turn is still held after a refusal.
---@param short string the card's short id
---@return string note the text to append to the refusal
local function kept_note(short)
    return "\n  (the landing turn you hold for "
        .. short
        .. " stays held while its lease lasts, so fix this and land again, or give it back with dev board turn "
        .. short
        .. " --release)"
end

M.check_options = check_options
M.check_lines = check_lines
M.check_rows = check_rows
M.card_problems = card_problems
M.land_problems = land_problems
M.await_turn = await_turn
M.land_held = land_held
M.kept_note = kept_note

return M
