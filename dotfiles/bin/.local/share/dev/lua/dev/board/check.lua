local board = require("dev.board")
local devos = require("dev.os")
local vcs = require("dev.vcs")

---@class dev.board.check
local M = {}

---The seconds a checks row may run when `--timeout` is not given.
M.DEFAULT_SECONDS = 1800

---The most seconds `--timeout` accepts.
M.MAX_SECONDS = 86400

local SHELL_CHARS = "[|&;<>()$`\\\"'*?\n]"
local JJ_TEMPLATE = 'commit_id ++ " " ++ change_id ++ " " ++ if(conflict, "conflict", "clean")'
local SHOWN_LINES = 12
local NO_CHANGE = "-"
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
---@field result string one of `RESULT`, where a timeout also covers a row killed from outside
---@field code integer the exit status
---@field tail string the last lines the run printed

---Split a checks row into the words of one command.
---
---A row is a command and never shell text, so a character the shell would act on is refused.
---@param row string the row as the card holds it
---@return string[]? argv the command and its arguments
---@return string? message why the row is not a plain command
function M.argv(row)
    local bad = row:match(SHELL_CHARS)
    if bad then
        return nil,
            string.format(
                "the row %q holds %q, which only a shell reads, and a row runs as a plain command",
                row,
                bad == "\n" and "a line break" or bad
            )
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
---@field argv string[] the row's words from `argv`
---@field seconds integer how long the row may run

---Run one checks row to its end or its time limit.
---@param opts dev.board.check.RunOpts the row and where it runs
---@return dev.board.check.Row row how it ended
function M.run(opts)
    local output, code =
        devos.capture_timed(opts.argv, opts.seconds, { cwd = opts.root, merge = true })
    local result = code == 0 and M.RESULT.PASS or M.RESULT.FAIL
    if code == TIMEOUT_EXIT then
        result = M.RESULT.TIMEOUT
    end
    return { run = opts.run, result = result, code = code, tail = tail_of(output) }
end

---Write one row's line of a run.
---@param index integer the row's place, counted from 1
---@param row dev.board.check.Row the finished row
---@return string line the line
function M.line(index, row)
    return string.format("%d %s %s", index, row.result, row.run)
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

return M
