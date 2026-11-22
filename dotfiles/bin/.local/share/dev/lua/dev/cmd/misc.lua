local dev_os = require("dev.os")
local fs = require("dev.fs")
local help = require("dev.help")
local project = require("dev.project")
local verb = require("dev.verb")

---@class dev.cmd.misc
local M = {}

local function exec(argv, opts)
    local _, message = dev_os.exec(argv, opts)
    verb.note("The command `" .. argv[1] .. "` could not run: " .. message .. ".")
    return dev_os.EXEC_FAILED
end

---Show the overview, or ask `guide` a question about this repo's commands and topics.
---
---With no question it shows the `overview` topic when there is one, a blank line, then the curated
---help, through the pager on a terminal. With one it runs `guide dev` from the project root
---with the project's topics read first.
---@param ctx dev.Ctx the verb's context, whose `args` are the question's words
---@param reg dev.Registry the project's registry
---@return integer code the exit code, or 126 when `guide` cannot be started
function M.guide(ctx, reg)
    local question = table.concat(ctx.args, " ")
    if question == "" then
        local intro = help.topic_text(ctx, "overview")
        help.page(
            (intro and intro .. "\n" or "") .. help.overview_text(ctx, reg),
            { curated = true }
        )
        return 0
    end
    verb.need("guide", "dev install guide")
    local topics = ctx.root .. "/.dev/topics"
    local argv = { "guide", "dev" }
    if fs.is_dir(topics) then
        argv[#argv + 1] = "--context-dir"
        argv[#argv + 1] = topics
    end
    argv[#argv + 1] = "--"
    argv[#argv + 1] = question
    return exec(argv, { cwd = ctx.root })
end

---Run `bootstrap.sh` from the dotfiles clone with the arguments untouched.
---@param ctx dev.Ctx the verb's context
---@return integer code the exit code, or 126 when `bash` cannot be started
function M.bootstrap(ctx)
    local root = project.dotfiles_root()
    local argv = { "bash", root .. "/bootstrap.sh" }
    for _, word in ipairs(ctx.args) do
        argv[#argv + 1] = word
    end
    return exec(argv, { cwd = root })
end

return M
