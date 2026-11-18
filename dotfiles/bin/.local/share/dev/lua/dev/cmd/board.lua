local board = require("dev.board")
local box = require("dev.cmd.box")
local check = require("dev.board.check")
local claims = require("dev.board.claims")
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
local runner = require("dev.board.runner")
local store = require("dev.board.store")
local text_width = require("dev.text").width
local templates = require("dev.templates")
local toml = require("dev.toml")
local turn = require("dev.board.turn")
local ui = require("dev.ui")
local vcs = require("dev.vcs")
local verb = require("dev.verb")
local wiring = require("dev.board.wiring")

local NO_BOARD = "dev: This project has no board."
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
local unqueued = guards.unqueued
local agent_name = guards.agent_name
local index_of = runner.index_of
local owner_holds = runner.owner_holds
local claimant = runner.claimant
local claim_card = runner.claim_card
local OWNER_MARK = " (owner)"
local DONE_MARK = " (done)"
local NAME_PATTERN = '^[^%c"\\]+$'
local NAME_CHARS = 100
local ADMIN_SCOPE = "admin"
local CLIENT_CHARS = 80
---Todo file names under the project root
local TODO_FILES = { "TODO.md", "docs/TODO.md" }
local STALE_DAYS = 7
local ICEBOX_DAYS = 30
local LEAD_HOURS = 1
local FLIGHT_HOURS = 24
local STAMP_CHARS = 16
local COMMIT_CHARS = 12
local WAIT_FLAG = "--wait"
local SET_FLAG = "--set"
local ID_ONLY_FLAG = "--id-only"
local SWITCH = "switch"
local MAX_WAIT_SECONDS = 86400
local MAX_LAND_ATTEMPTS = 5
local STRICT_FLAG = "--strict"
local RESERVED_NOTE = "A note cannot begin with "
    .. board.CHECK_PREFIX
    .. ", which `dev board check` writes, "
    .. board.REVIEW_PREFIX
    .. ", which `dev board review` writes, or "
    .. board.CLAIM_PREFIX
    .. ", which taking a card writes."
local LINK_HELP = table.concat(board.LINK_KINDS, ", ")
local EDIT_FLAG = "--edit"
local DELETE_FLAG = "--delete"
local NO_BIN = "This board keeps no recycle bin. Dev cannot delete a card from it."
local KIND_FLAG = "--kind"
local BY_FLAG = "--by"
local REV_FLAG = "--rev"
local GROUP_FLAG = "--group"
local AS_FLAG = guards.AS_FLAG
local REASON_FLAG = "--reason"
local RUN_END_FLAG = "--end"
local RUN_ORDERS_FLAG = "--orders"
local RUN_NAME = "run "
local HUMAN_ACTOR = "human"
local ANSWERED_NOTE = " (answered, waiting for your move)"
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
---@field columns table<string, string>? the `[board.columns]` map, keyed by role

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

---@class dev.cmd.board
---@field handlers table<string, fun(ctx: dev.Ctx): integer> the handlers of the `board` subcommands
---@field open fun(settings: dev.cmd.board.Settings): dev.board.Backend?, string? builds the backend
---   a board uses
local M = { handlers = {} }

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
                return nil, usage(arg .. " needs a value.")
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

local function named_column(backend, word)
    local column = backend.roles:column(word)
    if not column then
        return nil,
            usage("Unknown column " .. word .. ". The columns are " .. backend.roles:help() .. ".")
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

local function count_text(count, noun)
    return count .. " " .. noun .. (count == 1 and "" or "s")
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
    local cards, message = backend:cards()
    if not cards then
        return nil, failure(message)
    end
    local card, why = board.resolve(cards, word)
    if not card then
        return nil, failure(why)
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
    local cards, message = backend:cards()
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
            roles = backend.roles,
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
    local roles = backend.roles
    local column = roles.ready
    if flags["--column"] then
        local named, err = named_column(backend, flags["--column"])
        if not named then
            return err
        end
        local takes = named == roles.ready
            or named == roles.backlog
            or named == roles.icebox
            or named == roles.blocked
            or named == roles.review
            or named == roles.verify
            or named == roles.release
        if not takes then
            return usage(
                "Next --column takes Ready, Backlog, Icebox, Review, Verify, Release or Blocked."
            )
        end
        column = named
    end
    local asked = flags["--for"] and flags["--for"]:lower()
    if asked and (column ~= roles.blocked or not board.BLOCKED_LABELS[asked]) then
        return usage("Next --for takes planner or lead, with --column Blocked.")
    end
    local card, message = backend:next(column, {
        label = column == roles.blocked and board.BLOCKED_LABELS[asked or "lead"] or nil,
        max_size = limit,
        lane = lane,
    })
    if not card then
        if message then
            return failure(message)
        end
        if column == roles.ready then
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
            return usage(flag .. " takes one value, so give its text once")
        end
    end
    local problem = flags["--problem"] and flags["--problem"][1]
    local out_of_scope = flags["--out-of-scope"] and flags["--out-of-scope"][1]
    local change = flags["--change"] and table.concat(flags["--change"], "\n")
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
            return usage("--checks needs a command")
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
            return usage("--done-when needs the outcome")
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
    local roles = backend.roles
    local column = roles.backlog
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
        and column ~= roles.blocked
        and column ~= roles.icebox
    then
        return usage(
            board.NEEDS_HUMAN
                .. " lives only in Blocked or Icebox, so add the card there with --column."
        )
    end
    if column == roles.ready and unready(color) then
        return usage(
            "A card must be sized 1, 2 or 3 before it enters Ready, "
                .. "so add it with --size or to Backlog."
        )
    end
    local description = flags["--description"]
    if sectioned then
        description = board.compose(problem, change, out_of_scope, source)
    elseif column ~= roles.icebox then
        description = board.scaffold(description)
    end
    if column ~= roles.icebox and column ~= roles.ready then
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
                    .. roles.icebox
                    .. " needs a size, card format v3 and Done when outcomes, and this one lacks "
                    .. table.concat(missing, ", ")
                    .. ". Pass --size, --problem and --done-when, or add it to "
                    .. roles.icebox
                    .. "."
            )
        end
    end
    if column == roles.ready then
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
    if #checks > 0 or column == roles.ready then
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
    if column == roles.ready and not flags["--epic"] then
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
            local cards, why = backend:cards()
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
        local ok, why = backend:move(card.id, card.column, { position = position })
        if not ok then
            return {
                message = "Card "
                    .. card_prefix
                    .. " was added to "
                    .. card.column
                    .. " but not placed. "
                    .. why,
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
        return usage(EDIT_FLAG .. " needs a comment and the new text")
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
    local result = changed("edited", card, comment)
    result.warnings = board.prose_warnings(text)
    return result
end

local function delete_note(backend, args)
    if #args < 3 then
        return usage(DELETE_FLAG .. " needs a comment")
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
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local list, message = backend:comments(card.id)
    if not list then
        return failure(message)
    end
    return { output = comment_lines(list) }
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
    for _, field in ipairs({ "checks", "allow", "tests", "files" }) do
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
            "dev: Took card "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. ", but its view failed. "
                .. sentence(err.message)
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
            return nil, usage(args[i] .. " needs a value")
        end
        if args[i] == KIND_FLAG then
            kind = args[i + 1]
        else
            label = args[i + 1]
        end
        i = i + 2
    end
    if i > 2 and (args[i] == EDIT_FLAG or args[i] == DELETE_FLAG) then
        return nil, usage(args[i] .. " takes no " .. KIND_FLAG .. " or " .. AS_FLAG)
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
            return nil, usage(AS_FLAG .. " needs a label with no control characters")
        end
        if #opts.author > board.AUTHOR_CHARS then
            return nil, usage(AS_FLAG .. " takes at most " .. board.AUTHOR_CHARS .. " characters")
        end
    end
    return words, opts
end

function commands.note(backend, args)
    if args[2] == "--board" and (args[4] == EDIT_FLAG or args[4] == DELETE_FLAG) then
        return usage("--board takes no " .. EDIT_FLAG .. " or " .. DELETE_FLAG)
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
    local held = claims.read(card.id)
    local ok, message = home:note(card.id, text, held and held.fence, opts)
    if not ok then
        return failure(message)
    end
    return {
        output = "noted " .. card.id:sub(1, board.MIN_PREFIX),
        warnings = board.prose_warnings(text),
    }
end

---Refuse a move that takes a card out of In Progress before its claimant has noted.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card being moved
---@param column string the column it moves to
---@return dev.cmd.board.Result? refused the failure, nil when the move may go on
local function unnoted(backend, card, column)
    local roles = backend.roles
    local leaving = card.column == roles.progress
        and (column == roles.review or column == roles.ready or column == roles.blocked)
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
---@param roles dev.board.Roles the board's columns
---@param card dev.board.Card the card
---@return boolean before true in Icebox, Backlog or Ready
local function before_work(roles, card)
    return card.column == roles.icebox or card.column == roles.backlog or card.column == roles.ready
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

---Refuse a card that fails the Ready requirements past its size.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@param shape {children: integer, epic: boolean} the card's children and whether it is an epic
---@return dev.cmd.board.Result? refused the failure, nil when the card meets them
local function ready_refusal(backend, card, shape)
    local children, epic = shape.children, shape.epic
    local roles = backend.roles
    local unreadable = guards.unreadable_refusal(card, roles.ready)
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
                .. ". Add outcomes with `dev board outcome` and fix the description with `dev board edit`, where a v1 Done when checklist also counts."
        )
    end
    local unchecked = checks_refusal(backend, card, children)
    if unchecked then
        return unchecked
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
    local roles = backend.roles
    local column, err = named_column(backend, table.concat(words, " ", 2))
    if
        not column
        or column == roles.review
        or column == roles.verify
        or column == roles.release
    then
        local refused = guards.stage_refusal(backend)
        if refused then
            return refused
        end
    end
    if not column then
        return err
    end
    local to_done = column == roles:done_column() and not (opts and opts.drop)
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
    if to_done then
        local refused = guards.done_refusal(card, roles:done_column())
        if refused then
            return refused
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
    if column == roles.ready then
        local refused = size_refusal(card)
        if refused then
            return refused
        end
    end
    local dropping_icebox = opts and opts.drop and card.column == roles.icebox
    if column ~= roles.icebox and column ~= roles.ready and not dropping_icebox then
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
    if not (opts and opts.drop) then
        local refused = guards.children_refusal(backend, card, column, kids)
        if refused then
            return refused
        end
    end
    local starting = column == roles.progress and before_work(roles, card)
    if column == roles.ready then
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
    if column == roles.progress then
        local limit, bad = runner.limit(flags[runner.FLAG])
        if bad then
            return bad
        end
        local refused = runner.refusal(card, limit)
        if refused then
            return refused
        end
        if card.column ~= roles.progress and not claims.read(card.id) then
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
    local skipped = guards.skipped_refusal(roles, card, column)
    if skipped then
        return skipped
    end
    local missing_note = unnoted(backend, card, column)
    if missing_note then
        return missing_note
    end
    local held = claims.read(card.id)
    local started
    if column == roles.progress and not held and not card.claimant then
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
    if held and not started then
        wiring.renew_claim(backend, card, (agent_name()))
        held = claims.read(card.id) or held
    end
    local ok, message, at_limit = backend:move(card.id, column, {
        fence = held and held.fence,
        lane = lane,
        force = board.labelled(card, board.TRUNK_BLOCKER) or nil,
    })
    if not ok then
        if started then
            claims.stop(card.id)
            backend:release(card.id, held.fence)
        end
        if at_limit then
            return runner.full(runner.limits.REFUSED .. message)
        end
        return to_done and unqueued(failure(message)) or failure(message)
    end
    if held and column ~= roles.progress and column ~= roles.blocked then
        claims.stop(card.id)
        local released, why = backend:release(card.id, held.fence)
        if not released then
            verb.note("dev: Moved, but the claim was not released. " .. sentence(why))
        end
    end
    local result = { output = "moved " .. card.id:sub(1, board.MIN_PREFIX) .. " to " .. column }
    if started then
        card.column = column
        return claimed_view(backend, card, result)
    end
    return result
end

---@class dev.cmd.board.move.Opts
---@field drop boolean? skips the outcome check, and the planning check from Icebox
---@field nap (fun(seconds: number))? sleeps between tries, `dev.os.nap` when nil
---@field now (fun(): integer)? the clock in seconds since the epoch, `store.now` when nil

---Move a card, and with `--wait SECONDS` try again while its column is full.
---@param backend dev.board.Backend the board
---@param args string[] the card, the column and the flags
---@param opts dev.cmd.board.move.Opts? the options of `move_once` and the clock
---@return dev.cmd.board.Result result the result of the last try
local function move_card(backend, args, opts)
    local flags = parse(args, MOVE_FLAGS)
    local wait = 0
    if flags and flags[WAIT_FLAG] then
        wait = flags[WAIT_FLAG]:match("^%d+$") and tonumber(flags[WAIT_FLAG])
        if not wait or wait > MAX_WAIT_SECONDS then
            return usage(WAIT_FLAG .. " needs a whole number of seconds up to " .. MAX_WAIT_SECONDS)
        end
    end
    local nap = opts and opts.nap or dev_os.nap
    local clock = opts and opts.now or store.now
    local deadline = clock() + wait
    while true do
        local result = move_once(backend, args, opts)
        local left = deadline - clock()
        if result.code ~= runner.FULL or left <= 0 then
            return result
        end
        nap(math.min(runner.POLL_SECONDS, left))
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
    backend.roles = backend.roles or board.roles(backend.column_map, backend:done_columns() or {})
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
    backend.roles = backend.roles or board.roles(backend.column_map, backend:done_columns() or {})
    local column = named_column(backend, table.concat(words, " ", 2))
    if not column or column ~= backend.roles:done_column() then
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
    for position, card in ipairs(named) do
        local held = claims.read(card.id)
        local ok, why =
            backend:move(card.id, column, { fence = held and held.fence, position = position - 1 })
        if not ok then
            return failure(why)
        end
    end
    local after
    after, message = backend:cards()
    if not after then
        return failure(message)
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
        return usage("--reason needs text")
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
    if not (reason and card.column == backend.roles.icebox) then
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
    steps[#steps + 1] = { sub = "discard_move", args = { words[1], backend.roles:done_column() } }
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
    if color == board.SIZES.unsized and card.column ~= backend.roles.icebox then
        return failure(
            "Card "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. " is outside "
                .. backend.roles.icebox
                .. " and keeps a size. Move it to "
                .. backend.roles.icebox
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

function commands.label(backend, args)
    local edits, removals = {}, {}
    local pos = 2
    while pos <= #args do
        local arg = args[pos]
        pos = pos + 1
        if arg == "--remove" then
            if pos > #args then
                return usage("--remove needs a value")
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
        if
            change.add
            and change.word == board.NEEDS_HUMAN
            and not index_of(labels, change.word)
            and card.column ~= backend.roles.blocked
            and card.column ~= backend.roles.icebox
        then
            return failure(
                "Card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " is in "
                    .. card.column
                    .. ", and "
                    .. board.NEEDS_HUMAN
                    .. " lives only in Blocked or Icebox. Move it there first."
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

local Owner = { SETTLE_SECONDS = 60 }

---Check whether the newest comment on a card is the owner's.
---
---A card in Done never counts. Without `since`, a comment of any age counts.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@param since integer? the time in seconds since the epoch, only a comment newer than it counts
---@return boolean? answered whether the newest comment is the owner's, nil when they could not be
---   read
---@return string? why the reason the comments could not be read
function Owner.commented(backend, card, since)
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

function commands.ask(backend, args)
    local fields = { ["--question"] = "text", ["--recommend"] = "recommended", ["--why"] = "why" }
    if #args < 1 then
        return usage(
            "Needs a card, --question TEXT, --choice COLUMN=LABEL, --recommend N and --why TEXT."
        )
    end
    local question = { choices = {} }
    local i = 2
    while i <= #args do
        local flag, value = args[i], args[i + 1]
        if not value then
            return usage(flag .. " needs a value")
        end
        if flag == "--choice" then
            local column, label = value:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
            if not column or column == "" or label == "" then
                return usage("--choice takes COLUMN=LABEL, not " .. value)
            end
            question.choices[#question.choices + 1] = { column = column, label = label }
        elseif fields[flag] == "recommended" then
            if not value:match("^%d+$") then
                return usage("--recommend takes a choice number, not " .. value)
            end
            question.recommended = tonumber(value)
        elseif fields[flag] then
            question[fields[flag]] = value
        else
            return usage("Unknown flag " .. flag .. ".")
        end
        i = i + 2
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    if index_of(card.labels, board.NEEDS_HUMAN) then
        local answered, why = Owner.commented(backend, card)
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
        local released, why = backend:release(card.id, held.fence)
        if not released then
            verb.note("dev: Asked, but the claim was not released. " .. sentence(why))
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
        return usage("--choice counts from 1, not " .. choice)
    end
    local quote = table.concat(args, " ", quote_at + 1)
    if not quote:find("%S") then
        return usage("--quote needs the owner's words")
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
        if args[i] == AS_FLAG then
            local name = args[i + 1]
            if not name then
                return nil, nil, usage(AS_FLAG .. " needs a name")
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
    local refused = ticks and guards.tick_refused(card, opts.flag)
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
                return "put the flag before the number: dev board outcome CARD "
                    .. word
                    .. " "
                    .. number
            end
            return "the outcome text holds the flag " .. word .. ", which goes right after the card"
        end
    end
    local only = table.concat(args, " ", 2):match("^%s*(%d+)%s*$")
    if only then
        return "the outcome text is only a number; to tick it use dev board outcome CARD --tick "
            .. only
    end
end

function commands.outcome(backend, args)
    local ticker_flag
    local bad
    args, ticker_flag, bad = split_ticker(args)
    if not args then
        return bad
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
            return usage(CONVERT_FLAG .. " takes only the card")
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
            return usage("--rename needs an outcome number and the new text")
        end
        local at
        for i = 5, #args do
            if args[i] == REASON_FLAG then
                at = i
                break
            end
        end
        if not at then
            return usage("--rename needs " .. REASON_FLAG .. " TEXT")
        end
        word, text = args[3], table.concat(args, " ", 4, at - 1)
        reason = table.concat(args, " ", at + 1)
        if not reason:find("%S") then
            return usage(REASON_FLAG .. " needs the reason")
        end
    elseif mode == OutcomeMode.DELETE then
        if #args < 5 or args[4] ~= REASON_FLAG then
            return usage(DELETE_FLAG .. " needs an outcome number and " .. REASON_FLAG .. " TEXT")
        end
        word, text = args[3], table.concat(args, " ", 5)
        if not text:find("%S") then
            return usage(REASON_FLAG .. " needs the reason")
        end
        local agent = os.getenv("DEV_AGENT") or ""
        if not guards.is_lead(agent) then
            return failure(
                "Only the lead deletes an outcome. DEV_AGENT "
                    .. agent
                    .. " is not a lead name, whose role segment is lead. "
                    .. "Ask the lead, with the card, the number and the reason."
            )
        end
    else
        if #args ~= 3 then
            return usage(args[2] .. " needs one outcome number")
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
    elseif mode == OutcomeMode.TICK then
        local refused
        refused, ticker = guards.tick_refused(card, ticker_flag)
        if refused then
            return refused
        end
    end
    if mode == OutcomeMode.DELETE then
        local locked = require("dev.board.outcome_lock").refusal(backend.roles, card.column)
        if locked then
            return unqueued(failure(locked))
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
                        .. sentence(message)
                        .. ' Its text was "'
                        .. deleted_text
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
                        .. sentence(message)
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
    local roles = backend.roles or board.roles()
    if mode == OutcomeMode.TICK and card.column == roles.review then
        local open = false
        for i, outcome in ipairs(card.outcomes) do
            open = open or (i ~= number and not outcome.done)
        end
        if not open then
            local moved, why = backend:move(card.id, roles.verify, { fence = fence })
            if not moved then
                return failure(
                    result.output .. ", but the move to Verify failed. " .. sentence(why)
                )
            end
            result.output = result.output .. "\nmoved " .. prefix .. " to " .. roles.verify
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
    if card.column ~= backend.roles.icebox then
        local missing = board.backlog_missing(args[2])
        if #missing > 0 then
            return failure(
                "Card "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " is outside "
                    .. backend.roles.icebox
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
    if not name:find("%S") or #name > NAME_CHARS or not name:find(NAME_PATTERN) then
        return usage(
            "A title is one line of up to "
                .. NAME_CHARS
                .. " characters, with no quotes or backslashes."
        )
    end
    local cards, message = backend:cards()
    if not cards then
        return failure(message)
    end
    local card, why = board.resolve(cards, args[1])
    if not card then
        return usage(why)
    end
    local held_back = owner_holds(card)
    if held_back then
        return held_back
    end
    local held = claims.read(card.id)
    local ok
    ok, message = backend:set_name(card.id, name, held and held.fence)
    if not ok then
        return failure(message)
    end
    return { output = "renamed " .. card.id:sub(1, board.MIN_PREFIX) }
end

---Count things with the noun in the singular or the plural.
---@param count integer how many
---@param noun string the noun in the singular
---@return string text the count and the noun
local function counted(count, noun)
    return count .. " " .. noun .. (count == 1 and "" or "s")
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
    return { output = "set checks " .. short .. ", " .. counted(#runs, "row") }
end

function commands.check(backend, args)
    local opts, err = wiring.check_options(args)
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
    local flags, words = parse(
        args,
        { [KIND_FLAG] = true, [BY_FLAG] = true, [REV_FLAG] = true, [review.VERDICT_FLAG] = true }
    )
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
        recorded = record and record.change or recorded
    end
    if recorded and recorded ~= rev.change then
        return failure(
            string.format(
                "Card %s records change %s but this commit is change %s. Run `dev board review` from the change's workspace.",
                short,
                recorded,
                rev.change
            )
        )
    end
    if card.claimant then
        wiring.renew_claim(backend, card, card.claimant)
    end
    local held = claims.read(card.id)
    local ok
    ok, message = backend:note(
        card.id,
        review.record(kind, by, rev, verdict),
        held and held.fence,
        { kind = board.NoteKind.STATUS }
    )
    if not ok then
        return failure(
            string.format(
                "The review was NOT recorded on card %s. %s The board may or may not hold it. Read `dev board notes` before repeating it.",
                short,
                sentence(message)
            )
        )
    end
    return {
        output = string.format(
            "recorded %s review by %s on %s at commit %s",
            kind,
            by,
            short,
            rev.commit:sub(1, COMMIT_CHARS)
        ),
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
    local flags, words = parse(args, { [WAIT_FLAG] = true })
    if not flags then
        return words
    end
    if #words < 1 then
        return usage("Needs a card.")
    end
    local wait = 0
    if flags[WAIT_FLAG] then
        wait = flags[WAIT_FLAG]:match("^%d+$") and tonumber(flags[WAIT_FLAG])
        if not wait or wait > MAX_WAIT_SECONDS then
            return usage(WAIT_FLAG .. " needs a whole number of seconds up to " .. MAX_WAIT_SECONDS)
        end
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
    local list, message = backend:comments(card.id)
    if not list then
        return failure(message)
    end
    local early = wiring.card_problems(backend, card, { name = name, comments = list })
    if #early > 0 then
        local all = wiring.land_problems(backend, card, { name = name, comments = list })
        local kept = turn.held(backend, name, short)
        return failure(
            "Card "
                .. short
                .. " cannot land for these reasons.\n  - "
                .. table.concat(all, "\n  - ")
                .. (kept and wiring.kept_note(short) or "")
        )
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
    local kept = hold
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
            hold = kept,
        })
        if refused then
            if kept and refused.code and not refused.lost then
                refused.message = refused.message .. wiring.kept_note(short)
                return refused
            end
            if kept then
                turn.release(backend, kept)
            end
            return refused
        end
        hold = kept
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
            move = move_card,
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
            .. (kept and wiring.kept_note(short) or "")
    )
end

---@class dev.cmd.board.ShipRun
---@field argv string[] the command's words
---@field run string the command as one line

---Read the commands a ship runs: the words after `--`, else the `[board.release]` checks rows.
---@param backend dev.board.Backend the board
---@param args string[] the arguments, with a `--` in front of any command
---@return dev.cmd.board.ShipRun[]? runs the commands, nil on a refusal
---@return dev.cmd.board.Result? err the refusal
local function ship_runs(backend, args)
    local split = index_of(args, "--")
    if split and split > 1 then
        return nil, usage("Takes no argument before --, only the release command after it.")
    end
    if split then
        if #args == 1 then
            return nil, usage("Needs a command after --.")
        end
        local argv = { unpack(args, 2) }
        return { { argv = argv, run = table.concat(argv, " ") } }
    end
    if #args > 0 then
        return nil, usage("Takes the release command after --, not " .. args[1] .. ".")
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
---@param runs dev.cmd.board.ShipRun[] the commands
---@return dev.cmd.board.Result? err the failure naming the command, nil when every one passed
local function ship_ran(backend, runs)
    local remote = require("dev.remote")
    local rows = {}
    for i, one in ipairs(runs) do
        verb.note(string.format("Running row %d of %d with `%s`.", i, #runs, one.run))
        rows[i] = check.run({
            root = backend.root,
            run = one.run,
            argv = one.argv,
            seconds = check.DEFAULT_SECONDS,
            env = { [remote.VERB_ENV] = remote.Verb.RELEASE, [remote.PRIORITY_ENV] = "1" },
        })
        if rows[i].result ~= check.Result.PASS then
            return failure(
                string.format(
                    "The release command `%s` failed. No card moved.\n%s",
                    one.run,
                    table.concat(wiring.check_lines(rows), "\n")
                )
            )
        end
    end
end

local Ship = { DEFAULT_REV = "trunk()" }

---Split `--rev REV` off the words before `--`.
---@param args string[] the ship arguments
---@return string? rev the revision, the default when no flag was given, nil on a refusal
---@return string[]|dev.cmd.board.Result rest the other arguments, or the refusal
function Ship.rev(args)
    local flag = "--rev"
    local split = index_of(args, "--") or (#args + 1)
    local rev, rest = Ship.DEFAULT_REV, {}
    local i = 1
    while i <= #args do
        if i < split and args[i] == flag then
            if i + 1 >= split then
                return nil, usage(flag .. " needs a value")
            end
            rev = args[i + 1]
            i = i + 2
        else
            rest[#rest + 1] = args[i]
            i = i + 1
        end
    end
    return rev, rest
end

---Say why a Release card cannot ship at a revision.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the Release card
---@param commit string the commit the ship covers
---@param name string what to call that revision
---@return string? reason why it stays, nil when it may move
---@return string? landed the card's landed commit when it may move
function Ship.reason(backend, card, commit, name)
    if guards.done_refusal(card, backend.roles:done_column()) then
        return "an outcome is not ticked"
    end
    local comments = backend:comments(card.id)
    local landed = comments and land.landed_commit(comments)
    if not landed then
        return "no landed commit in its notes"
    end
    if not land.holds(backend.root, landed, commit) then
        return "landed commit " .. land.short(landed) .. " is not in " .. name
    end
    return nil, landed
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
    local synced = templates.changed(paths)
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
---@return string[] lines what moved and what stayed
---@return boolean ok false when a note or a move failed
local function ship_batch(backend, cards, rev, commit)
    local name = rev == Ship.DEFAULT_REV and "trunk" or rev
    local text = string.format("Shipped in %s, commit %s.", name, land.short(commit))
    local moved, kept, stranded, ok = {}, {}, {}, true
    local landed_commits = {}
    for _, card in ipairs(cards) do
        local short = card.id:sub(1, board.MIN_PREFIX)
        local reason, landed = Ship.reason(backend, card, commit, name)
        if landed then
            landed_commits[#landed_commits + 1] = landed
        end
        if reason then
            kept[#kept + 1] = "  " .. short .. " " .. card.name .. " (" .. reason .. ")"
        else
            local result = move_card(backend, { card.id, backend.roles:done_column() })
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
                    .. " ("
                    .. (why or "the note was not written")
                    .. ")"
            else
                ok = false
                kept[#kept + 1] = "  "
                    .. short
                    .. " "
                    .. card.name
                    .. " ("
                    .. (result and result.message or why)
                    .. ")"
            end
        end
    end
    local lines = {
        string.format(
            "shipped %s at %s commit %s",
            count_text(#moved, "card"),
            name,
            land.short(commit)
        ),
    }
    for _, line in ipairs(moved) do
        lines[#lines + 1] = line
    end
    if #kept > 0 then
        lines[#lines + 1] = "left in " .. backend.roles.release .. ":"
        for _, line in ipairs(kept) do
            lines[#lines + 1] = line
        end
    end
    if #stranded > 0 then
        lines[#lines + 1] = "moved to "
            .. backend.roles:done_column()
            .. " with no done note, write it by hand:"
        for _, line in ipairs(stranded) do
            lines[#lines + 1] = line
        end
    end
    for _, line in ipairs(ship_templates(backend.root, landed_commits)) do
        lines[#lines + 1] = line
    end
    return lines, ok
end

function commands.ship(backend, args)
    local rev, rest = Ship.rev(args)
    if not rev then
        return rest
    end
    local runs, err = ship_runs(backend, rest)
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
    local failed = ship_ran(backend, runs)
    if failed then
        return failed
    end
    local cards, message = backend:cards()
    if not cards then
        return failure(message)
    end
    local waiting = {}
    for _, card in ipairs(cards) do
        if card.column == backend.roles.release then
            waiting[#waiting + 1] = card
        end
    end
    local lines, ok = ship_batch(backend, waiting, rev, commit)
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
    local seconds, wait = turn.HOLD_SECONDS, 0
    if flags[HOLD_FLAG] then
        seconds = flags[HOLD_FLAG]:match("^%d+$") and tonumber(flags[HOLD_FLAG])
        if not seconds or seconds < 1 or seconds > turn.MAX_HOLD_SECONDS then
            return usage(
                HOLD_FLAG
                    .. " needs a whole number of seconds up to "
                    .. turn.MAX_HOLD_SECONDS
                    .. "."
            )
        end
    end
    if flags[WAIT_FLAG] then
        wait = flags[WAIT_FLAG]:match("^%d+$") and tonumber(flags[WAIT_FLAG])
        if not wait or wait > MAX_WAIT_SECONDS then
            return usage(
                WAIT_FLAG .. " needs a whole number of seconds up to " .. MAX_WAIT_SECONDS .. "."
            )
        end
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
        return nil, usage(board.ALLOW_NONE .. " clears the allow field and takes no other word")
    end
    return words, none
end

function commands.allow(backend, args)
    local words, none = parse_allow(args)
    if not words then
        return none
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
    local card, short = write_field(backend, args[1], key, function(id, fence)
        return backend:set_field(id, key, table.concat(names, "\n"), fence)
    end)
    if not card then
        return short
    end
    return { output = "set " .. noun .. "s " .. short .. ", " .. counted(#names, "name") }
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

function commands.delete(backend, args)
    local flags, words = parse(args, { ["--reason"] = true })
    if not flags then
        return words
    end
    local reason = flags["--reason"]
    if #words ~= 1 or reason == nil or reason:find("^%s*$") then
        return usage("Needs a card and --reason TEXT.")
    end
    local refused = guards.delete_refusal()
    if refused then
        return refused
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
        lines[i] = column.name .. (column.is_done and DONE_MARK or "")
    end
    return { output = table.concat(lines, "\n") }
end

local function set_limit(backend, value, words)
    local limit = value:match("^%d+$") and tonumber(value)
    if not limit or limit < 1 then
        return usage("--set needs a whole number of at least 1")
    end
    if #words > 0 then
        return usage("--set changes only this project's board")
    end
    local roles = backend.roles
    local columns = { roles.progress, roles.review, roles.verify }
    local done, message = backend:set_limit_group(columns, limit)
    if not done then
        if message:find("pomb answered 403", 1, true) then
            return failure(
                "Pomb refused the change. This token may not edit the board, "
                    .. "so use a lead token, which holds columns.edit."
            )
        end
        return failure(message)
    end
    return {
        output = string.format(
            "Set the limit of %s, %s and %s to %d.",
            roles.progress,
            roles.review,
            roles.verify,
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
        lines[#lines + 1] = "no limit group"
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

local function append(lines, more)
    for _, line in ipairs(more) do
        lines[#lines + 1] = line
    end
end

---Check whether `next` would skip an unclaimed card: a run card, an epic with an open child, or a
---card an open card blocks.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@return boolean? skipped, string? why nil with the reason when the board could not be read
local function skipped_by_next(backend, card)
    if board.labelled(card, board.RUN) or board.open_children(card.epic) > 0 then
        return true
    end
    return backend:blocked(card.id)
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
            usage(flag .. " needs a whole number of " .. opts.unit .. ", 1 or more: " .. value)
    end
    return limit
end

local function icebox_latest(backend, card, stamp, limit, now)
    local latest = stamp and box.parse_time(stamp)
    if not latest then
        return nil, "could not date " .. card.id .. " " .. card.name
    end
    if (now - latest) / box.SECONDS_PER_DAY < limit then
        return nil
    end
    local list = backend:comments(card.id)
    if not list then
        return nil, "could not read the comments of " .. card.id .. " " .. card.name
    end
    for _, comment in ipairs(list) do
        local at = box.parse_time(comment.at)
        if not at then
            return nil, "could not read the comments of " .. card.id .. " " .. card.name
        end
        latest = math.max(latest, at)
    end
    return latest
end

local function icebox_rows(backend, cards, entered, limit, now)
    local found, undated = {}, {}
    for _, card in ipairs(cards) do
        if
            card.column == backend.roles.icebox
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
    local roles = backend.roles
    local flying = { [roles.progress] = true, [roles.review] = true, [roles.verify] = true }
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
    local roles = backend.roles
    local started = { [roles.progress] = true, [roles.review] = true }
    local waiting = { [roles.backlog] = true, [roles.ready] = true }
    local found, warnings, others = {}, {}, {}
    for _, card in ipairs(cards) do
        local list
        if waiting[card.column] and not card.done then
            local why
            list, why = backend:links(card.id)
            if not list then
                warnings[#warnings + 1] = "could not read the links of "
                    .. card.id
                    .. " "
                    .. card.name
                    .. ": "
                    .. tostring(why)
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
                    warnings[#warnings + 1] = "could not read blocker "
                        .. target
                        .. " of "
                        .. card.id
                        .. " "
                        .. card.name
                        .. ": "
                        .. tostring(other.failed or message)
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

function commands.stale(backend, args, now)
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
    local roles = backend.roles
    local found, owner, moved, undated, unsized, commented = {}, {}, {}, {}, {}, {}
    local lead, planner, nobody = {}, {}, {}
    for _, card in ipairs(cards) do
        if
            card.column == roles.blocked
            and not card.done
            and not index_of(card.labels, board.NEEDS_HUMAN)
            and not index_of(card.labels, board.NEEDS_LEAD)
            and not index_of(card.labels, board.NEEDS_PLANNER)
        then
            local at = entered[card.id] and box.parse_time(entered[card.id])
            if not at then
                undated[#undated + 1] = "could not date " .. card.id .. " " .. card.name
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
            card.column == roles.blocked
            and not card.done
            and asks
            and not index_of(card.labels, board.NEEDS_HUMAN)
        then
            local at = entered[card.id] and box.parse_time(entered[card.id])
            if not at then
                undated[#undated + 1] = "could not date " .. card.id .. " " .. card.name
            else
                local hours = math.floor((now - at) / box.SECONDS_PER_HOUR)
                if hours >= lead_limit then
                    local skipped = false
                    if not card.claimant then
                        local why
                        skipped, why = skipped_by_next(backend, card)
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
        if card.column ~= roles.icebox and board.has_color(card, board.SIZES.unsized) then
            unsized[#unsized + 1] = card
        end
        local mine = index_of(card.labels, board.NEEDS_HUMAN) ~= nil
        local held = mine and (card.column == roles.blocked or card.column == roles.icebox)
        if not held then
            local spoke, why = Owner.commented(backend, card)
            if spoke == nil then
                if card.column ~= roles.icebox then
                    undated[#undated + 1] = why
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
        if mine or (not card.done and roles.stale[card.column]) then
            local stamp = entered[card.id]
            if not stamp then
                undated[#undated + 1] = "could not date " .. card.id .. " " .. card.name
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
                        local answered, why = Owner.commented(backend, card)
                        if answered == nil then
                            undated[#undated + 1] = why
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
    table.sort(undated)
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
    local fresh = {}
    for _, item in ipairs(commented) do
        if not listed[item.id] then
            fresh[#fresh + 1] = item
        end
    end
    commented = fresh
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
        lines[#lines + 1] = "unsized outside " .. roles.icebox .. ":"
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

function commands.lint(backend, args)
    local flags, words = parse(args, { [STRICT_FLAG] = SWITCH })
    if not flags then
        return words
    end
    if #words > 1 then
        return usage("Takes at most one card.")
    end
    local strict = flags[STRICT_FLAG] == true
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
    for _, card in ipairs(cards) do
        local facts = {
            comments = function()
                local list, why = backend:comments(card.id)
                if not list then
                    return nil, "could not read the comments of " .. card.id .. ": " .. why
                end
                return list
            end,
            links = function()
                local list, why = backend:links(card.id)
                if not list then
                    return nil, "could not read the links of " .. card.id .. ": " .. why
                end
                return list
            end,
            children = function()
                local family, why = backend:family(card.id)
                if not family then
                    return nil, "could not read the family of " .. card.id .. ": " .. why
                end
                local counts = family.children or { done = 0, total = 0 }
                return { done = counts.done, total = counts.total, epic = family.epic }
            end,
        }
        local rules, why, owned =
            lint.card(card, { roles = backend.roles, facts = facts, strict = strict })
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
    local roles = backend.roles
    local rival = not from and card.claimant ~= nil and card.claimant ~= (name or claimant())
    if card.claimant == nil or from then
        local shaped = runner.shape_refusal(name)
        if shaped then
            return shaped
        end
    end
    if card.claimant == nil and before_work(roles, card) then
        local shape, why_family = family_shape(backend, card)
        if not shape then
            return failure(why_family)
        end
        refused = checks_refusal(backend, card, shape.children)
        if refused then
            return refused
        end
    end
    local limited = card.column ~= roles.progress and not claims.read(card.id) and not rival
    if limited then
        refused = runner.limited(backend, card, roles.progress)
        if refused then
            return refused
        end
    end
    if from then
        local held = claims.read(card.id)
        local released, stuck = backend:release(card.id, held and held.fence)
        if not released then
            return failure(stuck)
        end
        claims.stop(card.id)
    end
    local result, fence = claim_card(backend, card, name)
    if not fence then
        return result
    end
    if from then
        local ok, message = backend:note(
            card.id,
            string.format("handoff: %s released the claim and %s took it", from, claimant(name)),
            fence,
            { kind = board.NoteKind.STATUS }
        )
        if not ok then
            verb.note(
                "Took card "
                    .. short
                    .. ", but the handoff note was not posted. "
                    .. sentence(message)
            )
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
    local ok, message = backend:release(card.id, held.fence)
    if not ok then
        return failure(message)
    end
    claims.stop(card.id)
    return {
        output = string.format(
            "released %s, fence %d",
            card.id:sub(1, board.MIN_PREFIX),
            held.fence
        ),
    }
end

local function run_card_for(cards, name)
    for _, card in ipairs(cards) do
        if board.labelled(card, board.RUN) and not card.done and card.name == RUN_NAME .. name then
            return card
        end
    end
end

local function start_run(backend, name, orders)
    local RUN_ORDERS_WORDS = 250
    local RUN_SIZE = "3"
    local RUN_CHECK = "dev board lint"
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
        return usage(RUN_ORDERS_FLAG .. " needs the orders")
    end
    if words > RUN_ORDERS_WORDS then
        return usage(
            string.format(
                "The orders are %d words and a run card holds at most %d. "
                    .. "Keep the rest in a file and name it in the orders.",
                words,
                RUN_ORDERS_WORDS
            )
        )
    end
    local args = {
        RUN_NAME .. name,
        "--column",
        backend.roles.progress,
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
    local added = commands.add(backend, args)
    if added.message then
        return added
    end
    local card, err = find_card(backend, added.output:match("^added (%S+)"))
    if not card then
        return err
    end
    local taken, fence = claim_card(backend, card, name)
    if not fence then
        taken.message = sentence(taken.message) .. " `dev board run` claims the new run card again."
        return taken
    end
    local shown = M.run("show", { card.id }, backend)
    if shown.message then
        return shown
    end
    return {
        output = "started " .. card.id:sub(1, board.MIN_PREFIX) .. "\n" .. shown.output,
        warnings = added.warnings,
    }
end

local function resume_run(backend, opts)
    local cards, run, name = opts.cards, opts.run, opts.name
    local warnings = {}
    if not run.claimant then
        local taken, fence = claim_card(backend, run, name)
        if not fence then
            warnings[1] = taken.message
        end
    end
    local shown = M.run("show", { run.id }, backend)
    if shown.message then
        return shown
    end
    local held = {}
    for _, card in ipairs(cards) do
        if card.claimant == name and card.id ~= run.id and not card.done then
            held[#held + 1] = card_line(card)
        end
    end
    local limit = runner.limit()
    local upcoming, message = backend:next(backend.roles.ready, { max_size = limit })
    if not upcoming and message then
        return failure(message)
    end
    return {
        output = table.concat({
            shown.output,
            "held by " .. name .. ":",
            #held > 0 and table.concat(held, "\n") or "nothing",
            "next:",
            upcoming and card_line(upcoming) or "no ready cards",
        }, "\n"),
        warnings = warnings,
    }
end

function commands.run(backend, args)
    local RUN_USAGE = "Start one with `dev board run --orders TEXT`."
    local ending, rest = false, {}
    for _, arg in ipairs(args) do
        if arg == RUN_END_FLAG then
            ending = true
        else
            rest[#rest + 1] = arg
        end
    end
    local flags, words = parse(rest, { [RUN_ORDERS_FLAG] = true }, { [RUN_ORDERS_FLAG] = true })
    if not flags then
        return words
    end
    if flags[RUN_ORDERS_FLAG] and #flags[RUN_ORDERS_FLAG] > 1 then
        return usage(RUN_ORDERS_FLAG .. " takes one value, so give the orders once")
    end
    flags[RUN_ORDERS_FLAG] = flags[RUN_ORDERS_FLAG] and flags[RUN_ORDERS_FLAG][1]
    if #words > 0 then
        return usage("Unknown argument " .. words[1] .. ".")
    end
    if ending and flags[RUN_ORDERS_FLAG] then
        return usage(RUN_END_FLAG .. " and " .. RUN_ORDERS_FLAG .. " do not go together")
    end
    local name, why = agent_name()
    if why then
        return why
    end
    local session = os.getenv("CLAUDE_SESSION_ID")
    if not name and (not session or session == "") then
        return usage("Run needs DEV_AGENT or CLAUDE_SESSION_ID, so the session keeps one name.")
    end
    name = claimant(name)
    if #RUN_NAME + #name > NAME_CHARS then
        return usage("The session name is too long for a card name.")
    end
    local cards, message = backend:cards()
    if not cards then
        return failure(message)
    end
    local run = run_card_for(cards, name)
    if flags[RUN_ORDERS_FLAG] then
        if run then
            return failure(
                name
                    .. " already has the run card "
                    .. run.id:sub(1, board.MIN_PREFIX)
                    .. ". Close it with `dev board run "
                    .. RUN_END_FLAG
                    .. "` first."
            )
        end
        return start_run(backend, name, flags[RUN_ORDERS_FLAG])
    end
    if not run then
        return failure("There is no open run card for " .. name .. ". " .. RUN_USAGE)
    end
    if ending then
        local closed = M.run("discard", { run.id, "--reason", "the run ended" }, backend)
        if closed.message then
            return closed
        end
        return { output = "ended " .. run.id:sub(1, board.MIN_PREFIX), warnings = closed.warnings }
    end
    return resume_run(backend, { cards = cards, run = run, name = name })
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

local function open_backend(settings, token)
    if settings.backend == board.Backend.LOCAL then
        if settings.path then
            return localboard.new({ name = settings.name, path = settings.path })
        end
        if not settings.name:find(LOCAL_NAME_PATTERN) or #settings.name > NAME_CHARS then
            return nil,
                "dev: A local board's name must be letters, digits, dots, dashes and underscores to name its file. Otherwise set the `path` setting of `[board]`."
        end
        return localboard.new({
            name = settings.name,
            path = store.dir() .. "/" .. settings.name .. ".json",
            private = true,
        })
    end
    local backend, message = pomb.new({
        url = config.user("board.pomb.url"),
        token = config.user("board.pomb." .. token),
        name = settings.name,
        lead = token == LEAD_TOKEN_KEY,
    })
    if not backend then
        return nil, "dev: " .. sentence(message)
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
    local token = opts and opts.token_key or TOKEN_KEY
    local backend, message = open_backend(settings, token)
    if backend then
        board.retarget(backend, settings.columns, settings.root)
    end
    return backend, message
end

local function column_map(root)
    local columns = {}
    for _, role in ipairs(board.ROLES) do
        columns[role] = config.get(root, "board.columns." .. role)
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
            'dev: The `backend` setting of `[board]` must be "pomb" or "local" in `.dev/config.toml`.'
        )
    end
    local name = config.get(ctx.root, "board.name")
    if name == nil then
        name = fs.basename(ctx.root)
    end
    if type(name) ~= "string" or name == "" then
        verb.die(
            "dev: The `name` setting of `[board]` must be a non-empty string in `.dev/config.toml`."
        )
    end
    local path = config.get(ctx.root, "board.path")
    if path ~= nil then
        if backend ~= board.Backend.LOCAL then
            verb.die('dev: The `path` setting of `[board]` only applies to `backend = "local"`.')
        end
        if
            type(path) ~= "string"
            or not path:find(PATH_PATTERN)
            or path:find("..", 1, true)
            or path:find("//", 1, true)
        then
            verb.die(
                "dev: The `path` setting of `[board]` must be a relative path inside the project, such as `.dev/board.json`."
            )
        end
        path = ctx.root .. "/" .. path
    end
    return {
        backend = backend,
        name = name,
        path = path,
        root = ctx.root,
        columns = column_map(ctx.root),
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

local function has_section(root)
    local text = fs.exists(root .. "/.dev/config.toml") and fs.read(root .. "/.dev/config.toml")
    local tree = text and toml.parse(text)
    return type(tree) == "table" and tree.board ~= nil
end

local function board_name(ctx, flags)
    local backend = config.get(ctx.root, "board.backend")
    local name = config.get(ctx.root, "board.name")
    if backend == nil and has_section(ctx.root) then
        verb.die('dev: The `[board]` section needs `backend = "pomb"` in `.dev/config.toml`.')
    end
    if backend ~= nil and backend ~= board.Backend.POMB then
        verb.die(
            'dev: The `backend` setting of `[board]` must be "pomb" or "local" in `.dev/config.toml`.'
        )
    end
    local asked = flags["--name"]
    if backend == nil then
        if not asked then
            verb.die(
                "dev: This project has no `[board]` section. Pass `--name N` to make a board and write it."
            )
        end
        name = asked
    else
        name = name or fs.basename(ctx.root)
        if asked and asked ~= name then
            verb.usage_error(
                ctx,
                "--name " .. asked .. " is not the [board] name " .. tostring(name)
            )
        end
    end
    if
        type(name) ~= "string"
        or #name == 0
        or #name > NAME_CHARS
        or not name:find(NAME_PATTERN)
    then
        verb.die("dev: The board's name must be 1 to 100 characters with no quote or backslash.")
    end
    return name, backend == nil
end

local function write_section(root, name)
    local path = root .. "/.dev/config.toml"
    local existing = fs.exists(path) and fs.read(path) or ""
    local gap = existing == "" and "" or (existing:sub(-1) == "\n" and "\n" or "\n\n")
    local section = '[board]\nbackend = "pomb"\nname = ' .. string.format("%q", name) .. "\n"
    assert(toml.parse(existing .. gap .. section), "dev: .dev/config.toml would not parse")
    local ok, message = true, nil
    if not fs.is_dir(root .. "/.dev") then
        ok, message = fs.mkdir(root .. "/.dev")
    end
    if ok then
        ok, message = fs.write(path, existing .. gap .. section)
    end
    if not ok then
        verb.die("dev: Cannot write " .. path .. ". " .. sentence(tostring(message)))
    end
end

local function host()
    return (dev_os.capture({ "hostname", "-s" }, { stderr = "null" }):gsub("%s+$", ""))
end

local function config_lanes(ctx)
    local lanes = config.get(ctx.root, "board.lanes")
    if lanes == nil then
        return {}
    end
    local ok = type(lanes) == "table"
    for _, lane in ipairs(ok and lanes or {}) do
        ok = ok and type(lane) == "string" and lane ~= ""
    end
    if not ok then
        verb.die(
            "dev: The `lanes` setting of `[board]` must be a list of lane names in `.dev/config.toml`."
        )
    end
    return lanes
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
    local changes
    changes, message = init.run(backend, found.name, verb.say, {
        roles = backend.roles,
        lanes = config_lanes(ctx),
        warn_first_lane = false,
    })
    if not changes then
        verb.die("dev: " .. sentence(message))
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
    local name, missing = board_name(ctx, flags)
    local opts = {
        url = config.user("board.pomb.url"),
        token = config.user("board.pomb.lead_token"),
        name = name,
        lead = not admin,
    }
    if not admin and opts.token == nil then
        verb.die(
            "dev: The `lead_token` setting of `[board.pomb]` is not set in `~/.config/dev/config.toml`. "
                .. "Set it to `pass:<entry>` or run with `--admin`."
        )
    end
    local backend, message = pomb.new(opts)
    if not backend then
        verb.die("dev: " .. sentence(message))
    end
    backend.roles = board.roles(column_map(ctx.root))
    if admin then
        local secret
        secret, message = device.pair({
            url = opts.url,
            client_name = ("dev-board-init@" .. host()):sub(1, CLIENT_CHARS),
            scope = ADMIN_SCOPE,
            say = print,
        })
        if not secret then
            verb.die("dev: " .. sentence(message))
        end
        backend:authorize(secret)
        local ok
        ok, message = backend:admin()
        if not ok then
            verb.die("dev: " .. sentence(message))
        end
    end
    local changes
    changes, message = init.run(backend, name, verb.say, {
        roles = backend.roles,
        lanes = config_lanes(ctx),
        warn_first_lane = true,
    })
    if not changes then
        verb.die("dev: " .. sentence(message))
    end
    if missing then
        write_section(ctx.root, name)
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
        return nil, "needs a card, and the description from --file PATH or standard input"
    end
    local text, message
    if flags["--file"] then
        text, message = fs.read(flags["--file"])
        if not text then
            return nil, "cannot read " .. flags["--file"] .. ": " .. tostring(message)
        end
    elseif dev_os.isatty(0) then
        return nil, "needs the description from --file PATH or standard input"
    else
        text = io.read("*a")
    end
    text = text:gsub("%s+$", "")
    if text == "" then
        return nil, "the new description is empty"
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
local function replay(backend, pending, say)
    local drained, message = pending:drain(function(entry)
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
        return nil, message
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
        return nil, "this project has no board"
    end
    local backend, message = M.open(settings({ root = root }))
    if not backend then
        return nil, (message:gsub("^dev: ", ""))
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
        local waiting, why = pending:count()
        if not waiting then
            stderr_line("dev: " .. sentence(why) .. " The queue is left in place.")
        elseif waiting > 0 then
            replay(backend, pending, stderr_news)
        end
    end
    return backend, pending
end

local function open_lead(ctx, action, permission)
    local refused = guards.delete_refusal(action)
    if refused then
        verb.die("dev: " .. sentence(refused.message))
    end
    local found = settings(ctx)
    if found.backend ~= board.Backend.POMB then
        verb.die("dev: " .. NO_BIN)
    end
    if config.user("board.pomb." .. LEAD_TOKEN_KEY) == nil then
        verb.die(
            "dev: The `lead_token` setting of `[board.pomb]` is not set in `~/.config/dev/config.toml`."
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
    local flags, extra = parse(ctx.args, { ["--role"] = true, ["--as"] = true })
    if not flags then
        verb.usage_error(ctx, extra.message)
    elseif #extra > 0 then
        verb.usage_error(ctx, "unknown argument " .. extra[1])
    elseif not flags["--role"] or not flags["--as"] or flags["--as"] == "" then
        verb.usage_error(ctx, "needs --role ROLE and --as NAME")
    end
    local backend = open_lead(ctx, "mints a role token")
    local issued, message = backend:mint(flags["--role"], flags["--as"])
    if not issued then
        verb.die("dev: " .. sentence(message))
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
        verb.die("dev: " .. sentence(message))
    end
    print(
        done.revoked and ("revoked the role token of " .. flags["--as"])
            or ("Nothing was left to revoke for " .. flags["--as"] .. ".")
    )
    return 0
end

M.handlers["board status"] = function(ctx)
    verb.no_args(ctx)
    local found = settings(ctx)
    print("backend: " .. found.backend)
    print("board: " .. found.name)
    if found.backend == board.Backend.POMB then
        local pending = queue.new(found.name)
        local waiting, why = pending:count()
        if not waiting then
            stderr_line("dev: " .. sentence(why) .. " The queue is left in place.")
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
    return 0
end

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
local WAIT_LIMITED_NOTICE =
    "dev: pomb holds too many open waits for this token, waiting for one to end"

local function cursor_path(name)
    return store.dir() .. "/" .. name:gsub("[^%w._-]", "_")
end

local function read_cursor(path)
    local text = fs.exists(path) and fs.read(path)
    text = text and text:gsub("%s+", "")
    return text ~= "" and text or nil
end

local function lead_cards(backend, roles, label)
    local cards, message = backend:cards()
    if not cards then
        return nil, message
    end
    local waiting = {}
    for _, card in ipairs(cards) do
        if
            card.column == roles.blocked
            and not card.claimant
            and index_of(card.labels, label)
            and not index_of(card.labels, board.NEEDS_HUMAN)
        then
            local skipped, why = skipped_by_next(backend, card)
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
---@return table<string, boolean>? spoke the ids of the cards, nil when the board could not be read
---@return string? why the reason the board could not be read
function Owner.comments(backend, events, since)
    local spoke = {}
    local cards
    for _, event in ipairs(events) do
        if event.kind == EventKind.COMMENTED and type(event.task_id) == "string" then
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
                local found, why = Owner.commented(backend, card, since)
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
function Owner.departed(backend, sat)
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
---@param roles dev.board.Roles the column names
---@return table<string, string>? sat the column of each card in Blocked or Icebox
---@return string? why the reason the board could not be read
function Owner.sitting(backend, roles)
    local cards, message = backend:cards()
    if not cards then
        return nil, message
    end
    local sat = {}
    for _, card in ipairs(cards) do
        if card.column == roles.blocked or card.column == roles.icebox then
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
function Owner.stage_cards(backend, column)
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
    local only, roles, leads = opts.only, opts.roles, opts.leads
    local spoke = opts.spoke
    local id = event.task_id:sub(1, board.MIN_PREFIX)
    local added = event.kind == EventKind.ADDED
    if only == WaitFor.LEAD or only == WaitFor.PLANNER then
        if leads[event.task_id] then
            leads[event.task_id] = nil
            return id .. " is labelled " .. board.BLOCKED_LABELS[only] .. " in " .. roles.blocked
        end
    elseif only == WaitFor.HUMAN then
        if
            event.kind == EventKind.MOVED
            and event.from_column == roles.blocked
            and event.actor == HUMAN_ACTOR
            and event.at
            and event.at >= opts.started
        then
            return "moved " .. id .. " out of " .. roles.blocked
        end
        if event.kind == EventKind.COMMENTED and spoke[event.task_id] then
            spoke[event.task_id] = nil
            return "the owner commented on " .. id
        end
    elseif WaitFor.STAGES[only] then
        if
            event.column == roles[only]
            and (added or event.kind == EventKind.MOVED)
            and opts.stage[event.task_id]
        then
            return (added and "added " or "moved ") .. id .. " to " .. roles[only]
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
    local flags, words = parse(args, { ["--for"] = true })
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
    local roles = backend.roles or board.roles()
    local legacy = guards.stage_refusal(backend)
    if legacy then
        return legacy
    end
    local nap = opts.nap or dev_os.nap
    local random = opts.random or turn.entropy
    local notice = opts.notice or stderr_line
    local limited = 0
    local told = false
    local clock = opts.now or store.now
    local started = clock()
    local held, touched, last = {}, {}, nil
    local sat
    if only == WaitFor.HUMAN then
        local why
        sat, why = Owner.sitting(backend, roles)
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
            last and math.max(1, Owner.SETTLE_SECONDS - (clock() - last))
        )
        local leads
        if reply and board.BLOCKED_LABELS[only] and #reply.events > 0 then
            local why
            leads, why = lead_cards(backend, roles, board.BLOCKED_LABELS[only])
            if not leads then
                if not pomb.unreachable(why, true) then
                    return failure(why)
                end
                reply, message = nil, why
            end
        end
        local spoke
        if reply and only == WaitFor.HUMAN then
            local why
            spoke, why = Owner.comments(backend, reply.events, started)
            if not spoke then
                if not pomb.unreachable(why, true) then
                    return flush(failure(why))
                end
                reply, message = nil, why
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
                stage, why = Owner.stage_cards(backend, roles[only])
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
                        roles = roles,
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
                if #reply.events == 0 or clock() - last >= Owner.SETTLE_SECONDS then
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
                local gone, reason = Owner.departed(backend, sat)
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
        elseif pomb.unreachable(message, true) then
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

M.handlers["board wait"] = function(ctx)
    local found = settings(ctx)
    if found.backend ~= board.Backend.POMB then
        verb.die("dev: A local board has nothing to wait on.")
    end
    local backend = open_board(ctx)
    local result = M.wait(backend, ctx.args, { stem = cursor_path(found.name) })
    if result.message then
        if result.code == USAGE then
            verb.usage_error(ctx, result.message)
        end
        verb.die("dev: " .. sentence(result.message))
    end
    print(result.output)
    return 0
end

M.handlers["board sync"] = function(ctx)
    verb.no_args(ctx)
    local found = settings(ctx)
    if found.backend ~= board.Backend.POMB then
        verb.die("dev: A local board has nothing to sync.")
    end
    local pending = queue.new(found.name)
    local waiting, message = pending:count()
    if not waiting then
        verb.die("dev: " .. sentence(message) .. " The queue is left in place.")
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
    left, message = replay(backend, pending, print)
    if not left then
        verb.die("dev: " .. sentence(message))
    end
    if left > 0 then
        print("queued: " .. left)
        return 1
    end
    print("synced")
    return 0
end

local function private_project(root)
    local backend = vcs.backend(root)
    if not backend then
        return true
    end
    local origin = vcs.config(root, backend, "remote.origin.url")
    if origin == "" then
        return true
    end
    if not origin:find("github.com", 1, true) then
        return false
    end
    local out, code = dev_os.capture(
        { "gh", "repo", "view", "--json", "isPrivate", "-q", ".isPrivate" },
        { cwd = root, stderr = "null" }
    )
    return code == 0 and out:find("^true") ~= nil
end

local function ensure_board(ctx)
    if config.get(ctx.root, "board.backend") ~= nil then
        return
    end
    if not private_project(ctx.root) then
        verb.die(
            "dev: This project has no board and is public or not known to be private. Ask the owner before it gets one. `dev board init --name N` makes it."
        )
    end
    local name = fs.basename(ctx.root)
    print("This project is private and has no board. Making " .. name .. ".")
    local making = {}
    for key, value in pairs(ctx) do
        making[key] = value
    end
    making.args = { "--name", name }
    local code = M.handlers["board init"](making)
    if code ~= 0 then
        os.exit(code)
    end
end

for sub in pairs(commands) do
    M.handlers["board " .. sub] = function(ctx)
        if
            sub == "run"
            and index_of(ctx.args, RUN_ORDERS_FLAG)
            and not index_of(ctx.args, RUN_END_FLAG)
        then
            ensure_board(ctx)
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
                verb.die("dev: The `strict` setting of `[board.lint]` must be true or false.")
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
                    local ok, why = pending:push(entry.sub, entry.args)
                    if not ok then
                        verb.die(
                            "dev: "
                                .. sentence(result.message)
                                .. " The change could not be queued. "
                                .. sentence(why)
                        )
                    end
                end
                print(QUEUED_NOTICE)
                return 0
            end
            if result.code == USAGE then
                verb.usage_error(ctx, result.message)
            end
            verb.note("dev: " .. result.message)
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
