local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local templates = require("dev.templates")
local project = require("dev.project")
local support = require("support")

local Kind = project.Kind
local MARKER = "-- --- project-specific checks below ---"

local CARGO =
    '[package]\nname = "x"\n\n[workspace.lints.rust]\nunsafe_code = "forbid"\n\n[workspace.lints.clippy]\npedantic = "warn"\n\n[dependencies]\nserde = "1"\n'
local BLOCK = '[workspace.lints.rust]\nunsafe_code = "deny"\n'

testing.test("the lints block replace keeps every line outside the block as it was", function()
    local out = templates.lints_replace(CARGO, BLOCK)
    testing.eq(
        out,
        '[package]\nname = "x"\n\n[workspace.lints.rust]\nunsafe_code = "deny"\n\n[dependencies]\nserde = "1"\n'
    )
    testing.eq(templates.lints_replace(out, BLOCK), out)
end)

testing.test("the lints block replace keeps a file that ends in the block", function()
    local text = '[package]\nname = "x"\n\n[workspace.lints.rust]\nunsafe_code = "forbid"\n'
    testing.eq(
        templates.lints_replace(text, BLOCK),
        '[package]\nname = "x"\n\n[workspace.lints.rust]\nunsafe_code = "deny"\n'
    )
end)

testing.test("the lints block is appended after a blank line when the file has none", function()
    local text = '[package]\nname = "x"\n'
    testing.eq(templates.lints_replace(text, BLOCK), text .. "\n" .. BLOCK)
end)

testing.test(
    "the project's lints block runs to the next other table without trailing blanks",
    function()
        testing.eq(
            templates.lints_project_block(CARGO),
            '[workspace.lints.rust]\nunsafe_code = "forbid"\n\n[workspace.lints.clippy]\npedantic = "warn"\n'
        )
        testing.eq(templates.lints_project_block('[package]\nname = "x"\n'), "")
    end
)

testing.test(
    "lib_attr_insert puts the snippet after the leading doc block and is idempotent",
    function()
        local snippet = "// lints\n#![warn(missing_docs)]\n"
        local lib = "//! Docs.\n//! More.\npub fn f() {}\n"
        local once = templates.lib_attr_insert(snippet, lib)
        testing.eq(
            once,
            "//! Docs.\n//! More.\n\n// lints\n#![warn(missing_docs)]\n\npub fn f() {}\n"
        )
        testing.ok(templates.lib_attr_present(snippet, once))
        testing.eq(templates.lib_attr_insert(snippet, once), once)
        testing.eq(
            templates.lib_attr_insert(snippet, "pub fn f() {}\n"),
            "// lints\n#![warn(missing_docs)]\n\npub fn f() {}\n"
        )
    end
)

testing.test("render keeps a project's advisories ignore array in deny.toml", function()
    local mark = "# --- project-specific entries below (dev sync keeps them) ---"
    local want = '[advisories]\nignore = [\n    "RUSTSEC-1",\n]\nyanked = "deny"\n\n'
    local root = support.sandbox({
        ["deny.toml"] = want .. mark .. "\nkept = 1\n",
    }, {})
    local src = root .. "/src.toml"
    assert(
        fs.write(src, '[advisories]\nyanked = "deny"\n\n' .. mark .. "\n"),
        "fixture setup failed"
    )
    testing.eq(
        templates.render(
            root,
            { kind = Kind.RUST, dest = "deny.toml", src = src, channel = "stable" }
        ),
        want .. mark .. "\nkept = 1\n"
    )
end)

local DENY_MARK = "# --- project-specific entries below (dev sync keeps them) ---"

local function render_deny(project_head, template_head)
    local root = support.sandbox({
        ["deny.toml"] = table.concat({ project_head, DENY_MARK, "kept = 1", "" }, "\n"),
    }, {})
    local src = root .. "/src.toml"
    assert(
        fs.write(src, table.concat({ template_head, DENY_MARK, "" }, "\n")),
        "fixture setup failed"
    )
    return templates.render(
        root,
        { kind = Kind.RUST, dest = "deny.toml", src = src, channel = "stable" }
    )
end

testing.test(
    "render keeps the whole advisories ignore array when a comment holds a bracket",
    function()
        local want = table.concat({
            "[advisories]",
            "ignore = [",
            '    "RUSTSEC-1", # see [issue]',
            '    "RUSTSEC-2",',
            "]",
            'yanked = "deny"',
            "",
        }, "\n")
        local template = table.concat({ "[advisories]", 'yanked = "deny"', "" }, "\n")
        testing.eq(
            render_deny(want, template),
            table.concat({ want, DENY_MARK, "kept = 1", "" }, "\n")
        )
    end
)

testing.test("dev_calls lists the modules and functions a template takes from dev", function()
    local text = table.concat({
        'local fs = require("dev.fs")',
        'local dev_os = require("dev.os")',
        'local standalone = require("dev.standalone")',
        'local x = require("dev.verb").say',
        "return fs.exists(a) and dev_os.run(b) and self.fs.read(c) and other.run(d)",
        "",
    }, "\n")
    testing.eq(templates.dev_calls(text), {
        "dev.fs",
        "dev.fs.exists",
        "dev.os",
        "dev.os.run",
        "dev.standalone",
        "dev.verb",
        "dev.verb.say",
    })
end)

testing.test("dev_calls lists nothing for a file that requires no dev module", function()
    testing.eq(templates.dev_calls('local fs = require("lfs")\nreturn fs.exists(a)\n'), {})
end)

testing.test("render leaves deny.toml alone when the project has no ignore array", function()
    local template = table.concat({ "[advisories]", 'yanked = "deny"', "" }, "\n")
    local existing = table.concat({ "[advisories]", 'yanked = "warn"', "" }, "\n")
    testing.eq(
        render_deny(existing, template),
        table.concat({ template, DENY_MARK, "kept = 1", "" }, "\n")
    )
end)

testing.test("render keeps the project's text below the deny.toml and lint.lua markers", function()
    local root = support.sandbox({
        ["deny.toml"] = "old\n# --- project-specific entries below (dev sync keeps them) ---\nkept = 1\n\n",
        [".dev/lint.lua"] = "old\n" .. MARKER .. "\n\ncheck extra\n\nreturn lint:finish()\n",
        ["rust-toolchain.toml"] = '[toolchain]\nchannel = "1.80.0"\n',
    }, {})
    local src = root .. "/src.toml"
    assert(
        fs.write(
            src,
            "head\n# --- project-specific entries below (dev sync keeps them) ---\ntail\n\n"
        ),
        "fixture setup failed"
    )
    testing.eq(
        templates.render(
            root,
            { kind = Kind.RUST, dest = "deny.toml", src = src, channel = "stable" }
        ),
        "head\n# --- project-specific entries below (dev sync keeps them) ---\nkept = 1\n"
    )
    assert(
        fs.write(src, "head\n\n" .. MARKER .. "\n\nreturn lint:finish()\n"),
        "fixture setup failed"
    )
    testing.eq(
        templates.render(
            root,
            { kind = Kind.RUST, dest = ".dev/lint.lua", src = src, channel = "stable" }
        ),
        "head\n\n" .. MARKER .. "\n\ncheck extra\n\nreturn lint:finish()\n"
    )
    testing.eq(templates.channel(root), "1.80.0")
    assert(
        fs.write(src, '[toolchain]\nchannel = "nightly"\ncomponents = []\n'),
        "fixture setup failed"
    )
    testing.eq(
        templates.render(
            root,
            { kind = Kind.RUST, dest = "rust-toolchain.toml", src = src, channel = "1.80.0" }
        ),
        '[toolchain]\nchannel = "1.80.0"\ncomponents = []\n'
    )
    fs.remove(root, { recursive = true })
end)

testing.test("channel falls back to the lint set's pin, not the installed compiler", function()
    local root = support.sandbox({}, {})
    local dir = assert(templates.dir(Kind.RUST), "no template dir")
    local pin = fs.read(dir .. "/rust-toolchain.toml"):match('channel = "([^"]+)"')
    testing.eq(templates.channel(root), pin)
    assert(
        fs.write(root .. "/rust-toolchain.toml", '[toolchain]\nchannel = "1.80.0"\n'),
        "fixture setup failed"
    )
    testing.eq(templates.channel(root), "1.80.0")
    fs.remove(root, { recursive = true })
end)

testing.test("the lua manifest adds love.yml for love2d only", function()
    local dir = assert(templates.dir(Kind.LUA), "no template dir")
    local function dests(kind)
        local out = {}
        for _, entry in ipairs(templates.manifest(dir, kind)) do
            out[#out + 1] = entry.dest
        end
        return table.concat(out, " ")
    end
    testing.ok(dests(Kind.LOVE2D):find("love.yml", 1, true))
    testing.ok(not dests(Kind.LUA):find("love.yml", 1, true))
    testing.ok(dests(Kind.LUA):find(".dev/ast-grep/rules/", 1, true))
end)

testing.test("lib_crates and app_crates split the member crates by publish = false", function()
    if not dev_os.which("yq") then
        print("skip - yq is not installed")
        return
    end
    local root = support.tempdir()
    local function crate(name, extra)
        assert(
            fs.mkdir(root .. "/crates/" .. name .. "/src", { parents = true }),
            "fixture setup failed"
        )
        assert(
            fs.write(
                root .. "/crates/" .. name .. "/Cargo.toml",
                '[package]\nname = "' .. name .. '"\n' .. extra
            ),
            "fixture setup failed"
        )
        assert(
            fs.write(root .. "/crates/" .. name .. "/src/lib.rs", "pub fn f() {}\n"),
            "fixture setup failed"
        )
    end
    crate("a", "")
    crate("b", "publish = false\n")
    assert(
        fs.write(root .. "/Cargo.toml", '[workspace]\nmembers = ["crates/*"]\n'),
        "fixture setup failed"
    )
    testing.eq(templates.lib_crates(root), { "crates/a" })
    testing.eq(templates.app_crates(root), { "crates/b" })
    fs.remove(root, { recursive = true })
end)

local function dests(dir, kind)
    local out = {}
    for _, entry in ipairs(templates.manifest(dir, kind)) do
        out[#out + 1] = entry.dest
    end
    return out
end

local function has(list, name)
    for _, item in ipairs(list) do
        if item == name then
            return true
        end
    end
    return false
end

testing.test("the manifest names Lua verbs and the shared library for both sets", function()
    local rust = dests(assert(templates.dir(Kind.RUST), "no template dir"), Kind.RUST)
    for _, name in ipairs({ ".dev/lint.lua", ".dev/fmt.lua", ".dev/test.lua" }) do
        testing.ok(has(rust, name), name)
    end
    testing.ok(has(rust, ".dev/lua/lintset.lua"))
    testing.ok(has(rust, "stylua.toml"))
    local lua = dests(assert(templates.dir(Kind.LUA), "no template dir"), Kind.LUA)
    testing.ok(has(lua, ".dev/lint.lua") and has(lua, ".dev/fmt.lua"))
    testing.ok(not has(lua, ".dev/test.lua"))
    for _, list in ipairs({ rust, lua }) do
        for _, name in ipairs(list) do
            testing.ok(not name:find("%.sh$"), name)
        end
    end
end)

testing.test("skip_pending leaves a verb whose bash file has no Lua verb", function()
    local root = support.sandbox({ [".dev/lint.sh"] = "#!/bin/sh\n", [".dev/fmt.lua"] = "" }, {})
    local entries = templates.manifest(assert(templates.dir(Kind.LUA), "no template dir"), Kind.LUA)
    local kept, pending = templates.skip_pending(root, entries)
    testing.eq(pending, { ".dev/lint.sh" })
    local names = {}
    for _, entry in ipairs(kept) do
        names[#names + 1] = entry.dest
    end
    testing.ok(not has(names, ".dev/lint.lua"))
    testing.ok(has(names, ".dev/fmt.lua"))
    testing.ok(has(names, ".dev/lua/lintset.lua"))
    fs.remove(root, { recursive = true })
end)

testing.test("skip_pending drops the shared library when every verb is pending", function()
    local root = support.sandbox({ [".dev/lint.sh"] = "", [".dev/fmt.sh"] = "" }, {})
    local entries = templates.manifest(assert(templates.dir(Kind.LUA), "no template dir"), Kind.LUA)
    local kept, pending = templates.skip_pending(root, entries)
    testing.eq(pending, { ".dev/lint.sh", ".dev/fmt.sh" })
    for _, entry in ipairs(kept) do
        testing.ok(entry.dest ~= ".dev/lua/lintset.lua", entry.dest)
    end
    fs.remove(root, { recursive = true })
end)

testing.test(
    "a rendered lint verb keeps the project's checks and renders the template unchanged",
    function()
        local dir = assert(templates.dir(Kind.RUST), "no template dir")
        local template = assert(fs.read(dir .. "/lint.lua"), "read failed")
        local root = support.sandbox({}, {})
        local opts =
            { kind = Kind.RUST, dest = ".dev/lint.lua", src = dir .. "/lint.lua", channel = "" }
        testing.eq(templates.render(root, opts), template)
        local mine = template:gsub(
            "\nreturn lint:finish%(%)\n$",
            '\nlint:step("mine")\n\nreturn lint:finish()\n'
        )
        assert(fs.write(root .. "/.dev/lint.lua", mine), "fixture setup failed")
        testing.eq(templates.render(root, opts), mine)
        fs.remove(root, { recursive = true })
    end
)

local function synced()
    local root = support.sandbox({ ["a.lua"] = "print(1)\n" }, {})
    local out, code = support.dev(root, { "sync", "--yes" })
    testing.ok(code == 0, out)
    return root
end

testing.test("sync writes Lua verbs and no shell file, and a second check is clean", function()
    local root = synced()
    testing.ok(fs.is_file(root .. "/.dev/lint.lua"))
    testing.ok(fs.is_file(root .. "/.dev/fmt.lua"))
    testing.ok(fs.is_file(root .. "/.dev/lua/lintset.lua"))
    for _, name in ipairs(fs.list(root .. "/.dev") or {}) do
        testing.ok(not name:find("%.sh$"), name)
    end
    local out, code = support.dev(root, { "sync", "--check" })
    testing.ok(code == 0, out)
    testing.ok(out:find("up to date", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("a project's checks below the marker survive a sync", function()
    local root = synced()
    local path = root .. "/.dev/lint.lua"
    local text = assert(fs.read(path), "read failed")
    local mine =
        text:gsub("\nreturn lint:finish%(%)\n$", '\nlint:step("mine")\n\nreturn lint:finish()\n')
    assert(fs.write(path, mine), "fixture setup failed")
    local out, code = support.dev(root, { "sync", "--check" })
    testing.ok(code == 0, out)
    assert(fs.write(root .. "/.dev/fmt.lua", "-- drifted\n"), "fixture setup failed")
    out, code = support.dev(root, { "sync", "--yes" })
    testing.ok(code == 0, out)
    testing.eq(fs.read(path), mine)
    testing.ok(fs.read(root .. "/.dev/fmt.lua") ~= "-- drifted\n")
    fs.remove(root, { recursive = true })
end)

testing.test("a project still on bash verbs passes sync --check and gets no Lua verb", function()
    local root = synced()
    fs.remove(root .. "/.dev/lint.lua")
    fs.remove(root .. "/.dev/fmt.lua")
    fs.remove(root .. "/.dev/lua/lintset.lua")
    assert(fs.write(root .. "/.dev/lint.sh", "#!/bin/sh\n"), "fixture setup failed")
    assert(fs.write(root .. "/.dev/fmt.sh", "#!/bin/sh\n"), "fixture setup failed")
    local out, code = support.dev(root, { "sync", "--check" })
    testing.ok(code == 0, out)
    testing.ok(out:find("pending: .dev/lint.sh, .dev/fmt.sh", 1, true), out)
    out, code = support.dev(root, { "sync", "--yes" })
    testing.ok(code == 0, out)
    testing.ok(not fs.exists(root .. "/.dev/lint.lua"))
    testing.ok(not fs.exists(root .. "/.dev/fmt.lua"))
    testing.ok(not fs.exists(root .. "/.dev/lua/lintset.lua"))
    fs.remove(root .. "/.dev/lint.sh")
    out, code = support.dev(root, { "sync", "--yes" })
    testing.ok(code == 0, out)
    testing.ok(not fs.exists(root .. "/.dev/lint.lua"))
    fs.remove(root .. "/.dev/fmt.sh")
    out, code = support.dev(root, { "sync", "--yes" })
    testing.ok(code == 0, out)
    testing.ok(fs.is_file(root .. "/.dev/lint.lua"))
    testing.ok(fs.is_file(root .. "/.dev/fmt.lua"))
    fs.remove(root, { recursive = true })
end)

testing.test("skip_pending holds every missing Rust verb while lint.sh and fmt.sh exist", function()
    local root = support.sandbox({ [".dev/lint.sh"] = "", [".dev/fmt.sh"] = "" }, {})
    local entries =
        templates.manifest(assert(templates.dir(Kind.RUST), "no template dir"), Kind.RUST)
    local kept, pending = templates.skip_pending(root, entries)
    testing.eq(pending, { ".dev/lint.sh", ".dev/fmt.sh" })
    for _, entry in ipairs(kept) do
        testing.ok(not entry.dest:find("^%.dev/[^/]+%.lua$"), entry.dest)
        testing.ok(entry.dest ~= ".dev/lua/lintset.lua", entry.dest)
    end
    fs.remove(root, { recursive = true })
end)

testing.test("a Rust project on bash verbs without test.sh passes sync --check", function()
    if not dev_os.which("yq") then
        testing.ok(os.getenv("CI") ~= "true", "yq is not installed on ci")
        print("skip - yq is not installed")
        return
    end
    local root = support.sandbox({ ["Cargo.toml"] = '[workspace]\nmembers = ["crates/*"]\n' }, {})
    local out, code = support.dev(root, { "sync", "--yes" })
    testing.ok(code == 0, out)
    for _, name in ipairs({ "lint", "fmt", "test" }) do
        fs.remove(root .. "/.dev/" .. name .. ".lua")
    end
    fs.remove(root .. "/.dev/lua/lintset.lua")
    assert(fs.write(root .. "/.dev/lint.sh", "#!/bin/sh\n"), "fixture setup failed")
    assert(fs.write(root .. "/.dev/fmt.sh", "#!/bin/sh\n"), "fixture setup failed")
    out, code = support.dev(root, { "sync", "--check" })
    testing.ok(code == 0, out)
    testing.ok(out:find("pending: .dev/lint.sh, .dev/fmt.sh", 1, true), out)
    out, code = support.dev(root, { "sync", "--yes" })
    testing.ok(code == 0, out)
    testing.ok(not fs.exists(root .. "/.dev/test.lua"))
    testing.ok(not fs.exists(root .. "/.dev/lua/lintset.lua"))
    fs.remove(root, { recursive = true })
end)

testing.test("a Rust project synced from scratch passes sync --check", function()
    if not dev_os.which("yq") then
        testing.ok(os.getenv("CI") ~= "true", "yq is not installed on ci")
        print("skip - yq is not installed")
        return
    end
    local root = support.sandbox({ ["Cargo.toml"] = '[workspace]\nmembers = ["crates/*"]\n' }, {})
    local out, code = support.dev(root, { "sync", "--yes" })
    testing.ok(code == 0, out)
    for _, name in ipairs({ "lint", "fmt", "test" }) do
        testing.ok(fs.is_file(root .. "/.dev/" .. name .. ".lua"), name)
    end
    testing.eq(
        fs.read(root .. "/stylua.toml"),
        fs.read(assert(templates.dir(Kind.LUA)) .. "/stylua.toml")
    )
    out, code = support.dev(root, { "sync", "--check" })
    testing.ok(code == 0, out)
    testing.eq(out, "up to date\n")
    fs.remove(root, { recursive = true })
end)

local README_MARKER = templates.README_MARKER

local function readme_fixture(own)
    local root = support.sandbox({}, {})
    local template = root .. "/template.md"
    local text = "# Dev\n\nthe template head\n\n" .. README_MARKER .. "\n\nReplace this.\n"
    assert(fs.write(template, text))
    if own then
        assert(fs.write(root .. "/.dev/README.md", own))
    end
    return root, template
end

testing.test("render_readme keeps the project section byte for byte", function()
    local section = README_MARKER
        .. "\n\n`dev go  ` runs\ttabs\r\n\n\n  indented\n\n\nno final newline"
    local root, template = readme_fixture("# old head\n\nstale\n\n" .. section)
    local text = assert(templates.render_readme(root, template))
    testing.eq(text, "# Dev\n\nthe template head\n\n" .. section)
    fs.remove(root, { recursive = true })
end)

testing.test("render_readme gives a file with no marker the template whole", function()
    local root, template = readme_fixture("# my own notes\n")
    local text = assert(templates.render_readme(root, template))
    testing.eq(text, assert(fs.read(template)))
    fs.remove(root, { recursive = true })
end)

testing.test("render_readme reports a README it cannot read", function()
    local root, template = readme_fixture(nil)
    local text, err = templates.render_readme(root, template)
    testing.eq(text, nil)
    testing.ok(err:find("cannot read", 1, true), err)
    fs.remove(root, { recursive = true })
end)
