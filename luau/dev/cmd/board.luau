local board = require("@dev/board")
local board_setup = require("@dev/board/setup")
local check = require("@dev/board/check")
local claims = require("@dev/board/claims")
local role_clock = require("@dev/board/clock")
local config = require("@dev/config")
local dev_config = require("@dev/cmd/config")
local device = require("@dev/board/device")
local dev_os = require("@dev/os")
local follow = require("@dev/cmd/follow")
local fs = require("@dev/fs")
local guards = require("@dev/board/guards")
local init = require("@dev/board/init")
local json = require("@dev/json")
local land = require("@dev/board/land")
local lint = require("@dev/board/lint")
local localboard = require("@dev/board/localboard")
local pomb = require("@dev/board/pomb")
local queue = require("@dev/board/queue")
local render = require("@dev/board/render")
local review = require("@dev/board/review")
local runcard = require("@dev/board/runcard")
local runner = require("@dev/board/runner")
local ship = require("@dev/board/ship")
local stale = require("@dev/board/stale")
local store = require("@dev/board/store")
local tokenfile = require("@dev/board/tokenfile")
local dev_text = require("@dev/text")
local text_width = dev_text.width
local turn = require("@dev/board/turn")
local ui = require("@dev/ui")
local vcs = require("@dev/vcs")
local dev_command = require("@dev/command")
local dev_spec = require("@dev/spec")
local runtime = require("@dev/runtime")
local board_wait = require("@dev/board/wait")
local wiring = require("@dev/board/wiring")

local NO_BOARD = "This project has no board."
local UNKNOWN_COLUMN = "?"
local USAGE = guards.USAGE
local FAILURE = guards.FAILURE
local usage = guards.usage
local failure = guards.failure

---The closed list of what only the owner decides, by the key `ask --list` takes
local ASK_LISTS = { "secrets", "destroy", "spend", "restart", "taste" }

local function clock_note(opening, reason, detail)
    local text = opening .. " " .. detail
    if reason == role_clock.Reason.DROPPED then
        text = text .. " The clock was dropped."
    end
    return text
end

local function queue_unreadable(path, reason, message)
    if reason == queue.Reason.READ then
        return "Cannot read the queue at " .. path .. ". " .. dev_text.sentence(message)
    end
    return dev_text.sentence(message)
end

---The sentence for each reason `pomb.new` refuses with
local POMB_REFUSALS = {
    [pomb.Reason.BAD_URL] = "The `url` setting of `[board.pomb]` must be an http or "
        .. "https address in ~/.config/dev/config.toml. Run `dev config` to set it.",
}

---Write the refusal of a command that only a lead runs.
---@param action string? what the lead does, nil for deleting a card
---@return string message the sentence
local function not_lead_message(action)
    return "Only the lead "
        .. (action or "deletes a card")
        .. ". DEV_AGENT "
        .. (dev_os.getenv("DEV_AGENT") or "")
        .. " is not a lead name, whose role segment is lead, and a name with no slash counts"
        .. " as the lead only at a terminal. Ask the lead"
        .. (action and "" or ", with the card and the reason")
        .. "."
end

local unqueued = guards.unqueued
local agent_name = guards.agent_name
local index_of = require("@dev/text").index_of
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
local OWNER_SEAT_CODE = "owner_seat"
local SEAT_NAME_PATTERN = "^[%w_-]+$"
local WAIT_FLAG = "--wait"
local FROM_FLAG = "--from"
local IGNORE_CHANGE_RUN_FLAG = "--ignore-change-run"
local LEAD_TOKEN_KEY = "lead_token"
local REVIEWER_TOKEN_KEY = "reviewer_token"
local VERIFIER_TOKEN_KEY = "verifier_token"
local CLEARS_BLOCKERS_FLAG = "--clears-blockers"
local BLOCKED_FLAG = "--blocked"
local MAX_WAIT_SECONDS = 86400
local MAX_LAND_ATTEMPTS = 5
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
local MULTI_TEXT_USAGE = "The outcome text is more than one argument. "
    .. "Quote the outcome as one argument and run outcome once per outcome."

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
---@field open fun(settings: dev.cmd.board.Settings): dev.board.Backend?, string? builds the backend
---   a board uses
local M = {}

---The folder of the spec files, one per subcommand.
local SPEC_DIR = "luau/dev/commands/board/"
local specs = {}

---Load the spec of a subcommand from the embedded command files.
---@param sub string the subcommand, `ls` or `token mint`
---@return table<string, any>? spec the validated spec, nil when the subcommand has no spec file
local function spec_of(sub)
    local cached = specs[sub]
    if cached ~= nil then
        return cached or nil
    end
    local path = SPEC_DIR .. sub:gsub(" ", "/") .. ".luau"
    local source = runtime.asset(path)
    if not source then
        specs[sub] = false
        return nil
    end
    local env = setmetatable({ dev_command = dev_command }, { __index = _G })
    local chunk, why = runtime.load(source, "@" .. path, env)
    if not chunk then
        error(why)
    end
    specs[sub] = chunk()
    return specs[sub]
end

---Parse the words of a subcommand through its spec.
---@param sub string the subcommand
---@param argv string[] the words after the subcommand
---@return table<string, any>? opts the flags by name with `-` as `_`, nil on a usage error
---@return table<string, any>|dev.cmd.board.Result args the named arguments, or the usage error
---@return string[]? passthrough the words after `--`
local function reparse(sub, argv)
    local spec = spec_of(sub)
    local opts, args, passthrough = dev_spec.parse(spec, argv)
    if not opts then
        return nil, usage(args)
    end
    if sub == "run" and opts.orders ~= nil then
        if #opts.orders > 1 then
            return nil, usage("The --orders flag takes one value, so give its text once.")
        end
        opts.orders = opts.orders[1]
    end
    return opts, args, passthrough
end

---Tell whether replaying a queued change twice does no more harm than once.
---@param sub string the queued subcommand
---@param argv string[] the queued words
---@return boolean
local function idempotent(sub, argv)
    local rule = QUEUE_RULES[sub]
    if rule ~= nil and rule.idempotent then
        return true
    end
    if sub ~= "outcome" then
        return false
    end
    local opts = reparse(sub, argv)
    return opts ~= nil
        and (opts.tick ~= nil or opts.untick ~= nil)
        and opts.delete == nil
        and opts.rename == nil
end

---Give a flag's repeated values as a list, nil when the flag was not given.
---@param values string[]? the values the spec gathered
---@return string[]? list the values, nil when there are none
local function listed(values)
    if values == nil or #values == 0 then
        return nil
    end
    return values
end

---Find the board a command names with `--board` or a `BOARD:CARD` word.
---@param backend dev.board.Backend the board the command ran against
---@param card string? the card word
---@param board_name string? the value of `--board`
---@return dev.board.Backend? home the board the card is on, nil when refused
---@return string? word the card word without its board prefix
---@return dev.cmd.board.Result? refused the usage error or failure, set when home is nil
local function home_of(backend, card, board_name)
    if card == nil then
        return nil, nil, usage("Needs a card.")
    end
    local words = { card }
    if board_name ~= nil then
        words = { card, "--board", board_name }
    end
    local home, rest, refused = guards.on_board(backend, words)
    if not home then
        return nil, nil, refused
    end
    return home, rest[1], nil
end

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
            or "The board has no "
                .. board.field_key(key)
                .. " field. Run `dev board init` to add it."
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
    if board.is_card_prefix(word) then
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

function commands.ls(backend, opts, _, _, screen)
    local lane
    if opts.lane then
        local named, err = named_lane(backend, opts.lane)
        if not named then
            return err
        end
        lane = named
    end
    local color
    if opts.size then
        local named, err = sized(opts.size)
        if not named then
            return err
        end
        color = named
    end
    local want
    if opts.column then
        local column, err = named_column(backend, opts.column)
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
        if shown and opts.label then
            shown = false
            for _, label in ipairs(card.labels) do
                shown = shown or label == opts.label
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
            grouped = opts.group,
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

function commands.next(backend, opts)
    local lane
    if opts.lane then
        local named, err = named_lane(backend, opts.lane)
        if not named then
            return err
        end
        lane = named
    end
    local limit, bad = runner.limit(opts.max_size)
    if bad then
        return bad
    end
    local stages = backend.stages
    local column = stages.ready
    if opts.column then
        local named, err = named_column(backend, opts.column)
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
    local asked = opts["for"] and opts["for"]:lower()
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

---Prose warnings for text just written, each ending with a note that the write happened.
---@param findings string[] the bare warning lines from the board library
---@return string[] warnings one line per finding
local function written_warnings(findings)
    local lines = {}
    for _, line in ipairs(findings) do
        lines[#lines + 1] = line .. " The write still went through."
    end
    return lines
end

---Add a card, and record in `held` whether the parsed flags hold the --id-only switch.
---@param backend dev.board.Backend the board to add the card to
---@param args string[] the arguments after `add`
---@param opts table<string, any> the parsed flags of `add`
---@param args table<string, any> the parsed arguments of `add`
---@return dev.cmd.board.Result result the outcome of the add
local function add_card(backend, opts, args, held)
    local words = args.name or {}
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
    held.id_only = opts.id_only
    if opts.board then
        local home, why = guards.other_home(backend, opts.board)
        if not home then
            return failure(why)
        end
        backend = home
    end
    for _, one in ipairs({
        { "--problem", opts.problem },
        { "--out-of-scope", opts.out_of_scope },
        { "--source", opts.source },
    }) do
        if one[2] and #one[2] > 1 then
            return usage("The " .. one[1] .. " flag takes one value, so give its text once.")
        end
    end
    local problem = opts.problem and opts.problem[1]
    local out_of_scope = opts.out_of_scope and opts.out_of_scope[1]
    local source = opts.source and opts.source[1]
    local change
    local changes = listed(opts.change)
    if changes then
        local lines = {}
        for i, line in ipairs(changes) do
            local text = line:match("^%s*(.-)%s*$")
            lines[i] = text:find("^%- ") and text or "- " .. text
        end
        change = table.concat(lines, "\n")
    end
    local sectioned = problem or change or out_of_scope or source
    if sectioned and opts.description then
        return usage(
            "The --description flag holds the whole text, "
                .. "so it cannot go with --problem, --change, --out-of-scope or --source."
        )
    end
    local labels
    for _, label in ipairs(listed(opts.label) or {}) do
        local ok, err = plain(label)
        if not ok then
            return err
        end
        local denied = require("@dev/standalone").label_problem(label)
        if denied then
            return failure(denied)
        end
        labels = labels or {}
        if not index_of(labels, label) then
            labels[#labels + 1] = label
        end
    end
    local checks = {}
    for _, run in ipairs(listed(opts.checks) or {}) do
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
    for _, item in ipairs(listed(opts.done_when) or {}) do
        if not item:find("%S") then
            return usage("The --done-when flag needs the outcome.")
        end
        outcomes[#outcomes + 1] = item
    end
    if #outcomes > board.MAX_OUTCOMES then
        return usage("A card has at most " .. board.MAX_OUTCOMES .. " --done-when outcomes.")
    end
    local color
    if opts.size then
        local named, err = sized(opts.size)
        if not named then
            return err
        end
        color = named
    end
    local stages = backend.stages
    local column = stages.backlog
    if opts.column then
        local named, err = named_column(backend, opts.column)
        if not named then
            return err
        end
        column = named
    end
    local lane
    if opts.lane then
        local named, err = named_lane(backend, opts.lane)
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
    local description = opts.description
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
            epic = opts.epic,
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
        local missing = board.missing(description, #outcomes, 0, opts.epic)
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
    if column == stages.ready and not opts.epic then
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
    for _, word in ipairs(listed(opts.blocked_by) or {}) do
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
    if opts.from then
        local found, _, err = other_card(backend, opts.from)
        if not found then
            return err
        end
        origin = found
    end
    local position
    local anchor_word = opts.before or opts.after
    if opts.top or anchor_word then
        if (opts.top and 1 or 0) + (opts.before and 1 or 0) + (opts.after and 1 or 0) > 1 then
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
            if opts.before then
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
        epic = opts.epic or nil,
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
    local prose = opts.description or (sectioned and description)
    if #outcomes > 0 then
        prose = (prose or "") .. "\n## Done when\n" .. table.concat(outcomes, "\n")
    end
    return {
        output = opts.id_only and card.id
            or "added "
                .. card.id:sub(1, board.MIN_PREFIX)
                .. " "
                .. card.column
                .. link_suffix(backend, card),
        warnings = written_warnings(board.prose_warnings(prose)),
    }
end

function commands.add(backend, opts, args)
    local held = {}
    local result = add_card(backend, opts, args, held)
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

local function edit_note(backend, opts, args)
    local words = args.text or {}
    if #words < 1 or not args.card then
        return usage("The " .. EDIT_FLAG .. " flag needs a comment and the new text.")
    end
    local card, err = find_card(backend, args.card)
    if not card then
        return err
    end
    local comment
    comment, err = find_comment(backend, card, opts.edit)
    if not comment then
        return err
    end
    local text = table.concat(words, " ")
    if board.reserved(comment.body) or board.reserved(text) then
        return failure(RESERVED_NOTE)
    end
    local ok, message = backend:edit_note(card.id, comment.id, text)
    if not ok then
        return failure(message)
    end
    return changed("edited", card, comment)
end

local function delete_note(backend, opts, args)
    if not args.card then
        return usage("The " .. DELETE_FLAG .. " flag needs a comment.")
    end
    if args.text and #args.text > 0 then
        return usage("Unknown argument " .. args.text[1] .. ".")
    end
    local card, err = find_card(backend, args.card)
    if not card then
        return err
    end
    local comment
    comment, err = find_comment(backend, card, opts.delete)
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

---Add each row's command to a `dev-check:` record that ran the card's current checks rows.
---@param lines string[] the comment body's lines
---@param body string the comment body
---@param checks string[] the card's checks rows
---@return string[] lines the lines, with a command after each row line when the record matches
local function named_rows(lines, body, checks)
    local record = check.parse(body)
    if not record or #record.rows ~= #checks or record.sum ~= check.fingerprint(checks) then
        return lines
    end
    local named = {}
    for i, line in ipairs(lines) do
        local index = line:match("^(%d+) ")
        local row = index and record.rows[tonumber(index)]
        if row and row.ran then
            local bare = line:gsub(" ran=%S+$", "")
            named[i] = bare
                .. " "
                .. checks[tonumber(index)]
                .. " -- "
                .. table.concat(row.ran, " ")
        else
            named[i] = index and line .. " " .. checks[tonumber(index)] or line
        end
    end
    return named
end

---Format the comments as aligned table rows, one per comment.
---@param list dev.board.Comment[]
---@param opts? { whole?: boolean, checks?: string[] } `whole` prints every line of each body, not
---   only the first, and `checks` names each row of a matching `dev-check:` record
---@return string
local function comment_lines(list, opts)
    if #list == 0 then
        return "no comments"
    end
    local rows, rests = {}, {}
    for i, comment in ipairs(list) do
        local lines = body_lines(comment.body)
        if opts and opts.checks then
            lines = named_rows(lines, comment.body, opts.checks)
        end
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

function commands.notes(backend, _, args)
    if not args.card then
        return usage("Needs a card.")
    end
    local home, word, refused = home_of(backend, args.card)
    if not home then
        return refused
    end
    local card, err = find_card(home, word)
    if not card then
        return err
    end
    local list, message = home:comments(card.id)
    if not list then
        return failure(message)
    end
    return { output = comment_lines(list, { checks = card.checks }) }
end

function commands.history(backend, _, args)
    if not args.card then
        return usage("Needs a card.")
    end
    local card, err = find_card(backend, args.card)
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

function commands.flow(backend)
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
        .. comment_lines(list, { whole = true, checks = card.checks })
end

function commands.show(backend, opts, args)
    if not args.card then
        return usage("Needs a card.")
    end
    local home, word, refused = home_of(backend, args.card, opts.board)
    if not home then
        return refused
    end
    local card, err = find_card(home, word)
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
        dev_command.note(
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

local function note_opts(opts)
    local note = {}
    if opts.kind then
        note.kind = opts.kind:lower()
        if note.kind == board.NoteKind.QUESTION then
            return nil,
                usage(
                    "Question is not a note kind. Ask the owner with "
                        .. "dev board ask CARD --question TEXT --choice COLUMN=LABEL "
                        .. "--recommend N --why TEXT."
                )
        end
        if not index_of(board.NOTE_KINDS, note.kind) then
            return nil,
                usage(
                    "Unknown kind "
                        .. opts.kind
                        .. ". The kinds are "
                        .. table.concat(board.NOTE_KINDS, ", ")
                        .. "."
                )
        end
    end
    if opts.as then
        note.author = opts.as:match("^%s*(.-)%s*$")
        if note.author == "" or note.author:find("%c") then
            return nil,
                usage("The " .. AS_FLAG .. " flag needs a label with no control characters.")
        end
        if #note.author > board.AUTHOR_CHARS then
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
    return note
end

function commands.note(backend, opts, args)
    if opts.board and (opts.edit or opts.delete) then
        return usage("The --board flag takes no " .. EDIT_FLAG .. " or " .. DELETE_FLAG .. ".")
    end
    if opts.edit and opts.delete then
        return usage("The " .. EDIT_FLAG .. " flag cannot go with " .. DELETE_FLAG .. ".")
    end
    if (opts.edit or opts.delete) and (opts.kind or opts.as) then
        return usage(
            "The "
                .. (opts.edit and EDIT_FLAG or DELETE_FLAG)
                .. " flag takes no "
                .. KIND_FLAG
                .. " or "
                .. AS_FLAG
                .. "."
        )
    end
    local home, word, refused = home_of(backend, args.card, opts.board)
    if not home then
        return refused
    end
    if opts.edit then
        return edit_note(home, opts, { card = word, text = args.text })
    elseif opts.delete then
        return delete_note(home, opts, { card = word, text = args.text })
    end
    local words = args.text or {}
    if not word or #words < 1 then
        return usage("Needs a card and the note.")
    end
    local note, bad = note_opts(opts)
    if not note then
        return bad
    end
    local card, err = find_card(home, word)
    if not card then
        return err
    end
    local text = table.concat(words, " ")
    if board.reserved(text) then
        return failure(RESERVED_NOTE)
    end
    if board.mostly_ids(text) then
        return usage(
            "That note is mostly ids, hashes and paths. Write two or three sentences for a person."
        )
    end
    local held = claims.read(card.id)
    local ok, message = home:note(card.id, text, held and held.fence, note)
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
        local short: string = card.id:sub(1, board.MIN_PREFIX)
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

---Name the last claimant of a card that leaves Blocked for In Progress under another name.
---
---Nothing applies when the card does not sit in Blocked or its newest claim record names the
---caller or no one.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card, which holds no live claim
---@param name string the caller's agent name
---@return string? last the other name, nil when the move claims the card as usual
---@return dev.cmd.board.Result? refused the failure, nil when the comments were read
local function blocked_holder(backend, card, name)
    if card.column ~= backend.stages.blocked then
        return nil
    end
    local past, why = backend:comments(card.id)
    if not past then
        return nil, failure(why)
    end
    local last = board.last_claimant(past)
    if last and last ~= runner.claimant(name) then
        return last
    end
    return nil
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
---@return dev.cmd.board.Result? refused the failure, nil when the card has started or is free
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

---Read a list of checks rows from the `[board.lint]` table.
---@param backend dev.board.Backend the board
---@param key string the setting, `required` or `bare_rows`
---@return string[]? rows the listed rows, nil when the project lists none
---@return dev.cmd.board.Result? err the failure when the setting is not a list of commands
local function lint_rows(backend, key)
    if not backend.root then
        return nil
    end
    local rows = config.get(backend.root, "board.lint." .. key)
    if rows == nil then
        return nil
    end
    local bad = failure("The `" .. key .. "` setting of `[board.lint]` must be a list of commands.")
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
---@return dev.cmd.board.Result? refused the failure, nil when the card holds every required row or is no-change
local function required_refusal(backend, card)
    if board.labelled(card, board.NO_CHANGE) then
        return nil
    end
    local required, err = lint_rows(backend, "required")
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

---Refuse a card whose checks lack a bare row the project lists in `bare_rows`.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@param action string what the refusal says the card cannot do, such as `enter Ready`
---@return dev.cmd.board.Result? refused the failure, nil when the card holds every bare row
local function bare_refusal(backend, card, action)
    local bare, err = lint_rows(backend, "bare_rows")
    if err then
        return err
    end
    local missing = board.missing_bare_rows(card.checks, bare or {})
    if #missing == 0 then
        return nil
    end
    return failure(
        "Card "
            .. card.id:sub(1, board.MIN_PREFIX)
            .. " lacks the bare row "
            .. table.concat(missing, ", ")
            .. " and cannot "
            .. action
            .. ". A named row such as `"
            .. missing[1]
            .. " -- FILE` does not count. Add it with `dev board checks CARD CMD...`."
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
        local unbare = bare_refusal(backend, card, "enter Ready")
        if unbare then
            return unbare
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

---Remove the workspace of a no-change card that has moved to Done.
---
---Only the card's own workspace goes: the working copy must sit in a folder named for the card, and
---`land.workspace_problem` must find it to be the card's.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card that moved
---@param opts dev.cmd.board.move.Opts? the checks and the removal, injected by tests
---@return string lines the cleanup's lines behind a newline, empty when nothing was removed or kept
local function no_change_clean_up(backend, card, opts)
    if not (backend.root and board.labelled(card, board.NO_CHANGE)) then
        return ""
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    local folder = fs.realpath(backend.root) or backend.root
    if fs.basename(folder) ~= short then
        return ""
    end
    if (opts and opts.workspace_problem or land.workspace_problem)(backend.root, short) then
        return ""
    end
    return (opts and opts.clean_up or M.clean_up)(backend.root, short)
end

---Move a card to a column, checking its outcomes first when the column is Done.
---@param backend dev.board.Backend the board
---@param flags table<string, any> the parsed flags of the move
---@param words table<string, any> the parsed arguments, `card` and the `column` word list
---@param opts {drop: boolean?}? `drop` skips the outcome check, and the planning check from Icebox
---@return dev.cmd.board.Result result the output, or a message and the exit code
local function move_once(backend, flags, words, opts)
    if not words.card or not listed(words.column) then
        return usage("Needs a card and a column.")
    end
    local lane
    if flags.lane then
        local named, bad = named_lane(backend, flags.lane)
        if not named then
            return bad
        end
        lane = named
    end
    if flags.max_size then
        local _, bad = runner.limit(flags.max_size)
        if bad then
            return bad
        end
    end
    local stages = backend.stages
    local column, err = named_column(backend, table.concat(words.column, " "))
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
    card, err = find_card(backend, words.card)
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
    if column == stages.ready or starting then
        local refused = (starting and size_refusal(card))
            or ready_refusal(backend, card, { children = children, epic = epic })
        if refused then
            return refused
        end
    end
    if column == stages.progress then
        local limit, bad = runner.limit(flags.max_size)
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
        local last, refused = blocked_holder(backend, card, name)
        if refused then
            return refused
        end
        if last then
            local short = card.id:sub(1, board.MIN_PREFIX)
            dev_command.note(
                string.format(
                    "Moved without a claim: the last claimant of %s is %s. "
                        .. "Take it with `dev board take %s`.",
                    short,
                    last,
                    short
                )
            )
        else
            local result, fence = claim_card(backend, card, name)
            if not fence then
                return result
            end
            started = true
            held = { fence = fence }
        end
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
            dev_command.note(clock_note("Moved, but its clock did not follow.", reason, detail))
        end
    end
    if own_claim and column ~= stages.progress and column ~= stages.blocked then
        claims.stop(card.id)
        local release_fence = held and held.fence
        local released, why, why_reason, why_detail = backend:release(card.id, release_fence)
        if not released then
            dev_command.note(
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
    if to_done and card.column ~= column and not (opts and opts.landed) then
        result.output = result.output .. no_change_clean_up(backend, card, opts)
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
---@field workspace_problem (fun(root: string, short: string): string?)? says why the working copy
---   is not the card's own workspace, `land.workspace_problem` when nil
---@field clean_up (fun(root: string, short: string): string)? removes the card's workspace after a
---   no-change move into Done, `M.clean_up` when nil
---@field nap (fun(seconds: number))? sleeps between tries, `dev.os.nap` when nil
---@field random dev.board.turn.Random? jitters the sleeps, `turn.entropy` when nil
---@field now (fun(): integer)? the clock in seconds since the epoch, `store.now` when nil

---Read the `--wait` flag, 0 when it is absent.
---@param opts table<string, string>? the parsed flags, which hold `wait` as typed
---@return integer? seconds the wait, nil when the value is not a whole number up to the bound
---@return dev.cmd.board.Result? refusal the usage result when the value is refused
local function wait_seconds(opts)
    if not (opts and opts.wait) then
        return 0
    end
    local seconds = opts.wait:match("^%d+$") and tonumber(opts.wait)
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

---Run `try` again after a growing pause while it answers a full column, until `wait` seconds pass.
---@param wait integer the seconds to keep trying, 0 for one try
---@param opts dev.cmd.board.move.Opts? how to sleep and tell time
---@param try fun(): dev.cmd.board.Result one whole try
---@return dev.cmd.board.Result result the result of the last try
local function until_room(wait, opts, try)
    local nap = opts and opts.nap or dev_os.nap
    local clock = opts and opts.now or store.now
    local poll = turn.poller({ random = opts and opts.random })
    local deadline = clock() + wait
    while true do
        local result = try()
        local left = deadline - clock()
        if result.code ~= runner.FULL or left <= 0 then
            return result
        end
        nap(math.min(poll:pace(runner.FULL), left))
    end
end

---Move a card to a column of another board, which only Pomb can do.
---@param backend dev.board.Backend the board the card sits on
---@param flags table<string, any> the parsed flags
---@param words table<string, any> the parsed arguments, `card` and the `column` word list
---@return dev.cmd.board.Result result the output, or a message and the exit code
local function move_across(backend, flags, words)
    if not words.card or not listed(words.column) then
        return usage("Needs a card and a column.")
    end
    if flags.lane or flags.wait or flags.max_size then
        return usage("The --to-board flag cannot go with --lane, --wait or " .. runner.FLAG .. ".")
    end
    local card, err = find_card(backend, words.card)
    if not card then
        return err
    end
    local held_back = owner_holds(card)
    if held_back then
        return held_back
    end
    local held = claims.read(card.id)
    local name, column = flags.to_board, table.concat(words.column, " ")
    local ok, message, reason, detail = backend:move_to_board(
        card.id,
        name,
        column,
        { fence = held and held.fence, closed = card.done }
    )
    if not ok then
        return failure(reason and board.cross_move_refusal(reason, detail, name, column) or message)
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    return { output = "moved " .. short .. " to " .. column .. " on board " .. name }
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
    local flags, words = reparse("move", args)
    if not flags then
        return words
    end
    if flags.to_board then
        return move_across(backend, flags, words)
    end
    local wait, bad_wait = wait_seconds(flags)
    if not wait then
        return bad_wait
    end
    return until_room(wait, opts, function()
        return move_once(backend, flags, words, opts)
    end)
end

function commands.move(backend, _, _, _, _, raw)
    local home, rest, refused = guards.on_board(backend, raw.argv)
    if not home then
        return refused
    end
    return move_card(home, rest)
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
    local home, rest = guards.on_board(backend, args)
    if not home then
        return false
    end
    local flags, words = reparse("move", rest)
    if not flags or not words.card or not listed(words.column) then
        return false
    end
    home.stages = home.stages or board.stages(home.column_map, home:done_columns() or {})
    local column = named_column(home, table.concat(words.column, " "))
    if not column or column ~= home.stages:done_column() then
        return false
    end
    local card = find_card(home, words.card)
    return card ~= nil and (card.epic ~= nil or card.kind == board.Kind.EPIC)
end

function commands.order(backend, _, args)
    local words = args.cards or {}
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
function commands.discard(backend, opts, args)
    local home, word, refused = home_of(backend, args.card, opts.board)
    if not home then
        return refused
    end
    local elsewhere = home ~= backend
    backend = home
    if not word then
        return usage("Needs a card, and an optional --reason TEXT.")
    end
    local reason = opts.reason
    if reason and reason:find("^%s*$") then
        return usage("The --reason flag needs text.")
    end
    local card, err = find_card(backend, word)
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
            { sub = "note", args = { word, KIND_FLAG, board.NoteKind.DECISION, reason } }
    end
    steps[#steps + 1] = { sub = "label", args = { word, DISCARD_LABEL } }
    steps[#steps + 1] = { sub = "discard_move", args = { word, backend.stages:done_column() } }
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

function commands.size(backend, _, args)
    if not args.card or not args.size then
        return usage("Needs a card and a size.")
    end
    local color, err = sized(args.size)
    if not color then
        return err
    end
    local card
    card, err = find_card(backend, args.card)
    if not card then
        return err
    end
    if
        color == board.SIZES.unsized
        and (dev_os.getenv("DEV_AGENT") or "") ~= ""
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
    return { output = "sized " .. card.id:sub(1, board.MIN_PREFIX) .. " " .. args.size:lower() }
end

function commands.time(backend, opts, args)
    local clock = require("@dev/board/clock")
    local positional = {}
    for _, word in ipairs({ args.first, args.second }) do
        positional[#positional + 1] = word
    end
    if clock.WORDS[positional[1]] then
        return clock.run(backend, positional, opts.as, opts.note, function(word)
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
    local role = clock.role(opts.as)
    if not role then
        return usage("The " .. AS_FLAG .. " flag needs the role the time was logged in.")
    end
    local card, err = find_card(backend, positional[1])
    if not card then
        return err
    end
    local ok, message = backend:log_time(card.id, minutes, role, opts.note)
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

---Read the label changes in the order the words gave them.
---@param opts table<string, any> the parsed flags
---@param args table<string, any> the parsed arguments
---@param words string[]? the raw words after `label`, nil to take adds before removals
---@return {add: boolean, word: string}[] edits the changes in order
local function label_edits(opts, args, words)
    local edits = {}
    if words == nil then
        for _, arg in ipairs(args.rest or {}) do
            edits[#edits + 1] = { add = true, word = (arg:gsub("^%+", "")) }
        end
        for _, word in ipairs(listed(opts.remove) or {}) do
            edits[#edits + 1] = { add = false, word = word }
        end
        return edits
    end
    local skipped_card = false
    local index = 1
    while index <= #words do
        local word = words[index]
        index = index + 1
        local inline = word:match("^%-%-remove=(.*)$")
        if word == "--" then
            for more = index, #words do
                edits[#edits + 1] = { add = true, word = (words[more]:gsub("^%+", "")) }
            end
            break
        elseif word == "--remove" then
            edits[#edits + 1] = { add = false, word = words[index] }
            index = index + 1
        elseif inline then
            edits[#edits + 1] = { add = false, word = inline }
        elseif not skipped_card then
            skipped_card = true
        else
            edits[#edits + 1] = { add = true, word = (word:gsub("^%+", "")) }
        end
    end
    return edits
end

function commands.label(backend, opts, args, _now, _screen, raw)
    local edits = label_edits(opts, args, raw and raw.argv)
    for _, change in ipairs(edits) do
        local ok, err = plain(change.word)
        if not ok then
            return err
        end
    end
    if not args.card or #edits == 0 then
        return usage("Needs a card and one or more labels to add or --remove label.")
    end
    local card, err = find_card(backend, args.card)
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
        local denied = require("@dev/standalone").label_problem(change.word)
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

function commands.ask(backend, opts, args)
    if not args.card then
        return usage(
            "Needs a card, --question TEXT, --choice COLUMN=LABEL, --recommend N, --why TEXT"
                .. " and --list KEY or --searched TEXT."
        )
    end
    local question = { choices = {} }
    for _, value in ipairs(listed(opts.choice) or {}) do
        local column, label = value:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
        if not column or column == "" or label == "" then
            return usage("The --choice flag takes COLUMN=LABEL, not " .. value .. ".")
        end
        question.choices[#question.choices + 1] = { column = column, label = label }
    end
    if opts.recommend then
        if not opts.recommend:match("^%d+$") then
            return usage(
                "The --recommend flag takes a choice number, not " .. opts.recommend .. "."
            )
        end
        question.recommended = tonumber(opts.recommend)
    end
    question.text = opts.question
    question.why = opts.why
    local listed_key, searched
    if opts.list then
        if index_of(ASK_LISTS, opts.list) == nil then
            return usage(
                "The --list flag takes one of "
                    .. table.concat(ASK_LISTS, ", ")
                    .. ", not "
                    .. opts.list
                    .. "."
            )
        end
        listed_key = opts.list
    end
    if opts.searched then
        searched = opts.searched:match("%S") and opts.searched or nil
    end
    if not listed_key and not searched then
        return usage(
            "A question names the owner's list item with --list KEY"
                .. " or the precedent search it ran with --searched TEXT."
        )
    end
    local card, err = find_card(backend, args.card)
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
            dev_command.note(
                "Asked, but the claim was not released. "
                    .. board.release_refusal(why_reason, why, why_detail, held.fence)
            )
        end
    end
    return { output = "asked " .. card.id:sub(1, board.MIN_PREFIX) }
end

function commands.answer(backend, opts, args)
    local choice = opts.choice
    if not args.card or not choice or not opts.quote then
        return usage("Needs a card, --choice N and --quote TEXT.")
    end
    if not choice:match("^%d+$") or tonumber(choice) < 1 then
        return usage("The --choice flag counts from 1, not " .. choice .. ".")
    end
    local quote = table.concat({ opts.quote, table.unpack(args.rest or {}) }, " ")
    if not quote:find("%S") then
        return usage("The --quote flag needs the owner's words.")
    end
    local card, err = find_card(backend, args.card)
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

function commands.escalate(backend, opts, args)
    for _, one in ipairs({
        { "--question", opts.question },
        { "--choice", opts.choice },
        { "--recommend", opts.recommend },
        { "--why", opts.why },
    }) do
        if one[2] ~= nil then
            return usage(
                "Escalate takes a card and the note text, not "
                    .. one[1]
                    .. ", so put a question for the owner through dev board ask."
            )
        end
    end
    local why = table.concat(args.text or {}, " ")
    if not args.card or not why:find("%S") then
        return usage("Needs a card and the reason.")
    end
    local card, err = find_card(backend, args.card)
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

---Past-tense word reported for each outcome mode
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

local CONVERT_MODE = "convert"

---Name the form an outcome command takes from its flags.
---@param opts table<string, any> the parsed flags of `outcome`
---@return string? mode an `OutcomeMode`, or `convert`, nil when more than one form was given
function M.outcome_mode(opts)
    local found
    for _, mode in ipairs({
        OutcomeMode.RENAME,
        OutcomeMode.TICK,
        OutcomeMode.UNTICK,
        OutcomeMode.DELETE,
    }) do
        if opts[mode] ~= nil then
            if found then
                return nil
            end
            found = mode
        end
    end
    if opts.convert then
        return not found and CONVERT_MODE or nil
    end
    return found or OutcomeMode.ADD
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
    local locked = require("@dev/board/outcome_lock").refusal(rows, card.column, what)
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

function commands.outcome(backend, opts, args, _now, _screen, raw)
    local ticker_flag = opts.as
    local mode = M.outcome_mode(opts)
    if not mode then
        return usage(
            "Give one outcome form: the text, --rename N TEXT --reason TEXT, "
                .. "--tick N, --untick N, --delete N --reason TEXT or --convert."
        )
    end
    local foreign = guards.foreign_refusal(args.card, "outcome")
    if foreign then
        return foreign
    end
    local rest = listed(args.rest) or {}
    if not args.card or (mode == OutcomeMode.ADD and not args.text) then
        return usage(
            "Needs a card and the outcome text, or --rename N TEXT --reason TEXT, "
                .. "--tick N, --untick N, --delete N --reason TEXT or --convert."
        )
    end
    local text, word, reason
    if mode == CONVERT_MODE then
        if args.text then
            return usage("The " .. CONVERT_FLAG .. " flag takes only the card.")
        end
        local card, err = find_card(backend, args.card)
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
    elseif mode == OutcomeMode.ADD then
        local misplaced = misplaced_outcome_form({ args.card, args.text, table.unpack(rest) })
        if misplaced then
            return usage(misplaced)
        end
        if #rest > 0 then
            return usage(MULTI_TEXT_USAGE)
        end
        text = args.text
    elseif mode == OutcomeMode.RENAME then
        if not args.text then
            return usage("The --rename flag needs an outcome number and the new text.")
        end
        if opts.reason == nil then
            return usage("The --rename flag needs " .. REASON_FLAG .. " TEXT.")
        end
        if #rest > 0 then
            local at = index_of(raw and raw.argv or {}, REASON_FLAG)
            if at and (raw.argv[at + 2] == rest[1]) then
                return usage(
                    "The "
                        .. REASON_FLAG
                        .. " flag takes one argument. Quote a reason of more than one word."
                )
            end
            return usage(MULTI_TEXT_USAGE)
        end
        word, text = opts.rename, args.text
        reason = opts.reason
        if not reason:find("%S") then
            return usage("The " .. REASON_FLAG .. " flag needs the reason.")
        end
    elseif mode == OutcomeMode.DELETE then
        if opts.reason == nil then
            return usage(
                "The "
                    .. DELETE_FLAG
                    .. " flag needs an outcome number and "
                    .. REASON_FLAG
                    .. " TEXT."
            )
        end
        word = opts.delete
        local words = { opts.reason }
        if args.text then
            words[#words + 1] = args.text
        end
        for _, more in ipairs(rest) do
            words[#words + 1] = more
        end
        text = table.concat(words, " ")
        if not text:find("%S") then
            return usage("The " .. REASON_FLAG .. " flag needs the reason.")
        end
        local agent = dev_os.getenv("DEV_AGENT") or ""
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
        if args.text then
            return usage("The --" .. mode .. " flag needs one outcome number.")
        end
        word = opts[mode]
    end
    if text and not text:find("%S") then
        return usage("The outcome text is empty.")
    end
    local card, err = find_card(backend, args.card)
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
            warnings = written_warnings(board.text_warnings(text)),
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
    local cleared = mode == OutcomeMode.RENAME and card.outcomes[number].done == true
    if cleared then
        fields.done = false
    end
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
        if cleared then
            body = body .. " The tick was cleared."
        end
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
    if cleared then
        result.output = result.output .. ", tick cleared"
    end
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
        result.warnings = written_warnings(board.text_warnings(text))
    end
    return result
end

function commands.edit(backend, opts, args)
    local home, word, refused = home_of(backend, args.card, opts.board)
    if not home then
        return refused
    end
    backend = home
    local text = args.text
    if not word or not text then
        return usage("Needs a card and the new description.")
    end
    local card, err = find_card(backend, word)
    if not card then
        return err
    end
    local held_back = owner_holds(card)
    if held_back then
        return held_back
    end
    local rendered = board.rendered_blocks(text)
    if rendered then
        return failure(
            "The text holds the rendered line `"
                .. rendered
                .. "`. The outcomes and checks have their own commands, `dev board outcome`"
                .. " and `dev board checks`."
        )
    end
    if card.column ~= backend.stages.icebox then
        local missing = board.backlog_missing(text)
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
    local ok, message = backend:set_description(card.id, text, held and held.fence)
    if not ok then
        return failure(message)
    end
    return {
        output = "edited " .. card.id:sub(1, board.MIN_PREFIX),
        warnings = written_warnings(board.prose_warnings(text)),
    }
end

function commands.rename(backend, _, args)
    if not args.card or not args.title or #args.title < 1 then
        return usage("Needs a card and the new title.")
    end
    local name = table.concat(args.title, " ")
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
    local card, err = find_card(backend, args.card)
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

function commands.checks(backend, _, args)
    local runs = args.rows or {}
    if not args.card or #runs < 1 then
        return usage("Needs a card and one or more commands to run as its checks.")
    end
    for _, run in ipairs(runs) do
        if not run:find("%S") then
            return usage("A check needs a command.")
        end
    end
    local refused_row = guards.row_refusal(runs, backend.root)
    if refused_row then
        return refused_row
    end
    local found, err = find_card(backend, args.card)
    if not found then
        return err
    end
    local refused = guards.claimant_refused(backend, found, { what = "change its checks" })
    if refused then
        return refused
    end
    local card, short = write_field(backend, args.card, board.CHECKS_FIELD, function(id, fence)
        return backend:set_checks(id, runs, fence)
    end)
    if not card then
        return short
    end
    return { output = "set checks " .. short .. ", " .. dev_text.count(#runs, "row") }
end

function commands.check(backend, given, args)
    local opts, err = wiring.check_options(backend.root, given, args.card)
    if not opts then
        return err
    end
    local card
    card, err = find_card(backend, opts.card)
    if not card then
        return err
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    if not opts.expect_fail then
        local elsewhere = guards.workspace_refusal(backend, short)
        if elsewhere then
            return elsewhere
        end
    end
    if #card.checks == 0 then
        return failure("Card " .. short .. " has no checks rows. Set them with `dev board checks`.")
    end
    if card.epic == nil and card.kind ~= board.Kind.EPIC then
        local unbare = bare_refusal(backend, card, "be checked")
        if unbare then
            return unbare
        end
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
    local stack = land.stack_note(backend.root)
    if stack then
        dev_command.note(stack)
    end
    local exempt = opts.expect_fail or board.labelled(card, board.NO_CHANGE)
    local empty = not exempt and check.empty_refusal(backend.root)
    if empty then
        return failure(empty)
    end
    local name = agent_name()
    if name then
        local hold, held_why = turn.held(backend, name, short)
        if not hold and held_why then
            dev_command.note(held_why)
        end
        if hold then
            local released, reason = turn.release(backend, hold)
            if not released then
                return failure(reason)
            end
            dev_command.note(
                "A check never holds the landing turn. It was given back, and dev board land takes it again."
            )
        end
    end
    return wiring.check_rows({
        name = name,
        backend = backend,
        card = card,
        before = before,
        argvs = argvs,
        options = opts,
    })
end

function commands.review(backend, opts, args)
    if not args.card then
        return usage("Needs a card.")
    end
    for _, one in ipairs({
        { KIND_FLAG, opts.kind },
        { BY_FLAG, opts.by },
        { REV_FLAG, opts.rev },
        { review.VERDICT_FLAG, opts.verdict },
    }) do
        if not one[2] then
            return usage("Needs " .. one[1] .. ".")
        end
    end
    local kind = opts.kind
    if not index_of(review.KINDS, kind) then
        return usage(
            "Unknown kind " .. kind .. ". The kinds are " .. table.concat(review.KINDS, ", ") .. "."
        )
    end
    local of = opts.of
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
    local verdict = opts.verdict
    if not index_of(review.VERDICTS, verdict) then
        return usage(
            "Unknown verdict "
                .. verdict
                .. ". The verdicts are "
                .. table.concat(review.VERDICTS, ", ")
                .. "."
        )
    end
    local by, why = agent_name(opts.by)
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
    local card, err = find_card(backend, args.card)
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
    local rev, message = review.resolve(backend.root, opts.rev)
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
        local held = (message or ""):find(SEAT_HELD_CODE, 1, true)
        if not ok and kind == review.Kind.RECHECK and held then
            seat_note = string.format(
                "\nThe recheck seat is already held, so only the card records this review. A lead frees it with `dev board seat reset %s %s`.",
                short,
                kind
            )
        elseif not ok then
            local detail =
                board.seat_refusal(held and board.SeatReason.HELD or refusal, message, kind, short)
            if (message or ""):find(OWNER_SEAT_CODE, 1, true) and not tokenfile.read(by) then
                detail = string.format(
                    "%s No minted reviewer token file was found for %s. The lead mints one with `dev board token mint --role reviewer --as %s`, or sets `%s` in `[board.pomb]`.",
                    detail,
                    by,
                    by,
                    guards.is_verifier(by) and VERIFIER_TOKEN_KEY or REVIEWER_TOKEN_KEY
                )
            end
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
    local ws = require("@dev/cmd/ws")
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

function commands.land(backend, opts, args)
    if not args.card then
        return usage("Needs a card.")
    end
    local words = { args.card, table.unpack(listed(args.rest) or {}) }
    local wait, bad_wait = wait_seconds(opts)
    if not wait then
        return bad_wait
    end
    local ignore = opts.ignore_change_run
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
    local own = config.get(backend.root, "board.land.command")
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
            if not result.code and not (result.output or ""):find("^landed") then
                result = failure(
                    "Card "
                        .. short
                        .. " cannot land. The landing stopped after the recheck without pushing,"
                        .. " and no step said why. Run `dev board land "
                        .. short
                        .. "` again."
                )
            end
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
        dev_command.note("Trunk moved while the card was rechecked. Rebasing and rechecking again.")
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

function commands.ship(backend, opts, _, _, _, raw)
    return ship.ship(backend, { rev = opts.rev, command = raw.passthrough or {} }, {
        move_card = move_card,
        outcome = function(home, argv)
            return M.run("outcome", argv, home)
        end,
        count_text = dev_text.count,
    })
end

function commands.turn(backend, opts, args)
    local releasing = opts.release == true
    if not args.card or listed(args.rest) then
        return usage("Name the one card to take the landing turn for.")
    end
    local seconds = turn.HOLD_SECONDS
    if opts.hold then
        seconds = opts.hold:match("^%d+$") and tonumber(opts.hold)
        if not seconds or seconds < 1 or seconds > turn.MAX_HOLD_SECONDS then
            return usage(
                "The --hold flag needs a whole number of seconds up to "
                    .. turn.MAX_HOLD_SECONDS
                    .. "."
            )
        end
    end
    local wait, bad_wait = wait_seconds(opts)
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
    local card, err = find_card(backend, args.card)
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
---@param given string[]? the words after the card
---@return string[]? words the words to set, empty with none
---@return boolean|dev.cmd.board.Result none whether the field is cleared, or the failure
local function allow_words(given)
    if not given then
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
    for _, word in ipairs(given) do
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
    if none and #given > 1 then
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

function commands.allow(backend, _, args)
    local words, none = allow_words(args.card and listed(args.words))
    if not words then
        return none
    end
    local refused = claim_refused(backend, args.card, "change its allow field")
    if refused then
        return refused
    end
    local card, short = write_field(backend, args.card, board.ALLOW_FIELD, function(id, fence)
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
---@param args table<string, any> the parsed arguments, `card` and the `names` list
---@param key string the field's key
---@param noun string what a name is, for the messages
---@return dev.cmd.board.Result result the output, or a message and the exit code
local function set_names(backend, args, key, noun)
    local names = listed(args.names)
    if not args.card or not names then
        return usage("Needs a card and one or more " .. noun .. " names.")
    end
    for _, name in ipairs(names) do
        if not name:find("%S") or name:find("%c") then
            return usage("A " .. noun .. " name must be one line of text.")
        end
    end
    local refused = claim_refused(backend, args.card, "change its " .. noun .. "s")
    if refused then
        return refused
    end
    local card, short = write_field(backend, args.card, key, function(id, fence)
        return backend:set_field(id, key, table.concat(names, "\n"), fence)
    end)
    if not card then
        return short
    end
    return { output = "set " .. noun .. "s " .. short .. ", " .. dev_text.count(#names, "name") }
end

function commands.tests(backend, _, args)
    return set_names(backend, args, board.TESTS_FIELD, "test")
end

function commands.files(backend, _, args)
    return set_names(backend, args, board.FILES_FIELD, "file")
end

local function link_rows(list, columns)
    local rows = {}
    for at, link in ipairs(list) do
        rows[#rows + 1] = { link.kind, link.id:sub(1, board.MIN_PREFIX), link.board or "-" }
        if columns then
            rows[#rows][4] = columns[at]
        end
    end
    return table.concat(board.table_lines(rows), "\n")
end

local function link_columns(backend, list)
    local columns, others = {}, {}
    for at, link in ipairs(list) do
        local reader = backend
        if link.board then
            if others[link.board] == nil then
                others[link.board] = backend:other_board(link.board) or false
            end
            reader = others[link.board]
        end
        local linked = reader and reader:card(link.id)
        columns[at] = linked and linked.column or "-"
    end
    return columns
end

local function link_ends(backend, args)
    if not args.card or not args.kind or not args.other then
        return nil,
            nil,
            nil,
            usage("Needs a card, a kind (" .. LINK_HELP .. ") and the other card.")
    end
    if not index_of(board.LINK_KINDS, args.kind) then
        return nil,
            nil,
            nil,
            usage("Unknown link kind " .. args.kind .. ". The kinds are " .. LINK_HELP .. ".")
    end
    local card, err = find_card(backend, args.card)
    if not card then
        return nil, nil, nil, err
    end
    local other, shown
    other, shown, err = other_card(backend, args.other)
    if not other then
        return nil, nil, nil, err
    end
    return card, other, shown
end

function commands.link(backend, _, args)
    local card, other, shown, err = link_ends(backend, args)
    if not card then
        return err
    end
    if args.kind == board.LinkKind.PARENT and other.kind ~= board.Kind.EPIC then
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
    local ok, message = backend:link(card.id, args.kind, other.id)
    if not ok then
        return failure(message)
    end
    return {
        output = "linked " .. card.id:sub(1, board.MIN_PREFIX) .. " " .. args.kind .. " " .. shown,
    }
end

function commands.epic(backend, _, args)
    if not args.card then
        return usage("Needs a card.")
    end
    local card, err = find_card(backend, args.card)
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

function commands.responsible(backend, opts, args)
    if not args.card or (opts.clear and args.name) then
        return usage("Needs a card, and a session name or --clear to change it.")
    end
    local card, err = find_card(backend, args.card)
    if not card then
        return err
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    if not args.name and not opts.clear then
        return { output = short .. " " .. (card.responsible or "none") }
    end
    local name = args.name
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

function commands.due(backend, opts, args)
    if not args.card or (opts.clear and args.date) then
        return usage("Needs a card, and a YYYY-MM-DD date or --clear.")
    end
    local date = args.date
    if date and not calendar_date(date) then
        return usage("The date is written YYYY-MM-DD and must exist.")
    end
    local card, err = find_card(backend, args.card)
    if not card then
        return err
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    if not date and not opts.clear then
        if card.due then
            return { output = short .. " due " .. card.due }
        end
        return { output = short .. " has no due date" }
    end
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

function commands.delete(backend, opts, args)
    local reason = opts.reason
    if not args.card or reason == nil or reason:find("^%s*$") then
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
    local card, err = find_card(backend, args.card)
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

function commands.restore(backend, _, args)
    if not args.card then
        return usage("Needs a card.")
    end
    if not backend.restore then
        return failure(NO_RESTORE)
    end
    local binned, message = backend:binned()
    if not binned then
        return failure(message)
    end
    local item, why = board.resolve(binned, args.card, "card in the bin")
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

function commands.unlink(backend, _, args)
    local card, other, shown, err = link_ends(backend, args)
    if not card then
        return err
    end
    local list, message = backend:links(card.id)
    if not list then
        return failure(message)
    end
    for _, link in ipairs(list) do
        if link.kind == args.kind and link.id == other.id then
            local ok
            ok, message = backend:unlink(card.id, args.kind, other.id)
            if not ok then
                return failure(message)
            end
            return {
                output = "unlinked "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " "
                    .. args.kind
                    .. " "
                    .. shown,
            }
        end
    end
    local held = #list == 0 and "It holds no links."
        or "Its links are listed below.\n" .. link_rows(list)
    return failure("The card holds no " .. args.kind .. " link to " .. shown .. ". " .. held)
end

function commands.attach(backend, _, args)
    local files = args.files or {}
    if args.card == nil or #files < 1 then
        return usage("Needs a card and one or more files.")
    end
    for index = 1, #files do
        if not fs.is_file(files[index]) then
            return failure(files[index] .. " is not a file.")
        end
    end
    local card, err = find_card(backend, args.card)
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
    for index = 1, #files do
        local name = fs.basename(files[index])
        if names[name] then
            lines[#lines + 1] = "skipped " .. name
        else
            local made
            made, message = backend:attach(card.id, files[index])
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

function commands.attachments(backend, _, args)
    if args.card == nil then
        return usage("Needs a card.")
    end
    local card, err = find_card(backend, args.card)
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

function commands.detach(backend, _, args)
    if args.card == nil or args.attachment == nil then
        return usage("Needs a card and an attachment id.")
    end
    local card, err = find_card(backend, args.card)
    if not card then
        return err
    end
    local held, message = backend:attachments(card.id)
    if not held then
        return failure(message)
    end
    local match
    for _, attachment in ipairs(held) do
        if attachment.id:sub(1, #args.attachment) == args.attachment then
            if match then
                return failure(args.attachment .. " matches more than one attachment.")
            end
            match = attachment
        end
    end
    if not match then
        return failure("The card holds no attachment with the id " .. args.attachment .. ".")
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

function commands.download(backend, opts, args)
    if args.card == nil or args.attachment == nil then
        return usage("Needs a card and an attachment id or name.")
    end
    local card, err = find_card(backend, args.card)
    if not card then
        return err
    end
    local held, message = backend:attachments(card.id)
    if not held then
        return failure(message)
    end
    local matches = {}
    for _, attachment in ipairs(held) do
        if
            attachment.id:sub(1, #args.attachment) == args.attachment
            or attachment.name == args.attachment
        then
            matches[#matches + 1] = attachment
        end
    end
    if #matches == 0 then
        return failure(
            "The card holds no attachment with the id or name " .. args.attachment .. "."
        )
    end
    if #matches > 1 then
        return failure(args.attachment .. " matches more than one attachment.")
    end
    local match = matches[1]
    local name = fs.basename(match.name)
    if name == "" or name == "." or name == ".." then
        return failure("The attachment's name " .. match.name .. " cannot name a file.")
    end
    local dir = opts.out
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

function commands.boards(backend)
    local names, message = backend:boards()
    if not names then
        return failure(message)
    end
    return { output = table.concat(names, "\n") }
end

function commands.whoami(backend)
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
    local drift = {}
    for _, side in ipairs({ "beyond", "lacks" }) do
        local names = who.drift and who.drift[side] or {}
        if #names > 0 then
            drift[#drift + 1] = side .. " " .. table.concat(names, ", ")
        end
    end
    lines[#lines + 1] = "drift: " .. (#drift > 0 and table.concat(drift, "; ") or "none")
    if who.preset then
        table.insert(lines, 5, "preset: " .. who.preset)
    end
    return { output = table.concat(lines, "\n") }
end

function commands.permissions(backend)
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

function commands.columns(backend, _, args)
    local rows, message = backend:columns(args.board)
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
---@param backend dev.board.Backend the board that refused
---@param message string the backend's reason
---@return dev.cmd.board.Result result the failure
local function board_edit_failure(backend, message)
    if board.forbidden(backend:failure(message)) then
        return failure(
            "Pomb refused the change. This token may not edit the board, "
                .. "so use a lead token, which holds columns.edit."
        )
    end
    return failure(message)
end

---Column field by flag name
local COLUMN_SWITCHES = {
    clears_blockers = "clears_blockers",
    blocked = "is_blocked",
}

function commands.column(backend, opts, args)
    if args.name == nil then
        return usage("Needs a column name.")
    end
    local fields = {}
    for flag, field in pairs(COLUMN_SWITCHES) do
        local value = opts[flag]
        if value ~= nil then
            if value ~= "on" and value ~= "off" then
                return usage("The --" .. flag:gsub("_", "-") .. " flag takes on or off.")
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
        if column.name:lower() == args.name:lower() then
            name = column.name
        end
    end
    if not name then
        return failure("The board has no column " .. args.name .. ".")
    end
    local done
    done, message = backend:set_column(name, fields)
    if not done then
        return board_edit_failure(backend, message)
    end
    return { output = "Set the flags of " .. name .. "." }
end

local function set_limit(backend, value, board_name)
    local limit = value:match("^%d+$") and tonumber(value)
    if not limit or limit < 1 then
        return usage("The --set flag needs a whole number of at least 1.")
    end
    if board_name ~= nil then
        return usage("The --set flag changes only this project's board.")
    end
    local stages = backend.stages
    local columns = { stages.progress, stages.review, stages.verify }
    local done, message = backend:set_limit_group(columns, limit)
    if not done then
        return board_edit_failure(backend, message)
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

function commands.limits(backend, opts, args)
    if opts.set then
        return set_limit(backend, opts.set, args.board)
    end
    local limits, message = backend:limits(args.board)
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

function commands.links(backend, _, args)
    if args.card == nil then
        return usage("Needs a card.")
    end
    local card, err = find_card(backend, args.card)
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
    return { output = link_rows(list, link_columns(backend, list)) }
end

function commands.stale(backend, opts, _, now)
    return stale.stale(backend, opts, now)
end

function commands.lint(backend, opts, args)
    local strict = opts.strict == true
    local open_only = opts.open == true and not args.card
    local required, bad = lint_rows(backend, "required")
    if bad then
        return bad
    end
    local bare, bad_bare = lint_rows(backend, "bare_rows")
    if bad_bare then
        return bad_bare
    end
    local cards, message = backend:cards()
    if not cards then
        return failure(message)
    end
    if args.card then
        local only, why = board.resolve(cards, args.card)
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
        local rules, why, owned = lint.card(card, {
            stages = backend.stages,
            facts = facts,
            strict = strict,
            required = required,
            bare = bare,
        })
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

---Claim a card once, refusing with the full-column code when the in-flight limit is full.
---@param backend dev.board.Backend the board
---@param opts table<string, any> the parsed flags
---@param args table<string, any> the parsed arguments
---@return dev.cmd.board.Result result the output, or a message and the exit code
local function take_once(backend, opts, args)
    if args.card == nil then
        return usage("Needs a card.")
    end
    local name, why = agent_name(opts.as)
    if why then
        return why
    end
    local limit, bad = runner.limit(opts.max_size)
    if bad then
        return bad
    end
    local card, err = find_card(backend, args.card)
    if not card then
        return err
    end
    local from = opts.from
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
            return runner.full(refused.message)
        end
    end
    if from then
        local held = claims.read(card.id)
        local fence = held and held.fence
        local released, stuck, reason, detail = backend:release(card.id, fence, from)
        if not released then
            return failure(board.release_refusal(reason, stuck, detail, fence))
        end
        claims.stop(card.id)
    end
    local result, fence = claim_card(backend, card, name)
    if not fence then
        if rival and result.message and result.message:find("owned by", 1, true) then
            result.message = result.message
                .. " To take it over, run dev board take "
                .. short
                .. " "
                .. FROM_FLAG
                .. " "
                .. card.claimant
                .. "."
        end
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
        dev_command.note(
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
            dev_command.note(
                "Took card " .. short .. ", but the handoff note was not posted. " .. message
            )
        end
    end
    return claimed_view(backend, card, result)
end

---Claim a card, and with `--wait SECONDS` try again while the in-flight limit is full.
---@param backend dev.board.Backend the board
---@param opts table<string, any> the parsed flags
---@param args table<string, any> the parsed arguments
---@param clock dev.cmd.board.move.Opts? how to sleep and tell time
---@return dev.cmd.board.Result result the result of the last try
local function take_card(backend, opts, args, clock)
    local wait, bad_wait = wait_seconds(opts)
    if not wait then
        return bad_wait
    end
    return until_room(wait, clock, function()
        return take_once(backend, opts, args)
    end)
end

function commands.take(backend, opts, args)
    return take_card(backend, opts, args)
end

---Claim a card, retrying a full in-flight limit until room frees when `--wait` is given.
---@param backend dev.board.Backend the board
---@param argv string[] the arguments after `take`
---@param clock dev.cmd.board.move.Opts? how to sleep and tell time
---@return dev.cmd.board.Result result the result of the last try
function M.take(backend, argv, clock)
    backend.stages = backend.stages
        or board.stages(backend.column_map, backend:done_columns() or {})
    local opts, args = reparse("take", argv)
    if not opts then
        return args
    end
    return take_card(backend, opts, args, clock)
end

function commands.release(backend, _, args)
    if args.card == nil then
        return usage("Needs a card.")
    end
    local card, err = find_card(backend, args.card)
    if not card then
        return err
    end
    local held = claims.read(card.id)
    if not held then
        return failure("No claim was taken for " .. args.card .. " with `dev board take`.")
    end
    local ok, message, reason, detail = backend:release(card.id, held.fence)
    if not ok then
        return failure(board.release_refusal(reason, message, detail, held.fence))
    end
    claims.stop(card.id)
    local stuck, cause = role_clock.follow(backend, card, nil, "")
    if stuck then
        dev_command.note(clock_note("Released, but the clock did not stop.", stuck, cause))
    end
    return {
        output = string.format(
            "released %s, fence %d",
            card.id:sub(1, board.MIN_PREFIX),
            held.fence
        ),
    }
end

function commands.run(backend, opts)
    return runcard.run(backend, opts, {
        dispatch = M.run,
        add = function(home, argv)
            return M.run("add", argv, home)
        end,
        find_card = find_card,
        card_line = card_line,
        name_chars = board_setup.NAME_CHARS,
    })
end

---Run one board subcommand against a backend, parsing its words through the subcommand's spec.
---@param sub string the subcommand, such as `ls`, `move` or `outcome`
---@param argv string[] the words after the subcommand
---@param backend dev.board.Backend the board
---@param now integer? the time in seconds since the epoch that `stale` counts from, the clock when
---   nil
---@param screen dev.ui.Context? the terminal `ls` draws for, left nil for the plain lines
---@return dev.cmd.board.Result result the output, or a message and the exit code
function M.run(sub, argv, backend, now, screen)
    local finished = backend:done_columns() or {}
    board.retarget(backend, backend.column_map, backend.root, finished)
    if internal[sub] then
        return internal[sub](backend, argv, now, screen)
    end
    local opts, args, passthrough = reparse(sub, argv)
    if not opts then
        return args
    end
    return commands[sub](
        backend,
        opts,
        args,
        now,
        screen,
        { argv = argv, passthrough = passthrough }
    )
end

---The standing `[board.pomb]` token key a name sends in place of its own token.
---@param token_key string the token key the caller asked for
---@param agent string the agent name
---@return string? key the standing key, nil when the name sends none
local function standing_key(token_key, agent)
    if token_key == LEAD_TOKEN_KEY then
        return nil
    end
    if guards.is_verifier(agent) then
        return VERIFIER_TOKEN_KEY
    end
    if guards.is_reviewer(agent) then
        return REVIEWER_TOKEN_KEY
    end
    return nil
end

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
    local key = standing_key(token_key, dev_os.getenv("DEV_AGENT") or "")
    local standing = key ~= nil and config.user("board.pomb." .. key) ~= nil
    local url = config.user("board.pomb.url")
    if url == nil then
        url = dev_config.prompt("board.pomb.url")
    end
    local backend, reason = pomb.new({
        url = url,
        token = config.user("board.pomb." .. (standing and key or token_key)),
        name = settings.name,
        lead = token_key == LEAD_TOKEN_KEY,
        standing = standing,
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
        dev_command.die(NO_BOARD)
    end
    if backend ~= board.Backend.POMB and backend ~= board.Backend.LOCAL then
        dev_command.die(
            'The `backend` setting of `[board]` must be "pomb" or "local" in `.dev/config.toml`.'
        )
    end
    local name = config.get(ctx.root, "board.name")
    if name == nil then
        name = fs.basename(ctx.root)
    end
    if type(name) ~= "string" or name == "" then
        dev_command.die(
            "The `name` setting of `[board]` must be a non-empty string in `.dev/config.toml`."
        )
    end
    local path = config.get(ctx.root, "board.path")
    if path ~= nil then
        if backend ~= board.Backend.LOCAL then
            dev_command.die('The `path` setting of `[board]` only applies to `backend = "local"`.')
        end
        if
            type(path) ~= "string"
            or not path:find(PATH_PATTERN)
            or path:find("..", 1, true)
            or path:find("//", 1, true)
        then
            dev_command.die(
                "The `path` setting of `[board]` must be a relative path inside the project, such as `.dev/board.json`."
            )
        end
        path = ctx.root .. "/" .. path
    end
    local columns = column_map(ctx.root)
    local collision = board.column_collision(columns)
    if collision then
        dev_command.die(collision)
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
        return (dev_text.sentence(message):gsub("%.$", ""))
            .. ". This token may not change this board, so run `dev board init --admin`."
    end
    return dev_text.sentence(message)
end

---Print one warning from the layout change, with the hint when the token may not change the board.
---@param line string a `Warning`, or a finished sentence
---@param detail string? the backend's message for a `Warning`
---@param reason dev.board.init.Reason? what `init.run` named
local function init_warning(line, detail, reason)
    if line == init.Warning.ROLES_UNREADABLE then
        line = "Agent roles were not checked. The roles list could not be read. " .. detail
    end
    dev_command.note(reason and init_refusal(line, reason) or line)
end

local function init_local(ctx, flags, admin)
    if admin then
        dev_command.usage_error(ctx, "--admin applies to a Pomb board, not a local one")
    end
    local found = settings(ctx)
    if flags["--name"] and flags["--name"] ~= found.name then
        dev_command.usage_error(
            ctx,
            "--name " .. flags["--name"] .. " is not the [board] name " .. found.name
        )
    end
    local backend, message = M.open(found)
    if not backend then
        dev_command.die(message)
    end
    local changes, reason
    changes, message, reason = init.run(backend, found.name, dev_command.say, {
        stages = backend.stages,
        lanes = board_setup.config_lanes(ctx),
        warn_first_lane = false,
        warn = init_warning,
    })
    if not changes then
        dev_command.die(init_refusal(message, reason))
    end
    dev_command.say(
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
        return "Pomb answered "
            .. detail.status
            .. ": "
            .. (detail.message and (detail.message:gsub("%.$", "")) .. "." or "no message.")
    elseif reason == Reason.NO_CODE then
        return "Pomb sent a sign-in with no code."
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

---Make or bring a board to the standard, for `dev board init`.
---@param ctx dev.Ctx the command context
---@param init_opts table<string, any> the parsed flags, `name` and `admin`
---@return integer code the exit code
local function run_init(ctx, init_opts)
    local admin = init_opts.admin == true
    local flags = { ["--name"] = init_opts.name }
    if config.get(ctx.root, "board.backend") == board.Backend.LOCAL then
        return init_local(ctx, flags, admin)
    end
    if not admin and guards.delete_refusal() == guards.Refusal.NOT_LEAD then
        dev_command.die(not_lead_message("initializes a board"))
    end
    local name, missing = board_setup.board_name(ctx, flags)
    local opts = {
        url = config.user("board.pomb.url"),
        token = config.user("board.pomb.lead_token"),
        name = name,
        lead = not admin,
    }
    if not admin and opts.token == nil then
        dev_command.die(
            "The `lead_token` setting of `[board.pomb]` is not set in `~/.config/dev/config.toml`. "
                .. "Set it to `pass:<entry>` or run with `--admin`."
        )
    end
    local backend, reason = pomb.new(opts)
    if not backend then
        dev_command.die(POMB_REFUSALS[reason])
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
            dev_command.die(sign_in_refusal(sign_in_reason, detail))
        end
        backend:authorize(secret)
        local ok
        ok, message = backend:admin()
        if not ok then
            dev_command.die(message)
        end
    end
    local changes, init_reason
    changes, message, init_reason = init.run(backend, name, dev_command.say, {
        stages = backend.stages,
        lanes = board_setup.config_lanes(ctx),
        warn_first_lane = true,
        warn = init_warning,
    })
    if not changes then
        dev_command.die(init_refusal(message, init_reason))
    end
    if missing then
        local written, failed = board_setup.write_section(ctx.root, name)
        if not written then
            dev_command.die(
                "Cannot write " .. ctx.root .. "/.dev/config.toml. " .. dev_text.sentence(failed)
            )
        end
        dev_command.say("wrote [board] to .dev/config.toml")
    end
    dev_command.say(
        changes == 0 and ("Board " .. name .. " already follows the standard. Nothing changed.")
            or ("board " .. name .. ": " .. changes .. (changes == 1 and " change" or " changes"))
    )
    return 0
end

local function description_args(argv)
    local opts, args = reparse("edit", argv)
    if not opts then
        return nil, args.message
    end
    if args.card == nil or args.text ~= nil then
        return nil, "Needs a card, and the description from --file PATH or standard input."
    end
    local text, message
    if opts.file then
        text, message = fs.read(opts.file)
        if not text then
            return nil, "Cannot read " .. opts.file .. ": " .. tostring(message) .. "."
        end
    elseif dev_os.isatty(0) then
        return nil, "Needs the description from --file PATH or standard input."
    else
        text = dev_os.stdin:read("*a")
    end
    text = text:gsub("%s+$", "")
    if text == "" then
        return nil, "The new description is empty."
    end
    if opts.board then
        return { args.card, "--board", opts.board, text }
    end
    return { args.card, text }
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
        elseif
            pomb.unreachable(backend:failure(result.message), idempotent(entry.sub, entry.args))
        then
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
    dev_command.note(line)
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
        dev_command.die(message)
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
        dev_command.die(not_lead_message(action))
    end
    local found = settings(ctx)
    if found.backend ~= board.Backend.POMB then
        dev_command.die(NO_BIN)
    end
    if config.user("board.pomb." .. LEAD_TOKEN_KEY) == nil then
        dev_command.die(
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
        dev_command.die(message)
    end
    return backend
end

local function run_token_mint(ctx, opts)
    if not opts.role or not opts.as or opts.as == "" then
        dev_command.usage_error(ctx, "needs --role ROLE and --as NAME")
    end
    local hours = opts.hours and opts.hours:match("^%d+$") and tonumber(opts.hours)
    if opts.hours and (not hours or hours < 1 or hours > pomb.MAX_TOKEN_HOURS) then
        dev_command.usage_error(
            ctx,
            "--hours takes a whole number from 1 to " .. pomb.MAX_TOKEN_HOURS
        )
    end
    local backend = open_lead(ctx, "mints a role token")
    local issued, message =
        backend:mint(opts.role, opts.as, { hours = hours, renew = opts.renew == true })
    if not issued then
        dev_command.die(message)
    end
    local stamp = issued.expires > 0 and os.date("!%Y-%m-%dT%H:%M:%SZ", issued.expires) or "never"
    dev_command.say(
        string.format(
            "minted role %s as %s, label %s, expires %s",
            issued.role,
            opts.as,
            issued.label,
            stamp
        )
    )
    return 0
end

local function run_token_revoke(ctx, opts)
    if not opts.as or opts.as == "" then
        dev_command.usage_error(ctx, "needs --as NAME")
    end
    local backend = open_lead(ctx, "revokes a role token")
    local done, message = backend:revoke(opts.as)
    if not done then
        dev_command.die(message)
    end
    dev_command.say(
        done.revoked and ("Revoked the role token of " .. opts.as)
            or ("Nothing was left to revoke for " .. opts.as .. ".")
    )
    return 0
end

local function run_seat_reset(ctx, _, args)
    if args.card == nil or args.seat == nil then
        dev_command.usage_error(ctx, "needs CARD and SEAT")
    elseif not args.seat:find(SEAT_NAME_PATTERN) then
        dev_command.usage_error(ctx, "SEAT is a seat name such as code, style or recheck")
    end
    local found = settings(ctx)
    if found.backend ~= board.Backend.POMB then
        dev_command.die("A local board has no seats to reset.")
    end
    local backend, message = M.open(found)
    if not backend then
        dev_command.die(message)
    end
    local card, err = find_card(backend, args.card)
    if not card then
        dev_command.die(err.message)
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    local seat = args.seat
    local done, why, missing, previous = backend:reset_seat(card.id, seat)
    if not done then
        if missing then
            dev_command.die(
                string.format(
                    "The reset of seat %s on card %s needs the %s permission, and Pomb refused this token (%s).",
                    seat,
                    short,
                    missing,
                    why
                )
            )
        end
        dev_command.die(why)
    end
    if not previous then
        dev_command.say(string.format("Added seat %s to card %s, open.", seat, short))
        return 0
    end
    dev_command.say(
        string.format(
            "Reset seat %s on card %s. It was held by %s with verdict %s, and is open again.",
            seat,
            short,
            previous.holder or "no one",
            previous.verdict or "no verdict"
        )
    )
    return 0
end

function Owner.print_needs_human(found)
    local backend, message = M.open(found)
    if not backend then
        dev_command.die(message)
    end
    local rows, unreadable = backend:needs_human()
    if not rows then
        dev_command.die(unreadable)
    end
    if #rows == 0 then
        dev_command.say("No cards.")
    else
        local cells = {}
        for i, row in ipairs(rows) do
            cells[i] = { row.board, row.id:sub(1, board.MIN_PREFIX), row.epic, row.name }
        end
        dev_command.say(table.concat(board.table_lines(cells), "\n"))
    end
    if #unreadable > 0 then
        dev_command.say("unreadable: " .. table.concat(unreadable, ", "))
    end
end

local function run_status(ctx, opts)
    local found = settings(ctx)
    dev_command.say("backend: " .. found.backend)
    dev_command.say("board: " .. found.name)
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
                dev_command.say("queued: " .. left)
            end
        end
    end
    local soon, expired = tokenfile.expiring(os.time())
    if soon > 0 or expired > 0 then
        dev_command.say(
            string.format("tokens: %d expire within an hour, %d expired", soon, expired)
        )
    end
    if opts.all then
        Owner.print_needs_human(found)
    end
    return 0
end

M.wait = board_wait.wait

local function run_wait(ctx, opts)
    local found = settings(ctx)
    if found.backend ~= board.Backend.POMB then
        dev_command.die("A local board has nothing to wait on.")
    end
    local backend = open_board(ctx)
    local result = M.wait(backend, opts, { stem = board_wait.cursor_path(found.name) })
    if result.message then
        if result.code == USAGE then
            dev_command.usage_error(ctx, result.message)
        end
        dev_command.die(result.message)
    end
    dev_command.say(result.output)
    return 0
end

local function run_sync(ctx)
    local found = settings(ctx)
    if found.backend ~= board.Backend.POMB then
        dev_command.die("A local board has nothing to sync.")
    end
    local pending = queue.new(found.name)
    local waiting, message, reason = pending:count()
    if not waiting then
        dev_command.die(
            queue_unreadable(pending.path, reason, message) .. " The queue is left in place."
        )
    end
    if waiting == 0 then
        dev_command.say("Nothing is queued.")
        return 0
    end
    local backend
    backend, message = M.open(found)
    if not backend then
        dev_command.die(message)
    end
    local left
    left, message, reason = replay(backend, pending, print)
    if not left then
        dev_command.die(
            queue_unreadable(pending.path, reason, message) .. " The queue is left in place."
        )
    end
    if left > 0 then
        dev_command.say("queued: " .. left)
        return 1
    end
    dev_command.say("synced")
    return 0
end

local OWN_HANDLERS = {
    ["init"] = run_init,
    ["token mint"] = run_token_mint,
    ["token revoke"] = run_token_revoke,
    ["seat reset"] = run_seat_reset,
    ["status"] = run_status,
    ["wait"] = run_wait,
    ["sync"] = run_sync,
}

---The words of a subcommand with the environment's ticker added to an outcome tick.
---@param argv string[] the words after `outcome`
---@param opts table<string, any> the parsed flags
---@return string[] argv the words, with `--as NAME` when a tick named no one and DEV_AGENT is set
local function env_ticker(argv, opts)
    if opts.tick == nil or opts.as ~= nil then
        return argv
    end
    local name = agent_name()
    if not name then
        return argv
    end
    local with = {}
    for index, word in ipairs(argv) do
        with[index] = word
    end
    with[#with + 1] = AS_FLAG
    with[#with + 1] = name
    return with
end

---Choose the backend a subcommand runs against, the lead's for the ones that need its token.
---@param sub string the subcommand
---@param ctx dev.Ctx the command context
---@param opts table<string, any> the parsed flags
---@param argv string[] the words after the subcommand
---@return dev.board.Backend backend the board
---@return dev.board.queue.Queue? pending the queue of changes to replay, nil on the lead's board
local function backend_for(sub, ctx, opts, argv)
    local pomb_board = function()
        return settings(ctx).backend == board.Backend.POMB
    end
    if sub == "delete" then
        return open_lead(ctx)
    elseif sub == "outcome" and opts.delete ~= nil and pomb_board() then
        return open_lead(ctx, "deletes an outcome", "subtasks.delete")
    elseif sub == "limits" and opts.set ~= nil and pomb_board() then
        return open_lead(ctx, "sets a limit", "columns.edit")
    elseif sub == "column" and pomb_board() then
        return open_lead(ctx, "sets a column flag", "columns.edit")
    end
    local backend, pending = open_board(ctx)
    if sub == "move" and pomb_board() then
        if closes_epic(backend, argv) then
            return open_lead(ctx, "closes an epic", "epics.manage"), nil
        end
    end
    return backend, pending
end

---Run one board subcommand for the command line: open the board, run it and print the result.
---@param sub string the subcommand, `ls` or `token mint`
---@param ctx dev.Ctx the command context, whose `argv` holds the words after the subcommand
---@return integer code the exit code
function M.invoke(sub, ctx)
    local argv = ctx.argv
    if sub == "ship" and ctx.dashed and #(ctx.passthrough or {}) == 0 then
        dev_command.usage_error(ctx, "Needs a command after --.")
    end
    if sub == "ship" and ctx.passthrough and #ctx.passthrough > 0 and not index_of(argv, "--") then
        argv = { table.unpack(argv) }
        argv[#argv + 1] = "--"
        for _, word in ipairs(ctx.passthrough) do
            argv[#argv + 1] = word
        end
    end
    local opts, args = reparse(sub, argv)
    if not opts then
        dev_command.usage_error(ctx, args.message)
    end
    local own = OWN_HANDLERS[sub]
    if own then
        return own(ctx, opts, args)
    end
    if sub == "run" and opts.orders ~= nil and not opts["end"] then
        local _, refused = runcard.precheck(opts, board_setup.NAME_CHARS)
        if refused then
            if refused.code == USAGE then
                dev_command.usage_error(ctx, refused.message)
            end
            dev_command.note(refused.message)
            return refused.code or FAILURE
        end
        board_setup.ensure_board(ctx, function(making)
            local init_opts = reparse("init", making.argv)
            return run_init(making, init_opts or {})
        end)
    end
    if sub == "edit" then
        local why
        argv, why = description_args(argv)
        if not argv then
            dev_command.usage_error(ctx, why)
        end
        opts, args = reparse(sub, argv)
    end
    if sub == "outcome" then
        argv = env_ticker(argv, opts)
        opts, args = reparse(sub, argv)
    end
    if sub == "lint" then
        local strict = config.get(ctx.root, "board.lint.strict")
        if strict ~= nil and type(strict) ~= "boolean" then
            dev_command.die("The `strict` setting of `[board.lint]` must be true or false.")
        end
        if strict and not opts.strict then
            argv = { "--strict", table.unpack(argv) }
        end
    end
    local backend, pending = backend_for(sub, ctx, opts, argv)
    local result = M.run(sub, argv, backend, nil, sub == "ls" and ui.context() or nil)
    if result.message then
        local note = sub == "note" and (opts.edit ~= nil or opts.delete ~= nil)
        local queued = result.queue
        local form_skips = sub == "outcome" and (opts.convert or opts.delete ~= nil)
        if
            not queued
            and QUEUE_RULES[sub]
            and not result.unqueued
            and not note
            and not form_skips
        then
            queued = { { sub = sub, args = argv } }
        end
        if
            pending
            and queued
            and pomb.unreachable(
                backend:failure(result.message),
                idempotent(queued[1].sub, queued[1].args)
            )
        then
            for _, entry in ipairs(queued) do
                local ok, why, reason = pending:push(entry.sub, entry.args)
                if not ok then
                    dev_command.die(
                        result.message
                            .. " The change could not be queued. "
                            .. queue_unreadable(pending.path, reason, why)
                    )
                end
            end
            dev_command.say(QUEUED_NOTICE)
            return 0
        end
        if result.code == USAGE then
            dev_command.usage_error(ctx, result.message)
        end
        dev_command.note(result.message)
        return result.code or FAILURE
    end
    if result.page then
        ui.page(result.output .. "\n")
    else
        dev_command.say(result.output)
    end
    dev_os.stdout:flush()
    for _, line in ipairs(result.warnings or {}) do
        stderr_line(line)
    end
    return result.code or 0
end

return M
