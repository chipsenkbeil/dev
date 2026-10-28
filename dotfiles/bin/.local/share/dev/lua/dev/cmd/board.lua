local board = require("dev.board")
local claims = require("dev.board.claims")
local config = require("dev.config")
local device = require("dev.board.device")
local devos = require("dev.os")
local fs = require("dev.fs")
local init = require("dev.board.init")
local pomb = require("dev.board.pomb")
local toml = require("dev.toml")
local verb = require("dev.verb")

local NO_BOARD = "dev: no board for this project"
local USAGE = 2
local FAILURE = 1
local CLAIMANT_CHARS = 200
local NAME_PATTERN = '^[^%c"\\]+$'
local NAME_CHARS = 100
local ADMIN_SCOPE = "admin"
local CLIENT_CHARS = 80

---@class dev.cmd.board.Settings
---@field backend string `pomb` or `local`
---@field name string the board's name

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

local function parse(args, takes)
    local flags, positional = {}, {}
    local i = 1
    while i <= #args do
        local arg = args[i]
        i = i + 1
        if takes[arg] then
            if i > #args then
                return nil, usage(arg .. " needs a value")
            end
            flags[arg] = args[i]
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
    local flags, extra = parse(args, { ["--column"] = true, ["--label"] = true })
    if not flags then
        return extra
    end
    if #extra > 0 then
        return usage("unknown argument " .. extra[1])
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
    local flags, words = parse(args, { ["--column"] = true, ["--description"] = true })
    if not flags then
        return words
    end
    if #words == 0 then
        return usage("needs a card name")
    end
    local column = board.DEFAULT_COLUMN
    if flags["--column"] then
        local named, err = named_column(flags["--column"])
        if not named then
            return err
        end
        column = named
    end
    local card, message = backend:add(table.concat(words, " "), column, flags["--description"])
    if not card then
        return failure(message)
    end
    return { output = "added " .. card.id:sub(1, board.MIN_PREFIX) .. " " .. card.column }
end

function commands.note(backend, args)
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
---@param sub string `ls`, `next`, `add`, `note`, `move`, `take` or `release`
---@param args string[] the arguments after the subcommand
---@param backend dev.board.Backend the board
---@return dev.cmd.board.Result result the output, or a message and the exit code
function M.run(sub, args, backend)
    return commands[sub](backend, args)
end

---Build the backend a project's board uses.
---@param settings dev.cmd.board.Settings the board's backend and name
---@return dev.board.Backend? backend the backend
---@return string? message why there is none
function M.open(settings)
    if settings.backend == board.Backend.LOCAL then
        return nil, "dev: the local board backend is not built yet"
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
    return { backend = backend, name = name }
end

local function has_section(root)
    local text = fs.exists(root .. "/.dev/config.toml") and fs.read(root .. "/.dev/config.toml")
    local tree = text and toml.parse(text)
    return tree ~= nil and tree.board ~= nil
end

local function board_name(ctx, flags)
    local backend = config.get(ctx.root, "board.backend")
    local name = config.get(ctx.root, "board.name")
    if backend == nil and has_section(ctx.root) then
        verb.die('dev: [board] needs backend = "pomb" in .dev/config.toml')
    end
    if backend == board.Backend.LOCAL then
        verb.die("dev: the local board backend is not built yet")
    elseif backend ~= nil and backend ~= board.Backend.POMB then
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
    local ok, message = fs.write(path, existing .. gap .. section)
    if not ok then
        verb.die("dev: cannot write " .. path .. ": " .. tostring(message))
    end
end

local function host()
    return (devos.capture({ "hostname", "-s" }, { stderr = "null" }):gsub("%s+$", ""))
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
        local scope
        scope, message = backend:scope()
        if not scope then
            verb.die("dev: " .. message)
        elseif scope ~= ADMIN_SCOPE then
            verb.die("dev: the approved token has the " .. scope .. " scope, init needs admin")
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

M.handlers["board status"] = function(ctx)
    verb.no_args(ctx)
    local found = settings(ctx)
    print("backend: " .. found.backend)
    print("board: " .. found.name)
    return 0
end

for sub in pairs(commands) do
    M.handlers["board " .. sub] = function(ctx)
        local found = settings(ctx)
        local backend, message = M.open(found)
        if not backend then
            verb.die(message)
        end
        local result = M.run(sub, ctx.args, backend)
        if result.message then
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
