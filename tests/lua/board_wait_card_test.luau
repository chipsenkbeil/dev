local testing = require("@dev/testing")
local board = require("@dev/board")
local cmd_board = require("@dev/cmd/board")
local fs = require("@dev/fs")
local support = require("./support")

local CARD_ID = "5af0e005-0000-4000-8000-000000000005"
local ID_B = "11111111-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
local COLUMN = support.COLUMN_NAME
local REVIEW = board.REVIEW_PREFIX .. " by=x kind=code verdict=PASS"

---Make a backend that serves one card, whose state each read takes from `script`.
---@param script {column: string?, reviews: integer?, ticked: integer?, broken: string?}[] the
---   state of each poll, the last one repeated
---@param listing_errors string[]? the failures of the first card listings
---@return dev.board.Backend backend
---@return {naps: number[], reads: integer} seen the naps and the number of reads
local function fake(script, listing_errors)
    local seen = { naps = {}, reads = 0 }
    local backend = {}
    local listed = 0
    local last
    local function state()
        return script[math.min(seen.reads, #script)]
    end
    function backend:failure()
        return support.failure_of(last)
    end
    function backend:cards()
        listed = listed + 1
        if listing_errors and listing_errors[listed] then
            last = listing_errors[listed]
            return nil, last
        end
        last = nil
        return { { id = CARD_ID, column = COLUMN.REVIEW } }
    end
    function backend:card()
        seen.reads = seen.reads + 1
        local now = state()
        last = now.broken
        if now.broken then
            return nil, now.broken
        end
        local outcomes = {}
        for i = 1, 3 do
            outcomes[i] = { id = "o" .. i, done = i <= (now.ticked or 0) }
        end
        return { id = CARD_ID, column = now.column or COLUMN.REVIEW, outcomes = outcomes }
    end
    function backend:comments()
        local list = { { body = "a plain note" } }
        for _ = 1, state().reviews or 0 do
            list[#list + 1] = { body = REVIEW }
        end
        return list
    end
    return backend, seen
end

local function wait_card(script, args, listing_errors)
    local backend, seen = fake(script, listing_errors)
    local result = cmd_board.wait(backend, args or { card = CARD_ID:sub(1, 8) }, {
        stem = "unused",
        nap = function(seconds)
            seen.naps[#seen.naps + 1] = seconds
        end,
        random = function()
            return 0
        end,
    })
    return result, seen
end

testing.test("wait --card exits on a column move and names it", function()
    local result, seen = wait_card({
        { column = COLUMN.REVIEW },
        { column = COLUMN.REVIEW },
        { column = COLUMN.VERIFY },
    })
    testing.eq(result.output, "5af0e005 moved to " .. COLUMN.VERIFY)
    testing.eq(seen.reads, 3)
end)

testing.test("wait --card exits on a new review row", function()
    local result = wait_card({ { reviews = 1 }, { reviews = 1 }, { reviews = 2 } })
    testing.eq(result.output, "5af0e005 reviews 1 to 2")
end)

testing.test("wait --card exits on a ticked outcome", function()
    local result = wait_card({ { ticked = 0 }, { ticked = 1 } })
    testing.eq(result.output, "5af0e005 ticked outcomes 0 to 1")
end)

testing.test("wait --card names every change that landed in one poll", function()
    local result =
        wait_card({ { reviews = 0 }, { column = COLUMN.VERIFY, reviews = 1, ticked = 3 } })
    testing.eq(
        result.output,
        "5af0e005 moved to " .. COLUMN.VERIFY .. ", reviews 0 to 1, ticked outcomes 0 to 3"
    )
end)

testing.test("wait --card backs off while the card is unchanged and starts over", function()
    -- Wait through five unchanged polls
    local result, seen = wait_card({ {}, {}, {}, {}, {}, { ticked = 1 } })
    testing.eq(result.output, "5af0e005 ticked outcomes 0 to 1")
    testing.eq(#seen.naps, 5)

    -- Nap longer after each unchanged poll
    for i = 2, #seen.naps do
        testing.ok(seen.naps[i] > seen.naps[i - 1], "nap " .. i .. " did not grow")
    end

    -- Cap the nap
    testing.ok(seen.naps[#seen.naps] <= 30)
end)

testing.test("wait --card retries an unreachable Pomb and then reads on", function()
    local result, seen = wait_card({
        {},
        { broken = "Board unavailable: pass timed out" },
        { column = COLUMN.DONE },
    })
    testing.eq(result.output, "5af0e005 moved to " .. COLUMN.DONE)
    testing.eq(#seen.naps, 2)
end)

testing.test("wait --card retries an unreachable Pomb on the first card listing", function()
    local result, seen = wait_card(
        { {}, { column = COLUMN.DONE } },
        nil,
        { "Board unavailable: pass timed out" }
    )
    testing.eq(result.output, "5af0e005 moved to " .. COLUMN.DONE)
    testing.eq(#seen.naps, 2)
end)

testing.test("wait --card fails on a read Pomb refuses", function()
    local result = wait_card({ {}, { broken = "Pomb refused the read" } })
    testing.ok(result.message:find("refused", 1, true), tostring(result.message))
end)

testing.test("wait --card refuses a card no card matches", function()
    local result = wait_card({ {} }, { card = "deadbeef" })
    testing.ok(result.message:find("No card starts with", 1, true), tostring(result.message))
end)

testing.test("wait --card refuses --for beside it", function()
    local result = wait_card({ {} }, { card = CARD_ID:sub(1, 8), ["for"] = "ready" })
    testing.ok(result.message:find("not both", 1, true), tostring(result.message))
end)

---Make a backend that lists cards only as a summary, with one wait reply that names `events`.
---@param cards dev.board.Card[] the cards the summary lists
---@param events {kind: string, task_id: string, column: string}[] the events of the one reply
---@return dev.board.Backend backend
---@return {summary: integer, export: integer} seen how many listings were summaries and exports
local function summary_only(cards, events)
    local seen = { summary = 0, export = 0 }
    local replies = { { cursor = "1", events = {} }, { cursor = "2", events = events } }
    local backend = {}
    function backend:wait()
        return table.remove(replies, 1)
    end
    function backend:failure()
        return nil
    end
    function backend:cards(opts)
        if opts and opts.summary then
            seen.summary = seen.summary + 1
            return cards
        end
        seen.export = seen.export + 1
        return nil, "the export was read"
    end
    function backend:blocked()
        return false
    end
    function backend:columns()
        return {}
    end
    return backend, seen
end

local function wait_for(backend, mode)
    return cmd_board.wait(backend, { ["for"] = mode }, {
        stem = support.tempdir() .. "/wait",
        nap = function() end,
        random = function()
            return 0
        end,
    })
end

testing.test("the cursor write prints the write sentence when it fails", function()
    -- Serve one new Ready card
    local backend = summary_only({ { id = CARD_ID, column = COLUMN.READY } }, {
        { kind = "task_added", task_id = ID_B, column = COLUMN.READY },
    })

    -- Block the cursor file with a directory
    local stem = support.tempdir() .. "/wait"
    local path = stem .. ".ready.cursor"
    assert(fs.mkdir(path, { parents = true }))

    -- Wait for a Ready card
    local result = cmd_board.wait(backend, { ["for"] = "ready" }, {
        stem = stem,
        nap = function() end,
        random = function()
            return 0
        end,
    })

    -- Name the path in the write failure
    testing.eq(result.message:sub(1, #path + 15), "Cannot write " .. path .. ": ")
end)

testing.test("wait --for ready lists the unclaimed cards from the summary", function()
    -- Serve one claimed and one unclaimed Ready card
    local backend, seen = summary_only({
        { id = CARD_ID, column = COLUMN.READY },
        { id = ID_B, column = COLUMN.READY, claimant = "x" },
    }, {
        { kind = "task_added", task_id = CARD_ID, column = COLUMN.READY },
        { kind = "task_added", task_id = ID_B, column = COLUMN.READY },
    })

    -- Wait for a Ready card
    local result = wait_for(backend, "ready")

    -- Name the unclaimed card and read only summaries
    testing.eq(result.output, "added 5af0e005 to " .. COLUMN.READY)
    testing.eq(seen.export, 0)
    testing.ok(seen.summary > 0)
end)

testing.test("wait --for lead skips an epic with open children by its summary counts", function()
    -- Serve an epic with an open child and an epic with none
    local backend, seen = summary_only({
        {
            id = CARD_ID,
            column = COLUMN.BLOCKED,
            labels = { "needs:lead" },
            epic = { done = 1, total = 2 },
        },
        {
            id = ID_B,
            column = COLUMN.BLOCKED,
            labels = { "needs:lead" },
            epic = { done = 2, total = 2 },
        },
    }, {
        { kind = "task_updated", task_id = CARD_ID, column = COLUMN.BLOCKED },
        { kind = "task_updated", task_id = ID_B, column = COLUMN.BLOCKED },
    })

    -- Wait for a card that needs the lead
    local result = wait_for(backend, "lead")

    -- Name the epic with no open child and read only summaries
    testing.eq(result.output, "11111111 is labelled needs:lead in " .. COLUMN.BLOCKED)
    testing.eq(seen.export, 0)
    testing.ok(seen.summary > 0)
end)
