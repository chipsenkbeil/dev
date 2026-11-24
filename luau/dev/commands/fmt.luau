local dev_command = require("@dev/command")
local types = require("@dev/cmd/types")

return dev_command({
    summary = "Format the source for the project type",
    group = "Check your work",
    remote = false,
    requires = { "workspace" },
    args = { { name = "rest", list = true, help = "Words for the last step" } },
    pass_unknown = true,
    passthrough = true,
    run = types.runner("fmt"),
})
