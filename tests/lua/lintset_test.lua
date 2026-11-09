local testing = require("dev.testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local STYLE = "dotfiles/claude/.claude/skills/style/lint"
local here = devos.capture({ "pwd" }):gsub("\n$", "")
package.path = here .. "/" .. STYLE .. "/?.lua;" .. package.path

local lintset = require("lintset")

local function lint_for(root)
    return lintset.new({ root = root, verbose = 0 })
end

testing.test(
    "spacing flags a comment right under code and passes a blank line before it",
    function()
        testing.eq(lintset.spacing("local a = 1\n-- why\nlocal b = 2\n", "--"), { 2 })
        testing.eq(lintset.spacing("local a = 1\n\n-- why\nlocal b = 2\n", "--"), {})
        testing.eq(lintset.spacing("f(function()\n    -- why\n    g()\nend)\n", "--"), {})
    end
)

testing.test(
    "spacing passes a comment inside a method chain and flags one after the chain",
    function()
        testing.eq(lintset.spacing("let a = x\n    .iter()\n    // keep\n    .map(f);\n", "//"), {})
        testing.eq(
            lintset.spacing("let a = x\n    .map(f);\n    // keep\nlet b = 1;\n", "//"),
            { 3 }
        )
    end
)

testing.test("spacing flags a comment between match arms and passes one in a literal", function()
    testing.eq(
        lintset.spacing("match x {\n    0 => 1,\n    // rest\n    _ => 2,\n}\n", "//"),
        { 3 }
    )
    testing.eq(lintset.spacing("let l = vec![\n    1,\n    // two\n    2,\n];\n", "//"), {})
end)

testing.test("spacing in shell passes a comment heading the next case arm", function()
    testing.eq(
        lintset.spacing(
            "case b in\na)\n    echo a\n    ;;\n# b arm\nb)\n    echo b\n    ;;\nesac\n",
            "#"
        ),
        {}
    )
    testing.eq(lintset.spacing("run \\\n    --flag\n# then\nfinish\n", "#"), { 3 })
end)

testing.test("spacing skips doc comments and block comments", function()
    testing.eq(lintset.spacing("local a = 1\n--- doc\nlocal b\n", "--"), {})
    testing.eq(lintset.spacing("local a = 1\n\n--[[\nnote\n]]\nlocal b\n", "--"), {})
end)

testing.test("runs flags three comment lines and passes lists and doc comments", function()
    testing.eq(lintset.runs("a\n-- one\n-- two\n-- three\nb\n", "--"), { { line = 2, count = 3 } })
    testing.eq(lintset.runs("a\n-- one\n-- two\nb\n", "--"), {})
    testing.eq(lintset.runs("a\n// 1. one\n// two\n// three\nb\n", "//"), {})
    testing.eq(lintset.runs("a\n/// one\n/// two\n/// three\nb\n", "//"), {})
    testing.eq(lintset.runs("// one\n// two\n// three", "//"), { { line = 1, count = 3 } })
end)

testing.test("periods finds a lone one-liner ending in a period and fix drops only that", function()
    local text =
        "fn a() {\n    // Drop it.\n    f();\n\n    // Keep.\n    // This.\n    f();\n    // Wait...\n    f();\n}\n\n/// Doc.\nfn b() {}\n"
    testing.eq(lintset.periods(text), { 2 })
    local fixed = lintset.fix_periods(text)
    testing.eq(fixed, (text:gsub("Drop it%.", "Drop it")))
    testing.eq(lintset.fix_periods(fixed), fixed)
end)

testing.test("files honours lint-ignore and the hidden switch in a git work tree", function()
    if not devos.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev/evidence", { parents = true }), "mkdir evidence failed")
    assert(fs.mkdir(root .. "/src", { parents = true }), "mkdir src failed")
    assert(fs.write(root .. "/.dev/evidence/old.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/src/new.rs", ""), "fixture setup failed")
    assert(devos.run({ "git", "-C", root, "init", "-q" }) == 0, "git init failed")
    local lint = lint_for(root)
    local files = lint:files({ "*.rs" })
    table.sort(files)
    testing.eq(files, { ".dev/evidence/old.rs", "src/new.rs" })
    assert(
        fs.write(root .. "/.dev/lint-ignore", "# note\n\n.dev/evidence/**\n"),
        "fixture setup failed"
    )
    testing.eq(lint:files({ "*.rs" }), { "src/new.rs" })
    fs.remove(root .. "/.dev/lint-ignore")
    lint.skip_hidden = true
    testing.eq(lint:files({ "*.rs" }), { "src/new.rs" })
    fs.remove(root, { recursive = true })
end)

testing.test("finish names the failed checks and returns 1", function()
    local lint = lint_for("/")
    testing.eq(lint:finish(), 0)
    lint.failed = { "a", "b" }
    testing.eq(lint:finish(), 1)
end)

testing.test("standalone warns without failing the lint", function()
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev", { parents = true }), "mkdir failed")
    assert(fs.write(root .. "/.dev/x.sh", "#!/bin/sh\n"), "fixture setup failed")
    local lint = lint_for(root)
    lint:standalone()
    testing.eq(lint.failed, {})
    testing.eq(lint:finish(), 0)
    fs.remove(root, { recursive = true })
end)
