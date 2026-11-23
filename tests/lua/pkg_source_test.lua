local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local MODULES = REPO .. "/lua"
local VERSION = "9.9.9"
local URL_BASE = "https://example.test/dl/"
local SYSTEM_TOOLS = {
    "tar",
    "shasum",
    "sha256sum",
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

local FAKE_CURL = '#!/bin/sh\necho "$*" >>"$FAKE_LOG"\n'
    .. 'while [ "$#" -gt 0 ]; do\n'
    .. '    case "$1" in -o) out=$2; shift ;; esac\n'
    .. "    url=$1\n"
    .. "    shift\n"
    .. "done\n"
    .. 'cp "$FAKE_ASSETS/${url##*/}" "$out"\n'

local FAKE_MAKE = '#!/bin/sh\necho "make $*" >>"$FAKE_LOG"\n'
    .. 'if [ "$1" = install ]; then\n'
    .. "    read -r flag <.cfg\n"
    .. "    prefix=${flag#--prefix=}\n"
    .. '    mkdir -p "$prefix/bin"\n'
    .. "    printf '#!/bin/sh\\n' >\"$prefix/bin/stow\"\n"
    .. '    chmod 755 "$prefix/bin/stow"\n'
    .. "fi\n"

local BATS_INSTALL = "#!/bin/sh\n"
    .. 'echo "install.sh $*" >>"$FAKE_LOG"\n'
    .. 'mkdir -p "$1/bin"\n'
    .. "printf '#!/bin/sh\\n' >\"$1/bin/bats\"\n"
    .. 'chmod 755 "$1/bin/bats"\n'

local STOW_CONFIGURE = "#!/bin/sh\n" .. 'echo "configure $*" >>"$FAKE_LOG"\n' .. 'echo "$1" >.cfg\n'

local TOOLS = {
    {
        name = "bats",
        root = "bats-core-" .. VERSION,
        file = "install.sh",
        text = BATS_INSTALL,
        url = "bats-${version}.tar.gz",
        asset = "bats-" .. VERSION .. ".tar.gz",
        steps = { "'bash' './install.sh' '" },
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

local function sha256(file)
    local out = dev_os.capture(
        dev_os.which("shasum") and { "shasum", "-a", "256", file } or { "sha256sum", file }
    )
    return out:match("^(%x+)")
end

local function sandbox(tool)
    local dir = assert(fs.realpath(support.tempdir()))
    for _, sub in ipairs({ "assets", "stubs", "pathbin", "tmp", "build", "home" }) do
        assert(fs.mkdir(dir .. "/" .. sub))
    end
    write_executable(dir .. "/stubs/curl", FAKE_CURL)
    write_executable(dir .. "/stubs/make", FAKE_MAKE)
    write_executable(dir .. "/stubs/perl", "#!/bin/sh\nexit 0\n")
    for _, name in ipairs(SYSTEM_TOOLS) do
        local real = dev_os.which(name)
        if real then
            assert(fs.symlink(real, dir .. "/pathbin/" .. name))
        end
    end
    local src = dir .. "/build/" .. tool.root
    assert(fs.mkdir(src, { parents = true }))
    write_executable(src .. "/" .. tool.file, tool.text)
    local archive = dir .. "/assets/" .. tool.asset
    assert(
        dev_os.run({ "tar", "-czf", archive, "-C", dir .. "/build", tool.root }) == 0,
        "tar failed"
    )
    return dir, archive
end

local function pins(dir, tool, sum)
    local row = table.concat({
        tool.name,
        VERSION,
        sum,
        URL_BASE .. tool.url,
        tool.root .. "/" .. tool.file,
    }, " ")
    assert(fs.write(dir .. "/releases.tsv", "name version sha256 url path\n" .. row .. "\n"))
end

local function run(dir, tool, args, extra)
    local env = {
        PATH = dir .. "/stubs:" .. dir .. "/pathbin",
        HOME = dir .. "/home",
        DEV_TOOLS_PREFIX = dir .. "/prefix",
        PKG_RELEASES = dir .. "/releases.tsv",
        TMPDIR = dir .. "/tmp",
        LUA_PATH = MODULES .. "/?.lua",
        FAKE_ASSETS = dir .. "/assets",
        FAKE_LOG = dir .. "/calls.log",
    }
    for key, value in pairs(extra or {}) do
        env[key] = value
    end
    local script = REPO .. "/tests/pkg/fixtures/install-" .. tool.name .. ".lua"
    local argv = { assert(dev_os.which("luajit")), script }
    for _, arg in ipairs(args or {}) do
        argv[#argv + 1] = arg
    end
    return dev_os.capture(argv, { stderr = "stdout", env = env })
end

local function cleanup(dir)
    fs.remove(dir, { recursive = true })
end

for _, tool in ipairs(TOOLS) do
    testing.test(tool.name .. " installs from its pin into the prefix and passes check", function()
        local dir, archive = sandbox(tool)
        pins(dir, tool, sha256(archive))
        local _, absent = run(dir, tool, { "--check" })
        testing.eq(absent, 1)
        local out, code = run(dir, tool)
        testing.ok(code == 0, out)
        testing.ok(fs.is_exec(dir .. "/prefix/bin/" .. tool.name), out)
        local _, present = run(dir, tool, { "--check" })
        testing.eq(present, 0)
        local log = assert(fs.read(dir .. "/calls.log"))
        testing.ok(log:find(URL_BASE .. tool.asset, 1, true), log)
        for _, step in ipairs(tool.ran) do
            testing.ok(log:find(step, 1, true), step .. " missing from " .. log)
        end
        testing.ok(log:find(dir .. "/prefix", 1, true), log)
        cleanup(dir)
    end)

    testing.test(tool.name .. " stops on a wrong sha256 before it extracts", function()
        local dir = sandbox(tool)
        local real_tar = dev_os.which("tar")
        write_executable(
            dir .. "/stubs/tar",
            '#!/bin/sh\necho tar >>"$FAKE_LOG.tar"\nexec ' .. real_tar .. ' "$@"\n'
        )
        pins(dir, tool, string.rep("0", 64))
        local out, code = run(dir, tool)
        testing.ok(code ~= 0, out)
        testing.ok(out:find("does not match the pin. Expected ", 1, true), out)
        testing.eq(fs.read(dir .. "/calls.log.tar"), nil)
        testing.eq(fs.is_exec(dir .. "/prefix/bin/" .. tool.name), false)
        testing.eq(fs.list(dir .. "/tmp"), {})
        cleanup(dir)
    end)

    testing.test(tool.name .. " dry run prints every step and changes nothing", function()
        local dir, archive = sandbox(tool)
        pins(dir, tool, sha256(archive))
        local out, code = run(dir, tool, { "--dry-run" })
        testing.eq(code, 0, out)
        testing.ok(out:find("curl", 1, true), out)
        testing.ok(out:find("(expect " .. sha256(archive) .. ")", 1, true), out)
        testing.ok(out:find("tar -xzf", 1, true), out)
        for _, step in ipairs(tool.steps) do
            testing.ok(out:find(step, 1, true), step .. " missing from " .. out)
        end
        testing.eq(fs.read(dir .. "/calls.log"), nil)
        testing.eq(fs.is_exec(dir .. "/prefix/bin/" .. tool.name), false)
        cleanup(dir)
    end)

    testing.test(tool.name .. " skips the build when it is already installed", function()
        local dir, archive = sandbox(tool)
        pins(dir, tool, sha256(archive))
        assert(fs.mkdir(dir .. "/prefix/bin", { parents = true }))
        write_executable(dir .. "/prefix/bin/" .. tool.name, "#!/bin/sh\n")
        local out, code = run(dir, tool)
        testing.eq(code, 0, out)
        testing.ok(out:find("skipping", 1, true), out)
        testing.eq(fs.read(dir .. "/calls.log"), nil)
        cleanup(dir)
    end)
end
