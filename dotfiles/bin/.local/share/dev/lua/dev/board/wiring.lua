local board = require("dev.board")
local check = require("dev.board.check")
local claims = require("dev.board.claims")
local config = require("dev.config")
local dev_os = require("dev.os")
local dev_text = require("dev.text")
local guards = require("dev.board.guards")
local land = require("dev.board.land")
local remote = require("dev.remote")
local runner = require("dev.board.runner")
local board_select = require("dev.board.select")
local scm = require("dev.scm")
local standalone = require("dev.standalone")
local store = require("dev.board.store")
local turn = require("dev.board.turn")
local vcs = require("dev.vcs")
local verb = require("dev.verb")

---The parsing, refusals and turn waits behind the `board` check and land verbs.
---@class dev.board.wiring
local M = {}

local usage = guards.usage
local failure = guards.failure
local EXPECT_FAIL_FLAG = "--expect-fail"
local TIMEOUT_FLAG = "--timeout"
local RUN_FLAG = "--run"
local MIN_RUN_COMMIT = 7
local REQUIRE_CHANGE_RUN = "board.land.require_change_run"
local REVIEWER_TOKEN_SETTING = "board.pomb.reviewer_token"

---Parse the flags and the card word of `board check`.
---@param root string the project root, whose config sets the default row wait
---@param args string[] the arguments
---@return dev.board.wiring.CheckFlags? opts the parsed flags, nil on a usage error
---@return dev.cmd.board.Result? err the usage error
local function check_options(root, args)
    local opts = { expect_fail = false, words = {} }
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
                        "The "
                            .. TIMEOUT_FLAG
                            .. " flag needs a whole number of seconds from 1 to "
                            .. check.MAX_SECONDS
                            .. "."
                    )
            end
            opts.seconds = seconds
        elseif arg == RUN_FLAG then
            i = i + 1
            opts.run = args[i] and args[i]:match("^%x+$")
            if not opts.run then
                return nil, usage("The " .. RUN_FLAG .. " flag needs a ci run id.")
            end
        elseif #arg > 1 and arg:sub(1, 1) == "-" then
            return nil, usage("Unknown flag " .. arg .. ".")
        else
            opts.words[#opts.words + 1] = arg
        end
        i = i + 1
    end
    if #opts.words ~= 1 then
        return nil, usage("Needs a card.")
    end
    opts.seconds = opts.seconds or check.row_seconds(root)
    return opts
end

---Render the rows as lines with each failing row's tail under it.
---@param rows dev.board.check.Row[] the rows that ran
---@return string[] lines the lines
local function check_lines(rows)
    local lines = {}
    for i, row in ipairs(rows) do
        lines[#lines + 1] = check.line(i, row)
        if row.result ~= check.Result.PASS and row.tail ~= "" then
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
---@field run string? the ci run to record the rows from instead of starting one
---@field words string[] the words that are not flags

---Renew the caller's claim on a card, and say so when it could not be.
---@param backend dev.board.Backend the board backend
---@param card dev.board.Card the card whose claim to renew
---@param name string? the caller's agent name
---@param seconds integer? the seconds the claim must outlast when that passes the size's cap
local function renew_claim(backend, card, name, seconds)
    local why = runner.renew_claim(backend, card, name, seconds)
    if why then
        verb.note("The claim was not renewed. " .. dev_text.sentence(why))
    end
end

---@param notes string[]? the sentences a rebase left about the workspaces it moved
local function note_all(notes)
    for _, line in ipairs(notes or {}) do
        verb.note(line)
    end
end

---@class dev.board.wiring.check_rows.Opts
---@field name string? the caller's agent name
---@field backend dev.board.Backend the board backend
---@field card dev.board.Card the card whose rows run
---@field before dev.board.check.State the commit the rows run on
---@field argvs string[][] one command per row
---@field options dev.board.wiring.CheckFlags the parsed flags

---Run the rows of a plan as one ci run.
---
---The run takes the label a `dev --remote` row would give it. `ci` refuses a run that has no
---`DEV_AGENT` and no terminal.
---@param opts dev.board.wiring.check_rows.Opts the card, its commit and the flags
---@param plan dev.board.check.Plan the rows that share the run
---@param env table<string, string> variables set for the run
---@return dev.board.check.Row[] rows the finished rows by their place in the card's checks
local function run_shared(opts, plan, env)
    local places = {}
    for _, entry in ipairs(plan.rows) do
        places[#places + 1] = tostring(entry.index)
    end
    local text = table.concat(places, ", ")
    local attach = opts.options.run
    verb.note(
        attach
                and string.format(
                    "Waiting on ci run %s for rows %s of %d.",
                    attach,
                    text,
                    #opts.argvs
                )
            or string.format("running rows %s of %d as one ci run", text, #opts.argvs)
    )
    local label = remote.run_label(opts.backend.root, {
        DEV_AGENT = os.getenv("DEV_AGENT"),
        DEV_CI_VERB = env[remote.VERB_ENV],
        DEV_CI_CARD = env[remote.CARD_ENV],
    }, { tty = false })
    local done = check.run_group({
        root = opts.backend.root,
        plan = plan,
        seconds = opts.options.seconds,
        env = { DEV_AGENT = label },
        attach = attach,
        on_run_id = function(run_id)
            verb.note(string.format("rows %s run %s", text, run_id))
        end,
    })
    local rows = {}
    for k, entry in ipairs(plan.rows) do
        rows[entry.index] = done[k]
    end
    return rows
end

---Find the landed card whose commit the working copy sits on.
---
---A card the board holds in Release names the commit `land` put on trunk, and `land` passed its
---checks first, so trunk was green at that commit.
---@param backend dev.board.Backend the board backend
---@return string? proof the card and the commit as `CARD@COMMIT`, nil when no card proves it
local function trunk_proof(backend)
    local base = land.base_commit(backend.root)
    local cards = base and backend:cards()
    for _, card in ipairs(cards or {}) do
        local comments = card.column == backend.stages.release and backend:comments(card.id)
        local landed = comments and land.landed_commit(comments)
        if landed and (base:sub(1, #landed) == landed or landed:sub(1, #base) == base) then
            return card.id:sub(1, board.MIN_PREFIX) .. "@" .. land.short(base)
        end
    end
end

---Read the test files the project lists as mac-only.
---
---A `mac_only` that is not a list of file paths ends the process with exit 1.
---@param root string the project root
---@return table<string, boolean> listed the listed files as a set, empty when none is set
local function mac_only_files(root)
    local key = "board.check.mac_only"
    local value = config.get(root, key)
    local listed = {}
    if value == nil then
        return listed
    end
    local bad = type(value) ~= "table" or (#value == 0 and next(value) ~= nil)
    for _, path in ipairs(not bad and value or {}) do
        bad = bad or type(path) ~= "string" or not path:find("%S")
        listed[path] = true
    end
    if bad then
        verb.die("The `" .. key .. "` setting must be a list of file paths.")
    end
    return listed
end

---Record the leading rows that passed, when more passed than the last record holds.
---
---A record that cannot be written costs only the saving, so it is told and the check goes on. A
---working copy that moved off the checked commit gets no record.
---@param opts dev.board.wiring.check_rows.Opts the card, its commit and the flags
---@param rows dev.board.check.Row[] the finished rows by their place in the card's checks
---@param posted integer how many leading rows the newest record of this run holds
---@return integer posted how many leading rows the newest record holds now
local function post_partial(opts, rows, posted)
    local backend, card, before = opts.backend, opts.card, opts.before

    -- Count the leading rows that passed
    local count = 0
    while rows[count + 1] and rows[count + 1].result == check.Result.PASS do
        count = count + 1
    end

    -- Leave the record alone when nothing new passed or the working copy moved
    local now = check.state(backend.root)
    if count <= posted or not now or now.commit ~= before.commit then
        return posted
    end

    -- Write the leading rows as a partial record
    local held = claims.read(card.id)
    local leading = { unpack(rows, 1, count) }
    local stamped = { commit = before.commit, change = before.change }
    local ok, message = backend:note(
        card.id,
        check.record(stamped, leading, check.Mode.PARTIAL),
        held and held.fence,
        { kind = board.NoteKind.STATUS }
    )
    if not ok then
        verb.note("The rows that passed were not saved. " .. dev_text.sentence(message))
        return posted
    end
    return count
end

---@class dev.board.wiring.start_rows.Opts
---@field check dev.board.wiring.check_rows.Opts the card, its commit and the flags
---@field commands string[] the rows as the card holds them
---@field argvs string[][] the rows' words after narrowing
---@field rows dev.board.check.Row[] the finished rows by their place, which a row ended at its start joins
---@field skip table<integer, boolean>[] the places that run another way, one set for each way
---@field env table<string, string> variables set for each start

---Start every ci row that runs on its own, to queue their runs in ci together.
---
---A row that ends at its start, failed or passed, is left in `rows`, and a refused start ends the
---starting. A serial run starts none.
---@param opts dev.board.wiring.start_rows.Opts the rows and where they start
---@return table<integer, string> pending the ci run id of each started row by its place
local function start_rows(opts)
    local commands, argvs, rows = opts.commands, opts.argvs, opts.rows
    local backend, flags = opts.check.backend, opts.check.options
    local pending = {}
    if flags.expect_fail or flags.run then
        return pending
    end
    for i, argv in ipairs(argvs) do
        local apart = false
        for _, set in ipairs(opts.skip) do
            apart = apart or set[i]
        end
        if not rows[i] and not apart and check.detachable(commands[i], argv) then
            renew_claim(backend, opts.check.card, opts.check.name, flags.seconds)
            local run_id, ended = check.start({
                root = backend.root,
                run = commands[i],
                argv = argv,
                seconds = flags.seconds,
                env = opts.env,
            })
            if run_id then
                pending[i] = run_id
                verb.note(
                    string.format(
                        "started row %d of %d as ci run %s: %s",
                        i,
                        #argvs,
                        run_id,
                        commands[i]
                    )
                )
            else
                rows[i] = ended
                if ended.refused then
                    break
                end
            end
        end
    end
    return pending
end

---Record the named test rows that rode on the plain test row's ci run.
---
---A host with no ci run id, as on a ci box, left nothing to read, so each guest runs on its own.
---So does a guest beside a host that an earlier run of this commit kept, since that run's log
---may not hold the guest's files.
---@class dev.board.wiring.settle_guests.Opts
---@field check dev.board.wiring.check_rows.Opts the card, its commit and the flags
---@field fold dev.board.check.Fold the host and its guests
---@field commands string[] the rows as the card holds them
---@field argvs string[][] the rows' words after narrowing
---@field rows dev.board.check.Row[] the finished rows by their place, which the guests join
---@field kept table<integer, dev.board.check.RecordRow> rows an earlier run passed, by place
---@field env table<string, string> variables set for each row

---@param settle dev.board.wiring.settle_guests.Opts the rows and where they ran
---@return integer? refused the place of a guest the ci hub refused, nil when none was
local function settle_guests(settle)
    local opts, fold, commands, argvs, rows =
        settle.check, settle.fold, settle.commands, settle.argvs, settle.rows
    local backend, flags = opts.backend, opts.options
    local host = rows[fold.host]
    local open = {}
    for _, place in ipairs(fold.guests) do
        if not rows[place] then
            open[#open + 1] = place
        end
    end
    if not host or #open == 0 then
        return nil
    end

    -- Run a guest on its own and say whether the hub refused it
    local function run_alone(place)
        renew_claim(backend, opts.card, opts.name, flags.seconds)
        verb.note(string.format("running %d of %d: %s", place, #argvs, commands[place]))
        rows[place] = check.run({
            root = backend.root,
            run = commands[place],
            argv = argvs[place],
            seconds = flags.seconds,
            expect_fail = flags.expect_fail,
            env = settle.env,
            on_run_id = function(run_id)
                verb.note(string.format("row %d run %s", place, run_id))
            end,
        })
        return rows[place].refused ~= nil
    end

    if host.run_id ~= "-" and not settle.kept[fold.host] then
        local asked = {}
        for k, place in ipairs(open) do
            local _, words = check.job_row(argvs[place])
            asked[k] = { run = commands[place], words = words }
        end
        verb.note(
            string.format(
                "reading rows %s from the test log of ci run %s",
                table.concat(open, ", "),
                host.run_id
            )
        )
        local unread = {}
        for k, row in ipairs(check.folded(host, asked, flags.expect_fail)) do
            rows[open[k]] = row
            if row.unread then
                unread[#unread + 1] = open[k]
            end
        end
        open = unread
    end
    for _, place in ipairs(open) do
        if run_alone(place) then
            return place
        end
    end
    return nil
end

---Run the card's rows and record the result.
---
---Each row that passes in a row from the first is saved in a partial record, and a rerun at the
---same commit skips those rows.
---
---An `--expect-fail` run on a commit with a trunk proof runs the rows the card adds only. Without
---a proof it runs every row, which is then the only sign that trunk was green.
---@param opts dev.board.wiring.check_rows.Opts the card, its commit and the commands
---@return dev.cmd.board.Result result the check's outcome
local function check_rows(opts)
    local backend, card, before, argvs, flags =
        opts.backend, opts.card, opts.before, opts.argvs, opts.options
    local short = card.id:sub(1, board.MIN_PREFIX)
    local message
    local rows = {}
    local commands, skipped = card.checks, 0
    local proof = flags.expect_fail and not flags.run and trunk_proof(backend) or nil
    if proof then
        local baseline = check.baseline(card.checks, argvs)
        commands, argvs, skipped = baseline.commands, baseline.argvs, baseline.skipped
    end
    local narrowed = {}
    argvs = board_select.narrow_rows(backend.root, commands, argvs, function()
        return land.card_touched(backend.root)
    end, function(row, count)
        narrowed[row] = count
        verb.note(string.format("Row %d narrowed to %d suites.", row, count))
    end)
    ---@type table<integer, string[]> suites narrowing added per row, which `record` writes as ran=
    local ran = {}
    for row, count in pairs(narrowed) do
        ran[row] = { unpack(argvs[row], #argvs[row] - count + 1) }
    end
    local env = {
        [remote.VERB_ENV] = remote.Verb.CHECK,
        [remote.CARD_ENV] = short,
    }
    local listed = mac_only_files(backend.root)
    local mac = {}
    for i, argv in ipairs(argvs) do
        if not flags.run and check.mac_only(argv, listed) then
            mac[i] = true
        end
    end

    -- Take the named test rows out, to read their results from the plain test row's run
    local fold = not flags.run and check.fold(commands, argvs, mac) or nil
    local guest = {}
    local planned, planned_argvs, origin = commands, argvs, nil
    if fold then
        argvs = { unpack(argvs) }
        argvs[fold.host] = fold.argv
        planned, planned_argvs, origin = {}, {}, {}
        for _, place in ipairs(fold.guests) do
            guest[place] = true
        end
        for i, argv in ipairs(argvs) do
            if not guest[i] then
                planned[#planned + 1] = commands[i]
                planned_argvs[#planned_argvs + 1] = argv
                origin[#origin + 1] = i
            end
        end
    end
    local plan
    if not flags.expect_fail or flags.run then
        plan = check.plan(planned, planned_argvs, function()
            return remote.default_jobs(backend.root)
        end)
        for _, entry in ipairs(plan and origin and plan.rows or {}) do
            entry.index = origin[entry.index]
        end
    end
    if next(mac) then
        plan = nil
    end
    if flags.run then
        plan = plan or check.single_plan(commands, argvs)
        if not plan then
            return failure(
                string.format(
                    "Card %s has no rows that share one ci run, so --run has nothing to record.",
                    short
                )
            )
        end
        local at = check.run_commit(flags.run)
        local full = before.commit
        local width = at and math.min(#at, #full) or 0
        if width < MIN_RUN_COMMIT or at:sub(1, width) ~= full:sub(1, width) then
            return failure(
                string.format(
                    "The ci run %s is of commit %s, not the checked commit %s. Nothing was recorded on card %s.",
                    flags.run,
                    at and at:sub(1, 12) or "unknown",
                    land.short(full),
                    short
                )
            )
        end
    end
    local shared, places = {}, {}
    for _, entry in ipairs(plan and plan.rows or {}) do
        shared[entry.index] = true
        places[#places + 1] = entry.index
    end

    -- Keep the rows that already passed at this commit
    local kept = {}
    if not flags.expect_fail and not flags.run then
        local past = backend:comments(card.id)
        kept = check.resume(past or {}, before.commit, commands, places)
        for i = 1, #commands do
            local row = kept[i]
            if row then
                rows[i] =
                    { run = commands[i], run_id = row.run_id, result = row.result, ran = row.ran }
                local where = row.run_id == "-" and "" or " in ci run " .. row.run_id
                verb.note(
                    string.format(
                        "Row %d of %d passed%s at this commit, so it is skipped.",
                        i,
                        #argvs,
                        where
                    )
                )
            end
        end
    end
    local posted = 0
    while rows[posted + 1] do
        posted = posted + 1
    end

    -- Tell a reader of the card that the rows have started
    if not flags.run then
        local held = claims.read(card.id)
        local ok, why = backend:note(
            card.id,
            string.format(
                "Check started at commit %s on %d rows, by %s.",
                land.short(before.commit),
                #argvs,
                opts.name or "an unnamed caller"
            ),
            held and held.fence,
            { kind = board.NoteKind.STATUS }
        )
        if not ok then
            verb.note("The start of the check was not noted. " .. dev_text.sentence(why))
        end
    end
    local pending = start_rows({
        check = opts,
        commands = commands,
        argvs = argvs,
        rows = rows,
        skip = { mac, shared, guest },
        env = env,
    })
    for i, argv in ipairs(argvs) do
        if mac[i] then
            verb.note(
                string.format(
                    "Not running row %d of %d. It is a mac-only test: %s",
                    i,
                    #argvs,
                    commands[i]
                )
            )
            rows[i] = check.not_run(commands[i])
        elseif guest[i] then
            if not rows[i] then
                verb.note(
                    string.format(
                        "Row %d of %d waits for the test log of row %d.",
                        i,
                        #argvs,
                        fold.host
                    )
                )
            end
        elseif plan and shared[i] then
            if not rows[i] then
                renew_claim(backend, card, opts.name, flags.seconds)
                local done = run_shared(opts, plan, env)
                for _, entry in ipairs(plan.rows) do
                    rows[entry.index] = done[entry.index]
                end
            end
        elseif not rows[i] and not pending[i] then
            renew_claim(backend, card, opts.name, flags.seconds)
            verb.note(string.format("running %d of %d: %s", i, #argvs, commands[i]))
            rows[i] = check.run({
                root = backend.root,
                run = commands[i],
                argv = argv,
                seconds = flags.seconds,
                expect_fail = flags.expect_fail,
                env = env,
                on_run_id = function(run_id)
                    verb.note(string.format("row %d run %s", i, run_id))
                end,
            })
        end
        if rows[i] and rows[i].refused then
            return failure(
                string.format(
                    "The ci hub refused row %d (%s). Nothing was recorded on card %s. The hub said: %s",
                    i,
                    commands[i],
                    short,
                    rows[i].refused
                )
            )
        end
        if not flags.expect_fail and i < #argvs then
            posted = post_partial(opts, rows, posted)
        end
    end

    -- Wait for the started rows in card order
    local waiting = {}
    for i in ipairs(argvs) do
        if pending[i] then
            waiting[#waiting + 1] = i
        end
    end
    for k, i in ipairs(waiting) do
        renew_claim(backend, card, opts.name, flags.seconds)
        verb.note(string.format("waiting on row %d of %d, ci run %s", i, #argvs, pending[i]))
        local job = check.job_row(argvs[i])
        rows[i] = check.run_group({
            root = backend.root,
            plan = { rows = { { index = i, job = job, run = commands[i] } }, args = {} },
            seconds = flags.seconds,
            attach = pending[i],
        })[1]
        verb.note(string.format("row %d of %d ended: %s", i, #argvs, rows[i].result))
        if k < #waiting then
            posted = post_partial(opts, rows, posted)
        end
    end
    if fold then
        local refused = settle_guests({
            check = opts,
            fold = fold,
            commands = commands,
            argvs = argvs,
            rows = rows,
            kept = kept,
            env = env,
        })
        if refused then
            return failure(
                string.format(
                    "The ci hub refused row %d (%s). Nothing was recorded on card %s. The hub said: %s",
                    refused,
                    commands[refused],
                    short,
                    rows[refused].refused
                )
            )
        end
    end
    local lines = check_lines(rows)
    local told = {}
    for _, row in ipairs(rows) do
        if row.result == check.Result.TIMEOUT and row.run_id ~= "-" and not told[row.run_id] then
            told[row.run_id] = true
            lines[#lines + 1] = string.format(
                "The wait ended while ci run %s was still going. Record it when it ends with `dev board check %s --run %s`.",
                row.run_id,
                short,
                row.run_id
            )
        end
    end
    local after = check.state(backend.root)
    if not after or after.commit ~= before.commit then
        return failure(
            string.format(
                "The working copy changed while the checks ran, from commit %s to commit %s. The result belongs to no commit, so it was NOT recorded on card %s.\n%s",
                land.short(before.commit),
                after and land.short(after.commit) or "unknown",
                short,
                table.concat(lines, "\n")
            )
        )
    end
    local held = claims.read(card.id)
    local stamped = { commit = before.commit, change = before.change, proof = proof }
    for i, row in ipairs(rows) do
        if row.result ~= check.Result.NOT_RUN then
            row.ran = row.ran or ran[i]
        end
    end
    local ok
    ok, message = backend:note(
        card.id,
        check.record(stamped, rows, flags.expect_fail),
        held and held.fence,
        { kind = board.NoteKind.STATUS }
    )
    if not ok then
        return failure(
            string.format(
                "The result was NOT recorded on card %s. %s The board may or may not hold it. Read `dev board notes` before trusting or repeating it.\n%s",
                short,
                dev_text.sentence(message),
                table.concat(lines, "\n")
            )
        )
    end
    local summary = check.summarize(rows, flags.expect_fail)
    local verdict = string.format(
        "recorded on %s at commit %s: %d of %s passed",
        short,
        land.short(before.commit),
        summary.passed,
        dev_text.count(#rows, "row")
    )
    if flags.expect_fail and summary.proves_nothing > 0 then
        verdict = verdict
            .. ". With --expect-fail every row but the plain lint and test rows should fail, so the passing ones prove nothing."
    elseif flags.expect_fail and summary.errors == 0 and not summary.good then
        verdict = verdict .. ". With --expect-fail a new row should fail, and none did."
    end
    if flags.expect_fail and summary.errors > 0 then
        verdict = verdict
            .. (verdict:sub(-1) == "." and " " or ". ")
            .. "With --expect-fail a row that never started proves nothing. Fix the row."
    end
    if proof and skipped > 0 then
        verdict = verdict
            .. string.format(
                "%sThe baseline left out %s that trunk proof %s covers.",
                verdict:sub(-1) == "." and " " or ". ",
                dev_text.count(skipped, "standard row"),
                proof
            )
    end
    lines[#lines + 1] = verdict
    if not summary.good then
        return failure(table.concat(lines, "\n"))
    end
    return { output = table.concat(lines, "\n") }
end

---@class dev.board.wiring.LandWho
---@field name string the caller's agent name
---@field comments {body: string}[] the card's comments, oldest first
---@field untaken boolean? true when no turn is held, so the turn's own trunk compare decides
---@field ignore_change_run string? the reason to land past a failed gerrit change run
---@field change_run_read boolean? true when the change run was read before the rebase

---Print the line that says what a change run lookup found instead, and pass its refusal on.
---@param problem string? the refusal
---@param seen string? the line that says what was found instead
---@return string? problem the refusal
local function noted_run_problem(problem, seen)
    if seen then
        verb.note(seen)
    end
    return problem
end

---Name why a failed gerrit change run of the commit stops the landing.
---@param root string the project root
---@param commit string the commit whose run is read
---@param ignore string? the reason to land past the run
---@return string? problem the refusal, nil when the landing may go on
local function failed_change_run(root, commit, ignore)
    if ignore then
        return nil
    end
    return noted_run_problem(land.change_run_problem(root, commit, {
        require_run = config.get(root, REQUIRE_CHANGE_RUN) == true,
    }))
end

---Name why the change run of a commit the rebase rewrote stops the landing, when the project
---requires one.
---@param root string the project root
---@param ignore string? the reason to land past the run
---@return string? problem the refusal, nil when the landing may go on
local function rebased_change_run(root, ignore)
    if ignore or config.get(root, REQUIRE_CHANGE_RUN) ~= true then
        return nil
    end
    local state, bad = land.state(root)
    if not state then
        return bad
    end
    return noted_run_problem(land.rebased_run_problem(root, state.commit))
end

---List what keeps the card from landing under the caller.
---@param backend dev.board.Backend the board backend
---@param card dev.board.Card the card
---@param who dev.board.wiring.LandWho the caller and the card's comments
---@return string[] problems the reasons, empty when none apply
local function card_problems(backend, card, who)
    local problems = {}
    local stages = backend.stages
    if card.column ~= stages.verify then
        problems[#problems + 1] = "It is in "
            .. card.column
            .. ", and only a card in "
            .. stages.verify
            .. " lands."
    end
    if card.claimant and card.claimant ~= who.name then
        problems[#problems + 1] = "It is claimed by "
            .. card.claimant
            .. ", and only that claimant lands it, not "
            .. who.name
            .. "."
    end
    local open = guards.done_refusal(card, stages:done_column())
    if open then
        problems[#problems + 1] = open.message
    end
    return problems
end

---Name each review recorded on the credential that claimed the card.
---
---Nothing is checked unless `[board.pomb] reviewer_token` is set on this machine.
---@param comments {body: string, who: string?}[] the card's comments, oldest first
---@param state dev.board.check.State the commit that would land
---@return string[] problems one line per review
local function credential_problems(comments, state)
    if config.user(REVIEWER_TOKEN_SETTING) == nil then
        return {}
    end
    local problems = {}
    for _, shared in ipairs(land.shared_credentials(comments, state)) do
        problems[#problems + 1] = string.format(
            "The %s review by %s was recorded on the credential of %s, which claimed the card.",
            shared.kind,
            shared.by,
            shared.claimant
        )
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
---@return boolean? check_only true when only the check carries and the reviews are judged apart
local function land_problems(backend, card, who)
    local problems = card_problems(backend, card, who)
    local state, message = land.state(backend.root)
    if not state then
        problems[#problems + 1] = message
        return problems
    end
    local added = land.added(backend.root, state.commit)
    local tool = vcs.LABEL[vcs.backend(backend.root) or vcs.JJ]
    local standalone_problem = tool .. " could not list the files the commit adds."
    if added then
        standalone_problem = standalone.land_problem(added, card.labels)
    end
    if standalone_problem then
        problems[#problems + 1] = standalone_problem
    end
    local touched = land.touched(backend.root, state.commit)
    local template_problem = tool .. " could not list the files the commit touches."
    if touched then
        template_problem = land.template_problem(backend.root, touched)
    end
    if template_problem then
        problems[#problems + 1] = template_problem
    end
    local lacking = land.missing_reviews(who.comments, state)
    local unproven = land.checks_problem(who.comments, state, card.checks)
    local carried, carry_why, check_only
    if #lacking > 0 or unproven then
        carried, carry_why, check_only = land.carry({
            root = backend.root,
            comments = who.comments,
            state = state,
            rows = card.checks,
        })
        if check_only and not unproven then
            carried, carry_why, check_only = nil, nil, nil
        end
        if carried and check_only then
            unproven = nil
            lacking = land.missing_reviews(who.comments, state, backend.root)
            if #lacking > 0 then
                problems[#problems + 1] = string.format(
                    "The check at commit %s carries over to this commit. Its reviews do not carry over.",
                    land.short(carried)
                )
            end
        elseif carried then
            lacking, unproven = {}, nil
        elseif #lacking > 0 then
            lacking = land.missing_reviews(who.comments, state, backend.root)
            if carry_why then
                problems[#problems + 1] = carry_why
            end
        end
    end
    local refused = land.refused_reviews(who.comments, state, backend.root)
    for _, missing in ipairs(lacking) do
        if not (carry_why and carry_why:find(missing, 1, true)) then
            problems[#problems + 1] = missing
        end
    end
    for _, line in ipairs(refused) do
        problems[#problems + 1] = line
    end
    for _, line in ipairs(credential_problems(who.comments, state)) do
        problems[#problems + 1] = line
    end
    if unproven then
        problems[#problems + 1] = unproven
    end
    if #problems == 0 and not carried and not who.untaken then
        local moved = land.trunk_problem(backend.root)
        if moved then
            problems[#problems + 1] = moved
        end
    end
    local unfinished = not who.change_run_read
        and failed_change_run(backend.root, state.commit, who.ignore_change_run)
    if unfinished then
        problems[#problems + 1] = unfinished
    end
    return problems, state, carried, check_only
end

---@class dev.board.wiring.await_turn.Opts
---@field backend dev.board.Backend the board backend
---@field name string the caller's agent name
---@field id string the full id of the card that lands
---@field short string the short id of the card that lands
---@field wait integer the seconds to keep asking
---@field take dev.board.turn.take.Opts? a hold and the lease it asks for

---Ask for the landing turn until it is free or the wait ends.
---@param opts dev.board.wiring.await_turn.Opts the board, the asker and the wait
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
                return nil, "Card " .. opts.short .. " is done. There is nothing to wait for."
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

---@class dev.board.wiring.Prepared
---@field state dev.board.check.State the commit that was checked and rebased onto trunk
---@field carried string? the commit whose check and reviews carry over
---@field check_only boolean? true when only the check carries over
---@field companions dev.board.Card[] the other cards that land with it, each read after the rebase
---@field ignore_change_run string? the reason the failed change run was ignored

---@class dev.board.wiring.land_prepare.Opts
---@field backend dev.board.Backend the board backend
---@field card dev.board.Card the card that lands
---@field companions dev.board.Card[] the other cards the same change carries, empty when none
---@field name string the caller's agent name
---@field hold dev.board.turn.Turn? a hold the caller already has, stretched for the recheck
---@field ignore_change_run string? the reason to land past a failed gerrit change run

---End a landed card's claim, or say that it stays when no local claim holds a fence to send.
---@param backend dev.board.Backend the board backend
---@param card dev.board.Card the landed card, read after its move
---@param held dev.board.claims.State? the local claim file of the card
local function release_landed(backend, card, held)
    local sent, stuck, reason, detail = claims.finish(backend, card.id, held)
    if sent == nil then
        verb.note(
            string.format(
                "Landed, and the card stays claimed by %s until the claim lapses "
                    .. "or its owner releases it.",
                card.claimant
            )
        )
    elseif not sent then
        verb.note(
            "Landed, but the claim was not released. "
                .. board.release_refusal(reason, stuck, detail, held.fence)
        )
    end
end

---@alias dev.board.wiring.MoveFn fun(b: dev.board.Backend, args: string[]): dev.cmd.board.Result

---@class dev.board.wiring.finish_companion.Opts
---@field backend dev.board.Backend the board backend
---@field move dev.board.wiring.MoveFn moves the card to its column
---@field other dev.board.Card the card that landed with the first one
---@field first dev.board.Card the card that ran the landing
---@field text string the first card's done note
---@field target string the column the landed cards move to

---Write the done note on a card that landed with the first one, move it and end its claim.
---@param opts dev.board.wiring.finish_companion.Opts the two cards and the note
---@return string? problem what went wrong, nil when the card is done
local function finish_companion(opts)
    local backend, other = opts.backend, opts.other
    local short = other.id:sub(1, board.MIN_PREFIX)
    local held = claims.read(other.id)
    local noted, message = backend:note(
        other.id,
        opts.text .. " It landed with card " .. opts.first.id:sub(1, board.MIN_PREFIX) .. ".",
        held and held.fence,
        { kind = board.NoteKind.DONE }
    )
    if not noted then
        return string.format(
            "The done note was NOT written on card %s, and the card was not moved. %s Write the note and move the card to %s by hand.",
            short,
            dev_text.sentence(message),
            opts.target
        )
    end
    local moved = opts.move(backend, { other.id, opts.target })
    if moved.code then
        return string.format(
            "Card %s was noted, but the move to %s failed. %s",
            short,
            opts.target,
            dev_text.sentence(moved.message)
        )
    end
    local left = backend:card(other.id)
    if left and left.claimant then
        release_landed(backend, left, held)
    end
end

---Renew the claim, check the card still lands and rebase the change onto trunk.
---@param backend dev.board.Backend the board backend
---@param card dev.board.Card the card that lands
---@param name string the caller's agent name
---@return dev.cmd.board.Result? refused the refusal, nil when the rebase ran
---@return boolean? rebased true when the rebase moved the change
local function land_rebase(backend, card, name)
    local short = card.id:sub(1, board.MIN_PREFIX)
    renew_claim(backend, card, name)
    local current = card_problems(backend, card, { name = name, comments = {} })
    if #current > 0 then
        return failure(
            "Card "
                .. short
                .. " cannot land for these reasons.\n  - "
                .. table.concat(current, "\n  - ")
        )
    end
    local rebased, why, notes = scm.workspace(backend.root):rebase()
    if rebased == nil then
        return failure("Card " .. short .. " cannot land. " .. dev_text.sentence(why))
    end
    note_all(notes)
    return nil, rebased
end

---Rebase the change onto trunk, check what may land and rerun the recheck rows, with no turn taken.
---@param opts dev.board.wiring.land_prepare.Opts the card and the hold the caller already has
---@return dev.cmd.board.Result? result the refusal, nil when the change may go to the turn
---@return dev.board.wiring.Prepared? prepared the commit the turn lands
local function land_prepare(opts)
    local backend, card, name, hold = opts.backend, opts.card, opts.name, opts.hold
    local short = card.id:sub(1, board.MIN_PREFIX)
    local message
    local state_ok, bad = land.state(backend.root)
    if not state_ok then
        return failure("Card " .. short .. " cannot land for these reasons.\n  - " .. bad)
    end
    local uploaded = failed_change_run(backend.root, state_ok.commit, opts.ignore_change_run)
    if uploaded then
        return failure("Card " .. short .. " cannot land for these reasons.\n  - " .. uploaded)
    end
    local refused, rebased = land_rebase(backend, card, name)
    if refused then
        return refused
    end
    local problem = rebased and rebased_change_run(backend.root, opts.ignore_change_run)
    if problem then
        return failure(
            "Card "
                .. short
                .. " cannot land for these reasons.\n  - "
                .. problem
                .. "\nThe change was rebased onto trunk."
        )
    end
    local fresh
    fresh, message = backend:comments(card.id)
    if not fresh then
        return failure(message)
    end
    local rebase_note = rebased and "\nThe change was rebased onto trunk." or ""
    local problems, state, carried, check_only = land_problems(backend, card, {
        name = name,
        comments = fresh,
        untaken = not hold,
        ignore_change_run = opts.ignore_change_run,
        change_run_read = true,
    })
    if #problems > 0 then
        return failure(
            "Card "
                .. short
                .. " cannot land for these reasons.\n  - "
                .. table.concat(problems, "\n  - ")
                .. rebase_note
        )
    end
    local others = {}
    for _, listed in ipairs(opts.companions) do
        local other = backend:card(listed.id)
        local other_short = listed.id:sub(1, board.MIN_PREFIX)
        if not other then
            return failure(
                "Card " .. other_short .. " cannot land with " .. short .. ". It is gone."
            )
        end
        renew_claim(backend, other, name)
        local other_comments, other_message = backend:comments(other.id)
        if not other_comments then
            return failure(other_message)
        end
        local who = {
            name = name,
            comments = other_comments,
            untaken = not hold,
            ignore_change_run = opts.ignore_change_run,
            change_run_read = true,
        }
        local other_problems = card_problems(backend, other, who)
        local other_carried, other_check_only
        if #other_problems == 0 then
            local other_state
            other_problems, other_state, other_carried, other_check_only =
                land_problems(backend, other, who)
            if not other_state and #other_problems == 0 then
                other_problems[1] = "The commit to land could not be read."
            end
        end
        if #other_problems > 0 then
            return failure(
                "Card "
                    .. other_short
                    .. " cannot land with "
                    .. short
                    .. " for these reasons.\n  - "
                    .. table.concat(other_problems, "\n  - ")
                    .. rebase_note
            )
        end
        local full = (carried and not check_only) or (other_carried and not other_check_only)
        carried = carried or other_carried
        check_only = carried ~= nil and not full
        others[#others + 1] = other
    end
    if carried and hold then
        local stretched
        stretched, message = turn.stretch(backend, hold, turn.RECHECK_LEASE_SECONDS)
        if not stretched then
            local lost = failure("Card " .. short .. " cannot land. " .. message)
            lost.lost = true
            return lost
        end
    end
    local trunk_text
    if carried then
        local read_why
        trunk_text, read_why = land.trunk_config(backend.root)
        if not trunk_text then
            return failure("Card " .. short .. " cannot land. " .. dev_text.sentence(read_why))
        end
    end
    local unchecked = carried
        and land.recheck_problem({
            root = backend.root,
            commit = carried,
            card = short,
            rows = config.get_text(backend.root, "board.land.recheck", trunk_text),
            note = verb.note,
        })
    renew_claim(backend, card, name)
    if unchecked then
        if hold then
            turn.renew(backend, hold)
        end
        return failure(
            "Card " .. short .. " cannot land for these reasons.\n  - " .. unchecked .. rebase_note
        )
    end
    return nil,
        {
            state = state,
            carried = carried,
            check_only = check_only,
            companions = others,
            ignore_change_run = opts.ignore_change_run,
        }
end

---@class dev.board.wiring.land_held.Opts
---@field backend dev.board.Backend the board backend
---@field card dev.board.Card the card that lands
---@field name string the caller's agent name
---@field hold dev.board.turn.Turn the landing turn in hand
---@field prepared dev.board.wiring.Prepared the rebased and checked commit to push
---@field move dev.board.wiring.MoveFn moves the card to its column
---@field clean_up fun(root: string, short: string): string removes the bookmark and workspace

---Land the checked commit while the turn is held, or say that trunk moved and nothing was pushed.
---@param opts dev.board.wiring.land_held.Opts the card and the turn in hand
---@return dev.cmd.board.Result result the landing's outcome, with `moved` set when trunk moved
local function land_held(opts)
    local backend, card, name, hold = opts.backend, opts.card, opts.name, opts.hold
    local short = card.id:sub(1, board.MIN_PREFIX)
    local message
    local stopped, rebased = land_rebase(backend, card, name)
    if stopped then
        return stopped
    end
    local state, carried = opts.prepared.state, opts.prepared.carried
    local check_only = opts.prepared.check_only
    local now, bad = land.state(backend.root)
    if not now then
        return failure("Card " .. short .. " cannot land for these reasons.\n  - " .. bad)
    end
    if rebased or now.commit ~= state.commit then
        return { moved = true }
    end
    local companions = {}
    for _, listed in ipairs(opts.prepared.companions) do
        local other = backend:card(listed.id)
        local other_short = listed.id:sub(1, board.MIN_PREFIX)
        if not other then
            return failure(
                "Card " .. other_short .. " cannot land with " .. short .. ". It is gone."
            )
        end
        renew_claim(backend, other, name)
        local other_problems = card_problems(backend, other, { name = name, comments = {} })
        if #other_problems > 0 then
            return failure(
                "Card "
                    .. other_short
                    .. " cannot land with "
                    .. short
                    .. " for these reasons.\n  - "
                    .. table.concat(other_problems, "\n  - ")
            )
        end
        companions[#companions + 1] = other
    end
    local renewed
    renewed, message = turn.renew(backend, hold)
    if not renewed then
        local lost = failure("Card " .. short .. " cannot land. " .. message)
        lost.lost = true
        return lost
    end
    local in_git = vcs.backend(backend.root) == vcs.GIT
    local landed, output = scm.workspace(backend.root):merge_into_trunk()
    if not landed then
        local text = output:gsub("\n$", "")
        local touched = land.touched(backend.root, state.commit)
        local drift = touched and land.template_drift(text, touched)
        return failure(
            "Card "
                .. short
                .. " stays in "
                .. card.column
                .. ". `"
                .. (in_git and "git push" or "jj land")
                .. "` failed with this output.\n"
                .. text
                .. (drift and ("\n" .. drift) or "")
        )
    end
    local on_trunk = land.trunk_commit(backend.root, state.change)
    local commit = land.short(on_trunk or state.commit)
    local held = claims.read(card.id)
    local text
    if in_git then
        text = string.format("Landed commit %s on trunk, run by %s.", commit, name)
        if not on_trunk then
            text = string.format(
                "Landed commit %s, run by %s. Trunk could not be read after the push. "
                    .. "The commit may not be on it.",
                commit,
                name
            )
        end
    elseif on_trunk then
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
    if carried and check_only then
        text = string.format(
            "%s The check was carried over from commit %s: the change id is the same and its patch is unchanged.",
            text,
            land.short(carried)
        )
    elseif carried then
        text = string.format(
            "%s The check and reviews were carried over from commit %s: the change id is the same, the interdiff is empty, and the rebase left no conflict.",
            text,
            land.short(carried)
        )
    end
    text = land.ignored_run_note(text, opts.prepared.ignore_change_run)
    local deploys = config.get(backend.root, "board.land.deploys") == true
    local deployed = config.get(backend.root, "board.land.deployed")
    if deploys and type(deployed) == "table" and #deployed > 0 then
        deploys = land.deploys(land.touched(backend.root, state.commit), deployed)
    end
    local target = deploys and backend.stages.release or backend.stages:done_column()
    if deploys then
        text = text .. " It waits in " .. target .. " for the deploy."
    end
    local noted
    noted, message =
        backend:note(card.id, text, held and held.fence, { kind = board.NoteKind.DONE })
    local first_problem
    if not noted then
        first_problem = string.format(
            "Landed commit %s. The done note was NOT written on card %s, and the card was not moved. %s Rerun `dev board land %s` from this workspace to write the note and move the card to %s.",
            commit,
            short,
            dev_text.sentence(message),
            short,
            target
        )
    else
        local moved = opts.move(backend, { card.id, target })
        if moved.code then
            first_problem = string.format(
                "Landed commit %s and noted it on card %s. The move to %s failed. %s",
                commit,
                short,
                target,
                dev_text.sentence(moved.message)
            )
        end
    end
    local left = not first_problem and backend:card(card.id)
    if left and left.claimant then
        release_landed(backend, left, held)
    end
    local together = ""
    local unfinished = {}
    for _, other in ipairs(companions) do
        local refused = finish_companion({
            backend = backend,
            move = opts.move,
            other = other,
            first = card,
            text = text,
            target = target,
        })
        if refused then
            unfinished[#unfinished + 1] = refused
        else
            together = together .. " and " .. other.id:sub(1, board.MIN_PREFIX)
        end
    end
    if first_problem or #unfinished > 0 then
        local lines = { first_problem or ("Landed commit " .. commit .. ".") }
        for _, line in ipairs(unfinished) do
            lines[#lines + 1] = line
        end
        local tail = first_problem and "" or opts.clean_up(backend.root, short)
        local refused = failure(table.concat(lines, " ") .. tail)
        refused.landed = true
        return refused
    end
    return {
        output = string.format(
            "landed %s%s at commit %s%s and moved %s to %s",
            short,
            together,
            commit,
            on_trunk and ""
                or " (the commit from before the land, which may differ: trunk could not be read)",
            together == "" and "it" or "them",
            target
        ) .. opts.clean_up(backend.root, short),
    }
end

---@class dev.board.wiring.settle.Opts
---@field backend dev.board.Backend the board backend
---@field card dev.board.Card the card in Verify
---@field comments {body: string}[] the card's comments, oldest first
---@field name string the caller's agent name
---@field empty string? why the working copy holds nothing to land
---@field move dev.board.wiring.MoveFn moves the card to its column
---@field clean_up fun(root: string, short: string): string removes its bookmark and workspace

---Finish the board half of a landing whose change already reached trunk.
---
---It runs when the working copy holds nothing to land, as after a land whose done note or move
---failed. The reviews, the check and the checks rows must back the newest checked commit, and
---trunk must hold that change. No land runs.
---@param opts dev.board.wiring.settle.Opts the card and its comments
---@return dev.cmd.board.Result? result nil when no checked change of the card is on trunk
local function settle(opts)
    local backend, card = opts.backend, opts.card
    local short = card.id:sub(1, board.MIN_PREFIX)
    local record
    for _, comment in ipairs(opts.comments) do
        local parsed = check.parse(comment.body)
        if parsed and parsed.mode == check.Mode.RUN then
            record = parsed
        end
    end
    if not record and opts.empty then
        return failure(
            "Card "
                .. short
                .. " cannot land. "
                .. dev_text.sentence(opts.empty)
                .. " No run of `dev board check` is recorded on the card, so a change already on trunk cannot be matched to it."
        )
    end
    local on_trunk = record and land.settled_commit(backend.root, record)
    if not on_trunk then
        if record and opts.empty then
            return failure(
                "Card "
                    .. short
                    .. " cannot land. "
                    .. dev_text.sentence(opts.empty)
                    .. " Trunk does not hold the change checked at commit "
                    .. land.short(record.commit)
                    .. "."
            )
        end
        return nil
    end
    local state = { commit = record.commit, change = record.change }
    local problems = land.missing_reviews(opts.comments, state)
    for _, line in ipairs(land.refused_reviews(opts.comments, state)) do
        problems[#problems + 1] = line
    end
    local unproven = land.checks_problem(opts.comments, state, card.checks)
    if unproven then
        problems[#problems + 1] = unproven
    end
    if #problems > 0 then
        return failure(
            "Card "
                .. short
                .. " landed on trunk at commit "
                .. land.short(on_trunk)
                .. ", but its board half cannot finish for these reasons.\n  - "
                .. table.concat(problems, "\n  - ")
        )
    end
    local commit = land.short(on_trunk)
    local text = string.format("Landed commit %s on trunk, run by %s.", commit, opts.name)
    if record.change ~= "-" then
        text = string.format(
            "Landed commit %s (change %s) on trunk, run by %s.",
            commit,
            record.change,
            opts.name
        )
    end
    text = text .. " A rerun of land finished the card after the first land's board call failed."
    local deploys = config.get(backend.root, "board.land.deploys") == true
    local deployed = config.get(backend.root, "board.land.deployed")
    if deploys and type(deployed) == "table" and #deployed > 0 then
        deploys = land.deploys(land.touched(backend.root, on_trunk), deployed)
    end
    local target = deploys and backend.stages.release or backend.stages:done_column()
    if deploys then
        text = text .. " It waits in " .. target .. " for the deploy."
    end
    local held = claims.read(card.id)
    local noted, message =
        backend:note(card.id, text, held and held.fence, { kind = board.NoteKind.DONE })
    if not noted then
        return failure(
            string.format(
                "Landed commit %s. The done note was NOT written on card %s, and the card was not moved. %s Rerun `dev board land %s` from this workspace to write the note and move the card to %s.",
                commit,
                short,
                dev_text.sentence(message),
                short,
                target
            )
        )
    end
    local moved = opts.move(backend, { card.id, target })
    if moved.code then
        return failure(
            string.format(
                "Landed commit %s and noted it on card %s. The move to %s failed. %s",
                commit,
                short,
                target,
                dev_text.sentence(moved.message)
            )
        )
    end
    local left = backend:card(card.id)
    if left and left.claimant then
        release_landed(backend, left, held)
    end
    return {
        output = string.format("settled %s at commit %s and moved it to %s", short, commit, target)
            .. opts.clean_up(backend.root, short),
    }
end

---Tell the caller its landing turn is still held after a refusal.
---@param short string the card's short id
---@return string note the text to append to the refusal
local function kept_note(short)
    return "\nThe landing turn you hold for "
        .. short
        .. " stays held while its lease lasts. Fix this and land again, or give it back with `dev board turn "
        .. short
        .. " --release`."
end

M.check_options = check_options
M.check_lines = check_lines
M.check_rows = check_rows
M.renew_claim = renew_claim
M.card_problems = card_problems
M.land_problems = land_problems
M.credential_problems = credential_problems
M.await_turn = await_turn
M.land_prepare = land_prepare
M.land_held = land_held
M.settle = settle
M.kept_note = kept_note
M.release_landed = release_landed

return M
