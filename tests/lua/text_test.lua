local t = require("dev.testing")
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

t.test("words splits on any whitespace", function()
    t.eq(text.words("  a bb\tc\n"), { "a", "bb", "c" })
end)

t.test("wrap fills lines up to the width", function()
    t.eq(text.wrap({ "aa", "bb", "cc" }, 5), { "aa bb", "cc" })
end)

t.test("wrap gives a word wider than the width its own line", function()
    t.eq(text.wrap({ "a", "bbbbbbbb", "c" }, 4), { "a", "bbbbbbbb", "c" })
end)

t.test("wrap counts columns without color escapes", function()
    t.eq(text.wrap({ "\27[1maa\27[0m", "bb" }, 5), { "\27[1maa\27[0m bb" })
end)

t.test("wrap of no words is no lines", function()
    t.eq(text.wrap({}, 5), {})
end)
