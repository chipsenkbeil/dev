local dev_os = require("dev.os")
local manifest = require("dev.manifest")

local failures = 0

local function check(name, body)
    local ok, err = pcall(body)
    if ok then
        print("ok   " .. name)
    else
        failures += 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local function same(actual, expected)
    if actual ~= expected then
        error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
    end
end

local function names(selected)
    local out = {}
    for _, row in selected do
        table.insert(out, row.name)
    end
    return table.concat(out, ",")
end

local VARS = table.concat({
    "# @env FOO bar_value",
    '# @env SP "asdf asdf"',
    "name         binary  brew",
    "bare-foo     x       $FOO",
    "braced-foo   x       ${FOO}",
    'quoted-sp    x       "$SP"',
    'braced-sp    x       "${SP}"',
    "mid-script   x       script:${FOO}",
    "mid-copr     x       copr:p,repo:${FOO}",
    'quoted-lit   x       "/x --y"',
    "escape       x       price$$5",
    "escape-name  x       $$FOO",
    "",
}, "\n")

local function cells(selected)
    local out = {}
    for _, row in selected do
        out[row.name] = row.cell
    end
    return out
end

check("parse reads the header, the defaults and each row", function()
    local rows = manifest.parse(VARS)
    -- the rows and the header
    same(#rows, 9)
    same(rows.header[3], "brew")
    -- the @env defaults
    same(rows.defaults.FOO, "bar_value")
    same(rows.defaults.SP, "asdf asdf")
    -- the first row and its cells
    same(rows[1].name, "bare-foo")
    same(rows[1].binary, "x")
    same(rows[1].fields[3], "$FOO")
    same(#rows[1].groups, 0)
end)

check("a quoted cell with spaces is one cell and unquoted cells split on runs of blanks", function()
    local rows = manifest.parse(
        'name\tbinary  brew\nplain\tpl\tripgrep\nargs zzz "script:/tmp/x.sh --flag value"\n'
    )
    local column = assert(manifest.column(rows, "brew"))
    local picked = cells(assert(manifest.select(rows, { column = column })))
    same(picked.plain, "ripgrep")
    same(picked.args, "script:/tmp/x.sh --flag value")
end)

check("select expands variables from the @env default and the environment", function()
    local picked = cells(assert(manifest.select(manifest.parse(VARS), { column = 3 })))
    -- variables that resolve through the defaults
    same(picked["bare-foo"], "bar_value")
    same(picked["braced-foo"], "bar_value")
    same(picked["quoted-sp"], "asdf asdf")
    same(picked["braced-sp"], "asdf asdf")
    same(picked["quoted-lit"], "/x --y")
    same(picked["mid-script"], "script:bar_value")
    same(picked["mid-copr"], "copr:p,repo:bar_value")
    -- the escape forms
    same(picked.escape, "price$5")
    same(picked["escape-name"], "$FOO")
    -- the environment against a default
    local env = manifest.parse("# @env HOME not-this\nname binary brew\nx y $HOME\n")
    local home = cells(assert(manifest.select(env, { column = 3 }))).x
    assert(home ~= "not-this" and home ~= "", "the environment should win over the default")
end)

check("an undefined variable fails the whole selection and names the variable and row", function()
    local selected, err = manifest.select(
        manifest.parse("name binary brew\nnope-row x ${NOPE_U03}\nfine y ripgrep\n"),
        { column = 3 }
    )
    same(selected, nil)
    same(err, "Variable ${NOPE_U03} is undefined in row nope-row.")
end)

check("a variable in another manager's column does not fail the selection", function()
    local rows = manifest.parse("name binary brew pacman\nx y ripgrep ${NOPE_U03}\n")
    same(names(assert(manifest.select(rows, { column = 3 }))), "x")
    same((manifest.select(rows, { column = 4 })), nil)
end)

check("select keeps the rows of one group, comma lists included", function()
    local rows = manifest.parse(
        "name binary brew groups\naa a aa-f base\nbb b bb-f rust\ncc c cc-f base,rust\ndd d dd-f -\n"
    )
    -- one group, then the unfiltered cases
    same(names(assert(manifest.select(rows, { column = 3, group = "base" }))), "aa,cc")
    same(names(assert(manifest.select(rows, { column = 3, group = "rust" }))), "bb,cc")
    same(names(assert(manifest.select(rows, { column = 3, group = "nope" }))), "")
    same(names(assert(manifest.select(rows, { column = 3 }))), "aa,bb,cc,dd")
    same(names(assert(manifest.select(rows, { column = 3, group = "" }))), "aa,bb,cc,dd")
    same(#rows[3].groups, 2)
end)

check("column finds a manager and never groups", function()
    local rows = manifest.parse("name binary brew groups\naa a aa-f base\n")
    same(manifest.column(rows, "brew"), 3)
    same(manifest.column(rows, "groups"), nil)
    same(manifest.column(rows, "nope"), nil)
    same(manifest.column(rows, "name"), nil)
end)

check("a manifest with no groups column has no groups", function()
    local rows = manifest.parse("name binary brew\naa a aa-f\n")
    same(#assert(manifest.select(rows, { column = 3, group = "base" })), 0)
end)

check("an empty manifest has no rows", function()
    local rows = manifest.parse("")
    same(#rows, 0)
    same(#rows.header, 0)
end)

if failures > 0 then
    print(failures .. " failed")
    dev_os.exit(1)
end
