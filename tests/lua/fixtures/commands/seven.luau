local dev_command = require("@dev/command")

return dev_command({
    summary = "Return seven",
    run = function()
        return 7
    end,
})
