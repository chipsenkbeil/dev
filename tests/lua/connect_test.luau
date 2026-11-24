local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local support = require("./support")

local LISTING =
    [[{"ok":true,"boxes":[{"name":"b1","state":"running","target":"linux-dev","machine":"example-box","shape":"medium","projects":[],"tailnet_name":"b1"}]}]]

local CONNECTABLES =
    [[{"protocol":1,"things":[{"name":"b1","machine":"example-box","kind":"box","address":"10.0.0.1","user":"dev","state":"running"},{"name":"s1","machine":"example-box","kind":"session","address":"10.0.0.2","user":"dev","state":"running"},{"name":"vm1","machine":"example-box","kind":"host","address":"10.0.0.9","user":"dev","state":"running"},{"name":"-oProxyCommand=x","machine":"m","kind":"host","address":"a","user":"u","state":"running"}],"notes":["example-box is slow"]}]]

local function executable(path, body)
    assert(fs.write(path, body))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
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
        FAKE_DEV = "1",
    }
    for name, value in pairs(extra or {}) do
        set[name] = value
    end
    return { env = set }
end

local function calls(root)
    return fs.read(root .. "/calls") or ""
end

testing.test("a named connectable writes the config, lists and execs ssh ci-NAME", function()
    local root = sandbox()
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    testing.eq(code, 0)
    testing.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-vm1\n")
    testing.ok(out:find("Ci said: example-box is slow", 1, true), out)
    testing.ok(out:find("Skipping a connectable with an invalid name.", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("a named box never asks ci ssh config", function()
    local root = sandbox()
    local _, code = support.dev(root, { "connect", "b1", "--ssh" }, env())
    testing.eq(code, 0)
    testing.eq(calls(root), "ci box ls --json\nci ssh b1 -- tmux new -A -s b1 -c /srv/projects\n")
    fs.remove(root, { recursive = true })
end)

testing.test("a connectable named ci-NAME execs ssh with that name as its own alias", function()
    local root = sandbox()
    assert(
        fs.write(
            root .. "/ssh.ls.json",
            [[{"protocol":1,"things":[{"name":"ci-session-x","machine":"example-box","kind":"host","address":"10.0.0.9","user":"dev","state":"running"}],"notes":[]}]]
        )
    )
    local _, code = support.dev(root, { "connect", "ci-session-x" }, env())
    testing.eq(code, 0)
    testing.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-session-x\n")
    fs.remove(root, { recursive = true })
end)

local SHADOWED =
    [[{"protocol":1,"things":[{"name":"foo","machine":"m","kind":"host","address":"10.0.0.1","user":"dev","state":"running"},{"name":"ci-foo","machine":"m","kind":"host","address":"10.0.0.2","user":"dev","state":"running"}],"notes":[]}]]

testing.test("a connectable whose alias names another is skipped by name", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.json", SHADOWED))
    local out, code = support.dev(root, { "connect", "foo" }, env())
    testing.eq(code, 3)
    local note = "Skipping foo, because its alias ci-foo is the name of another connectable."
    local first, last = out:find(note, 1, true)
    testing.ok(first, out)
    testing.eq(out:find(note, last + 1, true), nil)
    testing.eq(calls(root):find("ssh ci-", 1, true), nil)
    fs.remove(root, { recursive = true })
end)

testing.test("a connectable whose alias names another leaves the other one connecting", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.json", SHADOWED))
    local _, code = support.dev(root, { "connect", "ci-foo" }, env())
    testing.eq(code, 0)
    testing.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-foo\n")
    fs.remove(root, { recursive = true })
end)

testing.test("a connectable whose alias names another is not offered by the picker", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.json", SHADOWED))
    local out, code = support.dev(
        root,
        { "connect", "--ssh" },
        env({ FAKE_TTY = "1", FAKE_PICK = "b1", PICK_LOG = root .. "/picks" })
    )
    testing.eq(code, 0)
    testing.ok(out:find("Skipping foo, because its alias ci-foo", 1, true), out)
    local picks = fs.read(root .. "/picks") or ""
    testing.eq(picks:find("\nfoo\t", 1, true), nil)
    testing.ok(picks:find("\nci-foo\t", 1, true), picks)
    fs.remove(root, { recursive = true })
end)

testing.test("a name that is neither a box nor a connectable exits 3", function()
    local root = sandbox()
    local out, code = support.dev(root, { "connect", "nope" }, env())
    testing.eq(code, 3)
    testing.ok(out:find("No box is named nope.", 1, true), out)
    testing.eq(calls(root):find("ssh ci-", 1, true), nil)
    fs.remove(root, { recursive = true })
end)

testing.test("a ci without ssh config lists boxes only, with one note", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.config.rc", "2\n"))
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    testing.eq(code, 0)
    local note = "This ci has no ssh command, so only the boxes are listed."
    local _, count = out:gsub(note, "")
    testing.eq(count, 1)
    testing.eq(
        calls(root),
        "ci box ls --json\nci ssh config\nci ssh b1 -- tmux new -A -s b1 -c /srv/projects\n"
    )
    fs.remove(root, { recursive = true })
end)

testing.test("an older ci that reads config as a box name lists boxes only", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.config.err", "error: no box config\n"))
    assert(fs.write(root .. "/ssh.config.rc", "1\n"))
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    testing.eq(code, 0)
    local note = "This ci has no ssh command, so only the boxes are listed."
    local _, count = out:gsub(note, "")
    testing.eq(count, 1)
    testing.eq(out:find("no box config", 1, true), nil)
    fs.remove(root, { recursive = true })
end)

testing.test("a ci with ssh config but no ssh ls lists boxes only, with one note", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.rc", "2\n"))
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    testing.eq(code, 0)
    local _, count = out:gsub("This ci has no ssh command, so only the boxes are listed.", "")
    testing.eq(count, 1)
    testing.eq(
        calls(root),
        "ci box ls --json\nci ssh config\nci ssh ls --json\nci ssh b1 -- tmux new -A -s b1 -c /srv/projects\n"
    )
    fs.remove(root, { recursive = true })
end)

testing.test("a failing ci ssh ls still lets the picker attach a box", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.err", "hub down\n"))
    assert(fs.write(root .. "/ssh.ls.rc", "1\n"))
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    testing.eq(code, 0)
    testing.ok(out:find("Ci said: hub down", 1, true), out)
    testing.ok(calls(root):find("ci ssh b1", 1, true), calls(root))
    fs.remove(root, { recursive = true })
end)

testing.test("another ci ssh ls failure prints ci's standard error and keeps its code", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.err", "hub down\n"))
    assert(fs.write(root .. "/ssh.ls.rc", "7\n"))
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    testing.eq(code, 7)
    testing.ok(out:find("Ci said: hub down", 1, true), out)
    testing.eq(calls(root):find("ssh ci-", 1, true), nil)
    fs.remove(root, { recursive = true })
end)

testing.test(
    "a failing ci ssh config prints its standard error and never asks ci ssh ls",
    function()
        local root = sandbox()
        assert(fs.write(root .. "/ssh.config.err", "hub down\n"))
        assert(fs.write(root .. "/ssh.config.rc", "7\n"))
        local out, code = support.dev(root, { "connect", "vm1" }, env())
        testing.eq(code, 7)
        testing.ok(out:find("Ci said: hub down", 1, true), out)
        testing.eq(calls(root), "ci box ls --json\nci ssh config\n")
        fs.remove(root, { recursive = true })
    end
)

testing.test(
    "a successful ci ssh ls parses its document and shows a note on standard error",
    function()
        local root = sandbox()
        assert(fs.write(root .. "/ssh.ls.err", "ci: refreshing the session list\n"))
        local out, code = support.dev(root, { "connect", "vm1" }, env())
        testing.eq(code, 0)
        testing.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-vm1\n")
        testing.ok(out:find("Ci said: example-box is slow", 1, true), out)
        testing.ok(out:find("ci: refreshing the session list", 1, true), out)
        fs.remove(root, { recursive = true })
    end
)

testing.test("a successful ci ssh config shows its warning on standard error", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.config.err", "warning: stale host key\n"))
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    testing.eq(code, 0)
    testing.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-vm1\n")
    testing.ok(out:find("warning: stale host key", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("a temporary file that cannot be made still lets the picker list boxes", function()
    local root = sandbox()
    local out, code = support.dev(
        root,
        { "connect", "--ssh" },
        env({ FAKE_TTY = "1", FAKE_PICK = "b1", TMPDIR = root .. "/missing" })
    )
    testing.eq(code, 0)
    testing.ok(out:find("Cannot make a temporary path", 1, true), out)
    testing.ok(calls(root):find("ci ssh b1", 1, true), calls(root))
    fs.remove(root, { recursive = true })
end)

testing.test("a failing ci ssh config prints the first of several error lines", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.config.err", "error: first\nerror: second\n"))
    assert(fs.write(root .. "/ssh.config.rc", "1\n"))
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    testing.eq(code, 1)
    testing.ok(out:find("Ci said: error: first", 1, true), out)
    testing.ok(not out:find("error: second", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("a failing ci ssh config prints the error line after a warning", function()
    local root = sandbox()
    assert(fs.write(root .. "/ssh.config.err", "warning: stale host key\nerror: cannot write\n"))
    assert(fs.write(root .. "/ssh.config.rc", "1\n"))
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    testing.eq(code, 1)
    testing.ok(out:find("Ci said: error: cannot write", 1, true), out)
    fs.remove(root, { recursive = true })
end)
