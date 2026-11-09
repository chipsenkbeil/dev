local testing = require("dev.testing")
local toml = require("dev.toml")

testing.test("parse reads a table, a string and a trailing comment", function()
    testing.eq(toml.parse('[remote]\nrunner = "ci" # c'), { remote = { runner = "ci" } })
end)

testing.test("parse nests dotted tables, with a parent defined after its child", function()
    local tree =
        assert(toml.parse('[board.pomb]\nurl = "u"\ntoken = "pass:x"\n[board]\nbackend = "pomb"\n'))
    testing.eq(tree, { board = { backend = "pomb", pomb = { url = "u", token = "pass:x" } } })
end)

testing.test("parse reads root keys, integers, booleans, arrays and quoted keys", function()
    local tree =
        assert(toml.parse('n = -3\nok = true\nno = false\nxs = [1, "a", true,]\n"a b" = 1\n'))
    testing.eq(tree, { n = -3, ok = true, no = false, xs = { 1, "a", true }, ["a b"] = 1 })
end)

testing.test("parse reads escapes and keeps a # inside a string", function()
    testing.eq(toml.parse('s = "a\\tb\\n\\"c\\\\ # not"\r\n'), { s = 'a\tb\n"c\\ # not' })
end)

testing.test("parse accepts an empty document and comment lines", function()
    testing.eq(toml.parse("# c\n\n   # d\n"), {})
end)

testing.test("parse rejects an inline table at line 1", function()
    local tree, err = toml.parse("a = {b = 1}")
    testing.eq(tree, nil)
    testing.ok(err:find("^1: inline tables"), err)
end)

testing.test("parse names the line of each unsupported form", function()
    local cases = {
        { 'x = 1\ny = """a"""', "^2: multi%-line strings" },
        { "d = 2026-10-27", "^1: dates" },
        { "[[a]]", "^1: arrays of tables" },
        { "a.b = 1", "^1: dotted keys" },
        { "a = [1,\n2]", "^1: multi%-line arrays" },
        { "a = [[1]]", "^1: nested arrays" },
        { "a = 'x'", "^1: literal strings" },
        { 'a = "\\u0041"', "^1: unsupported escape" },
        { 'a = "x', "^1: unterminated" },
        { "a = 1.5", "^1: unsupported value" },
        { "a = 99999999999999999999", "^1: integer .* too large" },
        { "a = []\n[a]", "^2: key a is not a table" },
        { "a = 1 b", "^1: unexpected text" },
        { "a 1", "^1: expected =" },
        { "a =", "^1: missing value" },
        { "a = 1\na = 2", "^2: key a defined twice" },
        { "[a]\n[a]", "^2: table defined twice" },
        { "a = 1\n[a]", "^2: key a is not a table" },
        { "[a\n", "^1: expected %. or %]" },
    }
    for _, case in ipairs(cases) do
        local tree, err = toml.parse(case[1])
        testing.eq(tree, nil)
        testing.ok(err and err:find(case[2]), case[1] .. " gave " .. tostring(err))
    end
end)
