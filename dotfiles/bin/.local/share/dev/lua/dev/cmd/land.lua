local board = require("dev.board")
local cmd_board = require("dev.cmd.board")
local config = require("dev.config")
local guards = require("dev.board.guards")
local scm = require("dev.scm")
local text = require("dev.text")
local dev_command = require("dev.command")

local CARD_FLAG = "--card"
local WAIT_FLAG = "--wait"
local IGNORE_CHANGE_RUN_FLAG = "--ignore-change-run"

---@class dev.cmd.land
local M = {}

local function parse(ctx)
    local flags = {}
    local i = 1
    while i <= #ctx.args do
        local word = ctx.args[i]
        if word ~= CARD_FLAG and word ~= WAIT_FLAG and word ~= IGNORE_CHANGE_RUN_FLAG then
            dev_command.usage_error(ctx, "Unknown argument " .. word .. ".")
        end
        local value = ctx.args[i + 1]
        if value == nil then
            dev_command.usage_error(ctx, "The " .. word .. " flag needs a value.")
        end
        flags[word] = value
        i = i + 2
    end
    return flags
end

local function land_plain(ctx, workspace, flags)
    if flags[CARD_FLAG] or flags[WAIT_FLAG] or flags[IGNORE_CHANGE_RUN_FLAG] then
        dev_command.usage_error(
            ctx,
            "The "
                .. CARD_FLAG
                .. ", "
                .. WAIT_FLAG
                .. " and "
                .. IGNORE_CHANGE_RUN_FLAG
                .. " flags need a project with a board."
        )
    end
    local _, problem = workspace:rebase()
    if problem then
        dev_command.note(text.sentence(problem))
        return 1
    end
    local ok, output = workspace:merge_into_trunk()
    dev_command.relay(output)
    return ok and 0 or 1
end

---Land the change of the workspace dev runs in.
---
---In a project with a board the workspace's name is the card. The card's own proof refusal stops an
---unproven card, and the `board land` command lands the rest with its turn, note and move. A
---project with no board gets a rebase onto trunk and a land of the change. A `.dev/land.lua`
---replaces all of it.
---@param ctx dev.Ctx the verb's context
---@return integer code the exit code
function M.run(ctx)
    local flags = parse(ctx)
    local workspace = scm.workspace(ctx.root)
    if config.get(ctx.root, "board.backend") == nil then
        return land_plain(ctx, workspace, flags)
    end
    local found, message = board.find(workspace)
    if not found then
        dev_command.note(text.sentence(message))
        return 1
    end
    local card, why = found:find_card(flags[CARD_FLAG] or workspace:name())
    if not card then
        local named = flags[CARD_FLAG] and ""
            or "Cannot land the workspace " .. workspace:name() .. " as a card. "
        dev_command.note(named .. text.sentence(why))
        return 1
    end
    local agent, bad = guards.agent_name()
    if bad or not agent then
        dev_command.note(bad and bad.message or "Needs DEV_AGENT, the name that lands the card.")
        return 1
    end
    local problem = card:land_problem(flags[IGNORE_CHANGE_RUN_FLAG])
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
    landing.args = { card.card.id }
    if flags[WAIT_FLAG] then
        landing.args[#landing.args + 1] = WAIT_FLAG
        landing.args[#landing.args + 1] = flags[WAIT_FLAG]
    end
    if flags[IGNORE_CHANGE_RUN_FLAG] then
        landing.args[#landing.args + 1] = IGNORE_CHANGE_RUN_FLAG
        landing.args[#landing.args + 1] = flags[IGNORE_CHANGE_RUN_FLAG]
    end
    return cmd_board.handlers["board land"](landing)
end

return M
