local testing = require("dev.testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

testing.test("quote wraps in single quotes and escapes embedded ones", function()
    testing.eq(devos.quote("it's"), [['it'\''s']])
    testing.eq(devos.quote(""), "''")
end)

testing.test("quote refuses a NUL byte", function()
    testing.raises(function()
        devos.quote("a\0b")
    end, "NUL")
end)

testing.test("command joins the quoted words", function()
    testing.eq(devos.command({ "echo", "a b", "it's" }), [['echo' 'a b' 'it'\''s']])
end)

testing.test("capture passes hostile text through unchanged", function()
    local out, code = devos.capture({ "printf", "%s", "a b;$(id)'\"`" })
    testing.eq(out, "a b;$(id)'\"`")
    testing.eq(code, 0)
end)

testing.test("capture keeps trailing newlines", function()
    local out = devos.capture({ "printf", "a\n\n" })
    testing.eq(out, "a\n\n")
end)

testing.test("capture returns the exit code", function()
    testing.eq(select(2, devos.capture({ "sh", "-c", "exit 3" })), 3)
end)

testing.test("run returns the exit code", function()
    testing.eq(devos.run({ "sh", "-c", "exit 7" }), 7)
    testing.eq(devos.run({ "true" }), 0)
end)

testing.test("run reports a signal death as 128 plus the signal", function()
    testing.eq(devos.run({ "sh", "-c", "kill -TERM $$" }), 143)
end)

testing.test("which finds a tool or returns nil", function()
    local path = devos.which("sh")
    testing.ok(path and path:sub(1, 1) == "/", "sh should resolve to an absolute path")
    testing.eq(devos.which("no-such-tool-xyz"), nil)
end)

testing.test("getuid matches id -u", function()
    local out = devos.capture({ "id", "-u" })
    testing.eq(devos.getuid(), tonumber(out))
end)

testing.test("isatty is false for stdin from /dev/null", function()
    local snippet = ("package.path = %q; "):format(package.path)
        .. 'io.write(tostring(require("dev.os").isatty(0)))'
    local out = devos.capture({ "sh", "-c", [[luajit -e "$1" </dev/null]], "sh", snippet })
    testing.eq(out, "false")
end)

testing.test("exec returns nil and a message on failure", function()
    local res, err = devos.exec({ "no-such-tool-xyz" })
    testing.eq(res, nil)
    testing.ok(type(err) == "string" and err ~= "", "expected an error message")
end)

testing.test("run returns 127 for a missing tool", function()
    testing.eq(devos.run({ "no-such-tool-xyz" }), 127)
end)

testing.test("capture passes a newline and a leading dash through", function()
    local out = devos.capture({ "printf", "%s", "-x\ny" })
    testing.eq(out, "-x\ny")
end)

testing.test("run and capture flush Lua output before the child writes", function()
    local snippet = ("package.path = %q; local o = require('dev.os'); "):format(package.path)
        .. "io.write('a'); o.run({'printf', 'b'}); io.write('c'); "
        .. "local out = o.capture({'printf', 'd'}); io.write(out)"
    local out = devos.capture({ "sh", "-c", [[luajit -e "$1" | cat]], "sh", snippet })
    testing.eq(out, "abcd")
end)

testing.test("env passes hostile text to the child unchanged", function()
    local out = devos.capture({ "sh", "-c", [[printf %s "$X"]] }, { env = { X = "a b;$(id)" } })
    testing.eq(out, "a b;$(id)")
end)

testing.test("env refuses a name that is not a variable name", function()
    testing.raises(function()
        devos.run({ "true" }, { env = { ["A B"] = "x" } })
    end, "variable name")
end)

testing.test("defaults.env sits under opts.env", function()
    devos.defaults.env = { A = "default", B = "default" }
    local out = devos.capture({ "sh", "-c", [[printf %s-%s "$A" "$B"]] }, { env = { B = "own" } })
    devos.defaults.env = {}
    testing.eq(out, "default-own")
end)

testing.test("cwd runs the command in a directory with a quote and a space", function()
    local dir = support.tempdir() .. "/os test's"
    testing.eq(devos.run({ "mkdir", "--", dir }), 0)
    local out = devos.capture({ "sh", "-c", [[cd -P . && pwd -P]] }, { cwd = dir })
    local real = devos.capture({ "sh", "-c", [[cd -P "$1" && pwd -P]], "sh", dir })
    devos.run({ "rm", "-rf", "--", dir })
    testing.eq(out, real)
    testing.ok(out:find("os test's", 1, true), "the directory should be the one asked for")
end)

testing.test("stdin null gives the child an empty input", function()
    local out = devos.capture({ "sh", "-c", [[cat; printf end]] }, { stdin = "null" })
    testing.eq(out, "end")
end)

testing.test("stdin refuses any other value", function()
    testing.raises(function()
        devos.run({ "true" }, { stdin = "tty" })
    end, "stdin")
end)

testing.test("stderr stdout merges the streams into capture", function()
    local out = devos.capture({ "sh", "-c", "echo out; echo err >&2" }, { stderr = "stdout" })
    testing.eq(out, "out\nerr\n")
end)

testing.test("stdout and stderr null drop the streams", function()
    local out = devos.capture(
        { "sh", "-c", "echo out; echo err >&2" },
        { stdout = "null", stderr = "null" }
    )
    testing.eq(out, "")
end)

testing.test("stdout and stderr append to a file", function()
    local file = assert(require("dev.fs").mktemp({ prefix = "os-log" }))
    devos.run({ "sh", "-c", "echo out; echo err >&2" }, { stdout = file, stderr = file })
    devos.run({ "sh", "-c", "echo more" }, { stdout = file })
    local text = io.open(file):read("*a")
    devos.run({ "rm", "-f", "--", file })
    testing.eq(text, "out\nerr\nmore\n")
end)

testing.test("show writes the quoted command to stderr first", function()
    local snippet = ("package.path = %q; local o = require('dev.os'); "):format(package.path)
        .. "o.defaults.show = true; o.run({'printf', '%s', 'x'}); o.capture({'true'})"
    local out = devos.capture({ "sh", "-c", [[luajit -e "$1" 2>&1]], "sh", snippet })
    testing.eq(out, "+ 'printf' '%s' 'x'\nx+ 'true'\n")
end)

testing.test("exec honours env, cwd and stdin null", function()
    local snippet = ("package.path = %q; "):format(package.path)
        .. [[require('dev.os').exec({'sh', '-c', 'printf "%s|%s|" "$X" "$(pwd -P)"; cat'}, ]]
        .. [[{env = {X = 'a b'}, cwd = '/', stdin = 'null'})]]
    local out = devos.capture({ "sh", "-c", [[luajit -e "$1"]], "sh", snippet })
    testing.eq(out, "a b|/|")
end)

testing.test("exec appends output to a file", function()
    local file = assert(require("dev.fs").mktemp({ prefix = "os-log" }))
    local snippet = ("package.path = %q; "):format(package.path)
        .. ("require('dev.os').exec({'printf', 'hi'}, {stdout = %q})"):format(file)
    devos.run({ "luajit", "-e", snippet })
    local text = io.open(file):read("*a")
    devos.run({ "rm", "-f", "--", file })
    testing.eq(text, "hi")
end)

testing.test("name is Darwin, Linux or Windows", function()
    local name = devos.name()
    testing.ok(name == "Darwin" or name == "Linux" or name == "Windows", "unexpected name " .. name)
end)

testing.test("fake_env fakes the uid and the OS from the environment", function()
    local root = arg[0]:match("^(.*)/tests/lua/") or "."
    local FAKE_ENV = root .. "/tests/lua/fake_env.lua"
    local out = devos.capture(
        { "luajit", "-e", 'io.write(require("dev.os").getuid(), require("dev.os").name())' },
        {
            env = {
                LUA_INIT = "@" .. FAKE_ENV,
                FAKE_UID = "0",
                FAKE_OS = "Linux",
            },
        }
    )
    testing.eq(out, "0Linux")
end)

local function child(snippet, opts)
    local code = ("package.path = %q; local o = require('dev.os'); "):format(
        support.absolute_path()
    ) .. snippet
    return devos.capture({ "luajit", "-e", code }, opts)
end

testing.test("cwd may start with a dash, and a lone dash is a directory name", function()
    local dir = support.tempdir()
    testing.eq(devos.run({ "mkdir", "--", dir .. "/-x", dir .. "/-" }), 0)
    local out = child(
        "io.write((o.capture({'basename', '.'}, {cwd = '-x'})), (o.capture({'sh', '-c', 'basename \"$(pwd)\"'}, {cwd = '-'})))",
        { cwd = dir }
    )
    testing.eq(out, ".\n-\n")
    out = child("o.exec({'sh','-c','basename \"$(pwd)\"'}, {cwd = '-x'})", { cwd = dir })
    testing.eq(out, "-x\n")
    devos.run({ "rm", "-rf", "--", dir })
end)

testing.test("a command word that looks like an env option or assignment is safe", function()
    local out, code = devos.capture({ "-i" }, { env = { X = "1" }, stderr = "null" })
    testing.eq(out, "")
    testing.eq(code, 127)
    local _, assignment = devos.capture({ "A=b" }, { env = { X = "1" }, stderr = "null" })
    testing.eq(assignment, 127)
end)

testing.test("a command path with = in it runs through env, exec included", function()
    local dir = assert(fs.mktemp({ dir = true }))
    local script = dir .. "/a=b"
    assert(fs.write(script, "#!/bin/sh\nprintf '%s' \"$X\"\n"))
    assert(devos.run({ "chmod", "755", script }) == 0, "chmod failed")
    testing.eq(devos.capture({ script }, { env = { X = "1" } }), "1")
    testing.eq(child(("o.exec({ %q }, { env = { X = '2' } })"):format(script)), "2")
    fs.remove(dir, { recursive = true })
end)

testing.test("a bad env name reports the variable-name error from run, capture and exec", function()
    for _, call in ipairs({ devos.run, devos.capture, devos.exec }) do
        local ok, err = pcall(function()
            call({ "true" }, { env = { ["A B"] = "x" } })
        end)
        testing.ok(
            not ok and err:find("variable name", 1, true) and err:find("os_test.lua", 1, true),
            tostring(err)
        )
    end
    testing.raises(function()
        devos.run({ "true" }, { env = { [1] = "a" } })
    end, "variable name")
end)

testing.test("a relative stdout path resolves against the caller, not cwd", function()
    local dir = support.tempdir()
    testing.eq(devos.run({ "mkdir", "--", dir .. "/sub" }), 0)
    child("o.run({'echo', 'hi'}, {cwd = 'sub', stdout = 'out.txt'})", { cwd = dir })
    testing.eq(io.open(dir .. "/out.txt"):read("*a"), "hi\n")
    testing.ok(not io.open(dir .. "/sub/out.txt"), "the file must not land in cwd")
    child("o.exec({'echo', 'yo'}, {cwd = 'sub', stdout = 'out2.txt'})", { cwd = dir })
    testing.eq(io.open(dir .. "/out2.txt"):read("*a"), "yo\n")
    devos.run({ "rm", "-rf", "--", dir })
end)

testing.test("a stdout path with spaces and quotes is appended to", function()
    local dir = support.tempdir()
    local file = dir .. "/it's a log"
    devos.run({ "echo", "a" }, { stdout = file })
    devos.run({ "echo", "b" }, { stdout = file })
    testing.eq(io.open(file):read("*a"), "a\nb\n")
    devos.run({ "rm", "-rf", "--", dir })
end)

testing.test("exec merges stderr into stdout", function()
    local out = child("o.exec({'sh', '-c', 'echo out; echo err >&2'}, {stderr = 'stdout'})")
    testing.eq(out, "out\nerr\n")
end)

testing.test("unset removes a variable from the child, over the defaults too", function()
    local probe = { "sh", "-c", 'printf %s "${A-unset}${B-unset}"' }
    testing.eq(devos.capture(probe, { env = { A = "a", B = "b" }, unset = { "A" } }), "unsetb")
    devos.defaults.unset = { "B" }
    local out = devos.capture(probe, { env = { A = "a" } })
    devos.defaults.unset = {}
    testing.eq(out, "aunset")
end)

testing.test(
    "open_nofollow, fstat and read_fd read a regular file through one descriptor",
    function()
        local dir = support.tempdir()
        assert(fs.write(dir .. "/f", "hello world"))
        local fd = assert(devos.open_nofollow(dir .. "/f"))
        local stat = assert(devos.fstat(fd))
        testing.eq(stat.kind, "file")
        testing.eq(stat.size, 11)
        testing.eq(stat.uid, tonumber((devos.capture({ "id", "-u" }))))
        testing.eq(devos.read_fd(fd, 5), "hello")
        testing.eq(devos.read_fd(fd, 100), " world")
        devos.close(fd)
        fs.remove(dir, { recursive = true })
    end
)

testing.test("open_nofollow refuses a symbolic link and a missing file", function()
    local dir = support.tempdir()
    assert(fs.write(dir .. "/real", "x"))
    assert(fs.symlink(dir .. "/real", dir .. "/link"))
    local fd, message = devos.open_nofollow(dir .. "/link")
    testing.eq(fd, nil)
    testing.ok(type(message) == "string" and message ~= "", "expected a message")
    testing.eq((devos.open_nofollow(dir .. "/missing")), nil)
    fs.remove(dir, { recursive = true })
end)

testing.test("fstat names a directory and a FIFO, and opening a FIFO does not block", function()
    local dir = support.tempdir()
    assert(fs.mkdir(dir .. "/d"))
    assert(devos.run({ "mkfifo", dir .. "/p" }) == 0, "mkfifo failed")
    local fd = assert(devos.open_nofollow(dir .. "/d"))
    testing.eq(devos.fstat(fd).kind, "dir")
    devos.close(fd)
    fd = assert(devos.open_nofollow(dir .. "/p"))
    testing.eq(devos.fstat(fd).kind, "other")
    devos.close(fd)
    fs.remove(dir, { recursive = true })
end)

testing.test("open_nofollow refuses a path with a NUL byte", function()
    testing.eq((devos.open_nofollow("/tmp/a\0b")), nil)
end)

testing.test("capture_timed collects output and the exit code with no stdin", function()
    local out, code = devos.capture_timed({ "sh", "-c", "cat; echo out; exit 3" }, 10)
    testing.eq(out, "out\n")
    testing.eq(code, 3)
    out = devos.capture_timed({ "sh", "-c", "echo out; echo err >&2" }, 10, { merge = true })
    testing.eq(out, "out\nerr\n")
end)

testing.test("capture_timed hands the input to the command", function()
    local out, code = devos.capture_timed({ "cat" }, 10, { input = "a b\n" })
    testing.eq(out, "a b\n")
    testing.eq(code, 0)
end)

testing.test("capture_timed passes hostile words through unchanged", function()
    local out = devos.capture_timed({ "printf", "%s", "a b;$(id)'\"`" }, 10)
    testing.eq(out, "a b;$(id)'\"`")
end)

testing.test("capture_timed stops a command and its children after the limit", function()
    local started = os.time()
    local pid = devos.capture({ "sh", "-c", "echo $$" }):match("%d+")
    local unique_secs = 1000000 + 2 * tonumber(pid)
    local first, second = unique_secs, unique_secs + 1
    local out, code = devos.capture_timed({
        "sh",
        "-c",
        ("echo before; sleep %d >/dev/null 2>&1 & sleep %d >/dev/null 2>&1; wait"):format(
            first,
            second
        ),
    }, 1, { merge = true })
    testing.eq(code, 124)
    testing.eq(out, "before\n")
    testing.ok(os.time() - started < 30, "the limit should not take long")
    local left = devos.capture({
        "pgrep",
        "-f",
        ("^sleep (%d|%d)$"):format(first, second),
    }, { stderr = "null" })
    testing.eq(left, "")
end)

testing.test("capture_timed with reap kills what a finished command left running", function()
    local out, code = devos.capture_timed(
        { "sh", "-c", "sleep 3781 & echo done" },
        10,
        { merge = true, reap = true }
    )
    testing.eq(code, 0)
    testing.eq(out, "done\n")
    local left = devos.capture({ "pgrep", "-f", "sleep 378[1]" }, { stderr = "null" })
    testing.eq(left, "")
end)

testing.test("capture_timed reports a command killed by a signal as 124", function()
    local _, code = devos.capture_timed({ "sh", "-c", "exec kill -TERM $$" }, 10)
    testing.eq(code, 124)
end)

testing.test("without_sigpipe turns a write to a closed pipe into a failed write", function()
    local pipe = assert(io.popen("true", "w"))
    devos.run({ "sleep", "0.3" })
    local ok = devos.without_sigpipe(function()
        local wrote = pipe:write(string.rep("x", 1048576))
        local flushed = pipe:flush()
        return wrote ~= nil and flushed ~= nil
    end)
    pipe:close()
    testing.eq(ok, false)
end)

testing.test("capture_timed cleans up when its process is terminated", function()
    local tmp = assert(fs.mktemp({ dir = true }))
    local snippet = ("package.path = %q; "):format(package.path)
        .. 'require("dev.os").capture_timed({ "sh", "-c", "sleep 3773 & sleep 3774; wait" }, 600)'
    local pid = devos.capture({
        "sh",
        "-c",
        [[TMPDIR="$2" luajit -e "$1" </dev/null >/dev/null 2>&1 & echo $!]],
        "sh",
        snippet,
        tmp,
    })
    pid = pid:gsub("%s+$", "")
    local function sleeping()
        local out = devos.capture({ "sh", "-c", "ps -axo args=" })
        return ("\n" .. out):find("\nsleep 3773\n", 1, true) ~= nil
    end
    local function stray()
        return devos.capture({ "sh", "-c", "ps -axo args= | grep -x 'sleep 377[34]' || true" })
    end
    for _ = 1, 50 do
        if sleeping() then
            break
        end
        devos.run({ "sleep", "0.1" })
    end
    testing.ok(sleeping(), "the command should be running")
    devos.run({ "kill", "-TERM", pid })
    for _ = 1, 50 do
        if not sleeping() then
            break
        end
        devos.run({ "sleep", "0.1" })
    end
    local left = stray()
    local dirs = devos.capture({ "ls", tmp })
    fs.remove(tmp, { recursive = true })
    testing.eq(left, "")
    testing.eq(dirs, "")
end)

local function launch_capture_timed(command, tmp)
    local snippet = ("package.path = %q; "):format(package.path)
        .. ("require('dev.os').capture_timed({ 'sh', '-c', %q }, 600)"):format(command)
    local pid = devos.capture({
        "sh",
        "-c",
        [[TMPDIR="$2" luajit -e "$1" </dev/null >/dev/null 2>&1 & echo $!]],
        "sh",
        snippet,
        tmp,
    })
    return (pid:gsub("%s+$", ""))
end

local function process_listed(needle)
    local out = devos.capture({ "sh", "-c", "ps -axo args=" })
    return ("\n" .. out):find("\n" .. needle .. "\n", 1, true) ~= nil
end

local WAIT_POLL_SECS = "0.1"

local function wait_until(predicate)
    local WAIT_POLLS = 50
    for _ = 1, WAIT_POLLS do
        if predicate() then
            return true
        end
        devos.run({ "sleep", WAIT_POLL_SECS })
    end
    return predicate()
end

testing.test("capture_timed cleans up when its process is killed", function()
    local tmp = assert(fs.mktemp({ dir = true }))
    local pid = launch_capture_timed("sleep 3777 & sleep 3778; wait", tmp)
    testing.ok(
        wait_until(function()
            return process_listed("sleep 3777")
        end),
        "the command should be running"
    )
    devos.run({ "kill", "-KILL", pid })
    local gone = wait_until(function()
        return not process_listed("sleep 3777") and not process_listed("sleep 3778")
    end)
    local removed = wait_until(function()
        return devos.capture({ "ls", tmp }) == ""
    end)
    fs.remove(tmp, { recursive = true })
    testing.ok(gone, "the command and its children should be killed")
    testing.ok(removed, "the temporary directory should be removed")
end)

local function children_of(marker)
    local out = devos.capture({ "sh", "-c", "ps -axo pid=,ppid=,args=" })
    local owners, found = {}, {}
    local rows = {}
    for pid, ppid, args in out:gmatch("(%d+)%s+(%d+)%s+([^\n]*)") do
        rows[#rows + 1] = { pid = pid, ppid = ppid, args = args }
        if args:find("^sh %-c") and args:find(marker, 1, true) then
            owners[pid] = true
        end
    end
    for _, row in ipairs(rows) do
        if
            owners[row.ppid]
            and not row.args:find(marker, 1, true)
            and not row.args:find("^mv ")
        then
            found[#found + 1] = row.args
        end
    end
    return found
end

testing.test("capture_timed starts no process while its command runs", function()
    local tmp = assert(fs.mktemp({ dir = true }))
    local pid = launch_capture_timed("sleep 3779", tmp)
    testing.ok(
        wait_until(function()
            return process_listed("sleep 3779")
        end),
        "the command should be running"
    )
    local WATCH_POLLS = 15
    local polled = false
    for _ = 1, WATCH_POLLS do
        if #children_of("sleep 3779") > 0 then
            polled = true
        end
        devos.run({ "sleep", WAIT_POLL_SECS })
    end
    devos.run({ "kill", "-KILL", pid }, { stderr = "null" })
    wait_until(function()
        return not process_listed("sleep 3779")
    end)
    fs.remove(tmp, { recursive = true })
    testing.eq(polled, false)
end)

testing.test("capture_timed with no seconds sets no limit and runs to completion", function()
    local started = os.time()
    local out, code = devos.capture_timed({ "sh", "-c", "sleep 2; echo done" }, 0)
    testing.eq(out, "done\n")
    testing.eq(code, 0)
    testing.ok(os.time() - started >= 2, "the command should have been waited for")
end)
