local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local kinds = require("dev.pkg.kinds")
local manifest = require("dev.pkg.manifest")
local lib = require("dev.pkg.lib")
local support = require("support")

local REPO = devos.capture({ "pwd" }):gsub("\n$", "")
local VARS = assert(fs.read(REPO .. "/tests/pkg/fixtures/vars.tsv"))

local function cell_of(selected, name)
    for _, row in ipairs(selected) do
        if row.name == name then
            return row.cell
        end
    end
end

local PROBE = 'package.path = "'
    .. REPO
    .. '/dotfiles/bin/.local/share/dev/lua/?.lua"\n'
    .. [=[
local manifest = require("dev.pkg.manifest")
local selected, err = manifest.select(manifest.parse(arg[1]), { column = tonumber(arg[2]) })
if not selected then
    io.write("ERR\t", err)
    return
end
for _, row in ipairs(selected) do
    io.write(row.name, "\t", row.cell, "\n")
end
]=]

local function select_with_env(text, column, env)
    local dir = assert(fs.realpath(support.tempdir()))
    assert(fs.write(dir .. "/probe.lua", PROBE))
    local unset = {}
    for _, name in ipairs({ "FOO", "SP", "NOPE" }) do
        if env[name] == nil then
            unset[#unset + 1] = name
        end
    end
    local out = devos.capture(
        { "luajit", dir .. "/probe.lua", text, tostring(column) },
        { env = env, unset = unset }
    )
    fs.remove(dir, { recursive = true })
    local err = out:match("^ERR\t(.*)$")
    if err then
        return nil, err
    end
    local cells = {}
    for name, cell in out:gmatch("([^\t\n]*)\t([^\n]*)\n") do
        cells[name] = cell
    end
    return cells
end

local function select_all(rows, column, group)
    return manifest.select(rows, { column = column, group = group })
end

t.test("parse reads every row of the real manifest and finds its groups", function()
    local rows = manifest.parse(assert(fs.read(REPO .. "/.dev/tools.tsv")))
    t.ok(#rows > 10, "the real manifest should hold many rows")
    t.eq(rows.header[1], "name")
    t.eq(rows.header[#rows.header], "groups")
    local seen = {}
    for _, row in ipairs(rows) do
        for _, group in ipairs(row.groups) do
            seen[group] = true
        end
    end
    t.ok(seen.base and seen.rust, "the real manifest should have the base and rust groups")
    t.ok(manifest.column(rows, "brew") ~= nil)
    t.eq(manifest.column(rows, "groups"), nil)
    t.eq(manifest.column(rows, "nope"), nil)
end)

t.test(
    "a quoted cell with spaces is one cell and unquoted cells split on runs of blanks",
    function()
        local rows = manifest.parse(
            'name\tbinary  brew\nplain\tpl\tripgrep\nargs zzz "script:/tmp/x.sh --flag value"\n'
        )
        local column = assert(manifest.column(rows, "brew"))
        local selected = assert(select_all(rows, column))
        t.eq(cell_of(selected, "plain"), "ripgrep")
        t.eq(cell_of(selected, "args"), "script:/tmp/x.sh --flag value")
    end
)

t.test("select expands variables from the environment, then the @env default", function()
    local cells = assert(select_with_env(VARS, 3, {}))
    t.eq(cells["bare-foo"], "bar_value")
    t.eq(cells["braced-foo"], "bar_value")
    t.eq(cells["quoted-sp"], "asdf asdf")
    t.eq(cells["braced-sp"], "asdf asdf")
    t.eq(cells["quoted-lit"], "/x --y")
    t.eq(cells["mid-script"], "script:bar_value")
    t.eq(cells["mid-copr"], "copr:p,repo:bar_value")
    t.eq(cells["escape"], "price$5")
    t.eq(cells["escape-name"], "$FOO")
    local override = assert(select_with_env(VARS, 3, { FOO = "env_wins" }))
    t.eq(override["bare-foo"], "env_wins")
end)

t.test("an undefined variable fails the whole selection and names the variable and row", function()
    local selected, err =
        select_with_env("name binary brew\nnope-row x ${NOPE}\nfine y ripgrep\n", 3, {})
    t.eq(selected, nil)
    t.eq(err, "manifest: error: undefined variable ${NOPE} (row: nope-row)")
end)

t.test("a variable in another manager's column does not fail the selection", function()
    local text = "name binary brew pacman\nx y ripgrep ${NOPE}\n"
    t.eq(select_with_env(text, 3, {}), { x = "ripgrep" })
    t.eq(select_with_env(text, 4, {}), nil)
end)

t.test("select keeps the rows of one group, comma lists included", function()
    local rows = manifest.parse(
        "name binary brew groups\naa a aa-f base\nbb b bb-f rust\ncc c cc-f base,rust\ndd d dd-f -\n"
    )
    local names = function(group)
        local out = {}
        for _, row in ipairs(assert(select_all(rows, 3, group))) do
            out[#out + 1] = row.name
        end
        return out
    end
    t.eq(names("base"), { "aa", "cc" })
    t.eq(names("rust"), { "bb", "cc" })
    t.eq(names("nope"), {})
    t.eq(names(nil), { "aa", "bb", "cc", "dd" })
end)

t.test("a manifest with no groups column has no groups", function()
    local rows = manifest.parse("name binary brew\naa a aa-f\n")
    t.eq(#assert(select_all(rows, 3, "base")), 0)
end)

t.test(
    "route sends script, cargo and flatpak to the user and aur, copr and luarocks to third parties",
    function()
        local manager = kinds.Manager.PACMAN
        local function route(channel)
            local scope, driver = kinds.route(channel, manager)
            return { scope, driver }
        end
        t.eq(route("script"), { kinds.Scope.USER, "script" })
        t.eq(route("cargo"), { kinds.Scope.USER, "cargo" })
        t.eq(route("flatpak"), { kinds.Scope.USER, "flatpak" })
        t.eq(route("luarocks"), { kinds.Scope.THIRD_PARTY, "luarocks" })
        t.eq(route("aur"), { kinds.Scope.THIRD_PARTY, "pacman" })
        t.eq(route("copr"), { kinds.Scope.THIRD_PARTY, "pacman" })
        t.eq(route(""), { kinds.Scope.SYSTEM, "pacman" })
        t.eq(route("cask"), { kinds.Scope.SYSTEM, "pacman" })
    end
)

t.test("parse_cell splits the channel, package, repo and binary", function()
    local function parts(cell)
        local parsed = assert(lib.parse_cell(cell))
        return { parsed.channel, parsed.package, parsed.repo, parsed.bin }
    end
    t.eq(parts("ripgrep"), { "", "ripgrep", "", "" })
    t.eq(parts("cask:ghostty"), { "cask", "ghostty", "", "" })
    t.eq(parts("fd-find,bin:fdfind"), { "", "fd-find", "", "fdfind" })
    t.eq(
        parts("tap:browserpass,repo:amar1729/formulae"),
        { "tap", "browserpass", "amar1729/formulae", "" }
    )
    t.eq(parts("copr:ghostty,repo:pgdev/ghostty"), { "copr", "ghostty", "pgdev/ghostty", "" })
    t.eq(
        parts("tap:browserpass,repo:amar1729/formulae,bin:bpass"),
        { "tap", "browserpass", "amar1729/formulae", "bpass" }
    )
    t.eq(parts("aur:jjui-bin"), { "aur", "jjui-bin", "", "" })
    t.eq(parts("script:/tmp/x.sh --flag value"), { "script", "/tmp/x.sh --flag value", "", "" })
    t.eq(lib.parse_cell("-"), nil)
end)

t.test("valid_package accepts plain words and refuses anything that could be an option", function()
    local function valid(channel, package, repo)
        return lib.valid_package({
            channel = channel,
            package = package,
            repo = repo or "",
            bin = "",
        })
    end
    for _, ok in ipairs({ "ripgrep", "fd-find", "c++", "python3.12", "@scope.pkg", "a_b" }) do
        t.ok(valid("", ok), ok)
    end
    for _, bad in ipairs({
        "-U",
        "--config=/x",
        "a b",
        "-U http://evil/x",
        "a;b",
        "$(x)",
        "",
        "a/b",
    }) do
        t.ok(not valid("", bad), bad)
    end
    t.ok(valid("copr", "ok", "pgdev/ghostty"))
    t.ok(not valid("copr", "ok", "a/b/c"))
    t.ok(valid("script", "/x/y.sh --flag"))
end)

t.test("route names who installs a channel and which driver handles it", function()
    local scope, driver = kinds.route("", kinds.Manager.BREW)
    t.eq({ scope, driver }, { kinds.Scope.SYSTEM, "brew" })
    scope, driver = kinds.route("cargo", kinds.Manager.BREW)
    t.eq({ scope, driver }, { kinds.Scope.USER, "cargo" })
    t.ok(kinds.DRIVERS.script and kinds.DRIVERS.brew and not kinds.DRIVERS.flatpak)
end)

t.test("groups is never a manager column and a group name never lands in a cell", function()
    local rows = manifest.parse(
        "name binary brew groups\naa a aa-f base\nbb b bb-f rust\ncc c cc-f base,rust\ndd d dd-f -\n"
    )
    t.eq(manifest.column(rows, "groups"), nil)
    t.eq(manifest.column(rows, "brew"), 3)
    local selected = assert(select_all(rows, 3))
    t.eq(#selected, 4)
    for _, row in ipairs(selected) do
        t.ok(not row.cell:find("base", 1, true), row.cell)
    end
end)

t.test("the real manifest puts exactly the base and rust rows in their groups", function()
    local rows = manifest.parse(assert(fs.read(REPO .. "/.dev/tools.tsv")))
    local function names(group)
        local out = {}
        for _, row in ipairs(assert(select_all(rows, 1, group))) do
            out[#out + 1] = row.name
        end
        table.sort(out)
        return table.concat(out, " ")
    end
    t.eq(
        names("base"),
        "ast-grep bats dash difftastic fd gh git hyperfine jq jujutsu luajit ripgrep sd selene shellcheck shfmt stow stylua tokei watchexec yq zsh"
    )
    t.eq(
        names("rust"),
        "build-tools cargo-binstall cargo-deny cargo-nextest cargo-sort cargo-zigbuild rust-darwin-targets rustfmt-nightly rustup sccache zig"
    )
end)

t.test(
    "a failed logged command prints the last 20 lines of its output under the failure",
    function()
        local dir = assert(fs.realpath(support.tempdir()))
        local probe = 'package.path = "'
            .. REPO
            .. '/dotfiles/bin/.local/share/dev/lua/?.lua;" .. package.path\n'
            .. 'local lib = require("dev.pkg.lib")\n'
            .. "local opts = { log_file = arg[1] }\n"
            .. 'assert(lib.run({ "echo", "earlier" }, opts) == 0)\n'
            .. 'local code = lib.run({ "sh", "-c", "seq 1 30; echo broke >&2; exit 3" }, opts)\n'
            .. "assert(code == 3)\n"
            .. 'lib.failed({ name = "tool" }, "sh -c x")\n'
            .. 'assert(lib.run({ "true" }, opts) == 0)\n'
            .. "lib.flush_failure()\n"
        assert(fs.write(dir .. "/probe.lua", probe))
        local luajit = devos.capture({ "sh", "-c", "command -v luajit" }):gsub("\n$", "")
        local out, code = devos.capture(
            { luajit, dir .. "/probe.lua", dir .. "/log" },
            { stderr = "stdout" }
        )
        t.eq(code, 0)
        local expected = '  ! tool: "sh -c x" failed\n'
        for i = 12, 30 do
            expected = expected .. "      " .. i .. "\n"
        end
        t.eq(out, expected .. "      broke\n")
        fs.remove(dir, { recursive = true })
    end
)
