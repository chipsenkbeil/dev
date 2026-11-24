local testing = require("dev.testing")
local dev_os = require("dev.os")
local runtime = require("dev.runtime")
local fs = require("dev.fs")
local kinds = require("dev.pkg.kinds")
local manifest = require("dev.manifest")
local lib = require("dev.pkg.lib")
local support = require("support")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local VARS = assert(fs.read(REPO .. "/tests/pkg/fixtures/vars.tsv"))

local function cell_of(selected, name)
    for _, row in ipairs(selected) do
        if row.name == name then
            return row.cell
        end
    end
end

local PROBE = [=[
local dev_os = require("dev.os")
local manifest = require("dev.manifest")
local selected, err = manifest.select(manifest.parse(arg[1]), { column = tonumber(arg[2]) })
if not selected then
    dev_os.stdout:write("ERR\t", err)
    return
end
for _, row in ipairs(selected) do
    dev_os.stdout:write(row.name, "\t", row.cell, "\n")
end
]=]

local function select_with_env(text, column, env)
    local dir = assert(fs.realpath(support.tempdir()))
    assert(fs.write(dir .. "/probe.luau", PROBE))
    local unset = {}
    for _, name in ipairs({ "FOO", "SP", "NOPE" }) do
        if env[name] == nil then
            unset[#unset + 1] = name
        end
    end
    local out = dev_os.capture(
        { runtime.exe, "-l", dir .. "/probe.luau", text, tostring(column) },
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

testing.test("the driver refuses a run without --manifest", function()
    for _, sub in ipairs({ "check", "install" }) do
        local out, code = dev_os.capture({ runtime.exe, "__pkg", sub }, { stderr = "stdout" })
        testing.eq(code, 2)
        testing.ok(out:find("--manifest", 1, true), out)
    end
end)

testing.test(
    "a quoted cell with spaces is one cell and unquoted cells split on runs of blanks",
    function()
        local rows = manifest.parse(
            'name\tbinary  brew\nplain\tpl\tripgrep\nargs zzz "script:/tmp/x.sh --flag value"\n'
        )
        local column = assert(manifest.column(rows, "brew"))
        local selected = assert(select_all(rows, column))
        testing.eq(cell_of(selected, "plain"), "ripgrep")
        testing.eq(cell_of(selected, "args"), "script:/tmp/x.sh --flag value")
    end
)

testing.test("select expands variables from the environment, then the @env default", function()
    local cells = assert(select_with_env(VARS, 3, {}))
    testing.eq(cells["bare-foo"], "bar_value")
    testing.eq(cells["braced-foo"], "bar_value")
    testing.eq(cells["quoted-sp"], "asdf asdf")
    testing.eq(cells["braced-sp"], "asdf asdf")
    testing.eq(cells["quoted-lit"], "/x --y")
    testing.eq(cells["mid-script"], "script:bar_value")
    testing.eq(cells["mid-copr"], "copr:p,repo:bar_value")
    testing.eq(cells["escape"], "price$5")
    testing.eq(cells["escape-name"], "$FOO")
    local override = assert(select_with_env(VARS, 3, { FOO = "env_wins" }))
    testing.eq(override["bare-foo"], "env_wins")
end)

testing.test(
    "an undefined variable fails the whole selection and names the variable and row",
    function()
        local selected, err =
            select_with_env("name binary brew\nnope-row x ${NOPE}\nfine y ripgrep\n", 3, {})
        testing.eq(selected, nil)
        testing.eq(err, "Variable ${NOPE} is undefined in row nope-row.")
    end
)

testing.test("a variable in another manager's column does not fail the selection", function()
    local text = "name binary brew pacman\nx y ripgrep ${NOPE}\n"
    testing.eq(select_with_env(text, 3, {}), { x = "ripgrep" })
    testing.eq(select_with_env(text, 4, {}), nil)
end)

testing.test("select keeps the rows of one group, comma lists included", function()
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
    testing.eq(names("base"), { "aa", "cc" })
    testing.eq(names("rust"), { "bb", "cc" })
    testing.eq(names("nope"), {})
    testing.eq(names(nil), { "aa", "bb", "cc", "dd" })
end)

testing.test("a manifest with no groups column has no groups", function()
    local rows = manifest.parse("name binary brew\naa a aa-f\n")
    testing.eq(#assert(select_all(rows, 3, "base")), 0)
end)

testing.test(
    "route sends script, cargo and flatpak to the user and aur, copr and luarocks to third parties",
    function()
        local manager = kinds.Manager.PACMAN
        local function route(channel)
            local scope, driver = kinds.route(channel, manager)
            return { scope, driver }
        end
        testing.eq(route("script"), { kinds.Scope.USER, "script" })
        testing.eq(route("cargo"), { kinds.Scope.USER, "cargo" })
        testing.eq(route("flatpak"), { kinds.Scope.USER, "flatpak" })
        testing.eq(route("luarocks"), { kinds.Scope.THIRD_PARTY, "luarocks" })
        testing.eq(route("aur"), { kinds.Scope.THIRD_PARTY, "pacman" })
        testing.eq(route("copr"), { kinds.Scope.THIRD_PARTY, "pacman" })
        testing.eq(route(""), { kinds.Scope.SYSTEM, "pacman" })
        testing.eq(route("cask"), { kinds.Scope.SYSTEM, "pacman" })
    end
)

testing.test("parse_cell splits the channel, package, repo and binary", function()
    local function parts(cell)
        local parsed = assert(lib.parse_cell(cell))
        return { parsed.channel, parsed.package, parsed.repo, parsed.bin }
    end
    testing.eq(parts("ripgrep"), { "", "ripgrep", "", "" })
    testing.eq(parts("cask:ghostty"), { "cask", "ghostty", "", "" })
    testing.eq(parts("fd-find,bin:fdfind"), { "", "fd-find", "", "fdfind" })
    testing.eq(
        parts("tap:browserpass,repo:amar1729/formulae"),
        { "tap", "browserpass", "amar1729/formulae", "" }
    )
    testing.eq(parts("copr:ghostty,repo:pgdev/ghostty"), { "copr", "ghostty", "pgdev/ghostty", "" })
    testing.eq(
        parts("tap:browserpass,repo:amar1729/formulae,bin:bpass"),
        { "tap", "browserpass", "amar1729/formulae", "bpass" }
    )
    testing.eq(parts("aur:jjui-bin"), { "aur", "jjui-bin", "", "" })
    testing.eq(
        parts("script:/tmp/x.sh --flag value"),
        { "script", "/tmp/x.sh --flag value", "", "" }
    )
    testing.eq(lib.parse_cell("-"), nil)
end)

testing.test(
    "valid_package accepts plain words and refuses anything that could be an option",
    function()
        local function valid(channel, package, repo)
            return lib.valid_package({
                channel = channel,
                package = package,
                repo = repo or "",
                bin = "",
            })
        end
        for _, ok in ipairs({ "ripgrep", "fd-find", "c++", "python3.12", "@scope.pkg", "a_b" }) do
            testing.ok(valid("", ok), ok)
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
            testing.ok(not valid("", bad), bad)
        end
        testing.ok(valid("copr", "ok", "pgdev/ghostty"))
        testing.ok(not valid("copr", "ok", "a/b/c"))
        testing.ok(valid("script", "/x/y.sh --flag"))
    end
)

testing.test("route names who installs a channel and which driver handles it", function()
    local scope, driver = kinds.route("", kinds.Manager.BREW)
    testing.eq({ scope, driver }, { kinds.Scope.SYSTEM, "brew" })
    scope, driver = kinds.route("cargo", kinds.Manager.BREW)
    testing.eq({ scope, driver }, { kinds.Scope.USER, "cargo" })
    testing.ok(kinds.DRIVERS.script and kinds.DRIVERS.brew and not kinds.DRIVERS.flatpak)
end)

testing.test("groups is never a manager column and a group name never lands in a cell", function()
    local rows = manifest.parse(
        "name binary brew groups\naa a aa-f base\nbb b bb-f rust\ncc c cc-f base,rust\ndd d dd-f -\n"
    )
    testing.eq(manifest.column(rows, "groups"), nil)
    testing.eq(manifest.column(rows, "brew"), 3)
    local selected = assert(select_all(rows, 3))
    testing.eq(#selected, 4)
    for _, row in ipairs(selected) do
        testing.ok(not row.cell:find("base", 1, true), row.cell)
    end
end)

testing.test(
    "a failed logged command prints the last 20 lines of its output under the failure",
    function()
        local dir = assert(fs.realpath(support.tempdir()))
        local probe = 'local lib = require("dev.pkg.lib")\n'
            .. "local opts = { log_file = arg[1] }\n"
            .. 'assert(lib.run({ "echo", "earlier" }, opts) == 0)\n'
            .. 'local code = lib.run({ "sh", "-c", "seq 1 30; echo broke >&2; exit 3" }, opts)\n'
            .. "assert(code == 3)\n"
            .. 'lib.failed({ name = "tool" }, "sh -c x")\n'
            .. 'assert(lib.run({ "true" }, opts) == 0)\n'
            .. "lib.flush_failure()\n"
        assert(fs.write(dir .. "/probe.luau", probe))
        local out, code = dev_os.capture(
            { runtime.exe, "-l", dir .. "/probe.luau", dir .. "/log" },
            { stderr = "stdout" }
        )
        testing.eq(code, 0)
        local expected = '  ! tool: "sh -c x" failed\n'
        for i = 12, 30 do
            expected = expected .. "      " .. i .. "\n"
        end
        testing.eq(out, expected .. "      broke\n")
        fs.remove(dir, { recursive = true })
    end
)
