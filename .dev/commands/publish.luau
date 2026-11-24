local config = require("dev.config")
local dev_command = require("dev.command")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local hash = require("dev.hash")
local json = require("dev.json")

local REPO = "chipsenkbeil/dev"
local JOB = "targets"
local BINARY_MODE = 493

---The pipelines whose `targets` job builds a binary, each on the ci target the user config names.
local BUILDS = {
    { pipeline = "jobs", key = "ci.rust_target", triple = "x86_64-unknown-linux-musl" },
    {
        pipeline = "macos",
        key = "ci.macos_target",
        triple = "aarch64-apple-darwin",
        arch = "aarch64",
    },
}

local function gh_ready()
    if not dev_os.which("gh") then
        dev_command.die("The gh client is not on PATH. Install it with brew install gh.")
    end
    if dev_os.run({ "gh", "auth", "status" }, { stdout = "null", stderr = "null" }) ~= 0 then
        dev_command.die("The gh client is not logged in. Run gh auth login and try again.")
    end
end

local function check_tag(tag)
    local out, code = dev_os.capture(
        { "gh", "api", "repos/" .. REPO .. "/git/ref/tags/" .. tag },
        { stderr = "stdout" }
    )
    if code == 0 then
        return
    end
    if out:find("Not Found", 1, true) then
        dev_command.die(
            "The tag "
                .. tag
                .. " is not on github.com/"
                .. REPO
                .. " yet. Push it with dev push --tag "
                .. tag
                .. " first."
        )
    end
    dev_command.die(
        "The gh client could not read the tag " .. tag .. ": " .. (out:gsub("%s+$", ""))
    )
end

local function start(ctx, tag, build, target)
    local argv = { "ci", "-C", ctx.root, "run", build.pipeline, "--revision", tag, "--detach" }
    argv[#argv + 1] = "--job"
    argv[#argv + 1] = JOB
    if build.arch then
        argv[#argv + 1] = "--arch"
        argv[#argv + 1] = build.arch
    end
    dev_command.show(ctx, argv)
    local out, code = dev_os.capture(argv, { env = { CI_DEFAULT_TARGET = target } })
    local run = out:match("(%w+)%s*$")
    if code ~= 0 or not run then
        dev_command.die("The ci run of " .. build.pipeline .. " did not start.")
    end
    return run
end

local function finish(root, build, run)
    dev_command.say("Waiting for ci run " .. run .. " of the " .. build.pipeline .. " pipeline.")
    dev_os.run({ "ci", "-C", root, "ps", run, "--watch" })
    local out, code = dev_os.capture({ "ci", "-C", root, "ps", run, "--json" })
    local state = code == 0 and json.decode(out) or nil
    if type(state) ~= "table" or state.status ~= "passed" then
        dev_command.die(
            "The ci run "
                .. run
                .. " of the "
                .. build.pipeline
                .. " pipeline did not pass. Read it with ci ps "
                .. run
                .. "."
        )
    end
    local job = state.jobs and state.jobs[1]
    if not job then
        dev_command.die("The ci run " .. run .. " has no " .. JOB .. " job.")
    end
    return string.format("%s.%d.%s/dev", job.name, job.index, job.target)
end

local function pull(root, tag, build, run, path, dir)
    local scratch = assert(fs.mktemp({ prefix = "pull", dir = true }))
    local argv = { "ci", "-C", root, "cp", run .. ":" .. path, scratch }
    local out, code = dev_os.capture(argv, { stderr = "stdout" })
    local pulled = scratch .. "/dev"
    if code ~= 0 then
        dev_command.die("The artifact " .. path .. " of ci run " .. run .. " did not come: " .. out)
    end
    if not fs.is_file(pulled) then
        dev_command.die("The ci run " .. run .. " left no binary at " .. path .. ".")
    end
    local name = "dev-" .. tag .. "-" .. build.triple
    assert(fs.move(pulled, dir .. "/" .. name))
    assert(fs.chmod(dir .. "/" .. name, BINARY_MODE))
    fs.remove(scratch)
    return name
end

local function execute(opts, args, ctx)
    local tag = args.tag
    local root = ctx.root
    dev_command.need("ci", "install the ci client")
    gh_ready()
    check_tag(tag)

    local targets = {}
    for _, build in ipairs(BUILDS) do
        local target = config.prefer_user(root, build.key)
        if type(target) ~= "string" or target == "" then
            dev_command.die(
                "The user config sets no "
                    .. build.key
                    .. ", the ci target of the "
                    .. build.pipeline
                    .. " pipeline."
            )
        end
        targets[build] = target
    end

    local runs = {}
    for _, build in ipairs(BUILDS) do
        runs[build] = start(ctx, tag, build, targets[build])
    end

    local paths = {}
    for _, build in ipairs(BUILDS) do
        paths[build] = finish(root, build, runs[build])
    end

    local dir = assert(fs.mktemp({ prefix = "publish", dir = true }))
    local names, sums = {}, {}
    for _, build in ipairs(BUILDS) do
        local name = pull(root, tag, build, runs[build], paths[build], dir)
        local digest = assert(hash.sha256_file(dir .. "/" .. name))
        names[#names + 1] = dir .. "/" .. name
        sums[#sums + 1] = digest .. "  " .. name .. "\n"
    end
    assert(fs.write(dir .. "/SHA256SUMS", table.concat(sums)))
    names[#names + 1] = dir .. "/SHA256SUMS"

    local argv = { "gh", "release", "create", tag }
    for _, path in ipairs(names) do
        argv[#argv + 1] = path
    end
    for _, word in ipairs({
        "--repo",
        REPO,
        "--verify-tag",
        "--title",
        tag,
        "--notes",
        "Builds of dev at " .. tag .. " for the project ports.",
    }) do
        argv[#argv + 1] = word
    end
    if opts.prerelease then
        argv[#argv + 1] = "--prerelease"
    end
    dev_command.show(ctx, argv)
    local out, code = dev_os.capture(argv, { stderr = "stdout" })
    if code ~= 0 then
        dev_command.die("The gh client could not create the release: " .. out)
    end
    for _, build in ipairs(BUILDS) do
        dev_command.say("ci run " .. runs[build] .. " built " .. build.triple)
    end
    dev_command.say("Files kept in " .. dir)
    dev_command.say((out:gsub("%s+$", "")))
    return 0
end

return dev_command({
    summary = "Publish the ci-built binaries of a pushed tag as a GitHub release",
    group = "Release",
    remote = false,
    long = table.concat({
        "Starts the `targets` job of the `jobs` and `macos` pipelines on ci at TAG, ",
        "waits for both, pulls the two binaries and creates the GitHub release for TAG ",
        "on chipsenkbeil/dev with them and a `SHA256SUMS` file.",
        "",
        "- The files are named `dev-TAG-TRIPLE`, one per Rust target triple.",
        "- The ci targets come from the user config keys `ci.rust_target` and ",
        "`ci.macos_target`. A repo never names them.",
        "- Each `targets` job runs the native runtime suite on its binary before it ",
        "keeps the file.",
        "- TAG must already be on the GitHub remote. Push it first with ",
        "`dev push --tag TAG`. The command never pushes or creates a tag.",
        "- It needs `ci` and `gh`, with `gh` logged in. It refuses a ci run that ",
        "did not pass, a binary that did not arrive and a release that already exists.",
        "",
        "```",
        "dev push --tag v0.1.0-pre.1",
        "dev publish v0.1.0-pre.1 --prerelease",
        "```",
    }, "\n"),
    args = { { name = "tag", required = true, help = "An existing tag on the GitHub remote" } },
    flags = {
        { name = "prerelease", kind = "boolean", help = "Mark the release as a pre-release" },
    },
    run = execute,
})
