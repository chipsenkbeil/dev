local dev_command = require("@dev/command")

return dev_command({
    summary = "Print the arguments",
    args = { { name = "words", list = true } },
    run = function(_, args)
        print("run got", table.concat(args.words, ","))
    end,
})
