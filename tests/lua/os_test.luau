local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local support = require("./support")
local turn = require("@dev/board/turn")

local runtime = require("@dev/runtime")
local WAIT_TICKS = 100
local COMMAND_WAIT_TICKS = 300
local COMMAND_POLL_SECS = 0.1
local WAIT_POLL_SECS = "0.1"
local CLEANUP_COMMAND = table.concat({
    "-- Register a cleanup.",
    'local dev_os = require("@dev/os")',
    'local dir = dev_os.getenv("CLEANUP_DIR")',
    "dev_os.on_exit(function()",
    '    assert(require("@dev/fs").append(dir .. "/ran", "cleanup\\n"))',
    "end)",
    "",
}, "\n")
local WAIT_COMMAND = CLEANUP_COMMAND
    .. string.format(
        table.concat({
            'assert(require("@dev/fs").write(dir .. "/ready", ""))',
            "for _ = 1, %d do",
            "    dev_os.nap(%s)",
            "end",
            "return 0",
            "",
        }, "\n"),
        COMMAND_WAIT_TICKS,
        COMMAND_POLL_SECS
    )
local SIGNAL_SCRIPT = table.concat({
    'cd "$1" || exit 97',
    "set -m",
    '"$3" term >"$1/out" 2>&1 &',
    "pid=$!",
    "i=0",
    'while [ ! -e "$1/ready" ] && [ "$i" -lt "$4" ]; do sleep $5; i=$((i + 1)); done',
    'if [ ! -e "$1/ready" ]; then kill -KILL "$pid"; wait "$pid"; exit 99; fi',
    'kill -"$2" "$pid"',
    "i=0",
    'while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$4" ]; do sleep $5; i=$((i + 1)); done',
    'if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid"; wait "$pid"; exit 98; fi',
    'wait "$pid"',
    "",
}, "\n")

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
    -- Write a script that reports whether stdin is a terminal
    local snippet = 'require("@dev/os").stdout:write(tostring(require("@dev/os").isatty(0)))'

    -- Run it with stdin from the null device
    local out = dev_os.capture({
        "sh",
        "-c",
        [["$1" -l "$2" </dev/null]],
        "sh",
        runtime.exe,
        support.script(snippet),
    })

    -- Check it saw no terminal
    testing.eq(out, "false")
end)

testing.test("exec returns nil and a message on failure", function()
    local res, err = dev_os.exec({ "no-such-tool-xyz" })
    testing.eq(res, nil)
    testing.ok(type(err) == "string" and err ~= "", "expected an error message")
end)

local function feed_after_failed_execs(count)
    -- Fail the execs, then feed a large input to a command that quits without reading it
    local snippet = "local dev_os = require('@dev/os'); "
        .. ("for _ = 1, %d do dev_os.exec({ 'no-such-tool-xyz' }) end; "):format(count)
        .. "local input = string.rep('x', 1048576); "
        .. "local _, code = dev_os.capture_timed({ 'true' }, 10, { input = input }); "
        .. "dev_os.stdout:write('alive ', code)"
    return dev_os.capture(support.eval(snippet))
end

testing.test("a failed exec leaves dev getting EPIPE from a closed pipe", function()
    testing.eq(feed_after_failed_execs(1), "alive 0")
end)

testing.test("a second failed exec still leaves dev getting EPIPE from a closed pipe", function()
    testing.eq(feed_after_failed_execs(2), "alive 0")
end)

testing.test("an exec after a failed one runs its command and exits with its status", function()
    -- Fail an exec, then exec a command that exits with a status
    local snippet = "local dev_os = require('@dev/os'); dev_os.exec({ 'no-such-tool-xyz' }); "
        .. "dev_os.exec({ 'sh', '-c', 'echo hi; exit 7' })"
    local out, code = dev_os.capture_timed(support.eval(snippet), 10)

    -- Check the command's output and status came through
    testing.eq(out, "hi\n")
    testing.eq(code, 7)
end)

testing.test("run returns 127 for a missing tool", function()
    testing.eq(dev_os.run({ "no-such-tool-xyz" }), 127)
end)

testing.test("capture passes a newline and a leading dash through", function()
    local out = dev_os.capture({ "printf", "%s", "-x\ny" })
    testing.eq(out, "-x\ny")
end)

testing.test("run and capture flush Lua output before the child writes", function()
    -- Write a script that interleaves its own output with its children's
    local snippet = "local o = require('@dev/os'); "
        .. "o.stdout:write('a'); o.run({'printf', 'b'}); o.stdout:write('c'); "
        .. "local out = o.capture({'printf', 'd'}); o.stdout:write(out)"

    -- Run it with stdout piped
    local out = dev_os.capture({
        "sh",
        "-c",
        [["$1" -l "$2" | cat]],
        "sh",
        runtime.exe,
        support.script(snippet),
    })

    -- Check the output arrived in order
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
    -- Run with a default env that the call's own env partly overrides
    dev_os.defaults.env = { A = "default", B = "default" }
    local out = dev_os.capture({ "sh", "-c", [[printf %s-%s "$A" "$B"]] }, { env = { B = "own" } })

    -- Restore the defaults for later tests
    dev_os.defaults.env = {}

    -- Check the call's value wins and the default fills the rest
    testing.eq(out, "default-own")
end)

testing.test("cwd runs the command in a directory with a quote and a space", function()
    -- Make a directory whose name holds a quote and a space
    local dir = support.tempdir() .. "/os test's"
    testing.eq(dev_os.run({ "mkdir", "--", dir }), 0)

    -- Print the working directory from the option and from the shell
    local out = dev_os.capture({ "sh", "-c", [[cd -P . && pwd -P]] }, { cwd = dir })
    local real = dev_os.capture({ "sh", "-c", [[cd -P "$1" && pwd -P]], "sh", dir })

    -- Remove the directory
    dev_os.run({ "rm", "-rf", "--", dir })

    -- Check both name the directory asked for
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
    -- Make a log file to append to
    local file = assert(require("@dev/fs").mktemp({ prefix = "os-log" }))

    -- Run two commands that write to it
    dev_os.run({ "sh", "-c", "echo out; echo err >&2" }, { stdout = file, stderr = file })
    dev_os.run({ "sh", "-c", "echo more" }, { stdout = file })

    -- Read the log and remove it
    local text = fs.read(file)
    dev_os.run({ "rm", "-f", "--", file })

    -- Check both runs appended
    testing.eq(text, "out\nerr\nmore\n")
end)

testing.test("show writes the quoted command to stderr first", function()
    -- Write a script that runs two commands with show on
    local snippet = "local o = require('@dev/os'); "
        .. "o.defaults.show = true; o.run({'printf', '%s', 'x'}); o.capture({'true'})"

    -- Run it with stderr merged into stdout
    local out = dev_os.capture({
        "sh",
        "-c",
        [["$1" -l "$2" 2>&1]],
        "sh",
        runtime.exe,
        support.script(snippet),
    })

    -- Check each command was echoed before its output
    testing.eq(out, "+ 'printf' '%s' 'x'\nx+ 'true'\n")
end)

testing.test("exec honours env, cwd and stdin null", function()
    -- Write a script that execs a command with env, cwd and a null stdin
    local snippet = [[require('@dev/os').exec({'sh', '-c', 'printf "%s|%s|" "$X" "$(pwd -P)"; cat'}, ]]
        .. [[{env = {X = 'a b'}, cwd = '/', stdin = 'null'})]]

    -- Run the script
    local out =
        dev_os.capture({ "sh", "-c", [["$1" -l "$2"]], "sh", runtime.exe, support.script(snippet) })

    -- Check all three options took effect
    testing.eq(out, "a b|/|")
end)

testing.test("exec appends output to a file", function()
    -- Make a log file for the exec to write to
    local file = assert(require("@dev/fs").mktemp({ prefix = "os-log" }))
    local snippet = ("require('@dev/os').exec({'printf', 'hi'}, {stdout = %q})"):format(file)

    -- Run the exec
    dev_os.run(support.eval(snippet))

    -- Read the log and remove it
    local text = fs.read(file)
    dev_os.run({ "rm", "-f", "--", file })

    -- Check the output reached the file
    testing.eq(text, "hi")
end)

testing.test("name is Darwin, Linux or Windows", function()
    local name = dev_os.name()
    testing.ok(name == "Darwin" or name == "Linux" or name == "Windows", "unexpected name " .. name)
end)

testing.test("fake_env fakes the uid and the OS from the environment", function()
    -- Write a script that loads the fake and reports the uid and the OS
    local root = arg[0]:match("^(.*)/tests/lua/") or "."
    local FAKE_ENV = root .. "/tests/lua/fake_env.luau"
    local snippet = ("require('@dev/runtime').dofile(%q); local o = require('@dev/os'); "):format(
        FAKE_ENV
    ) .. "o.stdout:write(o.getuid(), o.name())"

    -- Run it with the fake values in the environment
    local out = dev_os.capture(support.eval(snippet), {
        env = {
            FAKE_UID = "0",
            FAKE_OS = "Linux",
        },
    })

    -- Check the fake values came back
    testing.eq(out, "0Linux")
end)

local function child(snippet, opts)
    local code = "local o = require('@dev/os'); " .. snippet
    return dev_os.capture(support.eval(code), opts)
end

testing.test("cwd may start with a dash, and a lone dash is a directory name", function()
    -- Make directories named with a dash
    local dir = support.tempdir()
    testing.eq(dev_os.run({ "mkdir", "--", dir .. "/-x", dir .. "/-" }), 0)

    -- Capture with each dashed directory as the cwd
    local out = child(
        "o.stdout:write((o.capture({'basename', '.'}, {cwd = '-x'})), (o.capture({'sh', '-c', 'basename \"$(pwd)\"'}, {cwd = '-'})))",
        { cwd = dir }
    )
    testing.eq(out, ".\n-\n")

    -- Exec with a dashed directory as the cwd
    out = child("o.exec({'sh','-c','basename \"$(pwd)\"'}, {cwd = '-x'})", { cwd = dir })
    testing.eq(out, "-x\n")

    -- Remove the directories
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
    -- Write an executable script whose path holds an equals sign
    local dir = assert(fs.mktemp({ dir = true }))
    local script = dir .. "/a=b"
    assert(fs.write(script, table.concat({ "#!/bin/sh", "printf '%s' \"$X\"", "" }, "\n")))
    assert(dev_os.run({ "chmod", "755", script }) == 0, "chmod failed")

    -- Run it through capture and through exec
    testing.eq(dev_os.capture({ script }, { env = { X = "1" } }), "1")
    testing.eq(child(("o.exec({ %q }, { env = { X = '2' } })"):format(script)), "2")

    -- Remove the directory
    fs.remove(dir, { recursive = true })
end)

testing.test("a bad env name reports the variable-name error from run, capture and exec", function()
    for _, call in ipairs({ dev_os.run, dev_os.capture, dev_os.exec }) do
        local ok, err = pcall(function()
            call({ "true" }, { env = { ["A B"] = "x" } })
        end)
        testing.ok(not ok and tostring(err):find("variable name", 1, true), tostring(err))
    end
    testing.raises(function()
        dev_os.run({ "true" }, { env = { [1] = "a" } })
    end, "variable name")
end)

testing.test("a relative stdout path resolves against the caller, not cwd", function()
    -- Make a directory with a subdirectory to use as the cwd
    local dir = support.tempdir()
    testing.eq(dev_os.run({ "mkdir", "--", dir .. "/sub" }), 0)

    -- Redirect a run's stdout to a relative path
    child("o.run({'echo', 'hi'}, {cwd = 'sub', stdout = 'out.txt'})", { cwd = dir })
    testing.eq(fs.read(dir .. "/out.txt"), "hi\n")
    testing.ok(not fs.exists(dir .. "/sub/out.txt"), "the file must not land in cwd")

    -- Redirect an exec's stdout to a relative path
    child("o.exec({'echo', 'yo'}, {cwd = 'sub', stdout = 'out2.txt'})", { cwd = dir })
    testing.eq(fs.read(dir .. "/out2.txt"), "yo\n")

    -- Remove the directory
    dev_os.run({ "rm", "-rf", "--", dir })
end)

testing.test("a stdout path with spaces and quotes is appended to", function()
    -- Name a log file with spaces and a quote
    local dir = support.tempdir()
    local file = dir .. "/it's a log"

    -- Write to it twice
    dev_os.run({ "echo", "a" }, { stdout = file })
    dev_os.run({ "echo", "b" }, { stdout = file })

    -- Check the second write appended
    testing.eq(fs.read(file), "a\nb\n")

    -- Remove the directory
    dev_os.run({ "rm", "-rf", "--", dir })
end)

testing.test("exec merges stderr into stdout", function()
    local out = child("o.exec({'sh', '-c', 'echo out; echo err >&2'}, {stderr = 'stdout'})")
    testing.eq(out, "out\nerr\n")
end)

testing.test("unset removes a variable from the child, over the defaults too", function()
    -- Unset a variable named in the call's own options
    local probe = { "sh", "-c", 'printf %s "${A-unset}${B-unset}"' }
    testing.eq(dev_os.capture(probe, { env = { A = "a", B = "b" }, unset = { "A" } }), "unsetb")

    -- Unset a variable named in the defaults
    dev_os.defaults.unset = { "B" }
    local out = dev_os.capture(probe, { env = { A = "a" } })

    -- Restore the defaults for later tests
    dev_os.defaults.unset = {}

    -- Check the default unset took effect
    testing.eq(out, "aunset")
end)

testing.test(
    "open_nofollow, fstat and read_fd read a regular file through one descriptor",
    function()
        -- Open a file and stat it through one descriptor
        local dir = support.tempdir()
        assert(fs.write(dir .. "/f", "hello world"))
        local fd = assert(fs.open_nofollow(dir .. "/f"))
        local stat = assert(fs.fstat(fd))

        -- Check the stat names a regular file of this user
        testing.eq(stat.kind, "file")
        testing.eq(stat.size, 11)
        testing.eq(stat.uid, tonumber((dev_os.capture({ "id", "-u" }))))

        -- Read the file in two parts through the same descriptor
        testing.eq(fs.read_fd(fd, 5), "hello")
        testing.eq(fs.read_fd(fd, 100), " world")

        -- Close the descriptor and remove the directory
        fs.close(fd)
        fs.remove(dir, { recursive = true })
    end
)

testing.test("open_nofollow refuses a symbolic link and a missing file", function()
    -- Link to a real file
    local dir = support.tempdir()
    assert(fs.write(dir .. "/real", "x"))
    assert(fs.symlink(dir .. "/real", dir .. "/link"))

    -- Check the link is refused with a message
    local fd, message = fs.open_nofollow(dir .. "/link")
    testing.eq(fd, nil)
    testing.ok(type(message) == "string" and message ~= "", "expected a message")

    -- Check a missing file is refused
    testing.eq((fs.open_nofollow(dir .. "/missing")), nil)

    -- Remove the directory
    fs.remove(dir, { recursive = true })
end)

testing.test("fstat names a directory and a FIFO, and opening a FIFO does not block", function()
    -- Make a directory and a FIFO
    local dir = support.tempdir()
    assert(fs.mkdir(dir .. "/d"))
    assert(dev_os.run({ "mkfifo", dir .. "/p" }) == 0, "mkfifo failed")

    -- Open and stat the directory
    local fd = assert(fs.open_nofollow(dir .. "/d"))
    testing.eq(fs.fstat(fd).kind, "dir")
    fs.close(fd)

    -- Open and stat the FIFO without blocking
    fd = assert(fs.open_nofollow(dir .. "/p"))
    testing.eq(fs.fstat(fd).kind, "other")
    fs.close(fd)

    -- Remove the directory
    fs.remove(dir, { recursive = true })
end)

testing.test("open_nofollow refuses a path with a NUL byte", function()
    testing.eq((fs.open_nofollow("/tmp/a\0b")), nil)
end)

testing.test("capture_timed collects output and the exit code with no stdin", function()
    local out, code = dev_os.capture_timed({ "sh", "-c", "cat; echo out; exit 3" }, 10)
    testing.eq(out, "out\n")
    testing.eq(code, 3)
    out = dev_os.capture_timed({ "sh", "-c", "echo out; echo err >&2" }, 10, { merge = true })
    testing.eq(out, "out\nerr\n")
end)

testing.test("capture_timed hands output to on_text while the command runs", function()
    -- Prepare a directory for the command's marker and a list for the chunks
    local dir = support.tempdir()
    local chunks = {}

    -- Run a command that waits for a marker the callback writes
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

    -- Check the output arrived in pieces before the command ended
    testing.eq(code, 0)
    testing.eq(out, "first\nsecond\n")
    testing.eq(table.concat(chunks), out)
    testing.ok(#chunks >= 2, "the first line should arrive before the command ends")
end)

testing.test(
    "capture_timed leaves no defunct child under this process while the command runs",
    function()
        -- List the defunct children of this process
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

        -- Look for defunct children from inside a running command's callback
        dev_os.capture_timed({ "sh", "-c", "echo go; sleep 2" }, 30, {
            on_text = function()
                dev_os.nap(1)
                zombies = defunct()
            end,
        })

        -- Check none was found
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
    -- Pick sleep lengths no other process shares
    local started = os.time()
    local pid = dev_os.capture({ "sh", "-c", "echo $$" }):match("%d+")
    local unique_secs = 1000000 + 2 * tonumber(pid)
    local first, second = unique_secs, unique_secs + 1

    -- Run a command with two sleeping children past a one-second limit
    local out, code = dev_os.capture_timed({
        "sh",
        "-c",
        ("echo before; sleep %d >/dev/null 2>&1 & sleep %d >/dev/null 2>&1; wait"):format(
            first,
            second
        ),
    }, 1, { merge = true })

    -- Check the limit stopped it promptly
    testing.eq(code, 124)
    testing.eq(out, "before\n")
    testing.ok(os.time() - started < 30, "the limit should not take long")

    -- Check no child outlived it
    local left = left_running(("^sleep (%d|%d)$"):format(first, second))
    testing.eq(left, "")
end)

testing.test("capture_timed with reap kills what a finished command left running", function()
    -- Pick a sleep length no other process shares
    local pid = dev_os.capture({ "sh", "-c", "echo $$" }):match("%d+")
    local unique_secs = 1000000 + 4 * tonumber(pid)

    -- Run a command that exits and leaves a sleeper running
    local out, code = dev_os.capture_timed(
        { "sh", "-c", ("sleep %d & echo done"):format(unique_secs) },
        10,
        { merge = true, reap = true }
    )

    -- Check the command finished normally
    testing.eq(code, 0)
    testing.eq(out, "done\n")

    -- Check the sleeper was killed
    local left = left_running(("^sleep %d$"):format(unique_secs))
    testing.eq(left, "")
end)

testing.test("capture_timed survives a watcher that ended before its release", function()
    -- Have the command kill the watcher that leads its group and wait until it is defunct
    local command = 'w=$(ps -o pgid= -p $$ | tr -d " "); [ "$w" != "$$" ] || exit 3; '
        .. 'kill -KILL "$w"; until ps -o stat= -p "$w" | grep -q Z; do sleep 0.05; done; '
        .. "echo done"

    -- Run it in a dev whose failed exec left SIGPIPE at its default
    local snippet = "local dev_os = require('@dev/os'); dev_os.exec({ 'no-such-tool-xyz' }); "
        .. ("local out, code = dev_os.capture_timed({ 'sh', '-c', %q }, 10); "):format(command)
        .. "dev_os.stdout:write(out, code)"
    local out, code = dev_os.capture(support.eval(snippet))

    -- Check dev returned the command's output and status
    testing.eq(code, 0)
    testing.eq(out, "done\n0")
end)

testing.test("capture_timed reports a command killed by a signal as 124", function()
    local _, code = dev_os.capture_timed({ "sh", "-c", "exec kill -TERM $$" }, 10)
    testing.eq(code, 124)
end)

local CAPTURE_TIMED_LIMIT_SECS = 600

local function launch_capture_timed(command, tmp)
    local snippet = ("require('@dev/os').capture_timed({ 'sh', '-c', %q }, %d)"):format(
        command,
        CAPTURE_TIMED_LIMIT_SECS
    )
    local pid = dev_os.capture({
        "sh",
        "-c",
        [[TMPDIR="$3" "$1" -l "$2" </dev/null >/dev/null 2>&1 & echo $!]],
        "sh",
        runtime.exe,
        support.script(snippet),
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
    -- Launch a command with two sleeping children in a private temporary directory
    local first = unique_secs(factor)
    local second = first + 1
    local tmp = assert(fs.mktemp({ dir = true }))
    local pid = launch_capture_timed(("sleep %d & sleep %d; wait"):format(first, second), tmp)

    -- Wait until the command is running
    testing.ok(
        wait_until(function()
            return process_listed("sleep " .. first)
        end),
        "the command should be running"
    )

    -- Signal the launcher and wait for the children and the directory to go
    dev_os.run({ "kill", signal, pid })
    local gone = wait_until(function()
        return not process_listed("sleep " .. first) and not process_listed("sleep " .. second)
    end)
    local removed = wait_until(function()
        return dir_empty(tmp)
    end)

    -- Remove the directory and check the cleanup happened
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

local function children_of(marker)
    -- List every process with its parent
    local out = dev_os.capture({ "sh", "-c", "ps -axo pid=,ppid=,args=" })
    local owners, found = {}, {}
    local rows = {}

    -- Collect every process row and the shells that own the marker
    for pid, ppid, args in out:gmatch("(%d+)%s+(%d+)%s+([^\n]*)") do
        rows[#rows + 1] = { pid = pid, ppid = ppid, args = args }
        if args:find("^sh %-c") and args:find(marker, 1, true) then
            owners[pid] = true
        end
    end

    -- Keep the children of those shells that are not the marker itself
    for _, row in ipairs(rows) do
        if owners[row.ppid] and not row.args:find(marker, 1, true) then
            found[#found + 1] = row.args
        end
    end

    -- Report the children and whether any owner was seen
    return found, next(owners) ~= nil
end

testing.test("capture_timed starts no process while its command runs", function()
    -- Launch a command that sleeps under a marker
    local tmp = assert(fs.mktemp({ dir = true }))
    local marker = "sleep " .. unique_secs(10)
    local pid = launch_capture_timed(marker .. "; :", tmp)

    -- Wait until the command is running
    testing.ok(
        wait_until(function()
            return process_listed(marker)
        end),
        "the command should be running"
    )

    -- Watch its owner for any child process while it runs
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

    -- Stop the command and remove its directory
    dev_os.run({ "kill", "-KILL", pid }, { stderr = "null" })
    wait_until(function()
        return not process_listed(marker)
    end)
    fs.remove(tmp, { recursive = true })

    -- Check the owner was seen and had no children
    testing.ok(saw_owner, "the probe should see the command's owner row")
    testing.eq(table.concat(seen, "\n"), "")
end)

local function capture_timed_in(tmp, body, bin)
    -- Build the script and an env with the private temporary directory
    local snippet = "local dev_os = require('@dev/os'); " .. body
    local env = { TMPDIR = tmp }

    -- Put the stub directory first on the path when given one
    if bin then
        env.PATH = bin .. ":" .. dev_os.getenv("PATH")
    end

    -- Run the script in that env
    return dev_os.capture(support.eval(snippet), { env = env })
end

local function timed_dirs_gone(tmp)
    return wait_until(function()
        return dev_os.capture({ "ls", tmp }) == ""
    end)
end

local function stderr_of_capture_timed(body)
    local snippet = "local dev_os = require('@dev/os'); " .. body
    return dev_os.capture({
        "sh",
        "-c",
        [["$1" -l "$2" 2>&1 >/dev/null </dev/null]],
        "sh",
        runtime.exe,
        support.script(snippet),
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
    -- Write a script that counts defunct children after a run
    local body = "dev_os.capture_timed({ 'true' }, 10); "
        .. "local mine = tostring(dev_os.getpid()); local n = 0; "
        .. "for ppid, stat in dev_os.capture({ 'ps', '-A', '-o', 'ppid=,stat=' })"
        .. ":gmatch('(%d+)%s+(%S+)') do "
        .. "if ppid == mine and stat:sub(1, 1) == 'Z' then n = n + 1 end end; "
        .. "dev_os.stdout:write(n)"

    -- Run it in a private temporary directory, then remove the directory
    local tmp = assert(fs.mktemp({ dir = true }))
    local got = capture_timed_in(tmp, body)
    fs.remove(tmp, { recursive = true })

    -- Check no defunct child was left
    testing.eq(got, "0")
end)

testing.test("capture_timed leaves no temporary directory after a normal return", function()
    -- Give the run a private temporary directory so only its own directories show
    local tmp = assert(fs.mktemp({ dir = true }))

    -- Run a command that returns normally
    local out =
        capture_timed_in(tmp, "dev_os.stdout:write((dev_os.capture_timed({ 'echo', 'done' }, 10)))")
    local gone = timed_dirs_gone(tmp)
    fs.remove(tmp, { recursive = true })

    -- Check the output and that the directory is gone
    testing.eq(out, "done\n")
    testing.ok(gone, "the temporary directory should be removed")
end)

testing.test("capture_timed returns 127 and no output for a program that is missing", function()
    local out, code = dev_os.capture_timed({ "dev-no-such-program" }, 10)
    testing.eq(out, "")
    testing.eq(code, 127)
end)

testing.test("capture_timed with no seconds sets no limit and runs to completion", function()
    local started = os.time()
    local out, code = dev_os.capture_timed({ "sh", "-c", "sleep 2; echo done" }, 0)
    testing.eq(out, "done\n")
    testing.eq(code, 0)
    testing.ok(os.time() - started >= 2, "the command should have been waited for")
end)

local function command(body)
    return table.concat({
        'local dev_command = require("@dev/command")',
        "return dev_command({",
        '    summary = "Register a cleanup.",',
        "    run = function()",
        (body:gsub("\n$", "")),
        "    end,",
        "})",
        "",
    }, "\n")
end

local function cleanup_project(source)
    local root = support.sandbox({ [".dev/commands/term.luau"] = command(source) }, {})
    assert(dev_os.run({ "chmod", "755", root .. "/.dev/commands/term.luau" }) == 0, "chmod failed")
    return root
end

local SURVIVE_SCRIPT = table.concat({
    'cd "$1" || exit 97',
    "trap '' HUP",
    '"$2" term >"$1/out" 2>&1 &',
    "pid=$!",
    "i=0",
    'while [ ! -e "$1/ready" ] && [ "$i" -lt "$3" ]; do sleep $4; i=$((i + 1)); done',
    'if [ ! -e "$1/ready" ]; then kill -KILL "$pid"; wait "$pid"; exit 99; fi',
    'kill -HUP "$pid"',
    "sleep 1",
    'if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; exit 96; fi',
    'kill -TERM "$pid"',
    "i=0",
    'while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "$3" ]; do sleep $4; i=$((i + 1)); done',
    'if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid"; wait "$pid"; exit 98; fi',
    'wait "$pid"',
    "",
}, "\n")
local function child_env(root)
    return { CLEANUP_DIR = root, DEV_SELF = runtime.exe }
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
        runtime.exe,
        tostring(WAIT_TICKS),
        WAIT_POLL_SECS,
    }, { env = child_env(root) })
    return code
end

testing.test("a command killed by SIGTERM runs its cleanup once and exits 143", function()
    -- Set up a command that registers a cleanup and waits
    local root = cleanup_project(WAIT_COMMAND)

    -- Signal it and check its exit and the cleanup it ran
    testing.eq(kill_child(root, "TERM"), 143)
    testing.eq(ran(root), "cleanup\n")

    -- Remove the sandbox
    fs.remove(root, { recursive = true })
end)

testing.test("a command killed by SIGHUP runs its cleanup once and exits 129", function()
    -- Set up a command that registers a cleanup and waits
    local root = cleanup_project(WAIT_COMMAND)

    -- Signal it and check its exit and the cleanup it ran
    testing.eq(kill_child(root, "HUP"), 129)
    testing.eq(ran(root), "cleanup\n")

    -- Remove the sandbox
    fs.remove(root, { recursive = true })
end)

testing.test("a command interrupted by SIGINT runs its cleanup once and exits 130", function()
    -- Set up a command that registers a cleanup and waits
    local root = cleanup_project(WAIT_COMMAND)

    -- Signal it and check its exit and the cleanup it ran
    testing.eq(kill_child(root, "INT"), 130)
    testing.eq(ran(root), "cleanup\n")

    -- Remove the sandbox
    fs.remove(root, { recursive = true })
end)

testing.test("a nohup'd command survives SIGHUP and still stops on SIGTERM", function()
    -- Skip hosts without a procfs
    if not fs.exists("/proc/self/status") then
        return
    end

    -- Set up a command that registers a cleanup and waits
    local root = cleanup_project(WAIT_COMMAND)

    -- Hang it up, then terminate it
    local code = dev_os.run({
        "sh",
        "-c",
        SURVIVE_SCRIPT,
        "sh",
        root,
        runtime.exe,
        tostring(WAIT_TICKS),
        WAIT_POLL_SECS,
    }, { env = child_env(root) })

    -- Check its exit and the cleanup it ran
    testing.eq(code, 143)
    testing.eq(ran(root), "cleanup\n")

    -- Remove the sandbox
    fs.remove(root, { recursive = true })
end)

testing.test("a Lua error runs the cleanup once", function()
    -- Set up a command that registers a cleanup, then raises
    local root = cleanup_project(CLEANUP_COMMAND .. 'error("boom")\n')

    -- Run it
    local _, code = dev_os.capture({ runtime.exe, "term" }, {
        cwd = root,
        stderr = "stdout",
        env = child_env(root),
    })

    -- Check it failed and the cleanup ran
    testing.eq(code, 1)
    testing.eq(ran(root), "cleanup\n")

    -- Remove the sandbox
    fs.remove(root, { recursive = true })
end)

testing.test("a normal exit runs the cleanup once", function()
    -- Set up a command that registers a cleanup, then returns 4
    local root = cleanup_project(CLEANUP_COMMAND .. "return 4\n")

    -- Run it
    local out, code = dev_os.capture({ runtime.exe, "term" }, {
        cwd = root,
        stderr = "stdout",
        env = child_env(root),
    })

    -- Check its exit and output and that the cleanup ran
    testing.eq(code, 4)
    testing.eq(out, "")
    testing.eq(ran(root), "cleanup\n")

    -- Remove the sandbox
    fs.remove(root, { recursive = true })
end)

testing.test("cleanups run newest first and one that raises does not stop the rest", function()
    -- Register three cleanups, the middle one raising
    local root = cleanup_project(table.concat({
        "-- Register cleanups.",
        'local dev_os = require("@dev/os")',
        'local dir = dev_os.getenv("CLEANUP_DIR")',
        "local function note(text)",
        '    assert(require("@dev/fs").append(dir .. "/ran", text .. "\\n"))',
        "end",
        "dev_os.on_exit(function()",
        '    note("first")',
        "end)",
        "dev_os.on_exit(function()",
        '    error("bad")',
        "end)",
        "dev_os.on_exit(function()",
        '    note("third")',
        "end)",
        "return 0",
        "",
    }, "\n"))

    -- Run the command to a normal exit
    local _, code = dev_os.capture({ runtime.exe, "term" }, {
        cwd = root,
        stderr = "null",
        env = child_env(root),
    })

    -- Check the exit and that the cleanups ran newest first
    testing.eq(code, 0)
    testing.eq(ran(root), "third\nfirst\n")

    -- Remove the sandbox
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
