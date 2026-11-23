local dev_os = require("dev.os")
local fs = require("dev.fs")
local stderr = io.stderr
local stdout = io.stdout

---@class dev.Ctx
---@field name string the command as typed, a parent command and its subcommand joined by a space
---@field words string[] the command words
---@field root string absolute path of the project root
---@field args string[] positional arguments, minus `KEY=value` words unless `positional`
---@field vars table<string, string> the `KEY=value` arguments, whose key starts with an uppercase
---   letter
---@field after integer? how many words of `args` follow a `--`, 0 when none was typed
---@field dashed boolean? whether a `--` was typed, even with nothing after it
---@field verbose 0|1|2 the verbosity after the flags and `VERBOSE`
---@field interpreter string? the program dev runs under, as the launcher started it

---@class dev.command
local M = {}

---Print `dev <name>: <msg>` and exit 2.
---@param ctx dev.Ctx the command's context
---@param msg string what is wrong with the arguments
function M.usage_error(ctx, msg)
    stderr:write("dev ", ctx.name, ": ", msg, "\n")
    os.exit(2)
end

---Refuse any positional argument, for a command that takes no positional arguments.
---@param ctx dev.Ctx the command's context
function M.no_args(ctx)
    local arg = ctx.args[1]
    if arg == nil then
        return
    end
    if arg:sub(1, 1) == "-" then
        M.usage_error(ctx, "Unknown flag " .. arg .. ".")
    end
    M.usage_error(
        ctx,
        "Unknown argument " .. arg .. ". This command takes no positional arguments."
    )
end

---Write `msg` and a newline to standard output.
---@param msg string the whole message
function M.say(msg)
    stdout:write(msg, "\n")
end

---Write a captured text to standard output without its one trailing newline, and nothing for an
---empty text.
---@param text string the captured command output
function M.relay(text)
    if text == "" then
        return
    end
    M.say((text:gsub("\n$", "")))
end

---Write `msg` and a newline to standard error.
---@param msg string the whole message
function M.note(msg)
    stderr:write(msg, "\n")
end

---Print `msg` and exit 1.
---@param msg string the whole message
function M.die(msg)
    M.note(msg)
    os.exit(1)
end

---Print the command on standard error as `+ command` when `ctx.verbose` is 1 or more.
---@param ctx dev.Ctx the command's context
---@param argv string[] the command and its arguments, joined with spaces
function M.show(ctx, argv)
    if ctx.verbose >= 1 then
        M.note("+ " .. table.concat(argv, " "))
    end
end

---Exit 1 with one line when `binary` is not on PATH.
---@param binary string the program the command needs
---@param install string how to install it, as the warning shows
function M.need(binary, install)
    if not dev_os.which(binary) then
        M.note("Tool " .. binary .. " not found. Install it with " .. install .. ".")
        os.exit(1)
    end
end

---Run a command script in this process.
---
---A syntax error, an error a script raises and a script that returns anything
---but an integer all end the run with a message and no traceback.
---@param path string the `.lua` file
---@param ctx dev.Ctx the context the chunk gets
---@return integer code the script's exit code modulo 256 as a shell takes it, 0 when it returns
---   nothing
function M.run(path, ctx)
    local source, read_error = fs.read(path)
    if not source then
        M.note("dev " .. ctx.name .. ": cannot read " .. tostring(read_error))
        return 1
    end
    local chunk, message = load(source, "=" .. ctx.name)
    local ok, result = false, message
    if chunk then
        ok, result = xpcall(chunk, tostring, ctx)
    end
    if not ok then
        local text = tostring(result)
        if text:find("interrupted!", 1, true) then
            return dev_os.interrupt_code()
        end
        if text:sub(1, #ctx.name + 1) == ctx.name .. ":" then
            text = text:sub(#ctx.name + 2):gsub("^%d+: ", "")
        end
        M.note("dev " .. ctx.name .. ": " .. text)
        return 1
    end
    if result == nil then
        return 0
    end
    if type(result) ~= "number" or result % 1 ~= 0 then
        M.note(
            "dev "
                .. ctx.name
                .. ": the script returned "
                .. tostring(result)
                .. ", not an exit code"
        )
        return 1
    end
    return result % 256
end

return M
