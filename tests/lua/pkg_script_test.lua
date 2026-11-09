local testing = require("dev.testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
local MODULES = REPO .. "/dotfiles/bin/.local/share/dev/lua"

local DRIVE = 'package.path = arg[1] .. "/?.lua"\n'
    .. 'local driver = require("dev.pkg." .. arg[2])\n'
    .. "local row = { name = arg[3], binary = arg[4], package = arg[5], channel = arg[6], repo = arg[7] }\n"
    .. 'local opts = { dry_run = arg[8] == "1", force = arg[9] == "1", log_file = "", interpreter = arg[10], modules = arg[1] }\n'
    .. "io.stdout:flush()\n"
    .. "os.exit(driver[arg[11]](row, opts))\n"

local function sandbox()
    local dir = assert(fs.realpath(support.tempdir()))
    assert(fs.write(dir .. "/drive.lua", DRIVE))
    return dir
end

local function drive(dir, spec)
    local argv = {
        "luajit",
        dir .. "/drive.lua",
        MODULES,
        spec.driver,
        spec.name or "tool",
        spec.binary or "zzz-no-such-binary",
        spec.package,
        spec.channel or "",
        spec.repo or "",
        spec.dry_run and "1" or "0",
        spec.force and "1" or "0",
        spec.interpreter or "luajit",
        spec.fn or "install",
    }
    return devos.capture(argv, { stderr = "stdout", env = spec.env })
end

local function script_row(dir, source, args, extra)
    local spec = { driver = "script", channel = "script", package = source .. (args or "") }
    for key, value in pairs(extra or {}) do
        spec[key] = value
    end
    return drive(dir, spec)
end

local function write_executable(path, text)
    assert(fs.write(path, text))
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
end

testing.test("a script argument that looks like a command substitution is one argv word", function()
    local dir = sandbox()
    local out = dir .. "/out"
    write_executable(dir .. "/args.sh", 'printf "%s|" "$#" "$@" >"' .. out .. '"\n')
    local hostile = "$(>" .. dir .. "/PWNED)"
    local _, code = script_row(dir, dir .. "/args.sh", " " .. hostile)
    testing.eq(code, 0)
    testing.ok(not fs.exists(dir .. "/PWNED"), "the argument must not run")
    testing.eq(fs.read(out), "1|" .. hostile .. "|")
    fs.remove(dir, { recursive = true })
end)

testing.test("a script argument with a space splits into words and still runs nothing", function()
    local dir = sandbox()
    local out = dir .. "/out"
    write_executable(dir .. "/args.sh", 'printf "%s|" "$#" "$@" >"' .. out .. '"\n')
    local _, code = script_row(dir, dir .. "/args.sh", " $(touch " .. dir .. "/PWNED)")
    testing.eq(code, 0)
    testing.ok(not fs.exists(dir .. "/PWNED"), "the argument must not run")
    testing.eq(fs.read(out), "2|$(touch|" .. dir .. "/PWNED)|")
    fs.remove(dir, { recursive = true })
end)

testing.test(
    "a .lua source runs under the interpreter with dev's modules on package.path",
    function()
        local dir = sandbox()
        local out = dir .. "/out"
        assert(
            fs.write(
                dir .. "/x.lua",
                'local lib = require("dev.pkg.lib")\n'
                    .. 'local f = assert(io.open("'
                    .. out
                    .. '", "w"))\n'
                    .. 'f:write(type(lib.parse_cell), "|", table.concat(arg, ","), "|", os.getenv("PKG_FORCE"))\n'
                    .. "f:close()\n"
            )
        )
        local _, code = script_row(dir, dir .. "/x.lua", " a b")
        testing.eq(code, 0)
        testing.eq(fs.read(out), "function|a,b|0")
        fs.remove(dir, { recursive = true })
    end
)

testing.test("a .lua source is handed to the interpreter the driver was given", function()
    local dir = sandbox()
    local out = dir .. "/out"
    write_executable(dir .. "/interpreter", 'printf "%s|" "$@" >"' .. out .. '"\n')
    local _, code = script_row(dir, dir .. "/x.lua", " a", { interpreter = dir .. "/interpreter" })
    testing.eq(code, 0)
    testing.eq(fs.read(out), dir .. "/x.lua|a|")
    fs.remove(dir, { recursive = true })
end)

testing.test("any other source runs under bash", function()
    local dir = sandbox()
    local out = dir .. "/out"
    assert(fs.write(dir .. "/x.sh", 'printf "%s|%s" "$0" "$*" >"' .. out .. '"\n'))
    local _, code = script_row(dir, dir .. "/x.sh", " a b")
    testing.eq(code, 0)
    testing.eq(fs.read(out), dir .. "/x.sh|a b")
    fs.remove(dir, { recursive = true })
end)

testing.test("the dry run prints luajit for a .lua source and bash for the rest", function()
    local dir = sandbox()
    local lua = script_row(dir, "/x/y.lua", " --flag", { dry_run = true })
    testing.eq(lua, "  + tool (dry-run):\n      luajit /x/y.lua --flag\n")
    local sh = script_row(dir, "/x/y.sh", " --flag", { dry_run = true })
    testing.eq(sh, "  + tool (dry-run):\n      bash /x/y.sh --flag\n")
    local remote = script_row(dir, "https://h/x.lua", " --flag", { dry_run = true })
    testing.eq(
        remote,
        "  + tool (dry-run):\n      curl -fsSL https://h/x.lua -o /tmp/tool-install.lua && luajit /tmp/tool-install.lua --flag\n"
    )
    local shell_remote = script_row(dir, "https://h/x.sh", nil, { dry_run = true })
    testing.eq(
        shell_remote,
        "  + tool (dry-run):\n      curl -fsSL https://h/x.sh -o /tmp/tool-install.sh && bash /tmp/tool-install.sh\n"
    )
    fs.remove(dir, { recursive = true })
end)

testing.test("a script whose binary is on PATH is skipped unless forced", function()
    local dir = sandbox()
    local out = dir .. "/out"
    assert(fs.write(dir .. "/x.sh", 'printf "%s" "$PKG_FORCE" >"' .. out .. '"\n'))
    local skipped = script_row(dir, dir .. "/x.sh", nil, { binary = "sh" })
    testing.eq(skipped, "  = tool already on PATH, skipping\n")
    testing.ok(not fs.exists(out))
    script_row(dir, dir .. "/x.sh", nil, { binary = "sh", force = true })
    testing.eq(fs.read(out), "1")
    fs.remove(dir, { recursive = true })
end)

testing.test("the pacman driver renders an aur install and refuses an unknown channel", function()
    local dir = sandbox()
    local spec = { driver = "pacman", package = "zzz-no-aur", dry_run = true, channel = "aur" }
    local out, code = drive(dir, spec)
    testing.eq(code, 0)
    testing.ok(out:find("aur.archlinux.org/zzz-no-aur.git", 1, true), out)
    testing.ok(out:find("makepkg -si --noconfirm", 1, true), out)
    spec.channel = "bogus"
    out, code = drive(dir, spec)
    testing.eq(code, 1)
    testing.ok(out:find('unknown pacman channel "bogus"', 1, true), out)
    fs.remove(dir, { recursive = true })
end)

local LINE = "aurbuild ALL=(root) NOPASSWD: /usr/bin/pacman"

local function guarded(dir, build)
    local pacman = require("dev.pkg.pacman")
    return pacman.guarded_build(dir .. "/99-aurbuild", LINE, build)
end

testing.test(
    "the sudoers drop-in exists, mode 0440, only while the build runs and is gone after success",
    function()
        local dir = sandbox()
        local seen = dir .. "/seen"
        local build = {
            "sh",
            "-c",
            'cat "$1" >"$2"; ls -l "$1" | cut -c1-10 >>"$2"',
            "sh",
            dir .. "/99-aurbuild",
            seen,
        }
        testing.eq(devos.run(guarded(dir, build)), 0)
        testing.eq(fs.read(seen), LINE .. "\n-r--r-----\n")
        testing.ok(not fs.exists(dir .. "/99-aurbuild"), "the drop-in must be removed")
        fs.remove(dir, { recursive = true })
    end
)

testing.test(
    "the sudoers drop-in is gone and the build's status is kept after a failed build",
    function()
        local dir = sandbox()
        testing.eq(devos.run(guarded(dir, { "sh", "-c", "exit 7" })), 7)
        testing.ok(not fs.exists(dir .. "/99-aurbuild"), "the drop-in must be removed")
        fs.remove(dir, { recursive = true })
    end
)

testing.test(
    "the sudoers drop-in is gone and the build stops when the wrapper gets TERM",
    function()
        local dir = sandbox()
        local pid = dir .. "/pid"
        local build = { "sh", "-c", 'echo $$ >"$1"; exec sleep 30', "sh", pid }
        local driver = 'wrapper_pid=; "$@" & wrapper_pid=$!\n'
            .. 'n=0; while [ ! -s "$PIDFILE" ] && [ $n -lt 100 ]; do sleep 0.1; n=$((n+1)); done\n'
            .. "kill -TERM $wrapper_pid\nwait $wrapper_pid\n"
        assert(fs.write(dir .. "/driver.sh", driver))
        local argv = { "bash", dir .. "/driver.sh", unpack(guarded(dir, build)) }
        local code = devos.run(argv, { env = { PIDFILE = pid } })
        testing.eq(code, 143)
        testing.ok(not fs.exists(dir .. "/99-aurbuild"), "the drop-in must be removed")
        local child = assert(fs.read(pid)):gsub("%s+", "")
        testing.ok(
            devos.run({ "sh", "-c", 'kill -0 "$1" 2>/dev/null', "sh", child }) ~= 0,
            "the build must stop"
        )
        fs.remove(dir, { recursive = true })
    end
)

testing.test("the sudoers path and line reach the wrapper as arguments, not script text", function()
    local dir = sandbox()
    local hostile = dir .. "/x'; touch " .. dir .. "/PWNED; '"
    local pacman = require("dev.pkg.pacman")
    local argv = pacman.guarded_build(hostile, "$(touch " .. dir .. "/PWNED2)", { "true" })
    testing.eq(devos.run(argv, { stderr = "null" }), 1)
    testing.ok(
        not fs.exists(dir .. "/PWNED") and not fs.exists(dir .. "/PWNED2"),
        "nothing may run"
    )
    fs.remove(dir, { recursive = true })
end)
