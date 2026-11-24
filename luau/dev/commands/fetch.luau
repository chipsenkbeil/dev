local dev_command = require("@dev/command")
local types = require("@dev/cmd/types")

return dev_command({
    summary = "Download the crates and advisory data for offline lint and test",
    group = "Check your work",
    remote = false,
    args = { { name = "rest", list = true, help = "Words for the last step" } },
    pass_unknown = true,
    passthrough = true,
    run = types.runner("fetch"),
})
