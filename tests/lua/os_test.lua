local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")
local turn = require("dev.board.turn")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/dotfiles/bin/.local/share/dev/main.lua"
local LAUNCHER = REPO .. "/dotfiles/bin/.local/bin/dev"
local WAIT_TICKS = 100
local VERB_WAIT_TICKS = 300
local VERB_POLL_SECS = 0.1
local WAIT_POLL_SECS = "0.1"
local CLEANUP_VERB = "-- Register a cleanup.\n"
    .. [[
local dev_os = require("dev.os")
local dir = os.getenv("CLEANUP_DIR")
dev_os.on_exit(function()
    local file = assert(io.open(dir .. "/ran", "a"))
    file:write("cleanup\n")
    file:close()
end)
]]
local WAIT_VERB = CLEANUP_VERB
    .. string.format(
        [[
assert(io.open(dir .. "/ready", "w")):close()
for _ = 1, %d do
    dev_os.nap(%s)
end
return 0
]],
        VERB_WAIT_TICKS,
        VERB_POLL_SECS
    )
local SIGNAL_SCRIPT = [[
cd "$1" || exit 97
luajit "$3" term >"$1/out" 2>&1 &
pid=$!
i=0
while [ ! -e "$1/ready" ] && [ "$i" -lt "$4" ]; do sleep 0.1; i=$((i + 1)); done
if [ ! -e "$1/ready" ]; then kill -KILL "$pid"; wait "$pid"; exit 99; fi
kill -"$2" "$pid"
i=0
while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$4" ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid"; wait "$pid"; exit 98; fi
wait "$pid"
]]

testing.test("quote wraps in single quotes and escapes embedded ones", function()
    testing.eq(dev_os.quote("it's"), [['it'\''s']])
    testing.eq(dev_os.quote(""), "''")
end)

testing.test("quote refuses a NUL byte", function()
    testing.raises(function()
        dev_os.quote("a\0b")
    end, "NUL")
end)

testing.test("command joins the quoted words", function()
    testing.eq(dev_os.command({ "echo", "a b", "it's" }), [['echo' 'a b' 'it'\''s']])
end)

testing.test("capture passes hostile text through unchanged", function()
    local out, code = dev_os.capture({ "printf", "%s", "a b;$(id)'\"`" })
    testing.eq(out, "a b;$(id)'\"`")
    testing.eq(code, 0)
end)

testing.test("capture keeps trailing newlines", function()
    local out = dev_os.capture({ "printf", "a\n\n" })
    testing.eq(out, "a\n\n")
end)

testing.test("capture returns the exit code", function()
    testing.eq(select(2, dev_os.capture({ "sh", "-c", "exit 3" })), 3)
end)

testing.test("run returns the exit code", function()
    testing.eq(dev_os.run({ "sh", "-c", "exit 7" }), 7)
    testing.eq(dev_os.run({ "true" }), 0)
end)

testing.test("run reports a signal death as 128 plus the signal", function()
    testing.eq(dev_os.run({ "sh", "-c", "kill -TERM $$" }), 143)
end)

testing.test("which finds a tool or returns nil", function()
    local path = dev_os.which("sh")
    testing.ok(path and path:sub(1, 1) == "/", "sh should resolve to an absolute path")
    testing.eq(dev_os.which("no-such-tool-xyz"), nil)
end)

testing.test("getuid matches id -u", function()
    local out = dev_os.capture({ "id", "-u" })
    testing.eq(dev_os.getuid(), tonumber(out))
end)

testing.test("isatty is false for stdin from /dev/null", function()
    local snippet = ("package.path = %q; "):format(package.path)
        .. 'io.write(tostring(require("dev.os").isatty(0)))'
    local out = dev_os.capture({ "sh", "-c", [[luajit -e "$1" </dev/null]], "sh", snippet })
    testing.eq(out, "false")
end)

testing.test("exec returns nil and a message on failure", function()
    local res, err = dev_os.exec({ "no-such-tool-xyz" })
    testing.eq(res, nil)
    testing.ok(type(err) == "string" and err ~= "", "expected an error message")
end)

testing.test("run returns 127 for a missing tool", function()
    testing.eq(dev_os.run({ "no-such-tool-xyz" }), 127)
end)

testing.test("capture passes a newline and a leading dash through", function()
    local out = dev_os.capture({ "printf", "%s", "-x\ny" })
    testing.eq(out, "-x\ny")
end)

testing.test("run and capture flush Lua output before the child writes", function()
    local snippet = ("package.path = %q; local o = require('dev.os'); "):format(package.path)
        .. "io.write('a'); o.run({'printf', 'b'}); io.write('c'); "
        .. "local out = o.capture({'printf', 'd'}); io.write(out)"
    local out = dev_os.capture({ "sh", "-c", [[luajit -e "$1" | cat]], "sh", snippet })
    testing.eq(out, "abcd")
end)

testing.test("env passes hostile text to the child unchanged", function()
    local out = dev_os.capture({ "sh", "-c", [[printf %s "$X"]] }, { env = { X = "a b;$(id)" } })
    testing.eq(out, "a b;$(id)")
end)

testing.test("env refuses a name that is not a variable name", function()
    testing.raises(function()
        dev_os.run({ "true" }, { env = { ["A B"] = "x" } })
    end, "variable name")
end)

testing.test("defaults.env sits under opts.env", function()
    dev_os.defaults.env = { A = "default", B = "default" }
    local out = dev_os.capture({ "sh", "-c", [[printf %s-%s "$A" "$B"]] }, { env = { B = "own" } })
    dev_os.defaults.env = {}
    testing.eq(out, "default-own")
end)

testing.test("cwd runs the command in a directory with a quote and a space", function()
    local dir = support.tempdir() .. "/os test's"
    testing.eq(dev_os.run({ "mkdir", "--", dir }), 0)
    local out = dev_os.capture({ "sh", "-c", [[cd -P . && pwd -P]] }, { cwd = dir })
    local real = dev_os.capture({ "sh", "-c", [[cd -P "$1" && pwd -P]], "sh", dir })
    dev_os.run({ "rm", "-rf", "--", dir })
    testing.eq(out, real)
    testing.ok(out:find("os test's", 1, true), "the directory should be the one asked for")
end)

testing.test("stdin null gives the child an empty input", function()
    local out = dev_os.capture({ "sh", "-c", [[cat; printf end]] }, { stdin = "null" })
    testing.eq(out, "end")
end)

testing.test("stdin refuses any other value", function()
    testing.raises(function()
        dev_os.run({ "true" }, { stdin = "tty" })
    end, "stdin")
end)

testing.test("stderr stdout merges the streams into capture", function()
    local out = dev_os.capture({ "sh", "-c", "echo out; echo err >&2" }, { stderr = "stdout" })
    testing.eq(out, "out\nerr\n")
end)

testing.test("stdout and stderr null drop the streams", function()
    local out = dev_os.capture(
        { "sh", "-c", "echo out; echo err >&2" },
        { stdout = "null", stderr = "null" }
    )
    testing.eq(out, "")
end)

testing.test("stdout and stderr append to a file", function()
    local file = assert(require("dev.fs").mktemp({ prefix = "os-log" }))
    dev_os.run({ "sh", "-c", "echo out; echo err >&2" }, { stdout = file, stderr = file })
    dev_os.run({ "sh", "-c", "echo more" }, { stdout = file })
    local text = io.open(file):read("*a")
    dev_os.run({ "rm", "-f", "--", file })
    testing.eq(text, "out\nerr\nmore\n")
end)

testing.test("show writes the quoted command to stderr first", function()
    local snippet = ("package.path = %q; local o = require('dev.os'); "):format(package.path)
        .. "o.defaults.show = true; o.run({'printf', '%s', 'x'}); o.capture({'true'})"
    local out = dev_os.capture({ "sh", "-c", [[luajit -e "$1" 2>&1]], "sh", snippet })
    testing.eq(out, "+ 'printf' '%s' 'x'\nx+ 'true'\n")
end)

testing.test("exec honours env, cwd and stdin null", function()
    local snippet = ("package.path = %q; "):format(package.path)
        .. [[require('dev.os').exec({'sh', '-c', 'printf "%s|%s|" "$X" "$(pwd -P)"; cat'}, ]]
        .. [[{env = {X = 'a b'}, cwd = '/', stdin = 'null'})]]
    local out = dev_os.capture({ "sh", "-c", [[luajit -e "$1"]], "sh", snippet })
    testing.eq(out, "a b|/|")
end)

testing.test("exec appends output to a file", function()
    local file = assert(require("dev.fs").mktemp({ prefix = "os-log" }))
    local snippet = ("package.path = %q; "):format(package.path)
        .. ("require('dev.os').exec({'printf', 'hi'}, {stdout = %q})"):format(file)
    dev_os.run({ "luajit", "-e", snippet })
    local text = io.open(file):read("*a")
    dev_os.run({ "rm", "-f", "--", file })
    testing.eq(text, "hi")
end)

testing.test("name is Darwin, Linux or Windows", function()
    local name = dev_os.name()
    testing.ok(name == "Darwin" or name == "Linux" or name == "Windows", "unexpected name " .. name)
end)

testing.test("fake_env fakes the uid and the OS from the environment", function()
    local root = arg[0]:match("^(.*)/tests/lua/") or "."
    local FAKE_ENV = root .. "/tests/lua/fake_env.lua"
    local out = dev_os.capture(
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
    return dev_os.capture({ "luajit", "-e", code }, opts)
end

testing.test("cwd may start with a dash, and a lone dash is a directory name", function()
    local dir = support.tempdir()
    testing.eq(dev_os.run({ "mkdir", "--", dir .. "/-x", dir .. "/-" }), 0)
    local out = child(
        "io.write((o.capture({'basename', '.'}, {cwd = '-x'})), (o.capture({'sh', '-c', 'basename \"$(pwd)\"'}, {cwd = '-'})))",
        { cwd = dir }
    )
    testing.eq(out, ".\n-\n")
    out = child("o.exec({'sh','-c','basename \"$(pwd)\"'}, {cwd = '-x'})", { cwd = dir })
    testing.eq(out, "-x\n")
    dev_os.run({ "rm", "-rf", "--", dir })
end)

testing.test("a command word that looks like an env option or assignment is safe", function()
    local out, code = dev_os.capture({ "-i" }, { env = { X = "1" }, stderr = "null" })
    testing.eq(out, "")
    testing.eq(code, 127)
    local _, assignment = dev_os.capture({ "A=b" }, { env = { X = "1" }, stderr = "null" })
    testing.eq(assignment, 127)
end)

testing.test("a command path with = in it runs through env, exec included", function()
    local dir = assert(fs.mktemp({ dir = true }))
    local script = dir .. "/a=b"
    assert(fs.write(script, "#!/bin/sh\nprintf '%s' \"$X\"\n"))
    assert(dev_os.run({ "chmod", "755", script }) == 0, "chmod failed")
    testing.eq(dev_os.capture({ script }, { env = { X = "1" } }), "1")
    testing.eq(child(("o.exec({ %q }, { env = { X = '2' } })"):format(script)), "2")
    fs.remove(dir, { recursive = true })
end)

testing.test("a bad env name reports the variable-name error from run, capture and exec", function()
    for _, call in ipairs({ dev_os.run, dev_os.capture, dev_os.exec }) do
        local ok, err = pcall(function()
            call({ "true" }, { env = { ["A B"] = "x" } })
        end)
        testing.ok(
            not ok and err:find("variable name", 1, true) and err:find("os_test.lua", 1, true),
            tostring(err)
        )
    end
    testing.raises(function()
        dev_os.run({ "true" }, { env = { [1] = "a" } })
    end, "variable name")
end)

testing.test("a relative stdout path resolves against the caller, not cwd", function()
    local dir = support.tempdir()
    testing.eq(dev_os.run({ "mkdir", "--", dir .. "/sub" }), 0)
    child("o.run({'echo', 'hi'}, {cwd = 'sub', stdout = 'out.txt'})", { cwd = dir })
    testing.eq(io.open(dir .. "/out.txt"):read("*a"), "hi\n")
    testing.ok(not io.open(dir .. "/sub/out.txt"), "the file must not land in cwd")
    child("o.exec({'echo', 'yo'}, {cwd = 'sub', stdout = 'out2.txt'})", { cwd = dir })
    testing.eq(io.open(dir .. "/out2.txt"):read("*a"), "yo\n")
    dev_os.run({ "rm", "-rf", "--", dir })
end)

testing.test("a stdout path with spaces and quotes is appended to", function()
    local dir = support.tempdir()
    local file = dir .. "/it's a log"
    dev_os.run({ "echo", "a" }, { stdout = file })
    dev_os.run({ "echo", "b" }, { stdout = file })
    testing.eq(io.open(file):read("*a"), "a\nb\n")
    dev_os.run({ "rm", "-rf", "--", dir })
end)

testing.test("exec merges stderr into stdout", function()
    local out = child("o.exec({'sh', '-c', 'echo out; echo err >&2'}, {stderr = 'stdout'})")
    testing.eq(out, "out\nerr\n")
end)

testing.test("unset removes a variable from the child, over the defaults too", function()
    local probe = { "sh", "-c", 'printf %s "${A-unset}${B-unset}"' }
    testing.eq(dev_os.capture(probe, { env = { A = "a", B = "b" }, unset = { "A" } }), "unsetb")
    dev_os.defaults.unset = { "B" }
    local out = dev_os.capture(probe, { env = { A = "a" } })
    dev_os.defaults.unset = {}
    testing.eq(out, "aunset")
end)

testing.test(
    "open_nofollow, fstat and read_fd read a regular file through one descriptor",
    function()
        local dir = support.tempdir()
        assert(fs.write(dir .. "/f", "hello world"))
        local fd = assert(dev_os.open_nofollow(dir .. "/f"))
        local stat = assert(dev_os.fstat(fd))
        testing.eq(stat.kind, "file")
        testing.eq(stat.size, 11)
        testing.eq(stat.uid, tonumber((dev_os.capture({ "id", "-u" }))))
        testing.eq(dev_os.read_fd(fd, 5), "hello")
        testing.eq(dev_os.read_fd(fd, 100), " world")
        dev_os.close(fd)
        fs.remove(dir, { recursive = true })
    end
)

testing.test("open_nofollow refuses a symbolic link and a missing file", function()
    local dir = support.tempdir()
    assert(fs.write(dir .. "/real", "x"))
    assert(fs.symlink(dir .. "/real", dir .. "/link"))
    local fd, message = dev_os.open_nofollow(dir .. "/link")
    testing.eq(fd, nil)
    testing.ok(type(message) == "string" and message ~= "", "expected a message")
    testing.eq((dev_os.open_nofollow(dir .. "/missing")), nil)
    fs.remove(dir, { recursive = true })
end)

testing.test("fstat names a directory and a FIFO, and opening a FIFO does not block", function()
    local dir = support.tempdir()
    assert(fs.mkdir(dir .. "/d"))
    assert(dev_os.run({ "mkfifo", dir .. "/p" }) == 0, "mkfifo failed")
    local fd = assert(dev_os.open_nofollow(dir .. "/d"))
    testing.eq(dev_os.fstat(fd).kind, "dir")
    dev_os.close(fd)
    fd = assert(dev_os.open_nofollow(dir .. "/p"))
    testing.eq(dev_os.fstat(fd).kind, "other")
    dev_os.close(fd)
    fs.remove(dir, { recursive = true })
end)

testing.test("open_nofollow refuses a path with a NUL byte", function()
    testing.eq((dev_os.open_nofollow("/tmp/a\0b")), nil)
end)

testing.test("capture_timed collects output and the exit code with no stdin", function()
    local out, code = dev_os.capture_timed({ "sh", "-c", "cat; echo out; exit 3" }, 10)
    testing.eq(out, "out\n")
    testing.eq(code, 3)
    out = dev_os.capture_timed({ "sh", "-c", "echo out; echo err >&2" }, 10, { merge = true })
    testing.eq(out, "out\nerr\n")
end)

testing.test("capture_timed hands output to on_text while the command runs", function()
    local dir = support.tempdir()
    local chunks = {}
    local out, code = dev_os.capture_timed(
        {
            "sh",
            "-c",
            "echo first; while [ ! -e seen ]; do sleep 0.1; done; echo second",
        },
        30,
        {
            cwd = dir,
            on_text = function(text)
                chunks[#chunks + 1] = text
                assert(fs.write(dir .. "/seen", "x"))
            end,
        }
    )
    testing.eq(code, 0)
    testing.eq(out, "first\nsecond\n")
    testing.eq(table.concat(chunks), out)
    testing.ok(#chunks >= 2, "the first line should arrive before the command ends")
end)

testing.test(
    "capture_timed leaves no defunct child under this process while the command runs",
    function()
        local zombies
        local function defunct()
            local rows = dev_os.capture({ "ps", "-A", "-o", "ppid=,stat=" })
            local mine = tostring(dev_os.getpid())
            local found = {}
            for ppid, stat in rows:gmatch("(%d+)%s+(%S+)") do
                if ppid == mine and stat:sub(1, 1) == "Z" then
                    found[#found + 1] = stat
                end
            end
            return found
        end
        dev_os.capture_timed({ "sh", "-c", "echo go; sleep 2" }, 30, {
            on_text = function()
                dev_os.nap(1)
                zombies = defunct()
            end,
        })
        testing.eq(zombies, {})
    end
)

testing.test("capture_timed hands the input to the command", function()
    local out, code = dev_os.capture_timed({ "cat" }, 10, { input = "a b\n" })
    testing.eq(out, "a b\n")
    testing.eq(code, 0)
end)

testing.test("capture_timed passes hostile words through unchanged", function()
    local out = dev_os.capture_timed({ "printf", "%s", "a b;$(id)'\"`" }, 10)
    testing.eq(out, "a b;$(id)'\"`")
end)

local LEFT_RUNNING_TRIES = 20

local function left_running(pattern)
    local left = ""
    for _ = 1, LEFT_RUNNING_TRIES do
        left = dev_os.capture({ "pgrep", "-f", pattern }, { stderr = "null" })
        if left == "" then
            break
        end
        dev_os.run({ "sleep", WAIT_POLL_SECS })
    end
    return left
end

testing.test("capture_timed stops a command and its children after the limit", function()
    local started = os.time()
    local pid = dev_os.capture({ "sh", "-c", "echo $$" }):match("%d+")
    local unique_secs = 1000000 + 2 * tonumber(pid)
    local first, second = unique_secs, unique_secs + 1
    local out, code = dev_os.capture_timed({
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
    local left = left_running(("^sleep (%d|%d)$"):format(first, second))
    testing.eq(left, "")
end)

testing.test("capture_timed with reap kills what a finished command left running", function()
    local pid = dev_os.capture({ "sh", "-c", "echo $$" }):match("%d+")
    local unique_secs = 1000000 + 4 * tonumber(pid)
    local out, code = dev_os.capture_timed(
        { "sh", "-c", ("sleep %d & echo done"):format(unique_secs) },
        10,
        { merge = true, reap = true }
    )
    testing.eq(code, 0)
    testing.eq(out, "done\n")
    local left = left_running(("^sleep %d$"):format(unique_secs))
    testing.eq(left, "")
end)

testing.test("capture_timed reports a command killed by a signal as 124", function()
    local _, code = dev_os.capture_timed({ "sh", "-c", "exec kill -TERM $$" }, 10)
    testing.eq(code, 124)
end)

testing.test("without_sigpipe turns a write to a closed pipe into a failed write", function()
    local pipe = assert(io.popen("true", "w"))
    dev_os.run({ "sleep", "0.3" })
    local ok = dev_os.without_sigpipe(function()
        local wrote = pipe:write(string.rep("x", 1048576))
        local flushed = pipe:flush()
        return wrote ~= nil and flushed ~= nil
    end)
    pipe:close()
    testing.eq(ok, false)
end)

local CAPTURE_TIMED_LIMIT_SECS = 600

local function launch_capture_timed(command, tmp)
    local snippet = ("package.path = %q; "):format(package.path)
        .. ("require('dev.os').capture_timed({ 'sh', '-c', %q }, %d)"):format(
            command,
            CAPTURE_TIMED_LIMIT_SECS
        )
    local pid = dev_os.capture({
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
    local out = dev_os.capture({ "sh", "-c", "ps -axo args=" })
    return ("\n" .. out):find("\n" .. needle .. "\n", 1, true) ~= nil
end

local function wait_until(predicate)
    local WAIT_POLLS = 50
    for _ = 1, WAIT_POLLS do
        if predicate() then
            return true
        end
        dev_os.run({ "sleep", WAIT_POLL_SECS })
    end
    return predicate()
end

local function dir_empty(dir)
    return dev_os.capture({ "ls", dir }) == ""
end

local function unique_secs(factor)
    local pid = dev_os.capture({ "sh", "-c", "echo $$" }):match("%d+")
    return 1000000 + factor * tonumber(pid)
end

local function cleans_up_after(signal, factor)
    local first = unique_secs(factor)
    local second = first + 1
    local tmp = assert(fs.mktemp({ dir = true }))
    local pid = launch_capture_timed(("sleep %d & sleep %d; wait"):format(first, second), tmp)
    testing.ok(
        wait_until(function()
            return process_listed("sleep " .. first)
        end),
        "the command should be running"
    )
    dev_os.run({ "kill", signal, pid })
    local gone = wait_until(function()
        return not process_listed("sleep " .. first) and not process_listed("sleep " .. second)
    end)
    local removed = wait_until(function()
        return dir_empty(tmp)
    end)
    fs.remove(tmp, { recursive = true })
    testing.ok(gone, "the command and its children should be killed")
    testing.ok(removed, "the temporary directory should be removed")
end

testing.test("capture_timed cleans up when its process is terminated", function()
    cleans_up_after("-TERM", 6)
end)

testing.test("capture_timed cleans up when its process is killed", function()
    cleans_up_after("-KILL", 8)
end)

local function wrapper_pid(marker)
    local out = dev_os.capture({ "sh", "-c", "ps -axo pid=,args=" })
    for pid, args in out:gmatch("(%d+)%s+([^\n]*)") do
        if args:find("^sh %-c") and args:find("set -m", 1, true) and args:find(marker, 1, true) then
            return pid
        end
    end
end

testing.test("capture_timed leaves no command running when its wrapper is terminated", function()
    local tmp = assert(fs.mktemp({ dir = true }))
    local marker = "sleep " .. unique_secs(12)
    local caller = launch_capture_timed(marker, tmp)
    local wrapper
    testing.ok(
        wait_until(function()
            wrapper = wrapper_pid(marker)
            return wrapper ~= nil
        end),
        "the wrapper should be running"
    )
    dev_os.run({ "kill", "-TERM", wrapper }, { stderr = "null" })
    dev_os.run({ "kill", "-KILL", caller }, { stderr = "null" })
    local gone = wait_until(function()
        return not process_listed(marker)
    end)
    local removed = wait_until(function()
        return dir_empty(tmp)
    end)
    fs.remove(tmp, { recursive = true })
    testing.ok(gone, "no process of the command should survive")
    testing.ok(removed, "the temporary directory should be removed")
end)

local function children_of(marker)
    local out = dev_os.capture({ "sh", "-c", "ps -axo pid=,ppid=,args=" })
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
    return found, next(owners) ~= nil
end

testing.test("capture_timed starts no process while its command runs", function()
    local tmp = assert(fs.mktemp({ dir = true }))
    local marker = "sleep " .. unique_secs(10)
    local pid = launch_capture_timed(marker, tmp)
    testing.ok(
        wait_until(function()
            return process_listed(marker)
        end),
        "the command should be running"
    )
    testing.ok(
        wait_until(function()
            return dev_os.capture({
                "sh",
                "-c",
                [[ls "$1"/dev-timed.*/pids 2>/dev/null]],
                "sh",
                tmp,
            }) ~= ""
        end),
        "the wrapper should have finished starting"
    )
    local WATCH_POLLS = 15
    local seen, saw_owner = {}, false
    for poll = 1, WATCH_POLLS do
        local found, owned = children_of(marker)
        for _, args in ipairs(found) do
            seen[#seen + 1] = ("poll %d: %s"):format(poll, args)
        end
        saw_owner = saw_owner or owned
        dev_os.run({ "sleep", WAIT_POLL_SECS })
    end
    dev_os.run({ "kill", "-KILL", pid }, { stderr = "null" })
    wait_until(function()
        return not process_listed(marker)
    end)
    fs.remove(tmp, { recursive = true })
    testing.ok(saw_owner, "the probe should see the command's owner row")
    testing.eq(table.concat(seen, "\n"), "")
end)

local function capture_timed_in(tmp, body, bin)
    local snippet = ("package.path = %q; local dev_os = require('dev.os'); "):format(package.path)
        .. body
    local env = { TMPDIR = tmp }
    if bin then
        env.PATH = bin .. ":" .. os.getenv("PATH")
    end
    return dev_os.capture({ "luajit", "-e", snippet }, { env = env })
end

local function timed_dirs_gone(tmp)
    return wait_until(function()
        return dev_os.capture({ "ls", tmp }) == ""
    end)
end

local function stderr_of_capture_timed(body)
    local snippet = ("package.path = %q; local dev_os = require('dev.os'); "):format(package.path)
        .. body
    return dev_os.capture({
        "sh",
        "-c",
        [[luajit -e "$1" 2>&1 >/dev/null </dev/null]],
        "sh",
        snippet,
    })
end

testing.test("capture_timed writes no job-control lines to stderr", function()
    testing.eq(stderr_of_capture_timed("dev_os.capture_timed({ 'true' }, 10)"), "")
    testing.eq(stderr_of_capture_timed("dev_os.capture_timed({ 'sh', '-c', 'exit 3' }, 10)"), "")
end)

testing.test("capture_timed still passes the command's own stderr through", function()
    local got = stderr_of_capture_timed("dev_os.capture_timed({ 'sh', '-c', 'echo err >&2' }, 10)")
    testing.eq(got, "err\n")
end)

testing.test("capture_timed leaves no defunct child once it returns", function()
    local body = "dev_os.capture_timed({ 'true' }, 10); "
        .. "local mine = tostring(dev_os.getpid()); local n = 0; "
        .. "for ppid, stat in dev_os.capture({ 'ps', '-A', '-o', 'ppid=,stat=' })"
        .. ":gmatch('(%d+)%s+(%S+)') do "
        .. "if ppid == mine and stat:sub(1, 1) == 'Z' then n = n + 1 end end; "
        .. "io.write(n)"
    local tmp = assert(fs.mktemp({ dir = true }))
    local got = capture_timed_in(tmp, body)
    fs.remove(tmp, { recursive = true })
    testing.eq(got, "0")
end)

testing.test("capture_timed leaves no temporary directory after a normal return", function()
    -- Give the run a private temporary directory so only its own directories show
    local tmp = assert(fs.mktemp({ dir = true }))

    -- Run a command that returns normally
    local out = capture_timed_in(tmp, "io.write((dev_os.capture_timed({ 'echo', 'done' }, 10)))")
    local gone = timed_dirs_gone(tmp)
    fs.remove(tmp, { recursive = true })

    -- Check the output and that the directory is gone
    testing.eq(out, "done\n")
    testing.ok(gone, "the temporary directory should be removed")
end)

testing.test("capture_timed errors and removes its directory when the launch fails", function()
    -- Give the run a private temporary directory and a mv that fails, so no pids file appears
    local tmp = assert(fs.mktemp({ dir = true }))
    local root = support.sandbox({ ["bin/mv"] = "#!/bin/sh\nexit 1\n" }, {})
    assert(dev_os.run({ "chmod", "755", root .. "/bin/mv" }) == 0, "chmod failed")

    -- Launch the command and catch the error
    local out = capture_timed_in(
        tmp,
        "local ok, err = pcall(dev_os.capture_timed, { 'true' }, 10); "
            .. "io.write(tostring(ok), ' ', err)",
        root .. "/bin"
    )
    local gone = timed_dirs_gone(tmp)
    fs.remove(tmp, { recursive = true })

    -- Check the launch error and that no directory is left
    testing.ok(out:find("false", 1, true) == 1, out)
    testing.ok(out:find("capture_timed could not start true", 1, true), out)
    testing.ok(gone, "the temporary directory should be removed")
end)

testing.test("capture_timed with no seconds sets no limit and runs to completion", function()
    local started = os.time()
    local out, code = dev_os.capture_timed({ "sh", "-c", "sleep 2; echo done" }, 0)
    testing.eq(out, "done\n")
    testing.eq(code, 0)
    testing.ok(os.time() - started >= 2, "the command should have been waited for")
end)

local function cleanup_project(source)
    local root = support.sandbox({ [".dev/term.lua"] = source }, {})
    assert(dev_os.run({ "chmod", "755", root .. "/.dev/term.lua" }) == 0, "chmod failed")
    return root
end

local function child_env(root)
    return { CLEANUP_DIR = root, DEV_SELF = LAUNCHER }
end

local function ran(root)
    return fs.read(root .. "/ran")
end

local function kill_child(root, signal)
    local code = dev_os.run({
        "sh",
        "-c",
        SIGNAL_SCRIPT,
        "sh",
        root,
        signal,
        MAIN,
        tostring(WAIT_TICKS),
    }, { env = child_env(root) })
    return code
end

testing.test("a verb killed by SIGTERM runs its cleanup once and exits 143", function()
    local root = cleanup_project(WAIT_VERB)
    testing.eq(kill_child(root, "TERM"), 143)
    testing.eq(ran(root), "cleanup\n")
    fs.remove(root, { recursive = true })
end)

testing.test("a verb interrupted by SIGINT runs its cleanup once and exits 130", function()
    local root = cleanup_project(WAIT_VERB)
    testing.eq(kill_child(root, "INT"), 130)
    testing.eq(ran(root), "cleanup\n")
    fs.remove(root, { recursive = true })
end)

testing.test("a Lua error runs the cleanup once", function()
    local root = cleanup_project(CLEANUP_VERB .. 'error("boom")\n')
    local _, code = dev_os.capture({ "luajit", MAIN, "term" }, {
        cwd = root,
        stderr = "stdout",
        env = child_env(root),
    })
    testing.eq(code, 1)
    testing.eq(ran(root), "cleanup\n")
    fs.remove(root, { recursive = true })
end)

testing.test("a normal exit runs the cleanup once", function()
    local root = cleanup_project(CLEANUP_VERB .. "return 4\n")
    local out, code = dev_os.capture({ "luajit", MAIN, "term" }, {
        cwd = root,
        stderr = "stdout",
        env = child_env(root),
    })
    testing.eq(code, 4)
    testing.eq(out, "")
    testing.eq(ran(root), "cleanup\n")
    fs.remove(root, { recursive = true })
end)

testing.test("cleanups run newest first and one that raises does not stop the rest", function()
    local root = cleanup_project("-- Register cleanups.\n" .. [=[
local dev_os = require("dev.os")
local dir = os.getenv("CLEANUP_DIR")
local function note(text)
    local file = assert(io.open(dir .. "/ran", "a"))
    file:write(text, "\n")
    file:close()
end
dev_os.on_exit(function()
    note("first")
end)
dev_os.on_exit(function()
    error("bad")
end)
dev_os.on_exit(function()
    note("third")
end)
return 0
]=])
    local _, code = dev_os.capture({ "luajit", MAIN, "term" }, {
        cwd = root,
        stderr = "null",
        env = child_env(root),
    })
    testing.eq(code, 0)
    testing.eq(ran(root), "third\nfirst\n")
    fs.remove(root, { recursive = true })
end)

local RANDOM_COUNTS = { 1, 4, 16 }
local ENTROPY_DRAWS = 1000

testing.test("random_bytes returns the count asked for and entropy stays in range", function()
    for _, count in ipairs(RANDOM_COUNTS) do
        testing.eq(#assert(dev_os.random_bytes(count)), count)
    end
    for _ = 1, ENTROPY_DRAWS do
        local fraction = turn.entropy()
        testing.ok(fraction >= 0 and fraction < 1, tostring(fraction))
    end
end)

local function set_io_open(replacement)
    -- Swap io.open to make the random device unreadable
    -- selene: allow(incorrect_standard_library_use)
    io.open = replacement
end

testing.test("random_bytes gives nil and a message when the device cannot be read", function()
    local open = io.open
    local bytes, message, short, short_message
    local ok, failure = pcall(function()
        set_io_open(function()
            return nil, "no such device"
        end)
        bytes, message = dev_os.random_bytes(RANDOM_COUNTS[1])
        set_io_open(function()
            return {
                read = function()
                    return "x"
                end,
                close = function() end,
            }
        end)
        short, short_message = dev_os.random_bytes(RANDOM_COUNTS[2])
    end)
    set_io_open(open)
    assert(ok, failure)
    testing.eq(bytes, nil)
    testing.eq(message, "no such device")
    testing.eq(short, nil)
    testing.ok(short_message:find("too few bytes", 1, true), short_message)
end)
