local dev_command = require("@dev/command")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local releasefile = require("@dev/releasefile")

local function execute(opts, args, ctx)
    local tag = args.tag
    local dir = assert(fs.mktemp({ prefix = "verify", dir = true }))
    dev_os.on_exit(function()
        fs.remove(dir, { recursive = true })
    end)

    local binary, got, name = releasefile.download(tag, dir)
    dev_command.say("checksum " .. got .. "  " .. name)

    releasefile.make_runnable(binary)
    local printed = releasefile.run_binary(binary, { "--version" }, "--version")
    if printed ~= "dev " .. tag then
        dev_command.die(
            "The binary prints " .. printed .. " from --version, not dev " .. tag .. "."
        )
    end
    dev_command.say(printed)
    releasefile.run_binary(binary, { "help" }, "help")
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
