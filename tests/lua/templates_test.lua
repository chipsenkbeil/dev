local t = require("testing")
local fs = require("dev.fs")
local templates = require("dev.templates")
local project = require("dev.project")
local support = require("support")

local Kind = project.Kind

local CARGO =
    '[package]\nname = "x"\n\n[workspace.lints.rust]\nunsafe_code = "forbid"\n\n[workspace.lints.clippy]\npedantic = "warn"\n\n[dependencies]\nserde = "1"\n'
local BLOCK = '[workspace.lints.rust]\nunsafe_code = "deny"\n'

t.test("the lints block replace keeps every line outside the block as it was", function()
    local out = templates.lints_replace(CARGO, BLOCK)
    t.eq(
        out,
        '[package]\nname = "x"\n\n[workspace.lints.rust]\nunsafe_code = "deny"\n\n[dependencies]\nserde = "1"\n'
    )
    t.eq(templates.lints_replace(out, BLOCK), out)
end)

t.test("the lints block replace keeps a file that ends in the block", function()
    local text = '[package]\nname = "x"\n\n[workspace.lints.rust]\nunsafe_code = "forbid"\n'
    t.eq(
        templates.lints_replace(text, BLOCK),
        '[package]\nname = "x"\n\n[workspace.lints.rust]\nunsafe_code = "deny"\n'
    )
end)

t.test("the lints block is appended after a blank line when the file has none", function()
    local text = '[package]\nname = "x"\n'
    t.eq(templates.lints_replace(text, BLOCK), text .. "\n" .. BLOCK)
end)

t.test("the project's lints block runs to the next other table without trailing blanks", function()
    t.eq(
        templates.lints_project_block(CARGO),
        '[workspace.lints.rust]\nunsafe_code = "forbid"\n\n[workspace.lints.clippy]\npedantic = "warn"\n'
    )
    t.eq(templates.lints_project_block('[package]\nname = "x"\n'), "")
end)

t.test("lib_attr_insert puts the snippet after the leading doc block and is idempotent", function()
    local snippet = "// lints\n#![warn(missing_docs)]\n"
    local lib = "//! Docs.\n//! More.\npub fn f() {}\n"
    local once = templates.lib_attr_insert(snippet, lib)
    t.eq(once, "//! Docs.\n//! More.\n\n// lints\n#![warn(missing_docs)]\n\npub fn f() {}\n")
    t.ok(templates.lib_attr_present(snippet, once))
    t.eq(templates.lib_attr_insert(snippet, once), once)
    t.eq(
        templates.lib_attr_insert(snippet, "pub fn f() {}\n"),
        "// lints\n#![warn(missing_docs)]\n\npub fn f() {}\n"
    )
end)

t.test("render keeps the project's text below the deny.toml and lint.sh markers", function()
    local root = support.sandbox({
        ["deny.toml"] = "old\n# --- project-specific entries below (dev sync keeps them) ---\nkept = 1\n\n",
        [".dev/lint.sh"] = "old\n# --- project-specific checks below ---\ncheck extra\n",
        ["rust-toolchain.toml"] = '[toolchain]\nchannel = "1.80.0"\n',
    }, {})
    local src = root .. "/src.toml"
    assert(
        fs.write(
            src,
            "head\n# --- project-specific entries below (dev sync keeps them) ---\ntail\n\n"
        )
    )
    t.eq(
        templates.render(
            root,
            { kind = Kind.RUST, dest = "deny.toml", src = src, channel = "stable" }
        ),
        "head\n# --- project-specific entries below (dev sync keeps them) ---\nkept = 1\n"
    )
    assert(
        fs.write(
            src,
            'cd "$(dirname "${BASH_SOURCE[0]}")"\nsource "$(dirname "${BASH_SOURCE[0]}")/../lint-lib.sh"\n'
        )
    )
    t.eq(
        templates.render(
            root,
            { kind = Kind.RUST, dest = ".dev/lint.sh", src = src, channel = "stable" }
        ),
        'cd "$(dirname "${BASH_SOURCE[0]}")/.."\nsource "$(dirname "${BASH_SOURCE[0]}")/lint-lib.sh"\ncheck extra\n'
    )
    t.eq(templates.channel(root), "1.80.0")
    assert(fs.write(src, '[toolchain]\nchannel = "nightly"\ncomponents = []\n'))
    t.eq(
        templates.render(
            root,
            { kind = Kind.RUST, dest = "rust-toolchain.toml", src = src, channel = "1.80.0" }
        ),
        '[toolchain]\nchannel = "1.80.0"\ncomponents = []\n'
    )
    fs.remove(root, { recursive = true })
end)

t.test("the lua manifest adds love.yml for love2d only", function()
    local dir = assert(templates.dir(Kind.LUA))
    local function dests(kind)
        local out = {}
        for _, entry in ipairs(templates.manifest(dir, kind)) do
            out[#out + 1] = entry.dest
        end
        return table.concat(out, " ")
    end
    t.ok(dests(Kind.LOVE2D):find("love.yml", 1, true))
    t.ok(not dests(Kind.LUA):find("love.yml", 1, true))
    t.ok(dests(Kind.LUA):find(".dev/ast-grep/rules/", 1, true))
end)
