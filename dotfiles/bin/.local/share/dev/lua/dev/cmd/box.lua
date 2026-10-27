local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local term = require("dev.term")
local text = require("dev.text")
local ui = require("dev.ui")
local verb = require("dev.verb")

local present = json.present
local stderr = io.stderr
local MAX_NAME = 40
local SECONDS_PER_MINUTE = 60
local SECONDS_PER_HOUR = 3600
local SECONDS_PER_DAY = 86400
local MISSING_CI = "dev: ci not found on PATH, dev box runs ci box (install it from the ci repo)"
local VALUE_FLAGS = { ["--target"] = true, ["--shape"] = true, ["--by"] = true, ["--ttl"] = true }

---@class dev.cmd.box.State
---@field RUNNING string a box that is up
---@field STOPPED string a box that is stopped and waits to be deleted

---@class dev.cmd.box.Exit
---@field FAILED integer a refusal or a failure of dev's own
---@field NOT_FOUND integer the box does not exist
---@field NOT_READY integer the box is in a state, or lacks a field, that connecting needs

---@class dev.cmd.box
---@field handlers table<string, fun(ctx: dev.Ctx): integer> the handlers of the `box` subcommands
---@field State dev.cmd.box.State the box states dev acts on
---@field Exit dev.cmd.box.Exit the exit codes dev picks itself, ci's own are passed through
local M = {
    handlers = {},
    State = { RUNNING = "running", STOPPED = "stopped" },
    Exit = { FAILED = 1, NOT_FOUND = 3, NOT_READY = 6 },
}

local State, Exit = M.State, M.Exit

---@class dev.cmd.box.Project
---@field name string|dev.json.Null the project's name
---@field path string|dev.json.Null where the project is on the box

---@class dev.cmd.box.Session
---@field name string the tmux session's name
---@field attached boolean whether a client is attached
---@field idle_seconds integer|dev.json.Null seconds since the last use

---@class dev.cmd.box.Archive
---@field path string where ci wrote the archive

---@class dev.cmd.box.Box
---@field name string the box's name
---@field state string `running`, `stopped`, `creating` and so on
---@field target string where the box runs
---@field shape string the size ci gave it
---@field cpu integer processor count
---@field memory_gib number memory in GiB
---@field projects dev.cmd.box.Project[] the projects on the box
---@field tailnet_name string|dev.json.Null the host name on the tailnet
---@field ssh_user string|dev.json.Null the user to log in as, shown for a single box
---@field created_by string who made the box
---@field ttl_hours integer|dev.json.Null the lifetime in hours, null when kept
---@field expires_at string|dev.json.Null RFC 3339 time a running box ends
---@field stopped_at string|dev.json.Null RFC 3339 time the box was stopped
---@field delete_after string|dev.json.Null RFC 3339 time a stopped box is deleted
---@field tmux_sessions dev.cmd.box.Session[]|dev.json.Null the sessions, null when unknown
---@field archive dev.cmd.box.Archive|dev.json.Null the archive of a deleted box
---@field error string|dev.json.Null what went wrong with the box

---@class dev.cmd.box.Cap
---@field running integer boxes running
---@field running_max integer most boxes that may run
---@field memory_limits_gib integer memory promised to running boxes
---@field memory_max_gib integer memory the machines have

---@class dev.cmd.box.Installed
---@field project string the project's name
---@field manifest boolean whether it has a `.dev/tools.tsv`

---@class dev.cmd.box.Doc
---@field ok boolean true for a document ci succeeded with
---@field box dev.cmd.box.Box? the box a one-box subcommand answers about
---@field boxes dev.cmd.box.Box[]? the boxes `ls` lists
---@field cap dev.cmd.box.Cap? the cap `ls` reports
---@field installed dev.cmd.box.Installed[]? the projects `install-tools` handled

---@class dev.cmd.box.Args
---@field target string? the `--target` value
---@field shape string? the `--shape` value
---@field by string? the `--by` value
---@field ttl string? the `--ttl` hours
---@field keep boolean whether `--keep` was given
---@field yes boolean whether `-y` or `--yes` was given
---@field all boolean whether `--all` was given
---@field ssh boolean whether `--ssh` was given
---@field no_archive boolean whether `--no-archive` was given
---@field pos string[] the positional arguments

---@class dev.cmd.box.CreateOpts
---@field target string? the target to create on, ci's default when nil
---@field shape string? the shape to create, ci's default when nil
---@field by string? who asks, `human:` and the user when nil
---@field ttl string? the lifetime in hours
---@field keep boolean whether the box is kept
---@field projects string[] the projects to put on the box

---Render a decoded value for a message, null as `null`.
---@param value any a decoded value
---@return string shown the value as text
local function interp(value)
    value = present(value)
    if value == nil then
        return "null"
    end
    return tostring(value)
end

---Render a decoded value for a table cell, null as nothing.
---@param value any a decoded value
---@return string shown the value as text, or an empty string
local function cell(value)
    value = present(value)
    if value == nil then
        return ""
    end
    return tostring(value)
end

---Count the seconds from the epoch to midnight UTC of a date.
---@param year integer the year
---@param month integer the month, 1 to 12
---@param day integer the day of the month
---@return integer seconds seconds since the epoch
local function midnight(year, month, day)
    if month <= 2 then
        year = year - 1
    end
    local era = math.floor(year / 400)
    local year_of_era = year - era * 400
    local month_index = (month + 9) % 12
    local day_of_year = math.floor((153 * month_index + 2) / 5) + day - 1
    local day_of_era = year_of_era * 365
        + math.floor(year_of_era / 4)
        - math.floor(year_of_era / 100)
        + day_of_year
    return (era * 146097 + day_of_era - 719468) * SECONDS_PER_DAY
end

---Read an RFC 3339 time, with optional fractional seconds and `Z` or an offset.
---@param stamp string? the time as ci writes it
---@return integer? seconds seconds since the epoch, nil when it does not parse
local function parse_time(stamp)
    if type(stamp) ~= "string" then
        return nil
    end
    local y, mo, d, h, mi, s, rest =
        stamp:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
    if not y then
        return nil
    end
    rest = rest:gsub("^%.%d+", "")
    local offset = 0
    if rest ~= "Z" then
        local sign, oh, om = rest:match("^([+-])(%d%d):(%d%d)$")
        if not sign then
            return nil
        end
        offset = (tonumber(oh) * SECONDS_PER_HOUR + tonumber(om) * SECONDS_PER_MINUTE)
            * (sign == "+" and 1 or -1)
    end
    return midnight(tonumber(y), tonumber(mo), tonumber(d))
        + tonumber(h) * SECONDS_PER_HOUR
        + tonumber(mi) * SECONDS_PER_MINUTE
        + tonumber(s)
        - offset
end

---Name a span in its largest whole unit.
---@param seconds number the span
---@return string span days, hours or minutes, such as `6d`
local function span(seconds)
    if seconds >= SECONDS_PER_DAY then
        return math.floor(seconds / SECONDS_PER_DAY) .. "d"
    elseif seconds >= SECONDS_PER_HOUR then
        return math.floor(seconds / SECONDS_PER_HOUR) .. "h"
    end
    return math.floor(seconds / SECONDS_PER_MINUTE) .. "m"
end

---Say how long a box has left.
---@param box dev.cmd.box.Box the box as ci gives it
---@param now integer the current time in seconds since the epoch
---@return string left `3h12m left`, `kept`, `deleted in 6d`, `expired`, `deleted soon`, or an empty string
function M.left(box, now)
    local state = present(box.state)
    local expires = present(box.expires_at)
    local delete_after = present(box.delete_after)
    if state == State.RUNNING then
        if expires == nil then
            return "kept"
        end
        local at = parse_time(expires)
        if not at then
            return ""
        end
        local seconds = math.floor(at - now)
        if seconds <= 0 then
            return "expired"
        elseif seconds >= SECONDS_PER_HOUR then
            return string.format(
                "%dh%dm left",
                math.floor(seconds / SECONDS_PER_HOUR),
                math.floor((seconds % SECONDS_PER_HOUR) / SECONDS_PER_MINUTE)
            )
        end
        return math.floor(seconds / SECONDS_PER_MINUTE) .. "m left"
    elseif state == State.STOPPED and delete_after ~= nil then
        local at = parse_time(delete_after)
        if not at then
            return ""
        end
        local seconds = math.floor(at - now)
        if seconds <= 0 then
            return "deleted soon"
        end
        return "deleted in " .. span(seconds)
    end
    return ""
end

---Name a box's projects.
---@param box dev.cmd.box.Box the box as ci gives it
---@return string names the names joined by commas, or `-` for none
local function project_list(box)
    local names = {}
    for _, project in ipairs(box.projects or {}) do
        names[#names + 1] = interp(project.name)
    end
    if #names == 0 then
        return "-"
    end
    return table.concat(names, ",")
end

---The cells of a box's row in `ls` and in the picker.
---@param box dev.cmd.box.Box the box as ci gives it
---@param now integer the current time in seconds since the epoch
---@return string[] cells name, state, target, projects and time left
function M.row(box, now)
    return {
        cell(box.name),
        cell(box.state),
        cell(box.target),
        project_list(box),
        M.left(box, now),
    }
end

---Pad rows into aligned columns, with no trailing spaces.
---@param rows string[][] the cells of each row
---@return string[] lines one line per row
local function table_lines(rows)
    local widths = {}
    for _, row in ipairs(rows) do
        for c, value in ipairs(row) do
            widths[c] = math.max(widths[c] or 0, text.width(value))
        end
    end
    local lines = {}
    for r, row in ipairs(rows) do
        local parts = {}
        for c, value in ipairs(row) do
            parts[c] = c < #row and value .. string.rep(" ", widths[c] - text.width(value)) or value
        end
        lines[r] = table.concat(parts, text.GAP):gsub(" +$", "")
    end
    return lines
end

---Say a box in one line.
---@param label string the leading word, such as `created`
---@param box dev.cmd.box.Box the box as ci gives it
---@return string line the summary line
function M.summary(label, box)
    local left = M.left(box, os.time())
    return string.format(
        "%s %s (%s, %s, %s), %s, host %s",
        label,
        interp(box.name),
        interp(box.target),
        interp(box.shape),
        project_list(box),
        left == "" and interp(box.state) or left,
        interp(present(box.tailnet_name) or "-")
    )
end

---Refuse unless `ci` is on PATH.
function M.need_ci()
    if not devos.which("ci") then
        verb.die(MISSING_CI)
    end
end

---Parse the arguments of a box subcommand.
---@param ctx dev.Ctx the subcommand's context, whose `name` heads the messages
---@param allowed string[] the flags the subcommand takes
---@return dev.cmd.box.Args parsed the flags and the positional arguments
function M.parse(ctx, allowed)
    local takes = {}
    for _, flag in ipairs(allowed) do
        takes[flag] = true
    end
    local args = ctx.args
    local parsed = {
        keep = false,
        yes = false,
        all = false,
        ssh = false,
        no_archive = false,
        pos = {},
    }
    local i = 1
    while i <= #args do
        local arg = args[i]
        i = i + 1
        if #arg > 1 and arg:sub(1, 1) == "-" and not takes[arg] then
            verb.usage_error(ctx, "unknown flag " .. arg)
        end
        if VALUE_FLAGS[arg] then
            if i > #args then
                verb.usage_error(ctx, arg .. " needs a value")
            end
            local value = args[i]
            i = i + 1
            if arg == "--ttl" then
                if not value:find("^[1-9]%d*$") then
                    verb.usage_error(ctx, "--ttl is a whole number of hours, not " .. value)
                end
                parsed.ttl = value
            else
                parsed[arg:sub(3)] = value
            end
        elseif arg == "--keep" then
            parsed.keep = true
        elseif arg == "-y" or arg == "--yes" then
            parsed.yes = true
        elseif arg == "--no-archive" then
            parsed.no_archive = true
        elseif arg == "--all" then
            parsed.all = true
        elseif arg == "--ssh" then
            parsed.ssh = true
        else
            parsed.pos[#parsed.pos + 1] = arg
        end
    end
    if parsed.ttl and parsed.keep then
        verb.usage_error(ctx, "--ttl and --keep cannot be combined")
    end
    return parsed
end

---Check a box name.
---@param name string the name as typed
---@return boolean ok whether it is 1 to 40 of a-z, 0-9 and -
local function valid_name(name)
    return #name <= MAX_NAME and name:find("^[a-z0-9%-]+$") ~= nil
end

---Refuse a box name that breaks the rule.
---@param ctx dev.Ctx the subcommand's context
---@param name string the name as typed
local function check_name(ctx, name)
    if not valid_name(name) then
        verb.usage_error(
            ctx,
            "bad box name " .. name .. ", a name is 1 to " .. MAX_NAME .. " of a-z, 0-9 and -"
        )
    end
end

---Take the one positional argument as a checked box name.
---@param ctx dev.Ctx the subcommand's context
---@param parsed dev.cmd.box.Args the parsed arguments
---@return string name the box name
function M.one_name(ctx, parsed)
    if #parsed.pos == 0 then
        verb.usage_error(ctx, "needs a box name")
    end
    if #parsed.pos > 1 then
        verb.usage_error(ctx, "unexpected argument " .. parsed.pos[2])
    end
    check_name(ctx, parsed.pos[1])
    return parsed.pos[1]
end

---Run `ci box` with `--json` and decode its document.
---
---A failure ends the run with ci's code, after its error message goes to
---standard error, or its output when it is no error document.
---@param sub string the subcommand's name, for the messages
---@param args string[] the arguments after `ci box`
---@return dev.cmd.box.Doc doc the decoded `ok` document
function M.call(sub, args)
    local argv = { "ci", "box" }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    local out, code = devos.capture(argv)
    out = out:gsub("\n+$", "")
    local doc = json.decode(out)
    if code ~= 0 then
        local message = type(doc) == "table"
            and doc.ok == false
            and type(doc.error) == "table"
            and doc.error.message
        if type(message) == "string" then
            stderr:write("dev box ", sub, ": ", message, "\n")
        elseif out ~= "" then
            stderr:write(out, "\n")
        end
        os.exit(code or Exit.FAILED)
    end
    if type(doc) ~= "table" or doc.ok ~= true then
        verb.die("dev: ci box " .. args[1] .. " printed no ok document")
    end
    return doc
end

---Run `ci box` for a subcommand that answers with one box.
---@param sub string the subcommand's name, for the messages
---@param args string[] the arguments after `ci box`
---@return dev.cmd.box.Box box the box in ci's document
function M.one(sub, args)
    local found = M.call(sub, args).box
    if type(found) ~= "table" then
        verb.die("dev: ci box " .. args[1] .. " printed no box")
    end
    return found
end

---The default project: the project root's directory name.
---@param root string absolute path of the project root
---@return string? name the name, or nil outside a project or for a name that starts with `-`
function M.default_project(root)
    if
        not (fs.is_dir(root .. "/.jj") or fs.exists(root .. "/.git") or fs.is_dir(root .. "/.dev"))
    then
        return nil
    end
    local name = root:match("([^/]+)/*$")
    if not name then
        return nil
    end
    if name:sub(1, 1) == "-" then
        stderr:write(
            "dev box: not using ",
            name,
            " as the default project, a project name cannot start with -\n"
        )
        return nil
    end
    return name
end

---Add a flag to an argument list, with its value when it has one.
---@param args string[] the list to extend
---@param flag string the flag, such as `--ttl`
---@param value string|boolean|nil the flag's value, `true` for a bare flag, nil or false to add nothing
local function append_flag(args, flag, value)
    if not value then
        return
    end
    args[#args + 1] = flag
    if value ~= true then
        args[#args + 1] = value
    end
end

---Work out who asks for a box.
---@param by string? the `--by` label, if given
---@return string by the label, `human:` and the user otherwise
local function requester(by)
    if by then
        return by
    end
    local user, logname = os.getenv("USER"), os.getenv("LOGNAME")
    if user and user ~= "" then
        return "human:" .. user
    elseif logname and logname ~= "" then
        return "human:" .. logname
    end
    verb.die("dev: dev box create: neither USER nor LOGNAME is set, pass --by LABEL")
    return ""
end

---Create a box and print its summary.
---@param opts dev.cmd.box.CreateOpts what to create
---@return dev.cmd.box.Box box the created box
function M.create(opts)
    local args = { "create" }
    append_flag(args, "--target", opts.target)
    append_flag(args, "--shape", opts.shape)
    append_flag(args, "--by", requester(opts.by))
    append_flag(args, "--ttl", opts.ttl)
    append_flag(args, "--keep", opts.keep)
    args[#args + 1] = "--json"
    if #opts.projects > 0 then
        args[#args + 1] = "--"
        for _, project in ipairs(opts.projects) do
            args[#args + 1] = project
        end
    end
    local created = M.one("create", args)
    print(M.summary("created", created))
    return created
end

---Build the arguments of a one-box subcommand.
---@param sub string the ci subcommand
---@param name string the box name
---@param parsed dev.cmd.box.Args? the parsed arguments, for the lifetime flags
---@return string[] args the arguments after `ci box`
local function box_args(sub, name, parsed)
    local args = { sub, name }
    if parsed then
        append_flag(args, "--ttl", parsed.ttl)
        append_flag(args, "--keep", parsed.keep)
    end
    args[#args + 1] = "--json"
    return args
end

M.handlers["box ls"] = function(ctx)
    local parsed = M.parse(ctx, { "--all" })
    if #parsed.pos > 0 then
        verb.usage_error(ctx, "unexpected argument " .. parsed.pos[1])
    end
    M.need_ci()
    local args = { "ls", "--json" }
    append_flag(args, "--all", parsed.all)
    local doc = M.call("ls", args)
    local boxes = doc.boxes or {}
    if #boxes == 0 then
        print("no boxes")
    else
        local now, rows = os.time(), {}
        for i, listed in ipairs(boxes) do
            rows[i] = M.row(listed, now)
        end
        for _, line in ipairs(table_lines(rows)) do
            print(line)
        end
    end
    local cap = doc.cap or {}
    print(
        string.format(
            "%s of %s running, %s of %s GiB",
            interp(cap.running),
            interp(cap.running_max),
            interp(cap.memory_limits_gib),
            interp(cap.memory_max_gib)
        )
    )
    return 0
end

M.handlers["box create"] = function(ctx)
    local parsed = M.parse(ctx, { "--target", "--shape", "--by", "--ttl", "--keep" })
    M.need_ci()
    local projects = parsed.pos
    if #projects == 0 then
        local project = M.default_project(ctx.root)
        if project then
            projects = { project }
        end
    end
    M.create({
        target = parsed.target,
        shape = parsed.shape,
        by = parsed.by,
        ttl = parsed.ttl,
        keep = parsed.keep,
        projects = projects,
    })
    return 0
end

---Render a box's tmux sessions.
---@param found dev.cmd.box.Box the box as ci gives it
---@return string sessions `unknown`, `none` or the sessions with their state
local function tmux_text(found)
    local sessions = present(found.tmux_sessions)
    if sessions == nil then
        return "unknown"
    elseif #sessions == 0 then
        return "none"
    end
    local items = {}
    for i, session in ipairs(sessions) do
        local state = session.attached == true and "attached"
            or "idle " .. span(present(session.idle_seconds) or 0)
        items[i] = interp(session.name) .. " (" .. state .. ")"
    end
    return table.concat(items, ", ")
end

M.handlers["box show"] = function(ctx)
    local name = M.one_name(ctx, M.parse(ctx, {}))
    M.need_ci()
    local found = M.one("show", box_args("show", name))
    local lines = {
        "name: " .. interp(found.name),
        "state: " .. interp(found.state),
        "target: " .. interp(found.target),
        "shape: " .. interp(found.shape),
        "cpu: " .. interp(found.cpu),
        "memory_gib: " .. interp(found.memory_gib),
        "projects: " .. project_list(found),
        "tailnet_name: " .. interp(present(found.tailnet_name) or "-"),
        "created_by: " .. interp(found.created_by),
        "ttl_hours: " .. interp(present(found.ttl_hours) or "kept"),
    }
    for _, key in ipairs({ "expires_at", "stopped_at", "delete_after" }) do
        if present(found[key]) ~= nil then
            lines[#lines + 1] = key .. ": " .. interp(found[key])
        end
    end
    if found.state == State.RUNNING then
        lines[#lines + 1] = "tmux_sessions: " .. tmux_text(found)
    end
    local archive = present(found.archive)
    if archive ~= nil then
        lines[#lines + 1] = "archive: " .. interp(archive.path)
    end
    if present(found.error) ~= nil then
        lines[#lines + 1] = "error: " .. interp(found.error)
    end
    print(table.concat(lines, "\n"))
    return 0
end

M.handlers["box stop"] = function(ctx)
    local name = M.one_name(ctx, M.parse(ctx, {}))
    M.need_ci()
    local stopped = M.one("stop", box_args("stop", name))
    local line = "stopped " .. interp(stopped.name)
    local at = parse_time(present(stopped.delete_after))
    if at then
        local days = math.max(math.ceil((at - os.time()) / SECONDS_PER_DAY), 0)
        line = line .. ", deleted in " .. days .. "d unless resumed"
    end
    print(line)
    return 0
end

M.handlers["box resume"] = function(ctx)
    local parsed = M.parse(ctx, { "--ttl", "--keep" })
    local name = M.one_name(ctx, parsed)
    M.need_ci()
    print(M.summary("resumed", M.one("resume", box_args("resume", name, parsed))))
    return 0
end

M.handlers["box extend"] = function(ctx)
    local parsed = M.parse(ctx, { "--ttl", "--keep" })
    local name = M.one_name(ctx, parsed)
    if not parsed.ttl and not parsed.keep then
        verb.usage_error(ctx, "needs --ttl HOURS or --keep")
    end
    M.need_ci()
    print(M.summary("extended", M.one("extend", box_args("extend", name, parsed))))
    return 0
end

M.handlers["box install-tools"] = function(ctx)
    local parsed = M.parse(ctx, {})
    if #parsed.pos == 0 then
        verb.usage_error(ctx, "needs a box name")
    end
    local name = parsed.pos[1]
    check_name(ctx, name)
    local args = box_args("install-tools", name)
    if #parsed.pos > 1 then
        args[#args + 1] = "--"
        for i = 2, #parsed.pos do
            args[#args + 1] = parsed.pos[i]
        end
    end
    M.need_ci()
    local installed = M.call("install-tools", args).installed or {}
    if #installed == 0 then
        print("no projects")
    end
    for _, item in ipairs(installed) do
        if item.manifest == true then
            print(interp(item.project) .. ": tools installed")
        else
            print(interp(item.project) .. ": no .dev/tools.tsv, nothing installed")
        end
    end
    return 0
end

---Tell whether a question can be asked on the controlling terminal.
---@return boolean ok whether `/dev/tty` opens
local function can_ask()
    local tty = io.open(term.TTY_PATH, "r")
    if not tty then
        return false
    end
    tty:close()
    return true
end

M.handlers["box delete"] = function(ctx)
    local parsed = M.parse(ctx, { "--yes", "-y", "--no-archive" })
    local name = M.one_name(ctx, parsed)
    local question, consequence = "Delete " .. name .. "?", "Its projects are archived first."
    local args = { "delete", name }
    if parsed.no_archive then
        question, consequence =
            "Delete " .. name .. " without an archive?", "Anything not pushed is lost."
    end
    append_flag(args, "--no-archive", parsed.no_archive)
    args[#args + 1] = "--json"
    if not parsed.yes then
        if not can_ask() then
            verb.usage_error(ctx, "no terminal to ask on, pass -y to delete " .. name)
        end
        local screen = ui.context({ interactive = true, color = false })
        if not ui.confirm(screen, question, consequence) then
            stderr:write("not deleted\n")
            return Exit.FAILED
        end
    end
    M.need_ci()
    local deleted = M.one("delete", args)
    local archive = present(deleted.archive)
    print(
        "deleted "
            .. interp(deleted.name)
            .. ", "
            .. (archive == nil and "no archive" or "archive " .. interp(archive.path))
    )
    return 0
end

return M
