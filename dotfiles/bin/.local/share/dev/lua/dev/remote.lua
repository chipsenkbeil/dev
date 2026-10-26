local devos = require("dev.os")
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
    bootstrap = true,
}
local MACHINE_NOUNS = { tools = true, box = true, cargo = true, pi = true, antinote = true }
local JOB_NAME = "^[A-Za-z0-9_-]+$"

---@class dev.remote
local M = {}

local function has_job(ctx, job)
    local out, code = devos.capture({ "ci", "-C", ctx.root, "jobs", "--json" }, { stderr = "null" })
    local doc = code == 0 and json.decode(out)
    for _, entry in ipairs(type(doc) == "table" and type(doc.jobs) == "table" and doc.jobs or {}) do
        if type(entry) == "table" and entry.name == job then
            return true
        end
    end
    return false
end

---Run a verb's job from the project's default pipeline on the fleet.
---
---The job of a subcommand is named `noun-sub`. It exits with the job's status
---and never falls back to a local run.
---@param ctx dev.Ctx the verb's context, whose `args` are every argument after the verb
---@return nil
function M.ci(ctx)
    local name = ctx.name
    if MACHINE_VERBS[name] or MACHINE_NOUNS[ctx.words[1]] then
        verb.usage_error(ctx, "--ci cannot run this verb, it works on this machine")
    end
    local job = name:gsub(" ", "-")
    if not job:find(JOB_NAME) then
        verb.usage_error(ctx, "--ci needs a job name, not " .. name)
    end
    if #ctx.args > 0 then
        verb.usage_error(ctx, "--ci passes no arguments to the job, got " .. ctx.args[1])
    end
    if not devos.which("ci") then
        stderr:write("WARNING: ci not found. Install with: dev install from the ci repo\n")
        os.exit(1)
    end
    if not has_job(ctx, job) then
        verb.die(
            "dev: no job named "
                .. job
                .. " in the project's default pipeline (.ci/jobs.lua), add one to run it with --ci"
        )
    end
    local argv = { "ci", "run", "--local", "--job", job, "-f" }
    if ctx.verbose >= 1 then
        stderr:write("+ ", table.concat(argv, " "), "\n")
    end
    local _, message = devos.exec(argv, { cwd = ctx.root })
    verb.die("dev: cannot run ci: " .. message)
end

return M
