local testing = require("@dev/testing")

testing.test("eq compares nested tables deeply", function()
    testing.eq({ a = { 1, 2 } }, { a = { 1, 2 } })
end)

testing.test("eq compares cyclic tables without overflowing the stack", function()
    local function cyclic(leaf)
        local node = { leaf = leaf }
        node.self = node
        return node
    end
    testing.eq(cyclic(1), cyclic(1))
    testing.raises(function()
        testing.eq(cyclic(1), cyclic(2))
    end, "want")
end)

testing.test("eq failure message shows both values", function()
    testing.raises(function()
        testing.eq(1, 2)
    end, "want 2")
end)

testing.test("raises matches the error message", function()
    testing.raises(function()
        error("boom")
    end, "boom")
end)
