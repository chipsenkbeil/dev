local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local hash = require("@dev/hash")
local testing = require("@dev/testing")
local support = require("./support")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local TAG = "v0.1.0-pre.1"
local TRIPLES = {
    Linux = "x86_64-unknown-linux-musl",
    Darwin = dev_os.arch() .. "-apple-darwin",
    freebsd = "x86_64-unknown-freebsd",
}
local NAME = "dev-" .. TAG .. "-" .. TRIPLES[dev_os.name()]

local function project()
    local files = {}
    for _, name in ipairs({ "DESCRIPTION", "verify.luau" }) do
        local path = ".dev/commands/release/" .. name
        files[path] = assert(fs.read(REPO .. "/" .. path))
    end
    return support.sandbox(files, {})
end

local function binary(root, version)
    return table.concat({
        "#!/bin/sh",
        'echo "$*" >> ' .. root .. "/run.log",
        'case "$1" in',
        "    --version) echo 'dev " .. version .. "' ;;",
        "esac",
        "",
    }, "\n")
end

local function serve(root, opts)
    local body = binary(root, opts.version or TAG)
    local digest = opts.digest or hash.sha256(body)
    local sums = if opts.unlisted then "" else digest .. "  " .. NAME .. "\n"
    return support.fake_http({
        { path = "/dl/SHA256SUMS", body = sums },
        { path = "/dl/" .. NAME, body = body },
    })
end

local function verify(root, server)
    return support.dev(
        root,
        { "release", "verify", TAG },
        { env = { DEV_RELEASE_URL = server.url .. "/dl" } }
    )
end

testing.test("verify checks the asset against SHA256SUMS and runs --version and help", function()
    local root = project()
    local out, code = verify(root, serve(root, {}))
    testing.eq(code, 0, out)
    testing.ok(out:find("dev " .. TAG, 1, true), out)
    testing.ok(out:find("help ran", 1, true), out)
    testing.eq(fs.read(root .. "/run.log"), "--version\nhelp\n")
end)

testing.test("verify refuses an asset that does not match SHA256SUMS and never runs it", function()
    local root = project()
    local wrong = hash.sha256("another binary")
    local out, code = verify(root, serve(root, { digest = wrong }))
    testing.eq(code, 1)
    testing.ok(out:find("The asset " .. NAME .. " does not match SHA256SUMS", 1, true), out)
    testing.ok(out:find(wrong, 1, true), out)
    testing.ok(not fs.exists(root .. "/run.log"))
end)

testing.test("verify refuses an asset that SHA256SUMS does not list", function()
    local root = project()
    local out, code = verify(root, serve(root, { unlisted = true }))
    testing.eq(code, 1)
    testing.ok(out:find("SHA256SUMS does not list " .. NAME, 1, true), out)
    testing.ok(not fs.exists(root .. "/run.log"))
end)

testing.test("verify refuses a binary whose version is not the tag", function()
    local root = project()
    local out, code = verify(root, serve(root, { version = "0.1.0" }))
    testing.eq(code, 1)
    testing.ok(out:find("prints dev 0.1.0 from --version, not dev " .. TAG, 1, true), out)
end)

testing.test("verify fails when the release holds no asset", function()
    local root = project()
    local server = support.fake_http({})
    local out, code = verify(root, server)
    testing.eq(code, 1)
    testing.ok(out:find("Could not download", 1, true), out)
end)
