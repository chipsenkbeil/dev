local dev_command = require("dev.command")

return dev_command({
    summary = "Inner command",
    group = "Nested group",
    run = function() end,
})
