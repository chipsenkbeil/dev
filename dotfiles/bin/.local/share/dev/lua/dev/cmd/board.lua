local board = require("dev.board")
local box = require("dev.cmd.box")
local claims = require("dev.board.claims")
local config = require("dev.config")
local device = require("dev.board.device")
local devos = require("dev.os")
local fs = require("dev.fs")
local init = require("dev.board.init")
local localboard = require("dev.board.localboard")
local pomb = require("dev.board.pomb")
local queue = require("dev.board.queue")
local store = require("dev.board.store")
local toml = require("dev.toml")
local verb = require("dev.verb")

local stderr = io.stderr
local NO_BOARD = "dev: no board for this project"
local USAGE = 2
local FAILURE = 1
local CLAIMANT_CHARS = 200
local NAME_PATTERN = '^[^%c"\\]+$'
local NAME_CHARS = 100
local ADMIN_SCOPE = "admin"
local CLIENT_CHARS = 80
local STALE_DAYS = 7
local STAMP_CHARS = 16
local LINK_HELP = table.concat(board.LINK_KINDS, ", ")
local EDIT_FLAG = "--edit"
local DELETE_FLAG = "--delete"
local LOCAL_NAME_PATTERN = "^[%w][%w._-]*$"
local PATH_PATTERN = "^[%w._][%w._/-]*$"
local QUEUED_NOTICE = "queued: Pomb unreachable, will sync"
local IDEMPOTENT = { move = true, size = true, label = true, link = true }
local QUEUED = { add = true, move = true, note = true, size = true, label = true, link = true }

---@class dev.cmd.board.Settings
---@field backend string `pomb` or `local`
---@field name string the board's name
---@field path string? the file of a local board, in the state directory when nil
---@field root string? the project's root, which a tracked path is under

---@class dev.cmd.board.Result
---@field output string? what to print on success
---@field message string? what went wrong
---@field code integer? 2 for a usage error, 1 otherwise

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

local function named_column(word)
    local column = board.column(word)
    if not column then
        return nil, usage("unknown column " .. word .. ", the columns are " .. board.column_help())
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

local function card_line(card)
    return board.table_lines({ board.cells(card) })[1]
end

local function claimant()
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

local commands = {}

function commands.ls(backend, args)
    local flags, extra = parse(args, { ["--column"] = true, ["--label"] = true, ["--size"] = true })
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
        local column, err = named_column(flags["--column"])
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
    local holders = false
    for _, card in ipairs(cards) do
        local shown = card.column == want or (not want and card.column ~= board.DONE)
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
        end
    end
    local rows = {}
    for _, card in ipairs(shown_cards) do
        rows[#rows + 1] = board.cells(card, holders)
    end
    if #rows == 0 then
        return { output = "no cards" }
    end
    return { output = table.concat(board.table_lines(rows), "\n") }
end

function commands.next(backend, args)
    if #args > 0 then
        return usage("unknown argument " .. args[1])
    end
    local card, message = backend:next()
    if not card then
        if message then
            return failure(message)
        end
        return { output = "no ready cards" }
    end
    return { output = card_line(card) }
end

function commands.add(backend, args)
    local flags, words = parse(
        args,
        { ["--column"] = true, ["--description"] = true, ["--size"] = true, ["--label"] = true },
        { ["--label"] = true }
    )
    if not flags then
        return words
    end
    if #words == 0 then
        return usage("needs a card name")
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
    local color
    if flags["--size"] then
        local named, err = sized(flags["--size"])
        if not named then
            return err
        end
        color = named
    end
    local column = board.DEFAULT_COLUMN
    if flags["--column"] then
        local named, err = named_column(flags["--column"])
        if not named then
            return err
        end
        column = named
    end
    if column == board.READY and unready(color) then
        return usage(
            "a card must be sized 1, 2 or 3 before it enters Ready, so add it with --size or to Backlog"
        )
    end
    local card, message = backend:add(
        table.concat(words, " "),
        column,
        { description = flags["--description"], color = color, labels = labels }
    )
    if not card then
        return failure(message)
    end
    return { output = "added " .. card.id:sub(1, board.MIN_PREFIX) .. " " .. card.column }
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
    local ok, message = backend:edit_note(card.id, comment.id, table.concat(args, " ", 4))
    if not ok then
        return failure(message)
    end
    return changed("edited", card, comment)
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
    local ok, message = backend:delete_note(card.id, comment.id)
    if not ok then
        return failure(message)
    end
    return changed("deleted", card, comment)
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
    if #list == 0 then
        return { output = "no comments" }
    end
    local rows = {}
    for _, comment in ipairs(list) do
        rows[#rows + 1] = {
            comment.id:sub(1, board.MIN_PREFIX),
            comment.who,
            comment.at:sub(1, STAMP_CHARS):gsub("T", " "),
            comment.body:match("^[^\r\n]*"),
        }
    end
    return { output = table.concat(board.table_lines(rows), "\n") }
end

function commands.note(backend, args)
    if args[2] == EDIT_FLAG then
        return edit_note(backend, args)
    elseif args[2] == DELETE_FLAG then
        return delete_note(backend, args)
    end
    if #args < 2 then
        return usage("needs a card and the note")
    end
    local words = args
    local card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    local held = claims.read(card.id)
    local ok, message = backend:note(card.id, table.concat(words, " ", 2), held and held.fence)
    if not ok then
        return failure(message)
    end
    return { output = "noted " .. card.id:sub(1, board.MIN_PREFIX) }
end

function commands.move(backend, args)
    local flags, words = parse(args, {})
    if not flags then
        return words
    end
    if #words < 2 then
        return usage("needs a card and a column")
    end
    local column, err = named_column(table.concat(words, " ", 2))
    if not column then
        return err
    end
    local card
    card, err = find_card(backend, words[1])
    if not card then
        return err
    end
    if column == board.READY and unready(card.color) then
        local why = card.color == board.SIZES["3+"] and "is red, more than 3 Pomodori, so split it"
            or "has no size"
        return failure(
            card.id:sub(1, board.MIN_PREFIX)
                .. " "
                .. why
                .. " and cannot enter Ready; size it with dev board size CARD 1, 2 or 3"
        )
    end
    local held = claims.read(card.id)
    local ok, message = backend:move(card.id, column, held and held.fence)
    if not ok then
        return failure(message)
    end
    if held and column ~= board.WORKING then
        claims.stop(card.id)
    end
    return { output = "moved " .. card.id:sub(1, board.MIN_PREFIX) .. " to " .. column }
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

function commands.link(backend, args)
    if #args ~= 3 then
        return usage("needs a card, a kind (" .. LINK_HELP .. ") and the other card")
    end
    if not index_of(board.LINK_KINDS, args[2]) then
        return usage("unknown link kind " .. args[2] .. ", the kinds are " .. LINK_HELP)
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local word = args[3]
    local other_name, prefix = word:match("^(.+):([^:]*)$")
    local home = backend
    if other_name then
        local why
        home, why = backend:other_board(other_name)
        if not home then
            return failure(why)
        end
        word = prefix
    end
    local other
    other, err = find_card(home, word)
    if not other then
        return err
    end
    local ok, message = backend:link(card.id, args[2], other.id)
    if not ok then
        return failure(message)
    end
    return {
        output = "linked "
            .. card.id:sub(1, board.MIN_PREFIX)
            .. " "
            .. args[2]
            .. " "
            .. (other_name and other_name .. ":" or "")
            .. other.id:sub(1, board.MIN_PREFIX),
    }
end

local function append(lines, more)
    for _, line in ipairs(more) do
        lines[#lines + 1] = line
    end
end

local function stale_rows(cards)
    local rows = {}
    for _, card in ipairs(cards) do
        rows[#rows + 1] = {
            card.id:sub(1, board.MIN_PREFIX),
            card.column,
            card.days .. "d",
            card.size,
            card.name,
        }
    end
    return board.table_lines(rows)
end

function commands.stale(backend, args, now)
    local flags, extra = parse(args, { ["--days"] = true })
    if not flags then
        return extra
    end
    if #extra > 0 then
        return usage("unknown argument " .. extra[1])
    end
    local limit = STALE_DAYS
    if flags["--days"] then
        limit = flags["--days"]:find("^%d+$") and tonumber(flags["--days"])
        if not limit or limit < 1 then
            return usage("--days needs a whole number of days, 1 or more: " .. flags["--days"])
        end
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
    local found, owner, undated, unsized = {}, {}, {}, {}
    for _, card in ipairs(cards) do
        if card.column == board.DEFAULT_COLUMN and board.has_color(card, board.SIZES.unsized) then
            unsized[#unsized + 1] = card
        end
        local mine = index_of(card.labels, board.NEEDS_HUMAN) ~= nil
        if card.column ~= board.DONE and (mine or board.STALE_COLUMNS[card.column]) then
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
                    local into = mine and owner or found
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
    if #unsized > 0 then
        local rows = {}
        for _, card in ipairs(unsized) do
            rows[#rows + 1] = { card.id:sub(1, board.MIN_PREFIX), card.column, card.name }
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "unsized in " .. board.DEFAULT_COLUMN .. ":"
        append(lines, board.table_lines(rows))
    end
    if #undated > 0 then
        lines[#lines + 1] = ""
        append(lines, undated)
    end
    return { output = table.concat(lines, "\n") }
end

function commands.take(backend, args)
    if #args ~= 1 then
        return usage("needs a card")
    end
    local card, err = find_card(backend, args[1])
    if not card then
        return err
    end
    local held = claims.read(card.id)
    local fence, message =
        backend:claim(card.id, claimant(), claims.TTL_SECONDS, held and held.fence)
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
        }
    end
    return {
        output = string.format(
            "took %s, fence %d, renewing every %dm for up to %dm",
            card.id:sub(1, board.MIN_PREFIX),
            fence,
            claims.TICK_MINUTES,
            minutes
        ),
    }
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

---Run one board subcommand against a backend.
---@param sub string `ls`, `next`, `add`, `note`, `notes`, `move`, `size`, `label`, `stale`, `take` or `release`
---@param args string[] the arguments after the subcommand
---@param backend dev.board.Backend the board
---@param now integer? the time in seconds since the epoch that `stale` counts from, the clock when nil
---@return dev.cmd.board.Result result the output, or a message and the exit code
function M.run(sub, args, backend, now)
    return commands[sub](backend, args, now)
end

---Build the backend a project's board uses.
---@param settings dev.cmd.board.Settings the board's backend and name
---@return dev.board.Backend? backend the backend
---@return string? message why there is none
function M.open(settings)
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
    return { backend = backend, name = name, path = path, root = ctx.root }
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
    changes, message = init.run(backend, found.name, print)
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
    changes, message = init.run(backend, name, print)
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
        if not QUEUED[entry.sub] or type(entry.args) ~= "table" then
            say("dropped " .. tostring(entry.sub) .. ": not a change dev queues")
            return queue.Replay.DONE
        end
        local result = M.run(entry.sub, entry.args, backend)
        if not result.message then
            say("synced " .. brief(entry))
            return queue.Replay.DONE
        elseif pomb.unreachable(result.message, IDEMPOTENT[entry.sub]) then
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

for sub in pairs(commands) do
    M.handlers["board " .. sub] = function(ctx)
        local backend, pending = open_board(ctx)
        local result = M.run(sub, ctx.args, backend)
        if result.message then
            local note = sub == "note" and (ctx.args[2] == EDIT_FLAG or ctx.args[2] == DELETE_FLAG)
            if
                pending
                and QUEUED[sub]
                and not note
                and pomb.unreachable(result.message, IDEMPOTENT[sub])
            then
                local ok, why = pending:push(sub, ctx.args)
                if not ok then
                    verb.die(
                        "dev: " .. result.message .. "; and the change could not be queued: " .. why
                    )
                end
                print(QUEUED_NOTICE)
                return 0
            end
            if result.code == USAGE then
                verb.usage_error(ctx, result.message)
            end
            verb.die("dev: " .. result.message)
        end
        print(result.output)
        return 0
    end
end

return M
