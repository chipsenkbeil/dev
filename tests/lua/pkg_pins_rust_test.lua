local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local manifest = require("dev.pkg.manifest")
local release = require("dev.pkg.release")
local support = require("support")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local PINS = REPO .. "/.dev/releases.tsv"
local PKG = REPO .. "/dotfiles/bin/.local/share/dev/pkg.lua"
local MODULES = REPO .. "/dotfiles/bin/.local/share/dev/lua"
local SCRIPT = REPO .. "/scripts/install-rustup-darwin.lua"
local COLUMN = "darwin-x86_64"
local TOOLCHAIN = "1.99.1"
local UNAME = '#!/bin/sh\ncase "$1" in -m) echo x86_64 ;; *) echo Darwin ;; esac\n'
local SYSTEM_TOOLS = {
    "chmod",
    "shasum",
    "sha256sum",
    "mkdir",
    "mv",
    "rm",
    "cat",
    "install",
    "mktemp",
    "dirname",
    "basename",
    "env",
    "sh",
    "bash",
    "realpath",
    "readlink",
    "cp",
    "ln",
    "stat",
    "find",
}

local ROUTES = {
    ["cargo-binstall"] = "release:cargo-binstall",
    rustup = "script:scripts/install-rustup-darwin.lua,bin:-",
    ["cargo-sort"] = "cargo:cargo-sort",
    ["cargo-deny"] = "release:cargo-deny",
    ["cargo-nextest"] = "release:cargo-nextest",
    ["rustfmt-nightly"] = "script:scripts/install-rustfmt-nightly.lua",
    zig = "-",
    ["cargo-zigbuild"] = "-",
    ["rust-darwin-targets"] = "-",
    sccache = "release:sccache",
    ["build-tools"] = "system:cc",
}
local ORDER = {
    "cargo-binstall",
    "rustup",
    "cargo-sort",
    "cargo-deny",
    "cargo-nextest",
    "rustfmt-nightly",
    "sccache",
    "build-tools",
}
local FAKE_CURL = '#!/bin/sh\necho "$*" >>"$FAKE_LOG"\n'
    .. 'while [ "$#" -gt 0 ]; do\n'
    .. '    case "$1" in -o) out=$2; shift ;; esac\n'
    .. "    url=$1\n"
    .. "    shift\n"
    .. "done\n"
    .. 'cp "$FAKE_ASSETS/${url##*/}" "$out"\n'
local PROXY_GUARD =
    'case "${0##*/}" in rustup-init) ;; *) echo "error: unknown proxy name: ${0##*/}" >&2; exit 1 ;; esac\n'
local FAKE_INIT = "#!/bin/sh\n"
    .. PROXY_GUARD
    .. 'echo "rustup-init $*" >>"$FAKE_LOG"\n'
    .. 'mkdir -p "$CARGO_HOME/bin"\n'
    .. "printf '#!/bin/sh\\n' >\"$CARGO_HOME/bin/rustup\"\n"
    .. 'chmod 755 "$CARGO_HOME/bin/rustup"\n'

local function rust_cells()
    local rows = manifest.parse(assert(fs.read(REPO .. "/.dev/tools.tsv")))
    local column = assert(manifest.column(rows, COLUMN))
    local cells = {}
    for _, row in ipairs(rows) do
        for _, group in ipairs(row.groups) do
            if group == "rust" then
                cells[row.name] = row.fields[column] or ""
            end
        end
    end
    return cells
end

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

local function sandbox(sum)
    local dir = assert(fs.realpath(support.tempdir()))
    for _, sub in ipairs({ "assets", "stubs", "pathbin", "tmp", "home" }) do
        assert(fs.mkdir(dir .. "/" .. sub))
    end
    write_executable(dir .. "/stubs/curl", FAKE_CURL)
    for _, name in ipairs(SYSTEM_TOOLS) do
        local real = dev_os.which(name)
        if real then
            assert(fs.symlink(real, dir .. "/pathbin/" .. name))
        end
    end
    write_executable(dir .. "/assets/rustup-init", FAKE_INIT)
    local sum_of = sum or sha256(dir .. "/assets/rustup-init")
    local row = table.concat({
        "rustup-init",
        "9.9.9",
        sum_of,
        "https://example.test/rustup/${version}/x86_64-apple-darwin/rustup-init",
        "-",
    }, " ")
    assert(fs.write(dir .. "/releases.tsv", "name version sha256 url path\n" .. row .. "\n"))
    return dir
end

local function run(dir, args, extra)
    local env = {
        PATH = dir .. "/stubs:" .. dir .. "/pathbin",
        HOME = dir .. "/home",
        CARGO_HOME = dir .. "/home/.cargo",
        PKG_RELEASES = dir .. "/releases.tsv",
        TMPDIR = dir .. "/tmp",
        LUA_PATH = MODULES .. "/?.lua",
        FAKE_ASSETS = dir .. "/assets",
        FAKE_LOG = dir .. "/calls.log",
    }
    for key, value in pairs(extra or {}) do
        env[key] = value
    end
    local argv = { assert(dev_os.which("luajit")), SCRIPT }
    for _, arg in ipairs(args or {}) do
        argv[#argv + 1] = arg
    end
    return dev_os.capture(argv, { stderr = "stdout", env = env })
end

testing.test("every rust row has a route or a drop on Intel macOS", function()
    testing.eq(rust_cells(), ROUTES)
end)

testing.test("every release route of the rust group has a pin", function()
    local pins = assert(release.read(PINS))
    for tool, cell in pairs(rust_cells()) do
        local name = cell:match("^release:(.+)$")
        if name then
            testing.ok(
                pins[name],
                tool .. " names the pin " .. name .. ", which .dev/releases.tsv lacks"
            )
        end
    end
    testing.ok(pins["rustup-init"], "rustup-init has no pin")
end)

testing.test("the Darwin x86_64 dry run prints the rust steps in manifest order", function()
    local dir = assert(fs.realpath(support.tempdir()))
    assert(fs.mkdir(dir .. "/stubs"))
    assert(fs.mkdir(dir .. "/home"))
    write_executable(dir .. "/stubs/uname", UNAME)
    local out, code = dev_os.capture({
        assert(dev_os.which("luajit")),
        PKG,
        "install",
        "--dry-run",
        "--group",
        "rust",
        "--manifest",
        REPO .. "/.dev/tools.tsv",
    }, {
        stderr = "stdout",
        env = { PATH = dir .. "/stubs", HOME = dir .. "/home", DEV_TOOLS_BIN = dir .. "/bin" },
    })
    testing.eq(code, 0, out)
    local last = 0
    for _, tool in ipairs(ORDER) do
        local at = out:find(tool .. " (dry-run):", 1, true)
            or out:find(tool .. " installed outside", 1, true)
        testing.ok(at, tool .. " has no step in " .. out)
        testing.ok(at > last, tool .. " is out of manifest order in " .. out)
        last = at
    end
    for _, tool in ipairs({ "zig", "cargo-zigbuild", "rust-darwin-targets" }) do
        testing.eq(out:find("+ " .. tool .. " (dry-run):", 1, true), nil, out)
    end
    testing.ok(out:find("luajit scripts/install-rustup-darwin.lua", 1, true), out)
    testing.ok(out:find("cargo-deny-0.20.2-x86_64-apple-darwin.tar.gz", 1, true), out)
    testing.ok(out:find("cargo-nextest-0.9.150-universal-apple-darwin.tar.gz", 1, true), out)
    testing.ok(out:find("sccache-v0.19.0-x86_64-apple-darwin.tar.gz", 1, true), out)
    testing.ok(out:find("cargo-binstall-x86_64-apple-darwin.zip", 1, true), out)
    fs.remove(dir, { recursive = true })
end)

testing.test("cargo-binstall comes before every cargo cell in the manifest", function()
    local rows = manifest.parse(assert(fs.read(REPO .. "/.dev/tools.tsv")))
    local column = assert(manifest.column(rows, COLUMN))
    local binstall, first_cargo
    for i, row in ipairs(rows) do
        local cell = row.fields[column] or ""
        if row.name == "cargo-binstall" then
            binstall = i
        elseif cell:find("^cargo:") and not first_cargo then
            first_cargo = i
        end
    end
    testing.ok(
        binstall and first_cargo and binstall < first_cargo,
        "cargo-binstall must come first"
    )
end)

testing.test(
    "the rustup script installs the pinned toolchain from its pin and passes check",
    function()
        local dir = sandbox()
        local _, absent = run(dir, { "--check" })
        testing.eq(absent, 1)
        local out, code = run(dir)
        testing.eq(code, 0, out)
        local log = assert(fs.read(dir .. "/calls.log"))
        testing.ok(
            log:find("https://example.test/rustup/9.9.9/x86_64-apple-darwin/rustup-init", 1, true),
            log
        )
        testing.ok(
            log:find("rustup-init -y --no-modify-path --default-toolchain " .. TOOLCHAIN, 1, true),
            log
        )
        testing.ok(fs.is_exec(dir .. "/home/.cargo/bin/rustup"), out)
        local _, present = run(dir, { "--check" })
        testing.eq(present, 0)
        fs.remove(dir, { recursive = true })
    end
)

testing.test("the rustup script check accepts a rustup on PATH", function()
    local dir = sandbox()
    write_executable(dir .. "/stubs/rustup", "#!/bin/sh\n")
    local _, code = run(dir, { "--check" })
    testing.eq(code, 0)
    fs.remove(dir, { recursive = true })
end)

testing.test("the rustup script refuses a download that does not match its pin", function()
    local dir = sandbox(string.rep("0", 64))
    local out, code = run(dir)
    testing.ok(code ~= 0, out)
    testing.ok(out:find("sha256 mismatch", 1, true), out)
    testing.eq(fs.read(dir .. "/calls.log"):find("rustup-init -y", 1, true), nil)
    testing.eq(fs.is_exec(dir .. "/home/.cargo/bin/rustup"), false)
    testing.eq(fs.list(dir .. "/tmp"), {})
    fs.remove(dir, { recursive = true })
end)

testing.test("the rustup script dry run prints every step and changes nothing", function()
    local dir = sandbox()
    local out, code = run(dir, { "--dry-run" })
    testing.eq(code, 0, out)
    testing.ok(out:find("(expect " .. sha256(dir .. "/assets/rustup-init") .. ")", 1, true), out)
    testing.ok(out:find("'--default-toolchain' '" .. TOOLCHAIN .. "'", 1, true), out)
    testing.ok(out:find("'install' '-m' '755'", 1, true), out)
    testing.ok(out:find("'<tmp>/rustup-init' '-y'", 1, true), out)
    testing.eq(fs.read(dir .. "/calls.log"), nil)
    testing.eq(fs.is_exec(dir .. "/home/.cargo/bin/rustup"), false)
    fs.remove(dir, { recursive = true })
end)

testing.test("the rustup script skips the install when rustup is already there", function()
    local dir = sandbox()
    assert(fs.mkdir(dir .. "/home/.cargo/bin", { parents = true }))
    write_executable(dir .. "/home/.cargo/bin/rustup", "#!/bin/sh\n")
    local out, code = run(dir)
    testing.eq(code, 0, out)
    testing.ok(out:find("skipping", 1, true), out)
    testing.eq(fs.read(dir .. "/calls.log"), nil)
    fs.remove(dir, { recursive = true })
end)

local ARCHIVED = { "cargo-binstall", "cargo-deny", "cargo-nextest", "sccache" }
local FAKE_BINSTALL = "#!/bin/sh\n"
    .. 'echo "cargo-binstall $*" >>"$FAKE_LOG"\n'
    .. "for last; do :; done\n"
    .. "home=${CARGO_HOME:-$HOME/.cargo}\n"
    .. 'mkdir -p "$home/bin"\n'
    .. "printf '#!/bin/sh\\n' >\"$home/bin/$last\"\n"
    .. 'chmod 755 "$home/bin/$last"\n'
local FAKE_RUSTUP = "#!/bin/sh\n"
    .. 'echo "rustup $*" >>"$FAKE_LOG"\n'
    .. 'case "$1 $2" in "toolchain install") : >"$FAKE_ASSETS/nightly" ;; esac\n'
local FAKE_CARGO =
    '#!/bin/sh\ncase "$1" in +nightly) test -f "$FAKE_ASSETS/nightly"; exit $? ;; esac\n'
local FAKE_HOME_INIT = "#!/bin/sh\n"
    .. PROXY_GUARD
    .. 'echo "rustup-init $*" >>"$FAKE_LOG"\n'
    .. "home=${CARGO_HOME:-$HOME/.cargo}\n"
    .. 'mkdir -p "$home/bin"\n'
    .. 'cp "$FAKE_ASSETS/rustup-stub" "$home/bin/rustup"\n'
    .. 'cp "$FAKE_ASSETS/cargo-stub" "$home/bin/cargo"\n'
    .. 'chmod 755 "$home/bin/rustup" "$home/bin/cargo"\n'

local function rust_group_sandbox()
    local dir = assert(fs.realpath(support.tempdir()))
    for _, sub in ipairs({ "assets", "stubs", "pathbin", "tmp", "home", "stage" }) do
        assert(fs.mkdir(dir .. "/" .. sub))
    end
    write_executable(dir .. "/stubs/curl", FAKE_CURL)
    write_executable(dir .. "/stubs/uname", UNAME)
    for _, name in ipairs(SYSTEM_TOOLS) do
        local real = dev_os.which(name)
        if real then
            assert(fs.symlink(real, dir .. "/pathbin/" .. name))
        end
    end
    for _, name in ipairs({ "tar", "gzip", "unzip" }) do
        local real = dev_os.which(name)
        if real then
            assert(fs.symlink(real, dir .. "/pathbin/" .. name))
        end
    end
    write_executable(dir .. "/assets/rustup-init", FAKE_HOME_INIT)
    write_executable(dir .. "/assets/rustup-stub", FAKE_RUSTUP)
    write_executable(dir .. "/assets/cargo-stub", FAKE_CARGO)
    local pins = {
        "name version sha256 url path",
        table.concat({
            "rustup-init",
            "9.9.9",
            sha256(dir .. "/assets/rustup-init"),
            "https://example.test/rustup-init",
            "-",
        }, " "),
    }
    for _, name in ipairs(ARCHIVED) do
        assert(fs.mkdir(dir .. "/stage/" .. name))
        write_executable(
            dir .. "/stage/" .. name .. "/" .. name,
            name == "cargo-binstall" and FAKE_BINSTALL or "#!/bin/sh\n"
        )
        local archive = dir .. "/assets/" .. name .. ".tar.gz"
        assert(
            dev_os.run({ "tar", "-czf", archive, "-C", dir .. "/stage/" .. name, name }) == 0,
            "tar failed"
        )
        pins[#pins + 1] = table.concat({
            name,
            "1.0.0",
            sha256(archive),
            "https://example.test/" .. name .. ".tar.gz",
            name,
        }, " ")
    end
    assert(fs.write(dir .. "/releases.tsv", table.concat(pins, "\n") .. "\n"))
    assert(fs.write(dir .. "/tools.tsv", assert(fs.read(REPO .. "/.dev/tools.tsv"))))
    return dir
end

local function install_rust_group(dir, extra)
    local env = {
        PATH = dir .. "/stubs:" .. dir .. "/pathbin",
        HOME = dir .. "/home",
        TMPDIR = dir .. "/tmp",
        FAKE_ASSETS = dir .. "/assets",
        FAKE_LOG = dir .. "/calls.log",
    }
    local unset = {}
    for _, key in ipairs({ "CARGO_HOME", "DEV_TOOLS_BIN" }) do
        if extra[key] then
            env[key] = extra[key]
        else
            unset[#unset + 1] = key
        end
    end
    return dev_os.capture({
        assert(dev_os.which("luajit")),
        PKG,
        "install",
        "--group",
        "rust",
        "--manifest",
        dir .. "/tools.tsv",
    }, {
        cwd = REPO,
        stderr = "stdout",
        env = env,
        unset = unset,
    })
end

local function check_rust_group(dir, cargo_bin, extra)
    local out, code = install_rust_group(dir, extra or {})
    testing.eq(code, 0, out)
    testing.eq(out:find("install failed", 1, true), nil, out)
    testing.ok(fs.is_exec(cargo_bin .. "/rustup"), out)
    testing.ok(fs.is_exec(cargo_bin .. "/cargo-sort"), out)
    testing.ok(fs.is_file(dir .. "/assets/nightly"), out)
    local log = assert(fs.read(dir .. "/calls.log"))
    testing.ok(log:find("rustup toolchain install nightly --profile minimal", 1, true), log)
    testing.ok(
        log:find("cargo-binstall --no-confirm --disable-telemetry --locked cargo-sort", 1, true),
        log
    )
end

testing.test(
    "the rust group installs in one run on an Intel Mac with no cargo or user bin on PATH",
    function()
        if dev_os.getuid() == 0 then
            return
        end
        local dir = rust_group_sandbox()
        check_rust_group(dir, dir .. "/home/.cargo/bin")
        testing.ok(fs.is_exec(dir .. "/home/.local/bin/cargo-binstall"))
        testing.ok(fs.is_exec(dir .. "/home/.local/bin/sccache"))
        fs.remove(dir, { recursive = true })
    end
)

testing.test("the rust group honours CARGO_HOME and DEV_TOOLS_BIN when they are set", function()
    if dev_os.getuid() == 0 then
        return
    end
    local dir = rust_group_sandbox()
    check_rust_group(dir, dir .. "/cargo/bin", {
        CARGO_HOME = dir .. "/cargo",
        DEV_TOOLS_BIN = dir .. "/tools",
    })
    testing.ok(fs.is_exec(dir .. "/tools/cargo-binstall"))
    testing.eq(fs.is_exec(dir .. "/home/.cargo/bin/rustup"), false)
    fs.remove(dir, { recursive = true })
end)
