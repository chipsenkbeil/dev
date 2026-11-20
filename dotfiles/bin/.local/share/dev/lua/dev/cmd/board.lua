local board = require("dev.board")
local board_setup = require("dev.board.setup")
local check = require("dev.board.check")
local claims = require("dev.board.claims")
local role_clock = require("dev.board.clock")
local config = require("dev.config")
local device = require("dev.board.device")
local dev_os = require("dev.os")
local follow = require("dev.cmd.follow")
local fs = require("dev.fs")
local guards = require("dev.board.guards")
local init = require("dev.board.init")
local json = require("dev.json")
local land = require("dev.board.land")
local lint = require("dev.board.lint")
local localboard = require("dev.board.localboard")
local pomb = require("dev.board.pomb")
local queue = require("dev.board.queue")
local render = require("dev.board.render")
local review = require("dev.board.review")
local runcard = require("dev.board.runcard")
local runner = require("dev.board.runner")
local ship = require("dev.board.ship")
local stale = require("dev.board.stale")
local store = require("dev.board.store")
local tokenfile = require("dev.board.tokenfile")
local dev_text = require("dev.text")
local text_width = dev_text.width
local turn = require("dev.board.turn")
local ui = require("dev.ui")
local vcs = require("dev.vcs")
local verb = require("dev.verb")
local board_wait = require("dev.board.wait")
local wiring = require("dev.board.wiring")

local NO_BOARD = "This project has no board."
local FULL_ID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
local UNKNOWN_COLUMN = "?"
local USAGE = guards.USAGE
local FAILURE = guards.FAILURE
local usage = guards.usage
local failure = guards.failure

local function sentence(text)
    text = text:gsub("^%l", string.upper)
    if not text:find("%.$") then
        text = text .. "."
    end
    return text
end

local function clock_note(opening, reason, detail)
    local text = opening .. " " .. sentence(detail)
    if reason == role_clock.Reason.DROPPED then
        text = text .. " The clock was dropped."
    end
    return text
end

local function queue_unreadable(path, reason, message)
    if reason == queue.Reason.READ then
        return "Cannot read the queue at " .. path .. ". " .. sentence(message)
    end
    return sentence(message)
end

---The sentence for each reason `pomb.new` refuses with
local POMB_REFUSALS = {
    [pomb.Reason.BAD_URL] = "The `url` setting of `[board.pomb]` must be an http or "
        .. "https address in ~/.config/dev/config.toml.",
}

---Write the refusal of a verb that only a lead runs.
---@param action string? what the lead does, nil for deleting a card
---@return string message the sentence
local function not_lead_message(action)
    return "Only the lead "
        .. (action or "deletes a card")
        .. ". DEV_AGENT "
        .. (os.getenv("DEV_AGENT") or "")
        .. " is not a lead name, whose role segment is lead, and a name with no slash counts"
        .. " as the lead only at a terminal. Ask the lead"
        .. (action and "" or ", with the card and the reason")
        .. "."
end

local unqueued = guards.unqueued
local agent_name = guards.agent_name
local index_of = require("dev.text").index_of
local owner_holds = runner.owner_holds
local claimant = runner.claimant
local claim_card = runner.claim_card
local OWNER_MARK = " (owner)"
local DONE_MARK = " (done)"
local CLEARS_BLOCKERS_MARK = " (clears blockers)"
local BLOCKED_MARK = " (blocked)"
local ADMIN_SCOPE = "admin"
local CLIENT_CHARS = 80
local STAMP_CHARS = 16
local COMMIT_CHARS = 12
local SEAT_HELD_CODE = "seat_held"
local WAIT_FLAG = "--wait"
local IGNORE_CHANGE_RUN_FLAG = "--ignore-change-run"
local SET_FLAG = "--set"
local CLEARS_BLOCKERS_FLAG = "--clears-blockers"
local BLOCKED_FLAG = "--blocked"
local ID_ONLY_FLAG = "--id-only"
local SWITCH = guards.SWITCH
local MAX_WAIT_SECONDS = 86400
local MAX_LAND_ATTEMPTS = 5
local STRICT_FLAG = "--strict"
local OPEN_FLAG = "--open"
local RESERVED_NOTE = "A note cannot begin with "
    .. board.CHECK_PREFIX
    .. ", which `dev board check` writes, "
    .. board.REVIEW_PREFIX
    .. ", which `dev board review` writes, "
    .. board.CLAIM_PREFIX
    .. ", which taking a card writes, or "
    .. board.TICK_PREFIX
    .. ", which ticking an outcome writes."
local LINK_HELP = table.concat(board.LINK_KINDS, ", ")
local EDIT_FLAG = "--edit"
local DELETE_FLAG = "--delete"
local NO_BIN = "This board keeps no recycle bin. Dev cannot delete a card from it."
local NO_RESTORE = "This board keeps no recycle bin. Dev cannot restore a card to it."
local KIND_FLAG = "--kind"
local BY_FLAG = "--by"
local REV_FLAG = "--rev"
local GROUP_FLAG = "--group"
local AS_FLAG = guards.AS_FLAG
local REASON_FLAG = "--reason"
local HUMAN_ACTOR = "human"
local LOCAL_NAME_PATTERN = "^[%w][%w._-]*$"
local PATH_PATTERN = "^[%w._][%w._/-]*$"
local QUEUED_NOTICE = "queued: Pomb unreachable, will sync"
---Replay idempotency for each queued subcommand
local QUEUE_RULES = {
    add = { idempotent = false },
    move = { idempotent = true },
    discard_move = { idempotent = true },
    order = { idempotent = true },
    note = { idempotent = false },
    size = { idempotent = true },
    label = { idempotent = true },
    link = { idempotent = true },
    epic = { idempotent = false },
    responsible = { idempotent = true },
    due = { idempotent = true },
    edit = { idempotent = true },
    rename = { idempotent = true },
    checks = { idempotent = true },
    allow = { idempotent = true },
    tests = { idempotent = true },
    files = { idempotent = true },
    outcome = { idempotent = false },
}
local OutcomeMode =
    { ADD = "add", RENAME = "rename", TICK = "tick", UNTICK = "untick", DELETE = "delete" }
---Outcome flags mapped to their modes
local OUTCOME_FLAGS = {
    ["--rename"] = OutcomeMode.RENAME,
    ["--tick"] = OutcomeMode.TICK,
    ["--untick"] = OutcomeMode.UNTICK,
    [DELETE_FLAG] = OutcomeMode.DELETE,
}
local CONVERT_FLAG = "--convert"

---Find the word that names an outcome form, which may follow a leading `--as NAME`.
---@param args string[] the card and the form's words
---@return string? word the form's flag, nil when the card has no second word
local function outcome_word(args)
    if args[2] == AS_FLAG then
        return args[4]
    end
    return args[2]
end

local function idempotent(sub, args)
    local rule = QUEUE_RULES[sub]
    local flag = OUTCOME_FLAGS[outcome_word(args)]
    return (rule ~= nil and rule.idempotent)
        or (sub == "outcome" and flag ~= nil and flag ~= OutcomeMode.DELETE and flag ~= OutcomeMode.RENAME)
        or false
end

---@class dev.cmd.board.Settings
---@field backend string `pomb` or `local`
---@field name string the board's name
---@field path string? the file of a local board, in the state directory when nil
---@field root string? the project's root, which a tracked path is under
---@field columns table<string, string>? the `[board.columns]` map, keyed by stage

---@class dev.cmd.board.open.Opts
---@field token_key string? the `[board.pomb]` key that names the token, `token` when nil

---@class dev.cmd.board.Result
---@field output string? what to print on success
---@field message string? what went wrong
---@field code integer? 2 for a usage error, 1 for a failure or a lint finding, nil on success
---@field warnings string[]? lines for standard error when the change still went through
---@field page boolean? whether the output goes through the pager when it is taller than the screen
---@field unqueued boolean? true when the refusal must not be queued for a later sync, as a move to
---   Done is not
---@field lost boolean? true when the landing turn was lost before the landing
---@field moved boolean? true when trunk moved under the turn and nothing was pushed
---@field landed boolean? true when the change is on trunk although the result is a failure
---@field unresolved boolean? true when a card word named no one card, as opposed to a board that
---   failed to answer

---@class dev.cmd.board
---@field handlers table<string, fun(ctx: dev.Ctx): integer> the handlers of the `board` subcommands
---@field open fun(settings: dev.cmd.board.Settings): dev.board.Backend?, string? builds the backend
---   a board uses
local M = { handlers = {} }

local parse = guards.parse

local function named_column(backend, word)
    local column = backend.stages:column(word)
    if not column then
        return nil,
            usage("Unknown column " .. word .. ". The columns are " .. backend.stages:help() .. ".")
    end
    return column
end

local function named_lane(backend, word)
    local lanes, message = backend:lanes()
    if not lanes then
        return nil, failure(message)
    end
    for _, lane in ipairs(lanes) do
        if lane:lower() == word:lower() then
            return lane
        end
    end
    if #lanes == 0 then
        return nil, usage("The board has no lanes, so --lane " .. word .. " names none.")
    end
    return nil,
        usage("Unknown lane " .. word .. ". The lanes are " .. table.concat(lanes, ", ") .. ".")
end

local function sized(word)
    local color = board.size_color(word)
    if not color then
        return nil, usage("Unknown size " .. word .. ". The sizes are " .. board.size_help() .. ".")
    end
    return color
end

local function unready(color)
    return color == nil or color == board.SIZES.unsized or color == board.SIZES["3+"]
end

---Refusal messages for reserved card fields, by key
local FIELD_REFUSALS = {
    [board.CHECKS_FIELD] = "The board has no checks field. Run `dev board init` to add it.",
}

---Say why a card cannot take a custom field: the board does not define it.
---@param backend dev.board.Backend the board
---@param key string the field's key
---@return string? message the reason, nil when the board has the field
---@return dev.cmd.board.Result? err the failure when the board could not be asked
local function named_field_problem(backend, key)
    local has, message = backend:has_field(key)
    if has == nil then
        return nil, failure(message)
    end
    if not has then
        return FIELD_REFUSALS[key]
            or "The board has no " .. key .. " field. Define it on the board first."
    end
end

local function plain(label)
    if label == "" or label:find("%s") or label:find("%c") or label:sub(1, 1) == "-" then
        return nil, usage("Label " .. label .. " must be one word that does not start with -.")
    end
    return label
end

local function card_line(card)
    return board.table_lines({ board.cells(card, { lanes = card.lane ~= nil }) })[1]
end

---Build the link line for `card`.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@return string lines the card's link line behind a newline, empty when the board has no host
local function link_suffix(backend, card)
    if not backend.card_url then
        return ""
    end
    return "\nlink: " .. backend:card_url(card.id)
end

local function find_card(backend, word)
    if word:find(FULL_ID) then
        local card = backend:card(word:lower())
        if card and card.column ~= UNKNOWN_COLUMN then
            return card
        end
    end
    local cards, message = backend:cards({ summary = true })
    if not cards then
        return nil, failure(message)
    end
    local found, why = board.resolve(cards, word)
    if not found then
        local unresolved = failure(why)
        unresolved.unresolved = true
        return nil, unresolved
    end
    local card
    card, message = backend:card(found.id)
    if not card then
        return nil, failure(message)
    end
    return card
end

local function other_card(backend, word)
    local other_name, prefix = word:match("^(.+):([^:]*)$")
    local home = backend
    if other_name then
        local why
        home, why = backend:other_board(other_name)
        if not home then
            return nil, nil, failure(why)
        end
        word = prefix
    end
    local other, err = find_card(home, word)
    if not other then
        if not other_name and err.message:find("^No card starts with") then
            err = failure(err.message .. " For a card on another board, give BOARD:PREFIX.")
        end
        return nil, nil, err
    end
    return other, (other_name and other_name .. ":" or "") .. other.id:sub(1, board.MIN_PREFIX)
end

local commands = {}

function commands.ls(backend, args, _, screen)
    local grouped, rest = false, {}
    for _, arg in ipairs(args) do
        if arg == GROUP_FLAG then
            grouped = true
        else
            rest[#rest + 1] = arg
        end
    end
    local flags, extra = parse(rest, {
        ["--column"] = true,
        ["--label"] = true,
        ["--size"] = true,
        ["--lane"] = true,
    })
    if not flags then
        return extra
    end
    if #extra > 0 then
        return usage("Unknown argument " .. extra[1] .. ".")
    end
    local lane
    if flags["--lane"] then
        local named, err = named_lane(backend, flags["--lane"])
        if not named then
            return err
        end
        lane = named
    end
    local color
    if flags["--size"] then
        local named, err = sized(flags["--size"])
        if not named then
            return err
        end
        color = named
    end
    local want
    if flags["--column"] then
        local column, err = named_column(backend, flags["--column"])
        if not column then
            return err
        end
        want = column
    end
    local cards, message = backend:cards({ skip_archived = lane == nil })
    if not cards then
        return failure(message)
    end
    local shown_cards = {}
    local holders, progress, lanes = false, false, false
    for _, card in ipairs(cards) do
        local shown = card.column == want or (not want and not card.done)
        if shown and flags["--label"] then
            shown = false
            for _, label in ipairs(card.labels) do
                shown = shown or label == flags["--label"]
            end
        end
        if shown and color then
            shown = board.has_color(card, color)
        end
        if shown and lane then
            shown = card.lane == lane
        end
        if shown then
            shown_cards[#shown_cards + 1] = card
            holders = holders or card.claimant ~= nil
            progress = progress or #card.outcomes > 0
            lanes = lanes or card.lane ~= nil
        end
    end
    if #shown_cards == 0 then
        return { output = "No cards." }
    end
    if screen and screen.color then
        local lines = render.ls(screen, shown_cards, {
            holders = holders,
            lanes = lanes,
            grouped = grouped,
            want = want,
            stages = backend.stages,
        })
        return { output = table.concat(lines, "\n"), page = true }
    end
    local rows = {}
    for _, card in ipairs(shown_cards) do
        rows[#rows + 1] =
            board.cells(card, { holders = holders, progress = progress, lanes = lanes })
    end
    return { output = table.concat(board.table_lines(rows), "\n") }
end

function commands.next(backend, args)
    local flags, words = parse(args, {
        ["--column"] = true,
        ["--for"] = true,
        ["--lane"] = true,
        [runner.FLAG] = true,
    })
    if not flags then
        return words
    end
    if #words > 0 then
        return usage("Unknown argument " .. words[1] .. ".")
    end
    local lane
    if flags["--lane"] then
        local named, err = named_lane(backend, flags["--lane"])
        if not named then
            return err
        end
        lane = named
    end
    local limit, bad = runner.limit(flags[runner.FLAG])
    if bad then
        return bad
    end
    local stages = backend.stages
    local column = stages.ready
    if flags["--column"] then
        local named, err = named_column(backend, flags["--column"])
        if not named then
            return err
        end
        local takes = named == stages.ready
            or named == stages.backlog
            or named == stages.icebox
            or named == stages.blocked
            or named == stages.review
            or named == stages.verify
            or named == stages.release
        if not takes then
            return usage(
                "Next --column takes Ready, Backlog, Icebox, Review, Verify, Release or Blocked."
            )
        end
        column = named
    end
    local asked = flags["--for"] and flags["--for"]:lower()
    if asked and (column ~= stages.blocked or not board.BLOCKED_LABELS[asked]) then
        return usage("Next --for takes planner or lead, with --column Blocked.")
    end
    local card, message = backend:next(column, {
        label = column == stages.blocked and board.BLOCKED_LABELS[asked or "lead"] or nil,
        max_size = limit,
        lane = lane,
    })
    if not card then
        if message then
            return failure(message)
        end
        if column == stages.ready then
            return { output = "No ready cards." }
        end
        return { output = "No cards in " .. column .. "." }
    end
    local list, why = backend:comments(card.id)
    if not list then
        return failure(why)
    end
    local owners = 0
    for _, comment in ipairs(list) do
        if comment.actor == HUMAN_ACTOR then
            owners = owners + 1
        end
    end
    return {
        output = string.format(
            "%s  %d %s, %d the owner's",
            card_line(card),
            #list,
            #list == 1 and "comment" or "comments",
            owners
        ) .. link_suffix(backend, card),
    }
end

---Link a new card as blocked by each blocker, and name the first link that fails.
---@param backend dev.board.Backend the board the card is on
---@param card dev.board.Card the card just added
---@param blockers dev.board.Card[] the cards that block it
---@return dev.cmd.board.Result? refused the failure, nil when every link is made
local function link_blockers(backend, card, blockers)
    local card_prefix = card.id:sub(1, board.MIN_PREFIX)
    for linked, blocker in ipairs(blockers) do
        local ok, why = backend:link(card.id, board.LinkKind.BLOCKED_BY, blocker.id)
        if not ok then
            return {
                message = card_prefix
                    .. " was added to "
                    .. card.column
                    .. " but its blocked_by link to "
                    .. blocker.id:sub(1, board.MIN_PREFIX)
                    .. " was not. "
                    .. (linked - 1)
                    .. " of "
                    .. #blockers
                    .. " links were made before it. Reason: "
                    .. why
                    .. ".",
                code = 1,
                unqueued = true,
            }
        end
    end
    return nil
end

---Tell whether a name word reads as a checks row left without its own --checks flag.
---@param word string one word of the card name
---@return boolean reads true when the word starts like a checks row
local function looks_like_a_checks_row(word)
    return word:find("^dev ") ~= nil or word:find("^rg ") ~= nil or word:find("^! ") ~= nil
end

---Add a card, and record in `held` whether the parsed flags hold the --id-only switch.
---@param backend dev.board.Backend the board to add the card to
---@param args string[] the arguments after `add`
---@param held { id_only: boolean? } receives `id_only`, true when the switch is set
---@return dev.cmd.board.Result result the outcome of the add
local function add_card(backend, args, held)
    local flags, words = parse(args, {
        ["--column"] = true,
        ["--description"] = true,
        ["--problem"] = true,
        ["--change"] = true,
        ["--out-of-scope"] = true,
        ["--source"] = true,
        ["--size"] = true,
        ["--label"] = true,
        ["--checks"] = true,
        ["--done-when"] = true,
        ["--board"] = true,
        ["--blocked-by"] = true,
        ["--from"] = true,
        ["--before"] = true,
        ["--after"] = true,
        ["--lane"] = true,
        ["--top"] = SWITCH,
        [ID_ONLY_FLAG] = SWITCH,
        ["--epic"] = SWITCH,
    }, {
        ["--problem"] = true,
        ["--change"] = true,
        ["--out-of-scope"] = true,
        ["--source"] = true,
        ["--label"] = true,
        ["--checks"] = true,
        ["--done-when"] = true,
        ["--blocked-by"] = true,
    })
    if not flags then
        return words
    end
    if #words == 0 then
        return usage("Needs a card name.")
    end
    for index = 2, #words do
        local word = words[index]
        if looks_like_a_checks_row(word) then
            return usage(
                "The name word "
                    .. word
                    .. " reads as a checks row. Give each row its own --checks flag."
            )
        end
    end
    held.id_only = flags[ID_ONLY_FLAG]
    if flags["--board"] then
        local home, why = guards.other_home(backend, flags["--board"])
        if not home then
            return failure(why)
        end
        backend = home
    end
    for _, flag in ipairs({ "--problem", "--out-of-scope", "--source" }) do
        if flags[flag] and #flags[flag] > 1 then
            return usage("The " .. flag .. " flag takes one value, so give its text once.")
        end
    end
    local problem = flags["--problem"] and flags["--problem"][1]
    local out_of_scope = flags["--out-of-scope"] and flags["--out-of-scope"][1]
    local change
    if flags["--change"] then
        local lines = {}
        for i, line in ipairs(flags["--change"]) do
            local text = line:match("^%s*(.-)%s*$")
            lines[i] = text:find("^%- ") and text or "- " .. text
        end
        change = table.concat(lines, "\n")
    end
    local source = flags["--source"] and flags["--source"][1]
    local sectioned = problem or change or out_of_scope or source
    if sectioned and flags["--description"] then
        return usage(
            "The --description flag holds the whole text, "
                .. "so it cannot go with --problem, --change, --out-of-scope or --source."
        )
    end
    local labels
    for _, label in ipairs(flags["--label"] or {}) do
        local ok, err = plain(label)
        if not ok then
            return err
        end
        local denied = require("dev.standalone").label_problem(label)
        if denied then
            return failure(denied)
        end
        labels = labels or {}
        if not index_of(labels, label) then
            labels[#labels + 1] = label
        end
    end
    local checks = {}
    for _, run in ipairs(flags["--checks"] or {}) do
        if not run:find("%S") then
            return usage("The --checks flag needs a command.")
        end
        checks[#checks + 1] = run
    end
    local refused_row = guards.row_refusal(checks, backend.root)
    if refused_row then
        return refused_row
    end
    local outcomes = {}
    for _, item in ipairs(flags["--done-when"] or {}) do
        if not item:find("%S") then
            return usage("The --done-when flag needs the outcome.")
        end
        outcomes[#outcomes + 1] = item
    end
    if #outcomes > board.MAX_OUTCOMES then
        return usage("A card has at most " .. board.MAX_OUTCOMES .. " --done-when outcomes.")
    end
    local color
    if flags["--size"] then
        local named, err = sized(flags["--size"])
        if not named then
            return err
        end
        color = named
    end
    local stages = backend.stages
    local column = stages.backlog
    if flags["--column"] then
        local named, err = named_column(backend, flags["--column"])
        if not named then
            return err
        end
        column = named
    end
    local lane
    if flags["--lane"] then
        local named, err = named_lane(backend, flags["--lane"])
        if not named then
            return err
        end
        lane = named
    end
    if
        index_of(labels or {}, board.NEEDS_HUMAN)
        and column ~= stages.blocked
        and column ~= stages.icebox
    then
        return usage(
            "The "
                .. board.NEEDS_HUMAN
                .. " label lives only in Blocked or Icebox, so add the card there with --column."
        )
    end
    if column == stages.ready and unready(color) then
        return usage(
            "A card must be sized 1, 2 or 3 before it enters Ready, "
                .. "so add it with --size or to Backlog."
        )
    end
    local description = flags["--description"]
    if sectioned then
        description = board.compose(problem, change, out_of_scope, source)
    elseif column ~= stages.icebox then
        description = board.scaffold(description)
    end
    if column ~= stages.icebox and column ~= stages.ready then
        local missing = board.unplanned({
            color = color,
            description = description,
            outcomes = #outcomes,
            need_outcomes = true,
            children = 0,
            epic = flags["--epic"],
        })
        if #missing > 0 then
            return usage(
                "A card outside "
                    .. stages.icebox
                    .. " needs a size, card format v3 and Done when outcomes, and this one lacks "
                    .. table.concat(missing, ", ")
                    .. ". Pass --size, --problem and --done-when, or add it to "
                    .. stages.icebox
                    .. "."
            )
        end
    end
    if column == stages.ready then
        local missing = board.missing(description, #outcomes, 0, flags["--epic"])
        if #missing > 0 then
            return usage(
                "A card needs card format v3 before it enters Ready, and this one lacks "
                    .. table.concat(missing, ", ")
                    .. ". Add it to Backlog or pass --problem, --change, "
                    .. "--out-of-scope and --done-when."
            )
        end
    end
    if #checks > 0 or column == stages.ready then
        local why, err = named_field_problem(backend, board.CHECKS_FIELD)
        if err then
            return err
        end
        if why then
            return usage(why)
        end
        if #checks == 0 then
            return usage("A card needs a checks row before it enters Ready. Pass --checks CMD.")
        end
    end
    if column == stages.ready and not flags["--epic"] then
        local named = {}
        for i, item in ipairs(outcomes) do
            named[i] = { name = item }
        end
        local unnamed = board.unnamed_checks(named, checks)
        if #unnamed > 0 then
            return usage(
                "An outcome needs a deciding check before the card enters Ready. "
                    .. "These outcomes lack one: "
                    .. table.concat(unnamed, ", ")
                    .. ". End each with "
                    .. board.CHECK_OPEN
                    .. "ROW) naming part of a checks row, or with "
                    .. board.JUDGEMENT
                    .. "."
            )
        end
    end
    local blockers, seen = {}, {}
    for _, word in ipairs(flags["--blocked-by"] or {}) do
        local blocker, _, err = other_card(backend, word)
        if not blocker then
            return err
        end
        if not seen[blocker.id] then
            seen[blocker.id] = true
            blockers[#blockers + 1] = blocker
        end
    end
    local origin
    if flags["--from"] then
        local found, _, err = other_card(backend, flags["--from"])
        if not found then
            return err
        end
        origin = found
    end
    local position
    local anchor_word = flags["--before"] or flags["--after"]
    if flags["--top"] or anchor_word then
        if
            (flags["--top"] and 1 or 0)
                + (flags["--before"] and 1 or 0)
                + (flags["--after"] and 1 or 0)
            > 1
        then
            return usage("Give only one of --top, --before and --after. Each places the card once.")
        end
        position = 0
        if anchor_word then
            local cards, why = backend:cards({ summary = true })
            if not cards then
                return failure(why)
            end
            local anchor
            anchor, why = board.resolve(cards, anchor_word)
            if not anchor then
                return failure(why)
            end
            if anchor.column ~= column then
                return usage(
                    "Card "
                        .. anchor.id:sub(1, board.MIN_PREFIX)
                        .. " is in "
                        .. anchor.column
                        .. ". The new card goes to "
                        .. column
                        .. "."
                )
            end
            if lane and anchor.lane ~= lane then
                return usage(
                    "Card "
                        .. anchor.id:sub(1, board.MIN_PREFIX)
                        .. " is in lane "
                        .. (anchor.lane or "none")
                        .. ". The new card goes to lane "
                        .. lane
                        .. "."
                )
            end
            lane = lane or anchor.lane
            for _, other in ipairs(cards) do
                if other.column == column and other.lane == anchor.lane then
                    position = position + 1
                end
                if other.id == anchor.id then
                    break
                end
            end
            if flags["--before"] then
                position = position - 1
            end
        end
    end
    local card, message = backend:add(table.concat(words, " "), column, {
        description = description,
        color = color,
        labels = labels,
        checks = checks,
        outcomes = outcomes,
        epic = flags["--epic"] or nil,
        lane = lane,
    })
    if not card then
        return failure(message)
    end
    local card_prefix = card.id:sub(1, board.MIN_PREFIX)
    local refused = link_blockers(backend, card, blockers)
    if refused then
        return refused
    end
    if origin and not seen[origin.id] then
        local ok, why = backend:link(card.id, board.LinkKind.RELATED, origin.id)
        if not ok then
            return {
                message = card_prefix
                    .. " was added to "
                    .. card.column
                    .. " but its related link to "
                    .. origin.id:sub(1, board.MIN_PREFIX)
                    .. " was not: "
                    .. why,
                code = 1,
                unqueued = true,
            }
        end
    end
    if position then
        local ok, why, reason = backend:move(card.id, card.column, { position = position })
        if not ok then
            return {
                message = "Card "
                    .. card_prefix
                    .. " was added to "
                    .. card.column
                    .. " but not placed. "
                    .. board.move_refusal(reason, why, card.column),
                code = 1,
                unqueued = true,
            }
        end
    end
    local prose = flags["--description"] or (sectioned and description)
    if #outcomes > 0 then
        prose = (prose or "") .. "\n## Done when\n" .. table.concat(outcomes, "\n")
    end
    return {
        output = flags[ID_ONLY_FLAG] and card.id
            or "added "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. " "
                .. card.column
                .. link_suffix(backend, card),
        warnings = board.prose_warnings(prose),
    }
end

function commands.add(backend, args)
    local held = {}
    local result = add_card(backend, args, held)
    if held.id_only and result.message then
        return unqueued(result)
    end
    return result
end

local function find_comment(backend, card, word)
    local list, message = backend:comments(card.id)
    if not list then
        return nil, failure(message)
    end
    local comment, why = board.resolve(list, word, "comment")
    if not comment then
        return nil, failure(why)
    end
    return comment
end

local function changed(verb_word, card, comment)
    return {
        output = verb_word .. " " .. card.id:sub(1, board.MIN_PREFIX) .. " " .. comment.id:sub(
            1,
            board.MIN_PREFIX
        ),
    }
end

local function edit_note(backend, args)
    if #args < 4 then
        return usage("The " .. EDIT_FLAG .. " flag needs a comment and the new text.")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local comment
    comment, err = find_comment(backend, card, args[3])
    if not comment then
        return err
    end
    local text = table.concat(args, " ", 4)
    if board.reserved(comment.body) or board.reserved(text) then
        return failure(RESERVED_NOTE)
    end
    local ok, message = backend:edit_note(card.id, comment.id, text)
    if not ok then
        return failure(message)
    end
    return changed("edited", card, comment)
end

local function delete_note(backend, args)
    if #args < 3 then
        return usage("The " .. DELETE_FLAG .. " flag needs a comment.")
    end
    if #args > 3 then
        return usage("Unknown argument " .. args[4] .. ".")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local comment
    comment, err = find_comment(backend, card, args[3])
    if not comment then
        return err
    end
    if board.reserved(comment.body) then
        return failure(RESERVED_NOTE)
    end
    local ok, message = backend:delete_note(card.id, comment.id)
    if not ok then
        return failure(message)
    end
    return changed("deleted", card, comment)
end

local function body_lines(body)
    local trimmed = body:gsub("\r\n?", "\n"):gsub("\n+$", "")
    local lines = {}
    for line in (trimmed .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

local function body_column(rows)
    local marked = {}
    for i, row in ipairs(rows) do
        marked[i] = { row[1], row[2], row[3], row[4], row[5], "x" }
    end
    return text_width(board.table_lines(marked)[1]) - text_width("x")
end

---Format the comments as aligned table rows, one per comment.
---@param list dev.board.Comment[]
---@param opts? { whole: boolean } `whole` prints every line of each body, not only the first
---@return string
local function comment_lines(list, opts)
    if #list == 0 then
        return "no comments"
    end
    local rows, rests = {}, {}
    for i, comment in ipairs(list) do
        local lines = body_lines(comment.body)
        rows[i] = {
            comment.id:sub(1, board.MIN_PREFIX),
            comment.who,
            comment.kind or "-",
            comment.author or "-",
            comment.at:sub(1, STAMP_CHARS):gsub("T", " "),
            lines[1],
        }
        rests[i] = {}
        if opts and opts.whole then
            for j = 2, #lines do
                rests[i][#rests[i] + 1] = lines[j]
            end
            local question = comment.question
            if question and question.choices and not question.answer then
                for index, choice in ipairs(question.choices) do
                    rests[i][#rests[i] + 1] = index
                        .. ". "
                        .. choice.label
                        .. (choice.column and " (" .. choice.column .. ")" or "")
                        .. (question.recommended == index and " [recommended]" or "")
                end
            end
        end
    end
    local indent = string.rep(" ", body_column(rows))
    local out = {}
    for i, line in ipairs(board.table_lines(rows)) do
        out[#out + 1] = line
        for _, rest in ipairs(rests[i]) do
            out[#out + 1] = rest:match("^%s*$") and "" or indent .. rest
        end
    end
    return table.concat(out, "\n")
end

function commands.notes(backend, args)
    if #args ~= 1 then
        return usage("Needs a card.")
    end
    local home, rest, refused = guards.on_board(backend, args)
    if not home then
        return refused
    end
    local card, err = find_card(home, rest[1])
    if not card then
        return err
    end
    local list, message = home:comments(card.id)
    if not list then
        return failure(message)
    end
    return { output = comment_lines(list) }
end

function commands.history(backend, args)
    if #args ~= 1 then
        return usage("Needs a card.")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local events, message = backend:history(card.id)
    if not events then
        return failure(message)
    end
    return { output = render.history(events) }
end

---The value at a percentile of a sorted list, by the nearest-rank rule.
---@param sorted number[] the values, ascending and not empty
---@param percent number the percentile from 1 to 100
---@return number
local function percentile(sorted, percent)
    return sorted[math.max(1, math.ceil(#sorted * percent / 100))]
end

function commands.flow(backend, args)
    if #args ~= 0 then
        return usage("Takes no arguments.")
    end
    local landed, message = backend:dwell()
    if not landed then
        return failure(message)
    end
    local minutes = {}
    for _, card in ipairs(landed) do
        minutes[#minutes + 1] = math.floor((card.done - card.verify) / 60)
    end
    table.sort(minutes)
    local lines = { "landed " .. #minutes }
    if #minutes > 0 then
        lines[#lines + 1] = "median " .. percentile(minutes, 50) .. " min"
        lines[#lines + 1] = "p90 " .. percentile(minutes, 90) .. " min"
    end
    return { output = table.concat(lines, "\n") }
end

---@param family dev.board.Family
---@return string
local function kin_lines(family)
    local lines = ""
    if family.parent then
        lines = lines
            .. "parent: "
            .. family.parent.id:sub(1, board.MIN_PREFIX)
            .. " "
            .. family.parent.name
            .. "\n"
    end
    if family.children then
        lines = lines
            .. "children: "
            .. family.children.done
            .. " of "
            .. family.children.total
            .. " done\n"
        for _, child in ipairs(family.children.items or {}) do
            lines = lines
                .. "- "
                .. (child.board and "[" .. child.board .. "] " or "")
                .. child.id:sub(1, board.MIN_PREFIX)
                .. " "
                .. child.name
                .. (child.column and " (" .. child.column .. ")" or "")
                .. "\n"
        end
    end
    return lines
end

---Format a card as `show` prints it, with every comment in full.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@return string? view the card line, kin, description, outcomes, blocks and comments
---@return dev.cmd.board.Result? err the failure when the comments or family could not be read
local function card_view(backend, card)
    local list, message = backend:comments(card.id)
    if not list then
        return nil, failure(message)
    end
    local family
    family, message = backend:family(card.id)
    if not family then
        return nil, failure(message)
    end
    local kin = kin_lines(family)
    if family.epic then
        local open = board.open_children(family.children)
        kin = "kind: epic" .. (open > 0 and ", " .. open .. " open" or "") .. "\n" .. kin
    end
    if card.responsible then
        kin = "responsible: " .. card.responsible .. "\n" .. kin
    end
    if card.due then
        kin = "due: " .. card.due .. "\n" .. kin
    end
    local description = (card.description or ""):match("^%s*(.-)%s*$")
    if #card.outcomes > 0 then
        local _, rest = board.split_checklist(description)
        description = rest or description
    end
    if description == "" then
        description = "no description"
    end
    local outcomes = ""
    if #card.outcomes > 0 then
        local lines = {}
        for _, outcome in ipairs(card.outcomes) do
            lines[#lines + 1] = "- [" .. (outcome.done and "x" or " ") .. "] " .. outcome.name
        end
        outcomes = "done when:\n" .. table.concat(lines, "\n") .. "\n\n"
    end
    local blocks = ""
    for _, field in ipairs(board.BLOCK_FIELDS) do
        local names = card[field]
        if names and #names > 0 then
            blocks = blocks .. field .. ":\n- " .. table.concat(names, "\n- ") .. "\n\n"
        end
    end
    return card_line(card)
        .. link_suffix(backend, card)
        .. "\n"
        .. kin
        .. "\n"
        .. description
        .. "\n\n"
        .. outcomes
        .. blocks
        .. comment_lines(list, { whole = true })
end

function commands.show(backend, args)
    local home, rest, refused = guards.on_board(backend, args)
    if not home then
        return refused
    end
    args = rest
    if #args ~= 1 then
        return usage("Needs a card.")
    end
    local card, err = find_card(home, args[1])
    if not card then
        return err
    end
    local view
    view, err = card_view(home, card)
    if not view then
        return err
    end
    return { output = view }
end

---Append the card as `show` prints it to the output of a claim that just succeeded.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the claimed card
---@param result dev.cmd.board.Result the claim's result
---@return dev.cmd.board.Result result the claim's result with the card view after its line
local function claimed_view(backend, card, result)
    local view, err = card_view(backend, card)
    if not view then
        verb.note(
            "Took card "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. ", but its view failed. "
                .. err.message
        )
        return result
    end
    result.output = result.output .. "\n\n" .. view
    return result
end

local function note_opts(args)
    local kind, label
    local i = 2
    while args[i] == KIND_FLAG or args[i] == AS_FLAG do
        if i == #args then
            return nil, usage("The " .. args[i] .. " flag needs a value.")
        end
        if args[i] == KIND_FLAG then
            kind = args[i + 1]
        else
            label = args[i + 1]
        end
        i = i + 2
    end
    if i > 2 and (args[i] == EDIT_FLAG or args[i] == DELETE_FLAG) then
        return nil,
            usage("The " .. args[i] .. " flag takes no " .. KIND_FLAG .. " or " .. AS_FLAG .. ".")
    end
    if args[i] and args[i]:find("^%-%-%a") then
        return nil, usage("Unknown flag " .. args[i] .. ".")
    end
    local words = { args[1] }
    for j = i, #args do
        words[#words + 1] = args[j]
    end
    if #words < 2 then
        return nil, usage("Needs a card and the note.")
    end
    local opts = {}
    if kind then
        opts.kind = kind:lower()
        if opts.kind == board.NoteKind.QUESTION then
            return nil,
                usage(
                    "Question is not a note kind. Ask the owner with "
                        .. "dev board ask CARD --question TEXT --choice COLUMN=LABEL "
                        .. "--recommend N --why TEXT."
                )
        end
        if not index_of(board.NOTE_KINDS, opts.kind) then
            return nil,
                usage(
                    "Unknown kind "
                        .. kind
                        .. ". The kinds are "
                        .. table.concat(board.NOTE_KINDS, ", ")
                        .. "."
                )
        end
    end
    if label then
        opts.author = label:match("^%s*(.-)%s*$")
        if opts.author == "" or opts.author:find("%c") then
            return nil,
                usage("The " .. AS_FLAG .. " flag needs a label with no control characters.")
        end
        if #opts.author > board.AUTHOR_CHARS then
            return nil,
                usage(
                    "The "
                        .. AS_FLAG
                        .. " flag takes at most "
                        .. board.AUTHOR_CHARS
                        .. " characters."
                )
        end
    end
    return words, opts
end

function commands.note(backend, args)
    if args[2] == "--board" and (args[4] == EDIT_FLAG or args[4] == DELETE_FLAG) then
        return usage("The --board flag takes no " .. EDIT_FLAG .. " or " .. DELETE_FLAG .. ".")
    end
    local home, rest, refused = guards.on_board(backend, args)
    if not home then
        return refused
    end
    args = rest
    if args[2] == EDIT_FLAG then
        return edit_note(home, args)
    elseif args[2] == DELETE_FLAG then
        return delete_note(home, args)
    end
    local words, opts = note_opts(args)
    if not words then
        return opts
    end
    local card, err = find_card(home, words[1])
    if not card then
        return err
    end
    local text = table.concat(words, " ", 2)
    if board.reserved(text) then
        return failure(RESERVED_NOTE)
    end
    if board.mostly_ids(text) then
        return usage(
            "That note is mostly ids, hashes and paths. Write two or three sentences for a person."
        )
    end
    local held = claims.read(card.id)
    local ok, message = home:note(card.id, text, held and held.fence, opts)
    if not ok then
        return failure(message)
    end
    return { output = "noted " .. card.id:sub(1, board.MIN_PREFIX) }
end

---Refuse a move that takes a card out of In Progress before its claimant has noted.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card being moved
---@param column string the column it moves to
---@return dev.cmd.board.Result? refused the failure, nil when the move may go on
local function unnoted(backend, card, column)
    local stages = backend.stages
    local leaving = card.column == stages.progress
        and (column == stages.review or column == stages.ready or column == stages.blocked)
    if not (leaving and card.claimant) then
        return nil
    end
    local past, why = backend:comments(card.id)
    if not past then
        return failure(why)
    end
    if board.noted_since_claim(past, card.claimant) == false then
        local short = card.id:sub(1, board.MIN_PREFIX)
        return failure(
            string.format(
                "Card %s has no note from its claimant %s since the claim. "
                    .. "It cannot leave In Progress. "
                    .. "Note what you built, tried and learned first with `dev board note %s TEXT`.",
                short,
                card.claimant,
                short
            )
        )
    end
end

---Take a lapsed claim again when the caller is the card's last claimant and leaves In Progress.
---
---A card whose claim lapsed during a long ci wait has no claimant, and the card's newest claim
---record still names who held it. Only that name takes the claim again, after the same note rule
---that a live claim meets. Any other caller, and a card another claimant holds, change nothing.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card, whose claimant this sets when it takes the claim
---@param column string the column the card moves to
---@return dev.cmd.board.Result? refused the failure, nil when nothing applied or the claim was
---   taken
---@return boolean? retaken true when the claim was taken again, after the note rule passed
local function retake_lapsed(backend, card, column)
    local stages = backend.stages
    if card.column ~= stages.progress or column == stages.progress or card.claimant then
        return nil
    end
    local name, bad = agent_name()
    if bad then
        return nil
    end
    local past, why = backend:comments(card.id)
    if not past then
        return failure(why)
    end
    local who = runner.claimant(name)
    local last = board.last_claimant(past)
    if last ~= who then
        if last and column == stages.review then
            local short = card.id:sub(1, board.MIN_PREFIX)
            return failure(
                string.format(
                    "The claim of %s lapsed. Take card %s again with `dev board take %s`.",
                    last,
                    short,
                    short
                )
            )
        end
        return nil
    end
    card.claimant = who
    local refused = unnoted(backend, card, column)
    if refused then
        card.claimant = nil
        return refused
    end
    local result, fence = claim_card(backend, card, name)
    if not fence then
        card.claimant = nil
        return result
    end
    return nil, true
end

---Refuse a card whose size cannot enter Ready.
---@param card dev.board.Card the card
---@return dev.cmd.board.Result? refused the failure, nil when the card has a size of 1 to 3
local function size_refusal(card)
    if not unready(card.color) then
        return nil
    end
    local why = card.color == board.SIZES["3+"]
            and " is red, more than 3 Pomodori. Split it, since a red card cannot enter Ready."
        or " has no size. It cannot enter Ready."
    return failure(
        "Card "
            .. card.id:sub(1, board.MIN_PREFIX)
            .. why
            .. " Size it with `dev board size CARD 1`, `2` or `3`."
    )
end

---Count a card's children and say whether it is an epic.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@return {children: integer, epic: boolean}? shape the card's family, nil when the board failed
---@return string? why the reason the board could not be read
local function family_shape(backend, card)
    if card.epic == nil and card.kind ~= board.Kind.EPIC then
        return { children = 0, epic = false }
    end
    local family, why = backend:family(card.id)
    if not family then
        return nil, why
    end
    return { children = family.children and family.children.total or 0, epic = true }
end

---Say whether a card sits in a column where work has not started.
---@param stages dev.board.Stages the board's columns
---@param card dev.board.Card the card
---@return boolean before true in Icebox, Backlog or Ready
local function before_work(stages, card)
    return card.column == stages.icebox
        or card.column == stages.backlog
        or card.column == stages.ready
end

---Refuse a card that has not started while an open card blocks it.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@return dev.cmd.board.Result? refused the failure, nil when the card has started or nothing open blocks it
local function blocker_refusal(backend, card)
    if not before_work(backend.stages, card) then
        return nil
    end
    local blocked, blocker = backend:blocked(card.id)
    if blocked == nil then
        return failure(blocker)
    end
    if not blocked then
        return nil
    end
    return failure(
        "Card "
            .. card.id:sub(1, board.MIN_PREFIX)
            .. " is blocked by open card "
            .. blocker
            .. ". Finish that card first."
    )
end

---Roles that take an Icebox or Backlog card unplanned
local PLANNING_ROLES = { planner = true, scoper = true }

---Say whether a planner or scoper takes a card in the column where it plans.
---@param stages dev.board.Stages the board's columns
---@param card dev.board.Card the card
---@param name string? the agent name from --as, nil for the environment's
---@return boolean plans true for a planner or scoper taking an Icebox or Backlog card
local function plans_card(stages, card, name)
    local role = board.agent_role(name or claimant())
    return PLANNING_ROLES[role] == true
        and (card.column == stages.icebox or card.column == stages.backlog)
end

---Refuse a card with no checks row and no children.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@param children integer how many children the card has
---@return dev.cmd.board.Result? refused the failure, nil when the card has a row or children
local function checks_refusal(backend, card, children)
    if #card.checks > 0 or children > 0 then
        return nil
    end
    local why, problem = named_field_problem(backend, board.CHECKS_FIELD)
    if problem then
        return problem
    end
    return failure(
        why
            or (
                "Card "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. " has no checks row and cannot enter Ready. Give it one with `dev board checks CARD CMD`."
            )
    )
end

---Read the checks rows the project requires of every card.
---@param backend dev.board.Backend the board
---@return string[]? rows the required rows, nil when the project lists none
---@return dev.cmd.board.Result? err the failure when the setting is not a list of commands
local function required_rows(backend)
    if not backend.root then
        return nil
    end
    local rows = config.get(backend.root, "board.lint.required")
    if rows == nil then
        return nil
    end
    local bad = failure("The `required` setting of `[board.lint]` must be a list of commands.")
    if type(rows) ~= "table" or (#rows == 0 and next(rows) ~= nil) then
        return nil, bad
    end
    for _, row in ipairs(rows) do
        if type(row) ~= "string" or not row:find("%S") then
            return nil, bad
        end
    end
    return rows
end

---Refuse a card whose checks lack a row the project requires.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@return dev.cmd.board.Result? refused the failure, nil when the card holds every required row
local function required_refusal(backend, card)
    local required, err = required_rows(backend)
    if err then
        return err
    end
    local missing = board.missing_rows(card.checks, required or {})
    if #missing == 0 then
        return nil
    end
    return failure(
        "Card "
            .. card.id:sub(1, board.MIN_PREFIX)
            .. " lacks the required row "
            .. table.concat(missing, ", ")
            .. " and cannot enter Ready. Add it with `dev board checks CARD CMD...`."
    )
end

---Refuse a card that fails the Ready requirements past its size.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@param shape {children: integer, epic: boolean} the card's children and whether it is an epic
---@return dev.cmd.board.Result? refused the failure, nil when the card meets them
local function ready_refusal(backend, card, shape)
    local children, epic = shape.children, shape.epic
    local stages = backend.stages
    local unreadable = guards.unreadable_refusal(card, stages.ready)
    if unreadable then
        return unreadable
    end
    local missing = board.missing(card.description, #card.outcomes, children, epic)
    if #missing > 0 then
        return failure(
            "Card "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. " is not in card format v3 and cannot enter Ready. It lacks "
                .. table.concat(missing, ", ")
                .. ". Add outcomes with `dev board outcome` and fix the description with `dev board edit`."
        )
    end
    local unchecked = checks_refusal(backend, card, children)
    if unchecked then
        return unchecked
    end
    if children == 0 and not epic then
        local unrequired = required_refusal(backend, card)
        if unrequired then
            return unrequired
        end
    end
    if children == 0 and not epic and not card.outcomes_unreadable then
        local unnamed = board.unnamed_checks(card.outcomes, card.checks)
        if #unnamed > 0 then
            return failure(
                "Card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " has an outcome that names no deciding check and cannot enter Ready. "
                    .. "These outcomes lack one: "
                    .. table.concat(unnamed, ", ")
                    .. ". End each with "
                    .. board.CHECK_OPEN
                    .. "ROW) naming part of a checks row, or with "
                    .. board.JUDGEMENT
                    .. "."
            )
        end
    end
    if children == 0 then
        local unrunnable = guards.row_refusal(card.checks, backend.root)
        if unrunnable then
            return failure(
                "Card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " has a checks row that cannot run and cannot enter Ready. "
                    .. unrunnable.message
            )
        end
    end
    local comments, why = backend:comments(card.id)
    if not comments then
        return failure(why)
    end
    local asked = board.open_question(comments)
    if asked then
        return failure(
            "Card "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. " has an unanswered question, comment "
                .. asked.id:sub(1, board.MIN_PREFIX)
                .. ", and cannot enter Ready. Answer it with a decision note first."
        )
    end
end

local MOVE_FLAGS = { [runner.FLAG] = true, [WAIT_FLAG] = true, ["--lane"] = true }

---Move a card to a column, checking its outcomes first when the column is Done.
---@param backend dev.board.Backend the board
---@param args string[] the card and the column
---@param opts {drop: boolean?}? `drop` skips the outcome check, and the planning check from Icebox
---@return dev.cmd.board.Result result the output, or a message and the exit code
local function move_once(backend, args, opts)
    local flags, words = parse(args, MOVE_FLAGS)
    if not flags then
        return words
    end
    if #words < 2 then
        return usage("Needs a card and a column.")
    end
    local lane
    if flags["--lane"] then
        local named, bad = named_lane(backend, flags["--lane"])
        if not named then
            return bad
        end
        lane = named
    end
    if flags[runner.FLAG] then
        local _, bad = runner.limit(flags[runner.FLAG])
        if bad then
            return bad
        end
    end
    local stages = backend.stages
    local column, err = named_column(backend, table.concat(words, " ", 2))
    if
        not column
        or column == stages.review
        or column == stages.verify
        or column == stages.release
    then
        local refused = guards.stage_refusal(backend)
        if refused then
            return refused
        end
    end
    if not column then
        return err
    end
    local to_done = column == stages:done_column() and not (opts and opts.drop)
    local card
    card, err = find_card(backend, words[1])
    if not card then
        return to_done and unqueued(err) or err
    end
    if card.column ~= column then
        local held_back = owner_holds(card)
        if held_back then
            return held_back
        end
    end
    if column == stages.progress then
        local refused = blocker_refusal(backend, card)
        if refused then
            return refused
        end
    end
    if to_done then
        local refused = guards.done_refusal(card, stages:done_column())
        if refused then
            return refused
        end
    end
    local proving = (column == stages.release or to_done)
        and card.column ~= stages.release
        and card.kind ~= board.Kind.EPIC
        and not (opts and (opts.landed or opts.drop))
        and not board.labelled(card, board.TRUNK_BLOCKER)
        and not (to_done and board.labelled(card, board.NO_CHANGE))
    if proving and guards.landed_on_trunk(backend, card, opts) then
        local refused = guards.done_refusal(card, column)
        if refused then
            return to_done and unqueued(refused) or refused
        end
        proving = false
    end
    if proving then
        local refused = guards.proof_refusal(backend, card, column, opts)
        if refused then
            return to_done and unqueued(refused) or refused
        end
    end
    local epic = card.epic ~= nil or card.kind == board.Kind.EPIC
    local kids
    if epic then
        local family, why = backend:family(card.id)
        if not family then
            return to_done and unqueued(failure(why)) or failure(why)
        end
        kids = family.children
    end
    local children = kids and kids.total or 0
    local closing = to_done and board.children_closed(kids)
    if column == stages.ready then
        local refused = size_refusal(card)
        if refused then
            return refused
        end
    end
    if not (opts and opts.drop) then
        local refused = guards.children_refusal(backend, card, column, kids)
        if refused then
            return refused
        end
    end
    local dropping_icebox = opts and opts.drop and card.column == stages.icebox
    if column ~= stages.icebox and column ~= stages.ready and not dropping_icebox then
        local facts = {
            color = card.color,
            description = card.description,
            outcomes = #card.outcomes,
            need_outcomes = not (opts and opts.drop) and not card.outcomes_unreadable,
            closing = closing,
            children = children,
            epic = epic,
            shapes = not (opts and opts.drop),
        }
        local missing = board.unplanned(facts)
        if #missing > 0 then
            return failure(
                "Card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " is not planned and cannot enter "
                    .. column
                    .. ". It lacks "
                    .. table.concat(missing, ", ")
                    .. ". Fix it with `dev board size`, `dev board edit` and `dev board outcome`."
            )
        end
    end
    local starting = column == stages.progress and before_work(stages, card)
    if column == stages.ready then
        local refused = ready_refusal(backend, card, { children = children, epic = epic })
        if refused then
            return refused
        end
    elseif starting then
        local refused = checks_refusal(backend, card, children)
        if refused then
            return refused
        end
    end
    if column == stages.progress then
        local limit, bad = runner.limit(flags[runner.FLAG])
        if bad then
            return bad
        end
        local refused = runner.refusal(card, limit)
        if refused then
            return refused
        end
        if card.column ~= stages.progress and not claims.read(card.id) then
            local _, wrong = agent_name()
            if wrong then
                return wrong
            end
            refused = runner.limited(backend, card, column)
            if refused then
                return runner.full(refused.message)
            end
        end
    elseif card.column ~= column and not to_done then
        local refused = runner.limited(backend, card, column)
        if refused then
            return runner.full(refused.message)
        end
    end
    local lapsed, retaken = retake_lapsed(backend, card, column)
    if lapsed then
        return lapsed
    end
    local skipped = guards.skipped_refusal(stages, card, column)
    if skipped then
        return skipped
    end
    local missing_note = not retaken and unnoted(backend, card, column)
    if missing_note then
        return missing_note
    end
    local held = claims.read(card.id)
    local started
    if column == stages.progress and not held and not card.claimant then
        local name, bad = agent_name()
        if bad then
            return bad
        end
        local shaped = runner.shape_refusal(name)
        if shaped then
            return shaped
        end
        local result, fence = claim_card(backend, card, name)
        if not fence then
            return result
        end
        started = true
        held = { fence = fence }
    end
    local own_claim = held ~= nil
    if held and not started then
        wiring.renew_claim(backend, card, (agent_name()))
        held = claims.read(card.id) or held
    elseif card.claimant then
        local name, bad = agent_name()
        own_claim = not bad and runner.claimant(name) == card.claimant
    end
    local closes
    if to_done and card.column ~= column then
        local own = backend:family(card.id)
        local parent = own and own.parent
        local siblings = parent and backend:family(parent.id)
        if siblings and siblings.children and board.open_children(siblings.children) == 1 then
            closes = parent.id
        end
    end
    local ok, message, refusal = backend:move(card.id, column, {
        fence = held and held.fence,
        lane = lane,
        force = board.labelled(card, board.TRUNK_BLOCKER) or nil,
    })
    if not ok then
        if started then
            claims.stop(card.id)
            backend:release(card.id, held.fence)
        end
        if refusal == board.MoveReason.FULL then
            return runner.full(runner.limits.REFUSED .. message)
        end
        local refused = board.move_refusal(refusal, message, column, lane)
        return to_done and unqueued(failure(refused)) or failure(refused)
    end
    if own_claim then
        local reason, detail = role_clock.follow(backend, card, column, claimant((agent_name())))
        if reason then
            verb.note(clock_note("Moved, but its clock did not follow.", reason, detail))
        end
    end
    if own_claim and column ~= stages.progress and column ~= stages.blocked then
        claims.stop(card.id)
        local release_fence = held and held.fence
        local released, why, why_reason, why_detail = backend:release(card.id, release_fence)
        if not released then
            verb.note(
                "Moved, but the claim was not released. "
                    .. board.release_refusal(why_reason, why, why_detail, release_fence)
            )
        end
    end
    local result = { output = "moved " .. card.id:sub(1, board.MIN_PREFIX) .. " to " .. column }
    if closes then
        result.output = result.output
            .. "\nEpic "
            .. closes:sub(1, board.MIN_PREFIX)
            .. " has every child Done and can close now."
    end
    if started then
        card.column = column
        return claimed_view(backend, card, result)
    end
    return result
end

---@class dev.cmd.board.move.Opts
---@field drop boolean? skips the outcome check, and the planning check from Icebox
---@field landed boolean? skips the proof of a move into Release or Done that land already checked
---@field state (fun(root: string): dev.board.check.State?, string?)? reads the commit the proof
---   of a move into Release or Done covers, `land.state` when nil
---@field holds (fun(root: string, commit: string, rev: string): boolean)? says whether
---   trunk holds a card's landed commit, `land.holds` when nil
---@field nap (fun(seconds: number))? sleeps between tries, `dev.os.nap` when nil
---@field random dev.board.turn.Random? jitters the sleeps, `turn.entropy` when nil
---@field now (fun(): integer)? the clock in seconds since the epoch, `store.now` when nil

---Read the `--wait` flag, 0 when it is absent.
---@param flags table<string, string>? the parsed flags, nil when parsing failed
---@return integer? seconds the wait, nil when the value is not a whole number up to the bound
---@return dev.cmd.board.Result? refusal the usage result when the value is refused
local function wait_seconds(flags)
    if not (flags and flags[WAIT_FLAG]) then
        return 0
    end
    local seconds = flags[WAIT_FLAG]:match("^%d+$") and tonumber(flags[WAIT_FLAG])
    if not seconds or seconds > MAX_WAIT_SECONDS then
        return nil,
            usage(
                "The "
                    .. WAIT_FLAG
                    .. " flag needs a whole number of seconds up to "
                    .. MAX_WAIT_SECONDS
                    .. "."
            )
    end
    return seconds
end

---Move a card, and with `--wait SECONDS` try again while its column is full.
---@param backend dev.board.Backend the board
---@param args string[] the card, the column and the flags
---@param opts dev.cmd.board.move.Opts? the options of `move_once` and the clock
---@return dev.cmd.board.Result result the result of the last try
local function move_card(backend, args, opts)
    local foreign = guards.foreign_refusal(args[1], "move")
    if foreign then
        return foreign
    end
    local flags = parse(args, MOVE_FLAGS)
    local wait, bad_wait = wait_seconds(flags)
    if not wait then
        return bad_wait
    end
    local nap = opts and opts.nap or dev_os.nap
    local clock = opts and opts.now or store.now
    local poll = turn.poller({ random = opts and opts.random })
    local deadline = clock() + wait
    while true do
        local result = move_once(backend, args, opts)
        local left = deadline - clock()
        if result.code ~= runner.FULL or left <= 0 then
            return result
        end
        nap(math.min(poll:pace(runner.FULL), left))
    end
end

function commands.move(backend, args)
    return move_card(backend, args)
end

---Move a card, retrying a full column until room frees when `--wait` is given.
---@param backend dev.board.Backend the board
---@param args string[] the arguments after `move`
---@param opts dev.cmd.board.move.Opts? how to sleep and tell time
---@return dev.cmd.board.Result result the result of the last try
function M.move(backend, args, opts)
    backend.stages = backend.stages
        or board.stages(backend.column_map, backend:done_columns() or {})
    return move_card(backend, args, opts)
end

---Tell whether a move args list closes an epic, a move of an epic into the Done column.
---@param backend dev.board.Backend the board
---@param args string[] the arguments after `move`
---@return boolean
local function closes_epic(backend, args)
    local flags, words = parse(args, MOVE_FLAGS)
    if not flags or #words < 2 then
        return false
    end
    backend.stages = backend.stages
        or board.stages(backend.column_map, backend:done_columns() or {})
    local column = named_column(backend, table.concat(words, " ", 2))
    if not column or column ~= backend.stages:done_column() then
        return false
    end
    local card = find_card(backend, words[1])
    return card ~= nil and (card.epic ~= nil or card.kind == board.Kind.EPIC)
end

function commands.order(backend, args)
    local flags, words = parse(args, {})
    if not flags then
        return words
    end
    if #words == 0 then
        return usage("Needs one or more cards.")
    end
    local cards, message = backend:cards()
    if not cards then
        return failure(message)
    end
    local named, seen, column = {}, {}, nil
    for _, word in ipairs(words) do
        local card, why = board.resolve(cards, word)
        if not card then
            return failure(why)
        end
        if seen[card.id] then
            return failure("Card " .. card.id:sub(1, board.MIN_PREFIX) .. " is named twice.")
        end
        if column and card.column ~= column then
            return failure(
                "Order takes cards of one column, but card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " is in "
                    .. card.column
                    .. " and card "
                    .. named[1].id:sub(1, board.MIN_PREFIX)
                    .. " is in "
                    .. column
                    .. "."
            )
        end
        if named[1] and card.lane ~= named[1].lane then
            return failure(
                "Order takes cards of one lane, but card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " is in lane "
                    .. (card.lane or "none")
                    .. " and card "
                    .. named[1].id:sub(1, board.MIN_PREFIX)
                    .. " is in lane "
                    .. (named[1].lane or "none")
                    .. "."
            )
        end
        column = card.column
        seen[card.id] = true
        named[#named + 1] = card
    end
    local after, top
    for _ = 1, 2 do
        for position, card in ipairs(named) do
            local held = claims.read(card.id)
            local ok, why, reason = backend:move(
                card.id,
                column,
                { fence = held and held.fence, position = position - 1 }
            )
            if not ok then
                return failure(board.move_refusal(reason, why, column))
            end
        end
        after, message = backend:cards()
        if not after then
            return failure(message)
        end
        top = nil
        local place = 0
        for _, card in ipairs(after) do
            if card.column == column and card.lane == named[1].lane then
                place = place + 1
                if place <= #named and card.id ~= named[place].id then
                    top = top or card
                end
            end
        end
        if not top then
            break
        end
    end
    if top then
        return failure(
            "Order left card "
                .. top.id:sub(1, board.MIN_PREFIX)
                .. " above the named cards in "
                .. column
                .. " after a second pass of moves."
        )
    end
    local rows = {}
    for _, card in ipairs(after) do
        if card.column == column then
            rows[#rows + 1] = card_line(card)
        end
    end
    return { output = table.concat(rows, "\n") }
end

local DISCARD_LABEL = board.DISCARDED

---Close a card as dropped: the reason as a decision note, the label, then the move to Done.
---Each step is a command of its own, so when Pomb cannot take a step the steps left are queued.
function commands.discard(backend, args)
    local home, rest, refused = guards.on_board(backend, args)
    if not home then
        return refused
    end
    local elsewhere = home ~= backend
    backend, args = home, rest
    local flags, words = parse(args, { ["--reason"] = true })
    if not flags then
        return words
    end
    if #words ~= 1 then
        return usage("Needs a card, and an optional --reason TEXT.")
    end
    local reason = flags["--reason"]
    if reason and reason:find("^%s*$") then
        return usage("The --reason flag needs text.")
    end
    local card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    local held_back = owner_holds(card)
    if held_back then
        return held_back
    end
    local missing = {}
    if not (reason and card.column == backend.stages.icebox) then
        missing = board.unplanned({
            color = card.color,
            description = card.description,
            outcomes = #card.outcomes,
            need_outcomes = false,
            children = 0,
            shapes = false,
        })
    end
    if #missing > 0 then
        return failure(
            "Card "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. " is not planned and cannot be discarded. It lacks "
                .. table.concat(missing, ", ")
                .. ". Fix it with `dev board size` and `dev board edit`."
        )
    end
    local steps = {}
    if reason then
        steps[#steps + 1] =
            { sub = "note", args = { words[1], KIND_FLAG, board.NoteKind.DECISION, reason } }
    end
    steps[#steps + 1] = { sub = "label", args = { words[1], DISCARD_LABEL } }
    steps[#steps + 1] = { sub = "discard_move", args = { words[1], backend.stages:done_column() } }
    local warnings = {}
    for i, step in ipairs(steps) do
        local result = M.run(step.sub, step.args, backend)
        if result.message then
            local left = {}
            for j = i, #steps do
                left[#left + 1] = steps[j]
            end
            if elsewhere then
                return { message = result.message, code = result.code, unqueued = true }
            end
            return { message = result.message, code = result.code, queue = left }
        end
        for _, line in ipairs(result.warnings or {}) do
            warnings[#warnings + 1] = line
        end
    end
    return {
        output = "discarded " .. card.id:sub(1, board.MIN_PREFIX),
        warnings = warnings,
    }
end

local internal = {}

---Move a card to Done without the outcome check, as a discard does.
---@param backend dev.board.Backend the board
---@param args string[] the card and the column
---@return dev.cmd.board.Result result the output, or a message and the exit code
function internal.discard_move(backend, args)
    return move_card(backend, args, { drop = true })
end

function commands.size(backend, args)
    if #args ~= 2 then
        return usage("Needs a card and a size.")
    end
    local color, err = sized(args[2])
    if not color then
        return err
    end
    local card
    card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    if
        color == board.SIZES.unsized
        and (os.getenv("DEV_AGENT") or "") ~= ""
        and index_of(card.labels, board.NEEDS_HUMAN)
    then
        return failure(
            "Card "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. " carries "
                .. board.NEEDS_HUMAN
                .. " and keeps the owner's size. Only the owner sets it unsized."
        )
    end
    if color == board.SIZES.unsized and card.column ~= backend.stages.icebox then
        return failure(
            "Card "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. " is outside "
                .. backend.stages.icebox
                .. " and keeps a size. Move it to "
                .. backend.stages.icebox
                .. " first."
        )
    end
    local held = claims.read(card.id)
    local ok, message = backend:set_size(card.id, color, held and held.fence)
    if not ok then
        return failure(message)
    end
    return { output = "sized " .. card.id:sub(1, board.MIN_PREFIX) .. " " .. args[2]:lower() }
end

function commands.time(backend, args)
    local NOTE_FLAG = "--note"
    local clock = require("dev.board.clock")
    local flags, positional = parse(args, { [AS_FLAG] = true, [NOTE_FLAG] = true })
    if not flags then
        return positional
    end
    if clock.WORDS[positional[1]] then
        return clock.run(backend, positional, flags[AS_FLAG], flags[NOTE_FLAG], function(word)
            return find_card(backend, word)
        end)
    end
    if #positional ~= 2 then
        return usage("Needs a card and the minutes.")
    end
    local minutes = positional[2]:match("^%d+$") and tonumber(positional[2])
    if not minutes or minutes < 1 or minutes > clock.MAX_MINUTES then
        return usage("The minutes are a whole number from 1 to " .. clock.MAX_MINUTES .. ".")
    end
    local role = clock.role(flags[AS_FLAG])
    if not role then
        return usage("The " .. AS_FLAG .. " flag needs the role the time was logged in.")
    end
    local card, err = find_card(backend, positional[1])
    if not card then
        return err
    end
    local ok, message = backend:log_time(card.id, minutes, role, flags[NOTE_FLAG])
    if not ok then
        return failure(message)
    end
    return {
        output = "logged " .. minutes .. " minutes as " .. role .. " on " .. card.id:sub(
            1,
            board.MIN_PREFIX
        ),
    }
end

function commands.label(backend, args)
    local edits, removals = {}, {}
    local pos = 2
    while pos <= #args do
        local arg = args[pos]
        pos = pos + 1
        if arg == "--remove" then
            if pos > #args then
                return usage("The --remove flag needs a value.")
            end
            local ok, err = plain(args[pos])
            if not ok then
                return err
            end
            removals[#removals + 1] = { add = false, word = args[pos] }
            pos = pos + 1
        else
            local sign = arg:sub(1, 1)
            local word = (sign == "+" or sign == "-") and arg:sub(2) or arg
            local ok, err = plain(word)
            if not ok then
                return err
            end
            edits[#edits + 1] = { add = sign ~= "-", word = word }
        end
    end
    if #args < 1 or #edits + #removals == 0 then
        return usage("Needs a card and one or more labels to add or --remove label.")
    end
    for _, removal in ipairs(removals) do
        edits[#edits + 1] = removal
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local labels = {}
    for i, label in ipairs(card.labels) do
        labels[i] = label
    end
    for _, change in ipairs(edits) do
        if change.add and change.word == board.NEEDS_HUMAN then
            return failure(
                "Card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " cannot take "
                    .. board.NEEDS_HUMAN
                    .. " by label. Pomb locks the card and refuses the question after it."
                    .. " Run `dev board ask CARD --question TEXT --choice COLUMN=LABEL...` instead,"
                    .. " which posts the question and sets the label in one write."
            )
        end
        local denied = require("dev.standalone").label_problem(change.word)
        if change.add and denied then
            return failure(denied)
        end
        local at = index_of(labels, change.word)
        if change.add and not at then
            labels[#labels + 1] = change.word
        elseif not change.add and at then
            table.remove(labels, at)
        end
    end
    if table.concat(labels, "\0") ~= table.concat(card.labels, "\0") then
        local held = claims.read(card.id)
        local ok, message = backend:set_labels(card.id, labels, held and held.fence)
        if not ok then
            return failure(message)
        end
    end
    local shown = #labels > 0 and table.concat(labels, ",") or "-"
    return { output = "labelled " .. card.id:sub(1, board.MIN_PREFIX) .. " " .. shown }
end

local Owner = {}

---The closed list of what only the owner decides, by the key `ask --list` takes
local ASK_LISTS = { "secrets", "destroy", "spend", "restart", "taste" }

function commands.ask(backend, args)
    if #args < 1 then
        return usage(
            "Needs a card, --question TEXT, --choice COLUMN=LABEL, --recommend N, --why TEXT"
                .. " and --list KEY or --searched TEXT."
        )
    end
    local question = { choices = {} }
    local listed, searched
    local i = 2
    while i <= #args do
        local flag, value = args[i], args[i + 1]
        if not value then
            return usage("The " .. flag .. " flag needs a value.")
        end
        if flag == "--choice" then
            local column, label = value:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
            if not column or column == "" or label == "" then
                return usage("The --choice flag takes COLUMN=LABEL, not " .. value .. ".")
            end
            question.choices[#question.choices + 1] = { column = column, label = label }
        elseif flag == "--recommend" then
            if not value:match("^%d+$") then
                return usage("The --recommend flag takes a choice number, not " .. value .. ".")
            end
            question.recommended = tonumber(value)
        elseif flag == "--question" then
            question.text = value
        elseif flag == "--why" then
            question.why = value
        elseif flag == "--list" then
            if index_of(ASK_LISTS, value) == nil then
                return usage(
                    "The --list flag takes one of "
                        .. table.concat(ASK_LISTS, ", ")
                        .. ", not "
                        .. value
                        .. "."
                )
            end
            listed = value
        elseif flag == "--searched" then
            searched = value:match("%S") and value or nil
        else
            return usage("Unknown flag " .. flag .. ".")
        end
        i = i + 2
    end
    if not listed and not searched then
        return usage(
            "A question names the owner's list item with --list KEY"
                .. " or the precedent search it ran with --searched TEXT."
        )
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    if index_of(card.labels, board.NEEDS_HUMAN) then
        local answered, why = board_wait.commented(backend, card)
        if answered == nil then
            return failure(why)
        end
        if not answered then
            local short = card.id:sub(1, board.MIN_PREFIX)
            local label = board.NEEDS_HUMAN
            return failure(
                "Card "
                    .. short
                    .. " already carries "
                    .. label
                    .. " and its newest comment is not the owner's. `dev board ask` adds that"
                    .. " label itself. Run `dev board label "
                    .. short
                    .. " --remove "
                    .. label
                    .. "` and then ask again."
            )
        end
    end
    local missing = board.unplanned({
        color = card.color,
        description = card.description,
        outcomes = #card.outcomes,
        need_outcomes = not card.outcomes_unreadable,
        children = 0,
    })
    if #missing > 0 then
        return failure(
            "Card "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. " is not planned, and a question locks it against the edits that would plan it."
                .. " It lacks "
                .. table.concat(missing, ", ")
                .. ". Fix it with `dev board size`, `dev board edit` and `dev board outcome`,"
                .. " then ask again."
        )
    end
    local held = claims.read(card.id)
    local ok, message = backend:ask(card.id, question, held and held.fence)
    if not ok then
        return failure(message)
    end
    if held then
        claims.stop(card.id)
        local released, why, why_reason, why_detail = backend:release(card.id, held.fence)
        if not released then
            verb.note(
                "Asked, but the claim was not released. "
                    .. board.release_refusal(why_reason, why, why_detail, held.fence)
            )
        end
    end
    return { output = "asked " .. card.id:sub(1, board.MIN_PREFIX) }
end

function commands.answer(backend, args)
    local choice, quote_at
    if args[2] == "--choice" then
        choice = args[3]
        if args[4] == "--quote" then
            quote_at = 4
        end
    end
    if #args < 2 or not choice or not quote_at then
        return usage("Needs a card, --choice N and --quote TEXT.")
    end
    if not choice:match("^%d+$") or tonumber(choice) < 1 then
        return usage("The --choice flag counts from 1, not " .. choice .. ".")
    end
    local quote = table.concat(args, " ", quote_at + 1)
    if not quote:find("%S") then
        return usage("The --quote flag needs the owner's words.")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local prefix = card.id:sub(1, board.MIN_PREFIX)
    if not index_of(card.labels, board.NEEDS_HUMAN) then
        return failure(
            "Card " .. prefix .. " is not " .. board.NEEDS_HUMAN .. ". Nothing waits on an answer."
        )
    end
    local held = claims.read(card.id)
    local ok, message =
        backend:answer(card.id, tonumber(choice), quote:match("^%s*(.-)%s*$"), held and held.fence)
    if not ok then
        return failure(message)
    end
    return { output = "answered " .. prefix .. " with choice " .. choice }
end

function commands.escalate(backend, args)
    local asks = { ["--question"] = 1, ["--choice"] = 1, ["--recommend"] = 1, ["--why"] = 1 }
    local words = {}
    for index = 1, #args do
        local flag = args[index]:match("^(%-%-[%a-]+)")
        if asks[flag] then
            return usage(
                "Escalate takes a card and the note text, not "
                    .. flag
                    .. ", so put a question for the owner through dev board ask."
            )
        end
        if index > 1 then
            words[#words + 1] = args[index]
        end
    end
    local why = table.concat(words, " ")
    if #args < 2 or not why:find("%S") then
        return usage("Needs a card and the reason.")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local prefix = card.id:sub(1, board.MIN_PREFIX)
    if not index_of(card.labels, board.NEEDS_PLANNER) then
        return failure(
            "Card "
                .. prefix
                .. " is not "
                .. board.NEEDS_PLANNER
                .. ". There is nothing to escalate."
        )
    end
    if card.column ~= backend.stages.blocked then
        return failure(
            "Card "
                .. prefix
                .. " is in "
                .. tostring(card.column)
                .. ". A "
                .. board.NEEDS_PLANNER
                .. " card waits in Blocked, so move it there first."
        )
    end
    if board.reserved(why) then
        return failure(RESERVED_NOTE)
    end
    local held = claims.read(card.id)
    local fence = held and held.fence
    local ok, message = backend:escalate(card.id, "lead", why, fence)
    if not ok then
        return failure(message)
    end
    return { output = "escalated " .. prefix .. " to " .. board.NEEDS_LEAD }
end

---Past-tense verb reported for each outcome mode
local OUTCOME_SAID = {
    [OutcomeMode.DELETE] = "deleted",
    [OutcomeMode.RENAME] = "reworded",
    [OutcomeMode.TICK] = "ticked",
    [OutcomeMode.UNTICK] = "unticked",
}

local function outcome_number(word, count)
    local number = tonumber(word)
    if not word:match("^%d+$") or number < 1 then
        return nil, usage("Outcome numbers count from 1, not " .. word .. ".")
    end
    if number > count then
        return nil,
            failure(
                "The card has "
                    .. count
                    .. (count == 1 and " outcome" or " outcomes")
                    .. ". There is no outcome "
                    .. number
                    .. "."
            )
    end
    return number
end

local function has_outcome_flag(args)
    local word = outcome_word(args)
    return OUTCOME_FLAGS[word] ~= nil or word == CONVERT_FLAG
end

---Take `--as NAME` out of the words of an outcome form, wherever it sits.
---@param args string[] the card and the form's words
---@return string[]? rest the words without the flag, nil on a usage error
---@return string? name the name after the flag, nil when there is none
---@return dev.cmd.board.Result? err the usage error
local function split_ticker(args)
    if not has_outcome_flag(args) then
        return args
    end
    for i = 2, #args do
        if args[i] == AS_FLAG and args[i - 1] ~= REASON_FLAG then
            local name = args[i + 1]
            if not name then
                return nil, nil, usage("The " .. AS_FLAG .. " flag needs a name.")
            end
            local rest = {}
            for at, word in ipairs(args) do
                if at ~= i and at ~= i + 1 then
                    rest[#rest + 1] = word
                end
            end
            return rest, name
        end
    end
    return args
end

---Refuse an outcome change on a card in a column the board locks.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card whose outcomes change
---@param what string the change, as the refusal names it
---@return dev.cmd.board.Result? refusal nil when the card's outcomes may change
local function outcomes_locked_refusal(backend, card, what)
    local rows, why = backend:columns()
    if not rows then
        return unqueued(
            failure("Cannot read the board's columns to check its outcome lock: " .. tostring(why))
        )
    end
    local locked = require("dev.board.outcome_lock").refusal(rows, card.column, what)
    if locked then
        return unqueued(failure(locked))
    end
    return nil
end

local function convert_outcomes(backend, card, opts)
    local fence = opts.fence
    local prefix = card.id:sub(1, board.MIN_PREFIX)
    if #card.outcomes > 0 then
        return {
            output = "Outcomes of card " .. prefix .. " are left alone. It already has outcomes.",
        }
    end
    local items, rest = board.split_checklist(card.description)
    if not items then
        return {
            output = "Outcomes of card "
                .. prefix
                .. " are left alone. It has no Done when checklist.",
        }
    end
    local ticks = false
    for _, item in ipairs(items) do
        ticks = ticks or item.done
    end
    local refused, ticker
    if ticks then
        refused, ticker = guards.tick_refused(card, opts.flag)
    end
    if refused then
        return refused
    end
    for _, item in ipairs(items) do
        local ok, message = backend:add_outcome(card.id, item.name, fence)
        if not ok then
            return failure(message)
        end
    end
    local cards, why = backend:cards()
    if not cards then
        return failure(why)
    end
    local fresh = board.resolve(cards, card.id)
    if not fresh or #fresh.outcomes ~= #items then
        return failure("The outcomes were added but could not be read back to tick them.")
    end
    for i, item in ipairs(items) do
        if item.done then
            local ok, message =
                backend:set_outcome(card.id, fresh.outcomes[i].id, { done = true }, fence)
            if not ok then
                return failure(message)
            end
            if ticker then
                ok, message = backend:note(
                    card.id,
                    board.tick_record(ticker, i),
                    fence,
                    { kind = board.NoteKind.STATUS }
                )
                if not ok then
                    return failure(message)
                end
            end
        end
    end
    local ok, message = backend:set_description(card.id, rest, fence)
    if not ok then
        return failure(message)
    end
    return {
        output = "outcome "
            .. prefix
            .. " converted "
            .. #items
            .. (#items == 1 and " outcome" or " outcomes"),
    }
end

local function with_env_ticker(args)
    if OUTCOME_FLAGS[args[2]] ~= OutcomeMode.TICK then
        return args
    end
    for _, word in ipairs(args) do
        if word == AS_FLAG then
            return args
        end
    end
    local name = agent_name()
    if not name then
        return args
    end
    local with = {}
    for i, word in ipairs(args) do
        with[i] = word
    end
    with[#with + 1] = AS_FLAG
    with[#with + 1] = name
    return with
end

local function misplaced_outcome_form(args)
    local first = args[2]
    if first:sub(1, 2) == "--" then
        local flag, value = first:match("^(%-%-[^=]+)=(.*)$")
        if flag then
            return "The outcome text starts with "
                .. first
                .. ". Write the flag as "
                .. flag
                .. " "
                .. value
                .. "."
        end
        return "The outcome text starts with " .. first .. ", which is not an outcome flag."
    end
    local number
    for i = 2, #args do
        local word = args[i]
        if word:match("^%d+$") then
            number = number or word
        end
        local mode = OUTCOME_FLAGS[word]
        if mode or word == CONVERT_FLAG then
            if mode and number then
                return "Put the flag before the number: dev board outcome CARD "
                    .. word
                    .. " "
                    .. number
                    .. "."
            end
            return "The outcome text holds the flag "
                .. word
                .. ", which goes right after the card."
        end
    end
    local only = table.concat(args, " ", 2):match("^%s*(%d+)%s*$")
    if only then
        return "The outcome text is only a number. To tick it use dev board outcome CARD --tick "
            .. only
            .. "."
    end
end

function commands.outcome(backend, args)
    local ticker_flag
    local bad
    args, ticker_flag, bad = split_ticker(args)
    if not args then
        return bad
    end
    local foreign = guards.foreign_refusal(args[1], "outcome")
    if foreign then
        return foreign
    end
    if #args < 2 then
        return usage(
            "Needs a card and the outcome text, or --rename N TEXT --reason TEXT, "
                .. "--tick N, --untick N, --delete N --reason TEXT or --convert."
        )
    end
    local mode = OUTCOME_FLAGS[args[2]]
    local text, word, reason
    if args[2] == CONVERT_FLAG then
        if #args ~= 2 then
            return usage("The " .. CONVERT_FLAG .. " flag takes only the card.")
        end
        local card, err = find_card(backend, args[1])
        if not card then
            return err
        end
        local refused =
            guards.claimant_refused(backend, card, { what = "add its outcomes", as = ticker_flag })
        if refused then
            return refused
        end
        refused = outcomes_locked_refusal(backend, card, CONVERT_FLAG)
        if refused then
            return refused
        end
        local held = claims.read(card.id)
        return convert_outcomes(backend, card, { fence = held and held.fence, flag = ticker_flag })
    elseif not mode then
        local misplaced = misplaced_outcome_form(args)
        if misplaced then
            return usage(misplaced)
        end
        mode, text = OutcomeMode.ADD, table.concat(args, " ", 2)
    elseif mode == OutcomeMode.RENAME then
        if #args < 4 then
            return usage("The --rename flag needs an outcome number and the new text.")
        end
        local at
        for i = 5, #args do
            if args[i] == REASON_FLAG then
                at = i
                break
            end
        end
        if not at then
            return usage("The --rename flag needs " .. REASON_FLAG .. " TEXT.")
        end
        word, text = args[3], table.concat(args, " ", 4, at - 1)
        reason = table.concat(args, " ", at + 1)
        if not reason:find("%S") then
            return usage("The " .. REASON_FLAG .. " flag needs the reason.")
        end
    elseif mode == OutcomeMode.DELETE then
        if #args < 5 or args[4] ~= REASON_FLAG then
            return usage(
                "The "
                    .. DELETE_FLAG
                    .. " flag needs an outcome number and "
                    .. REASON_FLAG
                    .. " TEXT."
            )
        end
        word, text = args[3], table.concat(args, " ", 5)
        if not text:find("%S") then
            return usage("The " .. REASON_FLAG .. " flag needs the reason.")
        end
        local agent = os.getenv("DEV_AGENT") or ""
        if not guards.is_lead(agent) then
            return failure(
                "Only the lead deletes an outcome. DEV_AGENT "
                    .. agent
                    .. " is not a lead name, whose role segment is lead, and a name with no slash"
                    .. " counts as the lead only at a terminal. "
                    .. "Ask the lead, with the card, the number and the reason."
            )
        end
    else
        if #args ~= 3 then
            return usage("The " .. args[2] .. " flag needs one outcome number.")
        end
        word = args[3]
    end
    if text and not text:find("%S") then
        return usage("The outcome text is empty.")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local ticker
    if mode == OutcomeMode.ADD or mode == OutcomeMode.RENAME or mode == OutcomeMode.DELETE then
        local refused = guards.claimant_refused(
            backend,
            card,
            { what = mode .. " its outcomes", as = ticker_flag }
        )
        if refused then
            return refused
        end
        refused = outcomes_locked_refusal(
            backend,
            card,
            mode == OutcomeMode.ADD and "adding an outcome" or mode
        )
        if refused then
            return refused
        end
    elseif mode == OutcomeMode.TICK then
        local refused
        refused, ticker = guards.tick_refused(card, ticker_flag)
        if refused then
            return refused
        end
    end
    local held = claims.read(card.id)
    local fence = held and held.fence
    local prefix = card.id:sub(1, board.MIN_PREFIX)
    local ok, message
    if mode == OutcomeMode.ADD then
        ok, message = backend:add_outcome(card.id, text, fence)
        if not ok then
            return failure(message)
        end
        return {
            output = "outcome " .. prefix .. " " .. (#card.outcomes + 1) .. " added",
            warnings = board.prose_warnings(text),
        }
    end
    local number
    number, err = outcome_number(word, #card.outcomes)
    if not number then
        return err
    end
    if mode == OutcomeMode.DELETE then
        local row = card.outcomes[number]
        local deleted_text = row.name
        ok, message = backend:delete_outcome(card.id, row.id, fence)
        if not ok then
            return unqueued(failure(message))
        end
        local body = "Deleted outcome " .. number .. ": " .. deleted_text .. " Reason: " .. text
        ok, message = backend:note(card.id, body, fence, { kind = board.NoteKind.DECISION })
        if not ok then
            return unqueued(
                failure(
                    "Outcome "
                        .. prefix
                        .. " "
                        .. number
                        .. " was deleted, but the note failed. "
                        .. message
                        .. ' Its text was "'
                        .. deleted_text
                        .. '". Its reason was "'
                        .. text
                        .. '".'
                )
            )
        end
        return { output = "outcome " .. prefix .. " " .. number .. " deleted" }
    end
    local fields = { name = text }
    if mode ~= OutcomeMode.RENAME then
        fields = { done = mode == OutcomeMode.TICK }
    end
    local old_text = card.outcomes[number].name
    ok, message = backend:set_outcome(card.id, card.outcomes[number].id, fields, fence)
    if not ok then
        return failure(message)
    end
    if mode == OutcomeMode.TICK and ticker then
        ok, message = backend:note(
            card.id,
            board.tick_record(ticker, number),
            fence,
            { kind = board.NoteKind.STATUS }
        )
        if not ok then
            return unqueued(
                failure(
                    "Outcome "
                        .. prefix
                        .. " "
                        .. number
                        .. " was ticked, but its tick record failed. "
                        .. message
                )
            )
        end
    end
    if mode == OutcomeMode.RENAME then
        local body = "Renamed outcome "
            .. number
            .. " from: "
            .. old_text
            .. " to: "
            .. text
            .. " Reason: "
            .. reason
        ok, message = backend:note(card.id, body, fence, { kind = board.NoteKind.DECISION })
        if not ok then
            return unqueued(
                failure(
                    "Outcome "
                        .. prefix
                        .. " "
                        .. number
                        .. " was renamed, but the note failed. "
                        .. message
                        .. ' Its old text was "'
                        .. old_text
                        .. '". Its reason was "'
                        .. reason
                        .. '".'
                )
            )
        end
    end
    local result = { output = "outcome " .. prefix .. " " .. number .. " " .. OUTCOME_SAID[mode] }
    if mode == OutcomeMode.TICK and ticker then
        result.output = result.output .. " by " .. ticker
    end
    local stages = backend.stages or board.stages()
    if mode == OutcomeMode.TICK and card.column == stages.review then
        local open = false
        for i, outcome in ipairs(card.outcomes) do
            open = open or (i ~= number and not outcome.done)
        end
        if not open then
            local moved, why, refusal = backend:move(card.id, stages.verify, { fence = fence })
            if not moved then
                return failure(
                    result.output
                        .. ", but the move to Verify failed. "
                        .. board.move_refusal(refusal, why, stages.verify)
                )
            end
            result.output = result.output .. "\nmoved " .. prefix .. " to " .. stages.verify
        end
    end
    if text then
        result.warnings = board.prose_warnings(text)
    end
    return result
end

function commands.edit(backend, args)
    local home, rest, refused = guards.on_board(backend, args)
    if not home then
        return refused
    end
    backend, args = home, rest
    if #args ~= 2 then
        return usage("Needs a card and the new description.")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local held_back = owner_holds(card)
    if held_back then
        return held_back
    end
    local rendered = board.rendered_blocks(args[2])
    if rendered then
        return failure(
            "The text holds the rendered line `"
                .. rendered
                .. "`. The outcomes and checks have their own verbs, `dev board outcome`"
                .. " and `dev board checks`."
        )
    end
    if card.column ~= backend.stages.icebox then
        local missing = board.backlog_missing(args[2])
        if #missing > 0 then
            return failure(
                "Card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " is outside "
                    .. backend.stages.icebox
                    .. " and keeps card format v3. That text lacks "
                    .. table.concat(missing, ", ")
                    .. "."
            )
        end
    end
    local held = claims.read(card.id)
    local ok, message = backend:set_description(card.id, args[2], held and held.fence)
    if not ok then
        return failure(message)
    end
    return {
        output = "edited " .. card.id:sub(1, board.MIN_PREFIX),
        warnings = board.prose_warnings(args[2]),
    }
end

function commands.rename(backend, args)
    if #args < 2 then
        return usage("Needs a card and the new title.")
    end
    for pos = 2, #args do
        if args[pos]:sub(1, 1) == "-" then
            return usage("Unknown flag " .. args[pos] .. ".")
        end
    end
    local name = table.concat(args, " ", 2)
    if
        not name:find("%S")
        or #name > board_setup.NAME_CHARS
        or not name:find(board_setup.NAME_PATTERN)
    then
        return usage(
            "A title is one line of up to "
                .. board_setup.NAME_CHARS
                .. " characters, with no quotes or backslashes."
        )
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err.unresolved and usage(err.message) or err
    end
    local held_back = owner_holds(card)
    if held_back then
        return held_back
    end
    local held = claims.read(card.id)
    local ok, message = backend:set_name(card.id, name, held and held.fence)
    if not ok then
        return failure(message)
    end
    return { output = "renamed " .. card.id:sub(1, board.MIN_PREFIX) }
end

---Find a card and replace one of its custom fields under its claim's fence.
---@param backend dev.board.Backend the board
---@param ref string the card
---@param key string the field's key
---@param write fun(id: string, fence: integer?): boolean?, string? the write to send
---@return dev.board.Card? card the card, nil on failure
---@return string|dev.cmd.board.Result? short the card's short id, or the failure
local function write_field(backend, ref, key, write)
    local card, err = find_card(backend, ref)
    if not card then
        return nil, err
    end
    local why, problem = named_field_problem(backend, key)
    if problem then
        return nil, problem
    end
    if why then
        return nil, failure(why)
    end
    local held = claims.read(card.id)
    local ok, message = write(card.id, held and held.fence)
    if not ok then
        return nil, failure(message)
    end
    return card, card.id:sub(1, board.MIN_PREFIX)
end

function commands.checks(backend, args)
    if #args < 2 then
        return usage("Needs a card and one or more commands to run as its checks.")
    end
    for pos = 2, #args do
        if not args[pos]:find("%S") then
            return usage("A check needs a command.")
        end
    end
    local runs = {}
    for pos = 2, #args do
        runs[#runs + 1] = args[pos]
    end
    local refused_row = guards.row_refusal(runs, backend.root)
    if refused_row then
        return refused_row
    end
    local found, err = find_card(backend, args[1])
    if not found then
        return err
    end
    local refused = guards.claimant_refused(backend, found, { what = "change its checks" })
    if refused then
        return refused
    end
    local card, short = write_field(backend, args[1], board.CHECKS_FIELD, function(id, fence)
        return backend:set_checks(id, runs, fence)
    end)
    if not card then
        return short
    end
    return { output = "set checks " .. short .. ", " .. dev_text.count(#runs, "row") }
end

function commands.check(backend, args)
    local opts, err = wiring.check_options(backend.root, args)
    if not opts then
        return err
    end
    local card
    card, err = find_card(backend, opts.words[1])
    if not card then
        return err
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    local elsewhere = guards.workspace_refusal(backend, short)
    if elsewhere then
        return elsewhere
    end
    if #card.checks == 0 then
        return failure("Card " .. short .. " has no checks rows. Set them with `dev board checks`.")
    end
    local argvs = {}
    for i, run in ipairs(card.checks) do
        local argv, why = check.argv(run)
        if not argv then
            return failure(
                "Row " .. i .. " of the checks of card " .. short .. " cannot run. " .. why
            )
        end
        argvs[i] = argv
    end
    if not backend.root then
        return failure("`dev board check` needs the project's root.")
    end
    local before, message = check.state(backend.root)
    if not before then
        return failure(message)
    end
    local empty = not opts.expect_fail and check.empty_refusal(backend.root)
    if empty then
        return failure(empty)
    end
    return wiring.check_rows({
        name = agent_name(),
        backend = backend,
        card = card,
        before = before,
        argvs = argvs,
        options = opts,
    })
end

function commands.review(backend, args)
    local flags, words = parse(args, {
        [KIND_FLAG] = true,
        [BY_FLAG] = true,
        [REV_FLAG] = true,
        [review.VERDICT_FLAG] = true,
        [review.OF_FLAG] = true,
    })
    if not flags then
        return words
    end
    if #words ~= 1 then
        return usage("Needs a card.")
    end
    for _, flag in ipairs({ KIND_FLAG, BY_FLAG, REV_FLAG, review.VERDICT_FLAG }) do
        if not flags[flag] then
            return usage("Needs " .. flag .. ".")
        end
    end
    local kind = flags[KIND_FLAG]
    if not index_of(review.KINDS, kind) then
        return usage(
            "Unknown kind " .. kind .. ". The kinds are " .. table.concat(review.KINDS, ", ") .. "."
        )
    end
    local of = flags[review.OF_FLAG]
    if kind == review.Kind.RECHECK then
        if not of or not index_of(review.OF_KINDS, of) then
            return usage(
                "A recheck needs "
                    .. review.OF_FLAG
                    .. " "
                    .. table.concat(review.OF_KINDS, "|")
                    .. "."
            )
        end
    elseif of then
        return usage("The " .. review.OF_FLAG .. " flag goes only with --kind recheck.")
    end
    local verdict = flags[review.VERDICT_FLAG]
    if not index_of(review.VERDICTS, verdict) then
        return usage(
            "Unknown verdict "
                .. verdict
                .. ". The verdicts are "
                .. table.concat(review.VERDICTS, ", ")
                .. "."
        )
    end
    local by, why = agent_name(flags[BY_FLAG])
    if not by then
        return why
    end
    local named = agent_name()
    if named and named ~= by then
        return failure(
            string.format(
                "%s cannot record a review by %s. A review is recorded under the caller's own name.",
                named,
                by
            )
        )
    end
    local card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    local caller = named or claimant()
    local past, comments_why = backend:comments(card.id)
    if not past then
        return failure(comments_why)
    end
    local claimed = board.claimants(past)
    local owner = card.claimant
    for _, name in ipairs({ by, caller }) do
        if name == owner or claimed[name] then
            return failure(
                string.format(
                    "Card %s %s claimed by %s. %s cannot review its own change.",
                    short,
                    name == owner and "is" or "was",
                    name,
                    name
                )
                    .. " A reviewer other than "
                    .. name
                    .. " must record it."
            )
        end
    end
    if not backend.root then
        return failure("`dev board review` needs the project's root.")
    end
    local rev, message = review.resolve(backend.root, flags[REV_FLAG])
    if not rev then
        return failure(message)
    end
    local recorded
    for _, comment in ipairs(past) do
        local record = review.parse(comment.body) or check.parse(comment.body)
        if record and record.mode ~= check.Mode.EXPECT_FAIL then
            recorded = record.change
        end
    end
    if
        recorded
        and recorded ~= rev.change
        and recorded ~= review.NO_CHANGE
        and rev.change ~= review.NO_CHANGE
    then
        return failure(
            string.format(
                "Card %s records change %s but this commit is change %s. Run `dev board review` from the change's workspace, or run `dev board check` at this commit first to re-point the card.",
                short,
                recorded,
                rev.change
            )
        )
    end
    local ok
    local warnings
    local seat_note = ""
    if backend.seat_verdict then
        local refusal
        ok, message, refusal =
            backend:seat_verdict(card.id, kind, by, review.SEAT_VERDICTS[verdict], rev.commit)
        if
            not ok
            and kind == review.Kind.RECHECK
            and (message or ""):find(SEAT_HELD_CODE, 1, true)
        then
            seat_note = "\nThe recheck seat is already held, so only the card records this review."
        elseif not ok then
            local detail = board.seat_refusal(refusal, message, kind)
            warnings = {
                string.format(
                    "The %s seat of card %s was NOT set, so Pomb holds no seat verdict for this review. %s The review is still recorded on the card.",
                    kind,
                    short,
                    detail
                ),
            }
        end
    end
    local held = claims.read(card.id)
    ok, message = backend:note(
        card.id,
        review.record(kind, by, rev, verdict, of),
        held and held.fence,
        { kind = board.NoteKind.STATUS }
    )
    if not ok then
        return failure(
            string.format(
                "The review was NOT recorded on card %s. %s The board may or may not hold it. Read `dev board notes` before repeating it.",
                short,
                message
            )
        )
    end
    return {
        output = string.format(
            "recorded %s review by %s on %s at commit %s%s",
            kind,
            by,
            short,
            rev.commit:sub(1, COMMIT_CHARS),
            seat_note
        ),
        warnings = warnings,
    }
end

---Delete the card's bookmark or branch and remove its workspace.
---@param root string absolute path of the workspace dev runs in
---@param short string the card's short id, which names both
---@return string lines what was deleted, removed or kept, each on its own line
function M.clean_up(root, short)
    local ws = require("dev.cmd.ws")
    local kind = vcs.backend(root)
    local lines = {}
    local function add(line)
        lines[#lines + 1] = line
    end
    local function delete_branch_from(from)
        local deleted, why = vcs.delete_branch(from, kind, short)
        if deleted then
            add("Deleted " .. (kind == vcs.JJ and "bookmark " or "branch ") .. short)
        elseif deleted == nil then
            add("Kept " .. short .. ". " .. why)
        end
    end
    local main = root
    if kind == vcs.GIT then
        local argv = vcs.with(
            vcs.base(root, kind),
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir"
        )
        local out, code = dev_os.capture(argv, { stderr = "null" })
        if code == 0 then
            main = out:gsub("\n$", ""):gsub("/%.git$", "")
        end
    else
        dev_os.capture(
            vcs.with(vcs.base(root, kind, { quiet = true }), "workspace", "update-stale"),
            { stderr = "null" }
        )
        delete_branch_from(root)
    end
    local result = ws.remove(root, short, { inside = true })
    if result.ok then
        add(result.message)
        for _, line in ipairs(result.purged) do
            add(line)
        end
        add("The workspace is gone. Run the next command from another folder.")
        if kind == vcs.GIT then
            delete_branch_from(main)
        end
    else
        local reason = ws.describe(result)
        if result.path and not reason:find(result.path, 1, true) then
            reason = reason .. " The workspace is at " .. result.path .. "."
        end
        add("Kept the workspace. " .. reason)
    end
    return "\n" .. table.concat(lines, "\n")
end

---@class dev.cmd.board.companion_cards.Opts
---@field backend dev.board.Backend the board
---@field words string[] the card words, the first of which names the workspace's card
---@field primary dev.board.Card the card the first word names
---@field name string the caller's agent name

---Read the other cards that land with the first one, each held to the same early rules.
---@param opts dev.cmd.board.companion_cards.Opts the board, the words and the caller
---@return dev.board.Card[]? cards the other cards, nil on a refusal
---@return dev.cmd.board.Result? err the refusal
local function companion_cards(opts)
    local backend, words, primary, name = opts.backend, opts.words, opts.primary, opts.name
    local cards = {}
    local seen = { [primary.id] = true }
    for i = 2, #words do
        local card, err = find_card(backend, words[i])
        if not card then
            return nil, err
        end
        local short = card.id:sub(1, board.MIN_PREFIX)
        if seen[card.id] then
            return nil, usage("Names card " .. short .. " twice.")
        end
        seen[card.id] = true
        local held_back = owner_holds(card)
        if held_back then
            return nil, held_back
        end
        local list, message = backend:comments(card.id)
        if not list then
            return nil, failure(message)
        end
        local early = wiring.card_problems(backend, card, { name = name, comments = list })
        if #early > 0 then
            return nil,
                failure(
                    "Card "
                        .. short
                        .. " cannot land with the others for these reasons.\n  - "
                        .. table.concat(early, "\n  - ")
                )
        end
        cards[#cards + 1] = card
    end
    return cards
end

function commands.land(backend, args)
    local flags, words = parse(args, { [WAIT_FLAG] = true, [IGNORE_CHANGE_RUN_FLAG] = true })
    if not flags then
        return words
    end
    if #words < 1 then
        return usage("Needs a card.")
    end
    local wait, bad_wait = wait_seconds(flags)
    if not wait then
        return bad_wait
    end
    local ignore = flags[IGNORE_CHANGE_RUN_FLAG]
    if ignore and not ignore:find("%S") then
        return usage("The " .. IGNORE_CHANGE_RUN_FLAG .. " flag needs a reason.")
    end
    local name, why = agent_name()
    if why then
        return why
    end
    if not name then
        return usage("Needs DEV_AGENT, the name that lands the card.")
    end
    local legacy = guards.stage_refusal(backend)
    if legacy then
        return legacy
    end
    local card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    local elsewhere = guards.workspace_refusal(backend, short)
    if elsewhere then
        return elsewhere
    end
    local held_back = owner_holds(card)
    if held_back then
        return held_back
    end
    if not backend.root then
        return failure("`dev board land` needs the project's root.")
    end
    local own = config.get(backend.root, "board.land.verb")
    if type(own) == "string" and own ~= "" then
        return failure(
            string.format(
                "This repo lands cards with `%s`, so `dev board land` refuses to land card %s. "
                    .. "Run `%s` instead.",
                own,
                short,
                own
            )
        )
    end
    local list, message = backend:comments(card.id)
    if not list then
        return failure(message)
    end
    local early = wiring.card_problems(backend, card, { name = name, comments = list })
    if #early > 0 then
        local all = wiring.land_problems(
            backend,
            card,
            { name = name, comments = list, ignore_change_run = ignore }
        )
        local kept = turn.held(backend, name, short)
        return failure(
            "Card "
                .. short
                .. " cannot land for these reasons.\n  - "
                .. table.concat(all, "\n  - ")
                .. (kept and wiring.kept_note(short) or "")
        )
    end
    local _, empty = land.state(backend.root)
    if #words == 1 and (vcs.backend(backend.root) == vcs.GIT or empty) then
        local settled = wiring.settle({
            backend = backend,
            card = card,
            comments = list,
            name = name,
            empty = empty,
            move = function(home, move_words)
                return move_card(home, move_words, { landed = true })
            end,
            clean_up = M.clean_up,
        })
        if settled then
            return settled
        end
    end
    local companions, companion_err = companion_cards({
        backend = backend,
        words = words,
        primary = card,
        name = name,
    })
    if not companions then
        return companion_err
    end
    local hold, lost
    hold, message, lost = turn.held(backend, name, short)
    if lost then
        local claimed, claim_message = turn.claimed(backend, name, short)
        if claim_message then
            return failure("Card " .. short .. " cannot land. " .. claim_message)
        end
        if claimed then
            hold, message = claimed, nil
        end
    end
    if lost and wait > 0 and not hold then
        message = nil
    end
    if message then
        return failure("Card " .. short .. " cannot land. " .. message)
    end
    local held_early = hold
    local main = config.get(backend.root, "board.land.deploys") ~= true
        and follow.main(backend.root)
    for _ = 1, MAX_LAND_ATTEMPTS do
        local current
        current, message = find_card(backend, words[1])
        if not current then
            return message
        end
        local refused, prepared = wiring.land_prepare({
            backend = backend,
            card = current,
            companions = companions,
            name = name,
            hold = held_early,
            ignore_change_run = ignore,
        })
        if refused then
            if held_early and refused.code and not refused.lost then
                refused.message = refused.message .. wiring.kept_note(short)
                return refused
            end
            if held_early then
                turn.release(backend, held_early)
            end
            return refused
        end
        hold = held_early
        if not hold then
            hold, message = wiring.await_turn({
                backend = backend,
                name = name,
                id = card.id,
                short = short,
                wait = wait,
            })
        end
        if not hold then
            return failure("Card " .. short .. " cannot land. " .. message)
        end
        current, message = find_card(backend, words[1])
        if not current then
            if not hold.hold then
                turn.release(backend, hold)
            end
            return message
        end
        local result = wiring.land_held({
            backend = backend,
            card = current,
            name = name,
            hold = hold,
            prepared = prepared,
            move = function(home, move_words)
                return move_card(home, move_words, { landed = true })
            end,
            clean_up = M.clean_up,
        })
        if not result.moved then
            if hold.hold and result.code and not result.landed and not result.lost then
                result.message = result.message .. wiring.kept_note(short)
                return result
            end
            turn.release(backend, hold)
            if main and not result.code then
                result.output = result.output .. "\n" .. follow.launch(main)
            end
            return result
        end
        if not hold.hold then
            turn.release(backend, hold)
        end
        verb.note("Trunk moved while the card was rechecked. Rebasing and rechecking again.")
    end
    return failure(
        "Card "
            .. short
            .. " cannot land. Trunk moved during each of "
            .. MAX_LAND_ATTEMPTS
            .. " rechecks. Nothing was pushed."
            .. (held_early and wiring.kept_note(short) or "")
    )
end

function commands.ship(backend, args)
    return ship.ship(backend, args, {
        move_card = move_card,
        outcome = commands.outcome,
        count_text = dev_text.count,
    })
end

function commands.turn(backend, args)
    local HOLD_FLAG = "--hold"
    local RELEASE_FLAG = "--release"
    local releasing = false
    local rest = {}
    for _, arg in ipairs(args) do
        if arg == RELEASE_FLAG then
            releasing = true
        else
            rest[#rest + 1] = arg
        end
    end
    local flags, words = parse(rest, { [HOLD_FLAG] = true, [WAIT_FLAG] = true })
    if not flags then
        return words
    end
    if #words ~= 1 then
        return usage("Name the one card to take the landing turn for.")
    end
    local seconds = turn.HOLD_SECONDS
    if flags[HOLD_FLAG] then
        seconds = flags[HOLD_FLAG]:match("^%d+$") and tonumber(flags[HOLD_FLAG])
        if not seconds or seconds < 1 or seconds > turn.MAX_HOLD_SECONDS then
            return usage(
                "The "
                    .. HOLD_FLAG
                    .. " flag needs a whole number of seconds up to "
                    .. turn.MAX_HOLD_SECONDS
                    .. "."
            )
        end
    end
    local wait, bad_wait = wait_seconds(flags)
    if not wait then
        return bad_wait
    end
    local name, why = agent_name()
    if why then
        return why
    end
    if not name then
        return usage("Set `DEV_AGENT` to the name that holds the turn.")
    end
    local card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    if not releasing then
        local elsewhere = guards.workspace_refusal(backend, short)
        if elsewhere then
            return elsewhere
        end
    end
    local hold, message, lost = turn.held(backend, name, short)
    if releasing then
        if message and not lost then
            return failure(message)
        end
        local claimed, claim_message
        if not hold then
            claimed, claim_message = turn.claimed(backend, name, short)
        end
        if claim_message then
            return failure(claim_message)
        end
        hold = hold or claimed
        if not hold and message then
            turn.leave(backend, name, short)
            return { output = "The landing turn held for " .. short .. " was already gone." }
        end
        if not hold then
            turn.leave(backend, name, short)
            return failure("Agent " .. name .. " holds no landing turn for card " .. short .. ".")
        end
        local released, reason = turn.release(backend, hold)
        if not released then
            return failure(reason)
        end
        return { output = "Gave back the landing turn held for " .. short .. "." }
    end
    if message and not lost then
        return failure(message)
    end
    if card.done then
        return failure("Card " .. short .. " is done. There is nothing to land.")
    end
    if hold then
        local renewed, capped, kept
        renewed, message, capped, kept = turn.extend(backend, hold, seconds)
        if capped then
            turn.release(backend, hold)
            return failure(message)
        end
        if kept then
            return failure(message)
        end
        if renewed then
            return {
                output = string.format(
                    "Renewed the landing turn held for %s for %d more seconds.",
                    short,
                    seconds
                ),
            }
        end
        if turn.held(backend, name, short) then
            return failure(message)
        end
    end
    hold, message = wiring.await_turn({
        backend = backend,
        name = name,
        id = card.id,
        short = short,
        wait = wait,
        take = { hold = true, seconds = seconds },
    })
    if not hold then
        return failure("Card " .. short .. " cannot take the landing turn. " .. message)
    end
    return {
        output = string.format(
            "Holding the landing turn for %s for %d seconds. Rebase, then run `dev board land %s`, which lands under it. Run `dev board turn %s` again to renew it, or add `--release` to give it back.",
            short,
            seconds,
            short,
            short
        ),
    }
end

---Read the words of an allow command.
---@param args string[] the card and the words
---@return string[]? words the words to set, empty with none
---@return boolean|dev.cmd.board.Result none whether the field is cleared, or the failure
local function parse_allow(args)
    if #args < 2 then
        return nil,
            usage(
                "Needs a card and one or more of "
                    .. table.concat(board.ALLOW_WORDS, ", ")
                    .. " or "
                    .. board.ALLOW_NONE
                    .. "."
            )
    end
    local words = {}
    local seen = {}
    local none = false
    for pos = 2, #args do
        local word = args[pos]
        if word == board.ALLOW_NONE then
            none = true
        elseif not index_of(board.ALLOW_WORDS, word) then
            return nil,
                usage(
                    "Unknown allow word "
                        .. word
                        .. ". The words are "
                        .. table.concat(board.ALLOW_WORDS, ", ")
                        .. " and "
                        .. board.ALLOW_NONE
                        .. "."
                )
        elseif not seen[word] then
            seen[word] = true
            words[#words + 1] = word
        end
    end
    if none and #args > 2 then
        return nil,
            usage(
                "The word "
                    .. board.ALLOW_NONE
                    .. " clears the allow field and takes no other word."
            )
    end
    return words, none
end

---Find a card and refuse the change when its claim bars the caller.
---@param backend dev.board.Backend the board
---@param ref string the card
---@param what string the change refused, for the message
---@return dev.cmd.board.Result? err the failure or refusal, nil when the caller may change the card
local function claim_refused(backend, ref, what)
    local found, err = find_card(backend, ref)
    if not found then
        return err
    end
    return guards.claimant_refused(backend, found, { what = what })
end

function commands.allow(backend, args)
    local words, none = parse_allow(args)
    if not words then
        return none
    end
    local refused = claim_refused(backend, args[1], "change its allow field")
    if refused then
        return refused
    end
    local card, short = write_field(backend, args[1], board.ALLOW_FIELD, function(id, fence)
        return backend:set_field(id, board.ALLOW_FIELD, none and json.null or words, fence)
    end)
    if not card then
        return short
    end
    if none then
        return { output = "cleared allow " .. short }
    end
    return { output = "set allow " .. short .. ", " .. table.concat(words, " ") }
end

---Replace a card's multiline name field with one name per line.
---@param backend dev.board.Backend the board
---@param args string[] the card and the names
---@param key string the field's key
---@param noun string what a name is, for the messages
---@return dev.cmd.board.Result result the output, or a message and the exit code
local function set_names(backend, args, key, noun)
    if #args < 2 then
        return usage("Needs a card and one or more " .. noun .. " names.")
    end
    for pos = 2, #args do
        if not args[pos]:find("%S") or args[pos]:find("%c") then
            return usage("A " .. noun .. " name must be one line of text.")
        end
    end
    local names = {}
    for pos = 2, #args do
        names[#names + 1] = args[pos]
    end
    local refused = claim_refused(backend, args[1], "change its " .. noun .. "s")
    if refused then
        return refused
    end
    local card, short = write_field(backend, args[1], key, function(id, fence)
        return backend:set_field(id, key, table.concat(names, "\n"), fence)
    end)
    if not card then
        return short
    end
    return { output = "set " .. noun .. "s " .. short .. ", " .. dev_text.count(#names, "name") }
end

function commands.tests(backend, args)
    return set_names(backend, args, board.TESTS_FIELD, "test")
end

function commands.files(backend, args)
    return set_names(backend, args, board.FILES_FIELD, "file")
end

local function link_rows(list)
    local rows = {}
    for _, link in ipairs(list) do
        rows[#rows + 1] = { link.kind, link.id:sub(1, board.MIN_PREFIX), link.board or "-" }
    end
    return table.concat(board.table_lines(rows), "\n")
end

local function link_ends(backend, args)
    if #args ~= 3 then
        return nil,
            nil,
            nil,
            usage("Needs a card, a kind (" .. LINK_HELP .. ") and the other card.")
    end
    if not index_of(board.LINK_KINDS, args[2]) then
        return nil,
            nil,
            nil,
            usage("Unknown link kind " .. args[2] .. ". The kinds are " .. LINK_HELP .. ".")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return nil, nil, nil, err
    end
    local other, shown
    other, shown, err = other_card(backend, args[3])
    if not other then
        return nil, nil, nil, err
    end
    return card, other, shown
end

function commands.link(backend, args)
    local card, other, shown, err = link_ends(backend, args)
    if not card then
        return err
    end
    if args[2] == board.LinkKind.PARENT and other.kind ~= board.Kind.EPIC then
        local prefix = other.id:sub(1, board.MIN_PREFIX)
        return failure(
            "Card "
                .. shown
                .. " is not an epic. Make it one with `dev board epic "
                .. prefix
                .. "`"
                .. (shown == prefix and "" or " from the project that owns that board")
                .. "."
        )
    end
    local ok, message = backend:link(card.id, args[2], other.id)
    if not ok then
        return failure(message)
    end
    return {
        output = "linked " .. card.id:sub(1, board.MIN_PREFIX) .. " " .. args[2] .. " " .. shown,
    }
end

function commands.epic(backend, args)
    if #args ~= 1 then
        return usage("Needs a card.")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local held = claims.read(card.id)
    local ok, message = backend:make_epic(card.id, held and held.fence)
    if not ok then
        return failure(message)
    end
    return { output = "made " .. card.id:sub(1, board.MIN_PREFIX) .. " an epic" }
end

function commands.responsible(backend, args)
    local flags, words = parse(args, { ["--clear"] = SWITCH })
    if not flags then
        return words
    end
    if #words < 1 or #words > 2 or (flags["--clear"] and #words ~= 1) then
        return usage("Needs a card, and a session name or --clear to change it.")
    end
    local card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    if #words == 1 and not flags["--clear"] then
        return { output = short .. " " .. (card.responsible or "none") }
    end
    local name = words[2]
    if name and not name:find("%S") then
        return usage("A session name needs text.")
    end
    local held = claims.read(card.id)
    local ok, message = backend:set_responsible(card.id, name, held and held.fence)
    if not ok then
        return failure(message)
    end
    if name then
        return { output = "set " .. short .. " responsible " .. name }
    end
    return { output = "cleared " .. short .. " responsible" }
end

---Tell whether a word is a real calendar date written `YYYY-MM-DD`.
---@param word string the word to test
---@return boolean valid whether the word names a date that exists
local function calendar_date(word)
    local year, month, day = word:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not year then
        return false
    end
    local at =
        os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 })
    return at ~= nil and os.date("%Y-%m-%d", at) == word
end

function commands.due(backend, args)
    local flags, words = parse(args, { ["--clear"] = SWITCH })
    if not flags then
        return words
    end
    if
        #words < 1
        or #words > 2
        or (flags["--clear"] and #words ~= 1)
        or (#words == 1 and not flags["--clear"])
    then
        return usage("Needs a card, and a YYYY-MM-DD date or --clear.")
    end
    local date = words[2]
    if date and not calendar_date(date) then
        return usage("The date is written YYYY-MM-DD and must exist.")
    end
    local card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    local held = claims.read(card.id)
    local ok, message = backend:set_due(card.id, date, held and held.fence)
    if not ok then
        return failure(message)
    end
    if date then
        return { output = "set " .. short .. " due " .. date }
    end
    return { output = "cleared " .. short .. " due" }
end

function commands.delete(backend, args)
    local flags, words = parse(args, { ["--reason"] = true })
    if not flags then
        return words
    end
    local reason = flags["--reason"]
    if #words ~= 1 or reason == nil or reason:find("^%s*$") then
        return usage("Needs a card and --reason TEXT.")
    end
    if guards.delete_refusal() == guards.Refusal.NOT_LEAD then
        return failure(not_lead_message())
    end
    if not backend.bin then
        return failure(NO_BIN)
    end
    local text = "the lead deletes this card, reason: " .. reason
    if board.reserved(text) then
        return failure(RESERVED_NOTE)
    end
    local card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    local ok, message = backend:note(card.id, text, nil, { kind = board.NoteKind.DECISION })
    if not ok then
        return failure(message)
    end
    ok, message = backend:bin(card.id)
    if not ok then
        return failure(message)
    end
    return { output = "moved " .. card.id:sub(1, board.MIN_PREFIX) .. " to the bin" }
end

function commands.restore(backend, args)
    if #args ~= 1 then
        return usage("Needs a card.")
    end
    if not backend.restore then
        return failure(NO_RESTORE)
    end
    local binned, message = backend:binned()
    if not binned then
        return failure(message)
    end
    local item, why = board.resolve(binned, args[1], "card in the bin")
    if not item then
        return failure(why)
    end
    local column
    column, message = backend:restore(item.id)
    if not column then
        return failure(message)
    end
    return {
        output = "restored "
            .. item.id:sub(1, board.MIN_PREFIX)
            .. " to "
            .. column
            .. ". The links the delete dropped stay dropped. Add them again with `dev board link`.",
    }
end

function commands.unlink(backend, args)
    local card, other, shown, err = link_ends(backend, args)
    if not card then
        return err
    end
    local list, message = backend:links(card.id)
    if not list then
        return failure(message)
    end
    for _, link in ipairs(list) do
        if link.kind == args[2] and link.id == other.id then
            local ok
            ok, message = backend:unlink(card.id, args[2], other.id)
            if not ok then
                return failure(message)
            end
            return {
                output = "unlinked "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " "
                    .. args[2]
                    .. " "
                    .. shown,
            }
        end
    end
    local held = #list == 0 and "It holds no links."
        or "Its links are listed below.\n" .. link_rows(list)
    return failure("The card holds no " .. args[2] .. " link to " .. shown .. ". " .. held)
end

function commands.attach(backend, args)
    if #args < 2 then
        return usage("Needs a card and one or more files.")
    end
    for index = 2, #args do
        if not fs.is_file(args[index]) then
            return failure(args[index] .. " is not a file.")
        end
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local held, message = backend:attachments(card.id)
    if not held then
        return failure(message)
    end
    local names = {}
    for _, attachment in ipairs(held) do
        names[attachment.name] = true
    end
    local lines = {}
    local refused = false
    for index = 2, #args do
        local name = fs.basename(args[index])
        if names[name] then
            lines[#lines + 1] = "skipped " .. name
        else
            local made
            made, message = backend:attach(card.id, args[index])
            if made then
                names[name] = true
                lines[#lines + 1] = "attached "
                    .. made.id:sub(1, board.MIN_PREFIX)
                    .. " "
                    .. made.name
            else
                refused = true
                lines[#lines + 1] = name .. ": " .. message
            end
        end
    end
    if refused then
        return failure(table.concat(lines, "\n"))
    end
    return { output = table.concat(lines, "\n") }
end

function commands.attachments(backend, args)
    if #args ~= 1 then
        return usage("Needs a card.")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local held, message = backend:attachments(card.id)
    if not held then
        return failure(message)
    end
    if #held == 0 then
        return { output = "No attachments." }
    end
    local lines = {}
    for _, attachment in ipairs(held) do
        lines[#lines + 1] = attachment.id:sub(1, board.MIN_PREFIX)
            .. "  "
            .. string.format("%d", attachment.size)
            .. "  "
            .. attachment.name
    end
    return { output = table.concat(lines, "\n") }
end

function commands.detach(backend, args)
    if #args ~= 2 then
        return usage("Needs a card and an attachment id.")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local held, message = backend:attachments(card.id)
    if not held then
        return failure(message)
    end
    local match
    for _, attachment in ipairs(held) do
        if attachment.id:sub(1, #args[2]) == args[2] then
            if match then
                return failure(args[2] .. " matches more than one attachment")
            end
            match = attachment
        end
    end
    if not match then
        return failure("The card holds no attachment with the id " .. args[2] .. ".")
    end
    local ok
    ok, message = backend:detach(card.id, match.id)
    if not ok then
        return failure(message)
    end
    return {
        output = "detached " .. match.id:sub(1, board.MIN_PREFIX) .. " " .. match.name,
    }
end

function commands.download(backend, args)
    local flags, words = parse(args, { ["--out"] = true })
    if not flags then
        return words
    end
    if #words ~= 2 then
        return usage("Needs a card and an attachment id or name.")
    end
    local card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    local held, message = backend:attachments(card.id)
    if not held then
        return failure(message)
    end
    local matches = {}
    for _, attachment in ipairs(held) do
        if attachment.id:sub(1, #words[2]) == words[2] or attachment.name == words[2] then
            matches[#matches + 1] = attachment
        end
    end
    if #matches == 0 then
        return failure("The card holds no attachment with the id or name " .. words[2] .. ".")
    end
    if #matches > 1 then
        return failure(words[2] .. " matches more than one attachment.")
    end
    local match = matches[1]
    local name = fs.basename(match.name)
    if name == "" or name == "." or name == ".." then
        return failure("The attachment's name " .. match.name .. " cannot name a file.")
    end
    local dir = flags["--out"]
    if dir and not fs.is_dir(dir) then
        return failure(dir .. " is not a directory.")
    end
    if not dir then
        dir, message = fs.mktemp({ prefix = "dev-board-download", dir = true })
        if not dir then
            return failure(message)
        end
    end
    local path = fs.join(dir, name)
    local part = fs.join(dir, "." .. name .. ".part")
    local ok
    ok, message = backend:download(card.id, match.id, part)
    if not ok then
        fs.remove(part)
        return failure(message)
    end
    fs.remove(path)
    ok, message = fs.move(part, path)
    if not ok then
        fs.remove(part)
        return failure(message)
    end
    return { output = path }
end

function commands.boards(backend, args)
    if #args > 0 then
        return usage("Unknown argument " .. args[1] .. ".")
    end
    local names, message = backend:boards()
    if not names then
        return failure(message)
    end
    return { output = table.concat(names, "\n") }
end

function commands.whoami(backend, args)
    if #args > 0 then
        return usage("Unknown argument " .. args[1] .. ".")
    end
    if not backend.whoami then
        return failure("This board holds no credential. There is nobody to show.")
    end
    local who, message = backend:whoami()
    if not who then
        return failure(message)
    end
    local function list(items)
        return type(items) == "string" and items
            or (#items > 0 and table.concat(items, ", ") or "none")
    end
    local lines = {
        "name: " .. who.name,
        "kind: " .. who.kind,
        "scope: " .. who.scope,
        "role: " .. (who.role or "none"),
        "label: " .. (who.label or "none"),
        "issuer: " .. (who.issuer or "none"),
        "expires: " .. (who.expires and os.date("!%Y-%m-%dT%H:%M:%SZ", who.expires) or "never"),
        "boards: " .. list(who.boards),
        "permissions: " .. list(who.permissions),
    }
    return { output = table.concat(lines, "\n") }
end

function commands.permissions(backend, args)
    if #args > 0 then
        return usage("Unknown argument " .. args[1] .. ".")
    end
    if not backend.permissions then
        return failure("This board holds no credential. There is no catalog to show.")
    end
    local catalog, message = backend:permissions()
    if not catalog then
        return failure(message)
    end
    local lines = {}
    for i, entry in ipairs(catalog) do
        local presets = #entry.presets > 0 and table.concat(entry.presets, ", ") or "none"
        lines[i] = entry.name .. " (" .. entry.group .. "): " .. presets
    end
    return { output = table.concat(lines, "\n") }
end

function commands.columns(backend, args)
    if #args > 1 then
        return usage("Takes at most one board name.")
    end
    local rows, message = backend:columns(args[1])
    if not rows then
        return failure(message)
    end
    local lines = {}
    for i, column in ipairs(rows) do
        lines[i] = column.name
            .. (column.is_done and DONE_MARK or "")
            .. (column.clears_blockers and CLEARS_BLOCKERS_MARK or "")
            .. (column.is_blocked and BLOCKED_MARK or "")
    end
    return { output = table.concat(lines, "\n") }
end

---Fail a board edit, naming the lead token when Pomb refused it.
---@param message string the backend's reason
---@return dev.cmd.board.Result result the failure
local function board_edit_failure(message)
    if message:lower():find("pomb answered 403", 1, true) then
        return failure(
            "Pomb refused the change. This token may not edit the board, "
                .. "so use a lead token, which holds columns.edit."
        )
    end
    return failure(message)
end

---Column field by flag name
local COLUMN_SWITCHES = {
    [CLEARS_BLOCKERS_FLAG] = "clears_blockers",
    [BLOCKED_FLAG] = "is_blocked",
}

function commands.column(backend, args)
    local flags, words = parse(args, { [CLEARS_BLOCKERS_FLAG] = true, [BLOCKED_FLAG] = true })
    if not flags then
        return words
    end
    if #words ~= 1 then
        return usage("Needs a column name.")
    end
    local fields = {}
    for flag, field in pairs(COLUMN_SWITCHES) do
        local value = flags[flag]
        if value ~= nil then
            if value ~= "on" and value ~= "off" then
                return usage("The " .. flag .. " flag takes on or off.")
            end
            fields[field] = value == "on"
        end
    end
    if next(fields) == nil then
        return usage("Needs " .. CLEARS_BLOCKERS_FLAG .. " or " .. BLOCKED_FLAG .. ".")
    end
    local rows, message = backend:columns()
    if not rows then
        return failure(message)
    end
    local name
    for _, column in ipairs(rows) do
        if column.name:lower() == words[1]:lower() then
            name = column.name
        end
    end
    if not name then
        return failure("The board has no column " .. words[1] .. ".")
    end
    local done
    done, message = backend:set_column(name, fields)
    if not done then
        return board_edit_failure(message)
    end
    return { output = "Set the flags of " .. name .. "." }
end

local function set_limit(backend, value, words)
    local limit = value:match("^%d+$") and tonumber(value)
    if not limit or limit < 1 then
        return usage("The --set flag needs a whole number of at least 1.")
    end
    if #words > 0 then
        return usage("The --set flag changes only this project's board.")
    end
    local stages = backend.stages
    local columns = { stages.progress, stages.review, stages.verify }
    local done, message = backend:set_limit_group(columns, limit)
    if not done then
        return board_edit_failure(message)
    end
    return {
        output = string.format(
            "Set the limit of %s, %s and %s to %d.",
            stages.progress,
            stages.review,
            stages.verify,
            limit
        ),
    }
end

function commands.limits(backend, args)
    local flags, words = parse(args, { [SET_FLAG] = true })
    if not flags then
        return words
    end
    if flags[SET_FLAG] then
        return set_limit(backend, flags[SET_FLAG], words)
    end
    args = words
    if #args > 1 then
        return usage("Takes at most one board name.")
    end
    local limits, message = backend:limits(args[1])
    if not limits then
        return failure(message)
    end
    local lines = {}
    local names = {}
    for name in pairs(limits.columns) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        lines[#lines + 1] = name .. ": " .. limits.columns[name] .. " " .. limits.units[name]
    end
    for _, group in ipairs(limits.groups) do
        lines[#lines + 1] = table.concat(group.columns, ", ")
            .. ": "
            .. group.limit
            .. (group.count and (" (" .. group.count .. " in flight)") or "")
    end
    if #limits.groups == 0 then
        lines[#lines + 1] = "The board has no limit group."
        return { output = table.concat(lines, "\n"), code = FAILURE }
    end
    return { output = table.concat(lines, "\n") }
end

function commands.links(backend, args)
    if #args ~= 1 then
        return usage("Needs a card.")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local list, message = backend:links(card.id)
    if not list then
        return failure(message)
    end
    if #list == 0 then
        return { output = "No links." }
    end
    return { output = link_rows(list) }
end

function commands.stale(backend, args, now)
    return stale.stale(backend, args, now)
end

function commands.lint(backend, args)
    local flags, words = parse(args, { [STRICT_FLAG] = SWITCH, [OPEN_FLAG] = SWITCH })
    if not flags then
        return words
    end
    if #words > 1 then
        return usage("Takes at most one card.")
    end
    local strict = flags[STRICT_FLAG] == true
    local open_only = flags[OPEN_FLAG] == true and not words[1]
    local required, bad = required_rows(backend)
    if bad then
        return bad
    end
    local cards, message = backend:cards()
    if not cards then
        return failure(message)
    end
    if words[1] then
        local only, why = board.resolve(cards, words[1])
        if not only then
            return failure(why)
        end
        cards = { only }
    end
    local rows = {}
    local fixable = false
    if open_only then
        local kept = {}
        for _, card in ipairs(cards) do
            if not card.done then
                kept[#kept + 1] = card
            end
        end
        cards = kept
    end
    for _, card in ipairs(cards) do
        local facts = {
            comments = function()
                local list, why = backend:comments(card.id)
                if not list then
                    return nil, "Could not read the comments of " .. card.id .. ". " .. why
                end
                return list
            end,
            links = function()
                local list, why = backend:links(card.id)
                if not list then
                    return nil, "Could not read the links of " .. card.id .. ". " .. why
                end
                return list
            end,
            children = function()
                local family, why = backend:family(card.id)
                if not family then
                    return nil, "Could not read the family of " .. card.id .. ". " .. why
                end
                local counts = family.children or { done = 0, total = 0 }
                return { done = counts.done, total = counts.total, epic = family.epic }
            end,
        }
        local rules, why, owned = lint.card(
            card,
            { stages = backend.stages, facts = facts, strict = strict, required = required }
        )
        if not rules then
            return failure(why)
        end
        for i, rule in ipairs(rules) do
            if owned[i] then
                rule = rule .. OWNER_MARK
            else
                fixable = true
            end
            rows[#rows + 1] = { card.id:sub(1, board.MIN_PREFIX), card.column, rule }
        end
    end
    if #rows == 0 then
        return { output = "No findings." }
    end
    return {
        output = table.concat(board.table_lines(rows), "\n"),
        code = fixable and FAILURE or nil,
    }
end

function commands.take(backend, args)
    local FROM_FLAG = "--from"
    local flags, words = parse(args, { [AS_FLAG] = true, [runner.FLAG] = true, [FROM_FLAG] = true })
    if not flags then
        return words
    end
    if #words ~= 1 then
        return usage("Needs a card.")
    end
    local name, why = agent_name(flags[AS_FLAG])
    if why then
        return why
    end
    local limit, bad = runner.limit(flags[runner.FLAG])
    if bad then
        return bad
    end
    local card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    local from = flags[FROM_FLAG]
    local short = card.id:sub(1, board.MIN_PREFIX)
    if from then
        if card.claimant == nil then
            return failure(
                "Card " .. short .. " has no claim. " .. FROM_FLAG .. " has nothing to take over."
            )
        end
        if card.claimant ~= from then
            return failure(
                "Card " .. short .. " is claimed by " .. card.claimant .. ", not by " .. from .. "."
            )
        end
        if from == (name or claimant()) then
            return failure(from .. " already holds card " .. short .. ".")
        end
    end
    local refused = runner.refusal(card, limit)
    if refused then
        return refused
    end
    local stages = backend.stages
    if not plans_card(stages, card, name) then
        refused = blocker_refusal(backend, card)
        if refused then
            return refused
        end
    end
    local rival = not from and card.claimant ~= nil and card.claimant ~= (name or claimant())
    if card.claimant == nil or from then
        local shaped = runner.shape_refusal(name)
        if shaped then
            return shaped
        end
    end
    if
        card.claimant == nil
        and before_work(stages, card)
        and not plans_card(stages, card, name)
    then
        local shape, why_family = family_shape(backend, card)
        if not shape then
            return failure(why_family)
        end
        refused = size_refusal(card) or ready_refusal(backend, card, shape)
        if refused then
            return refused
        end
    end
    local limited = card.column ~= stages.progress and not claims.read(card.id) and not rival
    if limited then
        refused = runner.limited(backend, card, stages.progress)
        if refused then
            return refused
        end
    end
    if from then
        local held = claims.read(card.id)
        local fence = held and held.fence
        local released, stuck, reason, detail = backend:release(card.id, fence)
        if not released then
            return failure(board.release_refusal(reason, stuck, detail, fence))
        end
        claims.stop(card.id)
    end
    local result, fence = claim_card(backend, card, name)
    if not fence then
        return result
    end
    if card.column == stages.ready then
        local moved, stuck, refusal = backend:move(card.id, stages.progress, {
            fence = fence,
            force = board.labelled(card, board.TRUNK_BLOCKER) or nil,
        })
        if not moved then
            claims.stop(card.id)
            backend:release(card.id, fence)
            return failure(board.move_refusal(refusal, stuck, stages.progress))
        end
        card.column = stages.progress
    end
    local reason, detail = role_clock.follow(backend, card, card.column, claimant(name))
    if reason then
        verb.note(
            clock_note("Took card " .. short .. ", but its clock did not follow.", reason, detail)
        )
    end
    if from then
        local ok, message = backend:note(
            card.id,
            string.format("handoff: %s released the claim and %s took it", from, claimant(name)),
            fence,
            { kind = board.NoteKind.STATUS }
        )
        if not ok then
            verb.note("Took card " .. short .. ", but the handoff note was not posted. " .. message)
        end
    end
    return claimed_view(backend, card, result)
end

function commands.release(backend, args)
    if #args ~= 1 then
        return usage("Needs a card.")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local held = claims.read(card.id)
    if not held then
        return failure("No claim was taken for " .. args[1] .. " with `dev board take`.")
    end
    local ok, message, reason, detail = backend:release(card.id, held.fence)
    if not ok then
        return failure(board.release_refusal(reason, message, detail, held.fence))
    end
    claims.stop(card.id)
    local stuck, cause = role_clock.follow(backend, card, nil, "")
    if stuck then
        verb.note(clock_note("Released, but the clock did not stop.", stuck, cause))
    end
    return {
        output = string.format(
            "released %s, fence %d",
            card.id:sub(1, board.MIN_PREFIX),
            held.fence
        ),
    }
end

function commands.run(backend, args)
    return runcard.run(backend, args, {
        dispatch = M.run,
        add = commands.add,
        find_card = find_card,
        sentence = sentence,
        card_line = card_line,
        name_chars = board_setup.NAME_CHARS,
    })
end

---Run one board subcommand against a backend.
---@param sub string `ls`, `next`, `add`, `note`, `notes`, `show`, `move`, `order`, `discard`,
---   `size`, `label`, `edit`, `checks`, `allow`, `tests`, `files`, `outcome`, `epic`, `link`,
---   `links`, `unlink`, `stale`, `lint`, `take` or `release`
---@param args string[] the arguments after the subcommand
---@param backend dev.board.Backend the board
---@param now integer? the time in seconds since the epoch that `stale` counts from, the clock when
---   nil
---@param screen dev.ui.Context? the terminal `ls` draws for, left nil for the plain lines
---@return dev.cmd.board.Result result the output, or a message and the exit code
function M.run(sub, args, backend, now, screen)
    local finished = backend:done_columns() or {}
    board.retarget(backend, backend.column_map, backend.root, finished)
    local run = commands[sub] or internal[sub]
    return run(backend, args, now, screen)
end

local LEAD_TOKEN_KEY = "lead_token"

local function open_backend(settings, token_key)
    if settings.backend == board.Backend.LOCAL then
        if settings.path then
            return localboard.new({ name = settings.name, path = settings.path })
        end
        if
            not settings.name:find(LOCAL_NAME_PATTERN)
            or #settings.name > board_setup.NAME_CHARS
        then
            return nil,
                "A local board's name must be letters, digits, dots, dashes and underscores to name its file. Otherwise set the `path` setting of `[board]`."
        end
        return localboard.new({
            name = settings.name,
            path = store.dir() .. "/" .. settings.name .. ".json",
            private = true,
        })
    end
    local backend, reason = pomb.new({
        url = config.user("board.pomb.url"),
        token = config.user("board.pomb." .. token_key),
        name = settings.name,
        lead = token_key == LEAD_TOKEN_KEY,
    })
    if not backend then
        return nil, POMB_REFUSALS[reason]
    end
    return backend
end

---Build the backend a project's board uses.
---@param settings dev.cmd.board.Settings the board's backend and name
---@param opts dev.cmd.board.open.Opts? the token key to read, token when nil
---@return dev.board.Backend? backend the backend
---@return string? message why there is none
function M.open(settings, opts)
    local TOKEN_KEY = "token"
    local token_key = opts and opts.token_key or TOKEN_KEY
    local backend, message = open_backend(settings, token_key)
    if backend then
        board.retarget(backend, settings.columns, settings.root)
    end
    return backend, message
end

local function column_map(root)
    local columns = {}
    for _, stage in ipairs(board.STAGES) do
        columns[stage] = config.get(root, "board.columns." .. stage)
    end
    columns.done = config.get(root, "board.columns.done")
    return columns
end

local function settings(ctx)
    local backend = config.get(ctx.root, "board.backend")
    if backend == nil then
        verb.die(NO_BOARD)
    end
    if backend ~= board.Backend.POMB and backend ~= board.Backend.LOCAL then
        verb.die(
            'The `backend` setting of `[board]` must be "pomb" or "local" in `.dev/config.toml`.'
        )
    end
    local name = config.get(ctx.root, "board.name")
    if name == nil then
        name = fs.basename(ctx.root)
    end
    if type(name) ~= "string" or name == "" then
        verb.die(
            "The `name` setting of `[board]` must be a non-empty string in `.dev/config.toml`."
        )
    end
    local path = config.get(ctx.root, "board.path")
    if path ~= nil then
        if backend ~= board.Backend.LOCAL then
            verb.die('The `path` setting of `[board]` only applies to `backend = "local"`.')
        end
        if
            type(path) ~= "string"
            or not path:find(PATH_PATTERN)
            or path:find("..", 1, true)
            or path:find("//", 1, true)
        then
            verb.die(
                "The `path` setting of `[board]` must be a relative path inside the project, such as `.dev/board.json`."
            )
        end
        path = ctx.root .. "/" .. path
    end
    local columns = column_map(ctx.root)
    local collision = board.column_collision(columns)
    if collision then
        verb.die(collision)
    end
    return {
        backend = backend,
        name = name,
        path = path,
        root = ctx.root,
        columns = columns,
    }
end

---Build the backend of the board a project root configures.
---@param root string the project root
---@return dev.board.Backend? backend the board's backend
---@return string? message why there is none
function M.backend_at(root)
    if config.get(root, "board.backend") == nil then
        return nil, "The project at " .. root .. " has no `[board]` section."
    end
    return M.open(settings({ root = root }))
end

---Write why the layout change stopped.
---@param message string the backend's message
---@param reason dev.board.init.Reason? what `init.run` named
---@return string message the sentence
local function init_refusal(message, reason)
    if reason == init.Reason.NEEDS_ADMIN then
        return (message:gsub("%.$", ""))
            .. ". This token may not change this board, so run `dev board init --admin`."
    end
    return sentence(message)
end

---Print one warning from the layout change, with the hint when the token may not change the board.
---@param line string a `Warning`, or a finished sentence
---@param detail string? the backend's message for a `Warning`
---@param reason dev.board.init.Reason? what `init.run` named
local function init_warning(line, detail, reason)
    if line == init.Warning.ROLES_UNREADABLE then
        line = "Agent roles were not checked. The roles list could not be read. " .. detail
    end
    verb.note(reason and init_refusal(line, reason) or line)
end

local function init_local(ctx, flags, admin)
    if admin then
        verb.usage_error(ctx, "--admin applies to a Pomb board, not a local one")
    end
    local found = settings(ctx)
    if flags["--name"] and flags["--name"] ~= found.name then
        verb.usage_error(
            ctx,
            "--name " .. flags["--name"] .. " is not the [board] name " .. found.name
        )
    end
    local backend, message = M.open(found)
    if not backend then
        verb.die(message)
    end
    local changes, reason
    changes, message, reason = init.run(backend, found.name, verb.say, {
        stages = backend.stages,
        lanes = board_setup.config_lanes(ctx),
        warn_first_lane = false,
        warn = init_warning,
    })
    if not changes then
        verb.die(init_refusal(message, reason))
    end
    print(
        changes == 0
                and ("Board " .. found.name .. " already follows the standard. Nothing changed.")
            or (
                "board "
                .. found.name
                .. ": "
                .. changes
                .. (changes == 1 and " change" or " changes")
            )
    )
    return 0
end

---Write why the device sign-in ended with no token.
---@param reason dev.board.device.Reason the reason `device.pair` named
---@param detail dev.board.device.Detail? the url and curl exit, or the status and Pomb's message
---@return string message the sentence
local function sign_in_refusal(reason, detail)
    local Reason = device.Reason
    if reason == Reason.UNREACHABLE then
        return "Cannot reach " .. detail.url .. " (curl exit " .. tostring(detail.curl_exit) .. ")."
    elseif reason == Reason.UNREADABLE then
        return "Pomb sent an answer dev cannot read."
    elseif reason == Reason.REFUSED then
        return sentence(
            "Pomb answered " .. detail.status .. ": " .. tostring(detail.message or "no message")
        )
    elseif reason == Reason.NO_CODE then
        return "Pomb sent a sign-in with no code."
    elseif reason == Reason.NO_TEMP then
        return "Cannot make a temporary file for the sign-in."
    elseif reason == Reason.WRITE_TEMP then
        return "Cannot write the temporary file for the sign-in."
    elseif reason == Reason.BAD_TOKEN then
        return "Pomb sent a token that is not plain text."
    elseif reason == Reason.DENIED then
        return "The sign-in was denied."
    elseif reason == Reason.EXPIRED then
        return "The sign-in was not approved in time."
    elseif reason == Reason.UNKNOWN then
        return "Pomb no longer knows this sign-in."
    elseif reason == Reason.QUOTA then
        return "The account holds too many tokens. Revoke one and run it again."
    end
    return "The sign-in ended for a reason dev does not know."
end

M.handlers["board init"] = function(ctx)
    local rest, admin = {}, false
    for _, arg in ipairs(ctx.args) do
        if arg == "--admin" then
            admin = true
        else
            rest[#rest + 1] = arg
        end
    end
    local flags, extra = parse(rest, { ["--name"] = true })
    if not flags then
        verb.usage_error(ctx, extra.message)
    elseif #extra > 0 then
        verb.usage_error(ctx, "unknown argument " .. extra[1])
    end
    if config.get(ctx.root, "board.backend") == board.Backend.LOCAL then
        return init_local(ctx, flags, admin)
    end
    if not admin and guards.delete_refusal() == guards.Refusal.NOT_LEAD then
        verb.die(not_lead_message("initializes a board"))
    end
    local name, missing = board_setup.board_name(ctx, flags)
    local opts = {
        url = config.user("board.pomb.url"),
        token = config.user("board.pomb.lead_token"),
        name = name,
        lead = not admin,
    }
    if not admin and opts.token == nil then
        verb.die(
            "The `lead_token` setting of `[board.pomb]` is not set in `~/.config/dev/config.toml`. "
                .. "Set it to `pass:<entry>` or run with `--admin`."
        )
    end
    local backend, reason = pomb.new(opts)
    if not backend then
        verb.die(POMB_REFUSALS[reason])
    end
    backend.stages = board.stages(column_map(ctx.root))
    local message
    if admin then
        local secret, sign_in_reason, detail = device.pair({
            url = opts.url,
            client_name = ("dev-board-init@" .. board_setup.host()):sub(1, CLIENT_CHARS),
            scope = ADMIN_SCOPE,
            say = print,
        })
        if not secret then
            verb.die(sign_in_refusal(sign_in_reason, detail))
        end
        backend:authorize(secret)
        local ok
        ok, message = backend:admin()
        if not ok then
            verb.die(message)
        end
    end
    local changes, init_reason
    changes, message, init_reason = init.run(backend, name, verb.say, {
        stages = backend.stages,
        lanes = board_setup.config_lanes(ctx),
        warn_first_lane = true,
        warn = init_warning,
    })
    if not changes then
        verb.die(init_refusal(message, init_reason))
    end
    if missing then
        local written, failed = board_setup.write_section(ctx.root, name)
        if not written then
            verb.die("Cannot write " .. ctx.root .. "/.dev/config.toml. " .. sentence(failed))
        end
        print("wrote [board] to .dev/config.toml")
    end
    print(
        changes == 0 and ("Board " .. name .. " already follows the standard. Nothing changed.")
            or ("board " .. name .. ": " .. changes .. (changes == 1 and " change" or " changes"))
    )
    return 0
end

local function description_args(args)
    local flags, words = parse(args, { ["--file"] = true, ["--board"] = true })
    if not flags then
        return nil, words.message
    end
    if #words ~= 1 then
        return nil, "Needs a card, and the description from --file PATH or standard input."
    end
    local text, message
    if flags["--file"] then
        text, message = fs.read(flags["--file"])
        if not text then
            return nil, "Cannot read " .. flags["--file"] .. ": " .. tostring(message) .. "."
        end
    elseif dev_os.isatty(0) then
        return nil, "Needs the description from --file PATH or standard input."
    else
        text = io.read("*a")
    end
    text = text:gsub("%s+$", "")
    if text == "" then
        return nil, "The new description is empty."
    end
    if flags["--board"] then
        return { words[1], "--board", flags["--board"], text }
    end
    return { words[1], text }
end

local function brief(entry)
    return entry.sub .. " " .. tostring(entry.args[1])
end

---Replay the changes queued while Pomb was unreachable, oldest first.
---
---A change Pomb refuses is reported and dropped. A change that finds Pomb
---unreachable again stays queued with the ones behind it.
---@param backend dev.board.Backend the Pomb board
---@param pending dev.board.queue.Queue the board's queue
---@param say fun(line: string) prints one line
---@return integer? left how many changes are still queued, nil when the queue could not be used
---@return string? message why the queue could not be used
---@return dev.board.queue.Reason? reason the kind of failure when the queue could not be loaded
local function replay(backend, pending, say)
    local drained, message, reason = pending:drain(function(entry)
        if not QUEUE_RULES[entry.sub] or type(entry.args) ~= "table" then
            say("dropped " .. tostring(entry.sub) .. ": not a change dev queues")
            return queue.Replay.DONE
        end
        local result = M.run(entry.sub, entry.args, backend)
        if not result.message then
            say("synced " .. brief(entry))
            return queue.Replay.DONE
        elseif pomb.unreachable(result.message, idempotent(entry.sub, entry.args)) then
            say("Pomb is still unreachable, " .. brief(entry) .. " stays queued")
            return queue.Replay.STOP
        end
        say("dropped " .. brief(entry) .. ": " .. result.message)
        return queue.Replay.DONE
    end)
    if not drained then
        return nil, message, reason
    end
    return pending:count()
end

local function stderr_line(line)
    verb.note(line)
end

local function stderr_news(line)
    if not line:find("^Pomb is still unreachable") then
        stderr_line(line)
    end
end

---List the cards of a project's board that sit in a done column.
---@param root string absolute path of the project root
---@return table<string, boolean>? finished the short ids of the done cards, nil when unread
---@return string? why why the board was not read
function M.finished(root)
    if config.get(root, "board.backend") == nil then
        return nil, "This project has no board."
    end
    local backend, message = M.open(settings({ root = root }))
    if not backend then
        return nil, message
    end
    local cards, why = backend:cards()
    if not cards then
        return nil, why
    end
    local finished = {}
    for _, card in ipairs(cards) do
        if card.done then
            finished[card.id:sub(1, board.MIN_PREFIX)] = true
        end
    end
    return finished
end

local function open_board(ctx)
    local found = settings(ctx)
    local backend, message = M.open(found)
    if not backend then
        verb.die(message)
    end
    local pending
    if found.backend == board.Backend.POMB then
        pending = queue.new(found.name)
        local waiting, why, reason = pending:count()
        if not waiting then
            stderr_line(
                queue_unreadable(pending.path, reason, why) .. " The queue is left in place."
            )
        elseif waiting > 0 then
            replay(backend, pending, stderr_news)
        end
    end
    return backend, pending
end

local function open_lead(ctx, action, permission)
    if guards.delete_refusal() == guards.Refusal.NOT_LEAD then
        verb.die(not_lead_message(action))
    end
    local found = settings(ctx)
    if found.backend ~= board.Backend.POMB then
        verb.die(NO_BIN)
    end
    if config.user("board.pomb." .. LEAD_TOKEN_KEY) == nil then
        verb.die(
            "The `lead_token` setting of `[board.pomb]` is not set in `~/.config/dev/config.toml`."
                .. (
                    permission
                        and " The `" .. permission .. "` permission needs the lead token."
                    or ""
                )
        )
    end
    local backend, message = M.open(found, { token_key = LEAD_TOKEN_KEY })
    if not backend then
        verb.die(message)
    end
    return backend
end

M.handlers["board token mint"] = function(ctx)
    local flags, extra = parse(
        ctx.args,
        { ["--role"] = true, ["--as"] = true, ["--hours"] = true, ["--renew"] = SWITCH }
    )
    if not flags then
        verb.usage_error(ctx, extra.message)
    elseif #extra > 0 then
        verb.usage_error(ctx, "unknown argument " .. extra[1])
    elseif not flags["--role"] or not flags["--as"] or flags["--as"] == "" then
        verb.usage_error(ctx, "needs --role ROLE and --as NAME")
    end
    local hours = flags["--hours"]
        and flags["--hours"]:match("^%d+$")
        and tonumber(flags["--hours"])
    if flags["--hours"] and (not hours or hours < 1 or hours > pomb.MAX_TOKEN_HOURS) then
        verb.usage_error(ctx, "--hours takes a whole number from 1 to " .. pomb.MAX_TOKEN_HOURS)
    end
    local backend = open_lead(ctx, "mints a role token")
    local issued, message = backend:mint(
        flags["--role"],
        flags["--as"],
        { hours = hours, renew = flags["--renew"] ~= nil }
    )
    if not issued then
        verb.die(message)
    end
    local stamp = issued.expires > 0 and os.date("!%Y-%m-%dT%H:%M:%SZ", issued.expires) or "never"
    print(
        string.format(
            "minted role %s as %s, label %s, expires %s",
            issued.role,
            flags["--as"],
            issued.label,
            stamp
        )
    )
    return 0
end

M.handlers["board token revoke"] = function(ctx)
    local flags, extra = parse(ctx.args, { ["--as"] = true })
    if not flags then
        verb.usage_error(ctx, extra.message)
    elseif #extra > 0 then
        verb.usage_error(ctx, "unknown argument " .. extra[1])
    elseif not flags["--as"] or flags["--as"] == "" then
        verb.usage_error(ctx, "needs --as NAME")
    end
    local backend = open_lead(ctx, "revokes a role token")
    local done, message = backend:revoke(flags["--as"])
    if not done then
        verb.die(message)
    end
    print(
        done.revoked and ("revoked the role token of " .. flags["--as"])
            or ("Nothing was left to revoke for " .. flags["--as"] .. ".")
    )
    return 0
end

function Owner.print_needs_human(found)
    local backend, message = M.open(found)
    if not backend then
        verb.die(message)
    end
    local rows, unreadable = backend:needs_human()
    if not rows then
        verb.die(unreadable)
    end
    if #rows == 0 then
        verb.say("No cards.")
    else
        local cells = {}
        for i, row in ipairs(rows) do
            cells[i] = { row.board, row.id:sub(1, board.MIN_PREFIX), row.epic, row.name }
        end
        verb.say(table.concat(board.table_lines(cells), "\n"))
    end
    if #unreadable > 0 then
        verb.say("unreadable: " .. table.concat(unreadable, ", "))
    end
end

M.handlers["board status"] = function(ctx)
    local flags, extra = parse(ctx.args, { ["--all"] = SWITCH })
    if not flags then
        verb.usage_error(ctx, extra.message)
    elseif #extra > 0 then
        verb.usage_error(ctx, "unknown argument " .. extra[1])
    end
    local found = settings(ctx)
    print("backend: " .. found.backend)
    print("board: " .. found.name)
    if found.backend == board.Backend.POMB then
        local pending = queue.new(found.name)
        local waiting, why, reason = pending:count()
        if not waiting then
            stderr_line(
                queue_unreadable(pending.path, reason, why) .. " The queue is left in place."
            )
        elseif waiting > 0 then
            local backend = M.open(found)
            if backend then
                replay(backend, pending, stderr_line)
            end
            local left = pending:count()
            if left and left > 0 then
                print("queued: " .. left)
            end
        end
    end
    local soon, expired = tokenfile.expiring(os.time())
    if soon > 0 or expired > 0 then
        verb.say(string.format("tokens: %d expire within an hour, %d expired", soon, expired))
    end
    if flags["--all"] then
        Owner.print_needs_human(found)
    end
    return 0
end

M.wait = board_wait.wait

M.handlers["board wait"] = function(ctx)
    local found = settings(ctx)
    if found.backend ~= board.Backend.POMB then
        verb.die("A local board has nothing to wait on.")
    end
    local backend = open_board(ctx)
    local result = M.wait(backend, ctx.args, { stem = board_wait.cursor_path(found.name) })
    if result.message then
        if result.code == USAGE then
            verb.usage_error(ctx, result.message)
        end
        verb.die(result.message)
    end
    print(result.output)
    return 0
end

M.handlers["board sync"] = function(ctx)
    verb.no_args(ctx)
    local found = settings(ctx)
    if found.backend ~= board.Backend.POMB then
        verb.die("A local board has nothing to sync.")
    end
    local pending = queue.new(found.name)
    local waiting, message, reason = pending:count()
    if not waiting then
        verb.die(queue_unreadable(pending.path, reason, message) .. " The queue is left in place.")
    end
    if waiting == 0 then
        print("Nothing is queued.")
        return 0
    end
    local backend
    backend, message = M.open(found)
    if not backend then
        verb.die(message)
    end
    local left
    left, message, reason = replay(backend, pending, print)
    if not left then
        verb.die(queue_unreadable(pending.path, reason, message) .. " The queue is left in place.")
    end
    if left > 0 then
        print("queued: " .. left)
        return 1
    end
    print("synced")
    return 0
end

for sub in pairs(commands) do
    M.handlers["board " .. sub] = function(ctx)
        if
            sub == "run"
            and index_of(ctx.args, runcard.ORDERS_FLAG)
            and not index_of(ctx.args, runcard.END_FLAG)
        then
            local _, refused = runcard.precheck(ctx.args, board_setup.NAME_CHARS)
            if refused then
                if refused.code == USAGE then
                    verb.usage_error(ctx, refused.message)
                end
                verb.note(refused.message)
                return refused.code or FAILURE
            end
            board_setup.ensure_board(ctx, function(making)
                return M.handlers["board init"](making)
            end)
        end
        local args = ctx.args
        if sub == "edit" then
            local why
            args, why = description_args(ctx.args)
            if not args then
                verb.usage_error(ctx, why)
            end
        end
        if sub == "ship" and ctx.dashed then
            args = { unpack(args, 1, #args - ctx.after) }
            args[#args + 1] = "--"
            for i = #ctx.args - ctx.after + 1, #ctx.args do
                args[#args + 1] = ctx.args[i]
            end
        end
        if sub == "outcome" then
            args = with_env_ticker(args)
        end
        if sub == "lint" then
            local strict = config.get(ctx.root, "board.lint.strict")
            if strict ~= nil and type(strict) ~= "boolean" then
                verb.die("The `strict` setting of `[board.lint]` must be true or false.")
            end
            if strict and not index_of(args, STRICT_FLAG) then
                args = { unpack(args) }
                table.insert(args, 1, STRICT_FLAG)
            end
        end
        local backend, pending
        if sub == "delete" then
            backend = open_lead(ctx)
        elseif
            sub == "outcome"
            and outcome_word(args) == DELETE_FLAG
            and settings(ctx).backend == board.Backend.POMB
        then
            backend = open_lead(ctx, "deletes an outcome", "subtasks.delete")
        elseif
            sub == "limits"
            and index_of(args, SET_FLAG)
            and settings(ctx).backend == board.Backend.POMB
        then
            backend = open_lead(ctx, "sets a limit", "columns.edit")
        elseif sub == "column" and settings(ctx).backend == board.Backend.POMB then
            backend = open_lead(ctx, "sets a column flag", "columns.edit")
        else
            backend, pending = open_board(ctx)
            if
                sub == "move"
                and settings(ctx).backend == board.Backend.POMB
                and closes_epic(backend, args)
            then
                backend, pending = open_lead(ctx, "closes an epic", "epics.manage"), nil
            end
        end
        local result = M.run(sub, args, backend, nil, sub == "ls" and ui.context() or nil)
        if result.message then
            local note = sub == "note" and (ctx.args[2] == EDIT_FLAG or ctx.args[2] == DELETE_FLAG)
            local queued = result.queue
            local form = sub == "outcome" and outcome_word(args)
            if
                not queued
                and QUEUE_RULES[sub]
                and not result.unqueued
                and not note
                and not (form == CONVERT_FLAG or form == DELETE_FLAG)
            then
                queued = { { sub = sub, args = args } }
            end
            if
                pending
                and queued
                and pomb.unreachable(result.message, idempotent(queued[1].sub, queued[1].args))
            then
                for _, entry in ipairs(queued) do
                    local ok, why, reason = pending:push(entry.sub, entry.args)
                    if not ok then
                        verb.die(
                            result.message
                                .. " The change could not be queued. "
                                .. queue_unreadable(pending.path, reason, why)
                        )
                    end
                end
                print(QUEUED_NOTICE)
                return 0
            end
            if result.code == USAGE then
                verb.usage_error(ctx, result.message)
            end
            verb.note(result.message)
            return result.code or FAILURE
        end
        for _, line in ipairs(result.warnings or {}) do
            stderr_line(line)
        end
        if result.page then
            ui.page(result.output .. "\n")
        else
            print(result.output)
        end
        return result.code or 0
    end
end

return M
