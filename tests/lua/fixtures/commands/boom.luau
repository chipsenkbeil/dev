local dev_command = require("@dev/command")

return dev_command({
    summary = "Raise an error",
    run = function()
        error("boom")
    end,
})
