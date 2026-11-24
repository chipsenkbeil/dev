local dev_command = require("dev.command")
local keychain = require("dev.board.keychain")

return dev_command({
    summary = "Get, put or drop the Keychain copy of a pass entry's token",
    hidden = true,
    remote = false,
    args = { { name = "subcommand" }, { name = "entry" } },
    run = function(_, args)
        return keychain.main(args.subcommand, args.entry)
    end,
})
