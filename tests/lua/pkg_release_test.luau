local testing = require("@dev/testing")
local runtime = require("@dev/runtime")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local kinds = require("@dev/pkg/kinds")
local release = require("@dev/pkg/release")
local support = require("./support")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local MODULES = REPO .. "/luau"
local ZIP_FIXTURE = REPO .. "/tests/lua/fixtures/release/tool.zip"
local TOOL_TEXT = table.concat({ "#!/bin/sh", "echo tool-ok", "" }, "\n")
local URL_BASE = ""
local SERVERS = {}
local ROUTES = {}

local DRIVE = table.concat({
    'local dev_os = require("@dev/os")',
    'local driver = require("@dev/pkg/release")',
    "local row = { name = arg[2], binary = arg[3], package = arg[4], channel = 'release', repo = '' }",
    'local opts = { dry_run = arg[5] == "1", force = arg[6] == "1", log_file = "", releases = arg[7] }',
    "dev_os.stdout:flush()",
    "dev_os.exit(driver[arg[8]](row, opts))",
    "",
}, "\n")

local function write_executable(path, text)
    assert(fs.write(path, text))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function sha256(file)
    return require("@dev/hash").sha256_file(file)
end

local function sandbox()
    -- Make a directory with the folders a run uses
    local dir = assert(fs.realpath(support.tempdir()))
    for _, sub in ipairs({ "assets", "stubs", "tmp", "build" }) do
        assert(fs.mkdir(dir .. "/" .. sub))
    end

    -- Write the driver script that each run executes
    assert(fs.write(dir .. "/drive.luau", DRIVE))

    -- Start a fake download server and record where it serves from
    SERVERS[dir] = support.fake_http({})
    ROUTES[dir] = {}
    URL_BASE = SERVERS[dir].url .. "/dl/"
    return dir
end

local function build_tool(dir, name)
    local src = dir .. "/build/" .. name
    assert(fs.mkdir(src .. "/bin", { parents = true }))
    write_executable(src .. "/bin/tool", TOOL_TEXT)
    return src
end

local function asset(dir, name)
    -- Name the asset file
    local file = dir .. "/assets/" .. name

    -- Build the asset in the format its name asks for
    if name:find("%.tar%.gz$") or name:find("%.tar%.xz$") then
        local flag = name:find("gz$") and "-czf" or "-cJf"
        local src = build_tool(dir, name)
        assert(dev_os.run({ "tar", flag, file, "-C", src, "bin" }) == 0, "tar failed")
    elseif name:find("%.zip$") then
        assert(dev_os.run({ "cp", ZIP_FIXTURE, file }) == 0, "cp failed")
    else
        write_executable(file, TOOL_TEXT)
    end

    -- Serve the asset's bytes from the fake server
    local routes = ROUTES[dir]
    routes[#routes + 1] = { path = "/dl/" .. name, body = assert(fs.read(file)) }
    SERVERS[dir]:set(routes)
    return file
end

local function pins(dir, rows)
    -- Start with the header row
    local lines = { "name version sha256 url path" }

    -- Add one line per pin
    for _, row in ipairs(rows) do
        lines[#lines + 1] = table.concat(row, " ")
    end

    -- Write the file ending in a newline
    lines[#lines + 1] = ""
    assert(fs.write(dir .. "/releases.tsv", table.concat(lines, "\n")))
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
        XDG_STATE_HOME = dir .. "/state",
    }
end

local function receipt_file(dir)
    return dir .. "/state/dev/tools/tool"
end

local function write_receipt(dir, version, sum)
    assert(fs.mkdir(dir .. "/state/dev/tools", { parents = true }))
    assert(fs.write(receipt_file(dir), "tool " .. version .. " " .. sum .. "\n"))
end

local function drive(dir, fn, spec)
    spec = spec or {}
    local argv = {
        runtime.exe,
        "-l",
        dir .. "/drive.luau",
        MODULES,
        "tool",
        spec.binary or "tool",
        spec.package or "tool",
        spec.dry_run and "1" or "0",
        spec.force and "1" or "0",
        dir .. "/releases.tsv",
        fn,
    }
    local path = dir .. "/stubs:" .. dir .. "/pathbin:" .. dev_os.getenv("PATH")
    return dev_os.capture(argv, {
        stderr = "stdout",
        env = env(dir, path),
    })
end

local function cleanup(dir)
    SERVERS[dir]:stop()
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
        -- Pin the asset and install it
        local dir = sandbox()
        local row = pin_asset(dir, case[2], case[3])
        pins(dir, { row })
        local out, code = drive(dir, "install")

        -- Expect an executable tool and no temporary leftovers
        testing.eq(code, 0)
        testing.ok(out:find("installing tool (release 1.2.3)", 1, true), out)
        testing.eq(installed_tool(dir), TOOL_TEXT)
        testing.ok(fs.is_exec(dir .. "/bin/tool"), "the binary must be executable")
        testing.eq(leftovers(dir), {})
        testing.eq(fs.read(receipt_file(dir)), "tool 1.2.3 " .. row[3] .. "\n")

        -- Expect the download to reach the server
        local logged = SERVERS[dir]:requests()
        testing.ok(logged:find("GET /dl/", 1, true), logged)

        -- Expect check to report the tool as installed
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
    testing.ok(out:find("Expected " .. wrong .. ", got " .. right .. ".", 1, true), out)
    testing.eq(fs.list(dir .. "/bin"), nil)
    testing.eq(leftovers(dir), {})
    cleanup(dir)
end)

testing.test("a wrong sha256 keeps the tool that was already installed", function()
    -- Install an old copy of the tool by hand
    local dir = sandbox()
    assert(fs.mkdir(dir .. "/bin"))
    write_executable(dir .. "/bin/tool", "old\n")

    -- Pin an asset under the wrong sum
    local row = pin_asset(dir, "tool-VERSION", "-")
    row[3] = ("0"):rep(64)
    pins(dir, { row })

    -- Expect a forced install to fail and leave the old copy alone
    local _, code = drive(dir, "install", { force = true })
    testing.eq(code, 1)
    testing.eq(installed_tool(dir), "old\n")
    testing.eq(fs.list(dir .. "/bin"), { "tool" })
    cleanup(dir)
end)

testing.test("a file:// pin installs a local tarball and checks its sha256", function()
    local dir = sandbox()
    local file = asset(dir, "tool-1.2.3.tar.gz")
    local row = { "tool", "1.2.3", sha256(file), "file://" .. file, "bin/tool" }
    pins(dir, { row })
    local out, code = drive(dir, "install")
    testing.eq(code, 0)
    testing.ok(out:find("installing tool (release 1.2.3)", 1, true), out)
    testing.eq(installed_tool(dir), TOOL_TEXT)
    testing.eq(leftovers(dir), {})
    testing.eq(SERVERS[dir]:requests(), "")
    cleanup(dir)
end)

testing.test("a file:// pin with the wrong sha256 is refused and leaves nothing behind", function()
    local dir = sandbox()
    local file = asset(dir, "tool-1.2.3.tar.gz")
    local wrong = ("0"):rep(64)
    pins(dir, { { "tool", "1.2.3", wrong, "file://" .. file, "bin/tool" } })
    local out, code = drive(dir, "install")
    testing.eq(code, 1)
    testing.ok(out:find("Expected " .. wrong .. ", got " .. sha256(file) .. ".", 1, true), out)
    testing.eq(fs.list(dir .. "/bin"), nil)
    testing.eq(leftovers(dir), {})
    cleanup(dir)
end)

testing.test("a file:// pin to a missing file fails and leaves nothing behind", function()
    local dir = sandbox()
    pins(dir, { { "tool", "1.2.3", ("0"):rep(64), "file://" .. dir .. "/assets/none", "-" } })
    local out, code = drive(dir, "install")
    testing.eq(code, 1)
    testing.ok(out:find("Failed to download file://" .. dir .. "/assets/none.", 1, true), out)
    testing.eq(leftovers(dir), {})
    cleanup(dir)
end)

testing.test("a failed download fails and leaves nothing behind", function()
    local dir = sandbox()
    local row = pin_asset(dir, "tool-VERSION", "-")
    ROUTES[dir] = {}
    SERVERS[dir]:set(ROUTES[dir])
    pins(dir, { row })
    local out, code = drive(dir, "install")
    testing.eq(code, 1)
    testing.ok(out:find("Failed to download " .. URL_BASE .. "tool-1.2.3.", 1, true), out)
    testing.eq(leftovers(dir), {})
    cleanup(dir)
end)

testing.test("a failed extract fails naming the url and leaves nothing behind", function()
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION.tar.gz", "bin/tool") })
    write_executable(dir .. "/stubs/tar", table.concat({ "#!/bin/sh", "exit 1", "" }, "\n"))
    local out, code = drive(dir, "install")
    testing.eq(code, 1)
    testing.ok(out:find("Failed to extract " .. URL_BASE .. "tool-1.2.3.tar.gz.", 1, true), out)
    testing.eq(leftovers(dir), {})
    cleanup(dir)
end)

testing.test("each reason of a fetch has a sentence that names what it holds", function()
    local pin = { url = URL_BASE .. "tool", sha256 = "aa" }
    local Reason = release.Reason
    testing.eq(
        release.refusal(pin, Reason.HASH_FAILED, "/tmp/f"),
        "Could not read the sha256 of /tmp/f."
    )
    testing.eq(
        release.refusal(pin, Reason.MISMATCH, "bb"),
        "The sha256 of " .. pin.url .. " does not match the pin. Expected aa, got bb."
    )
    testing.eq(
        release.refusal(pin, Reason.NO_FILE, "bin/tool"),
        "The archive holds no file bin/tool."
    )
    testing.eq(
        release.refusal(pin, Reason.DOWNLOAD, pin.url),
        "Failed to download " .. pin.url .. "."
    )
    testing.eq(
        release.refusal(pin, Reason.EXTRACT, pin.url),
        "Failed to extract " .. pin.url .. "."
    )
end)

testing.test("the dry run prints every step and changes nothing", function()
    -- Pin a tarball asset
    local dir = sandbox()
    local row = pin_asset(dir, "tool-VERSION.tar.gz", "bin/tool")
    pins(dir, { row })

    -- Run the install as a dry run
    local out, code = drive(dir, "install", { dry_run = true })
    testing.eq(code, 0)

    -- Expect every step to be printed
    testing.eq(
        out,
        table.concat({
            "  + tool (dry-run):",
            "      download " .. URL_BASE .. "tool-1.2.3.tar.gz to <download>",
            "      sha256 <download>  (expect " .. row[3] .. ")",
            "      tar -xzf <download> -C <extract>",
            "      install -m 755 <extract>/bin/tool " .. dir .. "/bin/tool",
            "",
        }, "\n")
    )

    -- Expect nothing to be made, fetched or left behind
    testing.ok(not fs.exists(dir .. "/bin"), "the bin directory must not be made")
    testing.eq(SERVERS[dir]:requests(), "")
    testing.eq(leftovers(dir), {})
    cleanup(dir)
end)

testing.test("the dry run of a bare binary and a zip names the right steps", function()
    -- Pin a bare binary and dry-run its install
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION", "-") })
    local bare = drive(dir, "install", { dry_run = true })

    -- Expect a plain install step with no archive tool
    testing.ok(not bare:find("tar ", 1, true) and not bare:find("unzip", 1, true), bare)
    testing.ok(bare:find("install -m 755 <download> " .. dir .. "/bin/tool", 1, true), bare)

    -- Pin a zip instead and expect an unzip step
    pins(dir, { pin_asset(dir, "tool-VERSION.zip", "bin/tool") })
    local zip = drive(dir, "install", { dry_run = true })
    testing.ok(zip:find("unzip -q -o <download> -d <extract>", 1, true), zip)
    cleanup(dir)
end)

testing.test("a tool on PATH is skipped, and force reinstalls it", function()
    -- Put a copy of the tool on PATH
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION", "-") })
    assert(fs.mkdir(dir .. "/pathbin"))
    write_executable(dir .. "/pathbin/tool", "#!/bin/sh\n")

    -- Expect the install to skip it, name where it is and install nothing
    local skipped, code = drive(dir, "install")
    testing.eq(code, 0)
    testing.eq(
        skipped,
        "  = tool already on PATH at "
            .. dir
            .. "/pathbin/tool, outside "
            .. dir
            .. "/bin, skipping\n"
    )
    testing.ok(not fs.exists(dir .. "/bin/tool"), "a skipped tool installs nothing")

    -- Expect force to install it anyway
    local _, forced = drive(dir, "install", { force = true })
    testing.eq(forced, 0)
    testing.eq(installed_tool(dir), TOOL_TEXT)
    cleanup(dir)
end)

testing.test("a tool whose receipt matches its pin is skipped, and force replaces it", function()
    -- Put a copy of the tool in the bin directory under a receipt that matches the pin
    local dir = sandbox()
    local row = pin_asset(dir, "tool-VERSION", "-")
    pins(dir, { row })
    assert(fs.mkdir(dir .. "/bin"))
    write_executable(dir .. "/bin/tool", "old\n")
    write_receipt(dir, "1.2.3", row[3])

    -- Expect the install to skip it and keep the old copy
    local skipped, code = drive(dir, "install")
    testing.eq(code, 0)
    testing.eq(skipped, "  = tool already installed in " .. dir .. "/bin, skipping\n")
    testing.eq(installed_tool(dir), "old\n")

    -- Expect force to replace it
    local _, forced = drive(dir, "install", { force = true })
    testing.eq(forced, 0)
    testing.eq(installed_tool(dir), TOOL_TEXT)
    testing.eq(fs.list(dir .. "/bin"), { "tool" })
    cleanup(dir)
end)

testing.test("a tool whose receipt names an older version is replaced without force", function()
    local dir = sandbox()
    local row = pin_asset(dir, "tool-VERSION", "-")
    pins(dir, { row })
    assert(fs.mkdir(dir .. "/bin"))
    write_executable(dir .. "/bin/tool", "old\n")
    write_receipt(dir, "1.2.2", row[3])

    local out, code = drive(dir, "install")
    testing.eq(code, 0)
    testing.ok(out:find("installing tool (release 1.2.3)", 1, true), out)
    testing.eq(installed_tool(dir), TOOL_TEXT)
    testing.eq(fs.read(receipt_file(dir)), "tool 1.2.3 " .. row[3] .. "\n")
    cleanup(dir)
end)

testing.test("a tool whose receipt names another sha256 is replaced without force", function()
    local dir = sandbox()
    local row = pin_asset(dir, "tool-VERSION", "-")
    pins(dir, { row })
    assert(fs.mkdir(dir .. "/bin"))
    write_executable(dir .. "/bin/tool", "old\n")
    write_receipt(dir, "1.2.3", ("0"):rep(64))

    local _, code = drive(dir, "install")
    testing.eq(code, 0)
    testing.eq(installed_tool(dir), TOOL_TEXT)
    cleanup(dir)
end)

testing.test("a tool in the bin directory with no receipt is replaced without force", function()
    local dir = sandbox()
    local row = pin_asset(dir, "tool-VERSION", "-")
    pins(dir, { row })
    assert(fs.mkdir(dir .. "/bin"))
    write_executable(dir .. "/bin/tool", "old\n")

    local _, code = drive(dir, "install")
    testing.eq(code, 0)
    testing.eq(installed_tool(dir), TOOL_TEXT)
    testing.eq(fs.read(receipt_file(dir)), "tool 1.2.3 " .. row[3] .. "\n")
    cleanup(dir)
end)

testing.test("a bin directory tool that PATH reaches through a link is not outside it", function()
    -- Link the bin directory's tool into a directory on PATH, as a home bin directory on PATH is
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION", "-") })
    assert(fs.mkdir(dir .. "/bin"))
    assert(fs.mkdir(dir .. "/pathbin"))
    write_executable(dir .. "/bin/tool", "old\n")
    assert(fs.symlink(dir .. "/bin/tool", dir .. "/pathbin/tool"))

    -- Expect the stale copy to be replaced, not skipped as a PATH tool
    local out, code = drive(dir, "install")
    testing.eq(code, 0)
    testing.ok(out:find("installing tool (release 1.2.3)", 1, true), out)
    testing.eq(installed_tool(dir), TOOL_TEXT)
    cleanup(dir)
end)

testing.test("a failed install leaves the receipt of the tool it kept", function()
    local dir = sandbox()
    local row = pin_asset(dir, "tool-VERSION", "-")
    row[3] = ("0"):rep(64)
    pins(dir, { row })
    assert(fs.mkdir(dir .. "/bin"))
    write_executable(dir .. "/bin/tool", "old\n")
    write_receipt(dir, "1.2.2", ("b"):rep(64))

    local _, code = drive(dir, "install")
    testing.eq(code, 1)
    testing.eq(installed_tool(dir), "old\n")
    testing.eq(fs.read(receipt_file(dir)), "tool 1.2.2 " .. ("b"):rep(64) .. "\n")
    cleanup(dir)
end)

testing.test("check prints [!] with both versions for a drifted tool and exits 1", function()
    local dir = sandbox()
    local row = pin_asset(dir, "tool-VERSION", "-")
    pins(dir, { row })
    assert(fs.mkdir(dir .. "/bin"))
    write_executable(dir .. "/bin/tool", "old\n")
    write_receipt(dir, "1.2.2", row[3])

    local out, code = drive(dir, "check")
    testing.eq(code, 1)
    testing.eq(out, "[!] tool\t(installed 1.2.2, pinned 1.2.3)\n")
    cleanup(dir)
end)

testing.test("check prints [!] with no receipt for a binary dev did not record", function()
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION", "-") })
    assert(fs.mkdir(dir .. "/bin"))
    write_executable(dir .. "/bin/tool", "old\n")

    local out, code = drive(dir, "check")
    testing.eq(code, 1)
    testing.eq(out, "[!] tool\t(no receipt, pinned 1.2.3)\n")
    cleanup(dir)
end)

testing.test(
    "check passes a tool whose receipt matches and a tool on PATH outside the bin",
    function()
        -- Expect a matching receipt to pass
        local dir = sandbox()
        local row = pin_asset(dir, "tool-VERSION", "-")
        pins(dir, { row })
        assert(fs.mkdir(dir .. "/bin"))
        write_executable(dir .. "/bin/tool", "old\n")
        write_receipt(dir, "1.2.3", row[3])
        local out, code = drive(dir, "check")
        testing.eq({ out, code }, { "[x] tool\t(" .. dir .. "/bin/tool)\n", 0 })

        -- Expect a PATH copy elsewhere to pass whatever the receipt says
        assert(fs.mkdir(dir .. "/pathbin"))
        write_executable(dir .. "/pathbin/tool", "#!/bin/sh\n")
        write_receipt(dir, "1.2.2", row[3])
        out, code = drive(dir, "check")
        testing.eq({ out, code }, { "[x] tool\t(" .. dir .. "/pathbin/tool)\n", 0 })
        cleanup(dir)
    end
)

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
    testing.ok(out:find("No pin named other", 1, true), out)
    cleanup(dir)
end)

testing.test("a symlink that leaves the archive is refused", function()
    -- Build an archive whose binary is a link out of it
    local dir = sandbox()
    local src = dir .. "/build/evil"
    assert(fs.mkdir(src .. "/bin", { parents = true }))
    assert(fs.symlink("/etc/hosts", src .. "/bin/tool"))

    -- Pack it, serve it and pin it under its real sum
    local file = dir .. "/assets/tool-1.2.3.tar.gz"
    assert(dev_os.run({ "tar", "-czf", file, "-C", src, "bin" }) == 0, "tar failed")
    SERVERS[dir]:set({ { path = "/dl/tool-1.2.3.tar.gz", body = assert(fs.read(file)) } })
    pins(
        dir,
        { { "tool", "1.2.3", sha256(file), URL_BASE .. "tool-${version}.tar.gz", "bin/tool" } }
    )

    -- Expect the install to refuse the link and install nothing
    local out, code = drive(dir, "install")
    testing.eq(code, 1)
    testing.ok(out:find("holds no file bin/tool", 1, true), out)
    testing.ok(not fs.exists(dir .. "/bin/tool"), "nothing may be installed")
    cleanup(dir)
end)

local function read_pins(text)
    -- Write the pins file under its header row
    local dir = support.tempdir()
    assert(fs.write(dir .. "/releases.tsv", "name version sha256 url path\n" .. text))

    -- Read the pins back
    local got, err = release.read(dir .. "/releases.tsv")

    -- Remove the file and hand back the result
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
            table.concat({
                "t 1.0 " .. SUM .. " https://h/t -",
                "t 2.0 " .. SUM .. " https://h/u -",
            }, "\n"),
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

local MAIN = table.concat({
    'local dev_os = require("@dev/os")',
    'local code = require("@dev/pkg").main({ table.unpack(arg, 2) })',
    "dev_os.stdout:flush()",
    "dev_os.exit(code)",
    "",
}, "\n")

testing.test("install and check read the pins file beside the manifest", function()
    -- Pin a tarball and write a manifest whose every manager column uses it
    local dir = sandbox()
    pins(dir, { pin_asset(dir, "tool-VERSION.tar.gz", "bin/tool") })
    assert(fs.write(dir .. "/main.luau", MAIN))
    local cell = "release:tool"
    assert(fs.write(
        dir .. "/tools.tsv",
        table.concat({
            "name binary brew pacman dnf apt groups",
            "tool tool " .. ("%s "):rep(4):format(cell, cell, cell, cell) .. "base",
            "",
        }, "\n")
    ))

    -- Run the pkg entry point inside the sandbox
    local function main(sub, ...)
        local path = dir .. "/stubs:" .. dev_os.getenv("PATH")
        local argv = {
            runtime.exe,
            "-l",
            dir .. "/main.luau",
            MODULES,
            sub,
            "--manifest",
            dir .. "/tools.tsv",
            ...,
        }
        return dev_os.capture(argv, {
            stderr = "stdout",
            env = env(dir, path),
        })
    end

    -- Expect check to fail first, an install to succeed, and check to pass after it
    local _, before = main("check")
    testing.eq(before, 1)
    local out, code = main("install", "--scope", "user")
    testing.eq(code, 0)
    testing.ok(out:find("installing tool (release 1.2.3)", 1, true), out)
    testing.eq(installed_tool(dir), TOOL_TEXT)
    local report, after = main("check")
    testing.eq({ report, after }, { "[x] tool\t(" .. dir .. "/bin/tool)\n", 0 })

    -- Expect an install for the system scope to do nothing
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
    testing.ok(out:find("The archive holds no file bin/other.", 1, true), out)
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
    testing.ok(out:find("A directory sits at " .. dir .. "/bin/tool.", 1, true), out)
    testing.eq(fs.list(dir .. "/bin/tool"), {})
    cleanup(dir)
end)
