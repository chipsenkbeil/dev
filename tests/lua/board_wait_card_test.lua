local testing = require("dev.testing")
local board = require("dev.board")
local cmd_board = require("dev.cmd.board")

local CARD_ID = "5af0e005-0000-4000-8000-000000000005"
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
    local function state()
        return script[math.min(seen.reads, #script)]
    end
    function backend:cards()
        listed = listed + 1
        if listing_errors and listing_errors[listed] then
            return nil, listing_errors[listed]
        end
        return { { id = CARD_ID, column = "Review" } }
    end
    function backend:card()
        seen.reads = seen.reads + 1
        local now = state()
        if now.broken then
            return nil, now.broken
        end
        local outcomes = {}
        for i = 1, 3 do
            outcomes[i] = { id = "o" .. i, done = i <= (now.ticked or 0) }
        end
        return { id = CARD_ID, column = now.column or "Review", outcomes = outcomes }
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
    local result = cmd_board.wait(backend, args or { "--card", CARD_ID:sub(1, 8) }, {
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
    local result, seen =
        wait_card({ { column = "Review" }, { column = "Review" }, { column = "Verify" } })
    testing.eq(result.output, "5af0e005 moved to Verify")
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
    local result = wait_card({ { reviews = 0 }, { column = "Verify", reviews = 1, ticked = 3 } })
    testing.eq(result.output, "5af0e005 moved to Verify, reviews 0 to 1, ticked outcomes 0 to 3")
end)

testing.test("wait --card backs off while the card is unchanged and starts over", function()
    local result, seen = wait_card({ {}, {}, {}, {}, {}, { ticked = 1 } })
    testing.eq(result.output, "5af0e005 ticked outcomes 0 to 1")
    testing.eq(#seen.naps, 5)
    for i = 2, #seen.naps do
        testing.ok(seen.naps[i] > seen.naps[i - 1], "nap " .. i .. " did not grow")
    end
    testing.ok(seen.naps[#seen.naps] <= 30)
end)

testing.test("wait --card retries an unreachable Pomb and then reads on", function()
    local result, seen =
        wait_card({ {}, { broken = "board unavailable: pass timed out" }, { column = "Done" } })
    testing.eq(result.output, "5af0e005 moved to Done")
    testing.eq(#seen.naps, 2)
end)

testing.test("wait --card retries an unreachable Pomb on the first card listing", function()
    local result, seen = wait_card(
        { {}, { column = "Done" } },
        nil,
        { "board unavailable: pass timed out" }
    )
    testing.eq(result.output, "5af0e005 moved to Done")
    testing.eq(#seen.naps, 2)
end)

testing.test("wait --card fails on a read Pomb refuses", function()
    local result = wait_card({ {}, { broken = "Pomb refused the read" } })
    testing.ok(result.message:find("refused", 1, true), tostring(result.message))
end)

testing.test("wait --card refuses a card no card matches", function()
    local result = wait_card({ {} }, { "--card", "deadbeef" })
    testing.ok(result.message:find("No card starts with", 1, true), tostring(result.message))
end)

testing.test("wait --card refuses --for beside it", function()
    local result = wait_card({ {} }, { "--card", CARD_ID:sub(1, 8), "--for", "ready" })
    testing.ok(result.message:find("not both", 1, true), tostring(result.message))
end)
