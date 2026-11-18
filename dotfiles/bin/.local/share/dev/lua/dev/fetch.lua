local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local remote = require("dev.remote")
local verb = require("dev.verb")

---@class dev.fetch
local M = {}

---The environment variable that holds the path of the file a verb's `fetch` header pulled.
M.ENV = "DEV_FETCHED"

local ARCHES = { arm64 = "aarch64", aarch64 = "aarch64", x86_64 = "x86_64", amd64 = "x86_64" }
local KERNELS = { macos = "Darwin", freebsd = "FreeBSD", windows = "Windows" }
local LOCAL_HINT = "Pass `--local` to build it here."

---Name the kernel and machine of this host, as `uname -sm` prints them.
---@return string kernel such as `Darwin`
---@return string machine such as `arm64`
function M.platform()
    local out, code = dev_os.capture({ "uname", "-sm" }, { stderr = "null" })
    local kernel, machine = out:match("^(%S+)%s+(%S+)")
    if code ~= 0 or not kernel then
        verb.die("The command `uname -sm` failed, so dev cannot tell this host's platform.")
    end
    return kernel, machine
end

---Name the kernel a ci target runs, from the OS word its name starts with.
---@param target string the target name, such as `macos-vm-rust`
---@return string kernel `Linux` for a target whose OS word is not listed
function M.target_kernel(target)
    return KERNELS[target:match("^(%a+)")] or "Linux"
end

---Find the pipeline and target that run a job on a kernel.
---@param listing string the lines of `ci run --list --all --json`, one document per pipeline
---@param job string the job name
---@param kernel string the kernel from `M.platform`
---@return string? pipeline the name of the pipeline file without its `.lua`
---@return string? target the first target of the job that runs the kernel
function M.pick(listing, job, kernel)
    for line in listing:gmatch("[^\n]+") do
        local doc = json.decode(line)
        for _, entry in ipairs(type(doc) == "table" and doc.jobs or {}) do
            if entry.name == job then
                for _, target in ipairs(entry.targets or {}) do
                    if M.target_kernel(target) == kernel then
                        return fs.basename(doc.pipeline):gsub("%.lua$", ""), target
                    end
                end
            end
        end
    end
    return nil
end

local function ci_env(root)
    local name = remote.run_label(root, {
        DEV_AGENT = os.getenv("DEV_AGENT"),
        DEV_CI_VERB = os.getenv(remote.VERB_ENV),
        DEV_CI_CARD = os.getenv(remote.CARD_ENV),
    }, { tty = dev_os.isatty(0) })
    return name and { DEV_AGENT = name } or nil
end

---Start the job on the target that matches this host and return its run.
---@param root string the project root
---@param spec dev.header.Fetch the job and file the verb's header names
---@return string run the ci run id
---@return string target the target the job runs on
local function start(root, spec)
    local kernel, machine = M.platform()
    local arch = ARCHES[machine]
    local listing, listed = dev_os.capture(
        { "ci", "-C", root, "run", "--list", "--all", "--json" },
        { stderr = "null" }
    )
    if listed ~= 0 then
        verb.die("The command `ci run --list --all` failed. " .. LOCAL_HINT)
    end
    local pipeline, target = M.pick(listing, spec.job, kernel)
    local platform = kernel .. " " .. machine
    if not pipeline or not arch then
        verb.die(
            "The ci job "
                .. spec.job
                .. " has no matrix entry for "
                .. platform
                .. ". "
                .. LOCAL_HINT
        )
    end
    local started, code = dev_os.capture({
        "ci",
        "-C",
        root,
        "run",
        pipeline,
        "--local",
        "--detach",
        "--job",
        spec.job .. ":" .. target,
        "--arch",
        arch,
    }, { env = ci_env(root), stderr = "stdout" })
    local run = started:match("(%w+)%s*$")
    if code ~= 0 or not run then
        verb.die(
            "The ci job "
                .. spec.job
                .. " could not start on "
                .. target
                .. " for "
                .. platform
                .. ": "
                .. started:gsub("%s+$", "")
                .. ". "
                .. LOCAL_HINT
        )
    end
    return run, target
end

---Wait for a run and return the matrix index of its passed job.
---@param root string the project root
---@param spec dev.header.Fetch the job and file the verb's header names
---@param run string the ci run id
---@param target string the target the job runs on
---@return integer index the job's matrix index, which names its artifact directory
local function await(root, spec, run, target)
    dev_os.run({ "ci", "-C", root, "ps", run, "-w" })
    local status, code = dev_os.capture({ "ci", "-C", root, "ps", run, "--json" })
    local doc = code == 0 and json.decode(status)
    for _, entry in ipairs(type(doc) == "table" and doc.jobs or {}) do
        if doc.status == "passed" and entry.name == spec.job and entry.target == target then
            return entry.index
        end
    end
    verb.die(
        "The ci run "
            .. run
            .. " of job "
            .. spec.job
            .. " did not pass. Read it with `ci logs "
            .. run
            .. "`."
    )
end

---Run a verb's `fetch` job on ci for this host's platform and pull the file it keeps.
---
---The job runs on the first target of its pipeline whose OS matches this host and at this host's
---architecture. It ends the process when ci cannot run it, when the run fails or when no
---target matches. The pulled file stays in a new temporary directory that the verb owns.
---@param root string the project root
---@param spec dev.header.Fetch the job and file the verb's header names
---@return string path the pulled file
function M.pull(root, spec)
    if not dev_os.which("ci") then
        verb.die("The ci client is not found. Install it with `dev install` from the ci repo.")
    end
    local run, target = start(root, spec)
    local index = await(root, spec, run, target)
    local dest = assert(fs.mktemp({ prefix = "dev-fetch", dir = true }))
    local artifact = table.concat({ spec.job, index, target }, ".") .. "/" .. spec.file
    local pulled = dev_os.run({ "ci", "-C", root, "cp", run .. ":" .. artifact, dest, "--force" })
    if pulled ~= 0 then
        verb.die("The command `ci cp " .. run .. ":" .. artifact .. "` failed.")
    end
    return dest .. "/" .. fs.basename(spec.file)
end

return M
