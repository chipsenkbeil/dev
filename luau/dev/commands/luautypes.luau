local dev_command = require("@dev/command")
local dev_text = require("@dev/text")
local luautypes = require("@dev/luautypes")

return dev_command({
    summary = "Write the declarations luau-analyze reads for the dev modules",
    group = "Set up a machine or project",
    remote = false,
    run = function(_, _, ctx)
        local folder = luautypes.folder(ctx.root)
        local changed, reason = luautypes.write(`{ctx.root}/{folder}`)
        if not changed then
            dev_command.die(dev_text.sentence(`The declarations were not written: {reason}`))
        end
        if changed == 0 then
            dev_command.say(`The declarations in {folder} are current.`)
        else
            dev_command.say(`Wrote {changed} files to {folder}.`)
        end
        return 0
    end,
})
