local dev_command = require("@dev/command")
local dev_os = require("@dev/os")
local follow = require("@dev/cmd/follow")
local markdown = require("@dev/ui/markdown")
local project = require("@dev/project")
local pull = require("@dev/cmd/pull")
local push = require("@dev/cmd/push")
local registry = require("@dev/registry")
local term = require("@dev/term")
local text = require("@dev/text")
local topics = require("@dev/topics")
local types = require("@dev/cmd/types")
local ui = require("@dev/ui")

local Style = ui.Style
local NAME = "^[A-Za-z0-9_-]+$"
local GROUPS = { "Check your work", "Share it", "Set up a machine or project", "Boxes" }
local HIDDEN = "Hidden"
local OVERRIDE = "(override)"
---The built-in commands whose help lists the commands they run.
local LISTED = { push = push, pull = pull, follow = follow }
local SEE_ALSO_FIELD = require("@dev/spec").SEE_ALSO_FIELD
local TOPIC_WIDTH = 100
local LESS_FILTER = " -+F"
local FILTER_HINT = "& filters · / searches · q quits"
local HELP_CTX = { name = "help" }
local ONE_COMMAND = "`dev help <command>` for one command and `dev help <page>` for a help page."
local GLOBAL_FLAG_HELP = {
    { "-v", "print each command before it runs, and debug log lines" },
    { "-vv", "also log every spawn with its folder, exit code and time" },
    {
        "-vvv",
        "also trace every native dev call, and run a .sh command under bash -x "
            .. "(that script only, not the scripts or tools it starts)",
    },
    { "-vvvv", "also trace calls between dev's Luau modules" },
    { "--remote", "run this command on a remote runner, see `dev help remote`" },
    {
        "--local",
        "run this command here, whatever the default is "
            .. "(refused for a ci command under DEV_AGENT)",
    },
    { "--detach", "with --remote, start the job and return" },
    { "--priority", "with --remote, start the job ahead of normal ci jobs" },
    { "--job-timeout DURATION", "with --remote, give the ci run a time limit" },
    { "-C DIR", "run as if dev started in DIR" },
    { "--version", "print dev's version and exit" },
    { "-V", "the same as --version" },
    { "--agent NAME", "export DEV_AGENT=NAME to the command" },
}

---@class dev.help.command.Opts
---@field words string[] one word for a command, two for a subcommand
---@field short boolean? true for the usage and flags `dev <command> -h` shows

---@class dev.help.parent.Opts
---@field stderr boolean? print on standard error, for a usage error

---@class dev.help
local M = {}

local function fail(message)
    dev_command.usage_error(HELP_CTX, message)
end

local function screen()
    return ui.context({ interactive = false })
end

local function pad(s, width)
    return s .. string.rep(" ", width - text.width(s))
end

local function widths(rows)
    local width, markw = 0, 0
    for _, row in ipairs(rows) do
        width = math.max(width, text.width(row.name))
        markw = math.max(markw, text.width(row.mark or ""))
    end
    return width, markw
end

local function fit_line(c, line)
    return c.color and text.fit(line, c.width) or line
end

local function row_text(c, lead, desc)
    local line = lead .. desc
    if not c.color or text.width(line) <= c.width then
        return line
    end
    local indent = string.rep(" ", text.width(lead))
    local lines = text.wrap(text.words(desc), c.width - text.width(lead))
    return lead .. table.concat(lines, "\n" .. indent)
end

---@class dev.help.Row
---@field name string the command, subcommand or topic
---@field mark string? the text of the mark column, `(override)` or the source
---@field desc string the description

---@class dev.help.Section
---@field title string the heading
---@field rows dev.help.Row[] the rows under it
---@field width integer? the name column width to keep at least
---@field markw integer? the mark column width to keep at least
---@field compact boolean? true for the terminal layout of the curated view

local function pointer(c, line)
    local styled = line:gsub("`([^`]+)`", function(span)
        return c.color and ui.paint(c, span, Style.CYAN) or "`" .. span .. "`"
    end)
    return fit_line(c, styled) .. "\n"
end

local function section(c, out, spec)
    local title, rows, compact = spec.title, spec.rows, spec.compact
    if #rows == 0 then
        return
    end
    local own_width, own_markw = widths(rows)
    local width = math.max(spec.width or 0, own_width)
    local markw = math.max(spec.markw or 0, own_markw)
    local heading = ui.paint(c, title, compact and Style.DIM or Style.BOLD)
    out[#out + 1] = "\n" .. heading .. "\n"
    for _, row in ipairs(rows) do
        local name = pad(row.name, width)
        local line = "  " .. ui.paint(c, name, compact and Style.BOLD or Style.CYAN) .. text.GAP
        if markw > 0 then
            line = line .. ui.paint(c, pad(row.mark or "", markw), Style.DIM) .. text.GAP
        end
        if compact then
            out[#out + 1] = fit_line(c, line .. row.desc) .. "\n"
        else
            out[#out + 1] = row_text(c, line, row.desc) .. "\n"
        end
    end
end

local function topic_rows(ctx)
    local seen, rows = {}, {}
    for _, file in ipairs(topics.files(ctx.root)) do
        if not seen[file.name] then
            seen[file.name] = true
            rows[#rows + 1] = { name = file.name, desc = topics.summary(file) }
        end
    end
    table.sort(rows, function(a, b)
        return a.name < b.name
    end)
    return rows
end

local function topic_file(ctx, name)
    if not name:find(NAME) then
        return nil
    end
    for _, file in ipairs(topics.files(ctx.root)) do
        if file.name == name then
            return file
        end
    end
end

local function render_markdown(source)
    if ui.context({ width = TOPIC_WIDTH }).color then
        local _, cols = term.size()
        return markdown(source, { width = math.min(cols, TOPIC_WIDTH), color = true })
    end
    return source
end

local function topic_source(ctx, file)
    local text = topics.text(file)
    if file.builtin and file.name == topics.OVERVIEW then
        for _, other in ipairs(topics.files(ctx.root)) do
            if not other.builtin and other.name == topics.OVERVIEW then
                text = text .. "\n" .. topics.text(other)
            end
        end
    end
    return render_markdown(text)
end

local function page(content, opts)
    local plan = M.page_plan(opts, dev_os.getenv("PAGER"), dev_os.getenv("DEV_PAGER"))
    if plan.hint and ui.should_page(content, plan.page) then
        plan.page.fallback = content
        content = M.hinted(content, screen())
    end
    ui.page(content, plan.page)
end

local function print_topic(ctx, name, opts)
    local file = topic_file(ctx, name)
    if not file then
        fail("Unknown help page " .. name .. ". Run `dev help --topics` to list them.")
    end
    page(topic_source(ctx, file), opts)
end

local function project_type(ctx)
    return project.detect_type(ctx.root) or project.Kind.NONE
end

local function source_label(row)
    return row.replaces and row.source .. " over " .. row.replaces or row.source
end

---@class dev.help.command_rows.Opts
---@field all boolean? whether the hidden commands are listed too

local function hidden_subs(reg, name, mark, rows)
    for _, sub in ipairs(reg:subs(name, { all = true })) do
        if sub.hidden then
            rows[#rows + 1] = { group = HIDDEN, name = sub.name, mark = mark, desc = sub.desc }
        end
        if sub.parent then
            hidden_subs(reg, sub.words, mark, rows)
        end
    end
end

local function command_rows(reg, opts)
    local all = opts.all
    local rows = {}
    for _, row in ipairs(reg:commands()) do
        local mark = all and source_label(row) or row.replaces and OVERRIDE or ""
        if not row.hidden then
            rows[#rows + 1] = { group = row.group, name = row.name, mark = mark, desc = row.desc }
        elseif all then
            rows[#rows + 1] = { group = HIDDEN, name = row.name, mark = mark, desc = row.desc }
        end
        if all and row.parent then
            hidden_subs(reg, row.name, mark, rows)
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
    local rows, listed = command_rows(reg, opts), topic_rows(ctx)
    local width, markw = widths(rows)
    width = math.max(width, (widths(listed)))
    local kind = project_type(ctx)
    local top = ui.paint(c, "dev", Style.BOLD)
        .. ": "
        .. (kind == project.Kind.NONE and "" or kind .. " ")
        .. "project at "
        .. ctx.root
    out[#out + 1] = fit_line(c, top) .. "\n"
    for _, group in ipairs(group_order(rows)) do
        section(c, out, {
            title = group,
            rows = in_group(rows, group),
            width = width,
            markw = markw,
            compact = true,
        })
    end
    if all then
        section(c, out, {
            title = HIDDEN,
            rows = in_group(rows, HIDDEN),
            width = width,
            markw = markw,
            compact = true,
        })
    end
    section(
        c,
        out,
        { title = "Help pages", rows = listed, width = width, markw = markw, compact = true }
    )
    if all then
        out[#out + 1] = "\n" .. pointer(c, "Run " .. ONE_COMMAND)
    else
        out[#out + 1] = "\n" .. pointer(c, "Run `dev help -a` for all, " .. ONE_COMMAND)
    end
    return table.concat(out)
end

---Return a command's description and subcommands as `dev help <command>` prints them.
---@param reg dev.Registry the project's registry
---@param c dev.ui.Context the drawing settings
---@param words string[] the command's words
---@return string text the command's help
function M.parent_text(reg, c, words)
    local out = {}
    local name = table.concat(words, " ")
    local row = reg:find(words)
    out[#out + 1] = ui.paint(c, "dev " .. name, Style.BOLD) .. "\n  " .. row.desc .. "\n"
    local subs = {}
    for _, sub in ipairs(reg:subs(words)) do
        subs[#subs + 1] = {
            name = sub.words[#sub.words],
            mark = sub.replaces and OVERRIDE or "",
            desc = sub.desc,
        }
    end
    section(c, out, { title = "subcommands", rows = subs })
    out[#out + 1] = "\nRun `dev help "
        .. name
        .. " <sub>` for a subcommand's flags and arguments.\n"
    return table.concat(out)
end

local function flag_label(flag)
    local label = "--" .. flag.name
    if flag.short then
        label = "-" .. flag.short .. ", " .. label
    end
    if flag.kind and flag.kind ~= "boolean" then
        label = label .. " <" .. flag.kind .. ">"
    end
    return label
end

local function notes_text(def)
    local notes = {}
    if def.required then
        notes[#notes + 1] = "required"
    end
    if def.repeatable then
        notes[#notes + 1] = "repeatable"
    end
    if def.list then
        notes[#notes + 1] = "list"
    end
    if def.default ~= nil then
        notes[#notes + 1] = "default " .. tostring(def.default)
    end
    if def.choices then
        notes[#notes + 1] = "one of " .. table.concat(def.choices, ", ")
    end
    return #notes > 0 and " (" .. table.concat(notes, "; ") .. ")" or ""
end

local function arg_label(arg)
    local name = arg.name .. (arg.list and "..." or "")
    return arg.required and "<" .. name .. ">" or "[" .. name .. "]"
end

local function usage_line(name, spec)
    local parts = { "dev " .. name }
    if #spec.flags > 0 then
        parts[#parts + 1] = "[flags]"
    end
    for _, arg in ipairs(spec.args) do
        parts[#parts + 1] = arg_label(arg)
    end
    return table.concat(parts, " ")
end

local function spec_of(reg, row)
    local ok, spec, reason = pcall(reg.spec, reg, row)
    if not ok then
        spec, reason = nil, spec
    end
    if not spec and reason then
        dev_command.note(`The spec of {row.name} does not load. {text.sentence(tostring(reason))}`)
    end
    spec = spec or {}
    return {
        flags = spec.flags or {},
        args = spec.args or {},
        runs_local = spec.runs_local,
        long = spec.long,
        see_also = spec[SEE_ALSO_FIELD],
    }
end

local function entry_line(entry, width)
    if entry[2] == "" then
        return `  {entry[1]}\n`
    end
    return `  {pad(entry[1], width)}{text.GAP}{entry[2]}\n`
end

local function pad_all(entries)
    local width = 0
    for _, entry in ipairs(entries) do
        width = math.max(width, text.width(entry[1]))
    end
    return width
end

local function built_in_runs(ctx, c, row)
    if row.source ~= registry.Source.BUILTIN then
        return ""
    end
    local scope, lines
    if types.COMMANDS[row.name] then
        local kind = project_type(ctx)
        scope = ` ({kind} project)`
        lines = types.commands(ctx.root, kind, row.name)
    elseif LISTED[row.name] then
        scope = ""
        lines = LISTED[row.name].commands(ctx.root)
    end
    if not lines then
        return ""
    end
    local out = { `\n{ui.paint(c, "the built-in runs", Style.BOLD)}{scope}\n` }
    for _, line in ipairs(lines) do
        out[#out + 1] = `  {line}\n`
    end
    return table.concat(out)
end

local function command_text(ctx, reg, c, opts)
    local words, short = opts.words, opts.short
    local name = table.concat(words, " ")
    local row = reg:find(words)
    if not row or row.parent then
        fail("Unknown command " .. name .. ". Run `dev help -a` to list them.")
    end
    local spec = spec_of(reg, row)
    local out = {}
    out[#out + 1] = ui.paint(c, "dev " .. name, Style.BOLD)
        .. (row.replaces and " (" .. source_label(row) .. ")" or "")
        .. "\n  "
        .. row.desc
        .. "\n"
    if spec.runs_local then
        out[#out + 1] = "  runs here under the remote default, see `dev help remote`\n"
    end
    out[#out + 1] = "\n"
        .. ui.paint(c, "usage", Style.BOLD)
        .. "\n  "
        .. usage_line(name, spec)
        .. "\n"
    if #spec.flags > 0 then
        out[#out + 1] = "\n" .. ui.paint(c, "flags", Style.BOLD) .. "\n"
        local entries = {}
        for _, flag in ipairs(spec.flags) do
            entries[#entries + 1] = { flag_label(flag), (flag.help or "") .. notes_text(flag) }
        end
        local width = pad_all(entries)
        for _, entry in ipairs(entries) do
            if short then
                out[#out + 1] = "  " .. entry[1] .. "\n"
            else
                out[#out + 1] = entry_line(entry, width)
            end
        end
    end
    if not short and #spec.args > 0 then
        out[#out + 1] = "\n" .. ui.paint(c, "arguments", Style.BOLD) .. "\n"
        local entries = {}
        for _, arg in ipairs(spec.args) do
            entries[#entries + 1] = { arg_label(arg), (arg.help or "") .. notes_text(arg) }
        end
        local width = pad_all(entries)
        for _, entry in ipairs(entries) do
            out[#out + 1] = entry_line(entry, width)
        end
    end
    if short then
        out[#out + 1] = "\nRun `dev " .. name .. " --help` for every flag and argument.\n"
        return table.concat(out)
    end
    local long = type(spec.long) == "table" and table.concat(spec.long, "\n") or spec.long
    if type(long) == "string" and long ~= "" then
        out[#out + 1] = "\n" .. (render_markdown(long):gsub("\n*$", "\n"))
    end
    out[#out + 1] = built_in_runs(ctx, c, row)
    if type(spec.see_also) == "table" and #spec.see_also > 0 then
        local pages = {}
        for _, page in ipairs(spec.see_also) do
            pages[#pages + 1] = `\`dev help {page}\``
        end
        local last = table.remove(pages)
        local listed = if #pages > 0 then `{table.concat(pages, ", ")} and {last}` else last
        out[#out + 1] = `\nSee {listed}.\n`
    end
    out[#out + 1] = "\nGlobal flags:\n"
    local width = 0
    for _, flag in ipairs(GLOBAL_FLAG_HELP) do
        width = math.max(width, #flag[1])
    end
    for _, flag in ipairs(GLOBAL_FLAG_HELP) do
        out[#out + 1] = "  " .. flag[1] .. string.rep(" ", width - #flag[1] + 2) .. flag[2] .. "\n"
    end
    return table.concat(out)
end

---Print the details of one command or subcommand.
---
---An unknown name is a usage error of `dev help`, exit 2.
---@param ctx dev.Ctx the context of the command
---@param reg dev.Registry the project's registry
---@param opts dev.help.command.Opts which command, and whether to print the short form
---@return integer code 0
function M.command(ctx, reg, opts)
    dev_os.stdout:write(command_text(ctx, reg, screen(), opts))
    return 0
end

---Print the curated view, as `dev help` does with no argument.
---
---On a terminal it always goes through the pager, with a hint line on filtering at its end when
---the pager is less.
---@param ctx dev.Ctx the context of the command
---@param reg dev.Registry the project's registry
---@param opts { no_pager: boolean? }? whether paging is off
---@return integer code 0
function M.overview(ctx, reg, opts)
    page(M.overview_text(ctx, reg), { no_pager = opts and opts.no_pager, curated = true })
    return 0
end

---Tell whether the pager `$PAGER` names is less.
---@param pager string? the value of `PAGER`
---@return boolean less true when its first word has the basename `less`
function M.uses_less(pager)
    local first = pager and pager:match("^%s*(%S+)")
    return first ~= nil and first:match("[^/]*$") == "less"
end

---@class dev.help.PagePlan
---@field page dev.ui.page.Opts the options for `dev.ui.page`
---@field hint boolean whether a paged text ends in the filter hint

---Decide how a text is paged.
---
---A set `PAGER` wins over the built-in pager. Only a `PAGER` that names less gets the filter hint
---and has its `-F` cancelled.
---@param opts { curated: boolean?, no_pager: boolean? }? whether it is the curated view, and
---   whether paging is off
---@param pager string? the value of `PAGER`
---@param dev_pager string? the value of `DEV_PAGER`
---@return dev.help.PagePlan plan the pager options, a curated view paging at any height
function M.page_plan(opts, pager, dev_pager)
    opts = opts or {}
    local plan = { page = { allowed = not opts.no_pager and dev_pager ~= "0" }, hint = false }
    if opts.curated then
        plan.page.rows = 0
        if M.uses_less(pager) then
            plan.hint = true
            plan.page.pager = pager .. LESS_FILTER
        end
    end
    return plan
end

---Append the line that tells a pager's reader how to filter and search.
---@param content string the text a pager will show
---@param c dev.ui.Context the drawing settings, which decide the dim style
---@return string hinted `content` and a blank line and the hint
function M.hinted(content, c)
    return content .. "\n" .. ui.paint(c, FILTER_HINT, Style.DIM) .. "\n"
end

---Refuse a flag or argument a command does not take.
---
---It prints the message and the curated view on standard error, then exits 2.
---@param ctx dev.Ctx the context of the command
---@param reg dev.Registry the project's registry
---@param arg string the argument that is not taken
function M.bad_argument(ctx, reg, arg)
    local message = "Unknown flag " .. arg .. "."
    if arg:sub(1, 1) ~= "-" then
        message = "Unknown argument " .. arg .. "."
    end
    dev_os.stderr:write("dev ", ctx.name, ": ", message, "\n\n")
    dev_os.stderr:write(overview(ctx, reg, screen():stderr(), {}))
    dev_os.exit(2)
end

---Refuse a combination of arguments a command does not take.
---
---It prints `dev: <message>` and the curated view on standard error, then exits 2.
---@param ctx dev.Ctx the context of the command
---@param reg dev.Registry the project's registry
---@param message string what is wrong
function M.usage_error(ctx, reg, message)
    dev_os.stderr:write("dev: ", message, "\n\n")
    dev_os.stderr:write(overview(ctx, reg, screen():stderr(), {}))
    dev_os.exit(2)
end

---Return the topic called `name`, rendered as `dev help <topic>` prints it.
---@param ctx dev.Ctx the context of the command
---@param name string the topic name
---@return string? text the topic, or nil when the project and dev have none
function M.topic_text(ctx, name)
    local file = topic_file(ctx, name)
    return file and topic_source(ctx, file)
end

---Return the curated view as `dev help` prints it.
---@param ctx dev.Ctx the context of the command
---@param reg dev.Registry the project's registry
---@param c dev.ui.Context? the drawing settings, read from the terminal when nil
---@return string text the curated view
function M.overview_text(ctx, reg, c)
    return overview(ctx, reg, c or screen(), {})
end

---Print `content` through the pager.
---
---It pages when it is taller than the screen, and `DEV_PAGER=0` prints it directly. With
---`curated` it pages on any terminal, and with less as the pager it ends in the filter hint and
---cancels a `-F`.
---@param content string the text to show
---@param opts { curated: boolean? }? whether the text is the curated view
function M.page(content, opts)
    page(content, opts)
end

---Print a command's description and its subcommands.
---@param reg dev.Registry the project's registry
---@param name string|string[] the command's words, or its name when it is one word
---@param opts dev.help.parent.Opts? where to print
---@return integer code 0
function M.parent(reg, name, opts)
    local c = screen()
    local words = type(name) == "string" and { name } or name
    if opts and opts.stderr then
        dev_os.stderr:write(M.parent_text(reg, c:stderr(), words))
    else
        dev_os.stdout:write(M.parent_text(reg, c, words))
    end
    return 0
end

---Print each problem the topic check finds as `file:line: message` on standard error.
---
---It loads its own registry with the header warnings silenced.
---@param ctx dev.Ctx the context of the command
---@return integer code 1 when there is a problem, else 0
function M.check_topics(ctx)
    local reg = registry.load(ctx.root, { warn = function() end })
    local problems = topics.check(reg)
    for _, found in ipairs(problems) do
        dev_os.stderr:write(found.file, ":", found.line, ": ", found.message, "\n")
    end
    return #problems > 0 and 1 or 0
end

---Run `dev help`.
---
---With no argument it prints the curated view. `-a` adds the hidden commands,
---`--topics` lists the topics, `-k TOPIC` prints one, `--check-topics` checks them, and a command or
---topic name prints its details. A topic goes through the pager when it is
---taller than the screen, unless `--no-pager` is given or `DEV_PAGER` is `0`.
---@param ctx dev.Ctx the context, whose `args` are the arguments after `help`
---@param reg dev.Registry? the project's registry, loaded when nil
---@return integer code 0, or the process exits 2 on a usage error
function M.run(ctx, reg)
    reg = reg or registry.load(ctx.root)
    local args = {}
    local no_pager = false
    for _, arg in ipairs(ctx.args) do
        if arg == "--no-pager" then
            no_pager = true
        else
            args[#args + 1] = arg
        end
    end
    local first = args[1]
    if first == "-h" then
        return M.command(ctx, reg, { words = { "help" }, short = true })
    elseif first == "--help" then
        return M.command(ctx, reg, { words = { "help" } })
    elseif first == "-a" then
        if #args ~= 1 then
            fail("The -a flag takes no arguments, but got " .. args[2] .. ".")
        end
        dev_os.stdout:write(overview(ctx, reg, screen(), { all = true }))
        return 0
    elseif first == "--topics" then
        if #args ~= 1 then
            fail("The --topics flag takes no arguments, but got " .. args[2] .. ".")
        end
        for _, row in ipairs(topic_rows(ctx)) do
            dev_os.stdout:write(row.name, "\t", row.desc, "\n")
        end
        return 0
    elseif first == "--check-topics" then
        if #args ~= 1 then
            fail("The --check-topics flag takes no arguments, but got " .. args[2] .. ".")
        end
        return M.check_topics(ctx)
    elseif first == "-k" then
        if #args ~= 2 then
            fail("The -k flag needs one help page name.")
        end
        print_topic(ctx, args[2], { no_pager = no_pager })
        return 0
    elseif first and first:sub(1, 1) == "-" then
        fail("Unknown flag " .. first .. ".")
    end
    if #args == 0 then
        return M.overview(ctx, reg, { no_pager = no_pager })
    elseif #args == 1 then
        local row, reason = reg:find({ first })
        if row and row.parent then
            return M.parent(reg, first)
        elseif row then
            return M.command(ctx, reg, { words = { first } })
        elseif reason then
            fail(registry.sentence(reason))
        elseif topic_file(ctx, first) then
            print_topic(ctx, first, { no_pager = no_pager })
        else
            fail("Unknown command " .. first .. ", and no help page has that name.")
        end
    else
        local _, reason = reg:find({ first })
        if reason then
            fail(registry.sentence(reason))
        end
        local parent = { first }
        for i = 2, #args do
            if not reg:is_parent(parent) then
                fail("The command " .. table.concat(parent, " ") .. " has no subcommands.")
            end
            parent[#parent + 1] = args[i]
            if not reg:find(parent) then
                parent[#parent] = nil
                fail("Unknown subcommand " .. args[i] .. " of " .. table.concat(parent, " ") .. ".")
            end
        end
        if reg:is_parent(args) then
            return M.parent(reg, args)
        end
        return M.command(ctx, reg, { words = args })
    end
    return 0
end

return M
