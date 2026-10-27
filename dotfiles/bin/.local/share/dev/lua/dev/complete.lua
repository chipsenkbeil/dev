local registry = require("dev.registry")
local topics = require("dev.topics")

local stderr = io.stderr

---@class dev.complete
local M = {}

---Print `name<TAB>origin<TAB>description` for every verb and noun, for shell completion.
---@param _ dev.Ctx the context
---@param reg dev.Registry the project's registry
---@return integer code 0
function M.verbs(_, reg)
    for _, row in ipairs(reg:verbs()) do
        io.write(row.name, "\t", row.kind, "\t", row.desc, "\n")
    end
    return 0
end

---Print `sub<TAB>origin<TAB>description` for each subcommand of the noun in `ctx.args[1]`.
---@param ctx dev.Ctx the context
---@param reg dev.Registry the project's registry
---@return integer code 0, with no output for a word that is not a noun
function M.subs(ctx, reg)
    local noun = ctx.args[1] or ""
    if reg:is_noun(noun) then
        for _, row in ipairs(reg:subs(noun)) do
            io.write(row.words[2], "\t", row.kind, "\t", row.desc, "\n")
        end
    end
    return 0
end

---Print the flags of the verb, and subcommand, in `ctx.args`, then the global flags.
---@param ctx dev.Ctx the context
---@param reg dev.Registry the project's registry
---@return integer code 0
function M.flags(ctx, reg)
    local words = {}
    for i = 1, math.min(#ctx.args, 2) do
        words[i] = ctx.args[i]
    end
    for _, flag in ipairs(reg:flags(words)) do
        io.write(flag, "\n")
    end
    for _, flag in ipairs(registry.GLOBAL_FLAGS) do
        io.write(flag, "\n")
    end
    return 0
end

---Print each problem the topic check finds as `file:line: message` on standard error.
---
---It loads its own registry with the header warnings silenced, since the check
---reports a reserved flag in a flags line as a problem and not as a warning.
---@param ctx dev.Ctx the context
---@return integer code 1 when there is a problem, else 0
function M.check_topics(ctx)
    local reg = registry.load(ctx.root, { warn = function() end })
    local problems = topics.check(reg)
    for _, found in ipairs(problems) do
        stderr:write(found.file, ":", found.line, ": ", found.message, "\n")
    end
    return #problems > 0 and 1 or 0
end

return M
