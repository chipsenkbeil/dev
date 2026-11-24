local dev_command = require("dev.command")

return dev_command({
    summary = "Print the context",
    args = { { name = "words", list = true } },
    run = function(_, args, ctx)
        local vars = {}
        for key, value in pairs(ctx.vars) do
            vars[#vars + 1] = key .. "=" .. value
        end
        table.sort(vars)
        print(ctx.name, ctx.root ~= nil, ctx.verbose)
        print("args", table.concat(args.words, ","))
        print("vars", table.concat(vars, ","))
    end,
})
