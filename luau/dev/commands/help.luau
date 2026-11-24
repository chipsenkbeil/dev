local dev_command = require("dev.command")
local complete = require("dev.complete")
local help = require("dev.help")
local registry = require("dev.registry")

local function targets(ctx)
    if #ctx.positional > 0 then
        return complete.subs(ctx.reg, ctx.positional)
    end
    local items = complete.commands(ctx.reg)
    for _, topic in ipairs(complete.topics(ctx.root)) do
        items[#items + 1] = topic
    end
    return items
end

return dev_command({
    summary = "Show the commands, the details of one command or a help page",
    hidden = true,
    remote = false,
    flags = {
        {
            name = "all",
            short = "a",
            kind = "boolean",
            help = "List the hidden commands and their layers",
        },
        { name = "topics", kind = "boolean", help = "List the help pages with their summaries" },
        {
            name = "topic",
            short = "k",
            kind = "string",
            help = "Print one help page",
            complete = function(ctx)
                return complete.topics(ctx.root)
            end,
        },
        { name = "no-pager", kind = "boolean", help = "Print without a pager" },
        {
            name = "check-topics",
            kind = "boolean",
            hidden = true,
            help = "Check the help pages against the real commands and flags",
        },
    },
    args = {
        {
            name = "target",
            list = true,
            help = "A command, a subcommand or a help page",
            complete = targets,
        },
    },
    run = function(_, _, ctx)
        local forwarded = setmetatable({ args = ctx.argv }, { __index = ctx })
        return help.run(forwarded, registry.load(ctx.root))
    end,
})
