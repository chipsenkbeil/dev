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
    testing.ok(err:find("^5: key with no value", 1), err)
end)

testing.test("parse names the line where an unclosed array ends", function()
    local tree, err = toml.parse(table.concat({
        "a = 1",
        "xs = [",
        "    1,",
        "    2,",
        "",
    }, "\n"))
    testing.eq(tree, nil)
    testing.ok(err:find("^4: unclosed array", 1), err)
end)

testing.test("parse reads a key line inside an array as a bad value", function()
    local tree, err = toml.parse(table.concat({
        "xs = [",
        "    1,",
        "b = 2",
        "]",
    }, "\n"))
    testing.eq(tree, nil)
    testing.ok(err:find("^3: unexpected `=` in array", 1), err)
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

testing.test("parse reads the TOML forms the old reader refused", function()
    testing.eq(toml.parse("a = {b = 1}"), { a = { b = 1 } })
    testing.eq(toml.parse(table.concat({ "x = 1", 'y = """a"""' }, "\n")), { x = 1, y = "a" })
    testing.eq(toml.parse("d = 2026-10-27"), { d = "2026-10-27" })
    testing.eq(toml.parse("[[a]]"), { a = { {} } })
    testing.eq(toml.parse("a.b = 1"), { a = { b = 1 } })
    testing.eq(toml.parse("a = [[1]]"), { a = { { 1 } } })
    testing.eq(toml.parse("a = 'x'"), { a = "x" })
    testing.eq(toml.parse('a = "\\u0041"'), { a = "A" })
    testing.eq(toml.parse("a = 1.5"), { a = 1.5 })
end)

testing.test("parse names the line of each form it refuses", function()
    local cases = {
        { 'a = "x', "^1: invalid basic string" },
        { "a = 99999999999999999999", "^1: invalid type: integer" },
        {
            table.concat({
                "a = []",
                "[a]",
            }, "\n"),
            "^2: duplicate key",
        },
        { "a = 1 b", "^1: string values must be quoted" },
        { "a 1", "^1: key with no value" },
        { "a =", "^1: string values must be quoted" },
        {
            table.concat({
                "a = 1",
                "a = 2",
            }, "\n"),
            "^2: duplicate key",
        },
        {
            table.concat({
                "[a]",
                "[a]",
            }, "\n"),
            "^2: duplicate key",
        },
        {
            table.concat({
                "a = 1",
                "[a]",
            }, "\n"),
            "^2: duplicate key",
        },
        {
            table.concat({
                "[a",
                "",
            }, "\n"),
            "^1: unclosed table",
        },
    }
    for _, case in ipairs(cases) do
        local tree, err = toml.parse(case[1])
        testing.eq(tree, nil)
        testing.ok(err and err:find(case[2]), case[1] .. " gave " .. tostring(err))
    end
end)

testing.test("set adds a key under an existing section and keeps the rest of the file", function()
    local input = table.concat({
        "# mine",
        "[board.pomb]",
        'url = "u"  # keep',
        "",
        "[gerrit]",
        'host = "h"',
        "",
    }, "\n")
    local out = assert(toml.set(input, "board.pomb.token", "pass:x"))
    testing.eq(
        out,
        table.concat({
            "# mine",
            "[board.pomb]",
            'url = "u"  # keep',
            'token = "pass:x"',
            "",
            "[gerrit]",
            'host = "h"',
            "",
        }, "\n")
    )
    testing.eq(toml.parse(out).board.pomb, { url = "u", token = "pass:x" })
end)

testing.test("set makes the section when it is absent", function()
    local out = assert(toml.set(table.concat({ "[a]", "x = 1", "" }, "\n"), "gerrit.host", "h"))
    testing.eq(out, table.concat({ "[a]", "x = 1", "", "[gerrit]", 'host = "h"', "" }, "\n"))
    local port = assert(toml.set("", "gerrit.port", 29418))
    testing.eq(port, table.concat({ "[gerrit]", "port = 29418", "" }, "\n"))
end)

testing.test("set writes a list of strings, an integer and an escaped string", function()
    local out = assert(toml.set("", "board.ship.source_roots", { "a/", "b c/" }))
    testing.eq(toml.parse(out).board.ship.source_roots, { "a/", "b c/" })
    out = assert(toml.set(out, "board.ship.n", 3))
    testing.eq(toml.parse(out).board.ship.n, 3)
    out = assert(toml.set(out, "board.ship.s", 'q"\\t'))
    testing.eq(toml.parse(out).board.ship.s, 'q"\\t')
end)

testing.test("set puts a root key before the first table", function()
    local out = assert(toml.set(table.concat({ "# c", "[a]", "x = 1", "" }, "\n"), "top", "v"))
    testing.eq(out, table.concat({ 'top = "v"', "# c", "[a]", "x = 1", "" }, "\n"))
    testing.eq(toml.parse(out), { top = "v", a = { x = 1 } })
end)

testing.test("set returns a reason for a key already set, a bad key and a bad value", function()
    local set = table.concat({ "[a]", "x = 1", "" }, "\n")
    local Refusal = toml.SetRefusal
    local cases = {
        { set, "a.x", "v", Refusal.ALREADY_SET },
        { "", "a..b", "v", Refusal.BAD_KEY },
        { "", "a b", "v", Refusal.BAD_KEY },
        { "", "a.b", {}, Refusal.BAD_VALUE },
        { "", "a.b", { 1 }, Refusal.BAD_VALUE },
    }
    for _, case in ipairs(cases) do
        local out, reason = toml.set(case[1], case[2], case[3])
        testing.eq(out, nil)
        testing.eq(reason, case[4])
    end
end)

testing.test("set names the line of a file that does not parse", function()
    local out, reason, detail = toml.set("[a\n", "a.b", "v")
    testing.eq(out, nil)
    testing.eq(reason, toml.SetRefusal.UNPARSEABLE)
    testing.ok(detail and detail:find("^1:"), tostring(detail))
end)

testing.test("set refuses to write a file that would not parse", function()
    local input = table.concat({ '[board."pomb"]', 'url = "u"', "" }, "\n")
    local out, reason, detail = toml.set(input, "board.pomb.token", "pass:x")
    testing.eq(out, nil)
    testing.eq(reason, toml.SetRefusal.RESULT_INVALID)
    testing.ok(detail and detail:find("4: duplicate key", 1, true), tostring(detail))
end)
