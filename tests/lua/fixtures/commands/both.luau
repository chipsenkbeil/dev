local dev_command = require("@dev/command")

return dev_command({
    summary = "Print which language ran",
    run = function()
        print("luau ran")
    end,
})
