local board = require("dev.board")
local check = require("dev.board.check")
local config = require("dev.config")
local follow = require("dev.cmd.follow")
local guards = require("dev.board.guards")
local land = require("dev.board.land")
local revert = require("dev.board.revert")
local dev_command = require("dev.command")
local wiring = require("dev.board.wiring")

local usage = guards.usage
local failure = guards.failure

---The ship command, which moves every Release card a tested revision holds to Done.
---@class dev.board.ship
local M = {}

---@class dev.board.ship.Run
---@field argv string[] the command's words
---@field run string the command as one line

---@alias dev.board.ship.Handler fun(backend: dev.board.Backend, args: string[]): dev.cmd.board.Result

---@class dev.board.ship.Deps
---@field move_card dev.board.ship.Handler moves a card
---@field outcome dev.board.ship.Handler edits outcomes
---@field count_text fun(count: integer, noun: string): string counts a noun

---Read the commands a ship runs: the words after `--`, else the `[board.release]` checks rows.
---@param backend dev.board.Backend the board
---@param command string[] the words after `--`, empty when none were given
---@return dev.board.ship.Run[]? runs the commands, nil on a refusal
---@return dev.cmd.board.Result? err the refusal
local function ship_runs(backend, command)
    if #command > 0 then
        return { { argv = command, run = table.concat(command, " ") } }
    end
    local rows = config.get(backend.root, "board.release.checks")
    if rows == nil then
        return nil, usage("Needs a release command after --, or checks rows under [board.release].")
    end
    if type(rows) ~= "table" or #rows == 0 then
        return nil, failure("The `[board.release]` checks must be a list of commands.")
    end
    local runs = {}
    for i, row in ipairs(rows) do
        if type(row) ~= "string" then
            return nil, failure("Row " .. i .. " of the `[board.release]` checks is not a string.")
        end
        local argv, why = check.argv(row)
        if not argv then
            return nil,
                failure("Row " .. i .. " of the `[board.release]` checks cannot run. " .. why)
        end
        runs[i] = { argv = argv, run = row }
    end
    return runs
end

---Run each command once and stop at the first that fails.
---@param backend dev.board.Backend the board
---@param runs dev.board.ship.Run[] the commands
---@param name_suspects fun(row: dev.board.check.Row): string[] the lines naming the cards behind a
---failed row
---@return dev.cmd.board.Result? err the failure naming the command, nil when every one passed
local function ship_ran(backend, runs, name_suspects)
    local remote = require("dev.remote")
    local rows = {}
    for i, one in ipairs(runs) do
        dev_command.note(string.format("Running row %d of %d with `%s`.", i, #runs, one.run))
        rows[i] = check.run({
            root = backend.root,
            run = one.run,
            argv = one.argv,
            seconds = check.row_seconds(backend.root),
            env = { [remote.COMMAND_ENV] = remote.Command.RELEASE, [remote.PRIORITY_ENV] = "1" },
        })
        if rows[i].result ~= check.Result.PASS then
            local lines = wiring.check_lines(rows)
            for _, line in ipairs(name_suspects(rows[i])) do
                lines[#lines + 1] = line
            end
            return failure(
                string.format(
                    "The release command `%s` failed. No card moved.\n%s",
                    one.run,
                    table.concat(lines, "\n")
                )
            )
        end
    end
end

local Ship = { DEFAULT_REV = land.TRUNK_REVSET }

---Say why a Release card cannot ship at a revision.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the Release card
---@param commit string the commit the ship covers
---@param name string what to call that revision
---@return string? reason why it stays, nil when it may move
---@return string? landed the card's landed commit when it may move
---@return boolean? reverted true when the card's revert is in the revision, so it goes back to Ready
function Ship.reason(backend, card, commit, name)
    if guards.done_refusal(card, backend.stages:done_column()) then
        return "An outcome is not ticked."
    end
    local comments = backend:comments(card.id)
    local landed = comments and land.landed_commit(comments)
    if not landed then
        return "The card has no landed commit in its notes."
    end
    if not land.holds(backend.root, landed, commit) then
        return "Its landed commit " .. land.short(landed) .. " is not in " .. name .. "."
    end
    local pending = revert.reverted(comments)
    if pending then
        if land.reverts(backend.root, pending, commit) then
            return nil, landed, true
        end
        return "Its revert of " .. pending .. " has not landed in " .. name .. ".", landed
    end
    return nil, landed
end

---Untick a reverted card's outcomes and send it back to Ready, once its revert is on trunk.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the Release card
---@param deps dev.board.ship.Deps the board commands the move calls
---@return string? refusal why the card stays in Release, nil when it moved
function Ship.reopen(backend, card, deps)
    for number, outcome in ipairs(card.outcomes) do
        if outcome.done then
            local untick = deps.outcome(backend, { card.id, "--untick", tostring(number) })
            if untick.code then
                return string.format("outcome %d stays ticked. %s", number, untick.message)
            end
        end
    end
    backend:note(
        card.id,
        "The revert of this card landed on trunk. Plan the change again, then take it.",
        nil,
        { kind = board.NoteKind.DECISION }
    )
    local moved = deps.move_card(backend, { card.id, backend.stages.ready })
    if moved.code then
        return "The move to " .. backend.stages.ready .. " was refused. " .. moved.message
    end
end

---Name the dev sync templates the landed commits of a batch changed.
---@param root string the project root
---@param landed string[] the landed commits of the shipped cards
---@return string[] lines the heading and one line per changed template, empty when none changed
local function ship_templates(root, landed)
    local set = {}
    for _, commit in ipairs(landed) do
        for _, path in ipairs(land.touched(root, commit) or {}) do
            set[path] = true
        end
    end
    local paths = {}
    for path in pairs(set) do
        paths[#paths + 1] = path
    end
    local prefixes = land.sync_templates(root)
    if not prefixes then
        return {}
    end
    local synced = {}
    for _, path in ipairs(paths) do
        if land.is_synced_template(prefixes, path) then
            synced[#synced + 1] = path
        end
    end
    table.sort(synced)
    if #synced == 0 then
        return {}
    end
    local lines = { "The dev sync templates changed. Synced repos run dev sync:" }
    for _, path in ipairs(synced) do
        lines[#lines + 1] = "  " .. path
    end
    return lines
end

---Move every Release card the shipped revision holds to Done, each with a done note.
---@param backend dev.board.Backend the board
---@param cards dev.board.Card[] the Release cards
---@param rev string the revset the ship covers
---@param commit string the full commit the revset names
---@param deps dev.board.ship.Deps the board commands the batch calls
---@return string[] lines what moved and what stayed
---@return boolean ok false when a note or a move failed
local function ship_batch(backend, cards, rev, commit, deps)
    local name = rev == Ship.DEFAULT_REV and "trunk" or rev
    local text = string.format("Shipped in %s, commit %s.", name, land.short(commit))
    local moved, kept, stranded, reopened, ok = {}, {}, {}, {}, true
    local landed_commits = {}
    for _, card in ipairs(cards) do
        local short = card.id:sub(1, board.MIN_PREFIX)
        local reason, landed, reverted = Ship.reason(backend, card, commit, name)
        if landed then
            landed_commits[#landed_commits + 1] = landed
        end
        if reason then
            kept[#kept + 1] = "  " .. short .. " " .. card.name .. ": " .. reason
        elseif reverted then
            local refusal = Ship.reopen(backend, card, deps)
            if refusal then
                ok = false
                kept[#kept + 1] = "  " .. short .. " " .. card.name .. ": " .. refusal
            else
                reopened[#reopened + 1] = "  " .. short .. " " .. card.name
            end
        else
            local result = deps.move_card(backend, { card.id, backend.stages:done_column() })
            local moved_ok = result ~= nil and not result.code
            local noted, why = moved_ok, nil
            if moved_ok then
                noted, why = backend:note(card.id, text, nil, { kind = board.NoteKind.DONE })
            end
            if moved_ok and noted then
                moved[#moved + 1] = "  " .. short .. " " .. card.name
            elseif moved_ok then
                ok = false
                stranded[#stranded + 1] = "  "
                    .. short
                    .. " "
                    .. card.name
                    .. ": "
                    .. (why or "The note was not written.")
            else
                ok = false
                kept[#kept + 1] = "  "
                    .. short
                    .. " "
                    .. card.name
                    .. ": "
                    .. (result and result.message or why)
            end
        end
    end
    local lines = {
        string.format(
            "shipped %s at %s commit %s",
            deps.count_text(#moved, "card"),
            name,
            land.short(commit)
        ),
    }
    for _, line in ipairs(moved) do
        lines[#lines + 1] = line
    end
    if #reopened > 0 then
        lines[#lines + 1] = "These cards were reverted and are back in "
            .. backend.stages.ready
            .. ":"
        for _, line in ipairs(reopened) do
            lines[#lines + 1] = line
        end
    end
    if #kept > 0 then
        lines[#lines + 1] = "These cards stay in " .. backend.stages.release .. ":"
        for _, line in ipairs(kept) do
            lines[#lines + 1] = line
        end
    end
    if #stranded > 0 then
        lines[#lines + 1] = "These cards moved to "
            .. backend.stages:done_column()
            .. " with no done note. Write each note by hand:"
        for _, line in ipairs(stranded) do
            lines[#lines + 1] = line
        end
    end
    for _, line in ipairs(ship_templates(backend.root, landed_commits)) do
        lines[#lines + 1] = line
    end
    return lines, ok
end

---Revert a suspect's landed commit and note it, leaving the card in Release until the revert lands.
---@param backend dev.board.Backend the board
---@param entry dev.board.suspects.Entry the suspect
---@param seconds integer how long it has been red
---@return string said what happened, as sentences
function Ship.requeue(backend, entry, seconds)
    local short = land.short(entry.landed)
    local ok, reason, detail = revert.apply(backend.root, entry.landed)
    if not ok then
        if reason == revert.Reason.CONFLICT then
            return "The revert of " .. short .. " conflicts with later changes, so it is left."
        end
        return "The revert of " .. short .. " failed. " .. tostring(detail)
    end
    backend:note(
        entry.card.id,
        string.format(
            "Reverted landed commit %s after the batch stayed red for %d seconds. "
                .. "Land the revert, then ship again.",
            short,
            seconds
        ),
        nil,
        { kind = board.NoteKind.DECISION }
    )
    return "Reverted "
        .. short
        .. ". The card stays in "
        .. backend.stages.release
        .. " until it lands."
end

---Note each red suspect, and revert the landed commit of one that stayed red past `revert_after`.
---@param backend dev.board.Backend the board
---@param named dev.board.suspects.Entry[] the suspect cards the failed ship named
---@param commit string the full commit the ship tested
---@param cases string[] the failing cases of the ship
---@return string[] lines what happened to each suspect
function Ship.settle(backend, named, commit, cases)
    local after = tonumber((config.get(backend.root, "board.release.revert_after")))
        or revert.AFTER_SECONDS
    local now = os.time()
    local lines = {}
    for _, entry in ipairs(revert.newest_first(backend.root, named)) do
        local since = revert.red_since(backend:comments(entry.card.id) or {}, cases)
        local said
        if not since then
            local ok, why = backend:note(
                entry.card.id,
                revert.red_text(land.short(commit), now, cases),
                nil,
                { kind = board.NoteKind.STATUS }
            )
            said = ok and "First red, so the card is noted."
                or ("First red, but the note failed. " .. tostring(why))
        elseif now - since < after then
            said = string.format("Red for %d seconds. Reverted after %d.", now - since, after)
        else
            said = Ship.requeue(backend, entry, now - since)
        end
        lines[#lines + 1] = "  " .. entry.label .. ": " .. said
    end
    return lines
end

---Name the cards of a batch that touched the files a failed release command left failing.
---@param backend dev.board.Backend the board
---@param opts { files: string[], cases: string[], rev: string, commit: string } the failing test
---files and cases the command printed, the revset the ship covers and the full commit it names
---@return string[] lines the suspect list
function Ship.suspects(backend, opts)
    local files, commit = opts.files, opts.commit
    local name = opts.rev == Ship.DEFAULT_REV and "trunk" or opts.rev
    local cards = backend:cards() or {}
    local entries = {}
    for _, card in ipairs(cards) do
        if card.column == backend.stages.release then
            local reason, landed, reverted = Ship.reason(backend, card, commit, name)
            if not reason and landed and not reverted then
                entries[#entries + 1] = {
                    label = card.id:sub(1, board.MIN_PREFIX) .. " " .. card.name,
                    landed = landed,
                    card = card,
                }
            end
        end
    end
    local lines, named = require("dev.board.suspects").lines(backend.root, files, entries)
    for _, line in ipairs(Ship.settle(backend, named, commit, opts.cases or {})) do
        lines[#lines + 1] = line
    end
    return lines
end

---@class dev.board.ship.Opts
---@field rev string? the revision to ship, trunk when nil
---@field command string[] the release command after `--`, empty for the `[board.release]` rows

---Ship the Release cards a tested revision holds.
---@param backend dev.board.Backend the board
---@param opts dev.board.ship.Opts the revision and the release command
---@param deps dev.board.ship.Deps the board commands the ship calls
---@return dev.cmd.board.Result result the ship's outcome
function M.ship(backend, opts, deps)
    local rev = opts.rev or Ship.DEFAULT_REV
    local runs, err = ship_runs(backend, opts.command)
    if not runs then
        return err
    end
    if not backend.root then
        return failure("`dev board ship` needs the project's root.")
    end
    local commit = land.fetched_commit(backend.root, rev)
    if not commit then
        return failure("Revision " .. rev .. " does not name one commit. No card moved.")
    end
    if not land.same_tree(backend.root, commit) then
        return failure(
            string.format(
                "The working copy is not at %s, so a release command would test another tree. "
                    .. "Run `dev board ship` from a workspace at that revision. No card moved.",
                land.short(commit)
            )
        )
    end
    local failed = ship_ran(backend, runs, function(row)
        local failing = { files = row.failed or {}, cases = row.cases, rev = rev, commit = commit }
        return Ship.suspects(backend, failing)
    end)
    if failed then
        return failed
    end
    local cards, message = backend:cards()
    if not cards then
        return failure(message)
    end
    local waiting = {}
    for _, card in ipairs(cards) do
        if card.column == backend.stages.release then
            waiting[#waiting + 1] = card
        end
    end
    local lines, ok = ship_batch(backend, waiting, rev, commit, deps)
    local main = follow.main(backend.root)
    if main then
        lines[#lines + 1] = follow.launch(main, commit)
    end
    local text = table.concat(lines, "\n")
    if not ok then
        return failure(text)
    end
    return { output = text }
end

return M
