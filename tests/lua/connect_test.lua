local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")

local LISTING =
    [[{"ok":true,"boxes":[{"name":"b1","state":"running","target":"linux-dev","machine":"example-box","shape":"medium","projects":[],"tailnet_name":"b1"}]}]]

local CONNECTABLES =
    [[{"protocol":1,"things":[{"name":"b1","machine":"example-box","kind":"box","address":"10.0.0.1","user":"dev","state":"running"},{"name":"s1","machine":"example-box","kind":"session","address":"10.0.0.2","user":"dev","state":"running"},{"name":"vm1","machine":"example-box","kind":"host","address":"10.0.0.9","user":"dev","state":"running"},{"name":"-oProxyCommand=x","machine":"m","kind":"host","address":"a","user":"u","state":"running"}],"notes":["example-box is slow"]}]]

local function executable(path, body)
    assert(fs.write(path, body))
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function sandbox()
    local root = support.sandbox({}, {})
    assert(fs.write(root .. "/ls.json", LISTING))
    assert(fs.write(root .. "/connect.json", CONNECTABLES))
    executable(
        root .. "/bin/ci",
        '#!/bin/sh\necho "ci $*" >> "'
            .. root
            .. '/calls"\n'
            .. 'if [ "$1" = connect ] && [ "$2" = sync ]; then exit "$(cat "'
            .. root
            .. '/sync.rc" 2>/dev/null || echo 0)"; fi\n'
            .. 'if [ "$1" = ssh ] && [ "$2" = ls ]; then\n'
            .. '  cat "'
            .. root
            .. '/connect.json"\n'
            .. '  exit "$(cat "'
            .. root
            .. '/connect.rc" 2>/dev/null || echo 0)"\n'
            .. "fi\n"
            .. 'cat "'
            .. root
            .. '/ls.json"\n'
    )
    executable(root .. "/bin/ssh", '#!/bin/sh\necho "ssh $*" >> "' .. root .. '/calls"\n')
    return root
end

local function env(extra)
    local set = {
        USER = "tester",
        NO_COLOR = "1",
        LUA_INIT = "@" .. REPO .. "/tests/lua/fake_env.lua",
    }
    for name, value in pairs(extra or {}) do
        set[name] = value
    end
    return { env = set }
end

local function calls(root)
    return fs.read(root .. "/calls") or ""
end

t.test("a named connectable syncs, lists and execs ssh ci-NAME", function()
    local root = sandbox()
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    t.eq(code, 0)
    t.eq(calls(root), "ci box ls --json\nci connect sync\nci ssh ls --json\nssh ci-vm1\n")
    t.ok(out:find("dev connect: example-box is slow", 1, true), out)
    t.ok(out:find("skipping a connectable with an invalid name", 1, true), out)
    fs.remove(root, { recursive = true })
end)

t.test("a named box never asks ci connect", function()
    local root = sandbox()
    local _, code = support.dev(root, { "connect", "b1", "--ssh" }, env())
    t.eq(code, 0)
    t.eq(calls(root), "ci box ls --json\nci ssh b1 -- tmux new -A -s b1 -c /srv/projects\n")
    fs.remove(root, { recursive = true })
end)

t.test("a connectable named ci-NAME execs ssh with that name as its own alias", function()
    local root = sandbox()
    assert(
        fs.write(
            root .. "/connect.json",
            [[{"protocol":1,"things":[{"name":"ci-session-x","machine":"example-box","kind":"host","address":"10.0.0.9","user":"dev","state":"running"}],"notes":[]}]]
        )
    )
    local _, code = support.dev(root, { "connect", "ci-session-x" }, env())
    t.eq(code, 0)
    t.eq(calls(root), "ci box ls --json\nci connect sync\nci ssh ls --json\nssh ci-session-x\n")
    fs.remove(root, { recursive = true })
end)

t.test("a name that is neither a box nor a connectable exits 3", function()
    local root = sandbox()
    local out, code = support.dev(root, { "connect", "nope" }, env())
    t.eq(code, 3)
    t.ok(out:find("no box named nope", 1, true), out)
    t.eq(calls(root):find("ssh ci-", 1, true), nil)
    fs.remove(root, { recursive = true })
end)

t.test("a ci without connect lists boxes only, with one note", function()
    local root = sandbox()
    assert(fs.write(root .. "/sync.rc", "2\n"))
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    t.eq(code, 0)
    local note = "this ci has no ssh command, listing boxes only"
    local _, count = out:gsub(note, "")
    t.eq(count, 1)
    t.eq(
        calls(root),
        "ci box ls --json\nci connect sync\nci ssh b1 -- tmux new -A -s b1 -c /srv/projects\n"
    )
    fs.remove(root, { recursive = true })
end)

t.test("a ci with connect but no ssh lists boxes only, with one note", function()
    local root = sandbox()
    assert(fs.write(root .. "/connect.rc", "2\n"))
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    t.eq(code, 0)
    local _, count = out:gsub("this ci has no ssh command, listing boxes only", "")
    t.eq(count, 1)
    t.eq(
        calls(root),
        "ci box ls --json\nci connect sync\nci ssh ls --json\nci ssh b1 -- tmux new -A -s b1 -c /srv/projects\n"
    )
    fs.remove(root, { recursive = true })
end)

t.test("a failing ci connect still lets the picker attach a box", function()
    local root = sandbox()
    assert(fs.write(root .. "/connect.json", "hub down"))
    assert(fs.write(root .. "/connect.rc", "7\n"))
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    t.eq(code, 0)
    t.ok(out:find("dev connect: hub down", 1, true), out)
    t.ok(calls(root):find("ci ssh b1", 1, true), calls(root))
    fs.remove(root, { recursive = true })
end)

t.test("another ci connect failure prints ci's message and keeps its code", function()
    local root = sandbox()
    assert(fs.write(root .. "/connect.json", "hub down"))
    assert(fs.write(root .. "/connect.rc", "7\n"))
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    t.eq(code, 7)
    t.ok(out:find("dev connect: hub down", 1, true), out)
    t.eq(calls(root):find("ssh ci-", 1, true), nil)
    fs.remove(root, { recursive = true })
end)
