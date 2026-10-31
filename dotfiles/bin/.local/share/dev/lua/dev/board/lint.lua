local board = require("dev.board")

---The rules `dev board lint` holds every card to, with no read of the board of its own.
---@class dev.board.lint
local M = {}

---The most words an open card's description holds.
M.MAX_WORDS = 400

---@class dev.board.lint.Opts
---@field roles dev.board.Roles the board's columns
---@field facts dev.board.lint.Facts lazy readers of the card's comments, links and children
---@field strict boolean? whether a Done card is held to the v2 sections too

---@class dev.board.lint.Facts
---@field comments fun(): dev.board.Comment[]?, string? the card's comments, read only when a rule needs them
---@field links fun(): dev.board.Link[]?, string? the card's links, read only when a rule needs them
---@field children fun(): integer?, string? how many children the card has, read only when a rule needs it

local function word_count(description)
    local count = 0
    if not description then
        return 0
    end
    for _ in description:gmatch("%S+") do
        count = count + 1
    end
    return count
end

local function asks(comments)
    for _, comment in ipairs(comments) do
        if comment.kind == "question" or comment.kind == "blocked" then
            return true
        end
    end
    return false
end

local function blocked_rule(facts)
    local comments, why = facts.comments()
    if not comments then
        return nil, why
    end
    if asks(comments) then
        return nil
    end
    local links
    links, why = facts.links()
    if not links then
        return nil, why
    end
    for _, link in ipairs(links) do
        if link.kind == board.LinkKind.BLOCKED_BY then
            return nil
        end
    end
    return "blocked with no question or blocked note and no blocker"
end

---Describe the outcomes of a card that are still open.
---@param card dev.board.Card the card
---@return string? rule how many outcomes are open, nil when all are ticked
local function unticked(card)
    local open = 0
    for _, outcome in ipairs(card.outcomes) do
        if not outcome.done then
            open = open + 1
        end
    end
    if open > 0 then
        return open .. " of " .. #card.outcomes .. " outcomes unticked"
    end
end

---List the rules a card breaks.
---@param card dev.board.Card the card
---@param opts dev.board.lint.Opts the board's columns, the lazy reads and whether Done cards are held to the v2 sections too
---@return string[]? rules what is wrong with the card, empty when it follows every rule
---@return string? message why a read failed
function M.card(card, opts)
    local roles, facts = opts.roles, opts.facts
    local rules = {}
    local function add(rule)
        rules[#rules + 1] = rule
    end
    local column = card.column
    local discarded = board.labelled(card, board.DISCARDED)
    local open = not card.done and column ~= roles.icebox
    if column ~= roles.icebox then
        local missing = board.unplanned({
            color = card.color,
            description = card.description,
            outcomes = #card.outcomes,
            need_outcomes = not (discarded and card.done) and not card.outcomes_unreadable,
            sections = open or opts.strict == true,
        })
        for _, item in ipairs(missing) do
            add("lacks " .. item)
        end
        if card.outcomes_unreadable then
            add("outcomes unreadable")
        end
    end
    if open then
        local worked = column == roles.ready or column == roles.progress or column == roles.review
        if worked and #card.checks == 0 then
            add("no checks row")
        end
        if column == roles.ready and card.color == board.SIZES["3+"] then
            add("red card in " .. column)
        end
        local words = word_count(card.description)
        if words > M.MAX_WORDS then
            add("over " .. M.MAX_WORDS .. " words (" .. words .. ")")
        end
    end
    if
        board.labelled(card, board.NEEDS_HUMAN)
        and column ~= roles.blocked
        and column ~= roles.icebox
    then
        add(board.NEEDS_HUMAN .. " outside " .. roles.blocked .. " and " .. roles.icebox)
    end
    if column == roles.blocked then
        local rule, why = blocked_rule(facts)
        if why then
            return nil, why
        end
        if rule then
            add(rule)
        end
    end
    if column == roles.progress and not card.claimant then
        local children, why = facts.children()
        if not children then
            return nil, why
        end
        if children == 0 then
            add("in progress with no claimant")
        end
    end
    if card.done and not discarded and not card.outcomes_unreadable then
        local unticked_rule = unticked(card)
        if unticked_rule then
            add(unticked_rule)
        end
    end
    return rules
end

return M
