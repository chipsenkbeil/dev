local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local runtime = require("dev.runtime")
local board = require("dev.board")

---@class support
local M = {}

---The dev binary the suites run.
M.DEV = runtime.exe

---The script that runs dev under the fakes of fake_env.luau, the way LUA_INIT did.
M.FAKE_DEV = assert(
    fs.realpath((arg[0]:match("^(.*)/tests/lua/") or ".") .. "/tests/lua/fixtures/fake_dev.luau")
)

---@class support.Route
---@field method string? the request method, any when unset
---@field path string the request path, a prefix when it ends in `*`
---@field status integer? the status, 200 when unset, 0 to close the connection unanswered, -1 to
---   answer nothing and stop listening so later connects are refused
---@field headers string[]? the response headers as `Name: value`
---@field body string? the response body
---@field contains string? a text the request target, headers or body must hold
---@field copy string? `SRC>DEST`, files to copy when the route answers

---@class support.FakeHttp
---@field port integer the loopback port the server listens on
---@field url string the base url, `http://127.0.0.1:PORT`
---@field log string the file the server records requests in
---@field dir string the directory of the routes and bodies
---@field pid string the process id of the server
local FakeHttp = {}
FakeHttp.__index = FakeHttp

local function route_line(server, route)
    local body = "-"
    if route.body then
        body = server.bodies[route.body]
        if not body then
            server.counted = server.counted + 1
            body = "body" .. server.counted
            server.bodies[route.body] = body
            assert(fs.write(server.dir .. "/" .. body, route.body))
        end
    end
    local headers = route.headers and table.concat(route.headers, "|") or "-"
    return table.concat({
        route.method or "*",
        route.path,
        tostring(route.status or 200),
        headers,
        body,
        route.contains or "-",
        route.copy or "-",
    }, "\t")
end

---Replace the routes the server answers, which it reads again on every request.
---@param routes support.Route[] the routes, the first match wins
---@param file string? the routes file to write, `routes.tsv` by default
function FakeHttp:set(routes, file)
    local lines = {}
    for index, route in ipairs(routes) do
        lines[index] = route_line(self, route)
    end
    local target = self.dir .. "/" .. (file or "routes.tsv")
    assert(fs.write(target, table.concat(lines, "\n") .. "\n", { atomic = true }))
end

---Write a routes file the server does not read yet, for a route to switch to with `copy`.
---@param name string the file name without `.tsv`
---@param routes support.Route[] the routes, the first match wins
---@return string path the file, to put in a route's `copy` as `PATH>` plus `self:path()`
function FakeHttp:stage(name, routes)
    self:set(routes, name .. ".tsv")
    return self.dir .. "/" .. name .. ".tsv"
end

---The file the server reads its routes from.
---@return string path the routes file
function FakeHttp:path()
    return self.dir .. "/routes.tsv"
end

---Read what the server recorded, one `METHOD TARGET body=BODY` line per request with its headers
---indented below.
---@return string text the log, empty when nothing arrived
function FakeHttp:requests()
    return fs.read(self.log) or ""
end

---Stop the server and remove its directory.
function FakeHttp:stop()
    if self.pid ~= "" then
        dev_os.run({
            "sh",
            "-c",
            'kill "$1" 2>/dev/null; i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.02; i=$((i + 1)); done',
            "sh",
            self.pid,
        })
        self.pid = ""
    end
    fs.remove(self.dir, { recursive = true })
end

---Start the fake HTTP server of examples/fake_http.rs on a free loopback port.
---@param routes support.Route[] the routes, the first match wins
---@return support.FakeHttp server the running server, to stop with `server:stop()`
function M.fake_http(routes)
    local exe = fs.dirname(runtime.exe) .. "/examples/fake_http"
    assert(fs.exists(exe), exe .. " is not built, run cargo build --examples")
    local dir = assert(fs.realpath(M.tempdir()))
    local server = setmetatable({
        dir = dir,
        log = dir .. "/requests.log",
        port = 0,
        url = "",
        pid = "",
        bodies = {},
        counted = 0,
    }, FakeHttp)
    server:set(routes)
    local code = dev_os.run({
        "sh",
        "-c",
        '"$1" "$2/routes.tsv" --log "$2/requests.log" >"$2/port" 2>"$2/err" & echo $! >"$2/pid"',
        "sh",
        exe,
        dir,
    })
    assert(code == 0, "fake_http did not start")
    server.pid = assert(fs.read(dir .. "/pid")):gsub("%s+", "")
    for _ = 1, 100 do
        local port = tonumber((fs.read(dir .. "/port") or ""):match("^(%d+)"))
        if port then
            server.port = port
            server.url = "http://127.0.0.1:" .. port
            dev_os.on_exit(function()
                server:stop()
            end)
            return server
        end
        dev_os.nap(0.05)
    end
    server:stop()
    error("fake_http printed no port")
end

---@section fake Pomb on fake_http (shared by the board suites)

---Write a routes file the server can switch to later, and return the `copy` field that switches
---to it. A route that carries the result answers once and then every later request meets the
---staged routes, which is how a suite makes the fake remember a claim or a call count.
---@param name string the name of the stage
---@param routes support.Route[] the routes of the stage
---@return string copy the `copy` field to put on the route that triggers the switch
function FakeHttp:stage_copy(name, routes)
    return self:stage(name, routes) .. ">" .. self:path()
end

---Split the raw JSON of an export document into one JSON text per task.
---@param text string the export document, `{"tasks":[...]}`
---@return string[] lines the tasks
function M.export_lines(text)
    local split = text:gsub('},{"id":"(%w%w%w%w%w%w%w%w%-%w%w%w%w%-)', '}\n{"id":"%1')
    split = split:gsub('^{"tasks":%[', ""):gsub("%]}$", "")
    local lines = {}
    for line in split:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    return lines
end

---Give a task's raw JSON the owner a claim would have made.
---@param line string the task JSON
---@param name string the agent name that holds it
---@return string json the task JSON
function M.owned_task(line, name)
    line = line:gsub(',"owner":.*,"claim_fence":%d+}$', "}")
    return (
        line:gsub("^{", function()
            return '{"owner":{"holder":{"kind":"agent","name":"'
                .. name
                .. '"},"lease_expires_at":null,"live":true,"fence":7},"claim":{"fence":7},'
        end, 1)
    )
end

---@class support.PombRoutes
---@field board string? the board id the task list and export hang from, `board-1` by default
---@field owner string? the agent name that holds every task a single read answers
---@field export string the raw export document
---@field move_status integer? the status of a move, 200 by default
---@field move_body string? the body of a move
---@field owner_stage string? the `copy` field to put on a claim, to switch to the owned routes
---@field owner_body string? the body of a claim and a renew, `{"live":true,"fence":7}` by default

---The routes of the task endpoints a fake Pomb answers from an export document: the task list
---and export of the board, one task by id and by its first eight characters, and the claim,
---move, comment and link calls of each task.
---@param opts support.PombRoutes what to answer
---@return support.Route[] routes the routes
function M.pomb_task_routes(opts)
    local board = opts.board or "board-1"
    local lines = M.export_lines(opts.export)
    local routes = {}
    local ids = {}
    for _, line in ipairs(lines) do
        local id = assert(line:match('^{"id":"([^"]+)"'), line)
        ids[#ids + 1] = id
        local body = opts.owner and M.owned_task(line, opts.owner) or line
        routes[#routes + 1] = { path = "/api/tasks/" .. id, body = body }
        routes[#routes + 1] = { path = "/api/tasks/" .. id:sub(1, 8), body = body }
    end
    for _, id in ipairs(ids) do
        local base = "/api/tasks/" .. id
        routes[#routes + 1] = {
            path = base .. "/move",
            status = opts.move_status,
            body = opts.move_body or '{"ok":true}',
        }
        routes[#routes + 1] = {
            path = base .. "/owner",
            body = opts.owner_body or '{"live":true,"fence":7}',
            copy = opts.owner_stage,
        }
        routes[#routes + 1] =
            { path = base .. "/owner/renew", body = opts.owner_body or '{"ok":true}' }
        routes[#routes + 1] = { path = base .. "/links", body = '{"ok":true}' }
        routes[#routes + 1] = { path = base .. "/owner/release" }
        routes[#routes + 1] = { path = base .. "/comments", body = "[]" }
    end
    routes[#routes + 1] = {
        path = "/api/boards/" .. board .. "/tasks",
        body = '{"items":[' .. table.concat(lines, ",") .. '],"next_cursor":null}',
    }
    routes[#routes + 1] = { path = "/api/boards/" .. board .. "/export-data", body = opts.export }
    return routes
end

---@endsection

---Turn an export-data answer into the page of the task list that holds the same tasks.
---@param export string the `{"tasks":[...]}` text
---@return string page the `{"items":[...],"next_cursor":null}` text
function M.export_page(export)
    return '{"items":' .. (export:match('^{"tasks":(.*)}%s*$') or "[]") .. ',"next_cursor":null}'
end

---Put a Luau snippet in a file.
---@param code string the snippet
---@return string path the file
function M.script(code)
    local path = assert(fs.mktemp({ prefix = "snippet" }))
    assert(fs.write(path, code))
    return path
end

---Return the command line that runs a Luau snippet under dev.
---@param code string the snippet
---@param ... string the words the snippet reads from `arg`
---@return string[] argv the command line
function M.eval(code, ...)
    return { runtime.exe, "-l", M.script(code), ... }
end

---Return the local backend's board file path for a test home.
---@param home string the test home
---@param name string the board name
---@return string path the board file
function M.board_file(home, name)
    return home .. "/state/dev/boards/" .. name .. ".json"
end

---Remove the landing turn card `dev board init` made from a local board file, to leave a test
---with only the cards it adds.
---@param path string the local board file
function M.drop_turn_card(path)
    local doc = assert(json.decode(assert(fs.read(path))))
    local kept = {}
    for _, card in ipairs(doc.cards) do
        if card.name ~= board.TURN_NAME then
            kept[#kept + 1] = card
        end
    end
    doc.cards = kept
    assert(fs.write(path, json.encode(doc)))
end

---Look a card up in a fake backend's own list.
---@param backend { cards: fun(self: any): table<string, any>[] } the fake to search
---@param id string the card id
---@return table<string, any>? card the card with that id
---@return string? message why no card was found
function M.listed_card(backend, id)
    local cards, message = backend:cards()
    if not cards then
        return nil, message
    end
    for _, listed in ipairs(cards) do
        if listed.id == id then
            return listed
        end
    end
    return nil, "no card " .. id
end

---Write the record `Backend:failure` holds after a fake backend answered with a refusal text.
---@param message string? what the fake returned, nil after an answer that succeeded
---@return dev.board.pomb.Failure? failure the record, nil when the fake did not fail
function M.failure_of(message)
    if type(message) ~= "string" then
        return nil
    end
    local Reason = board.TransportReason
    local lowered = message:lower()
    local code = lowered:match("curl exit (%d+)")
    local status = lowered:match("pomb answered (%d+)")
    if code then
        return { reason = Reason.UNREACHABLE, detail = { url = "https://p", code = tonumber(code) } }
    elseif lowered:find("pass timed out", 1, true) then
        return { reason = Reason.PASS_TIMEOUT, detail = {} }
    elseif lowered:find("pass is locked or has no entry", 1, true) then
        return { reason = Reason.PASS_ENTRY, detail = {} }
    elseif lowered:find("answer dev cannot read", 1, true) then
        return { reason = Reason.UNREADABLE, detail = {} }
    end
    return { reason = Reason.REFUSED, detail = { status = tonumber(status) } }
end

---Put a card in a column of a local board file, the way a landed card arrives, so the proof guard
---on a move into Release or Done never reads it.
---@param path string the local board file
---@param id string the card id or a prefix of it
---@param column string the column display name, one of `COLUMN_NAME`
function M.place(path, id, column)
    local doc = assert(json.decode(assert(fs.read(path))))
    local column_id
    for _, row in ipairs(doc.columns) do
        if row.name == column then
            column_id = row.id
        end
    end
    assert(column_id, "no column " .. column)
    for _, card in ipairs(doc.cards) do
        if card.id:sub(1, #id) == id then
            card.column_id = column_id
        end
    end
    assert(fs.write(path, json.encode(doc)))
end

---Make a temporary directory.
---@return string dir the new directory
function M.tempdir()
    return assert(fs.mktemp({ prefix = "test", dir = true }))
end

---Run `run` with an environment variable set, then put the variable back.
---@param name string the variable
---@param value string? the value, empty when nil
---@param run fun() the body to run
function M.with_env(name, value, run)
    local previous = dev_os.getenv(name)
    dev_os.setenv(name, value or "")
    local ok, err = pcall(run)
    dev_os.setenv(name, previous or "")
    assert(ok, err)
end

---Run `run` with HOME pointing at a temporary home whose user config holds `text`.
---@param text string the content of `~/.config/dev/config.toml`
---@param run fun() the body to run
function M.with_user_config(text, run)
    local home = M.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    assert(fs.write(home .. "/.config/dev/config.toml", text), "write failed")
    local previous = dev_os.getenv("HOME")
    dev_os.setenv("HOME", home)
    local ok, err = pcall(run)
    dev_os.setenv("HOME", previous)
    assert(ok, err)
end

---The author and committer a test's git commits carry.
M.GIT_IDENT = {
    GIT_AUTHOR_NAME = "t",
    GIT_AUTHOR_EMAIL = "t@example.com",
    GIT_COMMITTER_NAME = "t",
    GIT_COMMITTER_EMAIL = "t@example.com",
}

---Run git in a directory with the test identity and no signing, failing the test when git fails.
---@param dir string the repository directory
---@param ... string the git arguments
function M.git(dir, ...)
    local argv = { "git", "-C", dir, "-c", "commit.gpgsign=false", ... }
    local code = dev_os.run(argv, { stdout = "null", stderr = "null", env = M.GIT_IDENT })
    assert(code == 0, "git failed: " .. table.concat({ ... }, " "))
end

---Resolve a name to a commit in a repository.
---@param dir string the repository directory
---@param name string a ref or revision
---@return string sha the full commit id
function M.rev(dir, name)
    return (dev_os.capture({ "git", "-C", dir, "rev-parse", name }):match("^(%x+)"))
end

local STUB = '#!/bin/sh\necho "$(basename "$0") $* cwd=$PWD"\nexit "${STUB_CODE:-0}"\n'
local ASYNC_WAIT_SECONDS = 120
---Make a project directory with a `.dev` directory and stub tools in `bin`.
---
---Each stub prints its name, its arguments and its directory, then exits with `STUB_CODE`.
---@param files table<string, string> file contents by path under the project
---@param tools string[]? the stubs to make, `make`, `npm`, `cargo` and `ast-grep` when nil
---@return string root the project's real path
function M.sandbox(files, tools)
    local root = assert(fs.realpath(M.tempdir()))
    assert(fs.mkdir(root .. "/.dev", { parents = true }))
    assert(fs.mkdir(root .. "/bin", { parents = true }))
    for name, text in pairs(files) do
        assert(fs.mkdir(fs.dirname(root .. "/" .. name), { parents = true }))
        assert(fs.write(root .. "/" .. name, text))
    end
    for _, tool in ipairs(tools or { "make", "npm", "cargo", "ast-grep" }) do
        assert(fs.write(root .. "/bin/" .. tool, STUB))
        assert(dev_os.run({ "chmod", "755", root .. "/bin/" .. tool }) == 0, "chmod failed")
    end
    return root
end

---Write the fake `ci` into a sandbox's `bin`.
---
---It logs its arguments to `log` under root, prints the `<second argument>.json` file and, for
---`fleet`, the `shapes.json` file after it, then exits with the number in an `rc` file under
---root when one exists.
---@param root string the project's real path from `sandbox`
function M.fake_ci(root)
    local body = table
        .concat({
            "#!/bin/sh",
            'echo "$*" >> "%s/log"',
            'cat "%s/$2.json"',
            '[ "$1" != fleet ] || cat "%s/shapes.json"',
            '[ ! -f "%s/rc" ] || exit "$(cat "%s/rc")"',
            "",
        }, "\n")
        :format(root, root, root, root, root)
    assert(fs.write(root .. "/bin/ci", body))
    assert(dev_os.run({ "chmod", "755", root .. "/bin/ci" }) == 0, "chmod failed")
end

---@class support.dev.Opts
---@field cwd string? where to run, the project root when nil
---@field code string? the exit code the stubs return
---@field env table<string, string>? more environment variables, and FAKE_DEV to run under fake_env.luau
---@field split boolean? keep standard error apart and return it as a third value

local function invocation(root, args, opts)
    local fake = opts.env and opts.env.FAKE_DEV
    local argv = fake and { runtime.exe, "-l", M.FAKE_DEV } or { runtime.exe }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    local env = {
        DEV_SELF = runtime.exe,
        DEV_BOARD_TOKEN = "",
        PATH = root .. "/bin:" .. dev_os.getenv("PATH"),
        XDG_CONFIG_HOME = M.tempdir(),
    }
    env.STUB_CODE = opts.code
    for name, value in pairs(opts.env or {}) do
        env[name] = value
    end
    env.FAKE_DEV = nil
    return argv, { cwd = opts.cwd or root, stderr = "stdout", env = env }
end

---Run `dev` on a project with its `bin` first on PATH.
---@param root string the project root from `sandbox`
---@param args string[] the command line after `dev`
---@param opts support.dev.Opts? where to run and what to set
---@return string output standard output, with standard error merged in unless `opts.split` is set
---@return integer? code dev's exit code
---@return string? errors standard error alone, only when `opts.split` is set
function M.dev(root, args, opts)
    opts = opts or {}
    local argv, run = invocation(root, args, opts)
    local errors
    if opts.split then
        errors = assert(fs.mktemp({ prefix = "stderr" }))
        run.stderr = errors
    end
    local out, code
    if opts.input then
        out, code = dev_os.capture_input(argv, opts.input, run)
    else
        out, code = dev_os.capture(argv, run)
    end
    if errors then
        local text = fs.read(errors) or ""
        fs.remove(errors)
        return out, code, text
    end
    return out, code
end

---@class support.Running
---@field finished fun(): boolean whether the command has exited
---@field wait fun(): string, integer? the output and exit code once it has exited

---Start `dev` on a project in the background.
---@param root string the project root from `sandbox`
---@param args string[] the command line after `dev`
---@param opts support.dev.Opts? where to run and what to set
---@return support.Running running the handle of the started command
function M.dev_async(root, args, opts)
    local argv, run = invocation(root, args, opts or {})
    local dir = M.tempdir()
    local out, status = dir .. "/out", dir .. "/status"
    local line = dev_os.command(argv)
        .. " >"
        .. out
        .. " 2>&1; echo $? >"
        .. status
        .. ".tmp; mv "
        .. status
        .. ".tmp "
        .. status
    assert(
        dev_os.run({ "sh", "-c", "(" .. line .. ") &" }, { cwd = run.cwd, env = run.env }) == 0,
        "start failed"
    )
    local function finished()
        return fs.is_file(status)
    end
    return {
        finished = finished,
        wait = function()
            local waited = 0
            while not finished() and waited < ASYNC_WAIT_SECONDS * 10 do
                dev_os.nap(0.1)
                waited = waited + 1
            end
            return fs.read(out) or "", tonumber((fs.read(status) or ""):match("%d+"))
        end,
    }
end

---@class support.PombExportTask
---@field id string task id
---@field name string task name
---@field column_id string id of the column the task sits in
---@field swimlane_id? string id of the swimlane the task sits in, left out by default
---@field holder? string name of the agent that owns the task
---@field lease_expires_at? string end of the owner's lease as a timestamp, null by default
---@field claim_fence? integer counter of the latest claim, 0 by default
---@field position? integer place in the column, 1 by default
---@field color_id? string|false id of the card's color, false for a null one, left out by default
---@field labels? string[] label names, none by default
---@field kind? string card kind such as "epic", left out by default
---@field description? string description as JSON string content, left out by default
---@field subtasks? string raw JSON of the subtasks value, left out by default
---@field fields? string raw JSON object of the card's field values, left out by default

---Build one task of Pomb's export-data endpoint as the endpoint sends it.
---
---The owner carries only its holder and its lease, the time limit on the hold. The fence of the
---latest claim, the counter a write must present to prove it still holds the task, rides on the
---task as `claim_fence`, which is 0 for a task never claimed.
---@param task support.PombExportTask the task to build
---@return string json the task object
function M.pomb_export_task(task)
    local claim_fence = task.claim_fence or 0
    local position = task.position or 1
    local task_labels = task.labels or {}
    local owner = "null"
    if task.holder then
        local lease = task.lease_expires_at and ('"' .. task.lease_expires_at .. '"') or "null"
        owner = '{"holder":{"kind":"agent","name":"'
            .. task.holder
            .. '"},"lease_expires_at":'
            .. lease
            .. "}"
    end
    local swimlane = task.swimlane_id and ('"swimlane_id":"' .. task.swimlane_id .. '",') or ""
    local color = ""
    if task.color_id == false then
        color = '"color_id":null,'
    elseif task.color_id then
        color = '"color_id":"' .. task.color_id .. '",'
    end
    local labels = {}
    for _, label in ipairs(task_labels) do
        labels[#labels + 1] = '"' .. label .. '"'
    end
    local extra = ""
    if task.kind then
        extra = extra .. ',"kind":"' .. task.kind .. '"'
    end
    if task.description then
        extra = extra .. ',"description":"' .. task.description .. '"'
    end
    if task.subtasks then
        extra = extra .. ',"subtasks":' .. task.subtasks
    end
    if task.fields then
        extra = extra .. ',"fields":' .. task.fields
    end
    if task.history then
        extra = extra .. ',"history":' .. task.history
    end
    return '{"id":"'
        .. task.id
        .. '","name":"'
        .. task.name
        .. '","column_id":"'
        .. task.column_id
        .. '",'
        .. swimlane
        .. '"position":'
        .. position
        .. ","
        .. color
        .. '"labels":['
        .. table.concat(labels, ",")
        .. "]"
        .. extra
        .. ',"owner":'
        .. owner
        .. ',"claim_fence":'
        .. claim_fence
        .. "}"
end

---Three outcomes that each name a deciding check, the shape a card needs to be taken.
---@type { id: string, name: string, done: boolean }[]
M.READY_OUTCOMES = {
    { id = "r1", name = "a works (check: dev --remote lint)", done = false },
    { id = "r2", name = "b works (check: dev --remote lint)", done = false },
    { id = "r3", name = "c works (check: dev --remote lint)", done = false },
}

---The checks rows that decide `M.READY_OUTCOMES`.
---@type string[]
M.READY_CHECKS = { "dev --remote lint" }

---A v4 description with its Problem, Change and Out of scope.
M.READY_DESCRIPTION = "## Problem\nwhy\n\n## Change\n- x\n\n## Out of scope\nnone"

---`M.READY_DESCRIPTION` as the content of a JSON string.
M.READY_DESCRIPTION_JSON = M.READY_DESCRIPTION:gsub("\n", "\\n")

---Render outcomes as the raw JSON of an export's subtasks value.
---@param outcomes { id: string, name: string }[] the outcomes
---@param done? boolean whether every subtask is ticked
---@return string json the subtasks array
function M.subtasks(outcomes, done)
    local parts = {}
    for _, outcome in ipairs(outcomes) do
        parts[#parts + 1] = string.format(
            '{"id":"%s","name":"%s","done":%s}',
            outcome.id,
            outcome.name,
            tostring(done == true)
        )
    end
    return "[" .. table.concat(parts, ",") .. "]"
end

---Build the runner checks field of an export card from `M.READY_CHECKS`.
---@return string json the fields object
function M.ready_fields()
    local runs = {}
    for _, row in ipairs(M.READY_CHECKS) do
        runs[#runs + 1] = '{"run":"' .. row .. '"}'
    end
    return '{"runner.checks":[' .. table.concat(runs, ",") .. "]}"
end

---The fields JSON of a Pomb board that defines the four runner fields.
M.FIELDS = '[{"id":"f1","key":"runner.checks","label":"Checks","kind":"table",'
    .. '"options":[],"columns":[],"required":true},'
    .. '{"id":"f2","key":"runner.allow","label":"Allow","kind":"multiselect",'
    .. '"options":["test-edits","ci-edits"],"columns":[],"required":false},'
    .. '{"id":"f3","key":"runner.tests","label":"Tests","kind":"multiline",'
    .. '"options":[],"columns":[],"required":false},'
    .. '{"id":"f4","key":"runner.files","label":"Files","kind":"multiline",'
    .. '"options":[],"columns":[],"required":false}]'

---Shell functions for a fake curl that read tasks from the export fixture.
M.EXPORT_ROUTES = [[
export_lines() {
    sed 's/},{"id":"\([0-9a-z]\{8\}-[0-9a-z]\{4\}-\)/}\n{"id":"\1/g' "$ROOT/export.json" \
        | sed 's/^{"tasks":\[//; s/\]}$//'
}
task_of() {
    export_lines | grep "^{\"id\":\"$1\"" | head -1
}
tasks_page() {
    printf '{"items":[%s],"next_cursor":null}' "$(export_lines | paste -sd, -)"
}
]]

---Shell that makes a fake curl answer a task read by id prefix like Pomb: a unique prefix reads
---that task, and any other prefix answers 404. It needs `export_lines` and may use `$extra_id`.
M.PREFIX_RESOLVE = [[
prefix_miss=
tail=${last##*/api/tasks/}
if [ "$tail" != "$last" ] && [ "${#tail}" -ge 6 ] && [ "${#tail}" -lt 36 ] \
    && [ -z "$(printf '%s' "$tail" | tr -d '0-9a-f-')" ]; then
    ids=$( { export_lines | sed -n 's/^{"id":"\([^"]*\)".*/\1/p'
        echo; echo "$extra_id"; } | grep "^$tail")
    if [ "$(printf '%s\n' "$ids" | grep -c .)" = 1 ]; then
        last=${last%"$tail"}$ids
    else
        prefix_miss=1
    fi
fi
]]

---Shell that turns the answer of a missed prefix read into Pomb's 404.
M.PREFIX_MISS = [[
if [ -n "$prefix_miss" ]; then
    body='{"code":"not_found","message":"task not found"}'
    status=404
fi
]]

---The board column names, by constant.
---@enum support.Column
M.Column = {
    BACKLOG = "backlog",
    BLOCKED = "blocked",
    DONE = "done",
    ICEBOX = "icebox",
    PROGRESS = "progress",
    READY = "ready",
    RELEASE = "release",
    REVIEW = "review",
    VERIFY = "verify",
}

---The Pomb display name of a column, by constant.
---@type table<string, string>
M.COLUMN_NAME = {
    BACKLOG = "Backlog",
    BLOCKED = "Blocked",
    DONE = "Done",
    ICEBOX = "Icebox",
    IN_REVIEW = "In Review",
    PROGRESS = "In Progress",
    READY = "Ready",
    RELEASE = "Release",
    REVIEW = "Review",
    VERIFY = "Verify",
}

---Add the `--of code` a recheck review needs to the arguments of a `review` call.
---@param kind string the review kind
---@param args string[] the arguments
---@return string[] args the same list, with `--of code` appended for a recheck
function M.with_of(kind, args)
    if kind == "recheck" then
        args[#args + 1] = "--of"
        args[#args + 1] = "code"
    end
    return args
end

---Walk a card to Review through In Progress and the status note.
---
---Stops at the first step that exits non-zero.
---@param run fun(args: string[]): string, integer? one-command runner returning output and code
---@param id string the card id
---@return string output the output of the last step run
---@return integer? code the exit code of the last step run
function M.to_review(run, id)
    local steps = {
        { "board", "move", id, M.Column.PROGRESS },
        { "board", "note", id, "built, tried, learned" },
        { "board", "move", id, M.Column.REVIEW },
    }
    local out, code
    for _, args in ipairs(steps) do
        out, code = run(args)
        if code ~= 0 then
            break
        end
    end
    return out, code
end

---The id Pomb gives a column in the fixtures, from a column constant or display name.
---@param column string the column constant or display name
---@return string id the column id
function M.column_id(column)
    return "col-" .. column
end

---Build the fake `curl` script that answers Pomb's routes from the files in `$ROOT`.
---@param first_id string id of the card the task routes answer for
---@param second_id string id of the card the second page of the card list holds
---@param links_id string id of the card the link routes answer for
---@return string script the shell script
function M.pomb_curl(first_id, second_id, links_id)
    return [[#!/bin/sh
printf 'curl %s\n' "$*" >>"$ROOT/calls"
cat >"$ROOT/stdin"
for last; do :; done
]] .. M.EXPORT_ROUTES .. [[
status=${HTTP_STATUS:-200}
extra_id=dddddddd-dddd-4ddd-8ddd-dddddddddddd
]] .. M.PREFIX_RESOLVE .. [[
case "$last" in
*/api/boards) body=$(cat "$ROOT/boards.json") ;;
*/api/boards/board-1) body=$(cat "$ROOT/detail.json") ;;
*/api/boards/board-2) body=$(cat "$ROOT/general.json") ;;
*/colors) body=$(cat "$ROOT/colors.json") ;;
*/fields) body=$(cat "$ROOT/fields.json") ;;
*/api/boards/board-1/bin) body=$(cat "$ROOT/bin.json") ;;
*/restore) body=$(cat "$ROOT/restore.json") ;;
*/export-data) body=$(cat "$ROOT/export.json") ;;
*/history\?cursor=*) body=$(cat "$ROOT/history_next.json") ;;
*/history) body=$(cat "$ROOT/history.json") ;;
*/tasks\?limit=500\&cursor=c2) body='{"items":[{"id":"]] .. second_id .. [[",'\
'"column_entered_at":"2020-02-01T00:00:00Z"}],"next_cursor":null}' ;;
*/tasks\?limit=500) body='{"items":[{"id":"]] .. first_id .. [[",'\
'"column_entered_at":"2020-01-01T00:00:00.5+00:00"}],"next_cursor":"c2"}' ;;
*/tasks\?limit=1000*) body=$(tasks_page) ;;
*/tasks\?*) body='{"items":[{"id":"]] .. first_id .. [["}],"next_cursor":null}' ;;
*/attachments)
    body=$(cat "$ROOT/attachments.json")
    case "$*" in
    *"-X POST"*)
        n=$(cat "$ROOT/post_n" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo "$n" >"$ROOT/post_n"
        if [ "$n" -le "$(cat "$ROOT/busy" 2>/dev/null || echo 0)" ]; then
            body='{"code":"busy","message":"the server is busy"}'
            status=503
        elif [ -f "$ROOT/upload_$n.json" ]; then
            body=$(cat "$ROOT/upload_$n.json")
        else
            body=$(cat "$ROOT/upload.json")
        fi
        ;;
    esac
    ;;
*/attachments/*/file)
    out=
    prev=
    for arg; do
        if [ "$prev" = "-o" ]; then out=$arg; fi
        prev=$arg
    done
    if [ -f "$ROOT/file_status" ]; then status=$(cat "$ROOT/file_status"); fi
    if [ "$status" -ge 400 ]; then
        printf '%s' '{"code":"not_found","message":"no such file"}' >"$out"
    else
        printf 'bytes of the file' >"$out"
    fi
    body=
    ;;
*/attachments/*)
    body=
    if [ -f "$ROOT/detach_body" ]; then
        body=$(cat "$ROOT/detach_body")
        status=403
    fi
    ;;
*/api/tasks/]] .. first_id .. [[)
    body=$(task_of "]] .. first_id .. [[")
    if [ -f "$ROOT/owner_name" ]; then
        body=$(printf '%s' "$body" | sed 's|,"owner":.*,"claim_fence":[0-9]*}$|}|')
    fi
    if [ -f "$ROOT/task.json" ]; then
        if [ -n "$body" ]; then
            body="$(printf '%s' "$body" | sed 's|}$|,|')$(sed 's|^{||' "$ROOT/task.json")"
        else
            body=$(cat "$ROOT/task.json")
        fi
    fi
    if [ -f "$ROOT/task.seats.json" ]; then
        body="$(printf '%s' "$body" | sed 's|}$|,"seats":|')$(cat "$ROOT/task.seats.json")}"
    fi
    if [ -f "$ROOT/owner_name" ]; then
        body=$(printf '%s' "$body" | sed "s|^{|{\"owner\":{\"holder\":{\"kind\":\"agent\",\
\"name\":\"$(cat "$ROOT/owner_name")\"},\"lease_expires_at\":null,\"live\":true,\"fence\":7},\
\"claim\":{\"fence\":7},|")
    fi
    case "$*" in
    *"-X PATCH"*)
        if [ -f "$ROOT/label_fail" ]; then
            body='{"message":"nope"}'
            status=400
        fi
        ;;
    *"-X DELETE"*)
        if [ -f "$ROOT/delete_body" ]; then
            body=$(cat "$ROOT/delete_body")
            status=403
        fi
        ;;
    esac
    ;;
*/api/tasks)
    if [ -f "$ROOT/task.json" ]; then
        body=$(cat "$ROOT/task.json")
    else
        body=$(task_of "]] .. first_id .. [[")
    fi
    ;;
*/api/tasks/dddddddd-dddd-4ddd-8ddd-dddddddddddd)
    body=$(cat "$ROOT/far.json")
    if [ -f "$ROOT/far_gone" ]; then status=404; fi
    ;;
*/api/tasks/????????-????-????-????-????????????)
    body=$(task_of "${last##*/}")
    if [ -z "$body" ]; then body='{"ok":true}'; fi
    ;;
*/api/tasks/]] .. links_id .. [[/links) body=$(cat "$ROOT/holder_links.json") ;;
*/links) body=$(cat "$ROOT/links.json") ;;
*/subtasks)
    body='{"id":"sub-1","name":"x","done":false}'
    n=$(cat "$ROOT/sub_n" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" >"$ROOT/sub_n"
    if [ -f "$ROOT/sub_fail" ] && [ "$n" = "$(cat "$ROOT/sub_fail")" ]; then
        body='{"message":"nope"}'
        status=400
    fi
    ;;
*/owner/renew)
    body='{"live":true,"fence":7}'
    if [ -f "$ROOT/hb_status" ]; then status=$(cat "$ROOT/hb_status"); fi
    ;;
*/owner/release) body= ;;
*/comments/dddddddd*)
    body='{"message":"not yours"}'
    status=403
    if [ -f "$ROOT/locked" ]; then body='{"code":"card_locked","message":"locked"}'; fi
    ;;
*/comments/*) body='{"ok":true}' ;;
*/comments)
    body=$(cat "$ROOT/comments.json")
    case "$*" in
    *"-X POST"*)
        if [ -f "$ROOT/locked" ]; then
            body='{"code":"card_locked","message":"locked"}'
            status=403
        fi
        if [ -f "$ROOT/ask_refusal" ]; then
            body=$(cat "$ROOT/ask_refusal")
            status=400
        fi
        ;;
    esac
    ;;
*/owner)
    if [ -f "$ROOT/owner_held" ]; then
        body='{"code":"owner_held","message":"task owned by dotfiles/other '\
'until 2999-01-01T00:00:00Z"}'
        status=409
    else
        printf '%s' "$*" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' >"$ROOT/owner_name"
        body='{"holder":{"kind":"agent","name":"x"},'\
'"lease_expires_at":"2999-01-01T00:00:00Z","live":true,"fence":7}'
    fi
    ;;
*/api/boards/board-1/seats)
    body='{"seats":[]}'
    if [ -f "$ROOT/board_seats.json" ]; then body=$(cat "$ROOT/board_seats.json"); fi
    case " $* " in
    *" -X PUT "*)
        if [ -f "$ROOT/board_seats_status" ]; then
            status=$(cat "$ROOT/board_seats_status")
            body='{"code":"permission_denied","message":"seats.manage is needed"}'
        fi
        ;;
    esac
    ;;
*/seats/take)
    if [ -f "$ROOT/no_seat" ]; then
        body='{"message":"the task has no such seat"}'
        status=404
    fi
    ;;
*/seats)
    if [ -f "$ROOT/seat_refused" ]; then
        body='{"code":"permission_denied","message":"the role cannot add a seat"}'
        status=403
    fi
    ;;
*/seats\?name=*)
    if [ -f "$ROOT/seat_drop_refused" ]; then
        body='{"code":"permission_denied","message":"seats.manage is needed"}'
        status=403
    fi
    ;;
*) body='{"ok":true}' ;;
esac
]] .. M.PREFIX_MISS .. [[
printf '%s\n%s' "$body" "$status"
]]
end

-- Pomb routes for the fake HTTP server (U12e): the answers of the old `pomb_curl` stub

local POMB = {}

local function export_lines(root)
    local text = fs.read(root .. "/export.json") or '{"tasks":[]}'
    text = text:gsub('},{"id":"(%w%w%w%w%w%w%w%w%-%w%w%w%w%-)', '}\n{"id":"%1')
    text = text:gsub('^{"tasks":%[', ""):gsub("%]}$", "")
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    return lines
end

local function task_of(root, id)
    for _, line in ipairs(export_lines(root)) do
        if line:sub(1, #id + 7) == '{"id":"' .. id then
            return line
        end
    end
    return ""
end

local function first_task_body(root, id)
    local body = task_of(root, id)
    local named = fs.read(root .. "/owner_name")
    if named then
        body = body:gsub(',"owner":.*,"claim_fence":%d*}$', "}")
    end
    local task = fs.read(root .. "/task.json")
    if task then
        if body ~= "" then
            body = body:gsub("}$", ",") .. task:gsub("^{", "")
        else
            body = task
        end
    end
    local seats = fs.read(root .. "/task.seats.json")
    if seats then
        body = body:gsub("}$", ',"seats":') .. seats .. "}"
    end
    if named then
        named = named:gsub("%s+$", "")
        body = body:gsub(
            "^{",
            '{"owner":{"holder":{"kind":"agent","name":"'
                .. named
                .. '"},"lease_expires_at":null,"live":true,"fence":7},"claim":{"fence":7},',
            1
        )
    end
    return body
end

---Build the routes that answer like the old fake curl, from the control files in `root`.
---
---The files are read when this runs, so call `support.pomb_sync` again after a test writes one.
---Not carried over: the counters of subtask and attachment uploads, and reading a task by a short
---id prefix.
---@param root string the sandbox the control files sit in
---@param first_id string id of the card the task routes answer for
---@param second_id string id of the card the second page of the card list holds
---@param links_id string id of the card the link routes answer for
---@return support.Route[] routes the routes, the first match wins
function M.pomb_routes(root, first_id, second_id, links_id)
    local routes = {}
    local function file(name)
        return fs.read(root .. "/" .. name) or ""
    end
    local function add(route)
        routes[#routes + 1] = route
    end
    local function has(name)
        return fs.exists(root .. "/" .. name)
    end
    local page = {}
    for _, line in ipairs(export_lines(root)) do
        page[#page + 1] = line
    end
    local far = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    add({ path = "/api/boards", body = file("boards.json") })
    add({ path = "/api/boards/board-1", body = file("detail.json") })
    add({ path = "/api/boards/board-2", body = file("general.json") })
    add({ path = "*/colors", body = file("colors.json") })
    add({ path = "*/fields", body = file("fields.json") })
    add({ path = "/api/boards/board-1/bin", body = file("bin.json") })
    add({ path = "*/restore", body = file("restore.json") })
    add({ path = "*/export-data", body = file("export.json") })
    add({ path = "*/history?cursor=*", body = file("history_next.json") })
    add({ path = "*/history", body = file("history.json") })
    add({
        path = "*/tasks?limit=500&cursor=c2",
        body = '{"items":[{"id":"'
            .. second_id
            .. '","column_entered_at":"2020-02-01T00:00:00Z"}],"next_cursor":null}',
    })
    add({
        path = "*/tasks?limit=500",
        body = '{"items":[{"id":"'
            .. first_id
            .. '","column_entered_at":"2020-01-01T00:00:00.5+00:00"}],"next_cursor":"c2"}',
    })
    add({
        path = "*/tasks?limit=1000*",
        body = '{"items":[' .. table.concat(page, ",") .. '],"next_cursor":null}',
    })
    add({
        path = "*/tasks?*",
        body = '{"items":[{"id":"' .. first_id .. '"}],"next_cursor":null}',
    })
    add({ path = "*/attachments", body = file("attachments.json") })
    if has("label_fail") then
        add({
            method = "PATCH",
            path = "/api/tasks/" .. first_id,
            status = 400,
            body = '{"message":"nope"}',
        })
    end
    if has("delete_body") then
        add({
            method = "DELETE",
            path = "/api/tasks/" .. first_id,
            status = 403,
            body = file("delete_body"),
        })
    end
    add({ path = "/api/tasks/" .. first_id, body = first_task_body(root, first_id) })
    add({
        path = "/api/tasks/" .. far,
        status = has("far_gone") and 404 or 200,
        body = file("far.json"),
    })
    add({
        method = "GET",
        path = "/api/tasks/" .. links_id .. "/links",
        body = file("holder_links.json"),
    })
    add({ path = "*/links", body = file("links.json") })
    add({ path = "*/subtasks", body = '{"id":"sub-1","name":"x","done":false}' })
    add({
        path = "*/owner/renew",
        status = tonumber(file("hb_status")) or 200,
        body = '{"live":true,"fence":7}',
    })
    add({ path = "*/owner/release", body = "" })
    add({
        path = "*/comments/dddddddd*",
        status = 403,
        body = has("locked") and '{"code":"card_locked","message":"locked"}'
            or '{"message":"not yours"}',
    })
    add({ path = "*/comments/*", body = '{"ok":true}' })
    if has("locked") then
        add({
            method = "POST",
            path = "*/comments",
            status = 403,
            body = '{"code":"card_locked","message":"locked"}',
        })
    end
    if has("ask_refusal") then
        add({ method = "POST", path = "*/comments", status = 400, body = file("ask_refusal") })
    end
    add({ path = "*/comments", body = file("comments.json") })
    if has("owner_held") then
        add({
            path = "*/owner",
            status = 409,
            body = '{"code":"owner_held","message":"task owned by dotfiles/other '
                .. 'until 2999-01-01T00:00:00Z"}',
        })
    else
        add({
            path = "*/owner",
            body = '{"holder":{"kind":"agent","name":"x"},'
                .. '"lease_expires_at":"2999-01-01T00:00:00Z","live":true,"fence":7}',
        })
    end
    if has("board_seats_status") then
        add({
            method = "PUT",
            path = "/api/boards/board-1/seats",
            status = tonumber(file("board_seats_status")),
            body = '{"code":"permission_denied","message":"seats.manage is needed"}',
        })
    end
    add({
        path = "/api/boards/board-1/seats",
        body = has("board_seats.json") and file("board_seats.json") or '{"seats":[]}',
    })
    if has("no_seat") then
        add({
            path = "*/seats/take",
            status = 404,
            body = '{"message":"the task has no such seat"}',
        })
    end
    if has("seat_drop_refused") then
        add({
            path = "*/seats?name=*",
            status = 403,
            body = '{"code":"permission_denied","message":"seats.manage is needed"}',
        })
    end
    if has("seat_refused") then
        add({
            path = "*/seats",
            status = 403,
            body = '{"code":"permission_denied","message":"the role cannot add a seat"}',
        })
    end
    add({ path = "*", body = '{"ok":true}' })
    return routes
end

---Start the fake HTTP server for a sandbox and answer with `pomb_routes`.
---@param root string the sandbox
---@param first_id string id of the card the task routes answer for
---@param second_id string id of the card the second page of the card list holds
---@param links_id string id of the card the link routes answer for
---@return support.FakeHttp server the running server
function M.pomb_server(root, first_id, second_id, links_id)
    local server = M.fake_http({})
    POMB[root] = { server = server, ids = { first_id, second_id, links_id } }
    M.pomb_sync(root)
    return server
end

---Answer again from the control files, after a test wrote one.
---@param root string the sandbox `pomb_server` started a server for
function M.pomb_sync(root)
    local state = POMB[root]
    state.server:set(M.pomb_routes(root, state.ids[1], state.ids[2], state.ids[3]))
end

---Read the requests a server logged as entries.
---@param server support.FakeHttp the server
---@return { method: string, target: string, text: string }[] entries one per request, in order
function M.pomb_requests(server)
    local entries = {}
    for line in (server:requests() .. "\n"):gmatch("([^\n]*)\n") do
        local method, target = line:match("^(%u+) (%S+)")
        if method then
            entries[#entries + 1] = { method = method, target = target, text = line }
        elseif line ~= "" and #entries > 0 then
            entries[#entries].text = entries[#entries].text .. "\n" .. line
        end
    end
    return entries
end

---@endsection

-- Pomb fake routes for the board suites

local TASK_PREFIX = "/api/tasks/"
local EXTRA_ID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"

local function trimmed(text)
    return (text:gsub("\n+$", ""))
end

---Split an export-data document into its cards, as the old curl stub did.
---@param export string the document
---@return { id: string, json: string }[] cards the cards in order
local function export_cards(export)
    local text = export:gsub('},{"id":"(%w%w%w%w%w%w%w%w%-%w%w%w%w%-)', '}\n{"id":"%1')
    local cards = {}
    for line in text:gmatch("[^\n]+") do
        line = line:gsub('^{"tasks":%[', ""):gsub("%]}$", "")
        local id = line:match('^{"id":"([^"]*)"')
        if id then
            cards[#cards + 1] = { id = id, json = line }
        end
    end
    return cards
end

---Build the routes the Pomb board suites expect from the control files in `root`.
---
---The files are the ones the old curl stub read: boards.json, detail.json, export.json,
---task.json and so on. `att_step` and `sub_step` say which attachment upload and which
---subtask creation the routes answer, for the files that change from one call to the next.
---@param root string the sandbox directory holding the control files
---@param ids { first: string, second: string, links: string } the ids the routes answer for
---@param att_step integer which POST to /attachments the routes answer
---@param sub_step integer which POST to /subtasks the routes answer
---@return support.Route[] routes the routes
local function pomb_routes_at(root, ids, att_step, sub_step)
    local function control(name)
        local text = fs.read(root .. "/" .. name)
        return text and trimmed(text) or nil
    end
    local function has(name)
        return fs.exists(root .. "/" .. name)
    end
    local routes = {}
    local function add(path, body, status, method, extra)
        local route = { method = method, path = path, body = body, status = status }
        for key, value in pairs(extra or {}) do
            route[key] = value
        end
        routes[#routes + 1] = route
    end
    local export = control("export.json") or ""
    local cards = export_cards(export)
    local function task_of(id)
        for _, card in ipairs(cards) do
            if card.id == id then
                return card.json
            end
        end
        return ""
    end
    local function first_body()
        local body = task_of(ids.first)
        if has("owner_name") then
            body = body:gsub(',"owner":.*,"claim_fence":%d+}$', "}")
        end
        if has("task.json") then
            local extra = control("task.json")
            if body ~= "" then
                body = body:gsub("}$", ",") .. extra:gsub("^{", "")
            else
                body = extra
            end
        end
        if has("task.seats.json") then
            body = body:gsub("}$", ',"seats":') .. control("task.seats.json") .. "}"
        end
        if has("owner_name") then
            local owner = '{"owner":{"holder":{"kind":"agent","name":"'
                .. control("owner_name")
                .. '"},"lease_expires_at":null,"live":true,"fence":7},"claim":{"fence":7},'
            body = body:gsub("^{", function()
                return owner
            end)
        end
        return body
    end

    local known = {}
    for _, card in ipairs(cards) do
        known[#known + 1] = card.id
    end
    known[#known + 1] = EXTRA_ID

    local function answers(path, id)
        if id == ids.first then
            local body = first_body()
            add(
                path,
                has("label_fail") and '{"message":"nope"}' or body,
                has("label_fail") and 400 or 200,
                "PATCH"
            )
            add(
                path,
                has("delete_body") and control("delete_body") or body,
                has("delete_body") and 403 or 200,
                "DELETE"
            )
            add(path, body)
        elseif id == EXTRA_ID then
            add(path, control("far.json") or "", has("far_gone") and 404 or 200)
        else
            local body = task_of(id)
            add(path, body ~= "" and body or '{"ok":true}')
        end
    end

    for _, id in ipairs(known) do
        for length = 6, 35 do
            local prefix = id:sub(1, length)
            local count = 0
            for _, other in ipairs(known) do
                if other:sub(1, length) == prefix then
                    count = count + 1
                end
            end
            if count == 1 then
                answers(TASK_PREFIX .. prefix, id)
            end
        end
    end
    for length = 6, 35 do
        add(
            TASK_PREFIX .. ("#"):rep(length),
            '{"code":"not_found","message":"task not found"}',
            404
        )
    end

    add("/api/boards", control("boards.json"))
    add("/api/boards/board-1", control("detail.json"))
    add("/api/boards/board-2", control("general.json"))
    add("*/colors", control("colors.json"))
    add("*/fields", control("fields.json"))
    add("/api/boards/board-1/bin", control("bin.json"))
    add("*/restore", control("restore.json"))
    add("*/export-data", export)
    add("*/history?cursor=*", control("history_next.json"))
    add("*/history", control("history.json"))
    add(
        "*/tasks?limit=500&cursor=c2",
        '{"items":[{"id":"'
            .. ids.second
            .. '","column_entered_at":"2020-02-01T00:00:00Z"}],"next_cursor":null}'
    )
    add(
        "*/tasks?limit=500",
        '{"items":[{"id":"'
            .. ids.first
            .. '","column_entered_at":"2020-01-01T00:00:00.5+00:00"}],"next_cursor":"c2"}'
    )
    local page = {}
    for _, card in ipairs(cards) do
        page[#page + 1] = card.json
    end
    add("*/tasks?limit=1000*", '{"items":[' .. table.concat(page, ",") .. '],"next_cursor":null}')
    add("*/tasks?*", '{"items":[{"id":"' .. ids.first .. '"}],"next_cursor":null}')

    local attachments = control("attachments.json") or ""
    local busy = tonumber((control("busy"))) or 0
    if att_step <= busy then
        add(
            "*/attachments",
            '{"code":"busy","message":"the server is busy"}',
            503,
            "POST",
            { advance = "att" }
        )
    else
        add(
            "*/attachments",
            control("upload_" .. att_step .. ".json") or control("upload.json") or "",
            200,
            "POST",
            { advance = "att" }
        )
    end
    add("*/attachments", attachments)
    local file_status = tonumber((control("file_status"))) or 200
    add(
        "*/attachments/*/file",
        file_status >= 400 and '{"code":"not_found","message":"no such file"}'
            or "bytes of the file",
        file_status
    )
    if has("detach_body") then
        add("*/attachments/*", control("detach_body"), 403)
    else
        add("*/attachments/*", "")
    end

    answers("*/api/tasks/" .. ids.first, ids.first)
    add("*/api/tasks", has("task.json") and control("task.json") or task_of(ids.first))
    answers("*/api/tasks/" .. EXTRA_ID, EXTRA_ID)
    for _, card in ipairs(cards) do
        if card.id ~= ids.first then
            answers("*/api/tasks/" .. card.id, card.id)
        end
    end
    add("*/api/tasks/" .. ids.links .. "/links", control("holder_links.json"))
    add("*/links", control("links.json"))
    local sub_fail = tonumber((control("sub_fail")))
    if sub_fail == sub_step then
        add("*/subtasks", '{"message":"nope"}', 400, nil, { advance = "sub" })
    else
        add("*/subtasks", '{"id":"sub-1","name":"x","done":false}', 200, nil, { advance = "sub" })
    end
    add("*/owner/renew", '{"live":true,"fence":7}', tonumber((control("hb_status"))) or 200)
    add("*/owner/release", "")
    add(
        "*/comments/dddddddd*",
        has("locked") and '{"code":"card_locked","message":"locked"}' or '{"message":"not yours"}',
        403
    )
    add("*/comments/*", '{"ok":true}')
    if has("locked") then
        add("*/comments", '{"code":"card_locked","message":"locked"}', 403, "POST")
    elseif has("ask_refusal") then
        add("*/comments", control("ask_refusal"), 400, "POST")
    end
    add("*/comments", control("comments.json"))
    if has("owner_held") then
        add(
            "*/owner",
            '{"code":"owner_held","message":"task owned by dotfiles/other until 2999-01-01T00:00:00Z"}',
            409
        )
    else
        add(
            "*/owner",
            '{"holder":{"kind":"agent","name":"x"},"lease_expires_at":"2999-01-01T00:00:00Z","live":true,"fence":7}'
        )
    end
    local seats = control("board_seats.json") or '{"seats":[]}'
    if has("board_seats_status") then
        add(
            "/api/boards/board-1/seats",
            '{"code":"permission_denied","message":"seats.manage is needed"}',
            tonumber((control("board_seats_status"))),
            "PUT"
        )
    end
    add("/api/boards/board-1/seats", seats)
    add(
        "*/seats/take",
        has("no_seat") and '{"message":"the task has no such seat"}' or "",
        has("no_seat") and 404 or 200
    )
    add(
        "*/seats",
        has("seat_refused")
                and '{"code":"permission_denied","message":"the role cannot add a seat"}'
            or "",
        has("seat_refused") and 403 or 200
    )
    add(
        "*/seats?name=*",
        has("seat_drop_refused")
                and '{"code":"permission_denied","message":"seats.manage is needed"}'
            or "",
        has("seat_drop_refused") and 403 or 200
    )
    add("*", '{"ok":true}')
    return routes
end

---@class support.PombPlan
---@field prepend support.Route[]? routes that come before the standard ones
---@field transform (fun(route: support.Route): support.Route)? changes each standard route
---@field advance (fun(route: support.Route): boolean)? picks the routes whose request moves on to the next step
---@field steps support.PombPlan[]? one plan per request that advances, the last one for every request after

---Make a fake server answer Pomb's routes from the control files in `root`, as the old fake curl did.
---
---Run it before each command, since the files change between commands. A call that answers
---differently the second time (an upload, a subtask creation, a plan with `steps`) is answered by
---a chain of routes files that each advancing request moves on by one.
---@param server support.FakeHttp the running server
---@param root string the sandbox directory holding the control files
---@param ids { first: string, second: string, links: string } the ids the routes answer for
---@param plan (support.PombPlan | support.Route[])? extra routes or a plan
function M.pomb_plan_sync(server, root, ids, plan)
    local function control(name)
        return fs.read(root .. "/" .. name)
    end
    local plans = { {} }
    if plan then
        if plan.steps then
            plans = plan.steps
        elseif plan.prepend or plan.transform or plan.advance then
            plans = { plan }
        else
            plans = { { prepend = plan } }
        end
    end
    local counted = 1
    local busy = tonumber(control("busy") or "") or 0
    counted = math.max(counted, busy + 2)
    for step = 1, 9 do
        if fs.exists(root .. "/upload_" .. step .. ".json") then
            counted = math.max(counted, step + 1)
        end
    end
    local sub_fail = tonumber(control("sub_fail") or "")
    if sub_fail then
        counted = math.max(counted, sub_fail + 1)
    end
    local steps = math.max(counted, #plans)
    for step = 1, steps do
        local current = plans[math.min(step, #plans)]
        local routes = {}
        local function push(route, standard)
            if standard and current.transform then
                route = current.transform(route)
            end
            local advancing = route.advance == true
                or (standard and current.advance and current.advance(route))
                or (standard and counted > 1 and route.advance ~= nil)
            if advancing and step < steps then
                route.copy = server.dir
                    .. "/routes."
                    .. (step + 1)
                    .. ".tsv>"
                    .. server.dir
                    .. "/routes.tsv"
            end
            routes[#routes + 1] = route
        end
        for _, route in ipairs(current.prepend or {}) do
            push(route, false)
        end
        for _, route in ipairs(pomb_routes_at(root, ids, step, step)) do
            push(route, true)
        end
        server:set(routes, step == 1 and "routes.tsv" or ("routes." .. step .. ".tsv"))
    end
end

dev_os.setenv("XDG_CONFIG_HOME", M.tempdir())

return M
