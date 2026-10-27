local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local verb = require("dev.verb")

local stderr = io.stderr

local MACHINE_VERBS = {
    install = true,
    uninstall = true,
    restow = true,
    sync = true,
    setup = true,
    fmt = true,
    fetch = true,
    help = true,
    init = true,
    push = true,
    pull = true,
    guide = true,
    connect = true,
}
local MACHINE_NOUNS = { tools = true, box = true, board = true, pi = true, antinote = true }
local JOB_NAME = "^[A-Za-z0-9_.-]+$"

---@class dev.remote.Run
---@field words string[] the command words, a noun and its subcommand as two
---@field args string[] the arguments after `--`, untouched
---@field detach boolean whether `--detach` was given
---@field root string absolute path of the project root
---@field verbose integer 0, or 1 or 2 for `-v` or `-vv`

---@class dev.remote
local M = {}

local function has_job(root, job, pipeline)
    local errfile = fs.mktemp({ prefix = "dev-remote" })
    local list = { "ci", "-C", root, "jobs" }
    if pipeline then
        list[#list + 1] = pipeline
    end
    list[#list + 1] = "--json"
    local out, code = devos.capture(list, { stderr = errfile })
    local detail = errfile and fs.read(errfile) or ""
    if errfile then
        fs.remove(errfile)
    end
    local doc = code == 0 and json.decode(out)
    if code ~= 0 or type(doc) ~= "table" or type(doc.jobs) ~= "table" then
        detail = detail:gsub("%s+$", "")
        stderr:write("dev: ci jobs failed", detail ~= "" and (": " .. detail) or "", "\n")
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

---@class dev.remote.CiOpts
---@field verbosity integer 1 or more prints the ci command first
---@field pipeline? string a pipeline under `.ci/` to run the job from, else the default one

---Run a job on ci and return its exit code.
---@param run dev.remote.Run
---@param opts dev.remote.CiOpts
---@return integer code
function M.ci_runner(run, opts)
    local pipeline = opts.pipeline
    local job = table.concat(run.words, ".")
    if not job:find(JOB_NAME) then
        verb.die("dev: --remote needs a job name, not " .. table.concat(run.words, " "))
    end
    if not devos.which("ci") then
        stderr:write("WARNING: ci not found. Install with: dev install from the ci repo\n")
        return 1
    end
    if not has_job(run.root, job, pipeline) then
        verb.die(
            "dev: no job named "
                .. job
                .. " in the project's "
                .. (pipeline and ("pipeline " .. pipeline) or "default pipeline (.ci/jobs.lua)")
                .. ", add one to run it with --remote"
        )
    end
    local argv = { "ci", "-C", run.root, "run" }
    if pipeline then
        argv[#argv + 1] = pipeline
    end
    local mode = run.detach and "--detach" or "--follow"
    for _, word in ipairs({ "--local", mode, "--job", job, "--" }) do
        argv[#argv + 1] = word
    end
    for _, word in ipairs(run.args) do
        argv[#argv + 1] = word
    end
    trace(argv, opts.verbosity)
    local code = devos.run(argv)
    if code == nil then
        verb.die("dev: cannot run ci")
    end
    return code
end

local function file_runner(path, run)
    local source, reason = fs.read(path)
    if not source then
        verb.die("dev: cannot read " .. path .. ": " .. tostring(reason))
    end
    local chunk, message = load(source, "=" .. path)
    local ok, runner = false, message
    if chunk then
        ok, runner = pcall(chunk)
    end
    if not ok then
        verb.die("dev: " .. tostring(runner))
    end
    if type(runner) ~= "function" then
        verb.die("dev: " .. path .. " must return a function")
    end
    local done, code = pcall(runner, run)
    if not done then
        verb.die("dev: " .. tostring(code))
    end
    if code == nil then
        return 0
    end
    if type(code) ~= "number" or code % 1 ~= 0 then
        verb.die("dev: " .. path .. " returned " .. tostring(code) .. ", not an exit code")
    end
    return code % 256
end

---Run a command somewhere else and return its exit code.
---
---The runner is `.dev/__remote.lua` when the project has one, else `ci`. A
---machine-local verb is refused whatever the runner. Arguments before a `--`
---are a usage error, since only the arguments after it reach the job.
---@param ctx dev.Ctx the command's context, whose `args` are every argument after the command words
---@param words string[] the command words
---@param args string[] the arguments after `--`
---@param detach boolean whether to start the job and return
---@return integer code the runner's exit code
function M.run(ctx, words, args, detach)
    if MACHINE_VERBS[words[1]] or MACHINE_NOUNS[words[1]] then
        verb.usage_error(ctx, "runs on this machine only, so --remote does not apply")
    end
    if #ctx.args > #args then
        verb.usage_error(
            ctx,
            "--remote passes arguments to the job only after --, got " .. ctx.args[1]
        )
    end
    local run = {
        words = words,
        args = args,
        detach = detach,
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
