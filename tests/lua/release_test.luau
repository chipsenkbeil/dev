local dev_os = require("dev.os")
local fs = require("dev.fs")
local hash = require("dev.hash")
local testenv = require("dev.testenv")
local testing = require("dev.testing")
local support = require("support")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local TAG = "v0.1.0-pre.1"
local LINUX = "dev-" .. TAG .. "-x86_64-unknown-linux-musl"
local MACOS = "dev-" .. TAG .. "-aarch64-apple-darwin"

local function script(root, name, body)
    local path = root .. "/bin/" .. name
    assert(fs.write(path, "#!/bin/sh\n" .. body .. "\n"))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function fake_gh(root)
    script(
        root,
        "gh",
        table.concat({
            'echo "$*" >> ' .. root .. "/bin/gh.log",
            'case "$2" in',
            "    view)",
            "        if [ -f " .. root .. "/held ]; then",
            "            cat " .. root .. "/held",
            "        else",
            '            echo "release not found"; exit 1',
            "        fi ;;",
            '    create|upload) echo "https://github.com/chipsenkbeil/dev/releases/tag/'
                .. TAG
                .. '" ;;',
            "esac",
        }, "\n")
    )
end

local function project()
    local files = {}
    for _, name in ipairs({ "DESCRIPTION", "build.luau", "test.luau", "publish.luau" }) do
        local path = ".dev/commands/release/" .. name
        files[path] = assert(fs.read(REPO .. "/" .. path))
    end
    local root = support.sandbox(files, {})
    fake_gh(root)
    script(root, "cargo", 'echo "$* tag=$DEV_RELEASE_TAG" >> ' .. root .. "/bin/cargo.log")
    return root
end

local function release(root, words, env)
    local argv = { "release" }
    for _, word in ipairs(words) do
        argv[#argv + 1] = word
    end
    return support.dev(root, argv, { env = env })
end

local function artifacts(root)
    local dir = root .. "/artifacts"
    for _, name in ipairs({ LINUX, MACOS, "dev-v9.9.9-x86_64-unknown-linux-musl" }) do
        assert(fs.mkdir(dir .. "/" .. name, { parents = true }))
        assert(fs.write(dir .. "/" .. name .. "/dev", "binary-" .. name))
    end
    return dir
end

testing.test("build runs the one cargo line with the tag in the environment", function()
    local root = project()
    local out, code = release(root, { "build", "aarch64-apple-darwin", "--tag", TAG })
    testing.eq(code, 0, out)
    testing.eq(
        testenv.calls(root, "cargo"),
        { "build --release --locked --target aarch64-apple-darwin tag=" .. TAG }
    )
    testing.ok(out:find("target/aarch64-apple-darwin/release/dev", 1, true), out)
end)

testing.test("build leaves the tag unset without the flag and zigbuilds on request", function()
    local root = project()
    local out, code = release(root, { "build", "x86_64-unknown-linux-musl", "--zigbuild" })
    testing.eq(code, 0, out)
    testing.eq(
        testenv.calls(root, "cargo"),
        { "zigbuild --release --locked --target x86_64-unknown-linux-musl tag=" }
    )
end)

testing.test("build exits 1 when cargo fails", function()
    local root = project()
    script(root, "cargo", "exit 1")
    local out, code = release(root, { "build", "aarch64-apple-darwin" })
    testing.eq(code, 1)
    testing.ok(out:find("The release build for aarch64-apple-darwin failed.", 1, true), out)
end)

local function fake_binary(root, version, suite_code)
    script(
        root,
        "fakedev",
        table.concat({
            'case "$1" in',
            "    --version) echo 'dev " .. version .. "' ;;",
            '    -l) echo "$*" >> ' .. root .. "/suite.log; exit " .. suite_code .. " ;;",
            "esac",
        }, "\n")
    )
    return root .. "/bin/fakedev"
end

testing.test("test runs --version then the native suite on the binary", function()
    local root = project()
    local binary = fake_binary(root, TAG, 0)
    local out, code = release(root, { "test", binary, "--tag", TAG })
    testing.eq(code, 0, out)
    testing.ok(out:find("dev " .. TAG, 1, true), out)
    testing.eq(fs.read(root .. "/suite.log"), "-l tests/native/runtime_test.luau\n")
end)

testing.test("test refuses a binary whose version is not the tag", function()
    local root = project()
    local binary = fake_binary(root, "0.1.0", 0)
    local out, code = release(root, { "test", binary, "--tag", TAG })
    testing.eq(code, 1)
    testing.ok(out:find("prints dev 0.1.0 from --version, not dev " .. TAG, 1, true), out)
    testing.ok(not fs.exists(root .. "/suite.log"))
end)

testing.test("test fails when the native suite fails", function()
    local root = project()
    local binary = fake_binary(root, TAG, 1)
    local out, code = release(root, { "test", binary })
    testing.eq(code, 1)
    testing.ok(out:find("The native suite failed", 1, true), out)
end)

testing.test("publish creates a pre-release with SHA256SUMS over the tag's assets", function()
    local root = project()
    local dir = artifacts(root)
    local out, code = release(root, { "publish", TAG, "--dir", dir })
    testing.eq(code, 0, out)
    local create = testenv.calls(root, "gh")[2]
    local stage = create:match("^release create %S+ (%S+)/" .. MACOS:gsub("%p", "%%%0") .. " ")
    testing.ok(stage, create)
    testing.eq(
        create,
        table.concat({
            "release create " .. TAG,
            stage .. "/" .. MACOS,
            stage .. "/" .. LINUX,
            stage .. "/SHA256SUMS",
            "--repo chipsenkbeil/dev --verify-tag --title " .. TAG,
            "--notes Builds of dev at " .. TAG .. ". --prerelease",
        }, " ")
    )
    local want = hash.sha256("binary-" .. MACOS)
        .. "  "
        .. MACOS
        .. "\n"
        .. hash.sha256("binary-" .. LINUX)
        .. "  "
        .. LINUX
        .. "\n"
    testing.eq(fs.read(stage .. "/SHA256SUMS"), want)
    testing.ok(out:find("releases/tag/" .. TAG, 1, true), out)
end)

testing.test("publish marks no pre-release for a plain tag", function()
    local root = project()
    local dir = root .. "/artifacts"
    assert(fs.mkdir(dir .. "/dev-v1.0.0-x", { parents = true }))
    assert(fs.write(dir .. "/dev-v1.0.0-x/dev", "bin"))
    local out, code = release(root, { "publish", "v1.0.0", "--dir", dir })
    testing.eq(code, 0, out)
    testing.ok(not testenv.calls(root, "gh")[2]:find("--prerelease", 1, true))
end)

testing.test("publish uploads to a release that exists and refuses a held asset", function()
    local root = project()
    local dir = artifacts(root)
    assert(fs.write(root .. "/held", '{"assets":[{"name":"other"}]}'))
    local out, code = release(root, { "publish", TAG, "--dir", dir })
    testing.eq(code, 0, out)
    testing.ok(
        testenv.calls(root, "gh")[2]:find("release upload " .. TAG .. " ", 1, true) == 1,
        out
    )

    assert(fs.write(root .. "/held", '{"assets":[{"name":"' .. MACOS .. '"}]}'))
    out, code = release(root, { "publish", TAG, "--dir", dir })
    testing.eq(code, 1)
    testing.ok(out:find("already holds the asset " .. MACOS, 1, true), out)
    testing.eq(#testenv.calls(root, "gh"), 3)
end)

testing.test("publish refuses a folder with no artifact of the tag", function()
    local root = project()
    local dir = artifacts(root)
    local out, code = release(root, { "publish", "v0.2.0", "--dir", dir })
    testing.eq(code, 1)
    testing.ok(out:find("holds no dev-v0.2.0-TRIPLE artifact", 1, true), out)
    testing.eq(#testenv.calls(root, "gh"), 0)
end)

testing.test("publish refuses when gh is missing", function()
    local root = project()
    local dir = artifacts(root)
    local out, code = release(
        root,
        { "publish", TAG, "--dir", dir },
        { FAKE_DEV = "1", FAKE_HIDE = "gh" }
    )
    testing.eq(code, 1)
    testing.ok(out:find("The gh client is not on PATH.", 1, true), out)
end)
