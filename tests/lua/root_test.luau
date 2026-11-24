local testing = require("dev.testing")
local dev_os = require("dev.os")
local runtime = require("dev.runtime")
local fs = require("dev.fs")
local root = require("dev.root")
local support = require("support")
local tools = require("dev.cmd.tools")
local dev_command = require("dev.command")

local MAIN = runtime.exe
local MAX = 262144

local function line_of(length)
    return "#" .. string.rep("x", length - 1) .. "\n"
end

local function trusting(fn)
    local stat, fstat = fs.stat, fs.fstat
    fs.stat = function(path)
        local real = stat(path)
        if real then
            real.uid = 0
        end
        return real
    end
    fs.fstat = function(fd)
        local real = fstat(fd)
        if real then
            real.uid = 0
        end
        return real
    end
    local ok, err = pcall(fn)
    fs.stat, fs.fstat = stat, fstat
    if not ok then
        error(err, 0)
    end
end

local function project(base, name, manifest)
    local dir = base .. "/" .. name
    assert(fs.mkdir(dir .. "/.dev", { parents = true }))
    assert(dev_os.run({ "chmod", "755", dir, dir .. "/.dev" }) == 0, "chmod failed")
    if manifest then
        assert(fs.write(dir .. "/.dev/tools.tsv", manifest))
    end
    return dir, dir .. "/.dev/tools.tsv"
end

local function copy_of(dir, manifest)
    local copy, message, reason, detail
    trusting(function()
        copy, message, reason, detail = root.manifest_copy(dir, manifest)
    end)
    return copy, message, reason, detail
end

local function discard(copy)
    fs.remove(fs.dirname(copy), { recursive = true })
end

local function temp_count()
    local out = dev_os.capture({ "sh", "-c", "ls /tmp | grep -c '^dev-tools[.]' || true" })
    return tonumber(out)
end

testing.test(
    "allowed accepts only tools install, tools check and a __pkg driver on a root-owned manifest",
    function()
        testing.ok(root.allowed({ "tools", "install" }))
        testing.ok(root.allowed({ "tools", "check" }))
        testing.ok(not root.allowed({ "__pkg", "check" }))
        testing.ok(not root.allowed({ "__pkg", "check", "--manifest", "/nonexistent-zzz" }))
        testing.ok(not root.allowed({ "__pkg", "install" }))
        testing.ok(root.allowed({ "__pkg" }))
        testing.ok(not root.allowed({ "tools", "extra" }))
        testing.ok(not root.allowed({ "tools" }))
        testing.ok(not root.allowed({ "lint" }))
        testing.ok(not root.allowed({ "install", "check" }))
    end
)

testing.test("a hostile project name and manifest cell are read as text and run nothing", function()
    local base = assert(fs.realpath(support.tempdir()))
    local manifest_text = "name binary pacman\n$(touch PWNED) x y\n"
    local dir, manifest = project(base, "x'$(touch PWNED)", manifest_text)
    local copy = assert(copy_of(dir, manifest))
    testing.eq(fs.read(copy), manifest_text)
    testing.ok(
        not fs.exists(dir .. "/PWNED") and not fs.exists(base .. "/PWNED"),
        "nothing may run"
    )
    discard(copy)
    fs.remove(base, { recursive = true })
end)

testing.test(
    "a manifest of 262145 bytes returns the too_large reason and 262144 is read",
    function()
        local base = assert(fs.realpath(support.tempdir()))
        local lines = string.rep(line_of(1023), 256)
        testing.eq(#lines, MAX)
        local dir, manifest = project(base, "p", lines)
        local copy = assert(copy_of(dir, manifest))
        testing.eq(#fs.read(copy), MAX)
        discard(copy)
        assert(fs.write(manifest, lines .. "x"))
        local none, message, reason, detail = copy_of(dir, manifest)
        testing.eq(none, nil)
        testing.eq(message, nil)
        testing.eq(reason, root.Reason.TOO_LARGE)
        testing.eq(detail, manifest)
        fs.remove(base, { recursive = true })
    end
)

testing.test("a line of 4097 bytes is refused and 4096 is read", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", line_of(4096) .. "ok\n")
    local copy = assert(copy_of(dir, manifest))
    discard(copy)
    assert(fs.write(manifest, "ok\n" .. line_of(4097)))
    local none, _, reason, detail = copy_of(dir, manifest)
    testing.eq(none, nil)
    testing.eq(reason, root.Reason.LONG_LINE)
    testing.eq(detail, manifest)
    assert(fs.write(manifest, "ok\n" .. string.rep("y", 4097)))
    none, _, reason, detail = copy_of(dir, manifest)
    testing.eq(none, nil)
    testing.eq(reason, root.Reason.LONG_LINE)
    testing.eq(detail, manifest)
    fs.remove(base, { recursive = true })
end)

testing.test("a symlinked manifest is refused with the ownership text", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p")
    assert(fs.write(base .. "/outside", "SECRET\n"))
    assert(fs.symlink(base .. "/outside", manifest))
    local none, _, reason, detail = copy_of(dir, manifest)
    testing.eq(none, nil)
    testing.eq(reason, root.Reason.OWNERSHIP)
    testing.eq(detail, manifest)
    fs.remove(base, { recursive = true })
end)

testing.test("a group-writable .dev is refused and names the directory", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "x\n")
    assert(dev_os.run({ "chmod", "g+w", dir .. "/.dev" }) == 0, "chmod failed")
    local none, _, reason, detail = copy_of(dir, manifest)
    testing.eq(none, nil)
    testing.eq(reason, root.Reason.OWNERSHIP)
    testing.eq(detail, dir .. "/.dev")
    fs.remove(base, { recursive = true })
end)

testing.test("a user-owned chain is refused", function()
    if dev_os.getuid() == 0 then
        return
    end
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "x\n")
    local none, _, reason, detail = root.manifest_copy(dir, manifest)
    testing.eq(none, nil)
    testing.eq(reason, root.Reason.OWNERSHIP)
    testing.eq(type(detail), "string")
    fs.remove(base, { recursive = true })
end)

testing.test("a manifest swapped for a symlink after the directory checks is refused", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "good\n")
    assert(fs.write(base .. "/outside", "SECRET\n"))
    local before = temp_count()
    local stat = fs.stat
    local none, message, reason, detail
    trusting(function()
        local trusted_stat = fs.stat
        fs.stat = function(path)
            local result = trusted_stat(path)
            if path == "/" then
                assert(fs.remove(manifest))
                assert(fs.symlink(base .. "/outside", manifest))
            end
            return result
        end
        none, message, reason, detail = root.manifest_copy(dir, manifest)
        fs.stat = trusted_stat
    end)
    fs.stat = stat
    testing.eq(none, nil)
    testing.eq(message, nil)
    testing.eq(reason, root.Reason.OPEN)
    testing.eq(detail, manifest)
    testing.eq(temp_count(), before)
    fs.remove(base, { recursive = true })
end)

testing.test("a FIFO manifest returns the not_regular reason without blocking", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p")
    assert(dev_os.run({ "mkfifo", manifest }) == 0, "mkfifo failed")
    assert(dev_os.run({ "chmod", "600", manifest }) == 0, "chmod failed")
    local none, _, reason, detail = copy_of(dir, manifest)
    testing.eq(none, nil)
    testing.eq(reason, root.Reason.NOT_REGULAR)
    testing.eq(detail, manifest)
    fs.remove(base, { recursive = true })
end)

testing.test("a directory manifest returns the not_regular reason", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p")
    assert(fs.mkdir(manifest))
    assert(dev_os.run({ "chmod", "755", manifest }) == 0, "chmod failed")
    local none, _, reason, detail = copy_of(dir, manifest)
    testing.eq(none, nil)
    testing.eq(reason, root.Reason.NOT_REGULAR)
    testing.eq(detail, manifest)
    fs.remove(base, { recursive = true })
end)

local FIXED_ENV = {
    "env",
    "-i",
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "HOME=/root",
    "LANG=C.UTF-8",
}
local WRAPPER = 5
local INTERPRETER = runtime.exe

local function is_wrapper(argv)
    return argv[1] == "sh" and argv[2] == "-c" and argv[3]:find("trap", 1, true) ~= nil
end

---@class root_test.Opts
---@field verbose 0|1|2? the verbosity, 0 by default
---@field hook (fun(argv: string[], opts: table, run: function): integer)? replaces running the
---   wrapper

local function run_as_root(dir, handler, opts)
    opts = opts or {}
    local getuid, run = dev_os.getuid, dev_os.run
    local seen
    dev_os.getuid = function()
        return 0
    end
    dev_os.run = function(argv, run_opts)
        if not is_wrapper(argv) then
            return run(argv, run_opts)
        end
        seen = { argv = argv, opts = run_opts }
        return opts.hook and opts.hook(argv, run_opts, run) or 0
    end
    local code
    local ok, err = pcall(function()
        trusting(function()
            code = tools.check({}, {
                name = handler,
                args = {},
                root = dir,
                vars = {},
                verbose = opts.verbose or 0,
            })
        end)
    end)
    dev_os.getuid, dev_os.run = getuid, run
    if not ok then
        error(err, 0)
    end
    return code, seen
end

local function driver_of(argv)
    return { table.unpack(argv, WRAPPER + 1) }
end

testing.test("the driver runs under env -i with only the fixed variables, from the copy", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "name binary pacman\n")
    local before = temp_count()
    local code, seen = run_as_root(dir, "tools check")
    testing.eq(code, 0)
    local argv = seen.argv
    local copy = argv[WRAPPER]
    testing.ok(copy:find("^/tmp/dev%-tools%."), copy)
    local driver = driver_of(argv)
    testing.eq({ table.unpack(driver, 1, 5) }, FIXED_ENV)
    testing.eq(driver[6], INTERPRETER)
    testing.eq(driver[7], "__pkg")
    testing.eq({ driver[8], driver[9], driver[10] }, { "check", "--manifest", copy })
    testing.eq(#driver, 10)
    testing.eq(seen.opts.cwd, dir)
    testing.ok(not fs.exists(copy), "the copy should be removed")
    testing.ok(not fs.exists(fs.dirname(copy)), "the private folder should be removed")
    testing.eq(temp_count(), before)
    fs.remove(base, { recursive = true })
end)

testing.test(
    "the wrapper is a constant script and gets the copy and driver as arguments",
    function()
        local base = assert(fs.realpath(support.tempdir()))
        local dir = project(base, "x'$(touch PWNED)", "name binary pacman\n")
        local _, seen = run_as_root(dir, "tools check")
        testing.eq({ seen.argv[1], seen.argv[2], seen.argv[4] }, { "sh", "-c", "sh" })
        testing.ok(not seen.argv[3]:find(dir, 1, true), "the script must not hold project data")
        testing.ok(
            not seen.argv[3]:find(seen.argv[WRAPPER], 1, true),
            "the script must not hold the copy"
        )
        fs.remove(base, { recursive = true })
    end
)

testing.test("verbose adds VERBOSE to the driver environment and nothing else", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "name binary pacman\n")
    local _, seen = run_as_root(dir, "tools check", { verbose = 1 })
    local driver = driver_of(seen.argv)
    testing.eq({ table.unpack(driver, 1, 5) }, FIXED_ENV)
    testing.eq(driver[6], "VERBOSE=1")
    testing.eq(driver[7], INTERPRETER)
    fs.remove(base, { recursive = true })
end)

testing.test("at -vv the driver gets VERBOSE=2 and none of the caller's trace settings", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "name binary pacman\n")
    dev_os.defaults.env.BASH_ENV = "/tmp/evil-bash-env"
    dev_os.defaults.env.PS4 = "evil-ps4"
    local _, seen = run_as_root(dir, "tools check", { verbose = 2 })
    dev_os.defaults.env = {}
    local driver = driver_of(seen.argv)
    testing.eq({ table.unpack(driver, 1, 5) }, FIXED_ENV)
    testing.eq(driver[6], "VERBOSE=2")
    testing.eq(driver[7], INTERPRETER)
    fs.remove(base, { recursive = true })
end)

testing.test("the copy is gone after the driver exits nonzero or is terminated", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "name binary pacman\n")
    local before = temp_count()
    for _, script in ipairs({ "exit 3", "kill -TERM $PPID; sleep 1" }) do
        local gone, copy
        local code = run_as_root(dir, "tools check", {
            hook = function(argv, opts, run)
                copy = argv[WRAPPER]
                local real = { table.unpack(argv, 1, WRAPPER) }
                for _, word in ipairs({ "sh", "-c", script }) do
                    real[#real + 1] = word
                end
                local result = run(real, opts)
                gone = not fs.exists(copy)
                return result
            end,
        })
        testing.ok(code ~= 0, "the driver's failure should reach the caller")
        testing.ok(gone, "the wrapper should remove the copy for " .. script)
    end
    testing.eq(temp_count(), before)
    fs.remove(base, { recursive = true })
end)

testing.test("a failing fstat is a refusal, not a traceback", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "x\n")
    local fstat = fs.fstat
    fs.fstat = function()
        return nil, "no fstat"
    end
    local none, message, reason, detail
    local ok, err = pcall(function()
        none, message, reason, detail = copy_of(dir, manifest)
    end)
    fs.fstat = fstat
    assert(ok, err)
    testing.eq(none, nil)
    testing.eq(message, nil)
    testing.eq(reason, root.Reason.OPEN)
    testing.eq(detail, manifest)
    fs.remove(base, { recursive = true })
end)

local function with_mktemp(stub, fn)
    local capture = dev_os.capture
    dev_os.capture = function(argv, ...)
        if argv[1] == "mktemp" then
            return stub()
        end
        return capture(argv, ...)
    end
    local ok, err = pcall(fn)
    dev_os.capture = capture
    if not ok then
        error(err, 0)
    end
end

local function failing_mktemp()
    return "", 1
end

local function missing_mktemp(base)
    return function()
        return base .. "/missing/copy\n", 0
    end
end

local function noting(fn)
    local note = dev_command.note
    local lines = {}
    dev_command.note = function(text)
        lines[#lines + 1] = text
    end
    local ok, err = pcall(fn)
    dev_command.note = note
    if not ok then
        error(err, 0)
    end
    return lines
end

testing.test("manifest_copy returns the temp reason when mktemp fails", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "x\n")
    local none, message, reason, detail
    with_mktemp(failing_mktemp, function()
        none, message, reason, detail = copy_of(dir, manifest)
    end)
    testing.eq(none, nil)
    testing.eq(message, nil)
    testing.eq(reason, root.Reason.TEMP)
    testing.eq(detail, nil)
    fs.remove(base, { recursive = true })
end)

testing.test("manifest_copy returns the write reason with the copy path", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "x\n")
    local before = temp_count()
    local none, message, reason, detail
    with_mktemp(missing_mktemp(base), function()
        none, message, reason, detail = copy_of(dir, manifest)
    end)
    testing.eq(none, nil)
    testing.eq(message, nil)
    testing.eq(reason, root.Reason.WRITE)
    testing.eq(detail, base .. "/missing/copy")
    testing.ok(not fs.exists(base .. "/missing/copy"), "no copy should be left")
    testing.eq(temp_count(), before)
    fs.remove(base, { recursive = true })
end)

testing.test("tools check writes the temp file sentence when mktemp fails", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "name binary pacman\n")
    local code, seen
    local lines = noting(function()
        with_mktemp(failing_mktemp, function()
            code, seen = run_as_root(dir, "tools check")
        end)
    end)
    testing.eq(code, 1)
    testing.eq(seen, nil)
    testing.eq(lines, { "Cannot make a temp file." })
    fs.remove(base, { recursive = true })
end)

testing.test("tools check writes the cannot write sentence with the copy path", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "name binary pacman\n")
    local code, seen
    local lines = noting(function()
        with_mktemp(missing_mktemp(base), function()
            code, seen = run_as_root(dir, "tools check")
        end)
    end)
    testing.eq(code, 1)
    testing.eq(seen, nil)
    testing.eq(lines, { "Cannot write " .. base .. "/missing/copy." })
    fs.remove(base, { recursive = true })
end)

testing.test("a refused manifest never reaches the driver and leaves no copy", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "x\n")
    assert(dev_os.run({ "chmod", "g+w", dir .. "/.dev" }) == 0, "chmod failed")
    local before = temp_count()
    local code, seen = run_as_root(dir, "tools check")
    testing.eq(code, 1)
    testing.eq(seen, nil)
    testing.eq(temp_count(), before)
    fs.remove(base, { recursive = true })
end)

testing.test("a removed working directory exits 1 instead of hanging and names it", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = base .. "/gone"
    assert(fs.mkdir(dir))
    local out, code = dev_os.capture_timed({
        "sh",
        "-c",
        'cd "$1" && rmdir "$1" && exec "$2" help',
        "sh",
        dir,
        MAIN,
    }, 10, { merge = true, env = { CI = "", DEV_REMOTE = "0" } })
    testing.eq(code, 1)
    testing.ok(out:find("The working directory " .. dir .. " cannot be read.\n", 1, true), out)
    fs.remove(base, { recursive = true })
end)

testing.test(
    "the __pkg gate refuses a repeated --manifest and accepts one root-owned manifest",
    function()
        local base = assert(fs.realpath(support.tempdir()))
        local dir, manifest = project(base, "p", "x\n")
        local other_dir, other = project(base, "q", "y\n")
        assert(dev_os.run({ "chmod", "700", dir .. "/.dev", other_dir .. "/.dev" }) == 0)
        trusting(function()
            testing.ok(root.allowed({ "__pkg", "check", "--manifest", manifest }))
            testing.ok(
                not root.allowed({ "__pkg", "check", "--manifest", manifest, "--manifest", other })
            )
            testing.ok(
                not root.allowed({ "__pkg", "check", "--manifest", other, "--manifest", manifest })
            )
        end)
        testing.ok(not root.allowed({ "__pkg", "check", "--manifest", manifest }))
        fs.remove(base, { recursive = true })
    end
)

testing.test("the __pkg gate refuses a manifest in a folder anyone else can enter", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "x\n")
    for _, mode in ipairs({ "777", "755", "750", "710" }) do
        assert(dev_os.run({ "chmod", mode, dir .. "/.dev" }) == 0, "chmod failed")
        trusting(function()
            testing.ok(not root.allowed({ "__pkg", "check", "--manifest", manifest }), mode)
        end)
    end
    assert(dev_os.run({ "chmod", "700", dir .. "/.dev" }) == 0, "chmod failed")
    trusting(function()
        testing.ok(root.allowed({ "__pkg", "check", "--manifest", manifest }))
    end)
    fs.remove(base, { recursive = true })
end)

testing.test("the __pkg gate refuses a link or a writable folder above the manifest", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "x\n")
    assert(dev_os.run({ "chmod", "700", dir .. "/.dev" }) == 0, "chmod failed")
    assert(dev_os.run({ "ln", "-s", dir .. "/.dev", base .. "/lnk" }) == 0, "ln failed")
    trusting(function()
        testing.ok(root.allowed({ "__pkg", "check", "--manifest", manifest }))
        testing.ok(not root.allowed({ "__pkg", "check", "--manifest", base .. "/lnk/tools.tsv" }))
        assert(dev_os.run({ "chmod", "777", dir }) == 0, "chmod failed")
        testing.ok(not root.allowed({ "__pkg", "check", "--manifest", manifest }))
    end)
    fs.remove(base, { recursive = true })
end)

testing.test("the __pkg gate refuses --log-file and the --manifest=X form", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "x\n")
    assert(dev_os.run({ "chmod", "700", dir .. "/.dev" }) == 0, "chmod failed")
    trusting(function()
        testing.ok(
            not root.allowed({ "__pkg", "install", "--manifest", manifest, "--log-file", "/etc/x" })
        )
        testing.ok(not root.allowed({ "__pkg", "check", "--manifest=" .. manifest }))
    end)
    fs.remove(base, { recursive = true })
end)

testing.test("manifest_copy puts the manifest and the pins file in one 0700 folder", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "name binary pacman\n")
    assert(fs.write(dir .. "/.dev/releases.tsv", "name version sha256 url path\n"))
    local copy = assert(copy_of(dir, manifest))
    local folder = fs.dirname(copy)
    testing.eq(fs.read(copy), "name binary pacman\n")
    testing.eq(fs.read(folder .. "/releases.tsv"), "name version sha256 url path\n")
    testing.eq(bit32.band(fs.stat(folder).mode, 511), 448)
    trusting(function()
        testing.ok(root.allowed({ "__pkg", "install", "--manifest", copy }))
    end)
    discard(copy)
    testing.ok(not fs.exists(folder), "the private folder should be removed")
    fs.remove(base, { recursive = true })
end)

testing.test("manifest_copy refuses a pins file that is a link", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "name binary pacman\n")
    assert(fs.write(base .. "/elsewhere.tsv", "planted\n"))
    assert(dev_os.run({ "ln", "-s", base .. "/elsewhere.tsv", dir .. "/.dev/releases.tsv" }) == 0)
    local before = temp_count()
    local none, _, reason, detail = copy_of(dir, manifest)
    testing.eq(none, nil)
    testing.eq(reason, root.Reason.OPEN)
    testing.eq(detail, dir .. "/.dev/releases.tsv")
    testing.eq(temp_count(), before)
    fs.remove(base, { recursive = true })
end)

testing.test("manifest_copy refuses an oversize or long-lined pins file", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "name binary pacman\n")
    local before = temp_count()
    local cases = {
        { string.rep("x", MAX + 1), root.Reason.TOO_LARGE },
        { line_of(root.MAX_LINE_BYTES + 1), root.Reason.LONG_LINE },
    }
    for _, case in ipairs(cases) do
        assert(fs.write(dir .. "/.dev/releases.tsv", case[1]))
        local none, _, reason, detail = copy_of(dir, manifest)
        testing.eq(none, nil)
        testing.eq(reason, case[2])
        testing.eq(detail, dir .. "/.dev/releases.tsv")
    end
    testing.eq(temp_count(), before)
    fs.remove(base, { recursive = true })
end)

testing.test("a root run hands the driver the pins file beside the manifest copy", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "name binary pacman\n")
    assert(fs.write(dir .. "/.dev/releases.tsv", "pinned-text\n"))
    local seen_pins, mode
    local code = run_as_root(dir, "tools check", {
        hook = function(argv, opts, run)
            local copy = argv[WRAPPER]
            local real = { table.unpack(argv, 1, WRAPPER) }
            for _, word in ipairs({ "sh", "-c", 'cat "${1%/*}/releases.tsv"', "sh", copy }) do
                real[#real + 1] = word
            end
            mode = bit32.band(fs.stat(fs.dirname(copy)).mode, 511)
            local out = dev_os.capture(real, opts)
            seen_pins = out
            return 0
        end,
    })
    testing.eq(code, 0)
    testing.eq(seen_pins, "pinned-text\n")
    testing.eq(mode, 448)
    fs.remove(base, { recursive = true })
end)

testing.test("the __pkg gate refuses a manifest that is a link or a folder", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "x\n")
    assert(dev_os.run({ "ln", "-s", manifest, dir .. "/.dev/link.tsv" }) == 0, "ln failed")
    trusting(function()
        testing.ok(not root.allowed({ "__pkg", "check", "--manifest", dir .. "/.dev/link.tsv" }))
        testing.ok(not root.allowed({ "__pkg", "check", "--manifest", dir .. "/.dev" }))
    end)
    fs.remove(base, { recursive = true })
end)

testing.test("the driver refuses a repeated --manifest in check and install", function()
    for _, sub in ipairs({ "check", "install" }) do
        local out, code = dev_os.capture(
            { runtime.exe, "__pkg", sub, "--manifest", "/a.tsv", "--manifest", "/b.tsv" },
            { stderr = "stdout" }
        )
        testing.eq(code, 2)
        testing.ok(out:find("`--manifest` was given more than once", 1, true), out)
    end
end)
