local testing = require("dev.testing")
local toml = require("dev.toml")

testing.test("parse reads a table, a string and a trailing comment", function()
    local input = table.concat({
        "[remote]",
        'runner = "ci" # c',
    }, "\n")
    testing.eq(toml.parse(input), { remote = { runner = "ci" } })
end)

testing.test("parse nests dotted tables, with a parent defined after its child", function()
    local tree = assert(toml.parse(table.concat({
        "[board.pomb]",
        'url = "u"',
        'token = "pass:x"',
        "[board]",
        'backend = "pomb"',
        "",
    }, "\n")))
    testing.eq(tree, { board = { backend = "pomb", pomb = { url = "u", token = "pass:x" } } })
end)

testing.test("parse reads root keys, integers, booleans, arrays and quoted keys", function()
    local tree = assert(toml.parse(table.concat({
        "n = -3",
        "ok = true",
        "no = false",
        'xs = [1, "a", true,]',
        '"a b" = 1',
        "",
    }, "\n")))
    testing.eq(tree, { n = -3, ok = true, no = false, xs = { 1, "a", true }, ["a b"] = 1 })
end)

testing.test("parse reads escapes and keeps a # inside a string", function()
    local input = table.concat({
        's = "a\\tb\\n\\"c\\\\ # not"',
        "",
    }, "\r\n")
    testing.eq(toml.parse(input), { s = 'a\tb\n"c\\ # not' })
end)

testing.test("parse reads a multi-line array as the one-line form", function()
    local flat = assert(toml.parse(table.concat({
        "[board.release]",
        'checks = ["a", "b c"]',
        "n = 1",
    }, "\n")))
    local spread = assert(toml.parse(table.concat({
        "[board.release]",
        "checks = [",
        '    "a",',
        "",
        '    "b c"',
        "]",
        "n = 1",
    }, "\n")))
    testing.eq(spread, flat)
    testing.eq(spread.board.release.checks, { "a", "b c" })
end)

testing.test("parse reads a CRLF multi-line array", function()
    local entries = {
        "[board.release]",
        "checks = [",
        '    "a",',
        "",
        '    "b c"',
        "]",
        "n = 1",
        "",
    }
    local crlf = assert(toml.parse(table.concat(entries, "\r\n")))
    local lf = assert(toml.parse(table.concat(entries, "\n")))
    testing.eq(crlf, lf)
    testing.eq(crlf.board.release.checks, { "a", "b c" })
end)

testing.test("parse accepts a trailing comma and comments inside a multi-line array", function()
    local tree = assert(toml.parse(table.concat({
        "xs = [ # open",
        "    1, # one",
        "    # between",
        "    2,",
        "] # end",
        "y = 3",
    }, "\n")))
    testing.eq(tree, { xs = { 1, 2 }, y = 3 })
end)

testing.test("parse names the line two lines after a multi-line array closes", function()
    local tree, err = toml.parse(table.concat({
        "xs = [",
        "    1,",
        "]",
        "",
        "a 1",
    }, "\n"))
    testing.eq(tree, nil)
    testing.ok(err:find("^5: expected = after the key", 1), err)
end)

testing.test("parse names the opening line of an unclosed array", function()
    local tree, err = toml.parse(table.concat({
        "a = 1",
        "xs = [",
        "    1,",
        "    2,",
        "",
    }, "\n"))
    testing.eq(tree, nil)
    testing.ok(err:find("array opened on line 2 is not closed", 1, true), err)
end)

testing.test("parse reads a key line inside an array as a bad value", function()
    local tree, err = toml.parse(table.concat({
        "xs = [",
        "    1,",
        "b = 2",
        "]",
    }, "\n"))
    testing.eq(tree, nil)
    testing.ok(err:find("^3: unsupported value b"), err)
end)

testing.test("parse accepts an empty document and comment lines", function()
    testing.eq(
        toml.parse(table.concat({
            "# c",
            "",
            "   # d",
            "",
        }, "\n")),
        {}
    )
end)

testing.test("parse rejects an inline table at line 1", function()
    local tree, err = toml.parse("a = {b = 1}")
    testing.eq(tree, nil)
    testing.ok(err:find("^1: inline tables"), err)
end)

testing.test("parse names the line of each unsupported form", function()
    local cases = {
        {
            table.concat({
                "x = 1",
                'y = """a"""',
            }, "\n"),
            "^2: multi%-line strings",
        },
        { "d = 2026-10-27", "^1: dates" },
        { "[[a]]", "^1: arrays of tables" },
        { "a.b = 1", "^1: dotted keys" },
        { "a = [[1]]", "^1: nested arrays" },
        { "a = 'x'", "^1: literal strings" },
        { 'a = "\\u0041"', "^1: unsupported escape" },
        { 'a = "x', "^1: unterminated" },
        { "a = 1.5", "^1: unsupported value" },
        { "a = 99999999999999999999", "^1: integer .* too large" },
        {
            table.concat({
                "a = []",
                "[a]",
            }, "\n"),
            "^2: key a is not a table",
        },
        { "a = 1 b", "^1: unexpected text" },
        { "a 1", "^1: expected =" },
        { "a =", "^1: missing value" },
        {
            table.concat({
                "a = 1",
                "a = 2",
            }, "\n"),
            "^2: key a defined twice",
        },
        {
            table.concat({
                "[a]",
                "[a]",
            }, "\n"),
            "^2: table defined twice",
        },
        {
            table.concat({
                "a = 1",
                "[a]",
            }, "\n"),
            "^2: key a is not a table",
        },
        {
            table.concat({
                "[a",
                "",
            }, "\n"),
            "^1: expected %. or %]",
        },
    }
    for _, case in ipairs(cases) do
        local tree, err = toml.parse(case[1])
        testing.eq(tree, nil)
        testing.ok(err and err:find(case[2]), case[1] .. " gave " .. tostring(err))
    end
end)
