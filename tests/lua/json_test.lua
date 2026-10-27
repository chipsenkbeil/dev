local t = require("testing")
local json = require("dev.json")

local JOBS = '{"jobs":[{"name":"lint","oses":["linux-base"]}],"pipeline":"./.ci/jobs.lua"}'
local BOX = '{"name":"myproject-k3x","state":"running","profile":"medium","cpu":8,"memory_gib":16,'
    .. '"projects":[{"name":"myproject","path":"/srv/projects/myproject"}],"tailnet_name":"box-myproject-k3x",'
    .. '"created_at":"2026-10-19T14:03:11Z","ttl_hours":4,"expires_at":"2026-10-19T18:03:11Z","stopped_at":null,'
    .. '"delete_after":null,"tmux_sessions":null,"archive":null,"error":null}'

t.test("decode reads ci's jobs document", function()
    local doc = assert(json.decode(JOBS))
    t.eq(doc.pipeline, "./.ci/jobs.lua")
    t.eq(doc.jobs[1].name, "lint")
    t.eq(doc.jobs[1].oses, { "linux-base" })
end)

t.test("decode reads a box document with null fields", function()
    local box = assert(json.decode(BOX))
    t.eq(box.tmux_sessions, json.null)
    t.eq(box.stopped_at, json.null)
    t.eq(box.cpu, 8)
    t.eq(box.projects[1].path, "/srv/projects/myproject")
end)

t.test("decode keeps null inside arrays so lengths hold", function()
    local list = assert(json.decode("[1,null,3]"))
    t.eq(#list, 3)
    t.eq(list[2], json.null)
end)

t.test("decode turns escapes and surrogate pairs into UTF-8", function()
    t.eq(json.decode('"\\u00e9"'), "é")
    t.eq(json.decode('"\\ud83d\\ude00"'), "😀")
    t.eq(json.decode('"é😀"'), "é😀")
    t.eq(json.decode('"a\\n\\t\\"\\\\\\/b"'), 'a\n\t"\\/b')
end)

t.test("decode rejects an unpaired surrogate", function()
    local value, err = json.decode('"\\ud83d"')
    t.eq(value, nil)
    t.ok(err:find("surrogate"), err)
    t.eq((json.decode('"\\ude00"')), nil)
end)

t.test("decode reads numbers", function()
    t.eq(json.decode("1e3"), 1000)
    t.eq(json.decode("-0.5"), -0.5)
    t.eq(json.decode("0"), 0)
    t.eq(json.decode("[1.5E-1]"), { 0.15 })
end)

t.test("decode rejects malformed numbers", function()
    for _, bad in ipairs({ "01", "-", "1.", "1e", ".5", "+1", "--1" }) do
        t.eq((json.decode(bad)), nil)
    end
end)

t.test("decode names the byte offset of trailing data", function()
    local value, err = json.decode('{"a":1} x')
    t.eq(value, nil)
    t.eq(err, "unexpected trailing data at offset 9")
end)

t.test("decode names the offset of other errors", function()
    local _, err = json.decode('{"a":}')
    t.eq(err, "unexpected character at offset 6")
    _, err = json.decode('{"a":1')
    t.eq(err, "expected , or } at offset 7")
    _, err = json.decode("")
    t.eq(err, "unexpected end at offset 1")
    _, err = json.decode('"abc')
    t.ok(err:find("unterminated string"), err)
end)

t.test("decode rejects raw control characters in strings", function()
    t.eq((json.decode('"a\nb"')), nil)
end)

t.test("decode refuses nesting deeper than 200 without overflowing", function()
    local ok = assert(json.decode(string.rep("[", 200) .. string.rep("]", 200)))
    t.ok(type(ok) == "table", "200 levels should decode")
    local value, err = json.decode(string.rep("[", 201) .. string.rep("]", 201))
    t.eq(value, nil)
    t.ok(err:find("nesting too deep"), err)
    value = json.decode(string.rep("[", 100000))
    t.eq(value, nil)
end)

t.test("decode accepts literals and whitespace", function()
    t.eq(json.decode(" \n[true , false,\tnull ] "), { true, false, json.null })
end)

t.test("encode writes scalars", function()
    t.eq(json.encode(1), "1")
    t.eq(json.encode(-0.5), "-0.5")
    t.eq(json.encode(1e300), "1e+300")
    t.eq(json.encode(true), "true")
    t.eq(json.encode(json.null), "null")
    t.eq(json.encode("x"), '"x"')
end)

t.test("encode escapes quotes, backslashes and control characters", function()
    t.eq(json.encode('a"b\\c\n\t\r\8\12\1\31'), '"a\\"b\\\\c\\n\\t\\r\\b\\f\\u0001\\u001f"')
    t.eq(json.encode("é😀"), '"é😀"')
end)

t.test("encode tells arrays from objects", function()
    t.eq(json.encode({ 1, 2, 3 }), "[1,2,3]")
    t.eq(json.encode({}), "[]")
    t.eq(json.encode(json.object()), "{}")
    t.eq(json.encode({ a = 1 }), '{"a":1}')
    t.eq((json.encode({ [1] = "x", [3] = "z" })), nil)
    t.eq(json.encode({ 1, json.null, 3 }), "[1,null,3]")
end)

t.test("encode orders keys: opts.order first, the rest sorted", function()
    local doc =
        { zeta = 1, alpha = 2, model = "m", messages = { { role = "user", content = "hi" } } }
    t.eq(
        json.encode(doc),
        '{"alpha":2,"messages":[{"content":"hi","role":"user"}],"model":"m","zeta":1}'
    )
    t.eq(
        json.encode(doc, { order = { "model", "messages", "role", "content", "absent" } }),
        '{"model":"m","messages":[{"role":"user","content":"hi"}],"alpha":2,"zeta":1}'
    )
end)

t.test("encode round-trips what decode reads", function()
    local doc = assert(json.decode(BOX))
    t.eq(json.decode(assert(json.encode(doc))), doc)
end)

t.test("encode fails on values it cannot write", function()
    local text, err = json.encode({ f = print })
    t.eq(text, nil)
    t.ok(err:find("function"), err)
    t.eq((json.encode(0 / 0)), nil)
    t.eq((json.encode(math.huge)), nil)
    t.eq((json.encode({ [true] = 1 })), nil)
    local loop = {}
    loop.self = loop
    t.eq((json.encode(loop)), nil)
end)

t.test("decode and encode round-trip empty objects and arrays, nested", function()
    for _, text in ipairs({
        '{"a":{}}',
        '{"a":[]}',
        "[{},[]]",
        '{"a":{"b":{},"c":[[]]}}',
        "{}",
        "[]",
    }) do
        t.eq(json.encode(assert(json.decode(text))), text)
    end
end)

t.test("decode accepts a raw DEL in a string", function()
    t.eq(json.decode('"a\127b"'), "a\127b")
    t.eq(json.encode("a\127b"), '"a\\u007fb"')
end)

t.test("decode keeps the last value of a repeated key", function()
    t.eq(json.decode('{"a":1,"a":2}'), { a = 2 })
end)

t.test("decode rejects a number that overflows", function()
    local value, err = json.decode("[1e999]")
    t.eq(value, nil)
    t.eq(err, "number out of range at offset 2")
    t.eq((json.decode("-1e999")), nil)
end)

t.test("encode refuses nesting deeper than 200", function()
    local deep = {}
    for _ = 1, 201 do
        deep = { deep }
    end
    local text, err = json.encode(deep)
    t.eq(text, nil)
    t.eq(err, "nesting too deep")
    local ok = {}
    for _ = 1, 199 do
        ok = { ok }
    end
    t.ok(json.encode(ok), "199 levels should encode")
end)

t.test("present turns the null sentinel into nil and keeps other values", function()
    t.eq(json.present(json.null), nil)
    t.eq(json.present("x"), "x")
    t.eq(json.present(false), false)
end)
