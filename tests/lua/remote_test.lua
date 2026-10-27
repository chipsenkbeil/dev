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
    if [ "$2" = bootstrap ]; then
        printf '{"jobs":[{"name":"bootstrap"}]}\n'
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
    write_exec(base .. "/bin/ci", STUB)
    for name, text in pairs(files or {}) do
        write_exec(root .. "/.dev/" .. name, text)
    end
    return root, base
end

local function dev(root, base, args, env)
    local argv = { "luajit", MAIN }
    for _, word in ipairs(args) do
        argv[#argv + 1] = word
    end
    local merged = { STUB_LOG = base .. "/log", PATH = base .. "/bin:" .. os.getenv("PATH") }
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
    _, _, log = dev(root, base, { "test" }, { DEV_REMOTE = "0" })
    t.eq(log, "")
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
