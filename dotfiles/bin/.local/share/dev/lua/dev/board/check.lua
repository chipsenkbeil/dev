local bit = require("bit")
local board = require("dev.board")
local dev_os = require("dev.os")
local registry = require("dev.registry")
local vcs = require("dev.vcs")

---@class dev.board.check
local M = {}

---The seconds a checks row may take, from its start to its end, when `--timeout` is not given.
---The row is one `dev --remote` command, so the wait in the ci queue counts.
M.DEFAULT_SECONDS = 7200

---The most seconds `--timeout` accepts.
M.MAX_SECONDS = 86400

local SHELL_CHARS = "[|&;<>()$`\\\"'*?!\n]"
local NEGATED = "^%s*!%s+(.*)$"
local JJ_TEMPLATE = 'commit_id ++ " " ++ change_id ++ " " ++ if(conflict, "conflict", "clean")'
local SHOWN_LINES = 12
local NO_CHANGE = "-"
local NO_RUN = "-"
local RUN_LINE = "^run (%x+)$"
local REASON_INDENT = "  "
local REASON_MAX = 120
local COMMENT_BUDGET_BYTES = 4800
local NEWLINE_BYTE = 10
local FNV_OFFSET = 2166136261
local FNV_MODULUS = 4294967296
local FNV_HIGH = 16777216
local FNV_LOW = 403
local DRAIN_REFUSAL = "is draining"
local DRAIN_NOTHING_NEW = "nothing new starts"
local DRAIN_OFF = "`ci fleet drain off"
local ERROR_PREFIX = "^error: "
local TIMEOUT_EXIT = 124
local DRAINING_EXIT = 12
local DRAIN_CAP = "The drain did not lift within"
local NOT_EXECUTABLE_EXIT = 126
local NOT_FOUND_EXIT = 127
local REMOTE_FLAG = "--remote"
local CI_COMMAND = "ci"
local DEV_COMMAND = "dev"
local DOUBLE_DASH = "--"

---How a checks row ended.
M.RESULT = { PASS = "pass", FAIL = "fail", TIMEOUT = "timeout", ERROR = "error" }

---What a run was meant to show, as the record names it.
M.MODE = { RUN = "run", EXPECT_FAIL = "expect-fail" }

---@class dev.board.check.State
---@field commit string the full commit id the result belongs to
---@field change string the change id in a jj project, `-` in a git one

---@class dev.board.check.Row
---@field run string the row's command as the card holds it
---@field run_id string the ci run id the row printed, `-` when it printed none
---@field result string one of `RESULT`, where a timeout also covers a row killed from outside and an error is a row that never started under `--expect-fail`
---@field code integer the exit status
---@field tail string the last lines the run printed
---@field reason string? the last line a failed row printed when it printed no run id
---@field refused string? ci's refusal line when the hub refused the run, which no row records

---Say why a `dev --remote test` or `dev --remote lint` row passes a word before the double dash.
---@param row string the row without its leading `! `
---@return string? message why the row is refused, nil when it is allowed
local function bare_name(row)
    local words = {}
    for word in row:gmatch("%S+") do
        words[#words + 1] = word
    end
    if words[1] ~= "dev" then
        return nil
    end
    local remote, verb_at = false, nil
    local i = 2
    while i <= #words and words[i] ~= "--" do
        local word = words[i]
        if word == "--remote" then
            remote = true
        elseif registry.VALUE_FLAGS[word] then
            i = i + 1
        elseif word:sub(1, 1) ~= "-" then
            verb_at = i
            break
        end
        i = i + 1
    end
    local name = verb_at and words[verb_at]
    if not (name == "test" or name == "lint") then
        return nil
    end
    local extra
    local k = verb_at + 1
    while k <= #words and words[k] ~= "--" do
        local word = words[k]
        if word == "--remote" then
            remote = true
        elseif registry.VALUE_FLAGS[word] then
            k = k + 1
        elseif not registry.is_bare(word) then
            extra = extra or word
        end
        k = k + 1
    end
    if not (remote and extra) then
        return nil
    end
    return string.format(
        "The row %q gives %q before the double dash. Write `dev --remote %s -- %s` instead.",
        row,
        extra,
        name,
        extra
    )
end

---Say why a checks row is not a plain command.
---
---A row is a command and never shell text, so a character the shell would act on is refused, and
---so is a first word that is a dotted run such as `dev.--remote.lint`, which is a row written with
---dots for spaces. A `dev --remote test` or `dev --remote lint` row with a word before the double
---dash is refused, so a test name must come after the dash. A leading `! ` marks a negated row and
---is allowed.
---@param row string the row as the card holds it
---@return string? message why the row is refused, nil when it is a plain command
function M.refusal(row)
    row = row:match(NEGATED) or row
    local bad = row:match(SHELL_CHARS)
    if bad then
        return string.format(
            "The row %q holds %q, which only a shell reads. A row runs as a plain command.",
            row,
            bad == "\n" and "a line break" or bad
        )
    end
    local first = row:match("%S+")
    if first and not first:find("/", 1, true) and first:find("%.[^.]+%.") then
        return string.format(
            "The row %q starts with the dotted run %q. Write spaces between the words.",
            row,
            first
        )
    end
    return bare_name(row)
end

---Split a checks row into the words of one command.
---
---A leading `! ` marks a negated row and is dropped, since `run` reads it from the row.
---@param row string the row as the card holds it
---@return string[]? argv the command and its arguments
---@return string? message why the row is not a plain command, from `refusal`
function M.argv(row)
    row = row:match(NEGATED) or row
    local message = M.refusal(row)
    if message then
        return nil, message
    end
    local argv = {}
    for word in row:gmatch("%S+") do
        argv[#argv + 1] = word
    end
    if #argv == 0 then
        return nil, "A checks row is blank."
    end
    return argv
end

local function jj_state(root)
    local base = vcs.base(root, vcs.JJ, { quiet = true })
    local out, code = dev_os.capture(
        vcs.with(base, "log", "-r", "@", "--no-graph", "-T", JJ_TEMPLATE),
        { stderr = "null" }
    )
    local commit, change, conflict = out:match("^(%x+) (%a+) (%a+)\n?$")
    if code ~= 0 or not commit then
        return nil, "The `jj` command could not name the working-copy commit of " .. root .. "."
    end
    if conflict == "conflict" then
        return nil,
            "The working-copy commit has conflicts. Its checks mean nothing. Resolve them, then run `dev board check` again."
    end
    return { commit = commit, change = change }
end

local function git_state(root)
    local base = vcs.base(root, vcs.GIT)
    local status, code =
        dev_os.capture(vcs.with(base, "status", "--porcelain"), { stderr = "null" })
    if code ~= 0 then
        return nil, "The `git` command could not read the status of " .. root .. "."
    end
    local dirty = 0
    for _ in status:gmatch("[^\n]+") do
        dirty = dirty + 1
    end
    if dirty > 0 then
        return nil,
            string.format(
                "The working copy is dirty (%d changed paths). "
                    .. "Commit first, then check that commit.",
                dirty
            )
    end
    local head
    head, code = dev_os.capture(vcs.with(base, "rev-parse", "HEAD"), { stderr = "null" })
    head = head:match("^(%x+)\n?$")
    if code ~= 0 or not head then
        return nil, "The `git` command has no commit at HEAD in " .. root .. "."
    end
    return { commit = head, change = NO_CHANGE }
end

---Name the commit a result would belong to.
---
---Refuses a jj working copy that has conflicts and a git tree that is dirty.
---@param root string the project root
---@return dev.board.check.State? state the commit and change
---@return string? message why no commit holds the working copy
function M.state(root)
    local backend, message = vcs.require(root)
    if not backend then
        return nil, message
    end
    if backend == vcs.JJ then
        return jj_state(root)
    end
    return git_state(root)
end

local function last_line(output)
    local last
    for line in output:gmatch("[^\n]+") do
        if line:match("%S") then
            last = line
        end
    end
    return last and last:match("^%s*(.-)%s*$")
end

local function drain_refusal(output)
    for line in output:gmatch("[^\n]+") do
        if
            line:find(DRAIN_REFUSAL, 1, true)
            and line:find(DRAIN_NOTHING_NEW, 1, true)
            and line:find(DRAIN_OFF, 1, true)
        then
            return (line:gsub("^%s+", ""):gsub(ERROR_PREFIX, ""))
        end
    end
end

local function drain_cap_refusal(output)
    for line in output:gmatch("[^\n]+") do
        if line:find(DRAIN_CAP, 1, true) then
            return (line:gsub("^%s+", ""):gsub(ERROR_PREFIX, ""))
        end
    end
    return last_line(output)
end

local function tail_of(output)
    local lines = {}
    for line in output:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    local first = math.max(1, #lines - SHOWN_LINES + 1)
    return table.concat(lines, "\n", first)
end

---@class dev.board.check.RunOpts
---@field root string the project root the row runs in
---@field run string the row
---@field argv string[] the row's words from `argv`, without a leading `! `
---@field seconds integer how long the row may run
---@field env table<string, string>? variables set for the row
---@field on_run_id fun(run_id: string)? called with the row's ci run id once its line is complete
---@field expect_fail boolean? whether the run is meant to show the row failing

---Say whether a row is sent to ci.
---@param argv string[] the row's words
---@return boolean remote true for a `ci` row and a `dev` row that holds `--remote` before the double dash
local function is_remote(argv)
    if argv[1] == CI_COMMAND then
        return true
    end
    if argv[1] ~= DEV_COMMAND then
        return false
    end
    for i = 2, #argv do
        if argv[i] == DOUBLE_DASH then
            return false
        end
        if argv[i] == REMOTE_FLAG then
            return true
        end
    end
    return false
end

---Say whether a row's command never started.
---
---A shell exits 126 for a file it cannot run and 127 for a command it cannot find. A ci row prints
---`run <id>` once its run starts, so a row that exits non-zero without that line never started.
---@param argv string[] the row's words
---@param code integer the exit status
---@param run_id string? the run id the row printed
---@return boolean never true when the command never started
function M.never_started(argv, code, run_id)
    if run_id or code == 0 or code == TIMEOUT_EXIT then
        return false
    end
    if code == NOT_EXECUTABLE_EXIT or code == NOT_FOUND_EXIT then
        return true
    end
    return is_remote(argv)
end

---Run one checks row to its end or its time limit.
---@param opts dev.board.check.RunOpts the row and where it runs
---@return dev.board.check.Row row how it ended
function M.run(opts)
    local pending, announced = "", false
    local function watch(text)
        pending = pending .. text
        while not announced do
            local line, rest = pending:match("^([^\n]*)\n(.*)$")
            if not line then
                return
            end
            pending = rest
            local id = line:match(RUN_LINE)
            if id then
                announced = true
                opts.on_run_id(id)
            end
        end
    end
    local output, code = dev_os.capture_timed(opts.argv, opts.seconds, {
        cwd = opts.root,
        merge = true,
        env = opts.env,
        on_text = opts.on_run_id and watch or nil,
    })
    local negated = opts.run:match(NEGATED) ~= nil
    local passed = code == 0
    local note
    if negated then
        passed = code == 1
        if code == 0 then
            note = "A match was found."
        elseif code ~= 1 and code ~= TIMEOUT_EXIT then
            note = string.format("The command failed with exit %d, which is an error.", code)
        end
    end
    local run_id = M.run_id(output)
    local reason, refused
    if not run_id and code ~= 0 then
        refused = drain_refusal(output)
        if not refused and code == DRAINING_EXIT then
            refused = drain_cap_refusal(output)
        end
    end
    local result = passed and not refused and M.RESULT.PASS or M.RESULT.FAIL
    if code == TIMEOUT_EXIT then
        result = M.RESULT.TIMEOUT
    end
    if result == M.RESULT.FAIL and not run_id and not negated then
        reason = last_line(output)
    end
    if opts.expect_fail and not refused and M.never_started(opts.argv, code, run_id) then
        result = M.RESULT.ERROR
        note = string.format("The row never started (exit %d). Its failure proves nothing.", code)
        reason = reason or last_line(output)
    end
    return {
        run = opts.run,
        run_id = run_id or NO_RUN,
        reason = reason,
        refused = refused,
        result = result,
        code = code,
        tail = note and (note .. "\n" .. tail_of(output)) or tail_of(output),
    }
end

---Find the ci run id a row printed, from the `run <id>` line of `ci run --follow`.
---@param output string the row's output, with standard error in it
---@return string? run_id the id, nil when no line names one
function M.run_id(output)
    for line in output:gmatch("[^\n]+") do
        local id = line:match(RUN_LINE)
        if id then
            return id
        end
    end
    return nil
end

---Write one row's line of a run.
---@param index integer the row's place, counted from 1
---@param row dev.board.check.Row the finished row
---@return string line the line
function M.line(index, row)
    return string.format("%d %s %s %s", index, row.result, row.run_id, row.run)
end

---Count the rows that passed and say whether the run showed what it was meant to.
---@param rows dev.board.check.Row[] the finished rows
---@param expect_fail boolean whether every row was meant to fail
---@return integer passed how many rows passed
---@return boolean good true when every row passed, or with `expect_fail` when none passed or never started
---@return integer errors how many rows never started under `expect_fail`
function M.summarize(rows, expect_fail)
    local passed, errors = 0, 0
    for _, row in ipairs(rows) do
        if row.result == M.RESULT.PASS then
            passed = passed + 1
        elseif row.result == M.RESULT.ERROR then
            errors = errors + 1
        end
    end
    if expect_fail then
        return passed, passed == 0 and errors == 0, errors
    end
    return passed, passed == #rows, errors
end

---Hash a list of checks rows to show whether they changed.
---@param commands string[] the card's checks rows in order
---@return string sum eight lowercase hex digits
function M.fingerprint(commands)
    local hash = FNV_OFFSET
    for _, command in ipairs(commands) do
        for i = 1, #command + 1 do
            local byte = i <= #command and command:byte(i) or NEWLINE_BYTE
            hash = bit.bxor(hash, byte) % FNV_MODULUS
            hash = ((hash % 256) * FNV_HIGH + hash * FNV_LOW) % FNV_MODULUS
        end
    end
    return string.format("%08x", hash)
end

---Write the comment that records a run.
---
---A reason line is cut to 120 bytes and left out once the comment would pass 4800 bytes.
---@param state dev.board.check.State the commit the rows ran on
---@param rows dev.board.check.Row[] the finished rows
---@param expect_fail boolean whether every row was meant to fail
---@return string text the comment body, which begins with the reserved prefix
function M.record(state, rows, expect_fail)
    local commands = {}
    local lines = {}
    local size = 0
    for i, row in ipairs(rows) do
        commands[i] = row.run
        lines[i] = string.format("%d %s %s", i, row.result, row.run_id)
        size = size + #lines[i] + 1
    end
    local head = string.format(
        "%s commit=%s change=%s mode=%s rows=%d sum=%s",
        board.CHECK_PREFIX,
        state.commit,
        state.change,
        expect_fail and M.MODE.EXPECT_FAIL or M.MODE.RUN,
        #rows,
        M.fingerprint(commands)
    )
    size = size + #head
    local out = { head }
    for i, row in ipairs(rows) do
        out[#out + 1] = lines[i]
        local reason = row.reason and (REASON_INDENT .. row.reason:sub(1, REASON_MAX))
        if reason and size + #reason + 1 <= COMMENT_BUDGET_BYTES then
            out[#out + 1] = reason
            size = size + #reason + 1
        end
    end
    return table.concat(out, "\n")
end

---@class dev.board.check.RecordRow
---@field result string how the row ended
---@field run_id string the ci run id, `-` when the row printed none
---@field reason string? the last line a failed row printed when it printed no run id

---@class dev.board.check.Record
---@field commit string the full commit id the rows ran on
---@field change string the change id, `-` in a git project
---@field mode string one of `MODE`
---@field sum string the fingerprint of the checks rows the run used
---@field rows dev.board.check.RecordRow[] the rows in the order they ran

---Read a comment that `record` wrote.
---@param body string the comment body
---@return dev.board.check.Record? record nil when the body is not a record
function M.parse(body)
    local head, rest = body:match("^([^\n]*)\n?(.*)$")
    local prefix, commit, change, mode, count, sum =
        head:match("^(%S+) commit=(%x+) change=(%S+) mode=(%S+) rows=(%d+) sum=(%x+)$")
    if prefix ~= board.CHECK_PREFIX then
        return nil
    end
    local rows = {}
    for line in rest:gmatch("[^\n]+") do
        local reason = line:match("^%s+(%S.*)$")
        if reason then
            if #rows == 0 or rows[#rows].reason then
                return nil
            end
            rows[#rows].reason = reason
        else
            local index, result, run_id = line:match("^(%d+) (%a+) (%S+)$")
            if not index or tonumber(index) ~= #rows + 1 then
                return nil
            end
            if run_id ~= NO_RUN and not run_id:match("^%x+$") then
                return nil
            end
            rows[#rows + 1] = { result = result, run_id = run_id }
        end
    end
    if #rows ~= tonumber(count) then
        return nil
    end
    return { commit = commit, change = change, mode = mode, sum = sum, rows = rows }
end

---Read the commit of a comment that carries a record's head but does not parse.
---@param body string the comment body
---@return string? commit the full commit id, nil when the body has no record head or parses as a
---   record
---@return string? mode the mode the head names, nil when it names none
function M.unreadable(body)
    local prefix, commit = body:match("^(%S+) commit=(%x+)")
    if prefix == board.CHECK_PREFIX and not M.parse(body) then
        return commit, body:match("^[^\n]* mode=(%S+)")
    end
end

return M
