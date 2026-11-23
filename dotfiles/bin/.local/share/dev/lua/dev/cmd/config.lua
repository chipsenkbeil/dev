local config = require("dev.config")
local dev_command = require("dev.command")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local term = require("dev.term")
local text = require("dev.text")
local toml = require("dev.toml")

local PASS_ENTRY = "^[%w_./][%w_. /-]*$"
local MAX_PORT = 65535
local MAX_PORT_DIGITS = 5

---How an answer for a key becomes a value
---@enum dev.cmd.config.Kind
local Kind = { STRING = "string", INTEGER = "integer", LIST = "list", PASS = "pass" }

---@class dev.cmd.config
---@field handlers table<string, fun(ctx: dev.Ctx, reg: dev.Registry): integer> the handler of
---   `config`
---@field KEYS dev.cmd.config.Key[] the user keys the wizard asks for, the required ones first
local M = { handlers = {} }

---@class dev.cmd.config.Key
---@field name string the dotted key
---@field kind dev.cmd.config.Kind how an answer becomes a value
---@field required boolean whether dev cannot work without it
---@field ask string what the prompt calls it

M.KEYS = {
    { name = "board.pomb.url", kind = Kind.STRING, required = true, ask = "Pomb URL" },
    {
        name = "board.pomb.token",
        kind = Kind.PASS,
        required = true,
        ask = "Pomb token reference, as pass:<entry>",
    },
    { name = "gerrit.host", kind = Kind.STRING, required = true, ask = "Gerrit host" },
    {
        name = "board.pomb.field_prefix",
        kind = Kind.STRING,
        required = false,
        ask = "Pomb field prefix",
    },
    { name = "gerrit.port", kind = Kind.INTEGER, required = false, ask = "Gerrit port" },
    {
        name = "board.ship.source_roots",
        kind = Kind.LIST,
        required = false,
        ask = "Source roots, comma separated",
    },
}

---The sentence that says why `toml.set` wrote nothing, before the parser's line when it has one
local SET_REFUSALS = {
    [toml.SetRefusal.BAD_KEY] = "The key is not a plain dotted key",
    [toml.SetRefusal.BAD_VALUE] = "The value cannot be written",
    [toml.SetRefusal.ALREADY_SET] = "The key is already set",
    [toml.SetRefusal.UNPARSEABLE] = "The file does not parse, line",
    [toml.SetRefusal.RESULT_INVALID] = "The file would not parse after the key was added, line",
}

local function user_path()
    local home = os.getenv("HOME")
    if not home or home == "" then
        dev_command.die("HOME is not set.")
    end
    return home .. "/.config/dev/config.toml"
end

local function split_list(answer)
    local items = {}
    for item in answer:gmatch("[^,]+") do
        item = item:match("^%s*(.-)%s*$")
        if item ~= "" then
            items[#items + 1] = item
        end
    end
    return items
end

local function convert(key, answer)
    if key.kind == Kind.PASS then
        local entry = answer:match("^pass:(.+)$")
        if entry and entry:find(PASS_ENTRY) and not entry:find("..", 1, true) then
            return answer
        end
        return nil, "The token key takes only a pass:<entry> reference. Nothing was kept for it."
    elseif key.kind == Kind.INTEGER then
        local number = answer:match("^%d+$") and #answer <= MAX_PORT_DIGITS and tonumber(answer)
        if number and number >= 1 and number <= MAX_PORT then
            return number
        end
        return nil, key.name .. " takes a whole number from 1 to " .. MAX_PORT .. "."
    elseif key.kind == Kind.LIST then
        local items = split_list(answer)
        if #items > 0 then
            return items
        end
        return nil, key.name .. " takes a comma separated list."
    end
    return answer
end

local function read_answer(key)
    if key.kind ~= Kind.PASS then
        return io.read("*l")
    end
    local restore = term.silent(0)
    local ok, line = pcall(io.read, "*l")
    restore()
    if not ok then
        error(line, 0)
    end
    io.write("\n")
    return line
end

local function ask(key)
    while true do
        io.write(key.ask, key.required and ": " or " (blank to skip): ")
        io.flush()
        local line = read_answer(key)
        if line == nil then
            io.write("\n")
            return nil
        end
        local answer = line:match("^%s*(.-)%s*$")
        if answer == "" and not key.required then
            return nil
        elseif answer ~= "" then
            local value, refusal = convert(key, answer)
            if value ~= nil then
                return value
            end
            dev_command.say(refusal)
        end
    end
end

local function refusal_sentence(path, key, reason, detail)
    local sentence = SET_REFUSALS[reason] .. (detail and " " .. detail or "")
    return text.sentence(path .. ": " .. key .. ": " .. sentence)
end

local function write_answers(answers)
    local path = user_path()
    local body = fs.exists(path) and fs.read(path) or ""
    for _, answer in ipairs(answers) do
        local updated, reason, detail = toml.set(body, answer.key, answer.value)
        if not updated then
            dev_command.die(refusal_sentence(path, answer.key, reason, detail))
        end
        body = updated
    end
    local made, made_err = fs.mkdir(fs.dirname(path), { parents = true })
    if not made then
        dev_command.die(text.sentence(tostring(made_err)))
    end
    local written, write_err = fs.write(path, body)
    if not written then
        dev_command.die(text.sentence(path .. ": " .. tostring(write_err)))
    end
    for _, answer in ipairs(answers) do
        dev_command.say("Wrote " .. answer.key .. " to " .. path .. ".")
    end
end

local function any_required(keys)
    for _, key in ipairs(keys) do
        if key.required then
            return true
        end
    end
    return false
end

local function unset_keys()
    local unset, is_unset = {}, {}
    for _, key in ipairs(M.KEYS) do
        if config.user(key.name) == nil then
            unset[#unset + 1] = key
            is_unset[key.name] = true
        end
    end
    return unset, is_unset
end

local function report(is_unset, interactive)
    for _, key in ipairs(M.KEYS) do
        if not interactive or not is_unset[key.name] then
            local state = "set"
            if is_unset[key.name] then
                state = key.required and "unset, required" or "unset"
            end
            dev_command.say(key.name .. ": " .. state)
        end
    end
end

local function ask_all(unset)
    local answers, left = {}, {}
    for _, key in ipairs(unset) do
        local value = ask(key)
        if value == nil then
            left[#left + 1] = key
        else
            answers[#answers + 1] = { key = key.name, value = value }
        end
    end
    return answers, left
end

---Report the user keys, and on a terminal ask for the ones that are unset.
---
---Without a terminal it prints each key and whether it is set, and exits 1 when
---a required key is unset. On a terminal it asks for each unset key as a line
---on standard input and appends the answers to the user config, keeping what is
---there. An answer for `board.pomb.token` that is not `pass:<entry>` is
---refused and never printed or written, and the terminal does not echo it.
---@param ctx dev.Ctx the command's context
---@return integer code 0, or 1 when a required key is still unset
function M.run(ctx)
    dev_command.no_args(ctx)
    local unset, is_unset = unset_keys()
    local interactive = dev_os.isatty(0)
    report(is_unset, interactive)
    if not interactive then
        return any_required(unset) and 1 or 0
    end
    local answers, left = ask_all(unset)
    if #answers > 0 then
        write_answers(answers)
    end
    return any_required(left) and 1 or 0
end

M.handlers["config"] = M.run

return M
