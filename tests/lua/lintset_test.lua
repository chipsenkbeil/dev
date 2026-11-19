local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local verb = require("dev.verb")
local support = require("support")

local STYLE = "dotfiles/claude/.claude/skills/style/lint"
local here = dev_os.capture({ "pwd" }):gsub("\n$", "")
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
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev/evidence", { parents = true }), "mkdir evidence failed")
    assert(fs.mkdir(root .. "/src", { parents = true }), "mkdir src failed")
    assert(fs.write(root .. "/.dev/evidence/old.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/src/new.rs", ""), "fixture setup failed")
    assert(dev_os.run({ "git", "-C", root, "init", "-q" }) == 0, "git init failed")
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

testing.test("files lists a jj checkout with jj file list, not ignored files", function()
    if not dev_os.which("jj") then
        print("skip - jj is not installed")
        return
    end
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/src", { parents = true }), "mkdir src failed")
    assert(fs.mkdir(root .. "/target", { parents = true }), "mkdir target failed")
    assert(fs.write(root .. "/src/new.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/src/skip.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/target/built.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/.gitignore", "src/skip.rs\n"), "fixture setup failed")
    assert(dev_os.run({ "jj", "git", "init", root }) == 0, "jj git init failed")
    local lint = lint_for(root)
    testing.eq(lint:files({ "*.rs" }), { "src/new.rs" })
    assert(fs.mkdir(root .. "/.dev", { parents = true }), "mkdir dev failed")
    assert(fs.write(root .. "/.dev/hidden.rs", ""), "fixture setup failed")
    local files = lint:files({ "*.rs" })
    table.sort(files)
    testing.eq(files, { ".dev/hidden.rs", "src/new.rs" })
    lint.skip_hidden = true
    testing.eq(lint:files({ "*.rs" }), { "src/new.rs" })
    assert(fs.write(root .. "/.dev/lint-ignore", "src/new.rs\n"), "fixture setup failed")
    testing.eq(lint:files({ "*.rs" }), {})
    fs.remove(root, { recursive = true })
end)

testing.test("dev_lua lists the Lua under .dev and .ci with skip_hidden set", function()
    local root = support.tempdir()
    for _, dir in ipairs({ ".dev", ".ci", ".claude", "src" }) do
        assert(fs.mkdir(root .. "/" .. dir, { parents = true }), "mkdir failed")
    end
    assert(fs.write(root .. "/.dev/a.lua", ""), "fixture setup failed")
    assert(fs.write(root .. "/.ci/b.lua", ""), "fixture setup failed")
    assert(fs.write(root .. "/.claude/c.lua", ""), "fixture setup failed")
    assert(fs.write(root .. "/src/d.lua", ""), "fixture setup failed")
    assert(dev_os.run({ "git", "-C", root, "init", "-q" }) == 0, "git init failed")
    local lint = lint_for(root)
    lint.skip_hidden = true
    local files = lint:dev_lua()
    table.sort(files)
    testing.eq(files, { ".ci/b.lua", ".dev/a.lua" })
    testing.eq(lint.skip_hidden, true)
    fs.remove(root, { recursive = true })
end)

testing.test("files rg fallback honours gitignore without a git repository", function()
    if not dev_os.which("rg") then
        print("skip - rg is not installed")
        return
    end
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/src", { parents = true }), "mkdir src failed")
    assert(fs.write(root .. "/src/new.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/src/skip.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/.gitignore", "src/skip.rs\n"), "fixture setup failed")
    testing.eq(lint_for(root):files({ "*.rs" }), { "src/new.rs" })
    fs.remove(root, { recursive = true })
end)

testing.test("files rg fallback matches a literal name, a dot and a question mark", function()
    if not dev_os.which("rg") then
        print("skip - rg is not installed")
        return
    end
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/sub", { parents = true }), "mkdir sub failed")
    local names = { "Cargo.toml", "sub/Cargo.toml", "CargoXtoml", "a.lua", "ab.lua", "fooxlua" }
    for _, name in ipairs(names) do
        assert(fs.write(root .. "/" .. name, ""), "fixture setup failed")
    end
    local lint = lint_for(root)
    local files = lint:files({ "Cargo.toml" })
    table.sort(files)
    testing.eq(files, { "Cargo.toml", "sub/Cargo.toml" })
    testing.eq(lint:files({ "?.lua" }), { "a.lua" })
    files = lint:files({ "*.lua" })
    table.sort(files)
    testing.eq(files, { "a.lua", "ab.lua" })
    fs.remove(root, { recursive = true })
end)

testing.test("an unreadable file fails the comment checks instead of reading as empty", function()
    local root = support.tempdir()
    local lint = lint_for(root)
    lint:comment_spacing("gone.lua", "--")
    lint:comment_runs("gone.lua", "--")
    testing.eq(lint.failed, { "comment spacing", "comment runs" })
    fs.remove(root, { recursive = true })
end)

testing.test("finish names the failed checks and returns 1", function()
    local lint = lint_for("/")
    testing.eq(lint:finish(), 0)
    lint.failed = { "a", "b" }
    local original = verb.note
    local notes = {}
    verb.note = function(text)
        notes[#notes + 1] = text
    end
    local ok, code = pcall(lint.finish, lint)
    verb.note = original
    assert(ok, code)
    testing.eq(code, 1)
    testing.eq(notes, { "These checks failed: a, b." })
end)

testing.test("a check that fails twice is recorded once, in the order it first failed", function()
    local lint = lint_for("/")
    lint:check("a", { "false" })
    lint:fail("b", "b is wrong")
    lint:check("a", { "false" })
    lint:fail("b", "b is still wrong")
    lint:check("c", { "true" })
    lint:fail("d", "d is wrong")
    testing.eq(lint.failed, { "a", "b", "d" })
end)

testing.test("the closing note names each failed check once", function()
    local root = support.tempdir()
    local code = "local lint = require('lintset').new({ root = %q, verbose = 0 }); "
        .. "lint:fail('a', 'one'); lint:fail('b', 'two'); lint:fail('a', 'three'); "
        .. "os.exit(lint:finish())"
    local snippet = ("package.path = %q; " .. code):format(package.path, root)
    local errors = root .. "/stderr.txt"
    dev_os.capture({ "luajit", "-e", snippet }, { stderr = errors })
    testing.eq(assert(fs.read(errors)), "one\ntwo\nthree\nThese checks failed: a, b.\n")
    fs.remove(root, { recursive = true })
end)

local function quiet_finish(lint)
    local original = verb.note
    local notes = {}
    verb.note = function(text)
        notes[#notes + 1] = text
    end
    local ok, code = pcall(lint.finish, lint)
    verb.note = original
    assert(ok, code)
    return code, notes
end

testing.test("standalone fails the lint on a .sh outside .dev/standalone", function()
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev", { parents = true }), "mkdir failed")
    assert(fs.write(root .. "/.dev/x.sh", "#!/bin/sh\n"), "fixture setup failed")
    local lint = lint_for(root)
    lint:standalone()
    testing.eq(lint.failed, { "standalone shell" })
    local code, notes = quiet_finish(lint)
    testing.eq(code, 1)
    testing.eq(notes, { "These checks failed: standalone shell." })
    fs.remove(root, { recursive = true })
end)

testing.test("standalone fails the lint on a bad standalone header", function()
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev/standalone", { parents = true }), "mkdir failed")
    assert(
        fs.write(root .. "/.dev/standalone/x.sh", "#!/bin/sh\n# runs somewhere\n"),
        "fixture setup failed"
    )
    local lint = lint_for(root)
    lint:standalone()
    testing.eq(lint.failed, { "standalone shell" })
    local code, notes = quiet_finish(lint)
    testing.eq(code, 1)
    testing.eq(notes, { "These checks failed: standalone shell." })
    fs.remove(root, { recursive = true })
end)

testing.test("standalone writes each problem line to standard error", function()
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev", { parents = true }), "mkdir failed")
    assert(fs.write(root .. "/.dev/x.sh", "#!/bin/sh\n"), "fixture setup failed")
    assert(fs.write(root .. "/.dev/y.sh", "#!/bin/sh\n"), "fixture setup failed")
    local code = "require('lintset').new({ root = %q, verbose = 0 }):standalone()"
    local snippet = ("package.path = %q; " .. code):format(package.path, root)
    local errors = root .. "/stderr.txt"
    local out = dev_os.capture({ "luajit", "-e", snippet }, { stderr = errors })
    testing.eq(out, "> standalone shell\n")
    local reason = "shell outside .dev/standalone, port it to Lua (dev help porting)\n"
    testing.eq(assert(fs.read(errors)), ".dev/x.sh: " .. reason .. ".dev/y.sh: " .. reason)
    fs.remove(root, { recursive = true })
end)
