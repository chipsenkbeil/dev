local dev_command = require("@dev/command")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local hash = require("@dev/hash")
local http = require("@dev/http")

local REPO = "chipsenkbeil/dev"
local CONNECT_TIMEOUT_SECONDS = 15
local MAX_TIME_SECONDS = 600
local EXECUTABLE_MODE = 493

local TRIPLES = {
    Linux = { x86_64 = "x86_64-unknown-linux-musl" },
    Darwin = { x86_64 = "x86_64-apple-darwin", aarch64 = "aarch64-apple-darwin" },
    freebsd = { x86_64 = "x86_64-unknown-freebsd" },
    Windows = { x86_64 = "x86_64-pc-windows-msvc" },
}

local function base_url(tag)
    local set = dev_os.getenv("DEV_RELEASE_URL")
    if set and set ~= "" then
        return set
    end
    local repo = dev_os.getenv("GITHUB_REPOSITORY")
    return "https://github.com/"
        .. (if repo and repo ~= "" then repo else REPO)
        .. "/releases/download/"
        .. tag
end

---Name the asset of a release that this machine runs.
local function asset_name(tag)
    local system, arch = dev_os.name(), dev_os.arch()
    local triple = TRIPLES[system] and TRIPLES[system][arch]
    if not triple then
        dev_command.die("The release holds no binary for " .. system .. " on " .. arch .. ".")
    end
    return "dev-" .. tag .. "-" .. triple .. (if system == "Windows" then ".exe" else "")
end

local function fetch(url, path)
    local reply = http.download({
        url = url,
        path = path,
        timeout = MAX_TIME_SECONDS,
        connect_timeout = CONNECT_TIMEOUT_SECONDS,
    })
    if reply == nil or reply.status < 200 or reply.status >= 300 then
        dev_command.die("Could not download " .. url .. ".")
    end
end

---Read the checksum `SHA256SUMS` lists for `name`.
local function listed(sums, name)
    for line in (fs.read(sums) or ""):gmatch("[^\r\n]+") do
        local digest, file = line:match("^(%x+)%s+%*?(.+)$")
        if file == name then
            return digest:lower()
        end
    end
    dev_command.die("SHA256SUMS does not list " .. name .. ".")
end

local function run_binary(binary, argv, what)
    local out, code = dev_os.capture({ binary, table.unpack(argv) }, { stderr = "stdout" })
    if code ~= 0 then
        dev_command.die("The binary did not run " .. what .. ": " .. out)
    end
    return (out:gsub("%s+$", ""))
end

local function execute(opts, args, ctx)
    local tag = args.tag
    local name = asset_name(tag)
    local base = base_url(tag)
    local dir = assert(fs.mktemp({ prefix = "verify", dir = true }))
    dev_os.on_exit(function()
        fs.remove(dir, { recursive = true })
    end)
    local binary, sums = dir .. "/" .. name, dir .. "/SHA256SUMS"

    fetch(base .. "/SHA256SUMS", sums)
    fetch(base .. "/" .. name, binary)

    local want = listed(sums, name)
    local got = assert(hash.sha256_file(binary))
    if got ~= want then
        dev_command.die(
            "The asset "
                .. name
                .. " does not match SHA256SUMS: it lists "
                .. want
                .. ", the download is "
                .. got
                .. "."
        )
    end
    dev_command.say("checksum " .. got .. "  " .. name)

    if dev_os.name() ~= "Windows" then
        assert(fs.chmod(binary, EXECUTABLE_MODE))
    end
    local printed = run_binary(binary, { "--version" }, "--version")
    if printed ~= "dev " .. tag then
        dev_command.die(
            "The binary prints " .. printed .. " from --version, not dev " .. tag .. "."
        )
    end
    dev_command.say(printed)
    run_binary(binary, { "help" }, "help")
    dev_command.say("help ran")
    return 0
end

return dev_command({
    summary = "Check the released binary for this machine against SHA256SUMS and run it",
    group = "Release",
    remote = false,
    long = table.concat({
        "Downloads `SHA256SUMS` and the asset of the release TAG that matches this ",
        "machine, checks the asset against its line there, then runs it with ",
        "`--version` and `help`.",
        "",
        "- `--version` must print `dev TAG`.",
        "- It exits 1 on a checksum mismatch, a missing asset, a download that fails ",
        "or a binary that does not run.",
        "- It needs no `gh`. `GITHUB_REPOSITORY` names the repository, else ",
        "`chipsenkbeil/dev`, and `DEV_RELEASE_URL` replaces the base URL of the ",
        "folder that holds the assets.",
        "",
        "```",
        "dev release verify v0.1.0-pre.9",
        "```",
    }, "\n"),
    args = { { name = "tag", required = true, help = "A published release tag" } },
    run = execute,
})
