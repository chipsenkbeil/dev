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
local CONFIG = '[ci]\nrust_target = "linux-target"\nmacos_target = "mac-target"\n'
local STATUS_JSON = '{"status":"%s","jobs":[{"name":"targets","index":1,"target":"%s"}]}'

local function script(root, name, body)
    local path = root .. "/bin/" .. name
    assert(fs.write(path, "#!/bin/sh\n" .. body .. "\n"))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function fake_ci(root)
    script(
        root,
        "ci",
        table.concat({
            'echo "$* target=$CI_DEFAULT_TARGET" >> ' .. root .. "/bin/ci.log",
            'case "$3" in',
            '    run) echo "run$4" ;;',
            '    ps) case "$5" in',
            "        --json)",
            "            [ -f " .. root .. "/failed ] && state=failed || state=passed",
            "            printf '" .. STATUS_JSON .. '\' "$state" "t$4" ;;',
            "    esac ;;",
            "    cp)",
            "        [ -f " .. root .. '/nobinary ] || printf "binary-%s" "$4" > "${5}/dev" ;;',
            "esac",
        }, "\n")
    )
end

local function fake_gh(root, missing_tag)
    script(
        root,
        "gh",
        table.concat({
            'echo "$*" >> ' .. root .. "/bin/gh.log",
            'case "$1" in',
            missing_tag and '    api) echo "gh: Not Found (HTTP 404)"; exit 1 ;;'
                or "    api) echo ok ;;",
            '    release) echo "https://github.com/chipsenkbeil/dev/releases/tag/' .. TAG .. '" ;;',
            "esac",
        }, "\n")
    )
end

local function project(opts)
    opts = opts or {}
    local root = support.sandbox({
        [".dev/commands/publish.luau"] = assert(fs.read(REPO .. "/.dev/commands/publish.luau")),
        [".dev/config.toml"] = opts.config or CONFIG,
    }, {})
    fake_ci(root)
    fake_gh(root, opts.missing_tag)
    return root
end

local function publish(root, extra, env)
    local words = { "publish", TAG }
    for _, word in ipairs(extra or {}) do
        words[#words + 1] = word
    end
    local merged = { HOME = root }
    for name, value in pairs(env or {}) do
        merged[name] = value
    end
    return support.dev(root, words, { env = merged })
end

local function kept_dir(out)
    return out:match("Files kept in ([^\n]+)")
end

testing.test("publish refuses when gh is missing", function()
    local root = project()
    local out, code = publish(root, {}, { FAKE_DEV = "1", FAKE_HIDE = "gh" })
    testing.eq(code, 1)
    testing.ok(out:find("The gh client is not on PATH.", 1, true), out)
    testing.eq(#testenv.calls(root, "ci"), 0)
end)

testing.test("publish refuses when gh is not logged in", function()
    local root = project()
    testenv.fake(root, "gh", { code = 1 })
    local out, code = publish(root)
    testing.eq(code, 1)
    testing.ok(out:find("The gh client is not logged in.", 1, true), out)
    testing.eq(testenv.calls(root, "gh"), { "auth status" })
    testing.eq(#testenv.calls(root, "ci"), 0)
end)

testing.test("publish refuses a tag the GitHub remote lacks and starts no run", function()
    local root = project({ missing_tag = true })
    local out, code = publish(root)
    testing.eq(code, 1)
    testing.ok(
        out:find("The tag " .. TAG .. " is not on github.com/chipsenkbeil/dev yet.", 1, true),
        out
    )
    testing.ok(out:find("dev push --tag " .. TAG, 1, true), out)
    testing.eq(testenv.calls(root, "gh"), {
        "auth status",
        "api repos/chipsenkbeil/dev/git/ref/tags/" .. TAG,
    })
    testing.eq(#testenv.calls(root, "ci"), 0)
end)

testing.test("publish refuses when the user config sets no macOS target", function()
    local root = project({ config = '[ci]\nrust_target = "linux-target"\n' })
    local out, code = publish(root)
    testing.eq(code, 1)
    testing.ok(out:find("sets no ci.macos_target", 1, true), out)
    testing.eq(#testenv.calls(root, "ci"), 0)
end)

testing.test("publish refuses a ci run that did not pass", function()
    local root = project()
    assert(fs.write(root .. "/failed", ""))
    local out, code = publish(root, { "--prerelease" })
    testing.eq(code, 1)
    testing.ok(out:find("did not pass", 1, true), out)
    for _, line in ipairs(testenv.calls(root, "gh")) do
        testing.ok(not line:find("release", 1, true), line)
    end
end)

testing.test("publish refuses when a pulled binary is missing and creates no release", function()
    local root = project()
    assert(fs.write(root .. "/nobinary", ""))
    local out, code = publish(root, { "--prerelease" })
    testing.eq(code, 1)
    testing.ok(out:find("left no binary at targets.1.trun", 1, true), out)
    for _, line in ipairs(testenv.calls(root, "gh")) do
        testing.ok(not line:find("release", 1, true), line)
    end
end)

testing.test(
    "publish starts the targets job of both pipelines on the configured targets",
    function()
        local root = project()
        local out, code = publish(root, { "--prerelease" })
        testing.eq(code, 0, out)
        local calls = testenv.calls(root, "ci")
        local joined = table.concat(calls, "\n")
        local prefix = "-C " .. root .. " run "
        testing.ok(
            joined:find(
                prefix .. "jobs --revision " .. TAG .. " --detach --job targets target=linux-target",
                1,
                true
            ),
            joined
        )
        testing.ok(
            joined:find(
                prefix
                    .. "macos --revision "
                    .. TAG
                    .. " --detach --job targets --arch aarch64 target=mac-target",
                1,
                true
            ),
            joined
        )
        testing.ok(joined:find("cp runjobs:targets.1.trunjobs/dev", 1, true), joined)
        testing.ok(joined:find("cp runmacos:targets.1.trunmacos/dev", 1, true), joined)
    end
)

testing.test("publish names the binaries and writes SHA256SUMS for the release", function()
    local root = project()
    local out, code = publish(root, { "--prerelease" })
    testing.eq(code, 0, out)
    local dir = assert(kept_dir(out), out)
    testing.eq(fs.read(dir .. "/" .. LINUX), "binary-runjobs:targets.1.trunjobs/dev")
    testing.eq(fs.read(dir .. "/" .. MACOS), "binary-runmacos:targets.1.trunmacos/dev")
    local want = hash.sha256("binary-runjobs:targets.1.trunjobs/dev")
        .. "  "
        .. LINUX
        .. "\n"
        .. hash.sha256("binary-runmacos:targets.1.trunmacos/dev")
        .. "  "
        .. MACOS
        .. "\n"
    testing.eq(fs.read(dir .. "/SHA256SUMS"), want)
    testing.ok(out:find("https://github.com/chipsenkbeil/dev/releases/tag/" .. TAG, 1, true), out)
end)

testing.test("publish marks the release a pre-release only with the flag", function()
    local pre = project()
    local out, code = publish(pre, { "--prerelease" })
    testing.eq(code, 0, out)
    local dir = assert(kept_dir(out), out)
    local create = testenv.calls(pre, "gh")[3]
    testing.eq(
        create,
        table.concat({
            "release create " .. TAG,
            dir .. "/" .. LINUX,
            dir .. "/" .. MACOS,
            dir .. "/SHA256SUMS",
            "--repo chipsenkbeil/dev --verify-tag --title " .. TAG,
            "--notes Builds of dev at " .. TAG .. " for the project ports. --prerelease",
        }, " ")
    )

    local plain = project()
    local _, plain_code = publish(plain)
    testing.eq(plain_code, 0)
    testing.ok(not testenv.calls(plain, "gh")[3]:find("--prerelease", 1, true))
end)
