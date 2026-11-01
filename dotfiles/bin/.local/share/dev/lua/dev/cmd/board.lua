local board = require("dev.board")
local box = require("dev.cmd.box")
local check = require("dev.board.check")
local claims = require("dev.board.claims")
local config = require("dev.config")
local device = require("dev.board.device")
local devos = require("dev.os")
local fs = require("dev.fs")
local init = require("dev.board.init")
local json = require("dev.json")
local land = require("dev.board.land")
local lint = require("dev.board.lint")
local localboard = require("dev.board.localboard")
local pomb = require("dev.board.pomb")
local queue = require("dev.board.queue")
local review = require("dev.board.review")
local store = require("dev.board.store")
local text_width = require("dev.text").width
local toml = require("dev.toml")
local ui = require("dev.ui")
local vcs = require("dev.vcs")
local verb = require("dev.verb")

local stderr = io.stderr
local NO_BOARD = "dev: no board for this project"
local USAGE = 2
local FAILURE = 1
local OWNER_MARK = " (owner)"
local CLAIMANT_CHARS = 200
local NAME_PATTERN = '^[^%c"\\]+$'
local NAME_CHARS = 100
local ADMIN_SCOPE = "admin"
local CLIENT_CHARS = 80
local STALE_DAYS = 7
local ICEBOX_DAYS = 30
local LEAD_HOURS = 1
local STAMP_CHARS = 16
local COMMIT_CHARS = 12
local EXPECT_FAIL_FLAG = "--expect-fail"
local TIMEOUT_FLAG = "--timeout"
local STRICT_FLAG = "--strict"
local RESERVED_NOTE = "a note cannot begin with "
    .. board.CHECK_PREFIX
    .. ", which dev board check writes, or "
    .. board.REVIEW_PREFIX
    .. ", which dev board review writes"
local LINK_HELP = table.concat(board.LINK_KINDS, ", ")
local EDIT_FLAG = "--edit"
local DELETE_FLAG = "--delete"
local KIND_FLAG = "--kind"
local BY_FLAG = "--by"
local REV_FLAG = "--rev"
local GROUP_FLAG = "--group"
local AS_FLAG = "--as"
local RUN_END_FLAG = "--end"
local RUN_ORDERS_FLAG = "--orders"
local RUN_NAME = "run "
local HUMAN_ACTOR = "human"
local ANSWERED_NOTE = " (answered, waiting for your move)"
local LOCAL_NAME_PATTERN = "^[%w][%w._-]*$"
local PATH_PATTERN = "^[%w._][%w._/-]*$"
local QUEUED_NOTICE = "queued: Pomb unreachable, will sync"
local DOT = "●"
local HOLLOW = "○"
local UNSIZED_CELLS = 3
local METER_CELLS = 4
local GROUP_INDENT = "  "
local SIZE_ORDER = { "yellow", "green", "blue", "red" }
local SIZE_DOTS = { yellow = 1, green = 2, blue = 3, red = 4 }
local SIZE_WORDS = { yellow = "1", green = "2", blue = "3", red = ">3" }
local SIZE_STYLES = {
    yellow = ui.Style.YELLOW,
    green = ui.Style.GREEN,
    blue = ui.Style.BLUE,
    red = ui.Style.RED,
}
local function column_style(roles, column)
    if column == roles.progress then
        return ui.Style.GREEN
    elseif column == roles.blocked then
        return ui.Style.YELLOW
    end
    return ui.Style.DIM
end
local HEADERS = { "ID", "COLUMN", "SIZE", "LABELS", "DONE", "HELD BY", "NAME" }
local QUEUE_RULES = {
    add = { idempotent = false },
    move = { idempotent = true },
    discard_move = { idempotent = true },
    order = { idempotent = true },
    note = { idempotent = false },
    size = { idempotent = true },
    label = { idempotent = true },
    link = { idempotent = true },
    edit = { idempotent = true },
    rename = { idempotent = true },
    checks = { idempotent = true },
    allow = { idempotent = true },
    tests = { idempotent = true },
    files = { idempotent = true },
    outcome = { idempotent = false },
}
local OutcomeMode = { ADD = "add", RENAME = "rename", TICK = "tick", UNTICK = "untick" }
local OUTCOME_FLAGS = {
    ["--rename"] = OutcomeMode.RENAME,
    ["--tick"] = OutcomeMode.TICK,
    ["--untick"] = OutcomeMode.UNTICK,
}
local CONVERT_FLAG = "--convert"

local function idempotent(sub, args)
    local rule = QUEUE_RULES[sub]
    return (rule ~= nil and rule.idempotent)
        or (sub == "outcome" and OUTCOME_FLAGS[args[2]] ~= nil)
        or false
end

---@class dev.cmd.board.Settings
---@field backend string `pomb` or `local`
---@field name string the board's name
---@field path string? the file of a local board, in the state directory when nil
---@field root string? the project's root, which a tracked path is under
---@field columns table<string, string>? the `[board.columns]` map, keyed by role

---@class dev.cmd.board.Result
---@field output string? what to print on success
---@field message string? what went wrong
---@field code integer? 2 for a usage error, 1 for a failure or a lint finding, nil on success
---@field warnings string[]? lines for standard error when the change still went through
---@field page boolean? whether the output goes through the pager when it is taller than the screen
---@field unqueued boolean? true when the refusal must not be queued for a later sync, as a move to Done is not

---@class dev.cmd.board
---@field handlers table<string, fun(ctx: dev.Ctx): integer> the handlers of the `board` subcommands
---@field open fun(settings: dev.cmd.board.Settings): dev.board.Backend?, string? builds the backend a board uses
local M = { handlers = {} }

local function usage(message)
    return { message = message, code = USAGE }
end

local function failure(message)
    return { message = message, code = FAILURE }
end

local function parse(args, takes, many)
    local flags, positional = {}, {}
    local i = 1
    while i <= #args do
        local arg = args[i]
        i = i + 1
        if takes[arg] then
            if i > #args then
                return nil, usage(arg .. " needs a value")
            end
            if many and many[arg] then
                flags[arg] = flags[arg] or {}
                table.insert(flags[arg], args[i])
            else
                flags[arg] = args[i]
            end
            i = i + 1
        elseif #arg > 1 and arg:sub(1, 1) == "-" then
            return nil, usage("unknown flag " .. arg)
        else
            positional[#positional + 1] = arg
        end
    end
    return flags, positional
end

local function named_column(backend, word)
    local column = backend.roles:column(word)
    if not column then
        return nil, usage("unknown column " .. word .. ", the columns are " .. backend.roles:help())
    end
    return column
end

local function sized(word)
    local color = board.size_color(word)
    if not color then
        return nil, usage("unknown size " .. word .. ", the sizes are " .. board.size_help())
    end
    return color
end

local function unready(color)
    return color == nil or color == board.SIZES.unsized or color == board.SIZES["3+"]
end

local FIELD_REFUSALS = {
    [board.CHECKS_FIELD] = "the board has no checks field, so run dev board init to add it",
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
            or "the board has no " .. key .. " field, so define it on the board first"
    end
end

local function plain(label)
    if label == "" or label:find("%s") or label:find("%c") or label:sub(1, 1) == "-" then
        return nil, usage("label " .. label .. " must be one word that does not start with -")
    end
    return label
end

local function index_of(list, word)
    for i, item in ipairs(list) do
        if item == word then
            return i
        end
    end
end

local function count_text(count, noun)
    return count .. " " .. noun .. (count == 1 and "" or "s")
end

local function size_cell(screen, card)
    local color = card.color or board.SIZES.unsized
    local dots = SIZE_DOTS[color]
    if not dots then
        return ui.paint(screen, HOLLOW:rep(UNSIZED_CELLS), ui.Style.DIM)
    end
    return ui.paint(screen, DOT:rep(dots), SIZE_STYLES[color])
end

local function paint_run(screen, glyph, count, style)
    if count == 0 then
        return ""
    end
    return ui.paint(screen, glyph:rep(count), style)
end

local function meter_cell(screen, card)
    local total = #card.outcomes
    if total == 0 then
        return ui.paint(screen, "-", ui.Style.DIM)
    end
    local ticked = 0
    for _, outcome in ipairs(card.outcomes) do
        if outcome.done then
            ticked = ticked + 1
        end
    end
    local filled = math.floor(METER_CELLS * ticked / total + 0.5)
    return paint_run(screen, "▰", filled, ui.Style.GREEN)
        .. paint_run(screen, "▱", METER_CELLS - filled, ui.Style.DIM)
        .. " "
        .. ticked
        .. "/"
        .. total
end

---@class dev.cmd.board.LsView
---@field holders boolean whether a claimant column is drawn
---@field with_column boolean whether each row names its column

local function terminal_cells(screen, card, view)
    local labels = #card.labels > 0 and table.concat(card.labels, ",") or "-"
    local cells = { card.id:sub(1, board.MIN_PREFIX) }
    if view.with_column then
        local style = column_style(view.roles, card.column)
        cells[#cells + 1] = ui.paint(screen, card.column, style)
    end
    cells[#cells + 1] = size_cell(screen, card)
    cells[#cells + 1] =
        ui.paint(screen, labels, #card.labels > 0 and ui.Style.YELLOW or ui.Style.DIM)
    cells[#cells + 1] = meter_cell(screen, card)
    if view.holders then
        cells[#cells + 1] = card.claimant or ui.paint(screen, "-", ui.Style.DIM)
    end
    cells[#cells + 1] = card.name
    return cells
end

local function terminal_table(screen, cards, view)
    local headers = {}
    for _, header in ipairs(HEADERS) do
        if (header ~= "COLUMN" or view.with_column) and (header ~= "HELD BY" or view.holders) then
            headers[#headers + 1] = header
        end
    end
    local rows = {}
    for _, card in ipairs(cards) do
        rows[#rows + 1] = terminal_cells(screen, card, view)
    end
    return ui.table(screen, headers, rows)
end

local function summary_lines(screen, cards, roles)
    local counts = {}
    for _, card in ipairs(cards) do
        counts[card.column] = (counts[card.column] or 0) + 1
    end
    local parts = { ui.paint(screen, count_text(#cards, "card"), ui.Style.BOLD) }
    local shown = {}
    for _, column in ipairs(roles.list) do
        shown[#shown + 1] = column
    end
    for _, column in ipairs(roles.finished) do
        shown[#shown + 1] = column
    end
    local seen = {}
    for _, column in ipairs(shown) do
        if counts[column] and not seen[column] then
            seen[column] = true
            parts[#parts + 1] =
                ui.paint(screen, counts[column] .. " " .. column:lower(), ui.Style.DIM)
        end
    end
    local legend = { ui.paint(screen, "size", ui.Style.DIM) }
    for _, color in ipairs(SIZE_ORDER) do
        legend[#legend + 1] = ui.paint(screen, DOT:rep(SIZE_DOTS[color]), SIZE_STYLES[color])
            .. " "
            .. SIZE_WORDS[color]
    end
    legend[#legend + 1] = ui.paint(screen, HOLLOW:rep(UNSIZED_CELLS), ui.Style.DIM) .. " unsized"
    return { table.concat(parts, " · "), table.concat(legend, "  ") }
end

local function terminal_flat(screen, cards, opts)
    return terminal_table(
        screen,
        cards,
        { holders = opts.holders, with_column = true, roles = opts.roles }
    )
end

local function terminal_grouped(screen, cards, opts)
    local inner = screen:with_height(screen.height)
    inner.width = screen.width - #GROUP_INDENT
    local lines = terminal_table(
        inner,
        cards,
        { holders = opts.holders, with_column = false, roles = opts.roles }
    )
    local groups, order = {}, {}
    for at, card in ipairs(cards) do
        if not groups[card.column] then
            groups[card.column] = {}
            order[#order + 1] = card.column
        end
        table.insert(groups[card.column], lines[at + 1])
    end
    local out = {}
    for _, column in ipairs(order) do
        if #out > 0 then
            out[#out + 1] = ""
        end
        out[#out + 1] = ui.paint(screen, column, ui.Style.BOLD)
            .. "  "
            .. ui.paint(screen, count_text(#groups[column], "card"), ui.Style.DIM)
        for _, line in ipairs(groups[column]) do
            out[#out + 1] = GROUP_INDENT .. line
        end
    end
    if not opts.shows_done then
        out[#out + 1] = ""
        out[#out + 1] = ui.paint(
            screen,
            opts.roles:done_column()
                .. " is left out unless --column "
                .. opts.roles:done_column():lower(),
            ui.Style.DIM
        )
    end
    return out
end

---Refuse a card that carries `needs:human`, which waits on the owner.
---@param card dev.board.Card the card
---@return dev.cmd.board.Result? err the failure, nil when the card is free to change
local function owner_holds(card)
    if index_of(card.labels, board.NEEDS_HUMAN) then
        return failure(
            card.id:sub(1, board.MIN_PREFIX)
                .. " is labelled "
                .. board.NEEDS_HUMAN
                .. ", so it waits on the owner and only the owner moves or edits it"
        )
    end
end

local function card_line(card)
    return board.table_lines({ board.cells(card) })[1]
end

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
                    .. " characters"
            )
    end
    return name
end

local function claimant(name)
    if name then
        return name
    end
    local host = devos.capture({ "hostname", "-s" }, { stderr = "null" }):gsub("%s+$", "")
    local session = os.getenv("CLAUDE_SESSION_ID")
    if not session or session == "" then
        session = devos.capture({ "sh", "-c", "echo $PPID" }):gsub("%s+$", "")
    end
    return ("dev@" .. host .. ":" .. session:gsub("[^%w._-]", "_")):sub(1, CLAIMANT_CHARS)
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
    local flags, extra = parse(rest, { ["--column"] = true, ["--label"] = true, ["--size"] = true })
    if not flags then
        return extra
    end
    if #extra > 0 then
        return usage("unknown argument " .. extra[1])
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
    local holders, progress = false, false
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
        if shown then
            shown_cards[#shown_cards + 1] = card
            holders = holders or card.claimant ~= nil
            progress = progress or #card.outcomes > 0
        end
    end
    if #shown_cards == 0 then
        return { output = "no cards" }
    end
    if screen and screen.color then
        local lines = summary_lines(screen, shown_cards, backend.roles)
        local finished = {}
        for _, name in ipairs(backend.roles.finished) do
            finished[name] = true
        end
        lines[#lines + 1] = ""
        local body
        if grouped then
            body = terminal_grouped(screen, shown_cards, {
                holders = holders,
                shows_done = want ~= nil and finished[want],
                roles = backend.roles,
            })
        else
            body = terminal_flat(screen, shown_cards, { holders = holders, roles = backend.roles })
        end
        for _, line in ipairs(body) do
            lines[#lines + 1] = line
        end
        return { output = table.concat(lines, "\n"), page = true }
    end
    local rows = {}
    for _, card in ipairs(shown_cards) do
        rows[#rows + 1] = board.cells(card, { holders = holders, progress = progress })
    end
    return { output = table.concat(board.table_lines(rows), "\n") }
end

function commands.next(backend, args)
    local flags, words = parse(args, { ["--column"] = true })
    if not flags then
        return words
    end
    if #words > 0 then
        return usage("unknown argument " .. words[1])
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
        if not takes then
            return usage("next --column takes Ready, Backlog, Icebox or Blocked")
        end
        column = named
    end
    local card, message =
        backend:next(column, { label = column == roles.blocked and board.NEEDS_LEAD or nil })
    if not card then
        if message then
            return failure(message)
        end
        if column == roles.ready then
            return { output = "no ready cards" }
        end
        return { output = "no cards in " .. column }
    end
    return { output = card_line(card) }
end

function commands.add(backend, args)
    local flags, words = parse(args, {
        ["--column"] = true,
        ["--description"] = true,
        ["--problem"] = true,
        ["--change"] = true,
        ["--out-of-scope"] = true,
        ["--size"] = true,
        ["--label"] = true,
        ["--checks"] = true,
        ["--done-when"] = true,
        ["--board"] = true,
        ["--blocked-by"] = true,
    }, {
        ["--problem"] = true,
        ["--change"] = true,
        ["--out-of-scope"] = true,
        ["--label"] = true,
        ["--checks"] = true,
        ["--done-when"] = true,
        ["--blocked-by"] = true,
    })
    if not flags then
        return words
    end
    if #words == 0 then
        return usage("needs a card name")
    end
    if flags["--board"] then
        local home, why = backend:other_board(flags["--board"])
        if not home then
            return failure(why)
        end
        local found, message = home:find()
        if found == nil then
            return failure(message)
        end
        if not found then
            return failure("pomb has no board named " .. flags["--board"])
        end
        home.column_map = backend.column_map
        home.root = backend.root
        home.roles = board.roles(backend.column_map, home:done_columns() or {})
        backend = home
    end
    for _, flag in ipairs({ "--problem", "--out-of-scope" }) do
        if flags[flag] and #flags[flag] > 1 then
            return usage(flag .. " takes one value, so give its text once")
        end
    end
    local problem = flags["--problem"] and flags["--problem"][1]
    local out_of_scope = flags["--out-of-scope"] and flags["--out-of-scope"][1]
    local change = flags["--change"] and table.concat(flags["--change"], "\n")
    local sectioned = problem or change or out_of_scope
    if sectioned and flags["--description"] then
        return usage(
            "--description holds the whole text, so it cannot go with --problem, --change or --out-of-scope"
        )
    end
    local labels
    for _, label in ipairs(flags["--label"] or {}) do
        local ok, err = plain(label)
        if not ok then
            return err
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
    local outcomes = {}
    for _, item in ipairs(flags["--done-when"] or {}) do
        if not item:find("%S") then
            return usage("--done-when needs the outcome")
        end
        outcomes[#outcomes + 1] = item
    end
    if #outcomes > board.MAX_OUTCOMES then
        return usage("a card has at most " .. board.MAX_OUTCOMES .. " --done-when outcomes")
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
    if
        index_of(labels or {}, board.NEEDS_HUMAN)
        and column ~= roles.blocked
        and column ~= roles.icebox
    then
        return usage(
            board.NEEDS_HUMAN
                .. " lives only in Blocked or Icebox, so add the card there with --column"
        )
    end
    if column == roles.ready and unready(color) then
        return usage(
            "a card must be sized 1, 2 or 3 before it enters Ready, so add it with --size or to Backlog"
        )
    end
    local description = flags["--description"]
    if sectioned then
        description = board.compose(problem, change, out_of_scope)
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
        })
        if #missing > 0 then
            return usage(
                "a card outside "
                    .. roles.icebox
                    .. " needs a size, card format v2 and Done when outcomes, and this one lacks "
                    .. table.concat(missing, ", ")
                    .. "; pass --size, --problem and --done-when, or add it to "
                    .. roles.icebox
            )
        end
    end
    if column == roles.ready then
        local missing = board.missing(description, #outcomes)
        if #missing > 0 then
            return usage(
                "a card needs card format v2 before it enters Ready, and this one lacks "
                    .. table.concat(missing, ", ")
                    .. "; add it to Backlog or pass --problem, --change, --out-of-scope and --done-when"
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
            return usage("a card needs a checks row before it enters Ready; pass --checks CMD")
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
    local card, message = backend:add(table.concat(words, " "), column, {
        description = description,
        color = color,
        labels = labels,
        checks = checks,
        outcomes = outcomes,
    })
    if not card then
        return failure(message)
    end
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
                    .. " was not, and "
                    .. (linked - 1)
                    .. " of "
                    .. #blockers
                    .. " links were made before it: "
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
        output = "added " .. card.id:sub(1, board.MIN_PREFIX) .. " " .. card.column,
        warnings = board.prose_warnings(prose),
    }
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
        return usage("unknown argument " .. args[4])
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
        return usage("needs a card")
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

function commands.show(backend, args)
    if #args ~= 1 then
        return usage("needs a card")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local list, message = backend:comments(card.id)
    if not list then
        return failure(message)
    end
    local family
    family, message = backend:family(card.id)
    if not family then
        return failure(message)
    end
    local kin = kin_lines(family)
    local description = (card.description or ""):match("^%s*(.-)%s*$")
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
    return {
        output = card_line(card)
            .. "\n"
            .. kin
            .. "\n"
            .. description
            .. "\n\n"
            .. outcomes
            .. blocks
            .. comment_lines(list, { whole = true }),
    }
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
        return nil, usage("needs a card and the note")
    end
    local opts = {}
    if kind then
        opts.kind = kind:lower()
        if not index_of(board.NOTE_KINDS, opts.kind) then
            return nil,
                usage(
                    "unknown kind "
                        .. kind
                        .. ", the kinds are "
                        .. table.concat(board.NOTE_KINDS, ", ")
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
    if args[2] == EDIT_FLAG then
        return edit_note(backend, args)
    elseif args[2] == DELETE_FLAG then
        return delete_note(backend, args)
    end
    local words, opts = note_opts(args)
    if not words then
        return opts
    end
    local card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    local text = table.concat(words, " ", 2)
    if board.reserved(text) then
        return failure(RESERVED_NOTE)
    end
    local held = claims.read(card.id)
    local ok, message = backend:note(card.id, text, held and held.fence, opts)
    if not ok then
        return failure(message)
    end
    return {
        output = "noted " .. card.id:sub(1, board.MIN_PREFIX),
        warnings = board.prose_warnings(text),
    }
end

local function claim_card(backend, card, name)
    local held = claims.read(card.id)
    local fence, message =
        backend:claim(card.id, claimant(name), claims.TTL_SECONDS, held and held.fence)
    if not fence then
        return failure(message)
    end
    claims.stop(card.id)
    local ticks, minutes = claims.cap(card.size)
    local state = { card = card.id, fence = fence }
    local ok
    ok, message = claims.write(state)
    if not ok then
        backend:release(card.id, fence)
        return failure(message)
    end
    local pid
    pid, message = backend:keepalive(card.id, fence, ticks, claims.path(card.id))
    if not pid then
        claims.stop(card.id)
        backend:release(card.id, fence)
        return failure(message)
    end
    state.pid = pid
    ok, message = claims.write(state)
    if not ok then
        claims.stop(card.id)
        backend:release(card.id, fence)
        return failure(message)
    end
    if pid == 0 then
        return {
            output = string.format(
                "took %s, fence %d, held for %dm",
                card.id:sub(1, board.MIN_PREFIX),
                fence,
                minutes
            ),
        },
            fence
    end
    return {
        output = string.format(
            "took %s, fence %d, renewing every %dm for up to %dm",
            card.id:sub(1, board.MIN_PREFIX),
            fence,
            claims.TICK_MINUTES,
            minutes
        ),
    },
        fence
end

---Mark a refusal as one a queue must not keep.
---@param result dev.cmd.board.Result the refusal
---@return dev.cmd.board.Result result the same refusal, marked unqueued
local function unqueued(result)
    result.unqueued = true
    return result
end

---Refuse a move to Done that the card's children do not allow.
---@param card dev.board.Card the card
---@param children {done: integer, total: integer}? its children, nil when it has none
---@return dev.cmd.board.Result? err the refusal, nil when every child is Done
local function children_refusal(card, children)
    local unfinished = board.open_children(children)
    if unfinished == 0 then
        return nil
    end
    return unqueued(
        failure(
            string.format(
                "%s cannot move to Done: %d of %d children are open, and an umbrella is Done when every child is",
                card.id:sub(1, board.MIN_PREFIX),
                unfinished,
                children.total
            )
        )
    )
end

---Refuse a move to Done that the card's outcomes do not allow.
---@param card dev.board.Card the card
---@return dev.cmd.board.Result? err the refusal, nil when every outcome is ticked
local function done_refusal(card)
    local id = card.id:sub(1, board.MIN_PREFIX)
    if card.outcomes_unreadable then
        return unqueued(
            failure(
                id
                    .. " cannot move to Done: its outcomes cannot be read from Pomb, so they cannot be checked"
            )
        )
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
                "%s cannot move to Done: %d of %d outcomes are unticked (%s); the reviewer ticks them with dev board outcome CARD --tick N --as NAME, or dev board discard CARD drops it",
                id,
                #open,
                #card.outcomes,
                table.concat(open, ", ")
            )
        )
    )
end

---Move a card to a column, checking its outcomes first when the column is Done.
---@param backend dev.board.Backend the board
---@param args string[] the card and the column
---@param opts {drop: boolean?}? `drop` skips the outcome check, as a discard's move does
---@return dev.cmd.board.Result result the output, or a message and the exit code
local function move_card(backend, args, opts)
    local flags, words = parse(args, {})
    if not flags then
        return words
    end
    if #words < 2 then
        return usage("needs a card and a column")
    end
    local roles = backend.roles
    local column, err = named_column(backend, table.concat(words, " ", 2))
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
        local refused = done_refusal(card)
        if refused then
            return refused
        end
    end
    local children, children_read
    local function read_children()
        if not children_read then
            local family, why = backend:family(card.id)
            if not family then
                return to_done and unqueued(failure(why)) or failure(why)
            end
            children, children_read = family.children, true
        end
    end
    if column == roles.ready and unready(card.color) then
        local why = card.color == board.SIZES["3+"] and "is red, more than 3 Pomodori, so split it"
            or "has no size"
        return failure(
            card.id:sub(1, board.MIN_PREFIX)
                .. " "
                .. why
                .. " and cannot enter Ready; size it with dev board size CARD 1, 2 or 3"
        )
    end
    if column ~= roles.icebox and column ~= roles.ready then
        local facts = {
            color = card.color,
            description = card.description,
            outcomes = #card.outcomes,
            need_outcomes = not (opts and opts.drop) and not card.outcomes_unreadable,
            children = 0,
        }
        local missing = board.unplanned(facts)
        if #missing > 0 and facts.need_outcomes and facts.outcomes == 0 then
            facts.need_outcomes = false
            if #board.unplanned(facts) == 0 then
                local failed = read_children()
                if failed then
                    return failed
                end
                facts.need_outcomes = true
                if children then
                    facts.children = children.total
                end
                missing = board.unplanned(facts)
            end
        end
        if #missing > 0 then
            return failure(
                card.id:sub(1, board.MIN_PREFIX)
                    .. " is not planned and cannot enter "
                    .. column
                    .. "; it lacks "
                    .. table.concat(missing, ", ")
                    .. "; fix it with dev board size, edit and outcome"
            )
        end
    end
    if to_done then
        local failed = read_children()
        if failed then
            return failed
        end
        local refused = children_refusal(card, children)
        if refused then
            return refused
        end
    end
    if column == roles.ready then
        local missing = board.missing(card.description, #card.outcomes)
        if #missing > 0 then
            return failure(
                card.id:sub(1, board.MIN_PREFIX)
                    .. " is not in card format v2 and cannot enter Ready; it lacks "
                    .. table.concat(missing, ", ")
                    .. "; add outcomes with dev board outcome and fix the description with dev board edit, where a v1 Done when checklist also counts"
            )
        end
        if #card.checks == 0 then
            local why, problem = named_field_problem(backend, board.CHECKS_FIELD)
            if problem then
                return problem
            end
            return failure(
                why
                    or (
                        card.id:sub(1, board.MIN_PREFIX)
                        .. " has no checks row and cannot enter Ready; give it one with dev board checks CARD CMD"
                    )
            )
        end
    end
    if column == roles.ready then
        local family, why = backend:family(card.id)
        if not family then
            return failure(why)
        end
        if family.children and family.children.total > 0 then
            return failure(
                card.id:sub(1, board.MIN_PREFIX)
                    .. " is an umbrella with "
                    .. family.children.total
                    .. " children and never enters Ready; its children are the work"
            )
        end
    end
    local held = claims.read(card.id)
    local started
    if column == roles.progress and not held and not card.claimant then
        local name, bad = agent_name()
        if bad then
            return bad
        end
        local family, why = backend:family(card.id)
        if not family then
            return failure(why)
        end
        if not (family.children and family.children.total > 0) then
            local result, fence = claim_card(backend, card, name)
            if not fence then
                return result
            end
            started = true
            held = { fence = fence }
        end
    end
    local ok, message = backend:move(card.id, column, { fence = held and held.fence })
    if not ok then
        if started then
            claims.stop(card.id)
            backend:release(card.id, held.fence)
        end
        return to_done and unqueued(failure(message)) or failure(message)
    end
    if held and column ~= roles.progress then
        claims.stop(card.id)
        local released, why = backend:release(card.id, held.fence)
        if not released then
            stderr:write("dev: moved, but the claim was not released: ", why, "\n")
        end
    end
    return { output = "moved " .. card.id:sub(1, board.MIN_PREFIX) .. " to " .. column }
end

function commands.move(backend, args)
    return move_card(backend, args)
end

function commands.order(backend, args)
    local flags, words = parse(args, {})
    if not flags then
        return words
    end
    if #words == 0 then
        return usage("needs one or more cards")
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
            return failure(card.id:sub(1, board.MIN_PREFIX) .. " is named twice")
        end
        if column and card.column ~= column then
            return failure(
                "order takes cards of one column, but "
                    .. card.id:sub(1, board.MIN_PREFIX)
                    .. " is in "
                    .. card.column
                    .. " and "
                    .. named[1].id:sub(1, board.MIN_PREFIX)
                    .. " is in "
                    .. column
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
    local flags, words = parse(args, { ["--reason"] = true })
    if not flags then
        return words
    end
    if #words ~= 1 then
        return usage("needs a card, and an optional --reason TEXT")
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
    local missing = board.unplanned({
        color = card.color,
        description = card.description,
        outcomes = #card.outcomes,
        need_outcomes = false,
        children = 0,
    })
    if #missing > 0 then
        return failure(
            card.id:sub(1, board.MIN_PREFIX)
                .. " is not planned and cannot be discarded; it lacks "
                .. table.concat(missing, ", ")
                .. "; fix it with dev board size and edit"
        )
    end
    local steps = {}
    if reason then
        steps[#steps + 1] = { sub = "note", args = { words[1], KIND_FLAG, "decision", reason } }
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
        return usage("needs a card and a size")
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
            card.id:sub(1, board.MIN_PREFIX)
                .. " is outside "
                .. backend.roles.icebox
                .. " and keeps a size; move it to "
                .. backend.roles.icebox
                .. " first"
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
        return usage("needs a card and one or more labels to add or --remove label")
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
                card.id:sub(1, board.MIN_PREFIX)
                    .. " is in "
                    .. card.column
                    .. ", and "
                    .. board.NEEDS_HUMAN
                    .. " lives only in Blocked or Icebox; move it there first"
            )
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

local OUTCOME_SAID = {
    [OutcomeMode.RENAME] = "reworded",
    [OutcomeMode.TICK] = "ticked",
    [OutcomeMode.UNTICK] = "unticked",
}

local function outcome_number(word, count)
    local number = tonumber(word)
    if not word:match("^%d+$") or number < 1 then
        return nil, usage("outcome numbers count from 1, not " .. word)
    end
    if number > count then
        return nil,
            failure(
                "the card has "
                    .. count
                    .. (count == 1 and " outcome" or " outcomes")
                    .. ", so there is no outcome "
                    .. number
            )
    end
    return number
end

local function split_ticker(args)
    local n = #args
    if n >= 3 and args[n - 1] == AS_FLAG then
        local rest = {}
        for i = 1, n - 2 do
            rest[i] = args[i]
        end
        return rest, args[n]
    end
    return args
end

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
                .. " NAME or DEV_AGENT"
        )
    end
    if ticker == card.claimant then
        return failure(
            card.id:sub(1, board.MIN_PREFIX)
                .. " is claimed by "
                .. ticker
                .. ", so its claimant cannot tick its outcomes"
        )
    end
    return nil, ticker
end

local function convert_outcomes(backend, card, opts)
    local fence = opts.fence
    local prefix = card.id:sub(1, board.MIN_PREFIX)
    if #card.outcomes > 0 then
        return { output = "outcome " .. prefix .. " left alone: it already has outcomes" }
    end
    local items, rest = board.split_checklist(card.description)
    if not items then
        return { output = "outcome " .. prefix .. " left alone: it has no Done when checklist" }
    end
    local ticks = false
    for _, item in ipairs(items) do
        ticks = ticks or item.done
    end
    local refused = ticks and tick_refused(card, opts.flag)
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
        return failure("the outcomes were added but could not be read back to tick them")
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
    if #args >= 2 and (OUTCOME_FLAGS[args[2]] == OutcomeMode.TICK or args[2] == CONVERT_FLAG) then
        args, ticker_flag = split_ticker(args)
    end
    if #args < 2 then
        return usage(
            "needs a card and the outcome text, or --rename N TEXT, --tick N, --untick N or --convert"
        )
    end
    local mode = OUTCOME_FLAGS[args[2]]
    local text, word
    if args[2] == CONVERT_FLAG then
        if #args ~= 2 then
            return usage(CONVERT_FLAG .. " takes only the card")
        end
        local card, err = find_card(backend, args[1])
        if not card then
            return err
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
        word, text = args[3], table.concat(args, " ", 4)
    else
        if #args ~= 3 then
            return usage(args[2] .. " needs one outcome number")
        end
        word = args[3]
    end
    if text and not text:find("%S") then
        return usage("the outcome text is empty")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local ticker
    if mode == OutcomeMode.TICK then
        local refused
        refused, ticker = tick_refused(card, ticker_flag)
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
    local fields = { name = text }
    if mode ~= OutcomeMode.RENAME then
        fields = { done = mode == OutcomeMode.TICK }
    end
    ok, message = backend:set_outcome(card.id, card.outcomes[number].id, fields, fence)
    if not ok then
        return failure(message)
    end
    local result = { output = "outcome " .. prefix .. " " .. number .. " " .. OUTCOME_SAID[mode] }
    if mode == OutcomeMode.TICK and ticker then
        result.output = result.output .. " by " .. ticker
    end
    if text then
        result.warnings = board.prose_warnings(text)
    end
    return result
end

function commands.edit(backend, args)
    if #args ~= 2 then
        return usage("needs a card and the new description")
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
                card.id:sub(1, board.MIN_PREFIX)
                    .. " is outside "
                    .. backend.roles.icebox
                    .. " and keeps card format v2; that text lacks "
                    .. table.concat(missing, ", ")
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
        return usage("needs a card and the new title")
    end
    for pos = 2, #args do
        if args[pos]:sub(1, 1) == "-" then
            return usage("unknown flag " .. args[pos])
        end
    end
    local name = table.concat(args, " ", 2)
    if not name:find("%S") or #name > NAME_CHARS or not name:find(NAME_PATTERN) then
        return usage(
            "a title is one line of up to "
                .. NAME_CHARS
                .. " characters, with no quotes or backslashes"
        )
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
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
        return usage("needs a card and one or more commands to run as its checks")
    end
    for pos = 2, #args do
        if not args[pos]:find("%S") then
            return usage("a check needs a command")
        end
    end
    local runs = {}
    for pos = 2, #args do
        runs[#runs + 1] = args[pos]
    end
    local card, short = write_field(backend, args[1], board.CHECKS_FIELD, function(id, fence)
        return backend:set_checks(id, runs, fence)
    end)
    if not card then
        return short
    end
    return { output = "set checks " .. short .. ", " .. counted(#runs, "row") }
end

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

function commands.check(backend, args)
    local opts, err = check_options(args)
    if not opts then
        return err
    end
    local card
    card, err = find_card(backend, opts.words[1])
    if not card then
        return err
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    if #card.checks == 0 then
        return failure(short .. " has no checks rows; set them with dev board checks")
    end
    local argvs = {}
    for i, run in ipairs(card.checks) do
        local argv, why = check.argv(run)
        if not argv then
            return failure(short .. " checks row " .. i .. ": " .. why)
        end
        argvs[i] = argv
    end
    if not backend.root then
        return failure("dev board check needs the project's root")
    end
    local before, message = check.state(backend.root)
    if not before then
        return failure(message)
    end
    local rows = {}
    for i, argv in ipairs(argvs) do
        stderr:write(string.format("running %d of %d: %s\n", i, #argvs, card.checks[i]))
        rows[i] = check.run({
            root = backend.root,
            run = card.checks[i],
            argv = argv,
            seconds = opts.seconds,
        })
    end
    local lines = check_lines(rows)
    local after = check.state(backend.root)
    if not after or after.commit ~= before.commit then
        return failure(
            string.format(
                "the working copy changed while the checks ran (commit %s, then %s), so the result belongs to no commit and was NOT recorded on %s\n%s",
                before.commit:sub(1, COMMIT_CHARS),
                after and after.commit:sub(1, COMMIT_CHARS) or "unknown",
                short,
                table.concat(lines, "\n")
            )
        )
    end
    local held = claims.read(card.id)
    local ok
    ok, message = backend:note(
        card.id,
        check.record(before, rows, opts.expect_fail),
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
    local passed, good = check.summarize(rows, opts.expect_fail)
    local verdict = string.format(
        "recorded on %s at commit %s: %d of %s passed",
        short,
        before.commit:sub(1, COMMIT_CHARS),
        passed,
        count_text(#rows, "row")
    )
    if opts.expect_fail and passed > 0 then
        verdict = verdict
            .. "; with --expect-fail every row should fail, so the passing ones prove nothing"
    end
    lines[#lines + 1] = verdict
    if not good then
        return failure(table.concat(lines, "\n"))
    end
    return { output = table.concat(lines, "\n") }
end

function commands.review(backend, args)
    local flags, words = parse(args, { [KIND_FLAG] = true, [BY_FLAG] = true, [REV_FLAG] = true })
    if not flags then
        return words
    end
    if #words ~= 1 then
        return usage("needs a card")
    end
    for _, flag in ipairs({ KIND_FLAG, BY_FLAG, REV_FLAG }) do
        if not flags[flag] then
            return usage("needs " .. flag)
        end
    end
    local kind = flags[KIND_FLAG]
    if not index_of(review.KINDS, kind) then
        return usage(
            "unknown kind " .. kind .. ", the kinds are " .. table.concat(review.KINDS, ", ")
        )
    end
    local by, why = agent_name(flags[BY_FLAG])
    if not by then
        return why
    end
    local card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    local caller = agent_name()
    local owner = card.claimant
    if owner and (by == owner or caller == owner) then
        return failure(
            string.format(
                "%s is claimed by %s, so %s cannot review its own change",
                short,
                owner,
                owner
            )
                .. "; a reviewer other than "
                .. owner
                .. " must record it"
        )
    end
    if not backend.root then
        return failure("dev board review needs the project's root")
    end
    local rev, message = review.resolve(backend.root, flags[REV_FLAG])
    if not rev then
        return failure(message)
    end
    local held = claims.read(card.id)
    local ok
    ok, message = backend:note(
        card.id,
        review.record(kind, by, rev),
        held and held.fence,
        { kind = "status" }
    )
    if not ok then
        return failure(
            string.format(
                "the review was NOT recorded on %s (%s); the board may or may not hold it, so read dev board notes before repeating it",
                short,
                message
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

---@class dev.cmd.board.LandWho
---@field name string the caller's agent name
---@field comments {body: string}[] the card's comments, oldest first

local function land_problems(backend, card, who)
    local problems = {}
    local roles = backend.roles
    if card.column ~= roles.review then
        problems[#problems + 1] = "it is in "
            .. card.column
            .. ", and only a card in "
            .. roles.review
            .. " lands"
    end
    if card.claimant and card.claimant ~= who.name then
        problems[#problems + 1] = "it is claimed by "
            .. card.claimant
            .. ", and only that claimant lands it, not "
            .. who.name
    end
    local open = done_refusal(card)
    if open then
        problems[#problems + 1] = open.message
    end
    local state, message = land.state(backend.root)
    if not state then
        problems[#problems + 1] = message
        return problems
    end
    local lacking = land.missing_reviews(who.comments, state)
    local unproven = land.checks_problem(who.comments, state, card.checks)
    local carried
    if #lacking > 0 and #problems == 0 then
        local why
        carried, why = land.carry({
            root = backend.root,
            comments = who.comments,
            state = state,
            rows = card.checks,
        })
        if carried then
            lacking, unproven = {}, nil
        elseif why then
            problems[#problems + 1] = why
        end
    end
    for _, missing in ipairs(lacking) do
        problems[#problems + 1] = missing
    end
    if unproven then
        problems[#problems + 1] = unproven
    end
    if #problems == 0 then
        local moved = land.trunk_problem(backend.root)
        if moved then
            problems[#problems + 1] = moved
        end
    end
    return problems, state, carried
end

function commands.land(backend, args)
    if #args ~= 1 then
        return usage("needs a card")
    end
    local name, why = agent_name()
    if why then
        return why
    end
    if not name then
        return usage("needs DEV_AGENT, the name that lands the card")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local short = card.id:sub(1, board.MIN_PREFIX)
    local held_back = owner_holds(card)
    if held_back then
        return held_back
    end
    if not backend.root then
        return failure("dev board land needs the project's root")
    end
    if vcs.backend(backend.root) ~= vcs.JJ then
        return failure(
            short
                .. " cannot land: dev board land needs a jj project, and does not land in plain git"
        )
    end
    local list, message = backend:comments(card.id)
    if not list then
        return failure(message)
    end
    local problems, state, carried = land_problems(backend, card, { name = name, comments = list })
    if #problems > 0 then
        return failure(short .. " cannot land:\n  - " .. table.concat(problems, "\n  - "))
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
            "%s The check and reviews were carried over from commit %s: the change id is the same, the interdiff is empty, and the trunk commits since touch none of its files.",
            text,
            land.short(carried)
        )
    end
    local noted
    noted, message = backend:note(card.id, text, held and held.fence, { kind = "done" })
    if not noted then
        return failure(
            string.format(
                "landed commit %s, but the done note was NOT written on %s (%s) and the card was not moved; write the note and move it to Done by hand",
                commit,
                short,
                message
            )
        )
    end
    local moved = move_card(backend, { card.id, backend.roles:done_column() })
    if moved.code then
        return failure(
            string.format(
                "landed commit %s and noted it on %s, but the move to Done failed: %s",
                commit,
                short,
                moved.message
            )
        )
    end
    return {
        output = string.format(
            "landed %s at commit %s%s and moved it to Done",
            short,
            commit,
            on_trunk and ""
                or " (the commit from before the land, which may differ: trunk could not be read)"
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
                "needs a card and one or more of "
                    .. table.concat(board.ALLOW_WORDS, ", ")
                    .. " or "
                    .. board.ALLOW_NONE
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
                    "unknown allow word "
                        .. word
                        .. ", the words are "
                        .. table.concat(board.ALLOW_WORDS, ", ")
                        .. " and "
                        .. board.ALLOW_NONE
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
        return usage("needs a card and one or more " .. noun .. " names")
    end
    for pos = 2, #args do
        if not args[pos]:find("%S") or args[pos]:find("%c") then
            return usage("a " .. noun .. " name must be one line of text")
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
        return nil, nil, nil, usage("needs a card, a kind (" .. LINK_HELP .. ") and the other card")
    end
    if not index_of(board.LINK_KINDS, args[2]) then
        return nil,
            nil,
            nil,
            usage("unknown link kind " .. args[2] .. ", the kinds are " .. LINK_HELP)
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
    local ok, message = backend:link(card.id, args[2], other.id)
    if not ok then
        return failure(message)
    end
    return {
        output = "linked " .. card.id:sub(1, board.MIN_PREFIX) .. " " .. args[2] .. " " .. shown,
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
    local held = #list == 0 and "it holds no links" or "its links are\n" .. link_rows(list)
    return failure("the card holds no " .. args[2] .. " link to " .. shown .. ", " .. held)
end

function commands.links(backend, args)
    if #args ~= 1 then
        return usage("needs a card")
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
        return { output = "no links" }
    end
    return { output = link_rows(list) }
end

local function append(lines, more)
    for _, line in ipairs(more) do
        lines[#lines + 1] = line
    end
end

---Check whether the newest comment on a needs:human card is the owner's.
---@param backend dev.board.Backend the board
---@param card dev.board.Card the card
---@return boolean? answered whether the newest comment is the owner's, nil when they could not be read
---@return string? why the reason the comments could not be read
local function answered_by_human(backend, card)
    local list = backend:comments(card.id)
    if not list then
        return nil, "could not read the comments of " .. card.id .. " " .. card.name
    end
    local newest = list[#list]
    return newest ~= nil and newest.actor == HUMAN_ACTOR
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

function commands.stale(backend, args, now)
    local flags, extra =
        parse(args, { ["--days"] = true, ["--icebox-days"] = true, ["--lead-hours"] = true })
    if not flags then
        return extra
    end
    if #extra > 0 then
        return usage("unknown argument " .. extra[1])
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
    lead_limit, refusal =
        whole_limit("--lead-hours", flags["--lead-hours"], { default = LEAD_HOURS, unit = "hours" })
    if not lead_limit then
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
    now = now or os.time()
    local roles = backend.roles
    local found, owner, moved, undated, unsized, lead = {}, {}, {}, {}, {}, {}
    for _, card in ipairs(cards) do
        if
            card.column == roles.blocked
            and not card.done
            and index_of(card.labels, board.NEEDS_LEAD)
            and not index_of(card.labels, board.NEEDS_HUMAN)
        then
            local at = entered[card.id] and box.parse_time(entered[card.id])
            if not at then
                undated[#undated + 1] = "could not date " .. card.id .. " " .. card.name
            else
                local hours = math.floor((now - at) / box.SECONDS_PER_HOUR)
                if hours >= lead_limit then
                    lead[#lead + 1] = {
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
        if card.column ~= roles.icebox and board.has_color(card, board.SIZES.unsized) then
            unsized[#unsized + 1] = card
        end
        local mine = index_of(card.labels, board.NEEDS_HUMAN) ~= nil
        local held = mine and (card.column == roles.blocked or card.column == roles.icebox)
        if not card.done and (mine or roles.stale[card.column]) then
            local stamp = entered[card.id]
            if not stamp then
                undated[#undated + 1] = "could not date " .. card.id .. " " .. card.name
            else
                local at = box.parse_time(stamp)
                if not at then
                    return failure("pomb sent a column time dev cannot read for " .. card.id)
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
                        local answered, why = answered_by_human(backend, card)
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
    local lines = {}
    if #found == 0 then
        lines[1] = "no stale cards"
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
    if #moved > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "moved by the owner, remove " .. board.NEEDS_HUMAN .. ":"
        append(lines, stale_rows(moved))
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
    if #undated > 0 then
        lines[#lines + 1] = ""
        append(lines, undated)
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
    local strict = false
    for _, arg in ipairs(args) do
        if arg ~= STRICT_FLAG then
            return usage("takes only " .. STRICT_FLAG .. ", got " .. arg)
        end
        strict = true
    end
    local cards, message = backend:cards()
    if not cards then
        return failure(message)
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
                return family.children or { done = 0, total = 0 }
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
        return { output = "no findings" }
    end
    return {
        output = table.concat(board.table_lines(rows), "\n"),
        code = fixable and FAILURE or nil,
    }
end

function commands.take(backend, args)
    local flags, words = parse(args, { [AS_FLAG] = true })
    if not flags then
        return words
    end
    if #words ~= 1 then
        return usage("needs a card")
    end
    local name, why = agent_name(flags[AS_FLAG])
    if why then
        return why
    end
    local card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    return (claim_card(backend, card, name))
end

function commands.release(backend, args)
    if #args ~= 1 then
        return usage("needs a card")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local held = claims.read(card.id)
    if not held then
        return failure("no claim was taken for " .. args[1] .. " with dev board take")
    end
    local ok, message = backend:release(card.id, held.fence)
    if not ok then
        return failure(message)
    end
    claims.stop(card.id)
    return { output = "released " .. card.id:sub(1, board.MIN_PREFIX) }
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
                "the orders are %d words and a run card holds at most %d; keep the rest in a file and name it in the orders",
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
        "The orders below are carried out",
        "--done-when",
        "Every card the run took is Done or released",
        "--done-when",
        "Anything left over is a card on the board",
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
        taken.message = taken.message .. "; dev board run claims the new run card again"
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
    local upcoming, message = backend:next(backend.roles.ready)
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
    local RUN_USAGE = "start one with dev board run --orders TEXT"
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
        return usage("unknown argument " .. words[1])
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
        return usage("run needs DEV_AGENT or CLAUDE_SESSION_ID, so the session keeps one name")
    end
    name = claimant(name)
    if #RUN_NAME + #name > NAME_CHARS then
        return usage("the session name is too long for a card name")
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
                    .. "; close it with dev board run "
                    .. RUN_END_FLAG
                    .. " first"
            )
        end
        return start_run(backend, name, flags[RUN_ORDERS_FLAG])
    end
    if not run then
        return failure("no open run card for " .. name .. "; " .. RUN_USAGE)
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
---@param sub string `ls`, `next`, `add`, `note`, `notes`, `show`, `move`, `order`, `discard`, `size`, `label`, `edit`, `checks`, `allow`, `tests`, `files`, `outcome`, `link`, `links`, `unlink`, `stale`, `lint`, `take` or `release`
---@param args string[] the arguments after the subcommand
---@param backend dev.board.Backend the board
---@param now integer? the time in seconds since the epoch that `stale` counts from, the clock when nil
---@param screen dev.ui.Context? the terminal `ls` draws for, left nil for the plain lines
---@return dev.cmd.board.Result result the output, or a message and the exit code
function M.run(sub, args, backend, now, screen)
    local finished = backend:done_columns() or {}
    backend.roles = board.roles(backend.column_map, finished)
    local run = commands[sub] or internal[sub]
    return run(backend, args, now, screen)
end

local function open_backend(settings)
    if settings.backend == board.Backend.LOCAL then
        if settings.path then
            return localboard.new({ name = settings.name, path = settings.path })
        end
        if not settings.name:find(LOCAL_NAME_PATTERN) or #settings.name > NAME_CHARS then
            return nil,
                "dev: a local board's name must be letters, digits, dots, dashes and underscores to name its file, or set [board] path"
        end
        return localboard.new({
            name = settings.name,
            path = store.dir() .. "/" .. settings.name .. ".json",
            private = true,
        })
    end
    local backend, message = pomb.new({
        url = config.user("board.pomb.url"),
        token = config.user("board.pomb.token"),
        name = settings.name,
    })
    if not backend then
        return nil, "dev: " .. message
    end
    return backend
end

---Build the backend a project's board uses.
---@param settings dev.cmd.board.Settings the board's backend and name
---@return dev.board.Backend? backend the backend
---@return string? message why there is none
function M.open(settings)
    local backend, message = open_backend(settings)
    if backend then
        backend.column_map = settings.columns
        backend.roles = board.roles(settings.columns)
        backend.root = settings.root
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
        verb.die('dev: [board] backend must be "pomb" or "local" in .dev/config.toml')
    end
    local name = config.get(ctx.root, "board.name")
    if name == nil then
        name = fs.basename(ctx.root)
    end
    if type(name) ~= "string" or name == "" then
        verb.die("dev: [board] name must be a non-empty string in .dev/config.toml")
    end
    local path = config.get(ctx.root, "board.path")
    if path ~= nil then
        if backend ~= board.Backend.LOCAL then
            verb.die('dev: [board] path only applies to backend = "local"')
        end
        if
            type(path) ~= "string"
            or not path:find(PATH_PATTERN)
            or path:find("..", 1, true)
            or path:find("//", 1, true)
        then
            verb.die(
                "dev: [board] path must be a relative path inside the project, such as .dev/board.json"
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

local function has_section(root)
    local text = fs.exists(root .. "/.dev/config.toml") and fs.read(root .. "/.dev/config.toml")
    local tree = text and toml.parse(text)
    return type(tree) == "table" and tree.board ~= nil
end

local function board_name(ctx, flags)
    local backend = config.get(ctx.root, "board.backend")
    local name = config.get(ctx.root, "board.name")
    if backend == nil and has_section(ctx.root) then
        verb.die('dev: [board] needs backend = "pomb" in .dev/config.toml')
    end
    if backend ~= nil and backend ~= board.Backend.POMB then
        verb.die('dev: [board] backend must be "pomb" or "local" in .dev/config.toml')
    end
    local asked = flags["--name"]
    if backend == nil then
        if not asked then
            verb.die(
                "dev: this project has no [board] section, pass --name N to make a board and write it"
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
        verb.die("dev: the board's name must be 1 to 100 characters with no quote or backslash")
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
        verb.die("dev: cannot write " .. path .. ": " .. tostring(message))
    end
end

local function host()
    return (devos.capture({ "hostname", "-s" }, { stderr = "null" }):gsub("%s+$", ""))
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
    changes, message = init.run(backend, found.name, print, backend.roles)
    if not changes then
        verb.die("dev: " .. message)
    end
    print(
        changes == 0
                and ("board " .. found.name .. " already follows the standard, nothing to change")
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
    }
    if not admin and opts.token == nil then
        verb.die(
            "dev: [board.pomb] lead_token is not set in ~/.config/dev/config.toml, "
                .. "set it to pass:<entry> or run with --admin"
        )
    end
    local backend, message = pomb.new(opts)
    if not backend then
        verb.die("dev: " .. message)
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
            verb.die("dev: " .. message)
        end
        backend:authorize(secret)
        local ok
        ok, message = backend:admin()
        if not ok then
            verb.die("dev: " .. message)
        end
    end
    local changes
    changes, message = init.run(backend, name, print, backend.roles)
    if not changes then
        verb.die("dev: " .. message)
    end
    if missing then
        write_section(ctx.root, name)
        print("wrote [board] to .dev/config.toml")
    end
    print(
        changes == 0 and ("board " .. name .. " already follows the standard, nothing to change")
            or ("board " .. name .. ": " .. changes .. (changes == 1 and " change" or " changes"))
    )
    return 0
end

local function description_args(args)
    local flags, words = parse(args, { ["--file"] = true })
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
    elseif devos.isatty(0) then
        return nil, "needs the description from --file PATH or standard input"
    else
        text = io.read("*a")
    end
    text = text:gsub("%s+$", "")
    if text == "" then
        return nil, "the new description is empty"
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
    stderr:write(line, "\n")
end

local function stderr_news(line)
    if not line:find("^Pomb is still unreachable") then
        stderr_line(line)
    end
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
            stderr_line("dev: " .. why .. "; the queue is left in place")
        elseif waiting > 0 then
            replay(backend, pending, stderr_news)
        end
    end
    return backend, pending
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
            stderr_line("dev: " .. why .. "; the queue is left in place")
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

local WaitFor = { READY = "ready", HUMAN = "human", LEAD = "lead" }
local EventKind = {
    ADDED = "task_added",
    MOVED = "task_moved",
    UPDATED = "task_updated",
    COMMENTED = "comment_added",
}
local WAIT_KINDS = { EventKind.ADDED, EventKind.MOVED, EventKind.UPDATED, EventKind.COMMENTED }
local WAIT_FOR_KINDS = {
    [WaitFor.READY] = { EventKind.ADDED, EventKind.MOVED },
    [WaitFor.HUMAN] = { EventKind.MOVED },
    [WaitFor.LEAD] = { EventKind.ADDED, EventKind.MOVED, EventKind.UPDATED },
}
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

local function entropy()
    local file = assert(io.open("/dev/urandom", "rb"))
    local bytes = file:read(4)
    file:close()
    local n = 0
    for i = 1, 4 do
        n = n * 256 + bytes:byte(i)
    end
    return n / 4294967296
end

local function lead_cards(backend, roles)
    local cards, message = backend:cards()
    if not cards then
        return nil, message
    end
    local waiting = {}
    for _, card in ipairs(cards) do
        if
            card.column == roles.blocked
            and not card.claimant
            and index_of(card.labels, board.NEEDS_LEAD)
            and not index_of(card.labels, board.NEEDS_HUMAN)
        then
            waiting[card.id] = true
        end
    end
    return waiting
end

local function wait_line(event, opts)
    local only, roles, leads = opts.only, opts.roles, opts.leads
    local id = event.task_id:sub(1, board.MIN_PREFIX)
    local added = event.kind == EventKind.ADDED
    if only == WaitFor.LEAD then
        if leads[event.task_id] then
            leads[event.task_id] = nil
            return id .. " is labelled " .. board.NEEDS_LEAD .. " in " .. roles.blocked
        end
    elseif only == WaitFor.HUMAN then
        if event.kind == EventKind.MOVED and event.from_column == roles.blocked then
            return "moved " .. id .. " out of " .. roles.blocked
        end
    elseif only == WaitFor.READY then
        if event.column == roles.ready and (added or event.kind == EventKind.MOVED) then
            return (added and "added " or "moved ") .. id .. " to " .. roles.ready
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

---@class dev.cmd.board.WaitOpts
---@field stem string the path the cursor files start with, one per `--for` mode
---@field nap fun(seconds: number)? sleeps between retries, `dev.os.nap` when nil
---@field random (fun(): number)? a number in [0, 1) that spreads the pause, entropy from the system when nil
---@field notice fun(line: string)? prints the one line about too many open waits, standard error when nil

---Hold until the board changes in a way the caller asked for.
---
---The cursor is saved after every reply, so a restart misses nothing. A Pomb
---that cannot be asked is retried and fails once ten tries in a row run out. A
---refusal for too many open waits on the token is never a failure: the wait
---is reported once and retried with a pause that doubles from 30 seconds to
---5 minutes, spread by a random fraction so sessions do not retry together.
---A cursor Pomb no longer holds is replaced and reported as a notice, not an
---error.
---@param backend dev.board.Backend the Pomb board
---@param args string[] the arguments after `wait`
---@param opts dev.cmd.board.WaitOpts where the cursor lives and how to sleep
---@return dev.cmd.board.Result result the lines for the matching events, or a message and the exit code
function M.wait(backend, args, opts)
    local flags, words = parse(args, { ["--for"] = true })
    if not flags then
        return words
    end
    if #words > 0 then
        return usage("takes no card")
    end
    local only = flags["--for"]
    if only and not WAIT_FOR_KINDS[only] then
        return usage("unknown --for " .. only .. ", the choices are ready, human and lead")
    end
    local roles = backend.roles or board.roles()
    local nap = opts.nap or devos.nap
    local random = opts.random or entropy
    local notice = opts.notice or stderr_line
    local limited = 0
    local told = false
    local path = opts.stem .. "." .. (only or "all") .. ".cursor"
    local cursor = read_cursor(path)
    local failures = 0
    while true do
        local reply, message, oldest, refused =
            backend:wait(cursor, WAIT_FOR_KINDS[only] or WAIT_KINDS)
        if reply then
            failures = 0
            limited = 0
            if type(reply.cursor) ~= "string" then
                return failure("pomb answered without a cursor")
            end
            local leads
            if only == WaitFor.LEAD and #reply.events > 0 then
                local why
                leads, why = lead_cards(backend, roles)
                if not leads then
                    return failure(why)
                end
            end
            local saved, why = store.write(path, reply.cursor .. "\n", { private = true })
            if not saved then
                return failure(why)
            end
            cursor = reply.cursor
            local lines = {}
            for _, event in ipairs(reply.events) do
                lines[#lines + 1] = type(event.task_id) == "string"
                        and wait_line(event, { only = only, roles = roles, leads = leads })
                    or nil
            end
            if #lines > 0 then
                return { output = table.concat(lines, "\n") }
            end
        elseif oldest then
            local saved, why = store.write(path, oldest .. "\n", { private = true })
            if not saved then
                return failure(why)
            end
            return { output = WAIT_TRIMMED }
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
                return failure(message)
            end
            nap(WAIT_RETRY_SECONDS)
        else
            return failure(message)
        end
    end
end

M.handlers["board wait"] = function(ctx)
    local found = settings(ctx)
    if found.backend ~= board.Backend.POMB then
        verb.die("dev: a local board has nothing to wait on")
    end
    local backend = open_board(ctx)
    local result = M.wait(backend, ctx.args, { stem = cursor_path(found.name) })
    if result.message then
        if result.code == USAGE then
            verb.usage_error(ctx, result.message)
        end
        verb.die("dev: " .. result.message)
    end
    print(result.output)
    return 0
end

M.handlers["board sync"] = function(ctx)
    verb.no_args(ctx)
    local found = settings(ctx)
    if found.backend ~= board.Backend.POMB then
        verb.die("dev: a local board has nothing to sync")
    end
    local pending = queue.new(found.name)
    local waiting, message = pending:count()
    if not waiting then
        verb.die("dev: " .. message .. "; the queue is left in place")
    end
    if waiting == 0 then
        print("nothing queued")
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
        verb.die("dev: " .. message)
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
    local out, code = devos.capture(
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
            "dev: this project has no board and is public or not known to be private, so ask the owner before it gets one; dev board init --name N makes it"
        )
    end
    local name = fs.basename(ctx.root)
    print("this project is private and has no board, making " .. name)
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
        if sub == "outcome" then
            args = with_env_ticker(args)
        end
        if sub == "lint" then
            local strict = config.get(ctx.root, "board.lint.strict")
            if strict ~= nil and type(strict) ~= "boolean" then
                verb.die("dev: [board.lint] strict must be true or false in the config")
            end
            if strict and not index_of(args, STRICT_FLAG) then
                args = { unpack(args) }
                table.insert(args, 1, STRICT_FLAG)
            end
        end
        local backend, pending = open_board(ctx)
        local result = M.run(sub, args, backend, nil, sub == "ls" and ui.context() or nil)
        if result.message then
            local note = sub == "note" and (ctx.args[2] == EDIT_FLAG or ctx.args[2] == DELETE_FLAG)
            local queued = result.queue
            if
                not queued
                and QUEUE_RULES[sub]
                and not result.unqueued
                and not note
                and not (sub == "outcome" and args[2] == CONVERT_FLAG)
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
                                .. result.message
                                .. "; and the change could not be queued: "
                                .. why
                        )
                    end
                end
                print(QUEUED_NOTICE)
                return 0
            end
            if result.code == USAGE then
                verb.usage_error(ctx, result.message)
            end
            verb.die("dev: " .. result.message)
        end
        for _, line in ipairs(result.warnings or {}) do
            stderr_line("warning: " .. line)
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
