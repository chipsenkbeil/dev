local testing = require("@dev/testing")
local runtime = require("@dev/runtime")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local hash = require("@dev/hash")
local support = require("./support")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local VERSION = "9.9.9"
local SERVERS = {}
local SYSTEM_TOOLS = {
    "tar",
    "bash",
    "sh",
    "env",
    "chmod",
    "rm",
    "mkdir",
    "mv",
    "cp",
    "cat",
    "install",
    "mktemp",
    "dirname",
    "basename",
    "test",
    "realpath",
    "readlink",
    "find",
    "stat",
    "ln",
    "gzip",
}

local FAKE_MAKE = table.concat({
    "#!/bin/sh",
    'echo "make $*" >>"$FAKE_LOG"',
    'if [ "$1" = install ]; then',
    "    read -r flag <.cfg",
    "    prefix=${flag#--prefix=}",
    '    mkdir -p "$prefix/bin"',
    "    printf '#!/bin/sh\\n' >\"$prefix/bin/stow\"",
    '    chmod 755 "$prefix/bin/stow"',
    "fi",
    "",
}, "\n")

local BATS_INSTALL = table.concat({
    "#!/bin/sh",
    'echo "install.sh $*" >>"$FAKE_LOG"',
    'mkdir -p "$1/bin"',
    "printf '#!/bin/sh\\n' >\"$1/bin/bats\"",
    'chmod 755 "$1/bin/bats"',
    "",
}, "\n")

local STOW_CONFIGURE = table.concat({
    "#!/bin/sh",
    'echo "configure $*" >>"$FAKE_LOG"',
    'echo "$1" >.cfg',
    "",
}, "\n")

local TOOLS = {
    {
        name = "bats",
        root = "bats-core-" .. VERSION,
        file = "install.sh",
        text = BATS_INSTALL,
        url = "bats-${version}.tar.gz",
        asset = "bats-" .. VERSION .. ".tar.gz",
        steps = { "cd '<extract>/bats-core-9.9.9' && 'bash' './install.sh' '" },
        ran = { "install.sh " },
    },
    {
        name = "stow",
        root = "stow-" .. VERSION,
        file = "configure",
        text = STOW_CONFIGURE,
        url = "stow-${version}.tar.gz",
        asset = "stow-" .. VERSION .. ".tar.gz",
        steps = { "'./configure' '--prefix=", "&& 'make'\n", "'make' 'install'" },
        ran = { "configure --prefix=", "make \n", "make install" },
    },
}

local function write_executable(path, text)
    assert(fs.write(path, text))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function sandbox(tool)
    -- Stub the build tools and link the system tools the installer needs
    local dir = assert(fs.realpath(support.tempdir()))
    for _, sub in ipairs({ "assets", "stubs", "pathbin", "tmp", "build", "home" }) do
        assert(fs.mkdir(dir .. "/" .. sub))
    end
    write_executable(dir .. "/stubs/make", FAKE_MAKE)
    write_executable(dir .. "/stubs/perl", table.concat({ "#!/bin/sh", "exit 0", "" }, "\n"))
    for _, name in ipairs(SYSTEM_TOOLS) do
        local real = dev_os.which(name)
        if real then
            assert(fs.symlink(real, dir .. "/pathbin/" .. name))
        end
    end

    -- Pack the tool's source tree into an archive
    local src = dir .. "/build/" .. tool.root
    assert(fs.mkdir(src, { parents = true }))
    write_executable(src .. "/" .. tool.file, tool.text)
    local archive = dir .. "/assets/" .. tool.asset
    assert(
        dev_os.run({ "tar", "-czf", archive, "-C", dir .. "/build", tool.root }) == 0,
        "tar failed"
    )

    -- Serve the archive
    SERVERS[dir] = support.fake_http({
        { path = "/dl/" .. tool.asset, body = assert(fs.read(archive)) },
    })
    return dir, archive
end

local function pins(dir, tool, sum)
    local row = table.concat({
        tool.name,
        VERSION,
        sum,
        SERVERS[dir].url .. "/dl/" .. tool.url,
        tool.root .. "/" .. tool.file,
    }, " ")
    assert(
        fs.write(
            dir .. "/releases.tsv",
            table.concat({ "name version sha256 url path", row, "" }, "\n")
        )
    )
end

local function run(dir, tool, args, extra)
    local env = {
        PATH = dir .. "/stubs:" .. dir .. "/pathbin",
        HOME = dir .. "/home",
        DEV_TOOLS_PREFIX = dir .. "/prefix",
        PKG_RELEASES = dir .. "/releases.tsv",
        TMPDIR = dir .. "/tmp",
        FAKE_LOG = dir .. "/calls.log",
    }
    for key, value in pairs(extra or {}) do
        env[key] = value
    end
    local argv =
        { runtime.exe, "-l", REPO .. "/tests/pkg/fixtures/install-" .. tool.name .. ".luau" }
    for _, arg in ipairs(args or {}) do
        argv[#argv + 1] = arg
    end
    return dev_os.capture(argv, { stderr = "stdout", env = env })
end

local function cleanup(dir)
    SERVERS[dir]:stop()
    fs.remove(dir, { recursive = true })
end

for _, tool in ipairs(TOOLS) do
    testing.test(tool.name .. " installs from its pin into the prefix and passes check", function()
        -- Pin the archive and see the tool absent
        local dir, archive = sandbox(tool)
        pins(dir, tool, hash.sha256_file(archive))
        local _, absent = run(dir, tool, { "--check" })
        testing.eq(absent, 1)

        -- Install it and see the binary in the prefix
        local out, code = run(dir, tool)
        testing.ok(code == 0, out)
        testing.ok(fs.is_exec(dir .. "/prefix/bin/" .. tool.name), out)
        local _, present = run(dir, tool, { "--check" })
        testing.eq(present, 0)

        -- Check the build ran each step against the prefix
        local log = assert(fs.read(dir .. "/calls.log"))
        for _, step in ipairs(tool.ran) do
            testing.ok(log:find(step, 1, true), step .. " missing from " .. log)
        end
        testing.ok(log:find(dir .. "/prefix", 1, true), log)

        -- Check the archive was fetched and the temp dir is clean
        testing.ok(SERVERS[dir]:requests():find("GET /dl/" .. tool.asset, 1, true))
        testing.eq(fs.list(dir .. "/tmp"), {})
        cleanup(dir)
    end)

    testing.test(tool.name .. " stops on a wrong sha256 before it extracts", function()
        -- Wrap tar so a run leaves a trace, and pin a wrong sum
        local dir = sandbox(tool)
        local real_tar = dev_os.which("tar")
        write_executable(
            dir .. "/stubs/tar",
            table.concat({
                "#!/bin/sh",
                'echo tar >>"$FAKE_LOG.tar"',
                "exec " .. real_tar .. ' "$@"',
                "",
            }, "\n")
        )
        pins(dir, tool, string.rep("0", 64))

        -- Install and see the mismatch refused
        local out, code = run(dir, tool)
        testing.ok(code ~= 0, out)
        testing.ok(out:find("does not match the pin. Expected ", 1, true), out)

        -- Check nothing was extracted or installed
        testing.eq(fs.read(dir .. "/calls.log.tar"), nil)
        testing.eq(fs.is_exec(dir .. "/prefix/bin/" .. tool.name), false)
        testing.eq(fs.list(dir .. "/tmp"), {})
        cleanup(dir)
    end)

    testing.test(tool.name .. " dry run prints every step and changes nothing", function()
        -- Pin the archive and run a dry run
        local dir, archive = sandbox(tool)
        local sum = hash.sha256_file(archive)
        pins(dir, tool, sum)
        local out, code = run(dir, tool, { "--dry-run" })
        testing.eq(code, 0, out)

        -- Check the plan names the download, the sum and every step
        testing.ok(out:find("download " .. SERVERS[dir].url, 1, true), out)
        testing.ok(out:find("(expect " .. sum .. ")", 1, true), out)
        testing.ok(out:find("tar -xzf", 1, true), out)
        for _, step in ipairs(tool.steps) do
            testing.ok(out:find(step, 1, true), step .. " missing from " .. out)
        end

        -- Check nothing ran, was fetched or was installed
        testing.eq(fs.read(dir .. "/calls.log"), nil)
        testing.eq(SERVERS[dir]:requests(), "")
        testing.eq(fs.is_exec(dir .. "/prefix/bin/" .. tool.name), false)
        cleanup(dir)
    end)

    testing.test(tool.name .. " skips the build when it is already installed", function()
        -- Pin the archive with the binary already in the prefix
        local dir, archive = sandbox(tool)
        pins(dir, tool, hash.sha256_file(archive))
        assert(fs.mkdir(dir .. "/prefix/bin", { parents = true }))
        write_executable(dir .. "/prefix/bin/" .. tool.name, "#!/bin/sh\n")

        -- Install and see it skipped
        local out, code = run(dir, tool)
        testing.eq(code, 0, out)
        testing.ok(out:find("skipping", 1, true), out)

        -- Check no build ran
        testing.eq(fs.read(dir .. "/calls.log"), nil)
        cleanup(dir)
    end)

    testing.test(tool.name .. " reinstalls over a present binary under PKG_FORCE", function()
        -- Pin the archive with an old binary in the prefix
        local dir, archive = sandbox(tool)
        pins(dir, tool, hash.sha256_file(archive))
        assert(fs.mkdir(dir .. "/prefix/bin", { parents = true }))
        write_executable(dir .. "/prefix/bin/" .. tool.name, "old\n")

        -- Install under PKG_FORCE and see the binary replaced
        local out, code = run(dir, tool, {}, { PKG_FORCE = "1" })
        testing.eq(code, 0, out)
        testing.ok(not out:find("skipping", 1, true), out)
        testing.eq(fs.read(dir .. "/prefix/bin/" .. tool.name), "#!/bin/sh\n")

        -- Check the build ran
        local log = assert(fs.read(dir .. "/calls.log"))
        testing.ok(log:find(tool.ran[1], 1, true), log)
        cleanup(dir)
    end)
end
