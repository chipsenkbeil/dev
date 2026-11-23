local box = require("dev.cmd.box")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local picker = require("dev.ui.picker")
local ui = require("dev.ui")
local dev_command = require("dev.command")
local xdg = require("dev.xdg")

local present = json.present
local stderr = io.stderr
local State, Exit = box.State, box.Exit
local PROJECTS_DIR = "/srv/projects"
local NEW_VALUE = "__new__"
local MAX_DIR_NAME = 64
local MAX_USER = 32
local MAX_HOST = 253
local MAX_NAME = 40
local NO_CONNECT = 2
local OLD_CI_MESSAGE = "no box config"

---@class dev.cmd.connect
---@field handlers table<string, fun(ctx: dev.Ctx): integer> the handlers of `connect` and
---   `box connect`
local M = { handlers = {} }

---@class dev.cmd.connect.attach.Opts
---@field ssh boolean whether to go through `ci ssh` instead of `et`

---Say why connecting stops.
---@param message string what is wrong, as a sentence
local function say(message)
    dev_command.note(message)
end

---Say why a box cannot be connected to yet and exit.
---@param message string what is missing
local function not_ready(message)
    say(message)
    os.exit(Exit.NOT_READY)
end

---Find the file where ci keeps the host keys of the boxes it shows.
---@return string path the known_hosts file
local function known_hosts()
    return xdg.state_home() .. "/ci/known_hosts"
end

---Check a project directory against the names ci can make.
---@param dir string the directory on the box
---@return boolean ok whether it is `/srv/projects` or one name below it
local function safe_dir(dir)
    if dir == PROJECTS_DIR then
        return true
    end
    local name = dir:match("^" .. PROJECTS_DIR .. "/([A-Za-z0-9][A-Za-z0-9._%-]*)$")
    return name ~= nil and #name <= MAX_DIR_NAME
end

---Check a login name before it can reach an ssh command line.
---@param user string the name ci gave
---@return boolean ok whether it is a plain account name
local function safe_user(user)
    return #user <= MAX_USER and user:find("^[a-z_][a-z0-9_%-]*$") ~= nil
end

---Check a host name before it can reach an ssh command line.
---@param host string the name ci gave
---@return boolean ok whether it is a plain host name
local function safe_host(host)
    return #host <= MAX_HOST and host:find("^[A-Za-z0-9][A-Za-z0-9.%-]*$") ~= nil
end

---Write a value with every unusual character as a hex escape.
---@param value string the text
---@return string shown the text that is safe to print
local function printable(value)
    return (
        value:gsub("[^%w/._%-]", function(char)
            return string.format("\\x%02x", char:byte())
        end)
    )
end

---Replace this process with a command, or say it cannot run.
---@param argv string[] the command and its arguments
---@return integer code the exit code of a command that could not start
local function exec(argv)
    local _, message = dev_os.exec(argv)
    dev_command.note("Cannot run " .. argv[1] .. ". " .. message)
    return dev_os.EXEC_FAILED
end

---Name the ssh host that ci's config reaches a connectable by.
---@param name string the connectable's name
---@return string alias the name itself when it starts with `ci-`, else `ci-<name>`
local function alias(name)
    if name:sub(1, 3) == "ci-" then
        return name
    end
    return "ci-" .. name
end

---Refuse a field of the box that is missing or not a plain value.
---@param name string the box's name
---@param field string the field, `tailnet_name` or `ssh_user`
---@param value string|dev.json.Null|nil what ci sent
---@param valid fun(value: string): boolean the rule the value must meet
---@return string value the valid value
local function checked(name, field, value, valid)
    value = present(value)
    if type(value) ~= "string" or value == "" then
        not_ready("The box " .. name .. " has no " .. field .. " yet.")
    end
    if not valid(value) then
        not_ready("The box " .. name .. " has an invalid " .. field .. ".")
    end
    return value
end

---Attach to a running box, over `et` or over `ci ssh`.
---@param found dev.cmd.box.Box the box to attach to
---@param opts dev.cmd.connect.attach.Opts how to attach
---@return integer code the exit code of a hand-off that could not start
local function attach(found, opts)
    local name = found.name
    local state = tostring(present(found.state))
    local host = present(found.tailnet_name)
    if type(host) ~= "string" or host == "" then
        not_ready("The box " .. name .. " has no tailnet name yet (state " .. state .. ").")
    end
    checked(name, "tailnet_name", host, safe_host)
    local projects = found.projects or {}
    local first = projects[1]
    if first and present(first.path) == nil then
        not_ready("The box " .. name .. " has no project path yet (state " .. state .. ").")
    end
    local dir = first and present(first.path) or PROJECTS_DIR
    if not safe_dir(dir) then
        say("Refusing the project path '" .. printable(dir) .. "' of " .. name .. ".")
        os.exit(Exit.FAILED)
    end
    local session = tostring((first and present(first.name)) or name):gsub("[^A-Za-z0-9_-]", "_")
    local over_ssh = opts.ssh
    if not over_ssh and not dev_os.which("et") then
        say("The et command was not found. Using ssh.")
        over_ssh = true
    end
    if over_ssh then
        if present(found.ssh_user) ~= nil then
            checked(name, "ssh_user", found.ssh_user, safe_user)
        end
        return exec({
            "ci",
            "ssh",
            name,
            "--",
            "tmux",
            "new",
            "-A",
            "-s",
            session,
            "-c",
            dir,
        })
    end
    local shown = box.one("connect", { "show", name, "--json" })
    local shown_host = present(shown.tailnet_name)
    local shown_user = present(shown.ssh_user)
    if
        type(shown_host) ~= "string"
        or shown_host == ""
        or type(shown_user) ~= "string"
        or shown_user == ""
    then
        not_ready(
            "The box "
                .. name
                .. " has no tailnet name or ssh user (state "
                .. tostring(present(shown.state))
                .. ")."
        )
    end
    shown_host = checked(name, "tailnet_name", shown_host, safe_host)
    shown_user = checked(name, "ssh_user", shown_user, safe_user)
    return exec({
        "et",
        "--ssh-option",
        "UserKnownHostsFile=" .. known_hosts(),
        "--ssh-option",
        "StrictHostKeyChecking=yes",
        "-c",
        "tmux new -A -s " .. session .. " -c " .. dir,
        shown_user .. "@" .. shown_host,
    })
end

---@class dev.cmd.connect.Connectable
---@field name string what `ssh <alias>` reaches, the alias being the name or `ci-<name>`
---@field machine string? the machine it runs on
---@field kind string? what it is, always `host` for the rows dev keeps
---@field user string? the login name
---@field state string? what ci says it is doing

---@class dev.cmd.connect.connectables.Opts
---@field strict boolean whether a failure must end the run

---Print what ci said when `ci ssh config` or `ci ssh ls` failed, as one line.
---@param raw string ci's output
local function connect_failed(raw)
    local out = raw:gsub("\n+$", "")
    local doc = json.decode(out)
    local message = type(doc) == "table" and type(doc.error) == "table" and doc.error.message
    if type(message) ~= "string" then
        message = out
    end
    local shown = message:match("^[^\n]*")
    for line in message:gmatch("[^\n]+") do
        if line:find("^error:") then
            shown = line
            break
        end
    end
    message = shown
    if message ~= "" then
        dev_command.note("Ci said: " .. message:gsub("[^\32-\126]", " "))
    end
end

---Tell whether a name from ci can reach an ssh command line as `ci-<name>`.
---@param name any the value ci gave
---@return boolean ok whether it is 1 to 40 of a-z, 0-9 and -
local function safe_name(name)
    return type(name) == "string" and #name <= MAX_NAME and name:find("^[a-z0-9%-]+$") ~= nil
end

---Keep the printable ASCII of a note from ci.
---@param text string the note
---@return string shown the note with unprintable bytes replaced
local function plain(text)
    return (text:gsub("[^\32-\126]", " "))
end

---Run a ci command, keeping its standard error apart from its output.
---
---On success the standard error goes through to the terminal unchanged. On
---failure it is returned as the text to report. Without a temporary file ci
---writes to the terminal directly.
---@param argv string[] the ci command
---@return string output what ci wrote to standard output, or its standard error when it failed
---@return integer? code exit status of the command
local function capture_ci(argv)
    local errfile = fs.mktemp({ prefix = "dev-connect" })
    if not errfile then
        dev_command.note("Cannot make a temporary path for the standard error of ci.")
        return dev_os.capture(argv)
    end
    local ok, out, code = pcall(dev_os.capture, argv, { stderr = errfile })
    local detail = fs.read(errfile) or ""
    fs.remove(errfile)
    if not ok then
        error(out, 0)
    end
    if code ~= 0 then
        return detail, code
    end
    stderr:write(detail)
    return out, code
end

---Write ci's ssh_config and list the hosts of `ci ssh ls`, apart from boxes and sessions.
---
---A ci with no `ssh config` exits 2, which shows boxes only, with one note. An
---older ci that reads `config` as a box name exits 1 with `no box config`,
---which counts the same.
---Any other failure prints ci's message as one line, then ends the run with
---ci's code when `strict` is set and lists boxes only otherwise.
---@param opts dev.cmd.connect.connectables.Opts how to treat a failure
---@return dev.cmd.connect.Connectable[] found the connectables, in ci's order
local function connectables(opts)
    local raw, code = capture_ci({ "ci", "ssh", "config" })
    local old_ci = code == 1 and raw:find(OLD_CI_MESSAGE, 1, true) ~= nil
    if code == 0 then
        raw, code = capture_ci({ "ci", "ssh", "ls", "--json" })
    end
    if code == NO_CONNECT or old_ci then
        dev_command.note("This ci has no ssh command, so only the boxes are listed.")
        return {}
    end
    if code ~= 0 then
        connect_failed(raw)
        if opts.strict then
            os.exit(code or Exit.FAILED)
        end
        return {}
    end
    local doc = json.decode((raw:gsub("\n+$", "")))
    if type(doc) ~= "table" then
        dev_command.die("The `ci ssh ls` command printed no document.")
    end
    for _, note in ipairs(type(doc.notes) == "table" and doc.notes or {}) do
        if type(note) == "string" then
            dev_command.note("Ci said: " .. plain(note))
        end
    end
    local found = {}
    for _, entry in ipairs(type(doc.things) == "table" and doc.things or {}) do
        if type(entry) == "table" and entry.kind == "host" then
            if safe_name(entry.name) then
                found[#found + 1] = entry
            else
                dev_command.note("Skipping a connectable with an invalid name.")
            end
        end
    end
    local listed = {}
    for _, entry in ipairs(found) do
        listed[entry.name] = true
    end
    local kept = {}
    for _, entry in ipairs(found) do
        local reached = alias(entry.name)
        if reached ~= entry.name and listed[reached] then
            dev_command.note(
                "Skipping "
                    .. entry.name
                    .. ", because its alias "
                    .. reached
                    .. " is the name of another connectable."
            )
        else
            kept[#kept + 1] = entry
        end
    end
    return kept
end

---The cells of a connectable's row in the picker.
---@param entry dev.cmd.connect.Connectable the connectable
---@return string[] cells name, state, kind, machine and user
local function connectable_row(entry)
    local function cell(value)
        value = present(value)
        if type(value) ~= "string" or value == "" then
            return "-"
        end
        return plain(value)
    end
    return {
        entry.name,
        cell(entry.state),
        cell(entry.kind),
        cell(entry.machine),
        cell(entry.user),
    }
end

---Tell whether a box carries a project.
---@param candidate dev.cmd.box.Box the box
---@param project string the project's name
---@return boolean found whether one of its projects has that name
local function in_project(candidate, project)
    for _, entry in ipairs(candidate.projects or {}) do
        if entry.name == project then
            return true
        end
    end
    return false
end

---Make the picker's rows: the project's boxes, the others, the connectables, then a new-box row.
---@param boxes dev.cmd.box.Box[] the boxes ci lists
---@param others dev.cmd.connect.Connectable[] the connectables ci lists
---@param project string the current project, empty outside one
---@return dev.ui.picker.Item[] items the rows
local function items_for(boxes, others, project)
    local now = os.time()
    local ordered = {}
    for _, wanted in ipairs({ true, false }) do
        for _, candidate in ipairs(boxes) do
            if in_project(candidate, project) == wanted then
                ordered[#ordered + 1] = candidate
            end
        end
    end
    local items = {}
    for i, candidate in ipairs(ordered) do
        items[i] = { value = candidate.name, cells = box.row(candidate, now) }
    end
    for _, entry in ipairs(others) do
        items[#items + 1] = { value = entry.name, cells = connectable_row(entry) }
    end
    if project ~= "" then
        items[#items + 1] = { value = NEW_VALUE, cells = { "new box for " .. project } }
    end
    return items
end

---Ask which box or connectable to connect to.
---@param boxes dev.cmd.box.Box[] the boxes ci lists
---@param others dev.cmd.connect.Connectable[] the connectables ci lists
---@param project string the current project, empty outside one
---@return string value the picked name, or `__new__`
local function choose(boxes, others, project)
    local items = items_for(boxes, others, project)
    if #items == 0 then
        dev_command.note("There are no boxes. Create one with dev box create.")
        os.exit(Exit.FAILED)
    end
    if not box.interactive() then
        dev_command.usage_error(
            { name = "box connect" },
            "No box given and no terminal to pick one. Pass a name, like dev box connect ci-abc."
        )
    end
    local opts = {
        title = "Connect to a box",
        auto = not (#items == 1 and project ~= ""),
    }
    local ok, picked = pcall(picker.run, ui.context(), items, opts)
    if not ok then
        say(tostring(picked))
        os.exit(Exit.FAILED)
    end
    if not picked or picked == "" then
        os.exit(Exit.FAILED)
    end
    return picked
end

---Tell whether ci lists a box with a name.
---@param boxes dev.cmd.box.Box[] the boxes ci lists
---@param name string the name
---@return boolean found whether one of the boxes has it
local function has_box(boxes, name)
    for _, candidate in ipairs(boxes) do
        if candidate.name == name then
            return true
        end
    end
    return false
end

---Connect to a box or a connectable, picking, resuming or creating one first.
---@param ctx dev.Ctx the context of `connect` or `box connect`
---@return integer code the exit code of a hand-off that could not start
local function run(ctx)
    ctx.name = "box connect"
    local parsed = box.parse(ctx, { "--ssh" })
    if #parsed.pos > 1 then
        dev_command.usage_error(ctx, "unexpected argument " .. parsed.pos[2])
    end
    local given
    if #parsed.pos == 1 then
        given = box.one_name(ctx, parsed)
    end
    box.need_ci()
    local project = box.default_project(ctx.root) or ""
    local boxes = box.call("connect", { "ls", "--json" }).boxes or {}
    local others = {}
    if not given or not has_box(boxes, given) then
        others = connectables({ strict = given ~= nil })
    end
    local choice = given or choose(boxes, others, project)
    local found
    for _, entry in ipairs(others) do
        if entry.name == choice and not has_box(boxes, choice) then
            return exec({ "ssh", alias(entry.name) })
        end
    end
    if choice == NEW_VALUE then
        local target, shape
        if box.interactive() then
            target, shape = box.pick_create(project ~= "" and project or nil)
        end
        found = box.create({
            target = target,
            shape = shape,
            keep = false,
            projects = project ~= "" and { project } or {},
        })
    else
        for _, candidate in ipairs(boxes) do
            if candidate.name == choice then
                found = candidate
            end
        end
        if not found then
            say("No box is named " .. choice .. ".")
            os.exit(Exit.NOT_FOUND)
        end
        local state = present(found.state)
        if state == State.STOPPED then
            found = box.one("connect", { "resume", choice, "--json" })
            print(box.summary("resumed", found))
        elseif state ~= State.RUNNING then
            not_ready(
                "The box "
                    .. choice
                    .. " is "
                    .. tostring(state)
                    .. ". It must be running or stopped to connect."
            )
        end
    end
    return attach(found, { ssh = parsed.ssh })
end

M.handlers["connect"] = run
M.handlers["box connect"] = run

return M
