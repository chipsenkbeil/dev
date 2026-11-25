local dev_command = require("@dev/command")
local dev_os = require("@dev/os")
local json = require("@dev/json")
local text = require("@dev/text")
local vcs = require("@dev/vcs")

local REPO = "chipsenkbeil/dev"
local WORKFLOW = "release.yml"
local REMOTE = "origin"
local BRANCH_PREFIX = "review-"
local FOUND_SECONDS = 120
local DONE = { success = true, skipped = true }

local function repo()
    local set = dev_os.getenv("GITHUB_REPOSITORY")
    return if set and set ~= "" then set else REPO
end

local function jj_target(root, base)
    local out, code = dev_os.capture(
        vcs.with(
            base,
            "log",
            "--no-graph",
            "-r",
            "coalesce(@ ~ empty(), @-)",
            "-T",
            'commit_id ++ " " ++ change_id.short(12) ++ "\\n"'
        ),
        { cwd = root, stderr = "stdout" }
    )
    local sha, change = out:match("^(%x+) (%w+)")
    if code ~= 0 or not sha then
        dev_command.die(`The jj client could not name the current change: {text.trim(out)}`)
    end
    return sha, BRANCH_PREFIX .. change
end

local function git_target(root)
    local sha, code = dev_os.capture({ "git", "-C", root, "rev-parse", "HEAD" })
    if code ~= 0 then
        dev_command.die(`The git client could not read HEAD in {root}.`)
    end
    sha = text.trim(sha)
    local branch =
        text.trim(dev_os.capture({ "git", "-C", root, "symbolic-ref", "--short", "-q", "HEAD" }))
    if branch == "" then
        branch = sha:sub(1, 12)
    end
    return sha, BRANCH_PREFIX .. branch:gsub("[^%w._-]", "-")
end

local function jj_step(ctx, argv, failure)
    dev_command.show(ctx, argv)
    local out, code = dev_os.capture(argv, { cwd = ctx.root, stderr = "stdout" })
    if code ~= 0 then
        dev_command.die(`{failure}: {text.trim(out)}`)
    end
end

local function jj_push(ctx, sha, branch)
    local base = vcs.base(ctx.root, vcs.JJ, { quiet = true })
    local failure = `The push of {branch} to {REMOTE} failed`
    jj_step(ctx, vcs.with(base, "bookmark", "set", "--allow-backwards", "-r", sha, branch), failure)
    jj_step(ctx, vcs.with(base, "git", "fetch", "--remote", REMOTE, "--branch", branch), failure)
    jj_step(
        ctx,
        vcs.with(
            base,
            "--config",
            "git.sign-on-push=false",
            "git",
            "push",
            "--remote",
            REMOTE,
            "--bookmark",
            branch,
            "--allow-empty-description",
            "--allow-private"
        ),
        failure
    )
end

local function push(ctx, backend, sha, branch)
    if backend == vcs.JJ then
        jj_push(ctx, sha, branch)
        return
    end
    local argv = vcs.git_push(REMOTE, { `+{sha}:refs/heads/{branch}` })
    dev_command.show(ctx, argv)
    local out, code = dev_os.capture(argv, { cwd = ctx.root, stderr = "stdout" })
    if code ~= 0 then
        dev_command.die(`The push of {branch} to {REMOTE} failed: {text.trim(out)}`)
    end
end

local function remove_branch(ctx, backend, branch)
    local deletes
    if backend == vcs.JJ then
        local base = vcs.base(ctx.root, backend, { quiet = true })
        deletes = {
            vcs.with(base, "bookmark", "delete", branch),
            vcs.with(base, "git", "push", "--remote", REMOTE, "--bookmark", branch),
        }
    else
        deletes = { vcs.git_push(REMOTE, { `:refs/heads/{branch}` }) }
    end
    for _, argv in ipairs(deletes) do
        dev_command.show(ctx, argv)
        local out, code = dev_os.capture(argv, { cwd = ctx.root, stderr = "stdout" })
        if code ~= 0 then
            dev_command.say(`The branch {branch} stays on {REMOTE}: {text.trim(out)}`)
            return
        end
    end
end

local function run_ids(branch, sha)
    local out, code = dev_os.capture({
        "gh",
        "run",
        "list",
        "--repo",
        repo(),
        "--workflow",
        WORKFLOW,
        "--branch",
        branch,
        "--event",
        "workflow_dispatch",
        "--limit",
        "30",
        "--json",
        "databaseId,headSha",
    }, { stderr = "stdout" })
    local ids = {}
    local rows = code == 0 and json.decode(out) or nil
    if not rows then
        dev_command.die("The gh client could not list the runs: " .. text.trim(out))
    end
    for _, row in ipairs(rows) do
        if row.headSha == sha then
            ids[#ids + 1] = row.databaseId
        end
    end
    return ids
end

local function find_run(branch, sha, known, nap, interval)
    local started = dev_os.monotonic()
    while true do
        for _, id in ipairs(run_ids(branch, sha)) do
            if not text.contains(known, id) then
                return id
            end
        end
        if dev_os.monotonic() - started >= FOUND_SECONDS then
            dev_command.die(`No run of {WORKFLOW} appeared on {branch} within {FOUND_SECONDS}s.`)
        end
        nap(interval)
    end
end

local function view(id)
    local out, code = dev_os.capture({
        "gh",
        "run",
        "view",
        tostring(id),
        "--repo",
        repo(),
        "--json",
        "status,conclusion,url,jobs",
    }, { stderr = "stdout" })
    local run = code == 0 and json.decode(out) or nil
    if not run then
        dev_command.die(`The gh client could not read run {id}: {text.trim(out)}`)
    end
    return run
end

local function failing_lines(job, limit)
    local out = dev_os.capture({
        "gh",
        "run",
        "view",
        "--repo",
        repo(),
        "--job",
        tostring(job.databaseId),
        "--log-failed",
    }, { stderr = "stdout" })
    local lines = {}
    for line in out:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    return table.move(lines, math.max(#lines - limit + 1, 1), #lines, 1, {})
end

local function report(run, limit)
    local failed = 0
    for _, job in ipairs(run.jobs) do
        local result = job.conclusion
        if result == nil or result == "" then
            result = job.status
        end
        dev_command.say(`job {job.name}: {result}`)
        if not DONE[result] then
            failed += 1
            for _, line in ipairs(failing_lines(job, limit)) do
                dev_os.stdout:write("    ", line, "\n")
            end
        end
    end
    return failed
end

local function execute(opts, _, ctx)
    if not dev_os.which("gh") then
        dev_command.die("The gh client is not on PATH. Install it with brew install gh.")
    end
    local backend, err = vcs.require(ctx.root)
    if not backend then
        dev_command.die(err)
    end
    local sha, branch
    if backend == vcs.JJ then
        sha, branch = jj_target(ctx.root, vcs.base(ctx.root, backend, { quiet = true }))
    else
        sha, branch = git_target(ctx.root)
    end
    push(ctx, backend, sha, branch)
    dev_command.say(`Pushed {branch} at {sha:sub(1, 12)} to {REMOTE}.`)

    local known = run_ids(branch, sha)
    local argv = { "gh", "workflow", "run", WORKFLOW, "--repo", repo(), "--ref", branch }
    dev_command.show(ctx, argv)
    local out, code = dev_os.capture(argv, { stderr = "stdout" })
    if code ~= 0 then
        dev_command.die("The gh client could not start the run: " .. text.trim(out))
    end

    local id = find_run(branch, sha, known, dev_os.nap, opts.interval)
    dev_command.say(`Started run {id}.`)
    local started = dev_os.monotonic()
    local run = view(id)
    while run.status ~= "completed" do
        if dev_os.monotonic() - started >= opts.timeout then
            dev_command.say(`Run {id} was still {run.status} after {opts.timeout}s: {run.url}`)
            return 1
        end
        dev_os.nap(opts.interval)
        run = view(id)
    end
    local failed = report(run, opts.lines)
    if not opts.keep then
        remove_branch(ctx, backend, branch)
    end
    dev_command.say(`Run {id} ended {run.conclusion} with {failed} job(s) not green: {run.url}`)
    return if failed == 0 and run.conclusion == "success" then 0 else 1
end

return dev_command({
    summary = "Run the release workflow on this change without publishing",
    group = "Release",
    remote = false,
    long = table.concat({
        "Pushes the current change to a `review-` branch on origin, starts ",
        "`release.yml` on it with `gh workflow run`, waits for the run and prints ",
        "each job's result with the end of the log of every job that did not pass.",
        "",
        "- jj uses the working-copy change, or its parent when it is empty, and ",
        "names the branch from its change id. git uses HEAD and its branch name.",
        "- The branch is force-pushed, so a rerun on an amended change replaces it. jj ",
        "pushes it through a bookmark of the same name and deletes that bookmark ",
        "with the remote branch once the run ends, so jj never abandons the pushed ",
        "change when the branch vanishes. `--keep` leaves both, and a timeout leaves ",
        "them too.",
        "- A dispatched run runs the build jobs only. Publishing needs a `v*` tag, so ",
        "it creates no release and no tag.",
        "- `--timeout SECONDS` bounds the wait and exits 1 when the run is still going.",
        "- `--interval SECONDS` is the pause between looks at the run.",
        "- `--lines N` is how many log lines to print per failed job.",
        "- It exits 0 when the run succeeded and every job passed or was skipped, ",
        "else 1. A job marked continue-on-error still counts as not green.",
        "- `GITHUB_REPOSITORY` names another repository.",
        "",
        "```",
        "dev release dispatch --timeout 5400",
        "```",
    }, "\n"),
    flags = {
        {
            name = "timeout",
            kind = "number",
            default = 3600,
            help = "Seconds to wait for the run",
        },
        {
            name = "interval",
            kind = "number",
            default = 20,
            help = "Seconds between looks at the run",
        },
        { name = "keep", kind = "boolean", help = "Leave the review branch on origin" },
        {
            name = "lines",
            kind = "number",
            default = 40,
            help = "Log lines to print for each failed job",
        },
    },
    run = execute,
})
