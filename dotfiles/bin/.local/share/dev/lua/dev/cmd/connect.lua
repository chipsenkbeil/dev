local box = require("dev.cmd.box")
local devos = require("dev.os")
local json = require("dev.json")
local picker = require("dev.ui.picker")
local ui = require("dev.ui")
local verb = require("dev.verb")

local present = json.present
local stderr = io.stderr
local State, Exit = box.State, box.Exit
local PROJECTS_DIR = "/srv/projects"
local NEW_VALUE = "__new__"
local MAX_DIR_NAME = 64
local MAX_USER = 32
local MAX_HOST = 253

---@class dev.cmd.connect
---@field handlers table<string, fun(ctx: dev.Ctx): integer> the handlers of `connect` and `box connect`
local M = { handlers = {} }

---@class dev.cmd.connect.AttachOpts
---@field ssh boolean whether to go through `ci box ssh` instead of `et`

---Say why connecting stops, in the voice of `dev box connect`.
---@param message string what is wrong
local function say(message)
    stderr:write("dev box connect: ", message, "\n")
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
    local state = os.getenv("XDG_STATE_HOME")
    if not state or state:sub(1, 1) ~= "/" then
        state = os.getenv("HOME") .. "/.local/state"
    end
    return state .. "/ci/known_hosts"
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
    local _, message = devos.exec(argv)
    stderr:write("dev: cannot run ", argv[1], ": ", message, "\n")
    return devos.EXEC_FAILED
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
        not_ready(name .. " has no " .. field .. " yet")
    end
    if not valid(value) then
        not_ready(name .. " has an invalid " .. field)
    end
    return value
end

---Attach to a running box, over `et` or over `ci box ssh`.
---@param found dev.cmd.box.Box the box to attach to
---@param opts dev.cmd.connect.AttachOpts how to attach
---@return integer code the exit code of a hand-off that could not start
local function attach(found, opts)
    local name = found.name
    local state = tostring(present(found.state))
    local host = present(found.tailnet_name)
    if type(host) ~= "string" or host == "" then
        not_ready(name .. " has no tailnet name yet (state " .. state .. ")")
    end
    checked(name, "tailnet_name", host, safe_host)
    local projects = found.projects or {}
    local first = projects[1]
    if first and present(first.path) == nil then
        not_ready(name .. " has no project path yet (state " .. state .. ")")
    end
    local dir = first and present(first.path) or PROJECTS_DIR
    if not safe_dir(dir) then
        say("refusing the project path '" .. printable(dir) .. "' of " .. name)
        os.exit(Exit.FAILED)
    end
    local session = tostring((first and present(first.name)) or name):gsub("[^A-Za-z0-9_-]", "_")
    local over_ssh = opts.ssh
    if not over_ssh and not devos.which("et") then
        say("et not found, using ssh")
        over_ssh = true
    end
    if over_ssh then
        if present(found.ssh_user) ~= nil then
            checked(name, "ssh_user", found.ssh_user, safe_user)
        end
        return exec({
            "ci",
            "box",
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
            name
                .. " has no tailnet name or ssh user (state "
                .. tostring(present(shown.state))
                .. ")"
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

---Make the picker's rows: the project's boxes, the others, then a new-box row.
---@param boxes dev.cmd.box.Box[] the boxes ci lists
---@param project string the current project, empty outside one
---@return dev.ui.picker.Item[] items the rows
local function items_for(boxes, project)
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
    if project ~= "" then
        items[#items + 1] = { value = NEW_VALUE, cells = { "new box for " .. project } }
    end
    return items
end

---Ask which box to connect to.
---@param boxes dev.cmd.box.Box[] the boxes ci lists
---@param project string the current project, empty outside one
---@return string value the picked box's name, or `__new__`
local function choose(boxes, project)
    local items = items_for(boxes, project)
    if #items == 0 then
        stderr:write("no boxes; create one with dev box create\n")
        os.exit(Exit.FAILED)
    end
    if not box.interactive() then
        verb.usage_error(
            { name = "box connect" },
            "no box given and no terminal to pick one; pass a name, like dev box connect ci-abc"
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

---Connect to a box, picking, resuming or creating one first.
---@param ctx dev.Ctx the context of `connect` or `box connect`
---@return integer code the exit code of a hand-off that could not start
local function run(ctx)
    ctx.name = "box connect"
    local parsed = box.parse(ctx, { "--ssh" })
    if #parsed.pos > 1 then
        verb.usage_error(ctx, "unexpected argument " .. parsed.pos[2])
    end
    local given
    if #parsed.pos == 1 then
        given = box.one_name(ctx, parsed)
    end
    box.need_ci()
    local project = box.default_project(ctx.root) or ""
    local boxes = box.call("connect", { "ls", "--json" }).boxes or {}
    local choice = given or choose(boxes, project)
    local found
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
            say("no box named " .. choice)
            os.exit(Exit.NOT_FOUND)
        end
        local state = present(found.state)
        if state == State.STOPPED then
            found = box.one("connect", { "resume", choice, "--json" })
            print(box.summary("resumed", found))
        elseif state ~= State.RUNNING then
            not_ready(
                choice .. " is " .. tostring(state) .. ", it must be running or stopped to connect"
            )
        end
    end
    return attach(found, { ssh = parsed.ssh })
end

M.handlers["connect"] = run
M.handlers["box connect"] = run

return M
