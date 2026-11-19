local testing = require("dev.testing")
local text = require("dev.text")

testing.test("width counts codepoints", function()
    testing.eq(text.width("é●a"), 3)
end)

testing.test("width ignores ANSI escapes", function()
    testing.eq(text.width("\27[32m●\27[0m"), 1)
end)

testing.test("fit cuts with an ellipsis", function()
    testing.eq(text.fit("myproject-k3x", 8), "doug-ga…")
end)

testing.test("fit leaves a short string alone", function()
    testing.eq(text.fit("short", 8), "short")
end)

testing.test("fit cuts by codepoint and keeps escapes", function()
    testing.eq(text.fit("\27[32mééééé\27[0m", 3), "\27[32méé…\27[0m")
end)

testing.test("fit to width one gives only the ellipsis", function()
    testing.eq(text.fit("abc", 1), "…")
end)

testing.test("fit to width zero gives an empty string and keeps escapes", function()
    testing.eq(text.fit("abc", 0), "")
    testing.eq(text.fit("\27[32mabc\27[0m", 0), "\27[32m\27[0m")
end)

testing.test("words splits on any whitespace", function()
    testing.eq(text.words("  a bb\tc\n"), { "a", "bb", "c" })
end)

testing.test("wrap fills lines up to the width", function()
    testing.eq(text.wrap({ "aa", "bb", "cc" }, 5), { "aa bb", "cc" })
end)

testing.test("wrap gives a word wider than the width its own line", function()
    testing.eq(text.wrap({ "a", "bbbbbbbb", "c" }, 4), { "a", "bbbbbbbb", "c" })
end)

testing.test("wrap counts columns without color escapes", function()
    testing.eq(text.wrap({ "\27[1maa\27[0m", "bb" }, 5), { "\27[1maa\27[0m bb" })
end)

testing.test("wrap of no words is no lines", function()
    testing.eq(text.wrap({}, 5), {})
end)

testing.test("sentence capitalizes and ends with one period", function()
    testing.eq(text.sentence("no tag v1, nothing was pushed"), "No tag v1, nothing was pushed.")
    testing.eq(text.sentence("Already a sentence.\n"), "Already a sentence.")
    testing.eq(text.sentence("/tmp/x is dirty"), "/tmp/x is dirty.")
end)
