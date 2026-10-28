local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

t.test("quote wraps in single quotes and escapes embedded ones", function()
    t.eq(devos.quote("it's"), [['it'\''s']])
    t.eq(devos.quote(""), "''")
end)

t.test("quote refuses a NUL byte", function()
    t.raises(function()
        devos.quote("a\0b")
    end, "NUL")
end)

t.test("command joins the quoted words", function()
    t.eq(devos.command({ "echo", "a b", "it's" }), [['echo' 'a b' 'it'\''s']])
end)

t.test("capture passes hostile text through unchanged", function()
    local out, code = devos.capture({ "printf", "%s", "a b;$(id)'\"`" })
    t.eq(out, "a b;$(id)'\"`")
    t.eq(code, 0)
end)

t.test("capture keeps trailing newlines", function()
    local out = devos.capture({ "printf", "a\n\n" })
    t.eq(out, "a\n\n")
end)

t.test("capture returns the exit code", function()
    t.eq(select(2, devos.capture({ "sh", "-c", "exit 3" })), 3)
end)

t.test("run returns the exit code", function()
    t.eq(devos.run({ "sh", "-c", "exit 7" }), 7)
    t.eq(devos.run({ "true" }), 0)
end)

t.test("run reports a signal death as 128 plus the signal", function()
    t.eq(devos.run({ "sh", "-c", "kill -TERM $$" }), 143)
end)

t.test("which finds a tool or returns nil", function()
    local path = devos.which("sh")
    t.ok(path and path:sub(1, 1) == "/", "sh should resolve to an absolute path")
    t.eq(devos.which("no-such-tool-xyz"), nil)
end)

t.test("getuid matches id -u", function()
    local out = devos.capture({ "id", "-u" })
    t.eq(devos.getuid(), tonumber(out))
end)

t.test("isatty is false for stdin from /dev/null", function()
    local snippet = ("package.path = %q; "):format(package.path)
        .. 'io.write(tostring(require("dev.os").isatty(0)))'
    local out = devos.capture({ "sh", "-c", [[luajit -e "$1" </dev/null]], "sh", snippet })
    t.eq(out, "false")
end)

t.test("exec returns nil and a message on failure", function()
    local res, err = devos.exec({ "no-such-tool-xyz" })
    t.eq(res, nil)
    t.ok(type(err) == "string" and err ~= "", "expected an error message")
end)

t.test("run returns 127 for a missing tool", function()
    t.eq(devos.run({ "no-such-tool-xyz" }), 127)
end)

t.test("capture passes a newline and a leading dash through", function()
    local out = devos.capture({ "printf", "%s", "-x\ny" })
    t.eq(out, "-x\ny")
end)

t.test("run and capture flush Lua output before the child writes", function()
    local snippet = ("package.path = %q; local o = require('dev.os'); "):format(package.path)
        .. "io.write('a'); o.run({'printf', 'b'}); io.write('c'); "
        .. "local out = o.capture({'printf', 'd'}); io.write(out)"
    local out = devos.capture({ "sh", "-c", [[luajit -e "$1" | cat]], "sh", snippet })
    t.eq(out, "abcd")
end)

t.test("env passes hostile text to the child unchanged", function()
    local out = devos.capture({ "sh", "-c", [[printf %s "$X"]] }, { env = { X = "a b;$(id)" } })
    t.eq(out, "a b;$(id)")
end)

t.test("env refuses a name that is not a variable name", function()
    t.raises(function()
        devos.run({ "true" }, { env = { ["A B"] = "x" } })
    end, "variable name")
end)

t.test("defaults.env sits under opts.env", function()
    devos.defaults.env = { A = "default", B = "default" }
    local out = devos.capture({ "sh", "-c", [[printf %s-%s "$A" "$B"]] }, { env = { B = "own" } })
    devos.defaults.env = {}
    t.eq(out, "default-own")
end)

t.test("cwd runs the command in a directory with a quote and a space", function()
    local dir = support.tempdir() .. "/os test's"
    t.eq(devos.run({ "mkdir", "--", dir }), 0)
    local out = devos.capture({ "sh", "-c", [[cd -P . && pwd -P]] }, { cwd = dir })
    local real = devos.capture({ "sh", "-c", [[cd -P "$1" && pwd -P]], "sh", dir })
    devos.run({ "rm", "-rf", "--", dir })
    t.eq(out, real)
    t.ok(out:find("os test's", 1, true), "the directory should be the one asked for")
end)

t.test("stdin null gives the child an empty input", function()
    local out = devos.capture({ "sh", "-c", [[cat; printf end]] }, { stdin = "null" })
    t.eq(out, "end")
end)

t.test("stdin refuses any other value", function()
    t.raises(function()
        devos.run({ "true" }, { stdin = "tty" })
    end, "stdin")
end)

t.test("stderr stdout merges the streams into capture", function()
    local out = devos.capture({ "sh", "-c", "echo out; echo err >&2" }, { stderr = "stdout" })
    t.eq(out, "out\nerr\n")
end)

t.test("stdout and stderr null drop the streams", function()
    local out = devos.capture(
        { "sh", "-c", "echo out; echo err >&2" },
        { stdout = "null", stderr = "null" }
    )
    t.eq(out, "")
end)

t.test("stdout and stderr append to a file", function()
    local file = assert(require("dev.fs").mktemp({ prefix = "os-log" }))
    devos.run({ "sh", "-c", "echo out; echo err >&2" }, { stdout = file, stderr = file })
    devos.run({ "sh", "-c", "echo more" }, { stdout = file })
    local text = io.open(file):read("*a")
    devos.run({ "rm", "-f", "--", file })
    t.eq(text, "out\nerr\nmore\n")
end)

t.test("show writes the quoted command to stderr first", function()
    local snippet = ("package.path = %q; local o = require('dev.os'); "):format(package.path)
        .. "o.defaults.show = true; o.run({'printf', '%s', 'x'}); o.capture({'true'})"
    local out = devos.capture({ "sh", "-c", [[luajit -e "$1" 2>&1]], "sh", snippet })
    t.eq(out, "+ 'printf' '%s' 'x'\nx+ 'true'\n")
end)

t.test("exec honours env, cwd and stdin null", function()
    local snippet = ("package.path = %q; "):format(package.path)
        .. [[require('dev.os').exec({'sh', '-c', 'printf "%s|%s|" "$X" "$(pwd -P)"; cat'}, ]]
        .. [[{env = {X = 'a b'}, cwd = '/', stdin = 'null'})]]
    local out = devos.capture({ "sh", "-c", [[luajit -e "$1"]], "sh", snippet })
    t.eq(out, "a b|/|")
end)

t.test("exec appends output to a file", function()
    local file = assert(require("dev.fs").mktemp({ prefix = "os-log" }))
    local snippet = ("package.path = %q; "):format(package.path)
        .. ("require('dev.os').exec({'printf', 'hi'}, {stdout = %q})"):format(file)
    devos.run({ "luajit", "-e", snippet })
    local text = io.open(file):read("*a")
    devos.run({ "rm", "-f", "--", file })
    t.eq(text, "hi")
end)

t.test("name is Darwin, Linux or Windows", function()
    local name = devos.name()
    t.ok(name == "Darwin" or name == "Linux" or name == "Windows", "unexpected name " .. name)
end)

t.test("fake_env fakes the uid and the OS from the environment", function()
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
    t.eq(out, "0Linux")
end)

local function child(snippet, opts)
    local code = ("package.path = %q; local o = require('dev.os'); "):format(
        support.absolute_path()
    ) .. snippet
    return devos.capture({ "luajit", "-e", code }, opts)
end

t.test("cwd may start with a dash, and a lone dash is a directory name", function()
    local dir = support.tempdir()
    t.eq(devos.run({ "mkdir", "--", dir .. "/-x", dir .. "/-" }), 0)
    local out = child(
        "io.write((o.capture({'basename', '.'}, {cwd = '-x'})), (o.capture({'sh', '-c', 'basename \"$(pwd)\"'}, {cwd = '-'})))",
        { cwd = dir }
    )
    t.eq(out, ".\n-\n")
    out = child("o.exec({'sh','-c','basename \"$(pwd)\"'}, {cwd = '-x'})", { cwd = dir })
    t.eq(out, "-x\n")
    devos.run({ "rm", "-rf", "--", dir })
end)

t.test("a command word that looks like an env option or assignment is safe", function()
    local out, code = devos.capture({ "-i" }, { env = { X = "1" }, stderr = "null" })
    t.eq(out, "")
    t.eq(code, 127)
    local _, assignment = devos.capture({ "A=b" }, { env = { X = "1" }, stderr = "null" })
    t.eq(assignment, 127)
end)

t.test("a command path with = in it runs through env, exec included", function()
    local dir = assert(fs.mktemp({ dir = true }))
    local script = dir .. "/a=b"
    assert(fs.write(script, "#!/bin/sh\nprintf '%s' \"$X\"\n"))
    assert(devos.run({ "chmod", "755", script }) == 0, "chmod failed")
    t.eq(devos.capture({ script }, { env = { X = "1" } }), "1")
    t.eq(child(("o.exec({ %q }, { env = { X = '2' } })"):format(script)), "2")
    fs.remove(dir, { recursive = true })
end)

t.test("a bad env name reports the variable-name error from run, capture and exec", function()
    for _, call in ipairs({ devos.run, devos.capture, devos.exec }) do
        local ok, err = pcall(function()
            call({ "true" }, { env = { ["A B"] = "x" } })
        end)
        t.ok(
            not ok and err:find("variable name", 1, true) and err:find("os_test.lua", 1, true),
            tostring(err)
        )
    end
    t.raises(function()
        devos.run({ "true" }, { env = { [1] = "a" } })
    end, "variable name")
end)

t.test("a relative stdout path resolves against the caller, not cwd", function()
    local dir = support.tempdir()
    t.eq(devos.run({ "mkdir", "--", dir .. "/sub" }), 0)
    child("o.run({'echo', 'hi'}, {cwd = 'sub', stdout = 'out.txt'})", { cwd = dir })
    t.eq(io.open(dir .. "/out.txt"):read("*a"), "hi\n")
    t.ok(not io.open(dir .. "/sub/out.txt"), "the file must not land in cwd")
    child("o.exec({'echo', 'yo'}, {cwd = 'sub', stdout = 'out2.txt'})", { cwd = dir })
    t.eq(io.open(dir .. "/out2.txt"):read("*a"), "yo\n")
    devos.run({ "rm", "-rf", "--", dir })
end)

t.test("a stdout path with spaces and quotes is appended to", function()
    local dir = support.tempdir()
    local file = dir .. "/it's a log"
    devos.run({ "echo", "a" }, { stdout = file })
    devos.run({ "echo", "b" }, { stdout = file })
    t.eq(io.open(file):read("*a"), "a\nb\n")
    devos.run({ "rm", "-rf", "--", dir })
end)

t.test("exec merges stderr into stdout", function()
    local out = child("o.exec({'sh', '-c', 'echo out; echo err >&2'}, {stderr = 'stdout'})")
    t.eq(out, "out\nerr\n")
end)

t.test("unset removes a variable from the child, over the defaults too", function()
    local probe = { "sh", "-c", 'printf %s "${A-unset}${B-unset}"' }
    t.eq(devos.capture(probe, { env = { A = "a", B = "b" }, unset = { "A" } }), "unsetb")
    devos.defaults.unset = { "B" }
    local out = devos.capture(probe, { env = { A = "a" } })
    devos.defaults.unset = {}
    t.eq(out, "aunset")
end)

t.test("open_nofollow, fstat and read_fd read a regular file through one descriptor", function()
    local dir = support.tempdir()
    assert(fs.write(dir .. "/f", "hello world"))
    local fd = assert(devos.open_nofollow(dir .. "/f"))
    local stat = assert(devos.fstat(fd))
    t.eq(stat.kind, "file")
    t.eq(stat.size, 11)
    t.eq(stat.uid, tonumber((devos.capture({ "id", "-u" }))))
    t.eq(devos.read_fd(fd, 5), "hello")
    t.eq(devos.read_fd(fd, 100), " world")
    devos.close(fd)
    fs.remove(dir, { recursive = true })
end)

t.test("open_nofollow refuses a symbolic link and a missing file", function()
    local dir = support.tempdir()
    assert(fs.write(dir .. "/real", "x"))
    assert(fs.symlink(dir .. "/real", dir .. "/link"))
    local fd, message = devos.open_nofollow(dir .. "/link")
    t.eq(fd, nil)
    t.ok(type(message) == "string" and message ~= "", "expected a message")
    t.eq((devos.open_nofollow(dir .. "/missing")), nil)
    fs.remove(dir, { recursive = true })
end)

t.test("fstat names a directory and a FIFO, and opening a FIFO does not block", function()
    local dir = support.tempdir()
    assert(fs.mkdir(dir .. "/d"))
    assert(devos.run({ "mkfifo", dir .. "/p" }) == 0, "mkfifo failed")
    local fd = assert(devos.open_nofollow(dir .. "/d"))
    t.eq(devos.fstat(fd).kind, "dir")
    devos.close(fd)
    fd = assert(devos.open_nofollow(dir .. "/p"))
    t.eq(devos.fstat(fd).kind, "other")
    devos.close(fd)
    fs.remove(dir, { recursive = true })
end)

t.test("open_nofollow refuses a path with a NUL byte", function()
    t.eq((devos.open_nofollow("/tmp/a\0b")), nil)
end)

t.test("capture_timed collects output and the exit code with no stdin", function()
    local out, code = devos.capture_timed({ "sh", "-c", "cat; echo out; exit 3" }, 10)
    t.eq(out, "out\n")
    t.eq(code, 3)
    out = devos.capture_timed({ "sh", "-c", "echo out; echo err >&2" }, 10, { merge = true })
    t.eq(out, "out\nerr\n")
end)

t.test("capture_timed hands the input to the command", function()
    local out, code = devos.capture_timed({ "cat" }, 10, { input = "a b\n" })
    t.eq(out, "a b\n")
    t.eq(code, 0)
end)

t.test("capture_timed passes hostile words through unchanged", function()
    local out = devos.capture_timed({ "printf", "%s", "a b;$(id)'\"`" }, 10)
    t.eq(out, "a b;$(id)'\"`")
end)

t.test("capture_timed stops a command and its children after the limit", function()
    local started = os.time()
    local out, code = devos.capture_timed(
        { "sh", "-c", "echo before; sleep 3761 & sleep 3762; wait" },
        1,
        { merge = true }
    )
    t.eq(code, 124)
    t.eq(out, "before\n")
    t.ok(os.time() - started < 30, "the limit should not take long")
    local left = devos.capture({ "pgrep", "-f", "sleep 376[12]" }, { stderr = "null" })
    t.eq(left, "")
end)

t.test("capture_timed reports a command killed by a signal as 124", function()
    local _, code = devos.capture_timed({ "sh", "-c", "exec kill -TERM $$" }, 10)
    t.eq(code, 124)
end)

t.test("without_sigpipe turns a write to a closed pipe into a failed write", function()
    local pipe = assert(io.popen("true", "w"))
    devos.run({ "sleep", "0.3" })
    local ok = devos.without_sigpipe(function()
        local wrote = pipe:write(string.rep("x", 1048576))
        local flushed = pipe:flush()
        return wrote ~= nil and flushed ~= nil
    end)
    pipe:close()
    t.eq(ok, false)
end)

t.test("capture_timed cleans up when its process is terminated", function()
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
    t.ok(sleeping(), "the command should be running")
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
    t.eq(left, "")
    t.eq(dirs, "")
end)

t.test("capture_timed with no seconds sets no limit and runs to completion", function()
    local started = os.time()
    local out, code = devos.capture_timed({ "sh", "-c", "sleep 2; echo done" }, 0)
    t.eq(out, "done\n")
    t.eq(code, 0)
    t.ok(os.time() - started >= 2, "the command should have been waited for")
end)
