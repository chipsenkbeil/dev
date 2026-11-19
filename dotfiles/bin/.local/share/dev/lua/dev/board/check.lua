local bit = require("bit")
local board = require("dev.board")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
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
local RG_COMMAND = "rg"
local RG_USAGE_EXIT = 2
---The rg flags that take a value word
local RG_VALUE_FLAGS = {
    ["--color"] = true,
    ["--sort"] = true,
    ["--sortr"] = true,
    ["-E"] = true,
    ["--encoding"] = true,
    ["--max-filesize"] = true,
    ["--max-columns"] = true,
    ["--ignore-file"] = true,
    ["--type-add"] = true,
    ["--iglob"] = true,
    ["-e"] = true,
    ["-f"] = true,
    ["-g"] = true,
    ["-t"] = true,
    ["-T"] = true,
    ["-A"] = true,
    ["-B"] = true,
    ["-C"] = true,
    ["-m"] = true,
    ["-r"] = true,
    ["-j"] = true,
    ["-M"] = true,
    ["-d"] = true,
    ["--glob"] = true,
    ["--type"] = true,
    ["--type-not"] = true,
    ["--regexp"] = true,
    ["--file"] = true,
    ["--max-count"] = true,
    ["--replace"] = true,
    ["--max-depth"] = true,
    ["--threads"] = true,
    ["--after-context"] = true,
    ["--before-context"] = true,
    ["--context"] = true,
}
---The rg flags that supply the pattern
local RG_PATTERN_FLAGS = { ["-e"] = true, ["-f"] = true, ["--regexp"] = true, ["--file"] = true }
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
local STATE_SECONDS = 20
local STANDARD_TEST = "test"
local STANDARD_JOBS = { lint = true, [STANDARD_TEST] = true }
local STANDARD_ROWS = { ["dev --remote lint"] = true, ["dev --remote test"] = true }
local LOGS_SECONDS = 60

---How a checks row ended.
---@enum dev.board.check.Result
M.Result = { PASS = "pass", FAIL = "fail", TIMEOUT = "timeout", ERROR = "error" }

---What a run was meant to show, as the record names it.
---@enum dev.board.check.Mode
M.Mode = { RUN = "run", EXPECT_FAIL = "expect-fail" }

---@class dev.board.check.State
---@field commit string the full commit id the result belongs to
---@field change string the change id in a jj project, `-` in a git one
---@field proof string? the trunk proof an expect-fail run relied on, which `record` writes

---@class dev.board.check.Row
---@field run string the row's command as the card holds it
---@field run_id string the ci run id the row printed, `-` when it printed none
---@field result string one of `Result`, where a timeout also covers a row killed from outside and an error is a row that never started under `--expect-fail`
---@field code integer the exit status
---@field tail string the last lines the run printed
---@field failed string[]? the paths on the `FAIL PATH` lines the run printed, which the test runner prints
---@field cases string[]? the `not ok - NAME` names printed under each failing file, or the file's path when it printed none
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

---List the paths an rg row names after its pattern.
---@param words string[] the row's words, rg first
---@return string[] paths the positional words that follow the pattern
local function rg_paths(words)
    local paths, patterned, positional = {}, false, false
    local i = 2
    while i <= #words do
        local word = words[i]
        if word == "--" and not positional then
            positional = true
        elseif not positional and RG_VALUE_FLAGS[word] then
            patterned = patterned or RG_PATTERN_FLAGS[word] == true
            i = i + 1
        elseif positional or word:sub(1, 1) ~= "-" then
            if patterned then
                paths[#paths + 1] = word
            else
                patterned = true
            end
        end
        i = i + 1
    end
    return paths
end

---Say whether a program named `name` sits in a PATH directory, which a shell builtin does not.
---@param name string the first word of a row
---@return boolean found true when a PATH directory holds an executable of that name
local function on_path(name)
    for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
        if fs.is_exec(fs.join(dir, name)) then
            return true
        end
    end
    return false
end

---Say why a checks row can never run in the workspace at `root`.
---@param row string the row as the card holds it
---@param root string the workspace the row runs in
---@return string? message why the row cannot run, nil when it can
function M.unrunnable(row, root)
    row = row:match(NEGATED) or row
    local words = {}
    for word in row:gmatch("%S+") do
        words[#words + 1] = word
    end
    local first = words[1]
    if not first then
        return nil
    end
    if not first:find("/", 1, true) and not on_path(first) then
        return string.format("The row %q runs %q, which is not on PATH.", row, first)
    end
    if first ~= RG_COMMAND then
        return nil
    end
    for _, path in ipairs(rg_paths(words)) do
        local full = path:sub(1, 1) == "/" and path or fs.join(root, path)
        if not fs.exists(full) then
            return string.format(
                "The row %q gives rg the word %q, which is not a path in the workspace. "
                    .. "A row has no quoting, so write a pattern without a space.",
                row,
                path
            )
        end
    end
    return nil
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

local function hub_refusal(output, code)
    local refused = drain_refusal(output)
    if not refused and code == DRAINING_EXIT then
        refused = drain_cap_refusal(output)
    end
    return refused
end

local function tail_of(output)
    local lines = {}
    for line in output:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    local first = math.max(1, #lines - SHOWN_LINES + 1)
    return table.concat(lines, "\n", first)
end

local function failed_files(output)
    local seen, files = {}, {}
    for path in output:gmatch("%f[%w]FAIL ([%w_./%-]+%.%w+)") do
        if not seen[path] then
            seen[path] = true
            files[#files + 1] = path
        end
    end
    return files
end

local function failed_cases(output, files)
    local under, header = {}, nil
    for line in output:gmatch("[^\n]+") do
        local path = line:match("^> (.+)$")
        local name = line:match("^not ok %- (.+)$")
        if path then
            header = path
        elseif name and header then
            under[header] = under[header] or {}
            table.insert(under[header], name)
        end
    end
    local seen, cases = {}, {}
    for _, path in ipairs(files) do
        for _, key in ipairs(under[path] or { path }) do
            if not seen[key] then
                seen[key] = true
                cases[#cases + 1] = key
            end
        end
    end
    return cases
end

---@class dev.board.check.run.Opts
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

---Say what state the ci run of a row that hit its limit was in.
---@param run_id string the ci run id the row printed
---@return string reason one sentence for the record, short enough to keep
local function timeout_reason(run_id)
    local out, code = dev_os.capture_timed({ CI_COMMAND, "ps", run_id, "--json" }, STATE_SECONDS)
    local doc = code == 0 and json.decode(out) or nil
    local status = type(doc) == "table" and doc.status or nil
    if type(status) ~= "string" then
        return "The ci run state could not be read at the limit."
    end
    return "The ci run was " .. status .. " at the limit and may still finish."
end

---Make the `on_text` callback that hands the first `run <id>` line to `on_run_id`.
---@param on_run_id fun(run_id: string)? called once with the id, nil to watch nothing
---@return (fun(text: string))? watch the callback, nil when nothing is watched
local function run_id_watcher(on_run_id)
    if not on_run_id then
        return nil
    end
    local pending, announced = "", false
    return function(text)
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
                on_run_id(id)
            end
        end
    end
end

---Run one checks row to its end or its time limit.
---@param opts dev.board.check.run.Opts the row and where it runs
---@return dev.board.check.Row row how it ended
function M.run(opts)
    local output, code = dev_os.capture_timed(opts.argv, opts.seconds, {
        cwd = opts.root,
        merge = true,
        env = opts.env,
        on_text = run_id_watcher(opts.on_run_id),
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
        refused = hub_refusal(output, code)
    end
    local result = passed and not refused and M.Result.PASS or M.Result.FAIL
    if code == TIMEOUT_EXIT then
        result = M.Result.TIMEOUT
    end
    if result == M.Result.FAIL and not run_id and not negated then
        reason = last_line(output)
    end
    if result == M.Result.TIMEOUT and run_id then
        reason = timeout_reason(run_id)
        note = note or reason
    end
    if opts.argv[1] == RG_COMMAND and code == RG_USAGE_EXIT then
        result = M.Result.ERROR
        note = "The row is an error, not a fail: rg exited 2, so it could not search."
        reason = reason or last_line(output)
    end
    if opts.expect_fail and not refused and M.never_started(opts.argv, code, run_id) then
        result = M.Result.ERROR
        note = string.format("The row never started (exit %d). Its failure proves nothing.", code)
        reason = reason or last_line(output)
    end
    local files = failed_files(output)
    return {
        run = opts.run,
        run_id = run_id or NO_RUN,
        reason = reason,
        refused = refused,
        result = result,
        code = code,
        tail = note and (note .. "\n" .. tail_of(output)) or tail_of(output),
        failed = files,
        cases = failed_cases(output, files),
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

---@class dev.board.check.GroupRow
---@field index integer the row's place in the card's checks, counted from 1
---@field job string the ci job the row runs
---@field run string the row as the card holds it

---@class dev.board.check.Plan
---@field rows dev.board.check.GroupRow[] the rows that share one ci run, in the card's order
---@field args string[] the words after the double dash of the one row that has any

---Read the job and the words after the double dash of a `dev --remote JOB [-- WORDS]` row.
---@param argv string[] the row's words
---@return string? job the job name, nil when the row is any other command
---@return string[]? words the words after the double dash
function M.job_row(argv)
    local job = argv[3]
    if argv[1] ~= DEV_COMMAND or argv[2] ~= REMOTE_FLAG or not job or not job:match("^[%w_]+$") then
        return nil
    end
    local words = {}
    if argv[4] ~= nil then
        if argv[4] ~= DOUBLE_DASH then
            return nil
        end
        for i = 5, #argv do
            words[#words + 1] = argv[i]
        end
    end
    return job, words
end

---@class dev.board.check.Baseline
---@field commands string[] the rows the baseline runs, as the card holds them
---@field argvs string[][] the rows' words, without a leading `! `
---@field skipped integer how many standard rows the baseline leaves out

---Choose the rows an `--expect-fail` baseline runs.
---
---The standard rows are the plain `dev --remote lint` and `dev --remote test` rows. Only a row the
---card adds can fail on unchanged code, so the baseline drops the standard rows. It keeps the
---standard test row when a new row is a test, which is a `dev --remote test` row with words after
---the double dash. A card whose rows are all standard keeps every row.
---@param commands string[] the card's checks rows as it holds them
---@param argvs string[][] the rows' words, without a leading `! `
---@return dev.board.check.Baseline baseline the rows to run
function M.baseline(commands, argvs)
    local standard, new_test = {}, false
    for i, argv in ipairs(argvs) do
        local job, words = nil, nil
        if not commands[i]:match(NEGATED) then
            job, words = M.job_row(argv)
        end
        if job and STANDARD_JOBS[job] and #words == 0 then
            standard[i] = job
        elseif job == STANDARD_TEST then
            new_test = true
        end
    end
    local baseline = { commands = {}, argvs = {}, skipped = 0 }
    for i, argv in ipairs(argvs) do
        if standard[i] and not (standard[i] == STANDARD_TEST and new_test) then
            baseline.skipped = baseline.skipped + 1
        else
            baseline.commands[#baseline.commands + 1] = commands[i]
            baseline.argvs[#baseline.argvs + 1] = argv
        end
    end
    if #baseline.commands == 0 then
        return { commands = commands, argvs = argvs, skipped = 0 }
    end
    return baseline
end

---Choose the rows of a card that run as one ci run.
---
---The rows qualify when two or more are plain `dev --remote JOB` rows of different jobs, at most
---one passes words, and the jobs are exactly the jobs the default pipeline holds. A ci run without
---`--job` starts every job of the pipeline and hands the same words to each.
---@param commands string[] the card's checks rows as it holds them
---@param argvs string[][] the rows' words, without a leading `! `
---@param list_jobs fun(): string[]? the default pipeline's job names, called for a candidate only
---@return dev.board.check.Plan? plan nil when every row runs on its own
function M.plan(commands, argvs, list_jobs)
    local rows, seen, args = {}, {}, nil
    for i, argv in ipairs(argvs) do
        local job, words = nil, nil
        if not commands[i]:match(NEGATED) then
            job, words = M.job_row(argv)
        end
        if job then
            if seen[job] or (#words > 0 and args) then
                return nil
            end
            seen[job] = true
            args = #words > 0 and words or args
            rows[#rows + 1] = { index = i, job = job, run = commands[i] }
        end
    end
    if #rows < 2 then
        return nil
    end
    local names = list_jobs()
    if not names or #names ~= #rows then
        return nil
    end
    for _, name in ipairs(names) do
        if not seen[name] then
            return nil
        end
    end
    return { rows = rows, args = args or {} }
end

---Choose the one row of a one-row card as a plan, to record a run that already started.
---@param commands string[] the card's checks rows as it holds them
---@param argvs string[][] the rows' words, without a leading `! `
---@return dev.board.check.Plan? plan nil unless the card has one plain `dev --remote JOB` row
function M.single_plan(commands, argvs)
    if #argvs ~= 1 or commands[1]:match(NEGATED) then
        return nil
    end
    local job, words = M.job_row(argvs[1])
    if not job then
        return nil
    end
    return { rows = { { index = 1, job = job, run = commands[1] } }, args = words }
end

---Read how each job of a ci run ended.
---@param run_id string the ci run id
---@return table<string, {passed: boolean, code: integer}>? jobs by job name, nil when ci cannot say
local function job_results(run_id)
    local out, code = dev_os.capture_timed({ CI_COMMAND, "ps", run_id, "--json" }, STATE_SECONDS)
    local doc = code == 0 and json.decode(out) or nil
    if type(doc) ~= "table" or type(doc.jobs) ~= "table" then
        return nil
    end
    local results = {}
    for _, entry in ipairs(doc.jobs) do
        if type(entry) == "table" and type(entry.name) == "string" then
            local seen = results[entry.name] or { passed = true, code = 0 }
            local failed = entry.state ~= "passed"
            seen.passed = seen.passed and not failed
            if failed and seen.code == 0 then
                seen.code = type(entry.exit_code) == "number"
                        and entry.exit_code ~= 0
                        and entry.exit_code
                    or 1
            end
            results[entry.name] = seen
        end
    end
    return results
end

---Read the last lines one job of a ci run printed.
---@param run_id string the ci run id
---@param job string the job name
---@return string tail the lines, empty when ci cannot say
local function job_tail(run_id, job)
    local argv = { CI_COMMAND, "logs", run_id, "--job", job }
    local out = dev_os.capture_timed(argv, LOGS_SECONDS, { merge = true })
    return tail_of(out)
end

---@class dev.board.check.run_group.Opts
---@field root string the project root the run starts in
---@field plan dev.board.check.Plan the rows that share the run
---@field seconds integer how long the run may take
---@field env table<string, string>? variables set for the run
---@field on_run_id fun(run_id: string)? called with the run's ci run id once its line is complete
---@field attach string? the id of a ci run that already started, which is waited on, not started

---Find the commit a ci run holds.
---@param run_id string the ci run id
---@return string? commit the commit id ci shows, nil when ci cannot say
function M.run_commit(run_id)
    local out, code = dev_os.capture_timed({ CI_COMMAND, "ps", run_id, "--json" }, STATE_SECONDS)
    local doc = code == 0 and json.decode(out) or nil
    local source = type(doc) == "table" and doc.source
    return type(source) == "string" and source:match("@(%x+)$") or nil
end

---Run the rows of a plan as one ci run and read each row's result from its job.
---
---With `attach` the run is the named one, and the wait is `ci ps RUN --watch`, which returns at once
---for a run that has ended.
---@param opts dev.board.check.run_group.Opts the plan and where it runs
---@return dev.board.check.Row[] rows one per plan row, in the plan's order, all with the one run id
function M.run_group(opts)
    local argv
    if opts.attach then
        argv = { CI_COMMAND, "-C", opts.root, "ps", opts.attach, "--watch" }
    else
        argv = { CI_COMMAND, "-C", opts.root, "run", "--local", "--follow", DOUBLE_DASH }
        for _, word in ipairs(opts.plan.args) do
            argv[#argv + 1] = word
        end
    end
    local output, code = dev_os.capture_timed(argv, opts.seconds, {
        cwd = opts.root,
        merge = true,
        env = opts.env,
        on_text = run_id_watcher(opts.on_run_id),
    })
    local run_id = opts.attach or M.run_id(output)
    local refused = not run_id and code ~= 0 and hub_refusal(output, code) or nil
    local timed_out = code == TIMEOUT_EXIT
    local reason = timed_out and run_id and timeout_reason(run_id) or nil
    local results = run_id and not timed_out and job_results(run_id) or nil
    local rows = {}
    for k, entry in ipairs(opts.plan.rows) do
        local found = results and results[entry.job]
        local row = {
            run = entry.run,
            run_id = run_id or NO_RUN,
            refused = refused,
            result = M.Result.PASS,
            code = 0,
            tail = "",
        }
        if timed_out then
            row.result, row.code, row.reason = M.Result.TIMEOUT, code, reason
            row.tail = tail_of(output)
            if reason then
                row.tail = reason .. "\n" .. row.tail
            end
        elseif not (found and found.passed) and not (code == 0 and not results) then
            row.result = M.Result.FAIL
            row.code = found and found.code or (code ~= 0 and code or 1)
            if not found then
                row.reason = run_id and "The ci run state could not be read." or last_line(output)
            end
            row.tail = run_id and found and job_tail(run_id, entry.job) or tail_of(output)
        end
        rows[k] = row
    end
    return rows
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
---@return boolean good true when every row passed, or with `expect_fail` when no row but a plain lint or test row passed, none never started and one failed
---@return integer errors how many rows never started under `expect_fail`
---@return integer proves_nothing how many passing rows other than the plain lint and test rows
function M.summarize(rows, expect_fail)
    local passed, errors, proves_nothing = 0, 0, 0
    for _, row in ipairs(rows) do
        if row.result == M.Result.PASS then
            passed = passed + 1
            if not STANDARD_ROWS[row.run] then
                proves_nothing = proves_nothing + 1
            end
        elseif row.result == M.Result.ERROR then
            errors = errors + 1
        end
    end
    if expect_fail then
        return passed,
            proves_nothing == 0 and errors == 0 and passed < #rows,
            errors,
            proves_nothing
    end
    return passed, passed == #rows, errors, proves_nothing
end

---Sum a list of checks rows into a value that differs when a row changes.
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
---A reason line is left out when it would push the comment past its 4800-byte budget.
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
        expect_fail and M.Mode.EXPECT_FAIL or M.Mode.RUN,
        #rows,
        M.fingerprint(commands)
    )
    if state.proof then
        head = head .. " proof=" .. state.proof
    end
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
---@field mode string one of `Mode`
---@field sum string the fingerprint of the checks rows the run used
---@field proof string? the trunk proof an expect-fail run relied on, as `CARD@COMMIT`
---@field rows dev.board.check.RecordRow[] the rows in the order they ran

---Read a comment that `record` wrote.
---@param body string the comment body
---@return dev.board.check.Record? record nil when the body is not a record
function M.parse(body)
    local head, rest = body:match("^([^\n]*)\n?(.*)$")
    local bare, proof = head:match("^(.*) proof=(%S+)$")
    head = bare or head
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
    return { commit = commit, change = change, mode = mode, sum = sum, rows = rows, proof = proof }
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
