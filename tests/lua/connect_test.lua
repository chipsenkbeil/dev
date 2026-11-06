local t = require("dev.testing")
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
    assert(fs.write(root .. "/ssh.ls.json", CONNECTABLES))
    executable(
        root .. "/bin/ci",
        '#!/bin/sh\necho "ci $*" >> "'
            .. root
            .. '/calls"\n'
            .. 'if [ "$1" = ssh ] && [ "$2" = config ]; then\n'
            .. '  [ ! -f "'
            .. root
            .. '/ssh.config.err" ] || cat "'
            .. root
            .. '/ssh.config.err" >&2\n'
            .. '  exit "$(cat "'
            .. root
            .. '/ssh.config.rc" 2>/dev/null || echo 0)"\n'
            .. "fi\n"
            .. 'if [ "$1" = ssh ] && [ "$2" = ls ]; then\n'
            .. '  [ ! -f "'
            .. root
            .. '/ssh.ls.err" ] || cat "'
            .. root
            .. '/ssh.ls.err" >&2\n'
            .. '  cat "'
            .. root
            .. '/ssh.ls.json"\n'
            .. '  exit "$(cat "'
            .. root
            .. '/ssh.ls.rc" 2>/dev/null || echo 0)"\n'
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

t.test("a named connectable writes the config, lists and execs ssh ci-NAME", function()
    local root = sandbox()
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    t.eq(code, 0)
    t.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-vm1\n")
    t.ok(out:find("dev connect: example-box is slow", 1, true), out)
    t.ok(out:find("skipping a connectable with an invalid name", 1, true), out)
    fs.remove(root, { recursive = true })
end)

t.test("a named box never asks ci ssh config", function()
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
            root .. "/ssh.ls.json",
            [[{"protocol":1,"things":[{"name":"ci-session-x","machine":"example-box","kind":"host","address":"10.0.0.9","user":"dev","state":"running"}],"notes":[]}]]
        )
    )
    local _, code = support.dev(root, { "connect", "ci-session-x" }, env())
    t.eq(code, 0)
    t.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-session-x\n")
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

t.test("a ci without ssh config lists boxes only, with one note", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.config.rc", "2\n"))
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    t.eq(code, 0)
    local note = "this ci has no ssh command, listing boxes only"
    local _, count = out:gsub(note, "")
    t.eq(count, 1)
    t.eq(
        calls(root),
        "ci box ls --json\nci ssh config\nci ssh b1 -- tmux new -A -s b1 -c /srv/projects\n"
    )
    fs.remove(root, { recursive = true })
end)

t.test("a ci with ssh config but no ssh ls lists boxes only, with one note", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.rc", "2\n"))
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    t.eq(code, 0)
    local _, count = out:gsub("this ci has no ssh command, listing boxes only", "")
    t.eq(count, 1)
    t.eq(
        calls(root),
        "ci box ls --json\nci ssh config\nci ssh ls --json\nci ssh b1 -- tmux new -A -s b1 -c /srv/projects\n"
    )
    fs.remove(root, { recursive = true })
end)

t.test("a failing ci ssh ls still lets the picker attach a box", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.err", "hub down\n"))
    assert(fs.write(root .. "/ssh.ls.rc", "1\n"))
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    t.eq(code, 0)
    t.ok(out:find("dev connect: hub down", 1, true), out)
    t.ok(calls(root):find("ci ssh b1", 1, true), calls(root))
    fs.remove(root, { recursive = true })
end)

t.test("another ci ssh ls failure prints ci's standard error and keeps its code", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.err", "hub down\n"))
    assert(fs.write(root .. "/ssh.ls.rc", "1\n"))
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    t.eq(code, 1)
    t.ok(out:find("dev connect: hub down", 1, true), out)
    t.eq(calls(root):find("ssh ci-", 1, true), nil)
    fs.remove(root, { recursive = true })
end)

t.test("a failing ci ssh config prints its standard error and never asks ci ssh ls", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.config.err", "hub down\n"))
    assert(fs.write(root .. "/ssh.config.rc", "1\n"))
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    t.eq(code, 1)
    t.ok(out:find("dev connect: hub down", 1, true), out)
    t.eq(calls(root), "ci box ls --json\nci ssh config\n")
    fs.remove(root, { recursive = true })
end)

t.test("a successful ci ssh ls parses its document and shows a note on standard error", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.err", "ci: refreshing the session list\n"))
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    t.eq(code, 0)
    t.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-vm1\n")
    t.ok(out:find("dev connect: example-box is slow", 1, true), out)
    t.ok(out:find("ci: refreshing the session list", 1, true), out)
    fs.remove(root, { recursive = true })
end)

t.test("a successful ci ssh config shows its warning on standard error", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.config.err", "warning: stale host key\n"))
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    t.eq(code, 0)
    t.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-vm1\n")
    t.ok(out:find("warning: stale host key", 1, true), out)
    fs.remove(root, { recursive = true })
end)

t.test("a temporary file that cannot be made still lets the picker list boxes", function()
    local root = sandbox()
    local out, code = support.dev(
        root,
        { "connect", "--ssh" },
        env({ FAKE_TTY = "1", FAKE_PICK = "b1", TMPDIR = root .. "/missing" })
    )
    t.eq(code, 0)
    t.ok(out:find("dev connect: cannot make a temporary path", 1, true), out)
    t.ok(calls(root):find("ci ssh b1", 1, true), calls(root))
    fs.remove(root, { recursive = true })
end)

t.test("a failing ci ssh config prints the error line after a warning", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.config.err", "warning: stale host key\nerror: cannot write\n"))
    assert(fs.write(root .. "/ssh.config.rc", "1\n"))
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    t.eq(code, 1)
    t.ok(out:find("dev connect: error: cannot write", 1, true), out)
    fs.remove(root, { recursive = true })
end)
