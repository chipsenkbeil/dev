local dev_command = require("dev.command")
local types = require("dev.cmd.types")

return dev_command({
    summary = "Build the project",
    group = "Check your work",
    args = { { name = "rest", list = true, help = "Words for the last step" } },
    pass_unknown = true,
    passthrough = true,
    run = types.runner("build"),
})
