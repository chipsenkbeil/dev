local dev_command = require("dev.command")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local hash = require("dev.hash")
local json = require("dev.json")

local REPO = "chipsenkbeil/dev"
local PRERELEASE_MARK = "-pre."
local BINARIES = { "dev", "dev.exe" }

local function repo()
    local set = dev_os.getenv("GITHUB_REPOSITORY")
    return if set and set ~= "" then set else REPO
end

local function gh_ready()
    if not dev_os.which("gh") then
        dev_command.die("The gh client is not on PATH. Install it with brew install gh.")
    end
end

---Collect the binaries under `dir`, one folder per artifact named `dev-TAG-TRIPLE`.
local function artifacts(dir, tag)
    if not fs.is_dir(dir) then
        dev_command.die("The artifact folder " .. dir .. " does not exist.")
    end
    local prefix = "dev-" .. tag .. "-"
    local found = {}
    for _, name in ipairs(fs.list(dir) or {}) do
        if name:sub(1, #prefix) == prefix then
            for _, binary in ipairs(BINARIES) do
                local path = dir .. "/" .. name .. "/" .. binary
                if fs.is_file(path) then
                    found[#found + 1] = {
                        name = if binary == "dev" then name else name .. ".exe",
                        path = path,
                    }
                end
            end
        end
    end
    table.sort(found, function(a, b)
        return a.name < b.name
    end)
    if #found == 0 then
        dev_command.die("The folder " .. dir .. " holds no " .. prefix .. "TRIPLE artifact.")
    end
    return found
end

---Read the names of the assets the release holds, or nil when it does not exist.
local function existing(tag)
    local out, code = dev_os.capture(
        { "gh", "release", "view", tag, "--repo", repo(), "--json", "assets" },
        { stderr = "stdout" }
    )
    if code == 0 then
        local names = {}
        local state = json.decode(out)
        for _, asset in ipairs(state and state.assets or {}) do
            names[asset.name] = true
        end
        return names
    end
    if out:find("release not found", 1, true) then
        return nil
    end
    dev_command.die("The gh client could not read the release " .. tag .. ": " .. out)
end

local function execute(opts, args, ctx)
    local tag = args.tag
    gh_ready()
    local found = artifacts(opts.dir, tag)

    local stage = assert(fs.mktemp({ prefix = "publish", dir = true }))
    local files, sums = {}, {}
    for _, item in ipairs(found) do
        local target = stage .. "/" .. item.name
        if dev_os.run({ "cp", item.path, target }) ~= 0 then
            dev_command.die("Could not copy " .. item.path .. ".")
        end
        local digest = assert(hash.sha256_file(target))
        files[#files + 1] = target
        sums[#sums + 1] = digest .. "  " .. item.name .. "\n"
    end
    assert(fs.write(stage .. "/SHA256SUMS", table.concat(sums)))
    files[#files + 1] = stage .. "/SHA256SUMS"

    local assets = existing(tag)
    local argv
    if assets then
        for _, path in ipairs(files) do
            local name = fs.basename(path)
            if assets[name] then
                dev_command.die("The release " .. tag .. " already holds the asset " .. name .. ".")
            end
        end
        argv = { "gh", "release", "upload", tag }
        for _, path in ipairs(files) do
            argv[#argv + 1] = path
        end
        argv[#argv + 1] = "--repo"
        argv[#argv + 1] = repo()
    else
        argv = { "gh", "release", "create", tag }
        for _, path in ipairs(files) do
            argv[#argv + 1] = path
        end
        for _, word in ipairs({
            "--repo",
            repo(),
            "--verify-tag",
            "--title",
            tag,
            "--notes",
            "Builds of dev at " .. tag .. ".",
        }) do
            argv[#argv + 1] = word
        end
        if tag:find(PRERELEASE_MARK, 1, true) then
            argv[#argv + 1] = "--prerelease"
        end
    end
    dev_command.show(ctx, argv)
    local out, code = dev_os.capture(argv, { stderr = "stdout" })
    if code ~= 0 then
        dev_command.die("The gh client could not publish the release: " .. out)
    end
    for _, item in ipairs(found) do
        dev_command.say("published " .. item.name)
    end
    dev_command.say((out:gsub("%s+$", "")))
    return 0
end

return dev_command({
    summary = "Publish the built binaries of a tag as a GitHub release",
    group = "Release",
    remote = false,
    long = table.concat({
        "Collects the `dev-TAG-TRIPLE/dev` files under `--dir` (the layout ",
        "`actions/download-artifact` makes), writes a `SHA256SUMS` file over the ",
        "`dev-TAG-TRIPLE` assets and creates the GitHub release for TAG with them, or ",
        "uploads them to the release that exists.",
        "",
        "- A TAG that holds `-pre.` makes a pre-release.",
        "- It refuses to overwrite an asset the release already holds.",
        "- TAG must already be on the GitHub remote. The command never pushes or ",
        "creates a tag.",
        "- It needs `gh`, logged in or with `GH_TOKEN` set. `GITHUB_REPOSITORY` ",
        "names the repository, else chipsenkbeil/dev.",
        "",
        "```",
        "dev release publish v0.1.0-pre.1 --dir artifacts",
        "```",
    }, "\n"),
    args = { { name = "tag", required = true, help = "An existing tag on the GitHub remote" } },
    flags = {
        { name = "dir", kind = "string", default = "artifacts", help = "The downloaded artifacts" },
    },
    run = execute,
})
