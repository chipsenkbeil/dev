local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local root = require("dev.root")
local devproject = require("dev.project")
local support = require("support")
local tools = require("dev.cmd.tools")

local MAIN = devos.capture({ "pwd" }):gsub("\n$", "") .. "/dotfiles/bin/.local/share/dev/main.lua"
local MAX = 262144

local function line_of(length)
    return "#" .. string.rep("x", length - 1) .. "\n"
end

local function trusting(fn)
    local stat, fstat = fs.stat, devos.fstat
    fs.stat = function(path)
        local real = stat(path)
        if real then
            real.uid = 0
        end
        return real
    end
    devos.fstat = function(fd)
        local real = fstat(fd)
        if real then
            real.uid = 0
        end
        return real
    end
    local ok, err = pcall(fn)
    fs.stat, devos.fstat = stat, fstat
    if not ok then
        error(err, 0)
    end
end

local function project(base, name, manifest)
    local dir = base .. "/" .. name
    assert(fs.mkdir(dir .. "/.dev", { parents = true }))
    assert(devos.run({ "chmod", "755", dir, dir .. "/.dev" }) == 0, "chmod failed")
    if manifest then
        assert(fs.write(dir .. "/.dev/tools.tsv", manifest))
    end
    return dir, dir .. "/.dev/tools.tsv"
end

local function copy_of(dir, manifest)
    local copy, message
    trusting(function()
        copy, message = root.manifest_copy(dir, manifest)
    end)
    return copy, message
end

local function temp_count()
    local out = devos.capture({ "sh", "-c", "ls /tmp | grep -c '^dev-tools[.]' || true" })
    return tonumber(out)
end

t.test("allowed accepts only tools install and tools check", function()
    t.ok(root.allowed({ "tools", "install" }))
    t.ok(root.allowed({ "tools", "check" }))
    t.ok(not root.allowed({ "tools", "extra" }))
    t.ok(not root.allowed({ "tools" }))
    t.ok(not root.allowed({ "lint" }))
    t.ok(not root.allowed({ "install", "check" }))
end)

t.test("a hostile project name and manifest cell are read as text and run nothing", function()
    local base = assert(fs.realpath(support.tempdir()))
    local manifest_text = "name binary pacman\n$(touch PWNED) x y\n"
    local dir, manifest = project(base, "x'$(touch PWNED)", manifest_text)
    local copy = assert(copy_of(dir, manifest))
    t.eq(fs.read(copy), manifest_text)
    t.ok(not fs.exists(dir .. "/PWNED") and not fs.exists(base .. "/PWNED"), "nothing may run")
    fs.remove(copy)
    fs.remove(base, { recursive = true })
end)

t.test("a manifest of 262145 bytes is refused and 262144 is read", function()
    local base = assert(fs.realpath(support.tempdir()))
    local lines = string.rep(line_of(1023), 256)
    t.eq(#lines, MAX)
    local dir, manifest = project(base, "p", lines)
    local copy = assert(copy_of(dir, manifest))
    t.eq(#fs.read(copy), MAX)
    fs.remove(copy)
    assert(fs.write(manifest, lines .. "x"))
    local none, message = copy_of(dir, manifest)
    t.eq(none, nil)
    t.eq(message, "refusing " .. manifest .. " as root: larger than 256 KiB")
    fs.remove(base, { recursive = true })
end)

t.test("a line of 4097 bytes is refused and 4096 is read", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", line_of(4096) .. "ok\n")
    local copy = assert(copy_of(dir, manifest))
    fs.remove(copy)
    assert(fs.write(manifest, "ok\n" .. line_of(4097)))
    local none, message = copy_of(dir, manifest)
    t.eq(none, nil)
    t.eq(message, "refusing " .. manifest .. " as root: a line is longer than 4096 bytes")
    assert(fs.write(manifest, "ok\n" .. string.rep("y", 4097)))
    none, message = copy_of(dir, manifest)
    t.eq(none, nil)
    t.eq(message, "refusing " .. manifest .. " as root: a line is longer than 4096 bytes")
    fs.remove(base, { recursive = true })
end)

t.test("a symlinked manifest is refused with the ownership text", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p")
    assert(fs.write(base .. "/outside", "SECRET\n"))
    assert(fs.symlink(base .. "/outside", manifest))
    local none, message = copy_of(dir, manifest)
    t.eq(none, nil)
    t.eq(
        message,
        "refusing "
            .. manifest
            .. " as root: "
            .. manifest
            .. " must be owned by root and not writable by others"
    )
    fs.remove(base, { recursive = true })
end)

t.test("a group-writable .dev is refused and names the directory", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "x\n")
    assert(devos.run({ "chmod", "g+w", dir .. "/.dev" }) == 0, "chmod failed")
    local none, message = copy_of(dir, manifest)
    t.eq(none, nil)
    t.eq(
        message,
        "refusing "
            .. manifest
            .. " as root: "
            .. dir
            .. "/.dev must be owned by root and not writable by others"
    )
    fs.remove(base, { recursive = true })
end)

t.test("a user-owned chain is refused", function()
    if devos.getuid() == 0 then
        return
    end
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "x\n")
    local none, message = root.manifest_copy(dir, manifest)
    t.eq(none, nil)
    t.ok(message:find("refusing " .. manifest .. " as root: ", 1, true), message)
    t.ok(message:find("must be owned by root and not writable by others", 1, true), message)
    fs.remove(base, { recursive = true })
end)

t.test("a manifest swapped for a symlink after the directory checks is refused", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "good\n")
    assert(fs.write(base .. "/outside", "SECRET\n"))
    local before = temp_count()
    local stat = fs.stat
    local none, message
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
        none, message = root.manifest_copy(dir, manifest)
        fs.stat = trusted_stat
    end)
    fs.stat = stat
    t.eq(none, nil)
    t.eq(message, "cannot open " .. manifest)
    t.eq(temp_count(), before)
    fs.remove(base, { recursive = true })
end)

t.test("a FIFO manifest is refused without blocking", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p")
    assert(devos.run({ "mkfifo", manifest }) == 0, "mkfifo failed")
    assert(devos.run({ "chmod", "600", manifest }) == 0, "chmod failed")
    local none, message = copy_of(dir, manifest)
    t.eq(none, nil)
    t.eq(message, "refusing " .. manifest .. " as root, it is not a regular file")
    fs.remove(base, { recursive = true })
end)

t.test("a directory manifest is refused as not a regular file", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p")
    assert(fs.mkdir(manifest))
    assert(devos.run({ "chmod", "755", manifest }) == 0, "chmod failed")
    local none, message = copy_of(dir, manifest)
    t.eq(none, nil)
    t.eq(message, "refusing " .. manifest .. " as root, it is not a regular file")
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
local INTERPRETER = "/usr/bin/luajit"

local function is_wrapper(argv)
    return argv[1] == "sh" and argv[2] == "-c" and argv[3]:find("trap", 1, true) ~= nil
end

---@class root_test.Opts
---@field verbose 0|1|2? the verbosity, 0 by default
---@field hook (fun(argv: string[], opts: table, run: function): integer)? replaces running the wrapper
---@field interpreter string? the interpreter in the context, an absolute path by default

local function run_as_root(dir, handler, opts)
    opts = opts or {}
    local getuid, run = devos.getuid, devos.run
    local seen
    devos.getuid = function()
        return 0
    end
    devos.run = function(argv, run_opts)
        if not is_wrapper(argv) then
            return run(argv, run_opts)
        end
        seen = { argv = argv, opts = run_opts }
        return opts.hook and opts.hook(argv, run_opts, run) or 0
    end
    local code
    local ok, err = pcall(function()
        trusting(function()
            code = tools.handlers[handler]({
                name = handler,
                args = {},
                root = dir,
                vars = {},
                verbose = opts.verbose or 0,
                interpreter = opts.interpreter or INTERPRETER,
            })
        end)
    end)
    devos.getuid, devos.run = getuid, run
    if not ok then
        error(err, 0)
    end
    return code, seen
end

local function driver_of(argv)
    return { unpack(argv, WRAPPER + 1) }
end

t.test("the driver runs under env -i with only the fixed variables, from the copy", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "name binary pacman\n")
    local before = temp_count()
    local code, seen = run_as_root(dir, "tools check")
    t.eq(code, 0)
    local argv = seen.argv
    local copy = argv[WRAPPER]
    t.ok(copy:find("^/tmp/dev%-tools%."), copy)
    local driver = driver_of(argv)
    t.eq({ unpack(driver, 1, 5) }, FIXED_ENV)
    t.eq(driver[6], INTERPRETER)
    t.ok(driver[7]:find("/dotfiles/bin/%.local/share/dev/pkg%.lua$"), driver[7])
    t.eq({ driver[8], driver[9], driver[10] }, { "check", "--manifest", copy })
    t.eq(#driver, 10)
    t.eq(seen.opts.cwd, dir)
    t.ok(not fs.exists(copy), "the copy should be removed")
    t.eq(temp_count(), before)
    fs.remove(base, { recursive = true })
end)

t.test("the wrapper is a constant script and gets the copy and driver as arguments", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "x'$(touch PWNED)", "name binary pacman\n")
    local _, seen = run_as_root(dir, "tools check")
    t.eq({ seen.argv[1], seen.argv[2], seen.argv[4] }, { "sh", "-c", "sh" })
    t.ok(not seen.argv[3]:find(dir, 1, true), "the script must not hold project data")
    t.ok(not seen.argv[3]:find(seen.argv[WRAPPER], 1, true), "the script must not hold the copy")
    fs.remove(base, { recursive = true })
end)

t.test("verbose adds VERBOSE to the driver environment and nothing else", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "name binary pacman\n")
    local _, seen = run_as_root(dir, "tools check", { verbose = 1 })
    local driver = driver_of(seen.argv)
    t.eq({ unpack(driver, 1, 5) }, FIXED_ENV)
    t.eq(driver[6], "VERBOSE=1")
    t.eq(driver[7], INTERPRETER)
    fs.remove(base, { recursive = true })
end)

t.test("at -vv the driver gets exactly the trace file and the fixed PS4", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "name binary pacman\n")
    devos.defaults.env.BASH_ENV = "/tmp/evil-bash-env"
    devos.defaults.env.PS4 = "evil-ps4"
    local _, seen = run_as_root(dir, "tools check", { verbose = 2 })
    devos.defaults.env = {}
    local driver = driver_of(seen.argv)
    t.eq({ unpack(driver, 1, 5) }, FIXED_ENV)
    t.eq(driver[6], "VERBOSE=2")
    t.eq(driver[7], "BASH_ENV=" .. devproject.share .. "/xtrace.bash")
    t.eq(driver[8], "PS4=" .. devproject.PS4)
    t.eq(driver[9], INTERPRETER)
    fs.remove(base, { recursive = true })
end)

t.test("at -vv with the trace file missing the driver falls back to level 1", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "name binary pacman\n")
    local share = devproject.share
    devproject.share = base .. "/no-share"
    local _, seen = run_as_root(dir, "tools check", { verbose = 2 })
    devproject.share = share
    local driver = driver_of(seen.argv)
    t.eq(driver[6], "VERBOSE=1")
    t.eq(driver[7], INTERPRETER)
    fs.remove(base, { recursive = true })
end)

t.test("a relative interpreter is refused as root and leaves no copy", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "name binary pacman\n")
    local before = temp_count()
    local code, seen = run_as_root(dir, "tools check", { interpreter = "luajit" })
    t.eq(code, 1)
    t.eq(seen, nil)
    t.eq(temp_count(), before)
    fs.remove(base, { recursive = true })
end)

t.test("the copy is gone after the driver exits nonzero or is terminated", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "name binary pacman\n")
    local before = temp_count()
    for _, script in ipairs({ "exit 3", "kill -TERM $PPID; sleep 1" }) do
        local gone, copy
        local code = run_as_root(dir, "tools check", {
            hook = function(argv, opts, run)
                copy = argv[WRAPPER]
                local real = { unpack(argv, 1, WRAPPER) }
                for _, word in ipairs({ "sh", "-c", script }) do
                    real[#real + 1] = word
                end
                local result = run(real, opts)
                gone = not fs.exists(copy)
                return result
            end,
        })
        t.ok(code ~= 0, "the driver's failure should reach the caller")
        t.ok(gone, "the wrapper should remove the copy for " .. script)
    end
    t.eq(temp_count(), before)
    fs.remove(base, { recursive = true })
end)

t.test("a failing fstat is a refusal, not a traceback", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir, manifest = project(base, "p", "x\n")
    local fstat = devos.fstat
    devos.fstat = function()
        return nil, "no fstat"
    end
    local none, message
    local ok, err = pcall(function()
        none, message = copy_of(dir, manifest)
    end)
    devos.fstat = fstat
    assert(ok, err)
    t.eq(none, nil)
    t.eq(message, "cannot open " .. manifest)
    fs.remove(base, { recursive = true })
end)

t.test("a refused manifest never reaches the driver and leaves no copy", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = project(base, "p", "x\n")
    assert(devos.run({ "chmod", "g+w", dir .. "/.dev" }) == 0, "chmod failed")
    local before = temp_count()
    local code, seen = run_as_root(dir, "tools check")
    t.eq(code, 1)
    t.eq(seen, nil)
    t.eq(temp_count(), before)
    fs.remove(base, { recursive = true })
end)

t.test("a removed working directory exits 1 at once and names it", function()
    local base = assert(fs.realpath(support.tempdir()))
    local dir = base .. "/gone"
    assert(fs.mkdir(dir))
    local out, code = devos.capture_timed({
        "sh",
        "-c",
        'cd "$1" && rmdir "$1" && exec luajit "$2" help',
        "sh",
        dir,
        MAIN,
    }, 1, { merge = true, env = { CI = "", DEV_REMOTE = "0" } })
    t.eq(code, 1)
    t.ok(out:find("dev: The working directory " .. dir .. " cannot be read.\n", 1, true), out)
    fs.remove(base, { recursive = true })
end)
