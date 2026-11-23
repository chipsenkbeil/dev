local ffi = require("ffi")

local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/main.lua"

local STUB = [[#!/usr/bin/env bash
root=""
if [ "$1" = -C ]; then root="$2"; shift 2; fi
case "$1 ${2:-}" in
"run --list")
    if [ "$3" = --all ]; then
        printf '{"jobs":[{"name":"client","targets":["macos-vm-rust","linux-x86-rust"]}],'
        printf '"pipeline":"%s/.ci/client.lua"}\n' "$root"
        exit 0
    fi
    case "${CI_STUB_JOBS:-}" in
    fail)
        echo "hub unreachable" >&2
        exit 9
        ;;
    bad)
        echo "not json"
        exit 0
        ;;
    empty)
        echo "{}"
        exit 0
        ;;
    array)
        echo "[]"
        exit 0
        ;;
    esac
    if [ "$3" = bootstrap ] || [ "$3" = soak ]; then
        printf '{"jobs":[{"name":"%s"}]}\n' "$3"
    else
        printf '{"jobs":[{"name":"test"},{"name":"widget-save"},{"name":"n-m-x"}]}\n'
    fi
    ;;
run*)
    printf 'ci -C %s' "$root" >>"$STUB_LOG"
    printf ' [%s]' "$@" >>"$STUB_LOG"
    printf '\n' >>"$STUB_LOG"
    printf '%s\n' "${DEV_AGENT:-}" >>"$STUB_LOG.agent"
    case " $* " in
    *" --detach "*) [ "${CI_STUB_RC:-0}" = 0 ] && echo 123abc ;;
    esac
    exit "${CI_STUB_RC:-0}"
    ;;
"ps 123abc")
    printf 'ci -C %s [ps] [%s]\n' "$root" "$3" >>"$STUB_LOG"
    if [ "$3" = --json ]; then
        printf '{"status":"%s","jobs":[{"name":"client","target":"%s","index":2}]}\n' \
            "${CI_STUB_STATUS:-passed}" "${CI_STUB_TARGET:-macos-vm-rust}"
    fi
    ;;
"cp 123abc:"*)
    printf 'ci -C %s [cp] [%s] [%s]\n' "$root" "$2" "${4:+--force}" >>"$STUB_LOG"
    if [ -n "${CI_STUB_PATCH:-}" ]; then
        cp "$CI_STUB_PATCH" "$3/${2##*/}"
    else
        printf 'binary\n' >"$3/${2##*/}"
    fi
    ;;
esac
]]

local function write_exec(path, text)
    assert(fs.mkdir(fs.dirname(path), { parents = true }))
    assert(fs.write(path, text))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function setup(files)
    local base = assert(fs.realpath(support.tempdir()))
    local root = base .. "/p"
    assert(fs.mkdir(root .. "/.dev", { parents = true }))
    assert(fs.mkdir(root .. "/.ci", { parents = true }))
    assert(fs.write(root .. "/.ci/jobs.lua", "return {}\n"))
    write_exec(base .. "/bin/ci", STUB)
    for name, text in pairs(files or {}) do
        write_exec(root .. "/.dev/" .. name, text)
    end
    return root, base
end

local function write_config(base, body)
    assert(fs.mkdir(base .. "/home/.config/dev", { parents = true }))
    assert(fs.write(base .. "/home/.config/dev/config.toml", "[remote]\n" .. body .. "\n"))
end

local function with_empty_home(body)
    local previous = os.getenv("HOME")
    ffi.C.setenv("HOME", support.tempdir(), 1)
    local ok, err = pcall(body)
    ffi.C.setenv("HOME", previous or "", 1)
    assert(ok, err)
end

local function dev_env(base, env)
    local merged = {
        STUB_LOG = base .. "/log",
        PATH = base .. "/bin:" .. os.getenv("PATH"),
        HOME = base .. "/home",
        CI = "",
        DEV_AGENT = "",
        DEV_CI_COMMAND = "",
        DEV_CI_CARD = "",
        DEV_CI_PRIORITY = "",
        DEV_BOX_MARKER = base .. "/no-box",
    }
    for key, value in pairs(env or {}) do
        merged[key] = value
    end
    return merged
end

local function dev(root, base, args, env)
    local argv = { "luajit", MAIN }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    fs.remove(base .. "/log")
    local out, code = dev_os.capture(
        argv,
        { cwd = root, stderr = "stdout", stdin = "null", env = dev_env(base, env) }
    )
    return out, code, fs.read(base .. "/log") or ""
end

testing.test("--remote runs ci with the arguments after -- as separate words", function()
    local root, base = setup()
    local _, code, log = dev(root, base, { "--remote", "test", "--", "a", "b c", "$(x)" })
    testing.eq(code, 0)
    testing.eq(
        log,
        "ci -C " .. root .. " [run] [--local] [--follow] [--job] [test] [--] [a] [b c] [$(x)]\n"
    )
end)

testing.test("--detach replaces --follow and the flag order does not matter", function()
    local root, base = setup()
    local _, _, log = dev(root, base, { "test", "--remote", "--detach" })
    testing.ok(log:find("[--detach] [--job] [test]", 1, true), log)
    testing.ok(not log:find("--follow", 1, true), log)
    _, _, log = dev(root, base, { "test", "--remote" })
    testing.ok(log:find("[--follow] [--job] [test]", 1, true), log)
end)

testing.test("--detach without --remote is a usage error", function()
    local root, base = setup()
    local out, code, log = dev(root, base, { "--detach", "test" })
    testing.eq(code, 2)
    testing.eq(out, "The flag `--detach` needs `--remote`.\n")
    testing.eq(log, "")
end)

testing.test("--priority without --remote is a usage error", function()
    local root, base = setup()
    local out, code, log = dev(root, base, { "--priority", "test" })
    testing.eq(code, 2)
    testing.eq(out, "The flag `--priority` needs `--remote`.\n")
    testing.eq(log, "")
end)

testing.test("--remote --priority puts --priority before the double dash", function()
    local root, base = setup()
    local _, code, log = dev(root, base, { "--remote", "--priority", "test", "--", "-k", "x" })
    testing.eq(code, 0)
    testing.ok(log:find("[--job] [test] [--priority] [--] [-k] [x]", 1, true), log)
    _, code, log = dev(root, base, { "--remote", "test", "--", "-k", "x" })
    testing.eq(code, 0)
    testing.ok(not log:find("--priority", 1, true), log)
end)

testing.test("a parent command and its subcommand are one job named with a hyphen", function()
    local root, base = setup({ ["widget/save.sh"] = "#!/usr/bin/env bash\ntrue\n" })
    local _, _, log = dev(root, base, { "--remote", "widget", "save" })
    testing.ok(log:find("[--job] [widget-save]", 1, true), log)
end)

testing.test("ci's exit code is dev's", function()
    local root, base = setup()
    local _, code = dev(root, base, { "--remote", "test" }, { CI_STUB_RC = "7" })
    testing.eq(code, 7)
end)

testing.test("remote hands arguments given without -- to the job", function()
    local root, base = setup()
    local _, code, log = dev(root, base, { "--remote", "test", "name", "other" })
    testing.eq(code, 0)
    testing.eq(
        log,
        "ci -C " .. root .. " [run] [--local] [--follow] [--job] [test] [--] [name] [other]\n"
    )
end)

testing.test(
    "remote refuses arguments on both sides of -- and prints the working command",
    function()
        local root, base = setup()
        local out, code, log = dev(root, base, { "--remote", "test", "a", "--", "b" })
        testing.eq(code, 2)
        testing.eq(
            out,
            "dev test: --remote takes arguments on one side of -- only. "
                .. "Run `dev --remote test -- a b` instead.\n"
        )
        testing.eq(log, "")
    end
)

testing.test(
    "the both-sides refusal quotes a spaced argument and leaves a plain one bare",
    function()
        local root, base = setup()
        local out, code, log = dev(root, base, { "--remote", "test", "a", "--", "b c", "it's" })
        testing.eq(code, 2)
        testing.eq(
            out,
            "dev test: --remote takes arguments on one side of -- only. "
                .. "Run `dev --remote test -- a 'b c' 'it'\\''s'` instead.\n"
        )
        testing.eq(log, "")
    end
)

testing.test("a command with no job exits 1 and runs nothing", function()
    local root, base = setup()
    local out, code, log = dev(root, base, { "--remote", "build" })
    testing.eq(code, 1)
    testing.ok(
        out:find("No job named build exists in the project's default pipeline", 1, true),
        out
    )
    testing.eq(log, "")
end)

testing.test("a machine-local command is refused with the mockup text", function()
    local root, base = setup()
    for _, words in ipairs({ { "fetch" }, { "box", "ls" }, { "tools", "check" } }) do
        local args = { "--remote" }
        for _, word in ipairs(words) do
            args[#args + 1] = word
        end
        local out, code, log = dev(root, base, args)
        testing.eq(code, 2)
        testing.eq(
            out,
            "dev "
                .. table.concat(words, " ")
                .. ": runs on this machine only, so --remote does not apply\n"
        )
        testing.eq(log, "")
    end
end)

testing.test("DEV_REMOTE counts as --remote", function()
    local root, base = setup()
    local _, _, log = dev(root, base, { "test" }, { DEV_REMOTE = "1" })
    testing.ok(log:find("[--job] [test]", 1, true), log)
    write_config(base, 'default = "local"')
    _, _, log = dev(root, base, { "test" }, { DEV_REMOTE = "0" })
    testing.eq(log, "")
end)

testing.test("with no setting a command with a job runs on ci and --local keeps it here", function()
    local root, base = setup()
    local _, code, log = dev(root, base, { "test", "a", "--", "b" })
    testing.eq(code, 0)
    testing.eq(log, "ci -C " .. root .. " [run] [--local] [--follow] [--job] [test] [--] [a] [b]\n")
    _, _, log = dev(root, base, { "test", "--local" })
    testing.eq(log, "")
    local out, code2 = dev(root, base, { "test", "--local", "--remote" })
    testing.eq(code2, 2)
    testing.eq(out, "The flags `--local` and `--remote` cannot be used together.\n")
end)

testing.test("remote.default local runs here and --remote still goes to ci", function()
    local root, base = setup()
    write_config(base, 'default = "local"')
    local _, _, log = dev(root, base, { "test" })
    testing.eq(log, "")
    _, _, log = dev(root, base, { "test", "--remote" })
    testing.ok(log:find("[--job] [test]", 1, true), log)
end)

testing.test("the user file beats the project file for remote.default", function()
    local root, base = setup()
    assert(fs.write(root .. "/.dev/config.toml", '[remote]\ndefault = "local"\n'))
    local _, _, log = dev(root, base, { "test" })
    testing.eq(log, "")
    write_config(base, 'default = "remote"')
    _, _, log = dev(root, base, { "test" })
    testing.ok(log:find("[--job] [test]", 1, true), log)
end)

testing.test("a bad remote.default is one line and exit 1", function()
    local root, base = setup()
    write_config(base, 'default = "far"')
    local out, code = dev(root, base, { "test" })
    testing.eq(code, 1)
    testing.ok(
        out:find('The `remote.default` setting must be "remote" or "local", not far.', 1, true),
        out
    )
end)

testing.test("CI=true or a box marker runs here, whatever the flags and default", function()
    local root, base = setup()
    local _, _, log = dev(root, base, { "test" }, { CI = "true" })
    testing.eq(log, "")
    _, _, log = dev(root, base, { "test", "--remote" }, { CI = "true" })
    testing.eq(log, "")
    assert(fs.write(base .. "/box", "name=x\n"))
    _, _, log = dev(root, base, { "test", "--remote" }, { DEV_BOX_MARKER = base .. "/box" })
    testing.eq(log, "")
end)

testing.test(
    "commands without a job and machine-local commands run here under the default",
    function()
        local root, base = setup({ ["hello.sh"] = "#!/usr/bin/env bash\necho hi\n" })
        local out, code, log = dev(root, base, { "hello" })
        testing.eq(out, "hi\n")
        testing.eq(code, 0)
        testing.eq(log, "")
        out, code, log = dev(root, base, { "board", "status" })
        testing.eq(log, "")
        testing.eq(out, "This project has no board.\n")
        testing.eq(code, 1)
    end
)

testing.test("without ci on PATH the default fails with the --local hint", function()
    local root, base = setup({ ["hello.sh"] = "#!/usr/bin/env bash\necho hi\n" })
    assert(fs.mkdir(base .. "/lj"))
    assert(
        dev_os.run({ "ln", "-s", dev_os.which("luajit"), base .. "/lj/luajit" }) == 0,
        "ln failed"
    )
    local env = { PATH = base .. "/lj:/usr/bin:/bin" }
    local out, code = dev(root, base, { "hello" }, env)
    testing.eq(code, 1)
    testing.eq(out, "The ci client is not on PATH. Rerun it, or pass `--local` to run it here.\n")
    out, code = dev(root, base, { "test", "--remote" }, env)
    testing.eq(code, 1)
    testing.ok(out:find("The ci client is not found", 1, true), out)
    out, code = dev(root, base, { "hello", "--local" }, { PATH = env.PATH })
    testing.eq(out, "hi\n")
    testing.eq(code, 0)
    out, code = dev(root, base, { "hello" }, { PATH = env.PATH, CI = "true" })
    testing.eq(out, "hi\n")
    testing.eq(code, 0)
    out = dev(root, base, { "hello" }, { PATH = env.PATH, DEV_REMOTE = "0" })
    testing.eq(out, "hi\n")
    write_config(base, 'default = "local"')
    out = dev(root, base, { "hello" }, env)
    testing.eq(out, "hi\n")
end)

testing.test(
    "a failing ci run --list under the default fails with ci's error and the hint",
    function()
        local root, base = setup({ ["hello.sh"] = "#!/usr/bin/env bash\necho hi\n" })
        local out, code, log = dev(root, base, { "hello" }, { CI_STUB_JOBS = "fail" })
        testing.eq(code, 9)
        testing.eq(
            out,
            "The command `ci run --list` failed. The error was: hub unreachable. Rerun it, or pass `--local` to run it here.\n"
        )
        testing.eq(log, "")
        out, code = dev(root, base, { "hello", "--local" }, { CI_STUB_JOBS = "fail" })
        testing.eq(out, "hi\n")
        testing.eq(code, 0)
    end
)

testing.test("a project with no pipeline file runs here without calling ci", function()
    local root, base = setup({ ["hello.sh"] = "#!/usr/bin/env bash\necho hi\n" })
    assert(dev_os.run({ "rm", "-rf", root .. "/.ci" }) == 0, "rm failed")
    local out, code = dev(root, base, { "hello" }, { CI_STUB_JOBS = "fail" })
    testing.eq(out, "hi\n")
    testing.eq(code, 0)
end)

testing.test(
    "a __remote.lua runner gets the words, args, detach and root and its integer is the exit code",
    function()
        local root, base = setup({
            ["__remote.lua"] = [[return function(run)
    io.write(table.concat(run.words, " "), "|", table.concat(run.args, ","), "|", tostring(run.detach), "|", run.root, "\n")
    return 5
end
]],
        })
        local out, code, log = dev(root, base, { "--remote", "test", "--", "a", "b c" })
        testing.eq(code, 5)
        testing.eq(out, "test|a,b c|false|" .. root .. "\n")
        testing.eq(log, "")
        out = dev(root, base, { "--remote", "--detach", "test" })
        testing.eq(out, "test||true|" .. root .. "\n")
    end
)

testing.test(
    "a __remote.lua that errors or returns no function ends with one line and exit 1",
    function()
        local root, base = setup({ ["__remote.lua"] = "return 3\n" })
        local out, code = dev(root, base, { "--remote", "test" })
        testing.eq(code, 1)
        testing.ok(out:find(" must return a function.", 1, true), out)
        write_exec(root .. "/.dev/__remote.lua", "return function() error('nope', 0) end\n")
        out, code = dev(root, base, { "--remote", "test" })
        testing.eq(code, 1)
        testing.eq(out, "nope\n")
    end
)

testing.test(
    "a failing ci run --list is reported with ci's exit code, not as a missing job",
    function()
        local root, base = setup()
        local out, code, log = dev(root, base, { "--remote", "test" }, { CI_STUB_JOBS = "fail" })
        testing.eq(code, 9)
        testing.eq(out, "The command `ci run --list` failed. The error was: hub unreachable.\n")
        testing.eq(log, "")
        out, code, log = dev(root, base, { "--remote", "test" }, { CI_STUB_JOBS = "bad" })
        testing.eq(code, 1)
        testing.ok(out:find("The command `ci run --list` failed.", 1, true), out)
        testing.ok(not out:find("No job named", 1, true), out)
        testing.eq(log, "")
        for _, mode in ipairs({ "empty", "array" }) do
            out, code, log = dev(root, base, { "--remote", "test" }, { CI_STUB_JOBS = mode })
            testing.eq(code, 1)
            testing.eq(out, "The command `ci run --list` failed.\n")
            testing.eq(log, "")
        end
    end
)

testing.test("an unreadable __remote.lua ends with one line and exit 1", function()
    local root, base = setup({ ["__remote.lua"] = "return function() return 0 end\n" })
    assert(dev_os.run({ "chmod", "000", root .. "/.dev/__remote.lua" }) == 0, "chmod failed")
    local out, code = dev(root, base, { "--remote", "test" })
    dev_os.run({ "chmod", "644", root .. "/.dev/__remote.lua" })
    if dev_os.capture({ "id", "-u" }) == "0" then
        return
    end
    testing.eq(code, 1)
    testing.ok(out:find("The file " .. root .. "/.dev/__remote.lua cannot be read", 1, true), out)
    testing.ok(not out:find("traceback", 1, true), out)
end)

testing.test("a __remote.lua that returns a non-integer ends with one line and exit 1", function()
    local root, base = setup()
    for _, value in ipairs({ "2.5", '"x"' }) do
        write_exec(root .. "/.dev/__remote.lua", "return function() return " .. value .. " end\n")
        local out, code = dev(root, base, { "--remote", "test" })
        testing.eq(code, 1)
        testing.eq(
            out,
            "The file "
                .. root
                .. "/.dev/__remote.lua returned "
                .. value:gsub('"', "")
                .. ", not an exit code.\n"
        )
    end
end)

testing.test("-- before the command or parent command still names the job", function()
    local root, base = setup({ ["widget/save.sh"] = "#!/usr/bin/env bash\ntrue\n" })
    local _, code, log = dev(root, base, { "--remote", "--", "test", "a" })
    testing.eq(code, 0)
    testing.eq(log, "ci -C " .. root .. " [run] [--local] [--follow] [--job] [test] [--] [a]\n")
    _, code, log = dev(root, base, { "--remote", "--", "widget", "save" })
    testing.eq(code, 0)
    testing.ok(log:find("[--job] [widget-save] [--]", 1, true), log)
    _, code, log = dev(root, base, { "--remote", "widget", "--", "save" })
    testing.ok(log:find("[--job] [widget-save] [--]", 1, true), log)
end)

testing.test("-- before a machine-local parent command is still refused", function()
    local root, base = setup()
    local out, code, log = dev(root, base, { "--remote", "--", "box", "ls" })
    testing.eq(code, 2)
    testing.eq(out, "dev box ls: runs on this machine only, so --remote does not apply\n")
    testing.eq(log, "")
end)

testing.test("-v prints the ci argv to stderr", function()
    local root, base = setup()
    local out, code = dev(root, base, { "-v", "--remote", "test", "--", "a" })
    testing.eq(code, 0)
    testing.ok(
        out:find("+ ci -C " .. root .. " run --local --follow --job test -- a\n", 1, true),
        out
    )
end)

testing.test("arguments after -- reach the job untouched", function()
    local root, base = setup()
    local _, _, log = dev(root, base, { "--remote", "test", "--", "--anything" })
    testing.ok(log:find("[--] [--anything]", 1, true), log)
end)

testing.test("the project's __remote.lua sends soak to the soak pipeline", function()
    local override = assert(fs.read(REPO .. "/.dev/__remote.lua"))
    local root, base = setup({ ["__remote.lua"] = override })
    local _, code, log = dev(root, base, { "--remote", "soak", "--", "--runs", "5" })
    testing.eq(code, 0)
    testing.eq(
        log,
        "ci -C " .. root .. " [run] [soak] [--local] [--follow] [--job] [soak] [--] [--runs] [5]\n"
    )
    _, code, log = dev(root, base, { "--remote", "--detach", "soak" })
    testing.eq(code, 0)
    testing.eq(log, "ci -C " .. root .. " [run] [soak] [--local] [--detach] [--job] [soak] [--]\n")
end)

testing.test(
    "the project's __remote.lua sends every other command to the default pipeline",
    function()
        local override = assert(fs.read(REPO .. "/.dev/__remote.lua"))
        local root, base = setup({ ["__remote.lua"] = override })
        local _, code, log = dev(root, base, { "--remote", "test", "--", "x" })
        testing.eq(code, 0)
        testing.eq(log, "ci -C " .. root .. " [run] [--local] [--follow] [--job] [test] [--] [x]\n")
    end
)

testing.test("the project's __remote.lua keeps the default runner's job-not-found error", function()
    local override = assert(fs.read(REPO .. "/.dev/__remote.lua"))
    local root, base = setup({ ["__remote.lua"] = override })
    local out, code, log = dev(root, base, { "--remote", "lint" })
    testing.eq(code, 1)
    testing.ok(out:find("No job named lint exists in the project's default pipeline", 1, true), out)
    testing.eq(log, "")
end)

testing.test("the project's __remote.lua keeps -v and -vv for the ci echo", function()
    local override = assert(fs.read(REPO .. "/.dev/__remote.lua"))
    local root, base = setup({ ["__remote.lua"] = override })
    for _, flag in ipairs({ "-v", "-vv" }) do
        local out = dev(root, base, { flag, "--remote", "soak" })
        testing.ok(
            out:find("+ ci -C " .. root .. " run soak --local --follow --job soak --\n", 1, true),
            out
        )
        out = dev(root, base, { flag, "--remote", "test" })
        testing.ok(
            out:find("+ ci -C " .. root .. " run --local --follow --job test --\n", 1, true),
            out
        )
    end
    local out = dev(root, base, { "--remote", "test" })
    testing.ok(not out:find("+ ci", 1, true), out)
end)

testing.test(
    "a parent command nested two deep is one job with a hyphen between each word",
    function()
        local root, base = setup({ ["n/m/x.sh"] = "#!/usr/bin/env bash\ntrue\n" })
        local _, code, log = dev(root, base, { "--remote", "n", "m", "x" })
        testing.eq(code, 0)
        testing.ok(log:find("[--job] [n-m-x]", 1, true), log)
    end
)

testing.test("DEV_REMOTE=0 runs here under the default and --remote still wins", function()
    local root, base = setup()
    local _, _, log = dev(root, base, { "test" }, { DEV_REMOTE = "0" })
    testing.eq(log, "")
    _, _, log = dev(root, base, { "test", "--remote" }, { DEV_REMOTE = "0" })
    testing.ok(log:find("[--job] [test]", 1, true), log)
end)

testing.test(
    "a # local header keeps a command with a same-named job here until --remote",
    function()
        local root, base = setup({
            ["test.sh"] = "#!/usr/bin/env bash\n# Run the tests.\n# local\necho ran-local\n",
        })
        local out, code, log = dev(root, base, { "test" })
        testing.eq(out, "ran-local\n")
        testing.eq(code, 0)
        testing.eq(log, "")
        _, _, log = dev(root, base, { "test", "--remote" })
        testing.ok(log:find("[--job] [test]", 1, true), log)
        out = dev(root, base, { "help", "test" })
        testing.ok(out:find("runs here under the remote default", 1, true), out)
        testing.ok(not out:find("# local", 1, true), out)
    end
)

testing.test("a command script without # local keeps routing to its job", function()
    local root, base =
        setup({ ["test.sh"] = "#!/usr/bin/env bash\n# Run the tests.\necho ran-local\n" })
    local out, _, log = dev(root, base, { "test" })
    testing.eq(out, "")
    testing.ok(log:find("[--job] [test]", 1, true), log)
end)

testing.test(
    "# local also works in a Lua header and a parent command subcommand, and shows under -h",
    function()
        local root, base = setup({
            ["widget/save.lua"] = "--[[\nSave it.\nlocal\n]]\nprint('ran-lua')\n",
        })
        local out, code, log = dev(root, base, { "widget", "save" })
        testing.eq(out, "ran-lua\n")
        testing.eq(code, 0)
        testing.eq(log, "")
        out = dev(root, base, { "widget", "save", "-h" })
        testing.ok(out:find("runs here under the remote default", 1, true), out)
    end
)

testing.test("--remote ci run label is repo/remote when DEV_AGENT is unset", function()
    local root, base = setup()
    local _, code = dev(root, base, { "--remote", "test" })
    testing.eq(code, 0)
    testing.eq(fs.read(base .. "/log.agent"), "p/remote\n")
end)

testing.test("--remote ci run label takes DEV_CI_COMMAND and DEV_CI_CARD", function()
    local root, base = setup()
    local _, code = dev(
        root,
        base,
        { "--remote", "test" },
        { DEV_CI_COMMAND = "land", DEV_CI_CARD = "d9f0e004" }
    )
    testing.eq(code, 0)
    testing.eq(fs.read(base .. "/log.agent"), "p/land/d9f0e004\n")
    fs.remove(base .. "/log.agent")
    _, code = dev(root, base, { "--remote", "test" }, { DEV_CI_COMMAND = "release" })
    testing.eq(code, 0)
    testing.eq(fs.read(base .. "/log.agent"), "p/release\n")
end)

testing.test("--remote passes --priority to ci run only when DEV_CI_PRIORITY is 1", function()
    local root, base = setup()
    local _, code, log = dev(root, base, { "--remote", "test" })
    testing.eq(code, 0)
    testing.ok(not log:find("--priority", 1, true), log)
    _, code, log = dev(root, base, { "--remote", "test" }, { DEV_CI_PRIORITY = "1" })
    testing.eq(code, 0)
    testing.ok(log:find("[--job] [test] [--priority] [--]", 1, true), log)
end)

testing.test("a word holding a dot or an underscore is not a job", function()
    local remote = require("dev.remote")
    local root = setup()
    testing.eq(remote.has_default_job(root, { "a.b" }), false)
    testing.eq(remote.has_default_job(root, { "widget", "save_it" }), false)
end)

testing.test("run label is unset for a bare run in a terminal", function()
    local remote = require("dev.remote")
    local root = setup()
    with_empty_home(function()
        local terminal = { tty = true }
        testing.eq(remote.run_label(root, {}, terminal), nil)
        testing.eq(remote.run_label(root, { DEV_AGENT = "", DEV_CI_COMMAND = "" }, terminal), nil)
        testing.eq(remote.run_label(root, { DEV_CI_CARD = "d9f0e004" }, terminal), nil)
    end)
end)

testing.test("run label keeps check and release labels in a terminal", function()
    local remote = require("dev.remote")
    local root = setup()
    with_empty_home(function()
        local check = { DEV_CI_COMMAND = remote.Verb.CHECK, DEV_CI_CARD = "d9f0e004" }
        local terminal, piped = { tty = true }, { tty = false }
        testing.eq(remote.run_label(root, check, terminal), "p/check/d9f0e004")
        local release = "release"
        testing.eq(remote.run_label(root, { DEV_CI_COMMAND = release }, terminal), "p/" .. release)
        testing.eq(remote.run_label(root, {}, piped), "p/remote")
        local agent = { DEV_AGENT = "dotfiles/implementer/x/1" }
        testing.eq(remote.run_label(root, agent, piped), nil)
        testing.eq(remote.run_label(root, agent, terminal), nil)
    end)
end)

testing.test("run label names a check run even under an agent DEV_AGENT", function()
    local remote = require("dev.remote")
    local root = setup()
    with_empty_home(function()
        local agent = "dotfiles/implementer/d9f0e004"
        local check =
            { DEV_AGENT = agent, DEV_CI_COMMAND = remote.Verb.CHECK, DEV_CI_CARD = "d9f0e004" }
        testing.eq(remote.run_label(root, check, { tty = false }), "p/check/d9f0e004")
        testing.eq(remote.run_label(root, check, { tty = true }), "p/check/d9f0e004")
        testing.eq(remote.run_label(root, { DEV_AGENT = agent }, { tty = false }), nil)
    end)
end)

testing.test("--remote ci run label is unset when run from a real terminal", function()
    local root, base = setup()
    if dev_os.name() ~= "Linux" then
        error("the terminal run needs util-linux script, so it runs on Linux only")
    end
    local argv = { "luajit", MAIN, "--remote", "test" }
    local _, code = dev_os.capture(
        { "script", "-qec", dev_os.command(argv), "/dev/null" },
        { cwd = root, stderr = "stdout", env = dev_env(base) }
    )
    testing.eq(code, 0)
    testing.eq(fs.read(base .. "/log.agent"), "\n")
end)

local FETCH_VERB = [[#!/usr/bin/env bash
# Show the file ci built.
# fetch client ci
echo "fetched=${DEV_FETCHED:-none}"
[ -z "${DEV_FETCHED:-}" ] || cat "$DEV_FETCHED"
]]

local function fetch_setup()
    local root, base = setup({ ["show.sh"] = FETCH_VERB })
    write_exec(base .. "/bin/uname", '#!/usr/bin/env bash\necho "${UNAME_STUB:-Darwin arm64}"\n')
    return root, base
end

local FETCH_LOG = "ci -C %s [run] [client] [--local] [--detach] [--job] [client:%s] [--arch] [%s]\n"
    .. "ci -C %s [ps] [-w]\n"
    .. "ci -C %s [ps] [--json]\n"
    .. "ci -C %s [cp] [123abc:client.2.%s/ci] [--force]\n"

testing.test(
    "a fetch command run remote runs here with the pulled file for this platform",
    function()
        local root, base = fetch_setup()
        local expected =
            FETCH_LOG:format(root, "macos-vm-rust", "aarch64", root, root, root, "macos-vm-rust")
        for _, args in ipairs({ { "show" }, { "--remote", "show" } }) do
            local out, code, log = dev(root, base, args)
            testing.eq(code, 0, out)
            testing.ok(out:find("fetched=/", 1, true), out)
            testing.ok(out:find("binary", 1, true), out)
            testing.eq(log, expected)
        end
    end
)

testing.test("a fetch command picks the target for this host's OS and architecture", function()
    local root, base = fetch_setup()
    local out, code, log = dev(
        root,
        base,
        { "show" },
        { UNAME_STUB = "Linux x86_64", CI_STUB_TARGET = "linux-x86-rust" }
    )
    testing.eq(code, 0, out)
    testing.eq(
        log,
        FETCH_LOG:format(root, "linux-x86-rust", "x86_64", root, root, root, "linux-x86-rust")
    )
end)

testing.test("a fetch command under --local or default local runs here with no fetch", function()
    local root, base = fetch_setup()
    local runs = {
        { args = { "--local", "show" }, env = {} },
        { args = { "show" }, env = { DEV_REMOTE = "0" } },
    }
    for _, case in ipairs(runs) do
        local out, code, log = dev(root, base, case.args, case.env)
        testing.eq(code, 0, out)
        testing.eq(out, "fetched=none\n")
        testing.eq(log, "")
    end
    write_config(base, 'default = "local"')
    local out, code, log = dev(root, base, { "show" })
    testing.eq(code, 0, out)
    testing.eq(out, "fetched=none\n")
    testing.eq(log, "")
end)

testing.test("a fetch command on a platform with no target names it and hints --local", function()
    local root, base = fetch_setup()
    local out, code, log = dev(root, base, { "show" }, { UNAME_STUB = "Windows x86_64" })
    testing.eq(code, 1)
    testing.ok(out:find("has no matrix entry for Windows x86_64", 1, true), out)
    testing.ok(out:find("Pass `--local` to build it here.", 1, true), out)
    testing.ok(not log:find("[--detach]", 1, true), log)
end)

testing.test("a fetch command fails and names the run when the job does not pass", function()
    local root, base = fetch_setup()
    local out, code = dev(root, base, { "show" }, { CI_STUB_STATUS = "failed" })
    testing.eq(code, 1)
    testing.ok(out:find("The ci run 123abc of job client did not pass.", 1, true), out)
end)

local PATCH_VERB = [[#!/usr/bin/env bash
# Format the tree.
# patch client fmt.patch
echo "ran-here"
]]

local PATCH_LOG = "ci -C %s [run] [client] [--local] [--detach] [--job] [client:macos-vm-rust]\n"
    .. "ci -C %s [ps] [-w]\n"
    .. "ci -C %s [ps] [--json]\n"
    .. "ci -C %s [cp] [123abc:client.2.macos-vm-rust/fmt.patch] [--force]\n"

local PATCH_TEXT = "--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n-old\n+new\n"

local function patch_setup(patch)
    local root, base = setup({ ["fmt.sh"] = PATCH_VERB })
    assert(fs.write(root .. "/a.txt", "old\n"))
    assert(fs.write(base .. "/patch", patch))
    return root, base, { CI_STUB_PATCH = base .. "/patch" }
end

testing.test(
    "a patch command run remote applies the pulled patch and never runs the script",
    function()
        local root, base, env = patch_setup(PATCH_TEXT)
        local expected = PATCH_LOG:format(root, root, root, root)
        for _, args in ipairs({ { "fmt" }, { "--remote", "fmt" } }) do
            assert(fs.write(root .. "/a.txt", "old\n"))
            local out, code, log = dev(root, base, args, env)
            testing.eq(code, 0, out)
            testing.ok(not out:find("ran-here", 1, true), out)
            testing.eq(fs.read(root .. "/a.txt"), "new\n")
            testing.eq(log, expected)
        end
    end
)

testing.test("a patch command leaves every file untouched on an empty patch", function()
    local root, base, env = patch_setup("")
    local out, code = dev(root, base, { "fmt" }, env)
    testing.eq(code, 0, out)
    testing.ok(out:find("No file changed.", 1, true), out)
    testing.eq(fs.read(root .. "/a.txt"), "old\n")
end)

testing.test(
    "a patch command that does not apply changes nothing and names the run and patch",
    function()
        local first = "--- a/b.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-old\n+new\n"
        local root, base, env = patch_setup(first .. PATCH_TEXT)
        assert(fs.write(root .. "/b.txt", "old\n"))
        assert(fs.write(root .. "/a.txt", "other\n"))
        local out, code = dev(root, base, { "fmt" }, env)
        testing.eq(code, 1)
        testing.ok(out:find("ci run 123abc does not apply", 1, true), out)
        testing.ok(out:find("fmt.patch", 1, true), out)
        testing.eq(fs.read(root .. "/a.txt"), "other\n")
        testing.eq(fs.read(root .. "/b.txt"), "old\n")
    end
)

testing.test("a patch command on a ci job or in a box runs here with no ci call", function()
    local root, base, env = patch_setup(PATCH_TEXT)
    assert(fs.write(base .. "/box", "name=x\n"))
    local marker = { DEV_BOX_MARKER = base .. "/box" }
    for _, extra in ipairs({ { CI = "true" }, marker }) do
        extra.CI_STUB_PATCH = env.CI_STUB_PATCH
        local out, code, log = dev(root, base, { "fmt" }, extra)
        testing.eq(code, 0, out)
        testing.eq(out, "ran-here\n")
        testing.eq(log, "")
    end
end)

testing.test("a patch command shows its help under --remote and applies nothing", function()
    local root, base, env = patch_setup(PATCH_TEXT)
    local out, code, log = dev(root, base, { "--remote", "fmt", "-h" }, env)
    testing.eq(code, 0, out)
    testing.ok(out:find("Format the tree.", 1, true), out)
    testing.eq(log, "")
    testing.eq(fs.read(root .. "/a.txt"), "old\n")
end)

testing.test("a patch command under --local or default local runs here with no ci call", function()
    local root, base, env = patch_setup(PATCH_TEXT)
    local runs = {
        { args = { "--local", "fmt" }, env = env },
        { args = { "fmt" }, env = { DEV_REMOTE = "0", CI_STUB_PATCH = env.CI_STUB_PATCH } },
    }
    for _, case in ipairs(runs) do
        local out, code, log = dev(root, base, case.args, case.env)
        testing.eq(code, 0, out)
        testing.eq(out, "ran-here\n")
        testing.eq(log, "")
    end
    write_config(base, 'default = "local"')
    local out, code, log = dev(root, base, { "fmt" }, env)
    testing.eq(code, 0, out)
    testing.eq(out, "ran-here\n")
    testing.eq(log, "")
    testing.eq(fs.read(root .. "/a.txt"), "old\n")
end)

testing.test("--remote ci run label keeps a caller's DEV_AGENT", function()
    local root, base = setup()
    local _, code = dev(
        root,
        base,
        { "--remote", "test" },
        { DEV_AGENT = "dotfiles/implementer/x/1", DEV_CI_COMMAND = "land" }
    )
    testing.eq(code, 0)
    testing.eq(fs.read(base .. "/log.agent"), "dotfiles/implementer/x/1\n")
end)
