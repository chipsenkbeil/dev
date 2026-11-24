local dev_os = require("dev.os")
local toml = require("dev.toml")

local failures = 0

local function check(name, body)
    local ok, err = pcall(body)
    if ok then
        print("ok   " .. name)
    else
        failures += 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local function equal(actual, expected)
    if type(actual) ~= type(expected) then
        return false
    end
    if type(actual) ~= "table" then
        return actual == expected
    end
    for key, value in actual do
        if not equal(value, expected[key]) then
            return false
        end
    end
    for key in expected do
        if actual[key] == nil then
            return false
        end
    end
    return true
end

local function show(value)
    if type(value) ~= "table" then
        return tostring(value)
    end
    local parts = {}
    for key, item in value do
        table.insert(parts, tostring(key) .. "=" .. show(item))
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

local function same(actual, expected)
    if not equal(actual, expected) then
        error(string.format("expected %s, got %s", show(expected), show(actual)), 2)
    end
end

local function starts(text, prefix)
    if text == nil or text:sub(1, #prefix) ~= prefix then
        error(string.format("expected %q to start with %q", tostring(text), prefix), 2)
    end
end

local function lines(...)
    return table.concat({ ... }, "\n")
end

check("parse reads a table, a string and a trailing comment", function()
    same(toml.parse(lines("[remote]", 'runner = "ci" # c')), { remote = { runner = "ci" } })
end)

check("parse nests dotted tables, with a parent defined after its child", function()
    local tree = assert(
        toml.parse(
            lines(
                "[board.pomb]",
                'url = "u"',
                'token = "pass:x"',
                "[board]",
                'backend = "pomb"',
                ""
            )
        )
    )
    same(tree, { board = { backend = "pomb", pomb = { url = "u", token = "pass:x" } } })
end)

check("parse reads root keys, integers, booleans, arrays and quoted keys", function()
    local tree = assert(
        toml.parse(
            lines("n = -3", "ok = true", "no = false", 'xs = [1, "a", true,]', '"a b" = 1', "")
        )
    )
    same(tree, { n = -3, ok = true, no = false, xs = { 1, "a", true }, ["a b"] = 1 })
end)

check("parse reads escapes and keeps a # inside a string", function()
    same(toml.parse('s = "a\\tb\\n\\"c\\\\ # not"\r\n'), { s = 'a\tb\n"c\\ # not' })
end)

check("parse reads a multi-line array as the one-line form", function()
    local flat = assert(toml.parse(lines("[board.release]", 'checks = ["a", "b c"]', "n = 1")))
    local spread = assert(
        toml.parse(
            lines("[board.release]", "checks = [", '    "a",', "", '    "b c"', "]", "n = 1")
        )
    )
    same(spread, flat)
    same(spread.board.release.checks, { "a", "b c" })
end)

check("parse reads a CRLF multi-line array", function()
    local entries =
        { "[board.release]", "checks = [", '    "a",', "", '    "b c"', "]", "n = 1", "" }
    same(toml.parse(table.concat(entries, "\r\n")), toml.parse(table.concat(entries, "\n")))
end)

check("parse accepts an empty document and comment lines", function()
    same(toml.parse(lines("# c", "", "   # d", "")), {})
end)

check("parse names the line of a failure", function()
    local tree, err = toml.parse(lines("xs = [", "    1,", "]", "", "a 1"))
    same(tree, nil)
    starts(err, "5: ")
    tree, err = toml.parse(lines("a = 1", "a = 2"))
    same(tree, nil)
    starts(err, "2: ")
end)

check("parse reads the TOML 1.0 forms the old reader refused", function()
    same(toml.parse("a = {b = 1}"), { a = { b = 1 } })
    same(toml.parse("a.b = 1"), { a = { b = 1 } })
    same(toml.parse("a = 'x'"), { a = "x" })
    same(toml.parse("a = 1.5"), { a = 1.5 })
    same(toml.parse("a = [[1]]"), { a = { { 1 } } })
    same(toml.parse('a = """x\ny"""'), { a = "x\ny" })
    same(toml.parse("d = 2026-10-27"), { d = "2026-10-27" })
    same(toml.parse('a = "\\u0041"'), { a = "A" })
    same(toml.parse(lines("[[a]]", "x = 1", "[[a]]", "x = 2")), { a = { { x = 1 }, { x = 2 } } })
end)

check("parse refuses what TOML refuses", function()
    for _, text in { "[a]\n[a]", "a = 1\n[a]", "a 1", "a =", "a = 1 b", "[a\n" } do
        local tree, err = toml.parse(text)
        same(tree, nil)
        assert(err and err:find("^%d+: "), tostring(err))
    end
end)

check("set adds a key under an existing section and keeps the rest of the file", function()
    local input =
        lines("# mine", "[board.pomb]", 'url = "u"  # keep', "", "[gerrit]", 'host = "h"', "")
    local out = assert(toml.set(input, "board.pomb.token", "pass:x"))
    same(
        out,
        lines(
            "# mine",
            "[board.pomb]",
            'url = "u"  # keep',
            'token = "pass:x"',
            "",
            "[gerrit]",
            'host = "h"',
            ""
        )
    )
    same(toml.parse(out).board.pomb, { url = "u", token = "pass:x" })
end)

check("set makes the section when it is absent", function()
    local out = assert(toml.set(lines("[a]", "x = 1", ""), "gerrit.host", "h"))
    same(out, lines("[a]", "x = 1", "", "[gerrit]", 'host = "h"', ""))
    same(assert(toml.set("", "gerrit.port", 29418)), lines("[gerrit]", "port = 29418", ""))
end)

check("set writes a list of strings, an integer and an escaped string", function()
    local out = assert(toml.set("", "board.ship.source_roots", { "a/", "b c/" }))
    same(toml.parse(out).board.ship.source_roots, { "a/", "b c/" })
    out = assert(toml.set(out, "board.ship.n", 3))
    same(toml.parse(out).board.ship.n, 3)
    out = assert(toml.set(out, "board.ship.s", 'q"\\t'))
    same(toml.parse(out).board.ship.s, 'q"\\t')
end)

check("set puts a root key before the first table", function()
    local out = assert(toml.set(lines("# c", "[a]", "x = 1", ""), "top", "v"))
    same(out, lines('top = "v"', "# c", "[a]", "x = 1", ""))
    same(toml.parse(out), { top = "v", a = { x = 1 } })
end)

check("set returns a reason for a key already set, a bad key and a bad value", function()
    local set = lines("[a]", "x = 1", "")
    local Refusal = toml.SetRefusal
    local cases = {
        { set, "a.x", "v", Refusal.ALREADY_SET },
        { "", "a..b", "v", Refusal.BAD_KEY },
        { "", "a b", "v", Refusal.BAD_KEY },
        { "", "a.b", {}, Refusal.BAD_VALUE },
        { "", "a.b", { 1 }, Refusal.BAD_VALUE },
    }
    for _, case in cases do
        local out, reason = toml.set(case[1], case[2], case[3])
        same(out, nil)
        same(reason, case[4])
    end
    same(Refusal.BAD_KEY, "bad_key")
end)

check("set names the line of a file that does not parse", function()
    local out, reason, detail = toml.set("[a\n", "a.b", "v")
    same(out, nil)
    same(reason, toml.SetRefusal.UNPARSEABLE)
    starts(detail, "1:")
end)

check("set refuses to write a file that would not parse", function()
    local out, reason, detail =
        toml.set(lines('[board."pomb"]', 'url = "u"', ""), "board.pomb.token", "pass:x")
    same(out, nil)
    same(reason, toml.SetRefusal.RESULT_INVALID)
    starts(detail, "")
end)

check("encode round-trips a tree through parse", function()
    local trees = {
        {},
        { a = 1, b = "x", c = true, d = 1.5, e = { 1, 2, 3 }, f = { "a", "b" } },
        { board = { pomb = { url = "u", token = "pass:x" }, backend = "pomb" } },
        { ["a b"] = { ["c.d"] = "v" }, s = 'q"\\\n\t\1' },
        { list = { { x = 1 }, { x = 2, y = { z = 3 } } }, empty = {} },
        { mixed = { 1, "a", { k = 1 } }, nested = { { 1 }, { 2, 3 } } },
        { big = 1e300, neg = -5, tiny = 0.000001 },
    }
    for _, tree in trees do
        local text = toml.encode(tree)
        local back, err = toml.parse(text)
        same(back, tree)
        assert(back, tostring(err) .. "\n" .. text)
    end
end)

check("set keeps a key out of a multi-line string with blank, comment and header lines", function()
    local input = '[a]\nx = """\nfirst\n\n# not a comment\n[b]\n"""\ny = 1\n'
    local out = assert(toml.set(input, "a.z", "v"))
    same(out, input .. 'z = "v"\n')
    same(toml.parse(out).a.z, "v")
    same(toml.parse(out).a.x, "first\n\n# not a comment\n[b]\n")
end)

check("set writes CRLF lines into a CRLF file", function()
    local out = assert(toml.set("[a]\r\nx = 1\r\n", "b.y", "v"))
    same(out, '[a]\r\nx = 1\r\n\r\n[b]\r\ny = "v"\r\n')
    out = assert(toml.set("[a]\r\nx = 1\r\n", "a.y", "v"))
    same(out, '[a]\r\nx = 1\r\ny = "v"\r\n')
end)

if failures > 0 then
    print(failures .. " failed")
    dev_os.exit(1)
end
