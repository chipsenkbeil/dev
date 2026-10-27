local devos = require("dev.os")
local fs = require("dev.fs")
local project = require("dev.project")
local pull = require("dev.cmd.pull")
local push = require("dev.cmd.push")
local registry = require("dev.registry")
local types = require("dev.cmd.types")
local text = require("dev.text")
local topics = require("dev.topics")
local ui = require("dev.ui")
local verb = require("dev.verb")

local Style = ui.Style
local stderr = io.stderr
local NAME = "^[A-Za-z0-9_-]+$"
local GROUPS = { "Check your work", "Share it", "Set up a machine or project", "Boxes" }
local HIDDEN = "Hidden"
local OVERRIDE = "(override)"
local HELP_CTX = { name = "help" }
local ONE_COMMAND = "`dev help <verb>` for one command and `dev help <topic>` for a topic.\n"
local LISTED = { push = push, pull = pull }
local HELPERS = {
    { "__verbs", "List the verbs with their descriptions, for shell completion" },
    { "__subs", "List the subcommands of a noun, for shell completion" },
    { "__flags", "List the flags of a verb, for shell completion" },
    {
        "__check-topics",
        "Check the built-in and project topics against the real verbs and flags",
    },
}

---@class dev.help.VerbOpts
---@field words string[] one word for a verb, two for a subcommand
---@field short boolean? true for the usage and flags `dev <verb> -h` shows

---@class dev.help.NounOpts
---@field stderr boolean? print on standard error, for a usage error

---@class dev.help
local M = {}

local function fail(message)
    verb.usage_error(HELP_CTX, message)
end

local function screen()
    return ui.context({ width = 80, interactive = false })
end

local function pad(s, width)
    return s .. string.rep(" ", width - text.width(s))
end

local function widths(rows)
    local width, markw = 0, 0
    for _, row in ipairs(rows) do
        width = math.max(width, text.width(row.name))
        if row.origin == "override" then
            markw = text.width(OVERRIDE)
        end
    end
    return width, markw
end

local function section(c, out, title, rows, width, markw)
    if #rows == 0 then
        return
    end
    local own_width, own_markw = widths(rows)
    width, markw = math.max(width or 0, own_width), math.max(markw or 0, own_markw)
    out[#out + 1] = "\n" .. ui.paint(c, title, Style.BOLD) .. "\n"
    for _, row in ipairs(rows) do
        local line = "  " .. ui.paint(c, pad(row.name, width), Style.CYAN) .. text.GAP
        if markw > 0 then
            local mark = row.origin == "override" and OVERRIDE or ""
            line = line .. ui.paint(c, pad(mark, markw), Style.DIM) .. text.GAP
        end
        out[#out + 1] = line .. row.desc .. "\n"
    end
end

local function topic_rows(ctx)
    local seen, rows = {}, {}
    for _, file in ipairs(topics.files(ctx.root)) do
        if not seen[file.name] then
            seen[file.name] = true
            local first = (fs.read(file.path) or ""):match("^[^\n]*")
            local cut = first:find(": ", 1, true)
            rows[#rows + 1] = {
                name = file.name,
                origin = "topic",
                desc = cut and first:sub(cut + 2) or first,
            }
        end
    end
    table.sort(rows, function(a, b)
        return a.name < b.name
    end)
    return rows
end

local function topic_path(ctx, name)
    if not name:find(NAME) then
        return nil
    end
    for _, file in ipairs(topics.files(ctx.root)) do
        if file.name == name then
            return file.path
        end
    end
end

local function print_topic(ctx, name)
    local path = topic_path(ctx, name)
    if not path then
        fail("unknown topic " .. name .. ", see dev help --topics")
    end
    io.write(fs.read(path) or "")
end

local function project_type(ctx)
    return project.detect_type(ctx.root) or "none"
end

---@class dev.help.ListOpts
---@field all boolean? whether the hidden verbs and dev's helpers are listed too

local function verb_rows(reg, opts)
    local all = opts.all
    local rows = {}
    for _, row in ipairs(reg:verbs()) do
        if not row.hidden then
            rows[#rows + 1] =
                { group = row.group, name = row.name, origin = row.kind, desc = row.desc }
        elseif all then
            rows[#rows + 1] =
                { group = HIDDEN, name = row.name, origin = row.kind, desc = row.desc }
        end
    end
    if all then
        for _, helper in ipairs(HELPERS) do
            rows[#rows + 1] =
                { group = HIDDEN, name = helper[1], origin = "builtin", desc = helper[2] }
        end
    end
    return rows
end

local function in_group(rows, group)
    local out = {}
    for _, row in ipairs(rows) do
        if row.group == group then
            out[#out + 1] = row
        end
    end
    return out
end

local function group_order(rows)
    local order, seen = {}, { [HIDDEN] = true }
    for _, group in ipairs(GROUPS) do
        seen[group] = true
        order[#order + 1] = group
    end
    for _, row in ipairs(rows) do
        if not seen[row.group] then
            seen[row.group] = true
            order[#order + 1] = row.group
        end
    end
    return order
end

local function overview(ctx, reg, c, opts)
    local all = opts.all
    local out = {}
    local rows, listed = verb_rows(reg, opts), topic_rows(ctx)
    local width, markw = widths(rows)
    width = math.max(width, (widths(listed)))
    local kind = project_type(ctx)
    out[#out + 1] = ui.paint(c, "dev", Style.BOLD)
        .. ": "
        .. (kind == "none" and "" or kind .. " ")
        .. "project at "
        .. ctx.root
        .. "\n"
    for _, group in ipairs(group_order(rows)) do
        section(c, out, group, in_group(rows, group), width, markw)
    end
    if all then
        section(c, out, HIDDEN, in_group(rows, HIDDEN), width, markw)
    end
    section(c, out, "Topics", listed, width, markw)
    if all then
        out[#out + 1] = "\nRun " .. ONE_COMMAND
    else
        out[#out + 1] = "\nRun `dev help -a` for every command, " .. ONE_COMMAND
    end
    return table.concat(out)
end

local function noun_text(reg, c, noun)
    local out = {}
    local row = reg:find({ noun })
    out[#out + 1] = ui.paint(c, "dev " .. noun, Style.BOLD) .. "\n  " .. row.desc .. "\n"
    local subs = {}
    for _, sub in ipairs(reg:subs(noun)) do
        subs[#subs + 1] = { name = sub.words[2], origin = sub.kind, desc = sub.desc }
    end
    section(c, out, "subcommands", subs)
    out[#out + 1] = "\nRun `dev help " .. noun .. " <sub>` for a subcommand's flags and header.\n"
    return table.concat(out)
end

local function builtin_commands(ctx, row)
    if row.usage and row.usage ~= "" then
        return { row.usage }
    end
    if types.VERBS[row.name] then
        return types.commands(ctx.root, project_type(ctx), row.name)
    end
    if LISTED[row.name] then
        return LISTED[row.name].commands(ctx.root)
    end
    local out = devos.capture({ "bash", project.share .. "/legacy.bash", "__commands", row.name }, {
        env = { DEV_UID = tostring(devos.getuid()), DEV_OS = devos.name() },
    })
    local lines = {}
    for line in out:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

local function verb_text(ctx, reg, c, opts)
    local words, short = opts.words, opts.short
    local name = table.concat(words, " ")
    local row = reg:find(words)
    if not row or row.noun then
        fail("unknown verb " .. name)
    end
    local out = {}
    out[#out + 1] = ui.paint(c, "dev " .. name, Style.BOLD)
        .. (row.kind == "override" and " " .. OVERRIDE or "")
        .. "\n  "
        .. row.desc
        .. "\n"
    local flags = reg:flags(words)
    if short then
        local usage = row.usage
        if not (usage and usage:sub(1, 4) == "dev ") then
            usage = "dev " .. name .. (#flags > 0 and " [flags]" or "")
        end
        out[#out + 1] = "\n" .. ui.paint(c, "usage", Style.BOLD) .. "\n  " .. usage .. "\n"
    end
    if #flags > 0 then
        out[#out + 1] = "\n" .. ui.paint(c, "flags", Style.BOLD) .. "\n"
        for _, flag in ipairs(flags) do
            out[#out + 1] = "  " .. flag .. "\n"
        end
    end
    if short then
        out[#out + 1] = "\nRun `dev "
            .. name
            .. " --help` for the script header and the command it runs.\n"
        return table.concat(out)
    end
    local header = reg:header(row)
    if header then
        out[#out + 1] = "\n"
            .. ui.paint(c, row.script:sub(#ctx.root + 2) .. " header", Style.BOLD)
            .. "\n"
        for _, line in ipairs(header.long) do
            out[#out + 1] = "  " .. line .. "\n"
        end
    end
    if row.kind ~= "local" then
        out[#out + 1] = "\n"
            .. ui.paint(c, "the built-in runs", Style.BOLD)
            .. " ("
            .. project_type(ctx)
            .. " project)\n"
        for _, line in ipairs(builtin_commands(ctx, row)) do
            out[#out + 1] = "  " .. line .. "\n"
        end
    end
    out[#out + 1] = "\nGlobal flags:\n"
        .. "  -v          print each command before it runs\n"
        .. "  -vv         also trace every line of dev and of each bash script\n"
        .. "  --remote    run this command on a remote runner, see `dev help remote`\n"
        .. "  --detach    with --remote, start the job and return\n"
    return table.concat(out)
end

local function has_sub(reg, noun, sub)
    for _, row in ipairs(reg:subs(noun)) do
        if row.words[2] == sub then
            return true
        end
    end
    return false
end

---Print the details of one verb or subcommand.
---
---An unknown name is a usage error of `dev help`, exit 2.
---@param ctx dev.Ctx the context of the command
---@param reg dev.Registry the project's registry
---@param opts dev.help.VerbOpts which verb, and whether to print the short form
---@return integer code 0
function M.verb(ctx, reg, opts)
    io.write(verb_text(ctx, reg, screen(), opts))
    return 0
end

---Print the curated view, as `dev help` does with no argument.
---@param ctx dev.Ctx the context of the command
---@param reg dev.Registry the project's registry
---@return integer code 0
function M.overview(ctx, reg)
    io.write(overview(ctx, reg, screen(), {}))
    return 0
end

---Refuse a flag or argument a verb does not take.
---
---It prints the message and the curated view on standard error, then exits 2.
---@param ctx dev.Ctx the context of the command
---@param reg dev.Registry the project's registry
---@param arg string the argument that is not taken
function M.bad_argument(ctx, reg, arg)
    local kind = arg:sub(1, 1) == "-" and "flag" or "argument"
    stderr:write("dev ", ctx.name, ": unknown ", kind, " ", arg, "\n\n")
    stderr:write(overview(ctx, reg, screen():stderr(), {}))
    os.exit(2)
end

---Print the topic called `name` when the project or dev has one.
---@param ctx dev.Ctx the context of the command
---@param name string the topic name
---@return boolean found whether the topic exists, so whether it was printed
function M.topic(ctx, name)
    if not topic_path(ctx, name) then
        return false
    end
    print_topic(ctx, name)
    return true
end

---Print a noun's description and its subcommands.
---@param reg dev.Registry the project's registry
---@param noun string the noun's name
---@param opts dev.help.NounOpts? where to print
---@return integer code 0
function M.noun(reg, noun, opts)
    local c = screen()
    if opts and opts.stderr then
        stderr:write(noun_text(reg, c:stderr(), noun))
    else
        io.write(noun_text(reg, c, noun))
    end
    return 0
end

---Run `dev help`.
---
---With no argument it prints the curated view. `-a` adds the hidden verbs,
---`--topics` lists the topics, `-k TOPIC` prints one, and a verb, noun or
---topic name prints its details.
---@param ctx dev.Ctx the context, whose `args` are the arguments after `help`
---@param reg dev.Registry? the project's registry, loaded when nil
---@return integer code 0, or the process exits 2 on a usage error
function M.run(ctx, reg)
    reg = reg or registry.load(ctx.root)
    local args = ctx.args
    local first = args[1]
    if first == "-h" then
        return M.verb(ctx, reg, { words = { "help" }, short = true })
    elseif first == "--help" then
        return M.verb(ctx, reg, { words = { "help" } })
    elseif first == "-a" then
        if #args ~= 1 then
            fail("-a takes no arguments, got " .. args[2])
        end
        io.write(overview(ctx, reg, screen(), { all = true }))
        return 0
    elseif first == "--topics" then
        if #args ~= 1 then
            fail("--topics takes no arguments, got " .. args[2])
        end
        for _, row in ipairs(topic_rows(ctx)) do
            io.write(row.name, "\t", row.desc, "\n")
        end
        return 0
    elseif first == "-k" then
        if #args ~= 2 then
            fail("-k needs one topic name")
        end
        print_topic(ctx, args[2])
        return 0
    elseif first and first:sub(1, 1) == "-" then
        fail("unknown flag " .. first)
    end
    if #args == 0 then
        return M.overview(ctx, reg)
    elseif #args == 1 then
        local row = reg:find({ first })
        if row and row.noun then
            return M.noun(reg, first)
        elseif row then
            return M.verb(ctx, reg, { words = { first } })
        elseif topic_path(ctx, first) then
            print_topic(ctx, first)
        else
            fail("unknown verb " .. first .. ", and no topic of that name")
        end
    elseif #args == 2 then
        if not reg:is_noun(first) then
            fail(first .. " has no subcommands")
        end
        if not has_sub(reg, first, args[2]) then
            fail("unknown subcommand " .. args[2] .. " of " .. first)
        end
        return M.verb(ctx, reg, { words = { first, args[2] } })
    else
        fail("too many arguments, got " .. args[3])
    end
    return 0
end

return M
