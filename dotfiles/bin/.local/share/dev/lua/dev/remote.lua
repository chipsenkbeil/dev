local config = require("dev.config")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local dev_command = require("dev.command")

local stderr = io.stderr

local UNSAFE_WORD = "[^%w_%-%./:=@%%%+,]"

local JOB_NAME = "^[A-Za-z0-9-]+$"
local LOCAL_HINT = "Rerun it, or pass `--local` to run it here."
local AGENT_HINT = "An agent runs it on ci, so fix ci and rerun."

---@class dev.remote.Run
---@field words string[] the command words, a parent command and its subcommand as two
---@field args string[] the arguments for the job, untouched
---@field detach boolean whether `--detach` was given
---@field priority boolean whether `--priority` was given
---@field job_timeout string|nil the `--job-timeout` duration for `ci run --timeout`
---@field root string absolute path of the project root
---@field verbose integer 0, or 1 or 2 for `-v` or `-vv`

---@class dev.remote.Flags
---@field detach boolean whether to start the job and return
---@field priority boolean whether to start its ci jobs ahead of normal ones
---@field job_timeout string? the run's time limit
---@field never_remote boolean? whether the command declares `remote: false`

---@class dev.remote
local M = {}

---Path of the file ci writes into a dev box, which `DEV_BOX_MARKER` overrides.
M.BOX_MARKER = "/etc/ci-box"

---Check whether dev runs inside a ci job (`CI=true`) or a dev box.
---@return boolean
function M.is_remote_host()
    local marker = os.getenv("DEV_BOX_MARKER")
    return os.getenv("CI") == "true"
        or fs.exists(marker ~= nil and marker ~= "" and marker or M.BOX_MARKER)
end

---Check whether `ci` lists a job for the command, for the remote default.
---A project with no pipeline file has no job and `ci` is not asked. A missing
---`ci` or a failed listing ends the process with the hint, `LOCAL_HINT` unless
---the caller passes another.
---@param root string the project root
---@param words string[] the command words
---@param hint string? the text added to a failed ci error, else `LOCAL_HINT`
---@return boolean
function M.has_default_job(root, words, hint)
    hint = hint or LOCAL_HINT
    local job = table.concat(words, "-")
    if not job:find(JOB_NAME) then
        return false
    end
    local pipelines = fs.list(root .. "/.ci") or {}
    local found = false
    for _, name in ipairs(pipelines) do
        found = found or name:find("%.lua$") ~= nil
    end
    if not found then
        return false
    end
    if not dev_os.which("ci") then
        stderr:write("The ci client is not on PATH. ", hint, "\n")
        os.exit(1)
    end
    return M.has_job(root, job, nil, hint)
end

---Check whether an agent's local run must be refused: the command declares no
---`remote: false` and `ci` lists its default job, which the agent runs on ci.
---@param root string the project root
---@param words string[] the command words
---@param never_remote boolean whether the command declares `remote: false`
---@return boolean
function M.refuses_agent_local(root, words, never_remote)
    return not never_remote and M.has_default_job(root, words, AGENT_HINT)
end

---List the job names of the default pipeline.
---@param root string the project root
---@return string[]? names the job names in `ci` order, nil when `ci` cannot list them
function M.default_jobs(root)
    local out, code = dev_os.capture(
        { "ci", "-C", root, "run", "--list", "--json" },
        { stderr = "null" }
    )
    local doc = code == 0 and json.decode(out)
    if type(doc) ~= "table" or type(doc.jobs) ~= "table" then
        return nil
    end
    local names = {}
    for _, entry in ipairs(doc.jobs) do
        if type(entry) == "table" and type(entry.name) == "string" then
            names[#names + 1] = entry.name
        end
    end
    return names
end

---Check whether a pipeline lists a job.
---@param root string the project root
---@param job string the job name
---@param pipeline string? a pipeline under `.ci/`, else the default one
---@param hint string? text added to the error line of a failed listing
---@return boolean
function M.has_job(root, job, pipeline, hint)
    local errfile = fs.mktemp({ prefix = "dev-remote" })
    local list = { "ci", "-C", root, "run", "--list" }
    if pipeline then
        list[#list + 1] = pipeline
    end
    list[#list + 1] = "--json"
    local out, code = dev_os.capture(list, { stderr = errfile })
    local detail = errfile and fs.read(errfile) or ""
    if errfile then
        fs.remove(errfile)
    end
    local doc = code == 0 and json.decode(out)
    if code ~= 0 or type(doc) ~= "table" or type(doc.jobs) ~= "table" then
        detail = detail:gsub("%s+$", "")
        stderr:write(
            "The command `ci run --list` failed.",
            detail ~= "" and (" The error was: " .. detail .. ".") or "",
            hint and (" " .. hint) or "",
            "\n"
        )
        os.exit(code ~= 0 and code or 1)
    end
    for _, entry in ipairs(doc.jobs) do
        if type(entry) == "table" and entry.name == job then
            return true
        end
    end
    return false
end

local function trace(argv, verbosity)
    if verbosity >= 1 then
        stderr:write("+ ", table.concat(argv, " "), "\n")
    end
end

---The environment variable that names the command of a ci run, as `DEV_CI_COMMAND`.
M.COMMAND_ENV = "DEV_CI_COMMAND"

---The environment variable that names the card of a ci run, as `DEV_CI_CARD`.
M.CARD_ENV = "DEV_CI_CARD"

---The environment variable that starts the ci run ahead of normal jobs, as `DEV_CI_PRIORITY=1`.
M.PRIORITY_ENV = "DEV_CI_PRIORITY"

---The commands dev puts in a ci run label when the caller names none.
---@enum dev.remote.Verb
M.Verb = { CHECK = "check", REMOTE = "remote", RELEASE = "release" }

---Name the ci run dev starts, as `repo/command` or `repo/command/card`.
---@param root string the project root
---@param verb_name string the role, such as `remote`, `check`, `land` or `release`
---@param card string? the card's short id
---@return string label
local function label(root, verb_name, card)
    local name = (config.get(root, "board.name") or fs.basename(root)) .. "/" .. verb_name
    if card ~= nil and card ~= "" then
        name = name .. "/" .. card
    end
    return name
end

---@class dev.remote.run_label.Opts
---@field tty boolean whether stdin is a terminal

---Choose the `DEV_AGENT` label for a run dev starts on ci.
---
---A check run is always labelled by its command and card. Otherwise a caller's non-empty
---`DEV_AGENT` wins, a bare run from a terminal carries none, and any other run is
---labelled by its command and card.
---@param root string the project root
---@param env table<string, string?> `DEV_AGENT`, `DEV_CI_COMMAND` and `DEV_CI_CARD`
---@param opts dev.remote.run_label.Opts
---@return string? name the label to set, or nil to set none
function M.run_label(root, env, opts)
    local verb_name = env.DEV_CI_COMMAND
    if verb_name == M.Verb.CHECK then
        return label(root, verb_name, env.DEV_CI_CARD)
    end
    if env.DEV_AGENT ~= nil and env.DEV_AGENT ~= "" then
        return nil
    end
    if verb_name == nil or verb_name == "" then
        if opts.tty then
            return nil
        end
        verb_name = M.Verb.REMOTE
    end
    return label(root, verb_name, env.DEV_CI_CARD)
end

---@class dev.remote.ci_runner.Opts
---@field verbosity integer 1 or more prints the ci command first
---@field pipeline? string a pipeline under `.ci/` to run the job from, else the default one

---Run a job on ci and return its exit code.
---@param run dev.remote.Run
---@param opts dev.remote.ci_runner.Opts
---@return integer code
function M.ci_runner(run, opts)
    local pipeline = opts.pipeline
    local job = table.concat(run.words, "-")
    if not job:find(JOB_NAME) then
        dev_command.die(
            "The flag `--remote` needs a job name, not " .. table.concat(run.words, " ") .. "."
        )
    end
    if not dev_os.which("ci") then
        stderr:write(
            "The ci client is not found. Install it with `dev install` from the ci repo.\n"
        )
        return 1
    end
    if not M.has_job(run.root, job, pipeline) then
        dev_command.die(
            "No job named "
                .. job
                .. " exists in the project's "
                .. (pipeline and ("pipeline " .. pipeline) or "default pipeline (.ci/jobs.lua)")
                .. ". Add one to run it with `--remote`."
        )
    end
    local argv = { "ci", "-C", run.root, "run" }
    if pipeline then
        argv[#argv + 1] = pipeline
    end
    local mode = run.detach and "--detach" or "--follow"
    local words = { "--local", mode, "--job", job }
    if run.priority or os.getenv(M.PRIORITY_ENV) == "1" then
        words[#words + 1] = "--priority"
    end
    if run.job_timeout then
        words[#words + 1] = "--timeout"
        words[#words + 1] = run.job_timeout
    end
    words[#words + 1] = "--"
    for _, word in ipairs(words) do
        argv[#argv + 1] = word
    end
    for _, word in ipairs(run.args) do
        argv[#argv + 1] = word
    end
    trace(argv, opts.verbosity)
    local name = M.run_label(run.root, {
        DEV_AGENT = os.getenv("DEV_AGENT"),
        DEV_CI_COMMAND = os.getenv(M.COMMAND_ENV),
        DEV_CI_CARD = os.getenv(M.CARD_ENV),
    }, { tty = dev_os.isatty(0) })
    local env = name and { DEV_AGENT = name } or nil
    local code = dev_os.run(argv, { env = env })
    if code == nil then
        dev_command.die("The command `ci` could not run.")
    end
    return code
end

local function file_runner(path, run)
    local source, reason = fs.read(path)
    if not source then
        dev_command.die("The file " .. path .. " cannot be read: " .. tostring(reason) .. ".")
    end
    local chunk, message = load(source, "=" .. path)
    local ok, runner = false, message
    if chunk then
        ok, runner = pcall(chunk)
    end
    if not ok then
        dev_command.die(tostring(runner))
    end
    if type(runner) ~= "function" then
        dev_command.die("The file " .. path .. " must return a function.")
    end
    local done, code = pcall(runner, run)
    if not done then
        dev_command.die(tostring(code))
    end
    if code == nil then
        return 0
    end
    if type(code) ~= "number" or code % 1 ~= 0 then
        dev_command.die(
            "The file " .. path .. " returned " .. tostring(code) .. ", not an exit code."
        )
    end
    return code % 256
end

---Run a command somewhere else and return its exit code.
---
---The runner is `.dev/__remote.lua` when the project has one, else `ci`. A
---command that declares `remote: false` is refused whatever the runner. Without a `--` every
---argument reaches the job. Arguments on both sides of a `--` are a usage error.
---@param ctx dev.Ctx the command's context, whose `args` are every argument after the command words
---@param words string[] the command words
---@param args string[] the arguments after `--`
---@param flags dev.remote.Flags how to start the job
---@return integer code the runner's exit code
function M.run(ctx, words, args, flags)
    if flags.never_remote then
        dev_command.usage_error(ctx, "runs on this machine only, so --remote does not apply")
    end
    if ctx.dashed and #ctx.args > #args then
        local shown = {}
        for i, word in ipairs(ctx.args) do
            shown[i] = (word == "" or word:find(UNSAFE_WORD)) and dev_os.quote(word) or word
        end
        dev_command.usage_error(
            ctx,
            "--remote takes arguments on one side of -- only. Run `dev --remote "
                .. table.concat(words, " ")
                .. " -- "
                .. table.concat(shown, " ")
                .. "` instead."
        )
    end
    local run = {
        words = words,
        args = ctx.dashed and args or ctx.args,
        detach = flags.detach,
        priority = flags.priority,
        job_timeout = flags.job_timeout,
        root = ctx.root,
        verbose = ctx.verbose,
    }
    local override = ctx.root .. "/.dev/__remote.lua"
    if fs.is_file(override) then
        return file_runner(override, run)
    end
    return M.ci_runner(run, { verbosity = ctx.verbose })
end

return M
