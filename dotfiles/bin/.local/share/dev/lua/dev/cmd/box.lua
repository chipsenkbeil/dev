local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local term = require("dev.term")
local text = require("dev.text")
local ui = require("dev.ui")
local picker = require("dev.ui.picker")
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
    SECONDS_PER_DAY = SECONDS_PER_DAY,
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
---@field machine string|dev.json.Null the machine the box runs on
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

---@class dev.cmd.box.Machine
---@field name string the machine's name
---@field running integer boxes running on it
---@field memory_limits_gib number memory promised to its running boxes
---@field new_box_room_gib number memory a new box could still get
---@field reachable boolean whether ci could ask the machine

---@class dev.cmd.box.Installed
---@field project string the project's name
---@field manifest boolean whether it has a `.dev/tools.tsv`

---@class dev.cmd.box.Doc
---@field ok boolean true for a document ci succeeded with
---@field box dev.cmd.box.Box? the box a one-box subcommand answers about
---@field boxes dev.cmd.box.Box[]? the boxes `ls` lists
---@field cap dev.cmd.box.Cap? the cap `ls` reports
---@field machines dev.cmd.box.Machine[]? the machines `ls` reports
---@field installed dev.cmd.box.Installed[]? the projects `ci box install-tools` handled

---@class dev.cmd.box.Args
---@field target string? the `--target` value
---@field shape string? the `--shape` value
---@field by string? the `--by` value
---@field ttl string? the `--ttl` hours
---@field keep boolean whether `--keep` was given
---@field yes boolean whether `-y` or `--yes` was given
---@field all boolean whether `--all` was given
---@field json boolean whether `--json` was given
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
function M.parse_time(stamp)
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
        local at = M.parse_time(expires)
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
        local at = M.parse_time(delete_after)
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
        json = false,
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
        elseif arg == "--json" then
            parsed.json = true
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
---@return string raw ci's output exactly as it printed it
function M.call(sub, args)
    local argv = { "ci", "box" }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    local raw, code = devos.capture(argv)
    local out = raw:gsub("\n+$", "")
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
    return doc, raw
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

---Say a created box in one line.
---@param box dev.cmd.box.Box the box as ci gives it
---@return string line `Created <name> · <target> @ <machine> · <shape> · <time left> · dev connect <name>`
function M.created_line(box)
    local machine = present(box.machine)
    local left = M.left(box, os.time())
    return string.format(
        "Created %s · %s%s · %s · %s · dev connect %s",
        interp(box.name),
        interp(box.target),
        machine and " @ " .. tostring(machine) or "",
        interp(box.shape),
        left == "" and interp(box.state) or left,
        interp(box.name)
    )
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
    print(M.created_line(created))
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

---Name the user who runs dev.
---@return string? user `USER`, else `LOGNAME`, nil when neither is set
local function current_user()
    for _, name in ipairs({ "USER", "LOGNAME" }) do
        local value = os.getenv(name)
        if value and value ~= "" then
            return value
        end
    end
    return nil
end

---Say what is happening in a box's tmux sessions.
---@param box dev.cmd.box.Box the box as ci gives it
---@return string activity `attached`, `idle 40m`, `?` when unread, `-` when none or not running
function M.activity(box)
    if present(box.state) ~= State.RUNNING then
        return "-"
    end
    local sessions = present(box.tmux_sessions)
    if sessions == nil then
        return "?"
    elseif #sessions == 0 then
        return "-"
    end
    local shortest
    for _, session in ipairs(sessions) do
        if session.attached == true then
            return "attached"
        end
        local idle = present(session.idle_seconds)
        if idle ~= nil and (shortest == nil or idle < shortest) then
            shortest = idle
        end
    end
    return shortest == nil and "idle" or "idle " .. span(shortest)
end

---Say who made a box.
---@param box dev.cmd.box.Box the box as ci gives it
---@param user string? the user who runs dev
---@return string who `you`, `agent`, another human's name, or ci's label as it is
function M.who(box, user)
    local made = cell(box.created_by)
    local human = made:match("^human:(.+)$")
    if human then
        return human == user and "you" or human
    elseif made:find("^agent:") then
        return "agent"
    end
    return made == "" and "-" or made
end

local BAR_WIDTH = 20

---@class dev.cmd.box.BarLine
---@field used number amount filled
---@field total number amount that fills the bar
---@field words string what the numbers say

---Draw a bar and the words beside it, or the words alone off a terminal.
---@param screen dev.ui.Context drawing settings
---@param opts dev.cmd.box.BarLine the fill and the words
---@return string drawn the bar, a space and the words
local function bar_line(screen, opts)
    local bar = ui.bar(screen, { used = opts.used, total = opts.total, width = BAR_WIDTH })
    return bar == "" and opts.words or bar .. " " .. opts.words
end

---Draw the room lines: the hub's Boxes line, then each machine's.
---@param screen dev.ui.Context drawing settings
---@param doc dev.cmd.box.Doc ci's document
---@return string[] lines the room lines
local function room_lines(screen, doc)
    local machines = {}
    if doc.machines then
        machines = doc.machines
    end
    local width = 0
    for _, machine in ipairs(machines) do
        width = math.max(width, text.width(cell(machine.name)))
    end
    local lines = {}
    local cap = doc.cap
    if cap and present(cap.running) ~= nil and present(cap.running_max) ~= nil then
        local more = math.max(cap.running_max - cap.running, 0)
        lines[#lines + 1] = string.rep(" ", width)
            .. (width > 0 and text.GAP or "")
            .. "Boxes   "
            .. bar_line(screen, {
                used = cap.running,
                total = cap.running_max,
                words = string.format(
                    "%d of %d running · %d more can start",
                    cap.running,
                    cap.running_max,
                    more
                ),
            })
    end
    for _, machine in ipairs(machines) do
        local name = cell(machine.name)
        local head = ui.paint(screen, name, ui.Style.BOLD)
            .. string.rep(" ", width - text.width(name))
            .. text.GAP
        if machine.reachable == false then
            lines[#lines + 1] = head .. ui.paint(screen, "unreachable", ui.Style.DIM)
        else
            local blank = string.rep(" ", width) .. text.GAP
            lines[#lines + 1] = head .. string.format("Boxes   %d running", machine.running)
            local used = machine.memory_limits_gib
            local free = machine.new_box_room_gib
            lines[#lines + 1] = blank
                .. "Memory  "
                .. bar_line(screen, {
                    used = used,
                    total = used + free,
                    words = string.format(
                        "%g of %g GiB used · %g GiB free",
                        used,
                        used + free,
                        free
                    ),
                })
        end
    end
    return lines
end

local LS_HEADERS =
    { "NAME", "TARGET", "STATE", "ACTIVITY", "WHO", "SHAPE", "PROJECTS", "TIME LEFT" }

---@class dev.cmd.box.RowOpts
---@field screen dev.ui.Context drawing settings
---@field now integer the current time in seconds since the epoch
---@field user string? the user who runs dev

---The cells of a box's row in `ls`.
---@param box dev.cmd.box.Box the box as ci gives it
---@param opts dev.cmd.box.RowOpts how to draw the row
---@return string[] cells name, target, state, activity, who, shape, projects and time left
local function ls_row(box, opts)
    local screen, now, user = opts.screen, opts.now, opts.user
    local mark = " "
    if present(box.state) == State.RUNNING then
        mark = ui.mark(screen, ui.Mark.RUNNING)
    elseif present(box.state) == State.STOPPED then
        mark = ui.mark(screen, ui.Mark.STOPPED)
    end
    local machine = present(box.machine)
    local left = M.left(box, now)
    return {
        mark .. " " .. ui.paint(screen, cell(box.name), ui.Style.BOLD),
        cell(box.target) .. (machine and " @ " .. tostring(machine) or ""),
        cell(box.state),
        M.activity(box),
        M.who(box, user),
        cell(box.shape),
        project_list(box),
        left == "" and "-" or left,
    }
end

M.handlers["box ls"] = function(ctx)
    local parsed = M.parse(ctx, { "--all", "--json" })
    if #parsed.pos > 0 then
        verb.usage_error(ctx, "unexpected argument " .. parsed.pos[1])
    end
    M.need_ci()
    local args = { "ls", "--json" }
    append_flag(args, "--all", parsed.all)
    local doc, raw = M.call("ls", args)
    if parsed.json then
        io.write(raw)
        return 0
    end
    local screen = ui.context()
    if not screen.interactive then
        screen.width = math.huge
    end
    for _, line in ipairs(room_lines(screen, doc)) do
        print(line)
    end
    local boxes = doc.boxes or {}
    if #boxes == 0 then
        print("no boxes")
        return 0
    end
    local now, user, rows = os.time(), current_user(), {}
    for i, listed in ipairs(boxes) do
        rows[i] = ls_row(listed, { screen = screen, now = now, user = user })
    end
    print()
    for _, line in ipairs(ui.table(screen, LS_HEADERS, rows)) do
        print(line)
    end
    return 0
end

---@class dev.cmd.box.NothingFitsOpts
---@field what string what found no room, such as `no target`
---@field machines string[] the machines whose running boxes could be stopped

local Fit = { START = "start", WAIT = "wait", NEVER = "never" }
local WAITS_FOR_ROOM = "waits for room"
local OS_NAMES = { linux = "Linux", windows = "Windows", macos = "macOS" }

---@class dev.cmd.box.Target
---@field target string the target's name
---@field os string|dev.json.Null `linux`, `windows` or `macos`
---@field machines string[] the machines that host it
---@field image string|dev.json.Null the image its boxes start from
---@field min_shape string|dev.json.Null the smallest shape it takes, null for any
---@field can_take_box_now boolean whether a box could start now
---@field reason string|dev.json.Null why not, when it could not

---@class dev.cmd.box.Fit
---@field machine string the machine
---@field fits string `start`, `wait` or `never`, null when ci could not ask the machine
---@field reason string|dev.json.Null why it waits or never fits
---@field warning string|dev.json.Null what to watch for

---@class dev.cmd.box.ShapeTarget
---@field target string the target's name
---@field below_min boolean whether the shape is under the target's minimum
---@field machines dev.cmd.box.Fit[] how the shape fits each machine

---@class dev.cmd.box.Shape
---@field name string the shape's name
---@field cpu integer processor count
---@field memory_gib number memory in GiB
---@field default boolean whether ci picks it when none is named
---@field targets dev.cmd.box.ShapeTarget[] how it fits each target

---Tell whether the user can answer a picker.
---@return boolean ok whether standard input and output are a terminal
function M.interactive()
    return ui.context().interactive
end

---Name an operating system for a table.
---@param target dev.cmd.box.Target the target as ci gives it
---@return string name `Linux`, `Windows`, `macOS`, or ci's word
local function os_name(target)
    local name = cell(target.os)
    return OS_NAMES[name] or name
end

---Find the smallest shape.
---@param shapes dev.cmd.box.Shape[] the shapes ci lists
---@return string name the name of the shape with the least memory, then the fewest CPUs, `-` for none
local function smallest_shape(shapes)
    local best
    for _, shape in ipairs(shapes) do
        if
            best == nil
            or shape.memory_gib < best.memory_gib
            or (shape.memory_gib == best.memory_gib and shape.cpu < best.cpu)
        then
            best = shape
        end
    end
    return best and cell(best.name) or "-"
end

---Name the least shape a target takes.
---@param target dev.cmd.box.Target the target as ci gives it
---@param shapes dev.cmd.box.Shape[] the shapes ci lists
---@return string name `min_shape`, else the smallest shape
local function min_shape(target, shapes)
    return present(target.min_shape) or smallest_shape(shapes)
end

---Say why a target cannot take a box now.
---@param target dev.cmd.box.Target the target as ci gives it
---@return string reason ci's reason, else a plain one
local function why_not(target)
    local reason = cell(target.reason)
    return reason == "" and "cannot take a box now" or reason
end

---Say how much room a machine has.
---@param machine dev.cmd.box.Machine the machine as ci gives it
---@return string room `53 GiB free`, or `unreachable`
local function room_words(machine)
    if machine.reachable == false then
        return "unreachable"
    end
    local room = present(machine.new_box_room_gib)
    if room == nil then
        return "room unknown"
    end
    return string.format("%g GiB free", math.max(room, 0))
end

---Name a count of boxes that can still start.
---@param cap dev.cmd.box.Cap? the cap ci reports
---@return string words `1 more box`, `2 more boxes`, or an empty string without a cap
local function more_boxes(cap)
    if not cap or present(cap.running) == nil or present(cap.running_max) == nil then
        return ""
    end
    local more = math.max(cap.running_max - cap.running, 0)
    return more .. (more == 1 and " more box" or " more boxes")
end

---List the machines the targets run on, in the order they first appear.
---@param targets dev.cmd.box.Target[] the targets ci lists
---@return string[] names the machine names
local function machines_of(targets)
    local seen, names = {}, {}
    for _, target in ipairs(targets) do
        for _, name in ipairs(target.machines or {}) do
            if not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
    end
    return names
end

---Tell whether a list holds a name.
---@param list string[] the names
---@param name string the name to look for
---@return boolean found whether the list has it
local function has(list, name)
    for _, item in ipairs(list) do
        if item == name then
            return true
        end
    end
    return false
end

---Find a machine by name.
---@param machines dev.cmd.box.Machine[]? the machines ci reports
---@param name string the machine's name
---@return dev.cmd.box.Machine? machine the machine, nil when ci did not report it
local function find_machine(machines, name)
    for _, machine in ipairs(machines or {}) do
        if machine.name == name then
            return machine
        end
    end
    return nil
end

M.handlers["box targets"] = function(ctx)
    local parsed = M.parse(ctx, { "--json" })
    if #parsed.pos > 0 then
        verb.usage_error(ctx, "unexpected argument " .. parsed.pos[1])
    end
    M.need_ci()
    local doc, raw = M.call("targets", { "targets", "--json" })
    if parsed.json then
        io.write(raw)
        return 0
    end
    local targets = doc.targets or {}
    if #targets == 0 then
        print("no targets")
        return 0
    end
    local sized = M.call("targets", { "shapes", "--json" })
    local screen = ui.context()
    if not screen.interactive then
        screen.width = math.huge
    end
    local first = true
    for _, name in ipairs(machines_of(targets)) do
        if not first then
            print()
        end
        first = false
        local machine = find_machine(sized.machines, name)
        local head = ui.paint(screen, name, ui.Style.BOLD)
        if machine then
            local more = more_boxes(sized.cap)
            head = head .. text.GAP .. room_words(machine) .. (more == "" and "" or " · " .. more)
        end
        print(head)
        local rows = {}
        for _, target in ipairs(targets) do
            if has(target.machines or {}, name) then
                local now = { text = "✓ fits", style = { ui.Style.GREEN } }
                if target.can_take_box_now ~= true then
                    now = { text = why_not(target), style = { ui.Style.DIM } }
                end
                rows[#rows + 1] = {
                    cell(target.target),
                    os_name(target),
                    cell(target.image),
                    min_shape(target, sized.shapes or {}),
                    now,
                }
            end
        end
        local headers = { "TARGET", "OS", "IMAGE", "MIN SHAPE", "NOW" }
        for _, line in ipairs(ui.table(screen, headers, rows, { bold_column = 1 })) do
            print("  " .. line)
        end
    end
    return 0
end

---Stop with a message that names the boxes whose machines are full.
---@param opts dev.cmd.box.NothingFitsOpts what found no room, and the machines to look at
local function nothing_fits(opts)
    local running = {}
    for _, listed in ipairs(M.call("create", { "ls", "--json" }).boxes or {}) do
        local on = present(listed.machine)
        if present(listed.state) == State.RUNNING and on then
            for _, name in ipairs(opts.machines) do
                if on == name then
                    running[#running + 1] = cell(listed.name)
                end
            end
        end
    end
    stderr:write(
        "dev box create: ",
        opts.what,
        " fits now, ",
        #running > 0 and "stop a running box to make room: " .. table.concat(running, ", ")
            or "no box is running on its machines",
        "\n"
    )
    os.exit(Exit.FAILED)
end

---Run a picker, ending the run when the user backs out.
---@param items dev.ui.picker.Item[] the rows
---@param opts dev.ui.picker.Opts how to show them
---@return string value the picked row's value
local function choose(items, opts)
    local ok, picked = pcall(picker.run, ui.context(), items, opts)
    if not ok then
        stderr:write("dev box create: ", tostring(picked), "\n")
        os.exit(Exit.FAILED)
    end
    if not picked or picked == "" then
        os.exit(Exit.FAILED)
    end
    return picked
end

---Collect each machine's room into a picker note.
---@param machines dev.cmd.box.Machine[]? the machines ci reports
---@param names string[] the machines to name
---@return string note such as `example-box 53 GiB free`
local function room_note(machines, names)
    local parts = {}
    for _, name in ipairs(names) do
        local machine = find_machine(machines, name)
        if machine then
            parts[#parts + 1] = name .. " " .. room_words(machine)
        end
    end
    return table.concat(parts, ", ")
end

---Sum up how a shape fits the machines that could host a target.
---@param entry dev.cmd.box.ShapeTarget? the shape's entry for the target
---@return string fits `start`, `wait` or `never`, null when ci could not ask the machine
---@return string? note the reason it never fits, or what to watch for
local function fit_of(entry)
    if not entry or entry.below_min == true then
        return Fit.NEVER, nil
    end
    local waits, never_reason
    for _, fit in ipairs(entry.machines or {}) do
        if fit.fits == Fit.WAIT then
            waits = waits or fit
        elseif fit.fits == Fit.START then
            return Fit.START, present(fit.warning)
        else
            never_reason = never_reason or present(fit.reason)
        end
    end
    if waits then
        return Fit.WAIT, present(waits.warning)
    end
    return Fit.NEVER, never_reason
end

---Find how a shape fits a target.
---@param shape dev.cmd.box.Shape the shape
---@param name string the target's name
---@return dev.cmd.box.ShapeTarget? entry the shape's entry for the target
local function shape_entry(shape, name)
    for _, candidate in ipairs(shape.targets or {}) do
        if candidate.target == name then
            return candidate
        end
    end
end

---Sum up whether a target can take a box now, later or never.
---@param target dev.cmd.box.Target the target as ci gives it
---@param shapes dev.cmd.box.Shape[] the shapes ci lists
---@return string fits `start`, `wait` or `never`
local function target_fit(target, shapes)
    if target.can_take_box_now == true then
        return Fit.START
    end
    local least = min_shape(target, shapes)
    for _, shape in ipairs(shapes) do
        if shape.name == least then
            return (fit_of(shape_entry(shape, target.target)))
        end
    end
    return Fit.NEVER
end

---Ask which target the box should run.
---@param project string? the project the box is for
---@return string target the picked target's name
local function pick_target(project)
    local targets = M.call("create", { "targets", "--json" }).targets or {}
    local sized = M.call("create", { "shapes", "--json" })
    local items, enabled = {}, 0
    for i, target in ipairs(targets) do
        local fits = target_fit(target, sized.shapes or {})
        items[i] = {
            value = cell(target.target),
            cells = {
                cell(target.target),
                os_name(target) .. " · " .. cell(target.image),
                "from " .. min_shape(target, sized.shapes or {}),
                "@ " .. table.concat(target.machines or {}, ","),
                fits == Fit.WAIT and WAITS_FOR_ROOM .. " · " .. why_not(target) or nil,
            },
        }
        if fits == Fit.NEVER then
            items[i].disabled = why_not(target)
        else
            enabled = enabled + 1
        end
    end
    local names = machines_of(targets)
    if #targets == 0 then
        stderr:write("dev box create: ci lists no targets\n")
        os.exit(Exit.FAILED)
    end
    if enabled == 0 then
        nothing_fits({ what = "no target", machines = names })
    end
    return choose(items, {
        title = "What should the " .. (project and project .. " " or "") .. "box run?",
        note = room_note(sized.machines, names),
    })
end

---Ask which shape the box should have.
---@param target string the target the box runs
---@return string shape the picked shape's name
local function pick_shape(target)
    local doc = M.call("create", { "shapes", "--target", target, "--json" })
    local items, enabled, initial = {}, 0, nil
    local names = {}
    for i, shape in ipairs(doc.shapes or {}) do
        local entry = shape_entry(shape, target)
        for _, fit in ipairs(entry and entry.machines or {}) do
            names[fit.machine] = true
        end
        local fits, note = fit_of(entry)
        local notes = {}
        if fits == Fit.WAIT then
            notes[1] = WAITS_FOR_ROOM
        end
        if fits ~= Fit.NEVER and note then
            notes[#notes + 1] = note
        end
        items[i] = {
            value = cell(shape.name),
            cells = {
                cell(shape.name),
                cell(shape.cpu) .. " CPU",
                cell(shape.memory_gib) .. " GiB",
                table.concat(notes, " · "),
            },
        }
        if fits == Fit.NEVER then
            items[i].disabled = entry
                    and entry.below_min == true
                    and "below " .. target .. "'s minimum"
                or note
                or "does not fit"
        else
            enabled = enabled + 1
        end
        if shape.default == true then
            initial = cell(shape.name)
        end
    end
    local machines = {}
    for _, machine in ipairs(doc.machines or {}) do
        if names[machine.name] then
            machines[#machines + 1] = machine.name
        end
    end
    if enabled == 0 then
        nothing_fits({ what = "no shape of " .. target, machines = machines })
    end
    return choose(items, {
        title = "Pick a shape for " .. target .. " on " .. table.concat(machines, ", "),
        note = room_note(doc.machines, machines),
        initial = initial,
    })
end

---Ask which target to run and then which shape, as `box create` does on a terminal.
---@param project string? the project the box is for
---@return string target the picked target
---@return string shape the picked shape
function M.pick_create(project)
    local target = pick_target(project)
    return target, pick_shape(target)
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
    local target, shape = parsed.target, parsed.shape
    if M.interactive() and not target then
        target = pick_target(projects[1])
        if not shape then
            shape = pick_shape(target)
        end
    end
    M.create({
        target = target,
        shape = shape,
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

---@class dev.cmd.box.PickOpts
---@field sub string the subcommand's name, for ci's messages
---@field title string the picker's title
---@field keep fun(box: dev.cmd.box.Box): boolean whether the verb can act on a box
---@field none string what to say when no box qualifies
---@field example string? words that follow the example name in the usage error
---@field auto boolean? whether a single row skips the screen
---@field rest boolean? whether more positional arguments may follow the name

---Take the box from the arguments, or pick one on a terminal.
---@param ctx dev.Ctx the subcommand's context
---@param parsed dev.cmd.box.Args the parsed arguments
---@param opts dev.cmd.box.PickOpts how to pick
---@return string name the box name
---@return dev.cmd.box.Box[]? boxes the list ci gave when dev asked for it
local function pick_name(ctx, parsed, opts)
    if #parsed.pos > 0 then
        if not opts.rest and #parsed.pos > 1 then
            verb.usage_error(ctx, "unexpected argument " .. parsed.pos[2])
        end
        check_name(ctx, parsed.pos[1])
        return parsed.pos[1]
    end
    if not M.interactive() then
        verb.usage_error(
            ctx,
            "no box given and no terminal to pick one; pass a name, like dev "
                .. ctx.name
                .. " ci-abc"
                .. (opts.example or "")
        )
    end
    M.need_ci()
    local boxes = M.call(opts.sub, { "ls", "--json" }).boxes or {}
    local now = os.time()
    local items = {}
    for _, candidate in ipairs(boxes) do
        if opts.keep(candidate) then
            items[#items + 1] = { value = candidate.name, cells = M.row(candidate, now) }
        end
    end
    if #items == 0 then
        stderr:write("dev ", ctx.name, ": ", opts.none, "\n")
        os.exit(Exit.FAILED)
    end
    local ok, picked =
        pcall(picker.run, ui.context(), items, { title = opts.title, auto = opts.auto })
    if not ok then
        stderr:write("dev ", ctx.name, ": ", tostring(picked), "\n")
        os.exit(Exit.FAILED)
    end
    if not picked or picked == "" then
        os.exit(Exit.FAILED)
    end
    return picked, boxes
end

---Make a filter for boxes in one state.
---@param state string the state a box must be in
---@return fun(box: dev.cmd.box.Box): boolean keep whether a box is in that state
local function in_state(state)
    return function(candidate)
        return present(candidate.state) == state
    end
end

---Keep every box.
---@return boolean keep always true
local function any_box()
    return true
end

M.handlers["box show"] = function(ctx)
    local parsed = M.parse(ctx, { "--json" })
    local name = pick_name(ctx, parsed, {
        sub = "show",
        title = "Show which box?",
        keep = any_box,
        none = "no boxes to show",
        auto = true,
    })
    M.need_ci()
    local doc, raw = M.call("show", box_args("show", name))
    if parsed.json then
        io.write(raw)
        return 0
    end
    local found = doc.box
    if type(found) ~= "table" then
        verb.die("dev: ci box show printed no box")
    end
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
    local name = pick_name(ctx, M.parse(ctx, {}), {
        sub = "stop",
        title = "Stop which box?",
        keep = in_state(State.RUNNING),
        none = "no running boxes to stop",
        auto = false,
    })
    M.need_ci()
    local stopped = M.one("stop", box_args("stop", name))
    local line = "stopped " .. interp(stopped.name)
    local at = M.parse_time(present(stopped.delete_after))
    if at then
        local days = math.max(math.ceil((at - os.time()) / SECONDS_PER_DAY), 0)
        line = line .. ", deleted in " .. days .. "d unless resumed"
    end
    print(line)
    return 0
end

M.handlers["box resume"] = function(ctx)
    local parsed = M.parse(ctx, { "--ttl", "--keep" })
    local name = pick_name(ctx, parsed, {
        sub = "resume",
        title = "Resume which box?",
        keep = in_state(State.STOPPED),
        none = "no stopped boxes to resume",
        auto = true,
    })
    M.need_ci()
    print(M.summary("resumed", M.one("resume", box_args("resume", name, parsed))))
    return 0
end

M.handlers["box extend"] = function(ctx)
    local parsed = M.parse(ctx, { "--ttl", "--keep" })
    if not parsed.ttl and not parsed.keep then
        verb.usage_error(ctx, "needs --ttl HOURS or --keep")
    end
    local name = pick_name(ctx, parsed, {
        sub = "extend",
        title = "Extend which box?",
        keep = in_state(State.RUNNING),
        none = "no running boxes to extend",
        example = " --keep",
        auto = true,
    })
    M.need_ci()
    print(M.summary("extended", M.one("extend", box_args("extend", name, parsed))))
    return 0
end

M.handlers["box tools install"] = function(ctx)
    local parsed = M.parse(ctx, {})
    local name = pick_name(ctx, parsed, {
        sub = "tools install",
        title = "Install tools on which box?",
        keep = in_state(State.RUNNING),
        none = "no running boxes to install tools on",
        auto = true,
        rest = true,
    })
    local args = box_args("install-tools", name)
    if #parsed.pos > 1 then
        args[#args + 1] = "--"
        for i = 2, #parsed.pos do
            args[#args + 1] = parsed.pos[i]
        end
    end
    M.need_ci()
    local installed = M.call("tools install", args).installed or {}
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

---Tell whether a tmux session is attached to a box.
---@param boxes dev.cmd.box.Box[] the boxes ci lists
---@param name string the box's name
---@return boolean attached whether any session of that box has a client
local function is_attached(boxes, name)
    for _, candidate in ipairs(boxes) do
        if candidate.name == name then
            for _, session in ipairs(present(candidate.tmux_sessions) or {}) do
                if session.attached == true then
                    return true
                end
            end
        end
    end
    return false
end

---Word the question that guards a delete.
---@param name string the box's name
---@param no_archive boolean whether the projects are not archived
---@param attached boolean whether a session is attached
---@return string question what is asked
---@return string consequence what would be lost
function M.delete_prompt(name, no_archive, attached)
    local question, consequence = "Delete " .. name .. "?", "Its projects are archived first."
    if no_archive then
        question, consequence =
            "Delete " .. name .. " without an archive?", "Anything not pushed is lost."
    end
    if attached then
        consequence = "You're attached to it. " .. consequence
    end
    return question, consequence
end

M.handlers["box delete"] = function(ctx)
    local parsed = M.parse(ctx, { "--yes", "-y", "--no-archive" })
    local name, boxes = pick_name(ctx, parsed, {
        sub = "delete",
        title = "Delete which box?",
        keep = any_box,
        none = "no boxes to delete",
        example = " -y",
        auto = false,
    })
    local args = { "delete", name }
    append_flag(args, "--no-archive", parsed.no_archive)
    args[#args + 1] = "--json"
    if not parsed.yes then
        if not can_ask() then
            verb.usage_error(ctx, "no terminal to ask on, pass -y to delete " .. name)
        end
        M.need_ci()
        if not boxes then
            local raw, code = devos.capture({ "ci", "box", "ls", "--json" })
            local doc = code == 0 and json.decode(raw) or nil
            boxes = type(doc) == "table" and doc.boxes or {}
        end
        local question, consequence =
            M.delete_prompt(name, parsed.no_archive, is_attached(boxes, name))
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
        "Deleted "
            .. interp(deleted.name)
            .. " · "
            .. (archive == nil and "no archive" or "archive " .. interp(archive.path))
    )
    return 0
end

return M
