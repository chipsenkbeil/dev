local ffi = require("ffi")

local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/dotfiles/bin/.local/share/dev/main.lua"

local STUB = [[#!/usr/bin/env bash
root=""
if [ "$1" = -C ]; then root="$2"; shift 2; fi
case "$1 ${2:-}" in
"run --list")
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
        printf '{"jobs":[{"name":"test"},{"name":"widget.save"},{"name":"n.m.x"}]}\n'
    fi
    ;;
run*)
    printf 'ci -C %s' "$root" >>"$STUB_LOG"
    printf ' [%s]' "$@" >>"$STUB_LOG"
    printf '\n' >>"$STUB_LOG"
    printf '%s\n' "${DEV_AGENT:-}" >>"$STUB_LOG.agent"
    exit "${CI_STUB_RC:-0}"
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
        DEV_CI_VERB = "",
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

testing.test("a noun and its subcommand are one job named with a dot", function()
    local root, base = setup({ ["widget/save.sh"] = "#!/usr/bin/env bash\ntrue\n" })
    local _, _, log = dev(root, base, { "--remote", "widget", "save" })
    testing.ok(log:find("[--job] [widget.save]", 1, true), log)
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

testing.test("a verb with no job exits 1 and runs nothing", function()
    local root, base = setup()
    local out, code, log = dev(root, base, { "--remote", "build" })
    testing.eq(code, 1)
    testing.ok(
        out:find("No job named build exists in the project's default pipeline", 1, true),
        out
    )
    testing.eq(log, "")
end)

testing.test("a machine-local verb is refused with the mockup text", function()
    local root, base = setup()
    for _, words in ipairs({ { "install" }, { "box", "ls" }, { "tools", "check" } }) do
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

testing.test("commands without a job and machine-local verbs run here under the default", function()
    local root, base = setup({ ["hello.sh"] = "#!/usr/bin/env bash\necho hi\n" })
    local out, code, log = dev(root, base, { "hello" })
    testing.eq(out, "hi\n")
    testing.eq(code, 0)
    testing.eq(log, "")
    out, code, log = dev(root, base, { "board", "status" })
    testing.eq(log, "")
    testing.eq(out, "dev: This project has no board.\n")
    testing.eq(code, 1)
end)

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

testing.test("-- before the verb or noun still names the job", function()
    local root, base = setup({ ["widget/save.sh"] = "#!/usr/bin/env bash\ntrue\n" })
    local _, code, log = dev(root, base, { "--remote", "--", "test", "a" })
    testing.eq(code, 0)
    testing.eq(log, "ci -C " .. root .. " [run] [--local] [--follow] [--job] [test] [--] [a]\n")
    _, code, log = dev(root, base, { "--remote", "--", "widget", "save" })
    testing.eq(code, 0)
    testing.ok(log:find("[--job] [widget.save] [--]", 1, true), log)
    _, code, log = dev(root, base, { "--remote", "widget", "--", "save" })
    testing.ok(log:find("[--job] [widget.save] [--]", 1, true), log)
end)

testing.test("-- before a machine-local noun is still refused", function()
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

testing.test(
    "the project's __remote.lua sends bootstrap to the bootstrap pipeline and the rest to the default one",
    function()
        local override = assert(fs.read(REPO .. "/.dev/__remote.lua"))
        local root, base = setup({ ["__remote.lua"] = override })
        local _, code, log = dev(root, base, { "--remote", "bootstrap", "--", "a b" })
        testing.eq(code, 0)
        testing.eq(
            log,
            "ci -C "
                .. root
                .. " [run] [bootstrap] [--local] [--follow] [--job] [bootstrap] [--] [a b]\n"
        )
        _, code, log = dev(root, base, { "--remote", "--detach", "bootstrap" })
        testing.eq(code, 0)
        testing.eq(
            log,
            "ci -C " .. root .. " [run] [bootstrap] [--local] [--detach] [--job] [bootstrap] [--]\n"
        )
        _, code, log = dev(root, base, { "--remote", "test", "--", "x" })
        testing.eq(code, 0)
        testing.eq(log, "ci -C " .. root .. " [run] [--local] [--follow] [--job] [test] [--] [x]\n")
    end
)

testing.test("the project's __remote.lua sends soak to the soak pipeline", function()
    local override = assert(fs.read(REPO .. "/.dev/__remote.lua"))
    local root, base = setup({ ["__remote.lua"] = override })
    local _, code, log = dev(root, base, { "--remote", "soak", "--", "--runs", "5" })
    testing.eq(code, 0)
    testing.eq(
        log,
        "ci -C " .. root .. " [run] [soak] [--local] [--follow] [--job] [soak] [--] [--runs] [5]\n"
    )
end)

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
        local out = dev(root, base, { flag, "--remote", "bootstrap" })
        testing.ok(
            out:find(
                "+ ci -C " .. root .. " run bootstrap --local --follow --job bootstrap --\n",
                1,
                true
            ),
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

testing.test("a noun nested two deep is one job with a dot between each word", function()
    local root, base = setup({ ["n/m/x.sh"] = "#!/usr/bin/env bash\ntrue\n" })
    local _, code, log = dev(root, base, { "--remote", "n", "m", "x" })
    testing.eq(code, 0)
    testing.ok(log:find("[--job] [n.m.x]", 1, true), log)
end)

testing.test("DEV_REMOTE=0 runs here under the default and --remote still wins", function()
    local root, base = setup()
    local _, _, log = dev(root, base, { "test" }, { DEV_REMOTE = "0" })
    testing.eq(log, "")
    _, _, log = dev(root, base, { "test", "--remote" }, { DEV_REMOTE = "0" })
    testing.ok(log:find("[--job] [test]", 1, true), log)
end)

testing.test("a # local header keeps a verb with a same-named job here until --remote", function()
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
end)

testing.test("a verb script without # local keeps routing to its job", function()
    local root, base =
        setup({ ["test.sh"] = "#!/usr/bin/env bash\n# Run the tests.\necho ran-local\n" })
    local out, _, log = dev(root, base, { "test" })
    testing.eq(out, "")
    testing.ok(log:find("[--job] [test]", 1, true), log)
end)

testing.test(
    "# local also works in a Lua header and a noun subcommand, and shows under -h",
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

testing.test("--remote ci run label takes DEV_CI_VERB and DEV_CI_CARD", function()
    local root, base = setup()
    local _, code = dev(
        root,
        base,
        { "--remote", "test" },
        { DEV_CI_VERB = "land", DEV_CI_CARD = "d9f0e004" }
    )
    testing.eq(code, 0)
    testing.eq(fs.read(base .. "/log.agent"), "p/land/d9f0e004\n")
    fs.remove(base .. "/log.agent")
    _, code = dev(root, base, { "--remote", "test" }, { DEV_CI_VERB = "release" })
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

testing.test("run label is unset for a bare run in a terminal", function()
    local remote = require("dev.remote")
    local root = setup()
    with_empty_home(function()
        local terminal = { tty = true }
        testing.eq(remote.run_label(root, {}, terminal), nil)
        testing.eq(remote.run_label(root, { DEV_AGENT = "", DEV_CI_VERB = "" }, terminal), nil)
        testing.eq(remote.run_label(root, { DEV_CI_CARD = "d9f0e004" }, terminal), nil)
    end)
end)

testing.test("run label keeps check and release labels in a terminal", function()
    local remote = require("dev.remote")
    local root = setup()
    with_empty_home(function()
        local check = { DEV_CI_VERB = remote.Verb.CHECK, DEV_CI_CARD = "d9f0e004" }
        local terminal, piped = { tty = true }, { tty = false }
        testing.eq(remote.run_label(root, check, terminal), "p/check/d9f0e004")
        local release = "release"
        testing.eq(remote.run_label(root, { DEV_CI_VERB = release }, terminal), "p/" .. release)
        testing.eq(remote.run_label(root, {}, piped), "p/remote")
        local agent = { DEV_AGENT = "dotfiles/implementer/x/1" }
        testing.eq(remote.run_label(root, agent, piped), nil)
        testing.eq(remote.run_label(root, agent, terminal), nil)
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

testing.test("--remote ci run label keeps a caller's DEV_AGENT", function()
    local root, base = setup()
    local _, code = dev(
        root,
        base,
        { "--remote", "test" },
        { DEV_AGENT = "dotfiles/implementer/x/1", DEV_CI_VERB = "land" }
    )
    testing.eq(code, 0)
    testing.eq(fs.read(base .. "/log.agent"), "dotfiles/implementer/x/1\n")
end)
