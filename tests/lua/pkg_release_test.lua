local testing = require("dev.testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local kinds = require("dev.pkg.kinds")
local release = require("dev.pkg.release")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
local MODULES = REPO .. "/dotfiles/bin/.local/share/dev/lua"
local ZIP_FIXTURE = REPO .. "/tests/lua/fixtures/release/tool.zip"
local TOOL_TEXT = "#!/bin/sh\necho tool-ok\n"
local URL_BASE = "https://example.test/dl/"

local DRIVE = 'package.path = arg[1] .. "/?.lua"\n'
    .. 'local driver = require("dev.pkg.release")\n'
    .. "local row = { name = arg[2], binary = arg[3], package = arg[4], channel = 'release', repo = '' }\n"
    .. 'local opts = { dry_run = arg[5] == "1", force = arg[6] == "1", log_file = "", releases = arg[7] }\n'
    .. "io.stdout:flush()\n"
    .. "os.exit(driver[arg[8]](row, opts))\n"

local FAKE_CURL = '#!/bin/sh\necho "$*" >>"$FAKE_LOG"\n'
    .. 'while [ "$#" -gt 0 ]; do\n'
    .. '    case "$1" in -o) out=$2; shift ;; esac\n'
    .. "    url=$1\n"
    .. "    shift\n"
    .. "done\n"
    .. 'cp "$FAKE_ASSETS/${url##*/}" "$out"\n'

local function write_executable(path, text)
    assert(fs.write(path, text))
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function sha256(file)
    local out = devos.capture(
        devos.which("shasum") and { "shasum", "-a", "256", file } or { "sha256sum", file }
    )
    return out:match("^(%x+)")
end

local function sandbox()
    local dir = assert(fs.realpath(support.tempdir()))
    for _, sub in ipairs({ "assets", "stubs", "tmp", "build" }) do
        assert(fs.mkdir(dir .. "/" .. sub))
    end
    assert(fs.write(dir .. "/drive.lua", DRIVE))
    write_executable(dir .. "/stubs/curl", FAKE_CURL)
    return dir
end

local function build_tool(dir, name)
    local src = dir .. "/build/" .. name
    assert(fs.mkdir(src .. "/bin", { parents = true }))
    write_executable(src .. "/bin/tool", TOOL_TEXT)
    return src
end

local function asset(dir, name)
    local file = dir .. "/assets/" .. name
    if name:find("%.tar%.gz$") or name:find("%.tar%.xz$") then
        local flag = name:find("gz$") and "-czf" or "-cJf"
        local src = build_tool(dir, name)
        assert(devos.run({ "tar", flag, file, "-C", src, "bin" }) == 0, "tar failed")
    elseif name:find("%.zip$") then
        assert(devos.run({ "cp", ZIP_FIXTURE, file }) == 0, "cp failed")
    else
        write_executable(file, TOOL_TEXT)
    end
    return file
end

local function pins(dir, rows)
    local lines = { "name version sha256 url path" }
    for _, row in ipairs(rows) do
        lines[#lines + 1] = table.concat(row, " ")
    end
    assert(fs.write(dir .. "/releases.tsv", table.concat(lines, "\n") .. "\n"))
end

local function pin_asset(dir, name, path)
    local version = "1.2.3"
    local file = asset(dir, name:gsub("VERSION", version))
    return { "tool", version, sha256(file), URL_BASE .. name:gsub("VERSION", "${version}"), path }
end

local function env(dir, path)
    return {
        PATH = path,
        DEV_TOOLS_BIN = dir .. "/bin",
        TMPDIR = dir .. "/tmp",
        FAKE_ASSETS = dir .. "/assets",
        FAKE_LOG = dir .. "/curl.log",
    }
end

local function drive(dir, fn, spec)
    spec = spec or {}
    local argv = {
        "luajit",
        dir .. "/drive.lua",
        MODULES,
        "tool",
        spec.binary or "tool",
        spec.package or "tool",
        spec.dry_run and "1" or "0",
        spec.force and "1" or "0",
        dir .. "/releases.tsv",
        fn,
    }
    local path = dir .. "/stubs:" .. dir .. "/pathbin:" .. os.getenv("PATH")
    return devos.capture(argv, {
        stderr = "stdout",
        env = env(dir, path),
    })
end

local function cleanup(dir)
    fs.remove(dir, { recursive = true })
end

local function installed_tool(dir)
    return fs.read(dir .. "/bin/tool")
end

local function leftovers(dir)
    return fs.list(dir .. "/tmp")
end

for _, case in ipairs({
    { "a bare binary", "tool-VERSION", "-" },
    { "a .tar.gz", "tool-VERSION.tar.gz", "bin/tool" },
    { "a .tar.xz", "tool-VERSION.tar.xz", "bin/tool" },
    { "a .zip", "tool-VERSION.zip", "bin/tool" },
}) do
    testing.test(case[1] .. " installs into the bin directory and passes check", function()
        local dir = sandbox()
        pins(dir, { pin_asset(dir, case[2], case[3]) })
        local out, code = drive(dir, "install")
        testing.eq(code, 0)
        testing.ok(out:find("installing tool (release 1.2.3)", 1, true), out)
        testing.eq(installed_tool(dir), TOOL_TEXT)
        testing.ok(fs.is_exec(dir .. "/bin/tool"), "the binary must be executable")
        testing.eq(leftovers(dir), {})
        local logged = assert(fs.read(dir .. "/curl.log"))
        testing.ok(logged:find("-fsSL", 1, true) and logged:find("--max-time", 1, true), logged)
        local report, status = drive(dir, "check")
        testing.eq(status, 0)
        testing.eq(report, "[x] tool\t(" .. dir .. "/bin/tool)\n")
        cleanup(dir)
    end)
end

testing.test("check reports a missing tool", function()
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION", "-") })
    local out, code = drive(dir, "check")
    testing.eq(code, 1)
    testing.eq(out, "[ ] tool\n")
    cleanup(dir)
end)

testing.test("a wrong sha256 fails naming both sums and leaves nothing behind", function()
    local dir = sandbox()
    local row = pin_asset(dir, "tool-VERSION.tar.gz", "bin/tool")
    local wrong = ("0"):rep(64)
    local right = row[3]
    row[3] = wrong
    pins(dir, { row })
    local out, code = drive(dir, "install")
    testing.eq(code, 1)
    testing.ok(out:find("expected " .. wrong .. ", got " .. right, 1, true), out)
    testing.eq(fs.list(dir .. "/bin"), nil)
    testing.eq(leftovers(dir), {})
    cleanup(dir)
end)

testing.test("a wrong sha256 keeps the tool that was already installed", function()
    local dir = sandbox()
    assert(fs.mkdir(dir .. "/bin"))
    write_executable(dir .. "/bin/tool", "old\n")
    local row = pin_asset(dir, "tool-VERSION", "-")
    row[3] = ("0"):rep(64)
    pins(dir, { row })
    local _, code = drive(dir, "install", { force = true })
    testing.eq(code, 1)
    testing.eq(installed_tool(dir), "old\n")
    testing.eq(fs.list(dir .. "/bin"), { "tool" })
    cleanup(dir)
end)

testing.test("a failed download fails and leaves nothing behind", function()
    local dir = sandbox()
    local row = pin_asset(dir, "tool-VERSION", "-")
    assert(fs.remove(dir .. "/assets/tool-1.2.3"))
    pins(dir, { row })
    local out, code = drive(dir, "install")
    testing.eq(code, 1)
    testing.ok(out:find("failed to download " .. URL_BASE .. "tool-1.2.3", 1, true), out)
    testing.eq(leftovers(dir), {})
    cleanup(dir)
end)

testing.test("the dry run prints every step and changes nothing", function()
    local dir = sandbox()
    local row = pin_asset(dir, "tool-VERSION.tar.gz", "bin/tool")
    pins(dir, { row })
    local out, code = drive(dir, "install", { dry_run = true })
    testing.eq(code, 0)
    local checksum = devos.which("shasum") and "shasum -a 256" or "sha256sum"
    testing.eq(
        out,
        "  + tool (dry-run):\n"
            .. "      curl -fsSL --connect-timeout 15 --max-time 600 -o <download> "
            .. URL_BASE
            .. "tool-1.2.3.tar.gz\n"
            .. "      "
            .. checksum
            .. " <download>  (expect "
            .. row[3]
            .. ")\n"
            .. "      tar -xzf <download> -C <extract>\n"
            .. "      install -m 755 <extract>/bin/tool "
            .. dir
            .. "/bin/tool\n"
    )
    testing.ok(not fs.exists(dir .. "/bin"), "the bin directory must not be made")
    testing.ok(not fs.exists(dir .. "/curl.log"), "nothing may be downloaded")
    testing.eq(leftovers(dir), {})
    cleanup(dir)
end)

testing.test("the dry run of a bare binary and a zip names the right steps", function()
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION", "-") })
    local bare = drive(dir, "install", { dry_run = true })
    testing.ok(not bare:find("tar ", 1, true) and not bare:find("unzip", 1, true), bare)
    testing.ok(bare:find("install -m 755 <download> " .. dir .. "/bin/tool", 1, true), bare)
    pins(dir, { pin_asset(dir, "tool-VERSION.zip", "bin/tool") })
    local zip = drive(dir, "install", { dry_run = true })
    testing.ok(zip:find("unzip -q -o <download> -d <extract>", 1, true), zip)
    cleanup(dir)
end)

testing.test("a tool on PATH is skipped, and force reinstalls it", function()
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION", "-") })
    assert(fs.mkdir(dir .. "/pathbin"))
    write_executable(dir .. "/pathbin/tool", "#!/bin/sh\n")
    local skipped, code = drive(dir, "install")
    testing.eq(code, 0)
    testing.eq(skipped, "  = tool already on PATH, skipping\n")
    testing.ok(not fs.exists(dir .. "/bin/tool"), "a skipped tool installs nothing")
    local _, forced = drive(dir, "install", { force = true })
    testing.eq(forced, 0)
    testing.eq(installed_tool(dir), TOOL_TEXT)
    cleanup(dir)
end)

testing.test("a tool already in the bin directory is skipped, and force replaces it", function()
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION", "-") })
    assert(fs.mkdir(dir .. "/bin"))
    write_executable(dir .. "/bin/tool", "old\n")
    local skipped, code = drive(dir, "install")
    testing.eq(code, 0)
    testing.eq(skipped, "  = tool already installed in " .. dir .. "/bin, skipping\n")
    testing.eq(installed_tool(dir), "old\n")
    local _, forced = drive(dir, "install", { force = true })
    testing.eq(forced, 0)
    testing.eq(installed_tool(dir), TOOL_TEXT)
    testing.eq(fs.list(dir .. "/bin"), { "tool" })
    cleanup(dir)
end)

testing.test("the binary column names the installed file", function()
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION", "-") })
    local _, code = drive(dir, "install", { binary = "renamed" })
    testing.eq(code, 0)
    testing.eq(fs.list(dir .. "/bin"), { "renamed" })
    cleanup(dir)
end)

testing.test("a row with no pin fails naming it", function()
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION", "-") })
    local out, code = drive(dir, "install", { package = "other" })
    testing.eq(code, 1)
    testing.ok(out:find("no pin named other", 1, true), out)
    cleanup(dir)
end)

testing.test("a symlink that leaves the archive is refused", function()
    local dir = sandbox()
    local src = dir .. "/build/evil"
    assert(fs.mkdir(src .. "/bin", { parents = true }))
    assert(fs.symlink("/etc/hosts", src .. "/bin/tool"))
    local file = dir .. "/assets/tool-1.2.3.tar.gz"
    assert(devos.run({ "tar", "-czf", file, "-C", src, "bin" }) == 0, "tar failed")
    pins(
        dir,
        { { "tool", "1.2.3", sha256(file), URL_BASE .. "tool-${version}.tar.gz", "bin/tool" } }
    )
    local out, code = drive(dir, "install")
    testing.eq(code, 1)
    testing.ok(out:find("holds no file bin/tool", 1, true), out)
    testing.ok(not fs.exists(dir .. "/bin/tool"), "nothing may be installed")
    cleanup(dir)
end)

local function read_pins(text)
    local dir = support.tempdir()
    assert(fs.write(dir .. "/releases.tsv", "name version sha256 url path\n" .. text))
    local got, err = release.read(dir .. "/releases.tsv")
    fs.remove(dir, { recursive = true })
    return got, err
end

local SUM = ("a"):rep(64)

testing.test("the reader expands ${version} in the url and keys pins by name", function()
    local got = assert(read_pins("t 1.0 " .. SUM:upper() .. " https://h/t-${version}.zip bin/t\n"))
    testing.eq(got.t, {
        name = "t",
        version = "1.0",
        sha256 = SUM,
        url = "https://h/t-1.0.zip",
        path = "bin/t",
    })
end)

testing.test("the reader refuses a bad pin and names its row", function()
    local cases = {
        { "t 1.0 abc https://h/t -", "not 64 hex digits" },
        { "t 1.0 " .. SUM .. " http://h/t -", "must be https" },
        { "t 1.0 " .. SUM .. " https://h/t.zip -", "needs a path" },
        { "t 1.0 " .. SUM .. " https://h/t bin/t", "needs a path" },
        { "t 1.0 " .. SUM .. " https://h/t.zip ../x", "bad archive path" },
        { "t 1.0 " .. SUM .. " https://h/t.zip /x", "bad archive path" },
        { "t -1 " .. SUM .. " https://h/t -", "bad version" },
        { "-t 1.0 " .. SUM .. " https://h/t -", "bad name" },
        { "t 1.0 " .. SUM .. " https://h/t", "a pin has" },
        {
            "t 1.0 " .. SUM .. " https://h/t -\nt 2.0 " .. SUM .. " https://h/u -",
            "two pins named t",
        },
        { "t 1.0 " .. SUM .. " https://h/$(id) -", "plain word" },
    }
    for _, case in ipairs(cases) do
        local got, err = read_pins(case[1] .. "\n")
        testing.ok(got == nil and err:find(case[2], 1, true), case[1] .. " -> " .. tostring(err))
    end
end)

testing.test("release rows route to the user scope and the release driver", function()
    local scope, driver = kinds.route("release", kinds.Manager.BREW)
    testing.eq({ scope, driver }, { kinds.Scope.USER, "release" })
    testing.ok(kinds.DRIVERS.release, "release must have a driver")
end)

local MAIN = 'package.path = arg[1] .. "/?.lua"\n'
    .. 'local code = require("dev.pkg").main({ unpack(arg, 3) }, { interpreter = "luajit", modules = arg[1], manifest = arg[2] })\n'
    .. "io.stdout:flush()\n"
    .. "os.exit(code)\n"

testing.test("install and check read the pins file beside the manifest", function()
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION.tar.gz", "bin/tool") })
    assert(fs.write(dir .. "/main.lua", MAIN))
    local cell = "release:tool"
    assert(
        fs.write(
            dir .. "/tools.tsv",
            "name binary brew pacman dnf apt groups\ntool tool "
                .. ("%s "):rep(4):format(cell, cell, cell, cell)
                .. "base\n"
        )
    )
    local function main(...)
        local path = dir .. "/stubs:" .. os.getenv("PATH")
        return devos.capture({ "luajit", dir .. "/main.lua", MODULES, dir .. "/tools.tsv", ... }, {
            stderr = "stdout",
            env = env(dir, path),
        })
    end
    local _, before = main("check")
    testing.eq(before, 1)
    local out, code = main("install", "--scope", "user")
    testing.eq(code, 0)
    testing.ok(out:find("installing tool (release 1.2.3)", 1, true), out)
    testing.eq(installed_tool(dir), TOOL_TEXT)
    local report, after = main("check")
    testing.eq({ report, after }, { "[x] tool\t(" .. dir .. "/bin/tool)\n", 0 })
    local system, scoped = main("install", "--scope", "system")
    testing.eq({ system, scoped }, { "", 0 })
    cleanup(dir)
end)

testing.test("an archive without the named file fails and leaves nothing behind", function()
    local dir = sandbox()
    local row = pin_asset(dir, "tool-VERSION.tar.xz", "bin/other")
    pins(dir, { row })
    local out, code = drive(dir, "install")
    testing.eq(code, 1)
    testing.ok(out:find("holds no file bin/other", 1, true), out)
    testing.ok(not fs.exists(dir .. "/bin/tool"), "nothing may be installed")
    testing.eq(leftovers(dir), {})
    cleanup(dir)
end)

testing.test("a directory where the binary belongs is refused, even with force", function()
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION", "-") })
    assert(fs.mkdir(dir .. "/bin/tool", { parents = true }))
    local out, code = drive(dir, "install", { force = true })
    testing.eq(code, 1)
    testing.ok(out:find("is a directory", 1, true), out)
    testing.eq(fs.list(dir .. "/bin/tool"), {})
    cleanup(dir)
end)
