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
    -- Write the box listing and the connectables ci answers with
    local root = support.sandbox({}, {})
    assert(fs.write(root .. "/ls.json", LISTING))
    assert(fs.write(root .. "/ssh.ls.json", CONNECTABLES))

    -- Stand in for ci with a script that logs its call and answers from those files
    executable(
        root .. "/bin/ci",
        table.concat({
            "#!/bin/sh",
            'echo "ci $*" >> "' .. root .. '/calls"',
            'if [ "$1" = ssh ] && [ "$2" = config ]; then',
            '  [ ! -f "' .. root .. '/ssh.config.err" ] || cat "' .. root .. '/ssh.config.err" >&2',
            '  exit "$(cat "' .. root .. '/ssh.config.rc" 2>/dev/null || echo 0)"',
            "fi",
            'if [ "$1" = ssh ] && [ "$2" = ls ]; then',
            '  [ ! -f "' .. root .. '/ssh.ls.err" ] || cat "' .. root .. '/ssh.ls.err" >&2',
            '  cat "' .. root .. '/ssh.ls.json"',
            '  exit "$(cat "' .. root .. '/ssh.ls.rc" 2>/dev/null || echo 0)"',
            "fi",
            'cat "' .. root .. '/ls.json"',
            "",
        }, "\n")
    )

    -- Stand in for ssh with a script that logs its call
    executable(
        root .. "/bin/ssh",
        table.concat({
            "#!/bin/sh",
            'echo "ssh $*" >> "' .. root .. '/calls"',
            "",
        }, "\n")
    )
    return root
end

local function env(extra)
    -- Set the defaults of a session
    local set = {
        USER = "tester",
        NO_COLOR = "1",
        FAKE_DEV = "1",
    }

    -- Overlay the caller's values
    for name, value in pairs(extra or {}) do
        set[name] = value
    end

    -- Hand back the options
    return { env = set }
end

local function calls(root)
    return fs.read(root .. "/calls") or ""
end

testing.test("a named connectable writes the config, lists and execs ssh ci-NAME", function()
    -- Connect to a connectable by name
    local root = sandbox()
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    testing.eq(code, 0)

    -- Write the config, list and exec ssh
    testing.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-vm1\n")

    -- Relay ci's note and skip the invalid name
    testing.ok(out:find("Ci said: example-box is slow", 1, true), out)
    testing.ok(out:find("Skipping a connectable with an invalid name.", 1, true), out)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a named box never asks ci ssh config", function()
    -- Connect to a box by name
    local root = sandbox()
    local _, code = support.dev(root, { "connect", "b1", "--ssh" }, env())
    testing.eq(code, 0)

    -- Skip the ssh config call
    testing.eq(calls(root), "ci box ls --json\nci ssh b1 -- tmux new -A -s b1 -c /srv/projects\n")

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a connectable named ci-NAME execs ssh with that name as its own alias", function()
    -- Offer one connectable that already starts with ci-
    local root = sandbox()
    assert(
        fs.write(
            root .. "/ssh.ls.json",
            [[{"protocol":1,"things":[{"name":"ci-session-x","machine":"example-box","kind":"host","address":"10.0.0.9","user":"dev","state":"running"}],"notes":[]}]]
        )
    )

    -- Connect to it by name
    local _, code = support.dev(root, { "connect", "ci-session-x" }, env())
    testing.eq(code, 0)

    -- Exec ssh with the name as its own alias
    testing.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-session-x\n")

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

local SHADOWED =
    [[{"protocol":1,"things":[{"name":"foo","machine":"m","kind":"host","address":"10.0.0.1","user":"dev","state":"running"},{"name":"ci-foo","machine":"m","kind":"host","address":"10.0.0.2","user":"dev","state":"running"}],"notes":[]}]]

testing.test("a connectable whose alias names another is skipped by name", function()
    -- Offer two connectables whose aliases clash
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.json", SHADOWED))

    -- Connect to the one that loses its alias
    local out, code = support.dev(root, { "connect", "foo" }, env())
    testing.eq(code, 3)

    -- Say once why it was skipped
    local note = "Skipping foo, because its alias ci-foo is the name of another connectable."
    local first, last = out:find(note, 1, true)
    testing.ok(first, out)
    testing.eq(out:find(note, last + 1, true), nil)

    -- Exec no ssh
    testing.eq(calls(root):find("ssh ci-", 1, true), nil)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a connectable whose alias names another leaves the other one connecting", function()
    -- Offer two connectables whose aliases clash
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.json", SHADOWED))

    -- Connect to the one that keeps its name
    local _, code = support.dev(root, { "connect", "ci-foo" }, env())
    testing.eq(code, 0)

    -- Exec ssh for it
    testing.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-foo\n")

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a connectable whose alias names another is not offered by the picker", function()
    -- Offer two connectables whose aliases clash
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.json", SHADOWED))

    -- Open the picker
    local out, code = support.dev(
        root,
        { "connect", "--ssh" },
        env({ FAKE_TTY = "1", FAKE_PICK = "b1", PICK_LOG = root .. "/picks" })
    )
    testing.eq(code, 0)
    testing.ok(out:find("Skipping foo, because its alias ci-foo", 1, true), out)

    -- Offer the one that keeps its name and not the other
    local picks = fs.read(root .. "/picks") or ""
    testing.eq(picks:find("\nfoo\t", 1, true), nil)
    testing.ok(picks:find("\nci-foo\t", 1, true), picks)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a name that is neither a box nor a connectable exits 3", function()
    -- Connect to a name nothing has
    local root = sandbox()
    local out, code = support.dev(root, { "connect", "nope" }, env())

    -- Say no box has the name and exec no ssh
    testing.eq(code, 3)
    testing.ok(out:find("No box is named nope.", 1, true), out)
    testing.eq(calls(root):find("ssh ci-", 1, true), nil)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a ci without ssh config lists boxes only, with one note", function()
    -- Make ci refuse ssh config
    local root = sandbox()
    assert(fs.write(root .. "/ssh.config.rc", "2\n"))

    -- Open the picker
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    testing.eq(code, 0)

    -- Say once that only boxes are listed
    local note = "This ci has no ssh command, so only the boxes are listed."
    local _, count = out:gsub(note, "")
    testing.eq(count, 1)

    -- Attach the box without asking ssh ls
    testing.eq(
        calls(root),
        "ci box ls --json\nci ssh config\nci ssh b1 -- tmux new -A -s b1 -c /srv/projects\n"
    )

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("an older ci that reads config as a box name lists boxes only", function()
    -- Make ci read config as a box name
    local root = sandbox()
    assert(fs.write(root .. "/ssh.config.err", "error: no box config\n"))
    assert(fs.write(root .. "/ssh.config.rc", "1\n"))

    -- Open the picker
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    testing.eq(code, 0)

    -- Say once that only boxes are listed and hide ci's error
    local note = "This ci has no ssh command, so only the boxes are listed."
    local _, count = out:gsub(note, "")
    testing.eq(count, 1)
    testing.eq(out:find("no box config", 1, true), nil)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a ci with ssh config but no ssh ls lists boxes only, with one note", function()
    -- Make ci refuse ssh ls
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.rc", "2\n"))

    -- Open the picker
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    testing.eq(code, 0)

    -- Say once that only boxes are listed
    local _, count = out:gsub("This ci has no ssh command, so only the boxes are listed.", "")
    testing.eq(count, 1)

    -- Attach the box after asking both ssh calls
    testing.eq(
        calls(root),
        "ci box ls --json\nci ssh config\nci ssh ls --json\nci ssh b1 -- tmux new -A -s b1 -c /srv/projects\n"
    )

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a failing ci ssh ls still lets the picker attach a box", function()
    -- Make ci fail ssh ls with a message
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.err", "hub down\n"))
    assert(fs.write(root .. "/ssh.ls.rc", "1\n"))

    -- Open the picker
    local out, code =
        support.dev(root, { "connect", "--ssh" }, env({ FAKE_TTY = "1", FAKE_PICK = "b1" }))
    testing.eq(code, 0)

    -- Relay the message and attach the box
    testing.ok(out:find("Ci said: hub down", 1, true), out)
    testing.ok(calls(root):find("ci ssh b1", 1, true), calls(root))

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("another ci ssh ls failure prints ci's standard error and keeps its code", function()
    -- Make ci fail ssh ls with code 7
    local root = sandbox()
    assert(fs.write(root .. "/ssh.ls.err", "hub down\n"))
    assert(fs.write(root .. "/ssh.ls.rc", "7\n"))

    -- Connect to a connectable
    local out, code = support.dev(root, { "connect", "vm1" }, env())

    -- Keep ci's code, relay its message and exec no ssh
    testing.eq(code, 7)
    testing.ok(out:find("Ci said: hub down", 1, true), out)
    testing.eq(calls(root):find("ssh ci-", 1, true), nil)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test(
    "a failing ci ssh config prints its standard error and never asks ci ssh ls",
    function()
        -- Make ci fail ssh config with code 7
        local root = sandbox()
        assert(fs.write(root .. "/ssh.config.err", "hub down\n"))
        assert(fs.write(root .. "/ssh.config.rc", "7\n"))

        -- Connect to a connectable
        local out, code = support.dev(root, { "connect", "vm1" }, env())

        -- Keep ci's code, relay its message and stop before ssh ls
        testing.eq(code, 7)
        testing.ok(out:find("Ci said: hub down", 1, true), out)
        testing.eq(calls(root), "ci box ls --json\nci ssh config\n")

        -- Remove the project
        fs.remove(root, { recursive = true })
    end
)

testing.test(
    "a successful ci ssh ls parses its document and shows a note on standard error",
    function()
        -- Make ci note a refresh on standard error while succeeding
        local root = sandbox()
        assert(fs.write(root .. "/ssh.ls.err", "ci: refreshing the session list\n"))

        -- Connect to a connectable
        local out, code = support.dev(root, { "connect", "vm1" }, env())
        testing.eq(code, 0)
        testing.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-vm1\n")

        -- Show ci's note and the standard error
        testing.ok(out:find("Ci said: example-box is slow", 1, true), out)
        testing.ok(out:find("ci: refreshing the session list", 1, true), out)

        -- Remove the project
        fs.remove(root, { recursive = true })
    end
)

testing.test("a successful ci ssh config shows its warning on standard error", function()
    -- Make ci warn on standard error while succeeding
    local root = sandbox()
    assert(fs.write(root .. "/ssh.config.err", "warning: stale host key\n"))

    -- Connect to a connectable
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    testing.eq(code, 0)
    testing.eq(calls(root), "ci box ls --json\nci ssh config\nci ssh ls --json\nssh ci-vm1\n")

    -- Show the warning
    testing.ok(out:find("warning: stale host key", 1, true), out)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a temporary file that cannot be made still lets the picker list boxes", function()
    -- Open the picker with a temporary directory that does not exist
    local root = sandbox()
    local out, code = support.dev(
        root,
        { "connect", "--ssh" },
        env({ FAKE_TTY = "1", FAKE_PICK = "b1", TMPDIR = root .. "/missing" })
    )
    testing.eq(code, 0)

    -- Say what failed and attach the box
    testing.ok(
        out:find(
            "Cannot make a temporary path for the standard error of ci. Ci will write it to the terminal.",
            1,
            true
        ),
        out
    )
    testing.ok(calls(root):find("ci ssh b1", 1, true), calls(root))

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a failing ci ssh config prints the first of several error lines", function()
    -- Make ci fail ssh config with two error lines
    local root = sandbox()
    assert(
        fs.write(
            root .. "/ssh.config.err",
            table.concat({ "error: first", "error: second", "" }, "\n")
        )
    )
    assert(fs.write(root .. "/ssh.config.rc", "1\n"))

    -- Connect to a connectable
    local out, code = support.dev(root, { "connect", "vm1" }, env())
    testing.eq(code, 1)

    -- Print the first error line only
    testing.ok(out:find("Ci said: error: first", 1, true), out)
    testing.ok(not out:find("error: second", 1, true), out)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)

testing.test("a failing ci ssh config prints the error line after a warning", function()
    -- Make ci fail ssh config with a warning and then an error
    local root = sandbox()
    assert(
        fs.write(
            root .. "/ssh.config.err",
            table.concat({ "warning: stale host key", "error: cannot write", "" }, "\n")
        )
    )
    assert(fs.write(root .. "/ssh.config.rc", "1\n"))

    -- Connect to a connectable
    local out, code = support.dev(root, { "connect", "vm1" }, env())

    -- Print the error line, not the warning
    testing.eq(code, 1)
    testing.ok(out:find("Ci said: error: cannot write", 1, true), out)

    -- Remove the project
    fs.remove(root, { recursive = true })
end)
