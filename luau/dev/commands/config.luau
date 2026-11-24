local config = require("@dev/cmd/config")
local dev_command = require("@dev/command")

return dev_command({
    summary = "Ask for the user config keys that are unset and write them",
    group = "Set up a machine or project",
    remote = false,
    run = function()
        return config.run()
    end,
})
