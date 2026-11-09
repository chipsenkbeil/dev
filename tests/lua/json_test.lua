local testing = require("dev.testing")
local json = require("dev.json")

local TARGET = "linux-x86-base"
local JOBS = '{"jobs":[{"name":"lint","targets":["' .. TARGET .. '"]}],"pipeline":"./.ci/jobs.lua"}'
local BOX = '{"name":"myproject-k3x","state":"running","profile":"medium","cpu":8,"memory_gib":16,'
    .. '"projects":[{"name":"myproject","path":"/srv/projects/myproject"}],"tailnet_name":"box-myproject-k3x",'
    .. '"created_at":"2026-10-19T14:03:11Z","ttl_hours":4,"expires_at":"2026-10-19T18:03:11Z","stopped_at":null,'
    .. '"delete_after":null,"tmux_sessions":null,"archive":null,"error":null}'

testing.test("decode reads ci's jobs document", function()
    local doc = assert(json.decode(JOBS))
    testing.eq(doc.pipeline, "./.ci/jobs.lua")
    testing.eq(doc.jobs[1].name, "lint")
    testing.eq(doc.jobs[1].targets, { TARGET })
end)

testing.test("decode reads a box document with null fields", function()
    local box = assert(json.decode(BOX))
    testing.eq(box.tmux_sessions, json.null)
    testing.eq(box.stopped_at, json.null)
    testing.eq(box.cpu, 8)
    testing.eq(box.projects[1].path, "/srv/projects/myproject")
end)

testing.test("decode keeps null inside arrays so lengths hold", function()
    local list = assert(json.decode("[1,null,3]"))
    testing.eq(#list, 3)
    testing.eq(list[2], json.null)
end)

testing.test("decode turns escapes and surrogate pairs into UTF-8", function()
    testing.eq(json.decode('"\\u00e9"'), "é")
    testing.eq(json.decode('"\\ud83d\\ude00"'), "😀")
    testing.eq(json.decode('"é😀"'), "é😀")
    testing.eq(json.decode('"a\\n\\t\\"\\\\\\/b"'), 'a\n\t"\\/b')
end)

testing.test("decode rejects an unpaired surrogate", function()
    local value, err = json.decode('"\\ud83d"')
    testing.eq(value, nil)
    testing.ok(err:find("surrogate"), err)
    testing.eq((json.decode('"\\ude00"')), nil)
end)

testing.test("decode reads numbers", function()
    testing.eq(json.decode("1e3"), 1000)
    testing.eq(json.decode("-0.5"), -0.5)
    testing.eq(json.decode("0"), 0)
    testing.eq(json.decode("[1.5E-1]"), { 0.15 })
end)

testing.test("decode rejects malformed numbers", function()
    for _, bad in ipairs({ "01", "-", "1.", "1e", ".5", "+1", "--1" }) do
        testing.eq((json.decode(bad)), nil)
    end
end)

testing.test("decode names the byte offset of trailing data", function()
    local value, err = json.decode('{"a":1} x')
    testing.eq(value, nil)
    testing.eq(err, "unexpected trailing data at offset 9")
end)

testing.test("decode names the offset of other errors", function()
    local _, err = json.decode('{"a":}')
    testing.eq(err, "unexpected character at offset 6")
    _, err = json.decode('{"a":1')
    testing.eq(err, "expected , or } at offset 7")
    _, err = json.decode("")
    testing.eq(err, "unexpected end at offset 1")
    _, err = json.decode('"abc')
    testing.ok(err:find("unterminated string"), err)
end)

testing.test("decode rejects raw control characters in strings", function()
    testing.eq((json.decode('"a\nb"')), nil)
end)

testing.test("decode refuses nesting deeper than 200 without overflowing", function()
    local ok = assert(json.decode(string.rep("[", 200) .. string.rep("]", 200)))
    testing.ok(type(ok) == "table", "200 levels should decode")
    local value, err = json.decode(string.rep("[", 201) .. string.rep("]", 201))
    testing.eq(value, nil)
    testing.ok(err:find("nesting too deep"), err)
    value = json.decode(string.rep("[", 100000))
    testing.eq(value, nil)
end)

testing.test("decode accepts literals and whitespace", function()
    testing.eq(json.decode(" \n[true , false,\tnull ] "), { true, false, json.null })
end)

testing.test("encode writes scalars", function()
    testing.eq(json.encode(1), "1")
    testing.eq(json.encode(-0.5), "-0.5")
    testing.eq(json.encode(1e300), "1e+300")
    testing.eq(json.encode(true), "true")
    testing.eq(json.encode(json.null), "null")
    testing.eq(json.encode("x"), '"x"')
end)

testing.test("encode escapes quotes, backslashes and control characters", function()
    testing.eq(json.encode('a"b\\c\n\t\r\8\12\1\31'), '"a\\"b\\\\c\\n\\t\\r\\b\\f\\u0001\\u001f"')
    testing.eq(json.encode("é😀"), '"é😀"')
end)

testing.test("encode tells arrays from objects", function()
    testing.eq(json.encode({ 1, 2, 3 }), "[1,2,3]")
    testing.eq(json.encode({}), "[]")
    testing.eq(json.encode(json.object()), "{}")
    testing.eq(json.encode({ a = 1 }), '{"a":1}')
    testing.eq((json.encode({ [1] = "x", [3] = "z" })), nil)
    testing.eq(json.encode({ 1, json.null, 3 }), "[1,null,3]")
end)

testing.test("encode orders keys: opts.order first, the rest sorted", function()
    local doc =
        { zeta = 1, alpha = 2, model = "m", messages = { { role = "user", content = "hi" } } }
    testing.eq(
        json.encode(doc),
        '{"alpha":2,"messages":[{"content":"hi","role":"user"}],"model":"m","zeta":1}'
    )
    testing.eq(
        json.encode(doc, { order = { "model", "messages", "role", "content", "absent" } }),
        '{"model":"m","messages":[{"role":"user","content":"hi"}],"alpha":2,"zeta":1}'
    )
end)

testing.test("encode round-trips what decode reads", function()
    local doc = assert(json.decode(BOX))
    testing.eq(json.decode(assert(json.encode(doc))), doc)
end)

testing.test("encode fails on values it cannot write", function()
    local text, err = json.encode({ f = print })
    testing.eq(text, nil)
    testing.ok(err:find("function"), err)
    testing.eq((json.encode(0 / 0)), nil)
    testing.eq((json.encode(math.huge)), nil)
    testing.eq((json.encode({ [true] = 1 })), nil)
    local loop = {}
    loop.self = loop
    testing.eq((json.encode(loop)), nil)
end)

testing.test("decode and encode round-trip empty objects and arrays, nested", function()
    for _, text in ipairs({
        '{"a":{}}',
        '{"a":[]}',
        "[{},[]]",
        '{"a":{"b":{},"c":[[]]}}',
        "{}",
        "[]",
    }) do
        testing.eq(json.encode(assert(json.decode(text))), text)
    end
end)

testing.test("decode accepts a raw DEL in a string", function()
    testing.eq(json.decode('"a\127b"'), "a\127b")
    testing.eq(json.encode("a\127b"), '"a\\u007fb"')
end)

testing.test("decode keeps the last value of a repeated key", function()
    testing.eq(json.decode('{"a":1,"a":2}'), { a = 2 })
end)

testing.test("decode rejects a number that overflows", function()
    local value, err = json.decode("[1e999]")
    testing.eq(value, nil)
    testing.eq(err, "number out of range at offset 2")
    testing.eq((json.decode("-1e999")), nil)
end)

testing.test("encode refuses nesting deeper than 200", function()
    local deep = {}
    for _ = 1, 201 do
        deep = { deep }
    end
    local text, err = json.encode(deep)
    testing.eq(text, nil)
    testing.eq(err, "nesting too deep")
    local ok = {}
    for _ = 1, 199 do
        ok = { ok }
    end
    testing.ok(json.encode(ok), "199 levels should encode")
end)

testing.test("present turns the null sentinel into nil and keeps other values", function()
    testing.eq(json.present(json.null), nil)
    testing.eq(json.present("x"), "x")
    testing.eq(json.present(false), false)
end)
