local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
local MAIN = REPO .. "/dotfiles/bin/.local/share/dev/main.lua"

local STUB = [[#!/usr/bin/env bash
root=""
if [ "$1" = -C ]; then root="$2"; shift 2; fi
case "$1" in
jobs)
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
    if [ "$2" = bootstrap ] || [ "$2" = soak ]; then
        printf '{"jobs":[{"name":"%s"}]}\n' "$2"
    else
        printf '{"jobs":[{"name":"test"},{"name":"widget.save"},{"name":"n.m.x"}]}\n'
    fi
    ;;
run)
    printf 'ci -C %s' "$root" >>"$STUB_LOG"
    printf ' [%s]' "$@" >>"$STUB_LOG"
    printf '\n' >>"$STUB_LOG"
    exit "${CI_STUB_RC:-0}"
    ;;
esac
]]

local function write_exec(path, text)
    assert(fs.mkdir(fs.dirname(path), { parents = true }))
    assert(fs.write(path, text))
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
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

local function dev(root, base, args, env)
    local argv = { "luajit", MAIN }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    local merged = {
        STUB_LOG = base .. "/log",
        PATH = base .. "/bin:" .. os.getenv("PATH"),
        HOME = base .. "/home",
        CI = "",
        DEV_BOX_MARKER = base .. "/no-box",
    }
    for key, value in pairs(env or {}) do
        merged[key] = value
    end
    fs.remove(base .. "/log")
    local out, code = devos.capture(argv, { cwd = root, stderr = "stdout", env = merged })
    return out, code, fs.read(base .. "/log") or ""
end

t.test("--remote runs ci with the arguments after -- as separate words", function()
    local root, base = setup()
    local _, code, log = dev(root, base, { "--remote", "test", "--", "a", "b c", "$(x)" })
    t.eq(code, 0)
    t.eq(
        log,
        "ci -C " .. root .. " [run] [--local] [--follow] [--job] [test] [--] [a] [b c] [$(x)]\n"
    )
end)

t.test("--detach replaces --follow and the flag order does not matter", function()
    local root, base = setup()
    local _, _, log = dev(root, base, { "test", "--remote", "--detach" })
    t.ok(log:find("[--detach] [--job] [test]", 1, true), log)
    t.ok(not log:find("--follow", 1, true), log)
    _, _, log = dev(root, base, { "test", "--remote" })
    t.ok(log:find("[--follow] [--job] [test]", 1, true), log)
end)

t.test("--detach without --remote is a usage error", function()
    local root, base = setup()
    local out, code, log = dev(root, base, { "--detach", "test" })
    t.eq(code, 2)
    t.eq(out, "dev: --detach needs --remote\n")
    t.eq(log, "")
end)

t.test("a noun and its subcommand are one job named with a dot", function()
    local root, base = setup({ ["widget/save.sh"] = "#!/usr/bin/env bash\ntrue\n" })
    local _, _, log = dev(root, base, { "--remote", "widget", "save" })
    t.ok(log:find("[--job] [widget.save]", 1, true), log)
end)

t.test("ci's exit code is dev's", function()
    local root, base = setup()
    local _, code = dev(root, base, { "--remote", "test" }, { CI_STUB_RC = "7" })
    t.eq(code, 7)
end)

t.test("an argument before -- is a usage error", function()
    local root, base = setup()
    local out, code, log = dev(root, base, { "--remote", "test", "--extra" })
    t.eq(code, 2)
    t.eq(out, "dev test: --remote passes arguments to the job only after --, got --extra\n")
    t.eq(log, "")
end)

t.test("a verb with no job exits 1 and runs nothing", function()
    local root, base = setup()
    local out, code, log = dev(root, base, { "--remote", "build" })
    t.eq(code, 1)
    t.ok(out:find("no job named build in the project's default pipeline", 1, true), out)
    t.eq(log, "")
end)

t.test("a machine-local verb is refused with the mockup text", function()
    local root, base = setup()
    for _, words in ipairs({ { "install" }, { "box", "ls" }, { "tools", "check" } }) do
        local args = { "--remote" }
        for _, word in ipairs(words) do
            args[#args + 1] = word
        end
        local out, code, log = dev(root, base, args)
        t.eq(code, 2)
        t.eq(
            out,
            "dev "
                .. table.concat(words, " ")
                .. ": runs on this machine only, so --remote does not apply\n"
        )
        t.eq(log, "")
    end
end)

t.test("DEV_REMOTE counts as --remote", function()
    local root, base = setup()
    local _, _, log = dev(root, base, { "test" }, { DEV_REMOTE = "1" })
    t.ok(log:find("[--job] [test]", 1, true), log)
    write_config(base, 'default = "local"')
    _, _, log = dev(root, base, { "test" }, { DEV_REMOTE = "0" })
    t.eq(log, "")
end)

t.test("with no setting a command with a job runs on ci and --local keeps it here", function()
    local root, base = setup()
    local _, code, log = dev(root, base, { "test", "a", "--", "b" })
    t.eq(code, 0)
    t.eq(log, "ci -C " .. root .. " [run] [--local] [--follow] [--job] [test] [--] [a] [b]\n")
    _, _, log = dev(root, base, { "test", "--local" })
    t.eq(log, "")
    local out, code2 = dev(root, base, { "test", "--local", "--remote" })
    t.eq(code2, 2)
    t.eq(out, "dev: --local and --remote cannot be used together\n")
end)

t.test("remote.default local runs here and --remote still goes to ci", function()
    local root, base = setup()
    write_config(base, 'default = "local"')
    local _, _, log = dev(root, base, { "test" })
    t.eq(log, "")
    _, _, log = dev(root, base, { "test", "--remote" })
    t.ok(log:find("[--job] [test]", 1, true), log)
end)

t.test("the user file beats the project file for remote.default", function()
    local root, base = setup()
    assert(fs.write(root .. "/.dev/config.toml", '[remote]\ndefault = "local"\n'))
    local _, _, log = dev(root, base, { "test" })
    t.eq(log, "")
    write_config(base, 'default = "remote"')
    _, _, log = dev(root, base, { "test" })
    t.ok(log:find("[--job] [test]", 1, true), log)
end)

t.test("a bad remote.default is one line and exit 1", function()
    local root, base = setup()
    write_config(base, 'default = "far"')
    local out, code = dev(root, base, { "test" })
    t.eq(code, 1)
    t.ok(out:find('remote.default must be "remote" or "local", got far', 1, true), out)
end)

t.test("CI=true or a box marker runs here, whatever the flags and default", function()
    local root, base = setup()
    local _, _, log = dev(root, base, { "test" }, { CI = "true" })
    t.eq(log, "")
    _, _, log = dev(root, base, { "test", "--remote" }, { CI = "true" })
    t.eq(log, "")
    assert(fs.write(base .. "/box", "name=x\n"))
    _, _, log = dev(root, base, { "test", "--remote" }, { DEV_BOX_MARKER = base .. "/box" })
    t.eq(log, "")
end)

t.test("commands without a job and machine-local verbs run here under the default", function()
    local root, base = setup({ ["hello.sh"] = "#!/usr/bin/env bash\necho hi\n" })
    local out, code, log = dev(root, base, { "hello" })
    t.eq(out, "hi\n")
    t.eq(code, 0)
    t.eq(log, "")
    out, code, log = dev(root, base, { "board", "status" })
    t.eq(log, "")
    t.eq(out, "dev: no board for this project\n")
    t.eq(code, 1)
end)

t.test("without ci on PATH the default fails with the --local hint", function()
    local root, base = setup({ ["hello.sh"] = "#!/usr/bin/env bash\necho hi\n" })
    assert(fs.mkdir(base .. "/lj"))
    assert(devos.run({ "ln", "-s", devos.which("luajit"), base .. "/lj/luajit" }) == 0, "ln failed")
    local env = { PATH = base .. "/lj:/usr/bin:/bin" }
    local out, code = dev(root, base, { "hello" }, env)
    t.eq(code, 1)
    t.eq(out, "dev: ci is not on PATH, rerun, or pass --local to run it here\n")
    out, code = dev(root, base, { "test", "--remote" }, env)
    t.eq(code, 1)
    t.ok(out:find("ci not found", 1, true), out)
    out, code = dev(root, base, { "hello", "--local" }, { PATH = env.PATH })
    t.eq(out, "hi\n")
    t.eq(code, 0)
    out, code = dev(root, base, { "hello" }, { PATH = env.PATH, CI = "true" })
    t.eq(out, "hi\n")
    t.eq(code, 0)
    out = dev(root, base, { "hello" }, { PATH = env.PATH, DEV_REMOTE = "0" })
    t.eq(out, "hi\n")
    write_config(base, 'default = "local"')
    out = dev(root, base, { "hello" }, env)
    t.eq(out, "hi\n")
end)

t.test("a failing ci jobs listing under the default fails with ci's error and the hint", function()
    local root, base = setup({ ["hello.sh"] = "#!/usr/bin/env bash\necho hi\n" })
    local out, code, log = dev(root, base, { "hello" }, { CI_STUB_JOBS = "fail" })
    t.eq(code, 9)
    t.eq(out, "dev: ci jobs failed: hub unreachable; rerun, or pass --local to run it here\n")
    t.eq(log, "")
    out, code = dev(root, base, { "hello", "--local" }, { CI_STUB_JOBS = "fail" })
    t.eq(out, "hi\n")
    t.eq(code, 0)
end)

t.test("a project with no pipeline file runs here without calling ci", function()
    local root, base = setup({ ["hello.sh"] = "#!/usr/bin/env bash\necho hi\n" })
    assert(devos.run({ "rm", "-rf", root .. "/.ci" }) == 0, "rm failed")
    local out, code = dev(root, base, { "hello" }, { CI_STUB_JOBS = "fail" })
    t.eq(out, "hi\n")
    t.eq(code, 0)
end)

t.test(
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
        t.eq(code, 5)
        t.eq(out, "test|a,b c|false|" .. root .. "\n")
        t.eq(log, "")
        out = dev(root, base, { "--remote", "--detach", "test" })
        t.eq(out, "test||true|" .. root .. "\n")
    end
)

t.test("a __remote.lua that errors or returns no function ends with one line and exit 1", function()
    local root, base = setup({ ["__remote.lua"] = "return 3\n" })
    local out, code = dev(root, base, { "--remote", "test" })
    t.eq(code, 1)
    t.ok(out:find("must return a function", 1, true), out)
    write_exec(root .. "/.dev/__remote.lua", "return function() error('nope', 0) end\n")
    out, code = dev(root, base, { "--remote", "test" })
    t.eq(code, 1)
    t.eq(out, "dev: nope\n")
end)

t.test("a failing ci jobs listing is reported with ci's exit code, not as a missing job", function()
    local root, base = setup()
    local out, code, log = dev(root, base, { "--remote", "test" }, { CI_STUB_JOBS = "fail" })
    t.eq(code, 9)
    t.eq(out, "dev: ci jobs failed: hub unreachable\n")
    t.eq(log, "")
    out, code, log = dev(root, base, { "--remote", "test" }, { CI_STUB_JOBS = "bad" })
    t.eq(code, 1)
    t.ok(out:find("dev: ci jobs failed", 1, true), out)
    t.ok(not out:find("no job named", 1, true), out)
    t.eq(log, "")
    for _, mode in ipairs({ "empty", "array" }) do
        out, code, log = dev(root, base, { "--remote", "test" }, { CI_STUB_JOBS = mode })
        t.eq(code, 1)
        t.eq(out, "dev: ci jobs failed\n")
        t.eq(log, "")
    end
end)

t.test("an unreadable __remote.lua ends with one line and exit 1", function()
    local root, base = setup({ ["__remote.lua"] = "return function() return 0 end\n" })
    assert(devos.run({ "chmod", "000", root .. "/.dev/__remote.lua" }) == 0, "chmod failed")
    local out, code = dev(root, base, { "--remote", "test" })
    devos.run({ "chmod", "644", root .. "/.dev/__remote.lua" })
    if devos.capture({ "id", "-u" }) == "0" then
        return
    end
    t.eq(code, 1)
    t.ok(out:find("dev: cannot read " .. root .. "/.dev/__remote.lua", 1, true), out)
    t.ok(not out:find("traceback", 1, true), out)
end)

t.test("a __remote.lua that returns a non-integer ends with one line and exit 1", function()
    local root, base = setup()
    for _, value in ipairs({ "2.5", '"x"' }) do
        write_exec(root .. "/.dev/__remote.lua", "return function() return " .. value .. " end\n")
        local out, code = dev(root, base, { "--remote", "test" })
        t.eq(code, 1)
        t.eq(
            out,
            "dev: "
                .. root
                .. "/.dev/__remote.lua returned "
                .. value:gsub('"', "")
                .. ", not an exit code\n"
        )
    end
end)

t.test("-- before the verb or noun still names the job", function()
    local root, base = setup({ ["widget/save.sh"] = "#!/usr/bin/env bash\ntrue\n" })
    local _, code, log = dev(root, base, { "--remote", "--", "test", "a" })
    t.eq(code, 0)
    t.eq(log, "ci -C " .. root .. " [run] [--local] [--follow] [--job] [test] [--] [a]\n")
    _, code, log = dev(root, base, { "--remote", "--", "widget", "save" })
    t.eq(code, 0)
    t.ok(log:find("[--job] [widget.save] [--]", 1, true), log)
    _, code, log = dev(root, base, { "--remote", "widget", "--", "save" })
    t.ok(log:find("[--job] [widget.save] [--]", 1, true), log)
end)

t.test("-- before a machine-local noun is still refused", function()
    local root, base = setup()
    local out, code, log = dev(root, base, { "--remote", "--", "box", "ls" })
    t.eq(code, 2)
    t.eq(out, "dev box ls: runs on this machine only, so --remote does not apply\n")
    t.eq(log, "")
end)

t.test("-v prints the ci argv to stderr", function()
    local root, base = setup()
    local out, code = dev(root, base, { "-v", "--remote", "test", "--", "a" })
    t.eq(code, 0)
    t.ok(out:find("+ ci -C " .. root .. " run --local --follow --job test -- a\n", 1, true), out)
end)

t.test("arguments after -- reach the job untouched", function()
    local root, base = setup()
    local _, _, log = dev(root, base, { "--remote", "test", "--", "--anything" })
    t.ok(log:find("[--] [--anything]", 1, true), log)
end)

t.test(
    "the project's __remote.lua sends bootstrap to the bootstrap pipeline and the rest to the default one",
    function()
        local override = assert(fs.read(REPO .. "/.dev/__remote.lua"))
        local root, base = setup({ ["__remote.lua"] = override })
        local _, code, log = dev(root, base, { "--remote", "bootstrap", "--", "a b" })
        t.eq(code, 0)
        t.eq(
            log,
            "ci -C "
                .. root
                .. " [run] [bootstrap] [--local] [--follow] [--job] [bootstrap] [--] [a b]\n"
        )
        _, code, log = dev(root, base, { "--remote", "--detach", "bootstrap" })
        t.eq(code, 0)
        t.eq(
            log,
            "ci -C " .. root .. " [run] [bootstrap] [--local] [--detach] [--job] [bootstrap] [--]\n"
        )
        _, code, log = dev(root, base, { "--remote", "test", "--", "x" })
        t.eq(code, 0)
        t.eq(log, "ci -C " .. root .. " [run] [--local] [--follow] [--job] [test] [--] [x]\n")
    end
)

t.test("the project's __remote.lua sends soak to the soak pipeline", function()
    local override = assert(fs.read(REPO .. "/.dev/__remote.lua"))
    local root, base = setup({ ["__remote.lua"] = override })
    local _, code, log = dev(root, base, { "--remote", "soak", "--", "--runs", "5" })
    t.eq(code, 0)
    t.eq(
        log,
        "ci -C " .. root .. " [run] [soak] [--local] [--follow] [--job] [soak] [--] [--runs] [5]\n"
    )
end)

t.test("the project's __remote.lua keeps the default runner's job-not-found error", function()
    local override = assert(fs.read(REPO .. "/.dev/__remote.lua"))
    local root, base = setup({ ["__remote.lua"] = override })
    local out, code, log = dev(root, base, { "--remote", "lint" })
    t.eq(code, 1)
    t.ok(out:find("dev: no job named lint in the project's default pipeline", 1, true), out)
    t.eq(log, "")
end)

t.test("the project's __remote.lua keeps -v and -vv for the ci echo", function()
    local override = assert(fs.read(REPO .. "/.dev/__remote.lua"))
    local root, base = setup({ ["__remote.lua"] = override })
    for _, flag in ipairs({ "-v", "-vv" }) do
        local out = dev(root, base, { flag, "--remote", "bootstrap" })
        t.ok(
            out:find(
                "+ ci -C " .. root .. " run bootstrap --local --follow --job bootstrap --\n",
                1,
                true
            ),
            out
        )
        out = dev(root, base, { flag, "--remote", "test" })
        t.ok(out:find("+ ci -C " .. root .. " run --local --follow --job test --\n", 1, true), out)
    end
    local out = dev(root, base, { "--remote", "test" })
    t.ok(not out:find("+ ci", 1, true), out)
end)

t.test("a noun nested two deep is one job with a dot between each word", function()
    local root, base = setup({ ["n/m/x.sh"] = "#!/usr/bin/env bash\ntrue\n" })
    local _, code, log = dev(root, base, { "--remote", "n", "m", "x" })
    t.eq(code, 0)
    t.ok(log:find("[--job] [n.m.x]", 1, true), log)
end)

t.test("DEV_REMOTE=0 runs here under the default and --remote still wins", function()
    local root, base = setup()
    local _, _, log = dev(root, base, { "test" }, { DEV_REMOTE = "0" })
    t.eq(log, "")
    _, _, log = dev(root, base, { "test", "--remote" }, { DEV_REMOTE = "0" })
    t.ok(log:find("[--job] [test]", 1, true), log)
end)

t.test("a # local header keeps a verb with a same-named job here until --remote", function()
    local root, base = setup({
        ["test.sh"] = "#!/usr/bin/env bash\n# Run the tests.\n# local\necho ran-local\n",
    })
    local out, code, log = dev(root, base, { "test" })
    t.eq(out, "ran-local\n")
    t.eq(code, 0)
    t.eq(log, "")
    _, _, log = dev(root, base, { "test", "--remote" })
    t.ok(log:find("[--job] [test]", 1, true), log)
    out = dev(root, base, { "help", "test" })
    t.ok(out:find("runs here under the remote default", 1, true), out)
    t.ok(not out:find("# local", 1, true), out)
end)

t.test("a verb script without # local keeps routing to its job", function()
    local root, base =
        setup({ ["test.sh"] = "#!/usr/bin/env bash\n# Run the tests.\necho ran-local\n" })
    local out, _, log = dev(root, base, { "test" })
    t.eq(out, "")
    t.ok(log:find("[--job] [test]", 1, true), log)
end)

t.test("# local also works in a Lua header and a noun subcommand, and shows under -h", function()
    local root, base = setup({
        ["widget/save.lua"] = "--[[\nSave it.\nlocal\n]]\nprint('ran-lua')\n",
    })
    local out, code, log = dev(root, base, { "widget", "save" })
    t.eq(out, "ran-lua\n")
    t.eq(code, 0)
    t.eq(log, "")
    out = dev(root, base, { "widget", "save", "-h" })
    t.ok(out:find("runs here under the remote default", 1, true), out)
end)
