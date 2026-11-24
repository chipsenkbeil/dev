local board = require("@dev/board")
local cmd_board = require("@dev/cmd/board")
local config = require("@dev/config")
local guards = require("@dev/board/guards")
local scm = require("@dev/scm")
local text = require("@dev/text")
local dev_command = require("@dev/command")

---@class dev.cmd.land
local M = {}

local function land_plain(ctx, workspace, flags)
    if flags.card or flags.wait or flags.ignore_change_run then
        dev_command.usage_error(
            ctx,
            "The "
                .. "--card"
                .. ", "
                .. "--wait"
                .. " and "
                .. "--ignore-change-run"
                .. " flags need a project with a board."
        )
    end
    local _, problem = workspace:rebase()
    if problem then
        dev_command.note(text.sentence(problem))
        return 1
    end
    local ok, output, dropped = workspace:merge_into_trunk()
    dev_command.relay(output)
    for _, line in ipairs(dropped) do
        dev_command.relay(line)
    end
    return ok and 0 or 1
end

---Land the change of the workspace dev runs in.
---
---In a project with a board the workspace's name is the card. The card's own proof refusal stops an
---unproven card, and the `board land` command lands the rest with its turn, note and move. A
---project with no board gets a rebase onto trunk and a land of the change. A `.dev/land.lua`
---replaces all of it.
---@param flags { card: string?, wait: number?, ignore_change_run: string? } the flags
---@param ctx dev.Ctx the command's context
---@return integer code the exit code
function M.run(flags, ctx)
    local workspace = scm.workspace(ctx.root)
    if config.get(ctx.root, "board.backend") == nil then
        return land_plain(ctx, workspace, flags)
    end
    local found, message = board.find(workspace)
    if not found then
        dev_command.note(text.sentence(message))
        return 1
    end
    local card, why = found:find_card(flags.card or workspace:name())
    if not card then
        local named = flags.card and ""
            or "Cannot land the workspace " .. workspace:name() .. " as a card. "
        dev_command.note(named .. text.sentence(why))
        return 1
    end
    local agent, bad = guards.agent_name()
    if bad or not agent then
        dev_command.note(bad and bad.message or "Needs DEV_AGENT, the name that lands the card.")
        return 1
    end
    local problem = card:land_problem(flags.ignore_change_run)
    if problem then
        dev_command.note(
            "Card " .. card.card.id:sub(1, board.MIN_PREFIX) .. " cannot land. " .. problem
        )
        return 1
    end
    local landing = {}
    for key, value in pairs(ctx) do
        landing[key] = value
    end
    landing.name = "board land"
    landing.argv = { card.card.id }
    if flags.wait then
        landing.argv[#landing.argv + 1] = "--wait"
        landing.argv[#landing.argv + 1] = tostring(flags.wait)
    end
    if flags.ignore_change_run then
        landing.argv[#landing.argv + 1] = "--ignore-change-run"
        landing.argv[#landing.argv + 1] = flags.ignore_change_run
    end
    return cmd_board.invoke("land", landing)
end

return M
