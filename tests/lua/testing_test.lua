local t = require("dev.testing")

t.test("eq compares nested tables deeply", function()
    t.eq({ a = { 1, 2 } }, { a = { 1, 2 } })
end)

t.test("eq failure message shows both values", function()
    t.raises(function()
        t.eq(1, 2)
    end, "want 2")
end)

t.test("raises matches the error message", function()
    t.raises(function()
        error("boom")
    end, "boom")
end)
