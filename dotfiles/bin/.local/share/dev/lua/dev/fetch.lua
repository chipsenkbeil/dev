local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local remote = require("dev.remote")
local verb = require("dev.verb")

---@class dev.fetch
local M = {}

---The environment variable that holds the path of the file a verb's `fetch` header pulled.
M.ENV = "DEV_FETCHED"

---@class dev.fetch.Opts
---@field patch boolean? whether the job is a patch job

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

---Find the pipeline and first target that run a job, whatever the target's OS.
---@param listing string the lines of `ci run --list --all --json`, one document per pipeline
---@param job string the job name
---@return string? pipeline the name of the pipeline file without its `.lua`
---@return string? target the first target the job lists
function M.first(listing, job)
    for line in listing:gmatch("[^\n]+") do
        local doc = json.decode(line)
        for _, entry in ipairs(type(doc) == "table" and doc.jobs or {}) do
            if entry.name == job and entry.targets and entry.targets[1] then
                return fs.basename(doc.pipeline):gsub("%.lua$", ""), entry.targets[1]
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

---Start the job and return its run.
---
---A fetch job runs on the first target that matches this host's OS and at its architecture. A
---patch job runs on its first listed target with no architecture.
---@param root string the project root
---@param spec dev.header.Fetch the job and file the verb's header names
---@param opts dev.fetch.Opts which kind of job it is
---@return string run the ci run id
---@return string target the target the job runs on
local function start(root, spec, opts)
    local listing, listed = dev_os.capture(
        { "ci", "-C", root, "run", "--list", "--all", "--json" },
        { stderr = "null" }
    )
    if listed ~= 0 then
        verb.die("The command `ci run --list --all` failed. " .. LOCAL_HINT)
    end
    local pipeline, target, arch, platform
    if opts.patch then
        pipeline, target = M.first(listing, spec.job)
        platform = "ci"
    else
        local kernel, machine = M.platform()
        arch = ARCHES[machine]
        pipeline, target = M.pick(listing, spec.job, kernel)
        platform = kernel .. " " .. machine
    end
    if not pipeline or (not opts.patch and not arch) then
        verb.die(
            "The ci job "
                .. spec.job
                .. " has no matrix entry for "
                .. platform
                .. ". "
                .. LOCAL_HINT
        )
    end
    local argv = {
        "ci",
        "-C",
        root,
        "run",
        pipeline,
        "--local",
        "--detach",
        "--job",
        spec.job .. ":" .. target,
    }
    if arch then
        argv[#argv + 1] = "--arch"
        argv[#argv + 1] = arch
    end
    local started, code = dev_os.capture(argv, { env = ci_env(root), stderr = "stdout" })
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

---@param root string the project root
---@param spec dev.header.Fetch the job and file the verb's header names
---@param opts dev.fetch.Opts which kind of job it is
---@return string path the pulled file, in a new temporary directory
---@return string run the ci run id
local function download(root, spec, opts)
    if not dev_os.which("ci") then
        verb.die("The ci client is not found. Install it with `dev install` from the ci repo.")
    end
    local run, target = start(root, spec, opts)
    local index = await(root, spec, run, target)
    local dest = assert(fs.mktemp({ prefix = "dev-fetch", dir = true }))
    local artifact = table.concat({ spec.job, index, target }, ".") .. "/" .. spec.file
    local pulled = dev_os.run({ "ci", "-C", root, "cp", run .. ":" .. artifact, dest, "--force" })
    if pulled ~= 0 then
        verb.die("The command `ci cp " .. run .. ":" .. artifact .. "` failed.")
    end
    return dest .. "/" .. fs.basename(spec.file), run
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
    return (download(root, spec, {}))
end

---Run a verb's `patch` job on ci and apply the patch it keeps to the project root.
---
---The job runs on its first listed target with no architecture. An empty patch changes nothing.
---A patch that does not apply changes nothing either, because `git apply` is all or nothing. The
---process then ends naming the run and the kept patch. The temporary directory of a patch that
---applied or was empty is removed.
---@param root string the project root
---@param spec dev.header.Fetch the job and file the verb's header names
---@return integer code the exit code, 0 once the patch applied or was empty
function M.apply(root, spec)
    local path, run = download(root, spec, { patch = true })
    local dir = fs.dirname(path)
    local text = fs.read(path)
    if not text or not text:find("%S") then
        fs.remove(dir, { recursive = true })
        verb.say("No file changed.")
        return 0
    end
    local opts = {
        cwd = root,
        stderr = "stdout",
        env = { GIT_CEILING_DIRECTORIES = fs.dirname(root) },
    }
    local numstat, code = dev_os.capture({ "git", "apply", "--numstat", path }, opts)
    local failure = numstat
    if code == 0 then
        failure, code = dev_os.capture({ "git", "apply", path }, opts)
    end
    if code ~= 0 then
        verb.die(
            "The patch of ci run "
                .. run
                .. " does not apply and no file changed. It is kept at "
                .. path
                .. ".\n"
                .. failure:gsub("%s+$", "")
        )
    end
    fs.remove(dir, { recursive = true })
    verb.relay(numstat)
    return 0
end

return M
