local dev_command = require("@dev/command")
local passlock = require("@dev/board/passlock")

return dev_command({
    summary = "Read a pass entry under the shared lock, the Keychain first",
    hidden = true,
    remote = false,
    args = { { name = "entry", required = true } },
    run = function(_, args)
        return passlock.main(args.entry)
    end,
})
