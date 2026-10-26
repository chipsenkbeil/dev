local ctx = ...
local vars = {}
for key, value in pairs(ctx.vars) do
    vars[#vars + 1] = key .. "=" .. value
end
table.sort(vars)
print(ctx.name, ctx.root ~= nil, ctx.verbose)
print("args", table.concat(ctx.args, ","))
print("vars", table.concat(vars, ","))
