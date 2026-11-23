local dev_os = require("dev.os")
local forge = require("dev.forge")
local json = require("dev.json")
local text = require("dev.text")
local vcs = require("dev.vcs")
local dev_command = require("dev.command")

local REASON_FLAG = "--reason"

---@class dev.cmd.abandon
local M = {}

local function parse(ctx)
    local change, reason
    local i = 1
    while i <= #ctx.args do
        local word = ctx.args[i]
        if word == REASON_FLAG then
            reason = ctx.args[i + 1]
            if reason == nil then
                dev_command.usage_error(ctx, "The " .. REASON_FLAG .. " flag needs a value.")
            end
            i = i + 2
        elseif word:sub(1, 1) == "-" or change then
            dev_command.usage_error(ctx, "Unknown argument " .. word .. ".")
        else
            change = word
            i = i + 1
        end
    end
    if not change then
        dev_command.usage_error(ctx, "Name the change number or Change-Id to abandon.")
    end
    if not change:match("^[%w]+$") then
        dev_command.usage_error(ctx, change .. " is not a change number or Change-Id.")
    end
    return change, reason
end

---Parse `ssh://[user@]host[:port]/project` into the ssh arguments and the project.
---@param url string the gerrit remote's URL
---@return string? port the ssh port, 22 when the URL has none
---@return string? host the host, with its user
---@return string? project the project name
function M.parse_url(url)
    local authority, project = url:match("^ssh://([^/]+)/(.*)$")
    if not authority then
        return nil
    end
    local host, port = authority:match("^(.-):(%d+)$")
    host = host or authority
    project = project:gsub("%.git$", "")
    if host == "" or not project:match("^[%w._/-]+$") then
        return nil
    end
    return port or "22", host, project
end

local function quote_message(reason)
    return "'" .. reason:gsub("'", [['\'']]) .. "'"
end

local function ssh(ctx, port, host, args)
    local argv = { "ssh", "-o", "BatchMode=yes", "-p", port, host, "gerrit" }
    for _, arg in ipairs(args) do
        argv[#argv + 1] = arg
    end
    dev_command.show(ctx, argv)
    return dev_os.capture(argv, { cwd = ctx.root, stderr = "stdout" })
end

local function find_change(out)
    local first
    for line in out:gmatch("[^\n]+") do
        local row = json.decode(line)
        if type(row) == "table" and row.status and row.currentPatchSet then
            if row.status == "NEW" then
                return row
            end
            first = first or row
        end
    end
    return first
end

---Abandon an open change on the project's gerrit.
---
---It queries the change for its current revision, refuses one that is missing or not NEW, then
---sends `gerrit review --abandon`, with `--reason TEXT` as the message.
---@param ctx dev.Ctx the command's context, whose `args` hold a change number or Change-Id
---@return integer code 0 when the change was abandoned, 1 otherwise
function M.run(ctx)
    local change, reason = parse(ctx)
    local backend, err = vcs.require(ctx.root)
    if not backend then
        dev_command.die(text.sentence(err))
    end
    local found, ferr = forge.resolve(ctx.root)
    if not found then
        dev_command.die(text.sentence(ferr))
    end
    if found.kind ~= forge.Kind.GERRIT then
        dev_command.die(
            "The forge is " .. found.kind .. ", and only a gerrit change can be abandoned."
        )
    end
    local url = vcs.config(ctx.root, backend, "remote." .. found.remote .. ".url")
    local port, host, project = M.parse_url(url)
    if not port then
        dev_command.die(
            "The remote "
                .. found.remote
                .. " has the URL "
                .. url
                .. ", which is not ssh://host[:port]/project."
        )
    end
    local out, code = ssh(ctx, port, host, {
        "query",
        "--format=JSON",
        "--current-patch-set",
        "project:" .. project,
        "change:" .. change,
    })
    if code ~= 0 then
        dev_command.die("The query of change " .. change .. " failed.\n" .. out)
    end
    local row = find_change(out)
    if not row then
        dev_command.die("Gerrit has no change " .. change .. " in project " .. project .. ".")
    end
    if row.status ~= "NEW" then
        dev_command.die(
            "Change " .. change .. " is " .. row.status .. ", not NEW. Nothing was abandoned."
        )
    end
    local review = { "review", "--abandon" }
    if reason then
        review[#review + 1] = "--message"
        review[#review + 1] = quote_message(reason)
    end
    review[#review + 1] = row.currentPatchSet.revision
    out, code = ssh(ctx, port, host, review)
    if code ~= 0 then
        dev_command.die("The abandon of change " .. change .. " failed.\n" .. out)
    end
    dev_command.say("Abandoned change " .. change .. ".")
    return 0
end

return M
