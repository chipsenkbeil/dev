local dev_command = require("@dev/command")
local upgrade = require("@dev/cmd/upgrade")

return dev_command({
    summary = "Replace this dev with the latest release",
    group = "Set up a machine or project",
    remote = false,
    long = table.concat({
        "Reads the latest release that is not a pre-release, and does nothing but say ",
        "so when this dev is at that version or newer. Otherwise it downloads the ",
        "binary for this machine and `SHA256SUMS`, checks the digest, runs the new ",
        "binary with `--version` from a temporary folder, then replaces the running ",
        "executable.",
        "",
        "- The old executable stays beside it as `dev.old` until the swap works, and a ",
        "failed swap puts it back. On Windows the running executable is renamed ",
        "aside, and the `.old` file stays until the next upgrade removes it.",
        "- It exits 1 and leaves the install as it was when the release cannot be ",
        "read, a download fails, the checksum does not match or the new binary does ",
        "not run.",
        "- It refuses a dev built by cargo, which lives under a `target` folder next ",
        "to a `Cargo.toml`, and names its path.",
        "- `GITHUB_REPOSITORY` names the repository, else `chipsenkbeil/dev`. ",
        "`DEV_RELEASE_API` replaces the address of the latest release call and ",
        "`DEV_RELEASE_URL` the folder that holds the assets.",
        "",
        "```",
        "dev upgrade",
        "```",
    }, "\n"),
    run = function()
        return upgrade.run()
    end,
})
