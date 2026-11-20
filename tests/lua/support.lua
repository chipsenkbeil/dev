local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local board = require("dev.board")

---@class support
local M = {}

---Rewrite the relative entries of `package.path` against the current directory.
---@return string path a search path that works from any directory
function M.absolute_path()
    local cwd = dev_os.capture({ "pwd" }):gsub("\n$", "")
    return ((";" .. package.path):gsub(";%./", ";" .. cwd .. "/"):sub(2))
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

---Read everything a temporary file holds.
---@param file file* a file from `io.tmpfile`
---@return string text the whole content
function M.drain(file)
    file:seek("set")
    return file:read("*a")
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

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/dotfiles/bin/.local/share/dev/main.lua"
local SELF = REPO .. "/dotfiles/bin/.local/bin/dev"
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
---@field env table<string, string>? more environment variables
---@field split boolean? keep standard error apart and return it as a third value

local function invocation(root, args, opts)
    local argv = { "luajit", MAIN }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    local env =
        { DEV_SELF = SELF, DEV_BOARD_TOKEN = "", PATH = root .. "/bin:" .. os.getenv("PATH") }
    env.STUB_CODE = opts.code
    for name, value in pairs(opts.env or {}) do
        env[name] = value
    end
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

---Build the checks field of an export card from `M.READY_CHECKS`.
---@return string json the fields object
function M.ready_fields()
    local runs = {}
    for _, row in ipairs(M.READY_CHECKS) do
        runs[#runs + 1] = '{"run":"' .. row .. '"}'
    end
    return '{"dev.checks":[' .. table.concat(runs, ",") .. "]}"
end

---The fields JSON of a Pomb board that defines the four card fields.
M.FIELDS = '[{"id":"f1","key":"dev.checks","label":"Checks","kind":"table",'
    .. '"options":[],"columns":[],"required":true},'
    .. '{"id":"f2","key":"dev.allow","label":"Allow","kind":"multiselect",'
    .. '"options":["test-edits","ci-edits"],"columns":[],"required":false},'
    .. '{"id":"f3","key":"dev.tests","label":"Tests","kind":"multiline",'
    .. '"options":[],"columns":[],"required":false},'
    .. '{"id":"f4","key":"dev.files","label":"Files","kind":"multiline",'
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
*) body='{"ok":true}' ;;
esac
]] .. M.PREFIX_MISS .. [[
printf '%s\n%s' "$body" "$status"
]]
end

return M
