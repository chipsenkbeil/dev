local dev_command = require("@dev/command")
local board_card = require("@dev/complete/board_card")
local complete = require("@dev/complete")
local registry = require("@dev/registry")

return dev_command({
    summary = "List what the last word can complete to, for shell completion",
    hidden = true,
    remote = false,
    passthrough = true,
    flags = {
        {
            name = "refresh-cards",
            kind = "string",
            help = "Rewrite the card cache file from the card list, the detached step",
        },
        {
            name = "cur",
            kind = "string",
            help = "The word being completed, which a shell cannot pass empty",
        },
    },
    args = {
        {
            name = "words",
            list = true,
            help = "The words typed after dev, the last being completed",
        },
    },
    run = function(opts, args, ctx)
        if opts.refresh_cards then
            return board_card.refresh(ctx.root, opts.refresh_cards) and 0 or 1
        end
        local words = {}
        for _, word in ipairs(args.words or {}) do
            words[#words + 1] = word
        end
        for _, word in ipairs(ctx.passthrough or {}) do
            words[#words + 1] = word
        end
        if opts.cur then
            words[#words + 1] = opts.cur
        end
        return complete.run(ctx.root, registry.load(ctx.root, { warn = function() end }), words)
    end,
})
