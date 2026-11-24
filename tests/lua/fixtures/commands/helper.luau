local dev_command = require("@dev/command")

return dev_command({
    summary = "Use a library module",
    run = function()
        print(require("@lib/tools/shout").shout("hi"))
    end,
})
