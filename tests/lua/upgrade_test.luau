local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local hash = require("@dev/hash")
local releasefile = require("@dev/releasefile")
local runtime = require("@dev/runtime")
local testing = require("@dev/testing")
local upgrade_cmd = require("@dev/cmd/upgrade")
local support = require("./support")

local TAG = "v99.0.0"

local function release_binary(printed)
    return table.concat({
        "#!/bin/sh",
        'case "$1" in',
        `    --version) echo 'dev {printed}' ;;`,
        "esac",
        "",
    }, "\n")
end

local function install(dir)
    assert(fs.mkdir(dir, { parents = true }))
    local path = dir .. "/dev"
    assert(dev_os.run({ "cp", runtime.exe, path }) == 0, "cp failed")
    assert(fs.chmod(path, releasefile.EXECUTABLE_MODE))
    return path
end

local function serve(opts)
    local tag = opts.tag or TAG
    local body = release_binary(opts.printed or tag)
    local name = releasefile.asset_name(tag)
    local sums = `{opts.digest or hash.sha256(body)}  {name}\n`
    local routes = { { path = "/api", body = '{"tag_name":"' .. tag .. '"}' } }
    if not opts.no_assets then
        routes[#routes + 1] = { path = "/dl/SHA256SUMS", body = sums }
        routes[#routes + 1] = { path = "/dl/" .. name, body = body }
    end
    return support.fake_http(routes)
end

local function upgrade(path, server)
    return dev_os.capture({ path, "upgrade" }, {
        cwd = support.tempdir(),
        stderr = "stdout",
        env = {
            DEV_BOARD_TOKEN = "",
            DEV_RELEASE_API = server.url .. "/api",
            DEV_RELEASE_URL = server.url .. "/dl",
            XDG_CONFIG_HOME = support.tempdir(),
        },
    })
end

local function runs_as_before(path, before)
    testing.eq(hash.sha256_file(path), before)
    testing.eq((dev_os.capture({ path, "--version" }):gsub("%s+$", "")), "dev " .. runtime.version)
end

testing.test("upgrade replaces an older install with the latest release", function()
    local dir = support.tempdir() .. "/bin"
    local path = install(dir)
    local out, code = upgrade(path, serve({}))
    testing.eq(code, 0, out)
    testing.ok(out:find("upgraded to dev " .. TAG, 1, true), out)
    testing.eq(fs.read(path), release_binary(TAG))
    testing.ok(fs.is_exec(path))
    testing.eq(fs.list(dir), { "dev" })
end)

testing.test("upgrade says so and changes nothing when the install is current", function()
    local path = install(support.tempdir() .. "/bin")
    local before = hash.sha256_file(path)
    local server = serve({ tag = "v" .. runtime.version })
    local out, code = upgrade(path, server)
    testing.eq(code, 0, out)
    testing.ok(out:find("is current", 1, true), out)
    runs_as_before(path, before)
    testing.ok(not server:requests():find("/dl/", 1, true), server:requests())
end)

testing.test("upgrade refuses a dev built under a cargo target folder and names it", function()
    local root = support.tempdir()
    assert(fs.write(root .. "/Cargo.toml", ""))
    local path = install(root .. "/target/debug")
    local before = hash.sha256_file(path)
    local server = serve({})
    local out, code = upgrade(path, server)
    testing.eq(code, 1)
    testing.ok(out:find(fs.realpath(path), 1, true), out)
    testing.ok(out:find("cargo build", 1, true), out)
    testing.eq(server:requests(), "")
    runs_as_before(path, before)
end)

testing.test("cargo_build reads a Windows path and needs the Cargo.toml beside target", function()
    local with = function(path)
        return path == "C:/src/dev/Cargo.toml"
    end
    testing.ok(upgrade_cmd.cargo_build("C:\\src\\dev\\target\\release\\dev.exe", with))
    testing.ok(
        upgrade_cmd.cargo_build("C:/src/dev/target/x86_64-pc-windows-msvc/release/dev.exe", with)
    )
    testing.ok(not upgrade_cmd.cargo_build("C:\\Users\\me\\bin\\dev.exe", with))
    testing.ok(not upgrade_cmd.cargo_build("C:\\src\\other\\target\\release\\dev.exe", with))
end)

testing.test("is_current counts a pre-release of the latest release as older", function()
    testing.eq(upgrade_cmd.is_current("dev v0.2.0", "0.2.0"), true)
    testing.eq(upgrade_cmd.is_current("dev 0.3.1", "0.2.0"), true)
    testing.eq(upgrade_cmd.is_current("dev v0.1.9", "0.2.0"), false)
    testing.eq(upgrade_cmd.is_current("dev v0.2.0-pre.1", "0.2.0"), false)
    testing.eq(upgrade_cmd.is_current("dev v0.2.0-pre.1", "0.1.9"), true)
    local current, reason = upgrade_cmd.is_current("dev unknown", "0.2.0")
    testing.eq(current, nil)
    testing.ok(reason:find("Could not compare the version unknown", 1, true), reason)
end)

testing.test("upgrade leaves the install alone when the download fails", function()
    local path = install(support.tempdir() .. "/bin")
    local before = hash.sha256_file(path)
    local out, code = upgrade(path, serve({ no_assets = true }))
    testing.eq(code, 1)
    testing.ok(out:find("Could not download", 1, true), out)
    runs_as_before(path, before)
end)

testing.test("upgrade leaves the install alone on a checksum mismatch", function()
    local dir = support.tempdir() .. "/bin"
    local path = install(dir)
    local before = hash.sha256_file(path)
    local out, code = upgrade(path, serve({ digest = hash.sha256("another binary") }))
    testing.eq(code, 1)
    testing.ok(out:find("does not match SHA256SUMS", 1, true), out)
    runs_as_before(path, before)
    testing.eq(fs.list(dir), { "dev" })
end)

testing.test(
    "upgrade leaves the install alone when the new binary prints another version",
    function()
        local path = install(support.tempdir() .. "/bin")
        local before = hash.sha256_file(path)
        local out, code = upgrade(path, serve({ printed = "v98.0.0" }))
        testing.eq(code, 1)
        testing.ok(out:find("prints dev v98.0.0 from --version, not dev " .. TAG, 1, true), out)
        runs_as_before(path, before)
    end
)

testing.test("upgrade leaves the install alone when the old one cannot be moved aside", function()
    local dir = support.tempdir() .. "/bin"
    local path = install(dir)
    assert(fs.mkdir(dir .. "/dev.old", { parents = true }))
    assert(fs.write(dir .. "/dev.old/keep", "x"))
    local before = hash.sha256_file(path)
    local out, code = upgrade(path, serve({}))
    testing.eq(code, 1)
    testing.ok(out:find("aside", 1, true), out)
    runs_as_before(path, before)
    testing.eq(fs.list(dir), { "dev", "dev.old" })
end)
