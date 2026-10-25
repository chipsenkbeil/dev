local t = require("testing")
local text = require("dev.text")

t.test("width counts codepoints", function()
    t.eq(text.width("é●a"), 3)
end)

t.test("width ignores ANSI escapes", function()
    t.eq(text.width("\27[32m●\27[0m"), 1)
end)

t.test("fit cuts with an ellipsis", function()
    t.eq(text.fit("myproject-k3x", 8), "doug-ga…")
end)

t.test("fit leaves a short string alone", function()
    t.eq(text.fit("short", 8), "short")
end)

t.test("fit cuts by codepoint and keeps escapes", function()
    t.eq(text.fit("\27[32mééééé\27[0m", 3), "\27[32méé…\27[0m")
end)
