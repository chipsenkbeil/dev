local board = require("dev.board")
local config = require("dev.config")
local fs = require("dev.fs")
local pomb = require("dev.board.pomb")
local verb = require("dev.verb")

local NO_BOARD = "dev: no board for this project"
local USAGE = 2
local FAILURE = 1

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
    local rows = {}
    for _, card in ipairs(cards) do
        local shown = card.column == want or (not want and card.column ~= board.DONE)
        if shown and flags["--label"] then
            shown = false
            for _, label in ipairs(card.labels) do
                shown = shown or label == flags["--label"]
            end
        end
        if shown then
            rows[#rows + 1] = board.cells(card)
        end
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
    local ok, message = backend:note(card.id, table.concat(words, " ", 2))
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
    local ok, message = backend:move(card.id, column)
    if not ok then
        return failure(message)
    end
    return { output = "moved " .. card.id:sub(1, board.MIN_PREFIX) .. " to " .. column }
end

---Run one board subcommand against a backend.
---@param sub string `ls`, `next`, `add`, `note` or `move`
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
