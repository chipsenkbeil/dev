local dev_os = require("@dev/os")
local json = require("@dev/json")

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
    if type(actual) ~= "table" or actual == json.null or expected == json.null then
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

local function same(actual, expected)
    if not equal(actual, expected) then
        error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
    end
end

local function holds(text, part)
    if not tostring(text):find(part, 1, true) then
        error(string.format("expected %q inside %q", part, tostring(text)), 2)
    end
end

local TARGET = "linux-x86-dev"
local JOBS = '{"jobs":[{"name":"lint","targets":["' .. TARGET .. '"]}],"pipeline":"./.ci/jobs.lua"}'
local BOX = '{"name":"myproject-k3x","state":"running","profile":"medium","cpu":8,"memory_gib":16,'
    .. '"projects":[{"name":"myproject","path":"/srv/projects/myproject"}],"tailnet_name":"box-myproject-k3x",'
    .. '"created_at":"2026-10-19T14:03:11Z","ttl_hours":4,"expires_at":"2026-10-19T18:03:11Z","stopped_at":null,'
    .. '"delete_after":null,"tmux_sessions":null,"archive":null,"error":null}'

check("decode reads ci's jobs document", function()
    local doc = assert(json.decode(JOBS))
    same(doc.pipeline, "./.ci/jobs.lua")
    same(doc.jobs[1].name, "lint")
    same(doc.jobs[1].targets, { TARGET })
end)

check("decode reads a box document with null fields", function()
    local box = assert(json.decode(BOX))
    same(box.tmux_sessions, json.null)
    same(box.stopped_at, json.null)
    same(box.cpu, 8)
    same(box.projects[1].path, "/srv/projects/myproject")
    same(tostring(json.null), "json.null")
end)

check("decode keeps null inside arrays so lengths hold", function()
    local list = assert(json.decode("[1,null,3]"))
    same(#list, 3)
    same(list[2], json.null)
end)

check("decode turns escapes and surrogate pairs into UTF-8", function()
    same(json.decode('"\\u00e9"'), "é")
    same(json.decode('"\\ud83d\\ude00"'), "😀")
    same(json.decode('"é😀"'), "é😀")
    same(json.decode('"a\\n\\t\\"\\\\\\/b"'), 'a\n\t"\\/b')
end)

check("decode rejects an unpaired surrogate", function()
    local value, err = json.decode('"\\ud83d"')
    same(value, nil)
    holds(err, "surrogate")
    same((json.decode('"\\ude00"')), nil)
end)

check("decode reads numbers", function()
    same(json.decode("1e3"), 1000)
    same(json.decode("-0.5"), -0.5)
    same(json.decode("0"), 0)
    same(json.decode("[1.5E-1]"), { 0.15 })
end)

check("decode rejects malformed numbers", function()
    for _, bad in { "01", "-", "1.", "1e", ".5", "+1", "--1" } do
        same((json.decode(bad)), nil)
    end
end)

check("decode names the byte offset of trailing data", function()
    local value, err = json.decode('{"a":1} x')
    same(value, nil)
    same(err, "unexpected trailing data at offset 9")
end)

check("decode names the offset of other errors", function()
    local _, err = json.decode('{"a":}')
    same(err, "unexpected character at offset 6")
    _, err = json.decode('{"a":1')
    same(err, "expected , or } at offset 7")
    _, err = json.decode("")
    same(err, "unexpected end at offset 1")
    _, err = json.decode('"abc')
    holds(err, "unterminated string")
end)

check("decode rejects raw control characters in strings", function()
    same((json.decode('"a\nb"')), nil)
end)

check("decode refuses nesting deeper than 200 without overflowing", function()
    local ok = assert(json.decode(string.rep("[", 200) .. string.rep("]", 200)))
    same(type(ok), "table")
    local value, err = json.decode(string.rep("[", 201) .. string.rep("]", 201))
    same(value, nil)
    holds(err, "nesting too deep")
    same((json.decode(string.rep("[", 100000))), nil)
end)

check("decode accepts literals and whitespace", function()
    same(json.decode(" \n[true , false,\tnull ] "), { true, false, json.null })
end)

check("encode writes scalars", function()
    same(json.encode(1), "1")
    same(json.encode(-0.5), "-0.5")
    same(json.encode(1e300), "1e+300")
    same(json.encode(true), "true")
    same(json.encode(json.null), "null")
    same(json.encode("x"), '"x"')
end)

check("encode escapes quotes, backslashes and control characters", function()
    same(json.encode('a"b\\c\n\t\r\8\12\1\31'), '"a\\"b\\\\c\\n\\t\\r\\b\\f\\u0001\\u001f"')
    same(json.encode("é😀"), '"é😀"')
end)

check("encode tells arrays from objects", function()
    same(json.encode({ 1, 2, 3 }), "[1,2,3]")
    same(json.encode({}), "[]")
    same(json.encode(json.object()), "{}")
    same(json.encode({ a = 1 }), '{"a":1}')
    same((json.encode({ [1] = "x", [3] = "z" })), nil)
    same(json.encode({ 1, json.null, 3 }), "[1,null,3]")
end)

check("encode orders keys: opts.order first, the rest sorted", function()
    local doc =
        { zeta = 1, alpha = 2, model = "m", messages = { { role = "user", content = "hi" } } }
    same(
        json.encode(doc),
        '{"alpha":2,"messages":[{"content":"hi","role":"user"}],"model":"m","zeta":1}'
    )
    same(
        json.encode(doc, { order = { "model", "messages", "role", "content", "absent" } }),
        '{"model":"m","messages":[{"role":"user","content":"hi"}],"alpha":2,"zeta":1}'
    )
end)

check("encode round-trips what decode reads", function()
    local doc = assert(json.decode(BOX))
    same(json.decode(assert(json.encode(doc))), doc)
end)

check("encode fails on values it cannot write", function()
    local text, err = json.encode({ f = print })
    same(text, nil)
    holds(err, "function")
    same((json.encode(0 / 0)), nil)
    same((json.encode(math.huge)), nil)
    same((json.encode({ [true] = 1 })), nil)
    local loop = {}
    loop.self = loop
    same((json.encode(loop)), nil)
end)

check("decode and encode round-trip empty objects and arrays, nested", function()
    for _, text in { '{"a":{}}', '{"a":[]}', "[{},[]]", '{"a":{"b":{},"c":[[]]}}', "{}", "[]" } do
        same(json.encode(assert(json.decode(text))), text)
    end
end)

check("decode accepts a raw DEL in a string", function()
    same(json.decode('"a\127b"'), "a\127b")
    same(json.encode("a\127b"), '"a\\u007fb"')
end)

check("decode keeps the last value of a repeated key", function()
    same(json.decode('{"a":1,"a":2}'), { a = 2 })
end)

check("decode rejects a number that overflows", function()
    local value, err = json.decode("[1e999]")
    same(value, nil)
    same(err, "number out of range at offset 2")
    same((json.decode("-1e999")), nil)
end)

check("encode refuses nesting deeper than 200", function()
    local deep = {}
    for _ = 1, 201 do
        deep = { deep }
    end
    local text, err = json.encode(deep)
    same(text, nil)
    same(err, "nesting too deep")
    local ok = {}
    for _ = 1, 199 do
        ok = { ok }
    end
    assert(json.encode(ok), "199 levels should encode")
end)

check("encode keeps invalid UTF-8 bytes", function()
    same(json.decode('"\255"'), "\255")
    same(json.encode("\255"), '"\255"')
end)

check("is_object is true for decoded and built objects, empty ones included", function()
    same(json.is_object(assert(json.decode('{"a":1}'))), true)
    same(json.is_object(assert(json.decode("{}"))), true)
    same(json.is_object(json.object()), true)
end)

check("is_object is false for arrays, null and non-tables", function()
    same(json.is_object(assert(json.decode("[1,2]"))), false)
    same(json.is_object(assert(json.decode("[]"))), false)
    same(json.is_object({}), false)
    same(json.is_object(json.null), false)
    same(json.is_object("x"), false)
    same(json.is_object(nil), false)
end)

check("present turns the null sentinel into nil and keeps other values", function()
    same(json.present(json.null), nil)
    same(json.present("x"), "x")
    same(json.present(false), false)
end)

if failures > 0 then
    print(failures .. " failed")
    dev_os.exit(1)
end
