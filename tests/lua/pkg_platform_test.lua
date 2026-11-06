local t = require("dev.testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
local PKG = REPO .. "/dotfiles/bin/.local/share/dev/pkg.lua"
local SHA = string.rep("a", 64)

local UNAME = '#!/bin/sh\ncase "$1" in -m) echo "$FAKE_ARCH" ;; *) echo "$FAKE_KERNEL" ;; esac\n'
local BREW = '#!/bin/sh\necho "$*" >>"$BREW_LOG"\nexit 1\n'

local MANIFEST = table.concat({
    "name binary brew pacman darwin-x86_64 groups",
    "dropped dropped-zzz brew-pkg pacman-pkg - base",
    "shipped sh brew-ship pacman-ship system:sh base",
    "missing missing-zzz brew-miss pacman-miss system:missing-zzz base",
    "pinned pinned-zzz brew-pin pacman-pin release:pinned base",
    "",
}, "\n")

local function executable(path, text)
    assert(fs.write(path, text))
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function sandbox(manifest)
    local dir = assert(fs.realpath(support.tempdir()))
    assert(fs.mkdir(dir .. "/stubs"))
    executable(dir .. "/stubs/uname", UNAME)
    executable(dir .. "/stubs/brew", BREW)
    executable(dir .. "/stubs/pacman", "#!/bin/sh\nexit 1\n")
    assert(fs.write(dir .. "/tools.tsv", manifest or MANIFEST))
    assert(
        fs.write(
            dir .. "/releases.tsv",
            "name version sha256 url path\npinned 1.0 "
                .. SHA
                .. " https://example.test/pinned-${version} -\n"
        )
    )
    return dir
end

local function run(dir, kernel, arch, args)
    local argv = { "luajit", PKG, unpack(args) }
    argv[#argv + 1] = "--manifest"
    argv[#argv + 1] = dir .. "/tools.tsv"
    return devos.capture(argv, {
        stderr = "stdout",
        env = {
            PATH = dir .. "/stubs:" .. os.getenv("PATH"),
            FAKE_KERNEL = kernel,
            FAKE_ARCH = arch,
            BREW_LOG = dir .. "/brew.log",
            DEV_TOOLS_BIN = dir .. "/bin",
        },
    })
end

t.test("Darwin x86_64 reads its own column and never calls brew", function()
    local dir = sandbox()
    local out, code = run(dir, "Darwin", "x86_64", { "install", "--dry-run" })
    t.eq(code, 0)
    t.ok(out:find("shipped installed outside dev tools", 1, true), out)
    t.ok(out:find("pinned (dry-run)", 1, true), out)
    t.ok(not out:find("brew-", 1, true), out)
    t.ok(not fs.exists(dir .. "/brew.log"), "brew must not run")
    fs.remove(dir, { recursive = true })
end)

t.test("a dash cell is skipped by install and check, and a system cell is only probed", function()
    local dir = sandbox()
    local out, code = run(dir, "Darwin", "x86_64", { "check" })
    t.eq(code, 1)
    t.ok(out:find("[x] shipped", 1, true), out)
    t.ok(out:find("[ ] missing", 1, true), out)
    t.ok(not out:find("dropped", 1, true), out)
    out, code = run(dir, "Darwin", "x86_64", { "install", "--dry-run" })
    t.ok(not out:find("dropped", 1, true), out)
    t.ok(out:find("= missing installed outside dev tools", 1, true), out)
    fs.remove(dir, { recursive = true })
end)

t.test("a bare package in the darwin-x86_64 column is an error naming the row", function()
    local dir =
        sandbox("name binary brew darwin-x86_64 groups\nbare-row bare-zzz brew-bare ripgrep base\n")
    local out, code = run(dir, "Darwin", "x86_64", { "install", "--dry-run" })
    t.eq(code, 1)
    t.ok(out:find("! bare-row: a darwin-x86_64 cell takes", 1, true), out)
    out, code = run(dir, "Darwin", "x86_64", { "check" })
    t.eq(code, 1)
    t.ok(out:find("[ ] bare-row", 1, true), out)
    t.ok(not fs.exists(dir .. "/brew.log"), "brew must not run")
    fs.remove(dir, { recursive = true })
end)

t.test("Apple Silicon still reads the brew column", function()
    local dir = sandbox()
    local out, code = run(dir, "Darwin", "arm64", { "check" })
    t.eq(code, 1)
    t.ok(fs.exists(dir .. "/brew.log"), "brew must run")
    t.ok(out:find("[ ] dropped", 1, true), out)
    fs.remove(dir, { recursive = true })
end)

t.test("Linux still reads its own manager column", function()
    local dir = sandbox()
    local out = run(dir, "Linux", "x86_64", { "install", "--dry-run" })
    t.ok(out:find("pacman-pkg", 1, true), out)
    t.ok(not out:find("brew-", 1, true), out)
    t.ok(not fs.exists(dir .. "/brew.log"), "brew must not run")
    fs.remove(dir, { recursive = true })
end)

t.test("Linux with only apt-get reads the apt column", function()
    local dir = sandbox(table.concat({
        "name binary apt pacman groups",
        "fresh fresh-zzz apt-fresh pacman-fresh base",
        "present present-zzz apt-present pacman-present base",
        "pinned pinned-zzz release:pinned pacman-pin base",
        "dropped dropped-zzz - pacman-drop base",
        "",
    }, "\n"))
    assert(devos.run({ "rm", dir .. "/stubs/pacman", dir .. "/stubs/brew" }) == 0, "rm failed")
    executable(
        dir .. "/stubs/dpkg-query",
        '#!/bin/sh\ncase "$4" in apt-present) echo "install ok installed" ;; *) exit 1 ;; esac\n'
    )
    executable(dir .. "/stubs/apt-get", "#!/bin/sh\nexit 0\n")
    assert(fs.mkdir(dir .. "/sys"))
    assert(devos.run({ "ln", "-s", "/bin/sh", dir .. "/sys/sh" }) == 0, "ln failed")
    local luajit = devos.capture({ "sh", "-c", "command -v luajit" }):gsub("\n$", "")
    local out, code = devos.capture({
        luajit,
        PKG,
        "install",
        "--dry-run",
        "--manifest",
        dir .. "/tools.tsv",
    }, {
        stderr = "stdout",
        env = {
            PATH = dir .. "/stubs:" .. dir .. "/sys",
            FAKE_KERNEL = "Linux",
            FAKE_ARCH = "x86_64",
            DEV_TOOLS_BIN = dir .. "/bin",
        },
    })
    t.eq(code, 0)
    local _, updates = out:gsub("apt%-get update", "")
    t.eq(updates, 1)
    t.ok(out:find("apt-get install -y -- apt-fresh", 1, true), out)
    t.ok(out:find("present already installed via apt", 1, true), out)
    t.ok(not out:find("pacman", 1, true), out)
    t.ok(out:find("pinned (dry-run):", 1, true), out)
    fs.remove(dir, { recursive = true })
end)
