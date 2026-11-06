local board = require("dev.board")
local devos = require("dev.os")
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
local TIMEOUT_EXIT = 124

---How a checks row ended.
M.RESULT = { PASS = "pass", FAIL = "fail", TIMEOUT = "timeout" }

---What a run was meant to show, as the record names it.
M.MODE = { RUN = "run", EXPECT_FAIL = "expect-fail" }

---@class dev.board.check.State
---@field commit string the full commit id the result belongs to
---@field change string the change id in a jj project, `-` in a git one

---@class dev.board.check.Row
---@field run string the row's command as the card holds it
---@field run_id string the ci run id the row printed, `-` when it printed none
---@field result string one of `RESULT`, where a timeout also covers a row killed from outside
---@field code integer the exit status
---@field tail string the last lines the run printed

---Say why a checks row is not a plain command.
---
---A row is a command and never shell text, so a character the shell would act on is refused, and
---so is a first word that is a dotted run such as `dev.--remote.lint`, which is a row written with
---dots for spaces. A leading `! ` marks a negated row and is allowed.
---@param row string the row as the card holds it
---@return string? message why the row is refused, nil when it is a plain command
function M.refusal(row)
    row = row:match(NEGATED) or row
    local bad = row:match(SHELL_CHARS)
    if bad then
        return string.format(
            "the row %q holds %q, which only a shell reads, and a row runs as a plain command",
            row,
            bad == "\n" and "a line break" or bad
        )
    end
    local first = row:match("%S+")
    if first and not first:find("/", 1, true) and first:find("%.[^.]+%.") then
        return string.format(
            "the row %q starts with the dotted run %q, so write spaces between the words",
            row,
            first
        )
    end
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
        return nil, "a checks row is blank"
    end
    return argv
end

local function jj_state(root)
    local base = vcs.base(root, vcs.JJ, { quiet = true })
    local out, code = devos.capture(
        vcs.with(base, "log", "-r", "@", "--no-graph", "-T", JJ_TEMPLATE),
        { stderr = "null" }
    )
    local commit, change, conflict = out:match("^(%x+) (%a+) (%a+)\n?$")
    if code ~= 0 or not commit then
        return nil, "jj could not name the working-copy commit of " .. root
    end
    if conflict == "conflict" then
        return nil, "the working-copy commit has conflicts, so its checks mean nothing"
    end
    return { commit = commit, change = change }
end

local function git_state(root)
    local base = vcs.base(root, vcs.GIT)
    local status, code = devos.capture(vcs.with(base, "status", "--porcelain"), { stderr = "null" })
    if code ~= 0 then
        return nil, "git could not read the status of " .. root
    end
    local dirty = 0
    for _ in status:gmatch("[^\n]+") do
        dirty = dirty + 1
    end
    if dirty > 0 then
        return nil,
            string.format(
                "the working copy is dirty (%d changed paths), so commit first and check that commit",
                dirty
            )
    end
    local head
    head, code = devos.capture(vcs.with(base, "rev-parse", "HEAD"), { stderr = "null" })
    head = head:match("^(%x+)\n?$")
    if code ~= 0 or not head then
        return nil, "git has no commit at HEAD in " .. root
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

---Run one checks row to its end or its time limit.
---@param opts dev.board.check.RunOpts the row and where it runs
---@return dev.board.check.Row row how it ended
function M.run(opts)
    local output, code = devos.capture_timed(
        opts.argv,
        opts.seconds,
        { cwd = opts.root, merge = true, env = opts.env }
    )
    local negated = opts.run:match(NEGATED) ~= nil
    local passed = code == 0
    local note
    if negated then
        passed = code == 1
        if code == 0 then
            note = "a match was found"
        elseif code ~= 1 and code ~= TIMEOUT_EXIT then
            note = string.format("the command failed with exit %d, which is an error", code)
        end
    end
    local result = passed and M.RESULT.PASS or M.RESULT.FAIL
    if code == TIMEOUT_EXIT then
        result = M.RESULT.TIMEOUT
    end
    return {
        run = opts.run,
        run_id = M.run_id(output) or NO_RUN,
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
        local id = line:match("^run (%x+)$")
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
---@return boolean good true when every row passed, or with `expect_fail` when none did
function M.summarize(rows, expect_fail)
    local passed = 0
    for _, row in ipairs(rows) do
        if row.result == M.RESULT.PASS then
            passed = passed + 1
        end
    end
    if expect_fail then
        return passed, passed == 0
    end
    return passed, passed == #rows
end

---Write the comment that records a run.
---@param state dev.board.check.State the commit the rows ran on
---@param rows dev.board.check.Row[] the finished rows
---@param expect_fail boolean whether every row was meant to fail
---@return string text the comment body, which begins with the reserved prefix
function M.record(state, rows, expect_fail)
    local lines = {
        string.format(
            "%s commit=%s change=%s mode=%s",
            board.CHECK_PREFIX,
            state.commit,
            state.change,
            expect_fail and M.MODE.EXPECT_FAIL or M.MODE.RUN
        ),
    }
    for i, row in ipairs(rows) do
        lines[#lines + 1] = M.line(i, row)
    end
    return table.concat(lines, "\n")
end

---@class dev.board.check.Record
---@field commit string the full commit id the rows ran on
---@field change string the change id, `-` in a git project
---@field mode string one of `MODE`
---@field rows {result: string, run_id: string, run: string}[] the rows in the order they ran

---Read a comment that `record` wrote.
---@param body string the comment body
---@return dev.board.check.Record? record nil when the body is not a record
function M.parse(body)
    local head, rest = body:match("^([^\n]*)\n?(.*)$")
    local prefix, commit, change, mode = head:match("^(%S+) commit=(%x+) change=(%S+) mode=(%S+)$")
    if prefix ~= board.CHECK_PREFIX then
        return nil
    end
    local rows = {}
    for line in rest:gmatch("[^\n]+") do
        local index, result, run_id, run = line:match("^(%d+) (%a+) (%S+) (.+)$")
        if not index or tonumber(index) ~= #rows + 1 then
            return nil
        end
        if run_id ~= NO_RUN and not run_id:match("^%x+$") then
            return nil
        end
        rows[#rows + 1] = { result = result, run_id = run_id, run = run }
    end
    return { commit = commit, change = change, mode = mode, rows = rows }
end

---Read the commit of a comment that carries a record's head but does not parse.
---@param body string the comment body
---@return string? commit the full commit id, nil when the body has no record head or parses as a record
---@return string? mode the mode the head names, nil when it names none
function M.unreadable(body)
    local prefix, commit = body:match("^(%S+) commit=(%x+)")
    if prefix == board.CHECK_PREFIX and not M.parse(body) then
        return commit, body:match("^[^\n]* mode=(%S+)")
    end
end

return M
