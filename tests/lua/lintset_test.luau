local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local dev_command = require("@dev/command")
local support = require("./support")

local STYLE = ".dev/lib"
local here = dev_os.capture({ "pwd" }):gsub("\n$", "")

local lintset = require("@lib/lintset")

local function lint_for(root)
    return lintset.new({ root = root, verbose = 0 })
end

testing.test(
    "spacing flags a comment right under code and passes a blank line before it",
    function()
        testing.eq(
            lintset.spacing(
                table.concat({ "local a = 1", "-- why", "local b = 2", "" }, "\n"),
                "--"
            ),
            { 2 }
        )
        testing.eq(
            lintset.spacing(
                table.concat({ "local a = 1", "", "-- why", "local b = 2", "" }, "\n"),
                "--"
            ),
            {}
        )
        testing.eq(
            lintset.spacing(
                table.concat({ "f(function()", "    -- why", "    g()", "end)", "" }, "\n"),
                "--"
            ),
            {}
        )
    end
)

testing.test(
    "spacing passes a comment inside a method chain and flags one after the chain",
    function()
        testing.eq(
            lintset.spacing(
                table.concat({
                    "let a = x",
                    "    .iter()",
                    "    // keep",
                    "    .map(f);",
                    "",
                }, "\n"),
                "//"
            ),
            {}
        )
        testing.eq(
            lintset.spacing(
                table.concat({
                    "let a = x",
                    "    .map(f);",
                    "    // keep",
                    "let b = 1;",
                    "",
                }, "\n"),
                "//"
            ),
            { 3 }
        )
    end
)

testing.test("spacing flags a comment between match arms and passes one in a literal", function()
    testing.eq(
        lintset.spacing(
            table.concat({
                "match x {",
                "    0 => 1,",
                "    // rest",
                "    _ => 2,",
                "}",
                "",
            }, "\n"),
            "//"
        ),
        { 3 }
    )
    testing.eq(
        lintset.spacing(
            table.concat({ "let l = vec![", "    1,", "    // two", "    2,", "];", "" }, "\n"),
            "//"
        ),
        {}
    )
end)

testing.test("spacing in shell passes a comment heading the next case arm", function()
    testing.eq(
        lintset.spacing(
            table.concat({
                "case b in",
                "a)",
                "    echo a",
                "    ;;",
                "# b arm",
                "b)",
                "    echo b",
                "    ;;",
                "esac",
                "",
            }, "\n"),
            "#"
        ),
        {}
    )
    testing.eq(
        lintset.spacing(table.concat({ "run \\", "    --flag", "# then", "finish", "" }, "\n"), "#"),
        { 3 }
    )
end)

testing.test("spacing in shell skips a heredoc body and flags a comment after it", function()
    testing.eq(lintset.spacing(table.concat({ "cat <<EOF", "# data", "EOF", "" }, "\n"), "#"), {})
    testing.eq(
        lintset.spacing(table.concat({ "cat <<'EOF'", "x", "# data", "EOF", "" }, "\n"), "#"),
        {}
    )
    testing.eq(
        lintset.spacing(table.concat({ "cat <<-EOF", "\t# data", "\tEOF", "" }, "\n"), "#"),
        {}
    )
    testing.eq(
        lintset.spacing(
            table.concat({ "cat <<EOF", "# data", "EOF", "# after", "next", "" }, "\n"),
            "#"
        ),
        { 4 }
    )
    testing.eq(
        lintset.spacing(table.concat({ "cat <<< word", "# after", "next", "" }, "\n"), "#"),
        { 2 }
    )
    testing.eq(lintset.spacing(table.concat({ "cat <<\\EOF", "# data", "EOF", "" }, "\n"), "#"), {})
end)

testing.test("spacing in shell ignores a heredoc marker in a string or a comment", function()
    testing.eq(
        lintset.spacing(table.concat({ 'echo "cmd <<EOF"', "# after", "next", "" }, "\n"), "#"),
        { 2 }
    )
    testing.eq(
        lintset.spacing(table.concat({ "foo # see <<EOF", "# after", "next", "" }, "\n"), "#"),
        { 2 }
    )
    testing.eq(
        lintset.spacing(table.concat({ "x=$[1<<n]", "# after", "next", "" }, "\n"), "#"),
        { 2 }
    )
end)

testing.test("spacing in shell treats an unclosed heredoc as code", function()
    testing.eq(
        lintset.spacing(table.concat({ "cat <<EOF", "# after", "next", "" }, "\n"), "#"),
        { 2 }
    )
    testing.eq(
        lintset.runs(table.concat({ "cat <<EOF", "# a", "# b", "# c", "" }, "\n"), "#"),
        { { line = 2, count = 3 } }
    )
end)

testing.test("spacing in shell closes a dash heredoc on a tab terminator only", function()
    testing.eq(
        lintset.spacing(
            table.concat({ "cat <<-EOF", "    EOF", "# data", "\tEOF", "next", "" }, "\n"),
            "#"
        ),
        {}
    )
    testing.eq(
        lintset.spacing(table.concat({ "cat <<-EOF", "# data", "    EOF", "next", "" }, "\n"), "#"),
        { 2 }
    )
end)

testing.test("spacing in shell reads a quoted heredoc word with spaces whole", function()
    testing.eq(
        lintset.spacing(
            table.concat({ "cat <<'END OF'", "# data", "END OF", "# after", "next", "" }, "\n"),
            "#"
        ),
        { 4 }
    )
    testing.eq(
        lintset.spacing(
            table.concat({ 'cat <<"END OF"', "# data", "END", "END OF", "next", "" }, "\n"),
            "#"
        ),
        {}
    )
end)

testing.test("spacing in shell tracks two heredocs on one line in order", function()
    testing.eq(
        lintset.spacing(
            table.concat({ "cat <<A <<B", "# a", "A", "# b", "B", "# after", "next", "" }, "\n"),
            "#"
        ),
        { 6 }
    )
end)

testing.test(
    "spacing in shell finds an opener after hash in a count or an escaped quote",
    function()
        testing.eq(
            lintset.spacing(table.concat({ "cat ${#x} <<EOF", "# data", "EOF", "" }, "\n"), "#"),
            {}
        )
        testing.eq(
            lintset.spacing(table.concat({ 'echo \\" <<EOF', "# data", "EOF", "" }, "\n"), "#"),
            {}
        )
    end
)

testing.test("spacing skips doc comments and block comments", function()
    testing.eq(
        lintset.spacing(table.concat({ "local a = 1", "--- doc", "local b", "" }, "\n"), "--"),
        {}
    )
    testing.eq(
        lintset.spacing(
            table.concat({ "local a = 1", "", "--[[", "note", "]]", "local b", "" }, "\n"),
            "--"
        ),
        {}
    )
end)

testing.test("runs flags three comment lines and passes lists and doc comments", function()
    testing.eq(
        lintset.runs(table.concat({ "a", "-- one", "-- two", "-- three", "b", "" }, "\n"), "--"),
        { { line = 2, count = 3 } }
    )
    testing.eq(lintset.runs(table.concat({ "a", "-- one", "-- two", "b", "" }, "\n"), "--"), {})
    testing.eq(
        lintset.runs(table.concat({ "a", "// 1. one", "// two", "// three", "b", "" }, "\n"), "//"),
        {}
    )
    testing.eq(
        lintset.runs(table.concat({ "a", "/// one", "/// two", "/// three", "b", "" }, "\n"), "//"),
        {}
    )
    testing.eq(
        lintset.runs(table.concat({ "// one", "// two", "// three" }, "\n"), "//"),
        { { line = 1, count = 3 } }
    )
end)

testing.test("runs skips a heredoc body and counts real hash comments around it", function()
    testing.eq(
        lintset.runs(table.concat({ "cat <<EOF", "# a", "# b", "# c", "EOF", "" }, "\n"), "#"),
        {}
    )
    testing.eq(
        lintset.runs(
            table.concat({ "cat <<-EOF", "\t# a", "\t# b", "\t# c", "\tEOF", "" }, "\n"),
            "#"
        ),
        {}
    )
    testing.eq(
        lintset.runs(
            table.concat({ "cat <<EOF", "x", "EOF", "# one", "# two", "# three", "b", "" }, "\n"),
            "#"
        ),
        { { line = 4, count = 3 } }
    )
    testing.eq(
        lintset.runs(table.concat({ "a", "# one", "# two", "# three", "b", "" }, "\n"), "#"),
        { { line = 2, count = 3 } }
    )
    testing.eq(
        lintset.runs(table.concat({ "echo 'cmd <<EOF'", "# a", "# b", "# c", "" }, "\n"), "#"),
        { { line = 2, count = 3 } }
    )
end)

testing.test("periods finds a lone one-liner ending in a period and fix drops only that", function()
    -- Write source with one removable one-liner period and several that must stay
    local text = table.concat({
        "fn a() {",
        "    // Drop it.",
        "    f();",
        "",
        "    // Keep.",
        "    // This.",
        "    f();",
        "    // Wait...",
        "    f();",
        "}",
        "",
        "/// Doc.",
        "fn b() {}",
        "",
    }, "\n")

    -- Expect only the lone one-liner to be found
    testing.eq(lintset.periods(text), { 2 })

    -- Expect the fix to drop that period only, and a second fix to change nothing
    local fixed = lintset.fix_periods(text)
    testing.eq(fixed, (text:gsub("Drop it%.", "Drop it")))
    testing.eq(lintset.fix_periods(fixed), fixed)
end)

testing.test("files honours lint-ignore and the hidden switch in a git work tree", function()
    -- Skip when git is not installed
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end

    -- Make a git work tree with one evidence file and one source file
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev/evidence", { parents = true }), "mkdir evidence failed")
    assert(fs.mkdir(root .. "/src", { parents = true }), "mkdir src failed")
    assert(fs.write(root .. "/.dev/evidence/old.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/src/new.rs", ""), "fixture setup failed")
    assert(dev_os.run({ "git", "-C", root, "init", "-q" }) == 0, "git init failed")

    -- Expect both files to be listed
    local lint = lint_for(root)
    local files = lint:files({ "*.rs" })
    table.sort(files)
    testing.eq(files, { ".dev/evidence/old.rs", "src/new.rs" })

    -- Expect lint-ignore to hide the evidence folder
    assert(
        fs.write(
            root .. "/.dev/lint-ignore",
            table.concat({ "# note", "", ".dev/evidence/**", "" }, "\n")
        ),
        "fixture setup failed"
    )
    testing.eq(lint:files({ "*.rs" }), { "src/new.rs" })

    -- Expect the hidden switch to hide it too once lint-ignore is gone
    fs.remove(root .. "/.dev/lint-ignore")
    lint.skip_hidden = true
    testing.eq(lint:files({ "*.rs" }), { "src/new.rs" })
    fs.remove(root, { recursive = true })
end)

testing.test("files lists a jj checkout with jj file list, not ignored files", function()
    -- Skip when jj is not installed
    if not dev_os.which("jj") then
        print("skip - jj is not installed")
        return
    end

    -- Make a jj checkout with an ignored file and a build folder
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/src", { parents = true }), "mkdir src failed")
    assert(fs.mkdir(root .. "/target", { parents = true }), "mkdir target failed")
    assert(fs.write(root .. "/src/new.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/src/skip.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/target/built.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/.gitignore", "src/skip.rs\n"), "fixture setup failed")
    assert(dev_os.run({ "jj", "git", "init", root }) == 0, "jj git init failed")

    -- Expect only the tracked source file to be listed
    local lint = lint_for(root)
    testing.eq(lint:files({ "*.rs" }), { "src/new.rs" })

    -- Add a hidden file and expect it to be listed
    assert(fs.mkdir(root .. "/.dev", { parents = true }), "mkdir dev failed")
    assert(fs.write(root .. "/.dev/hidden.rs", ""), "fixture setup failed")
    local files = lint:files({ "*.rs" })
    table.sort(files)
    testing.eq(files, { ".dev/hidden.rs", "src/new.rs" })

    -- Expect skip_hidden and then lint-ignore to drop files
    lint.skip_hidden = true
    testing.eq(lint:files({ "*.rs" }), { "src/new.rs" })
    assert(fs.write(root .. "/.dev/lint-ignore", "src/new.rs\n"), "fixture setup failed")
    testing.eq(lint:files({ "*.rs" }), {})
    fs.remove(root, { recursive = true })
end)

testing.test("files says why when jj file list fails and still lists the files", function()
    -- Skip when jj is not installed
    if not dev_os.which("jj") then
        print("skip - jj is not installed")
        return
    end

    -- Make a jj checkout whose lint-ignore holds a bad glob
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/src", { parents = true }), "mkdir src failed")
    assert(fs.mkdir(root .. "/.dev", { parents = true }), "mkdir dev failed")
    assert(fs.write(root .. "/src/new.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/.dev/lint-ignore", "{a\n"), "fixture setup failed")
    assert(dev_os.run({ "jj", "git", "init", root }) == 0, "jj git init failed")

    -- Record the notes the lint raises instead of printing them
    local notes = {}
    local note = dev_command.note
    dev_command.note = function(text)
        notes[#notes + 1] = text
    end

    -- List the files, then restore the note function and clean up
    local ok, files = pcall(function()
        return lint_for(root):files({ "*.rs" })
    end)
    dev_command.note = note
    fs.remove(root, { recursive = true })
    assert(ok, files)

    -- Expect the note to give the reason and the listing to fall back
    testing.eq(notes, {
        "The jj file list command failed with exit 1. A bad glob in .dev/lint-ignore is the usual cause."
            .. " Lint falls back to git or rg.",
    })
    testing.eq(files, { "src/new.rs" })
end)

testing.test("dev_lua lists the Lua under .dev and .ci with skip_hidden set", function()
    -- Make a git work tree with Lua files in hidden and visible folders
    local root = support.tempdir()
    for _, dir in ipairs({ ".dev", ".ci", ".claude", "src" }) do
        assert(fs.mkdir(root .. "/" .. dir, { parents = true }), "mkdir failed")
    end
    assert(fs.write(root .. "/.dev/a.lua", ""), "fixture setup failed")
    assert(fs.write(root .. "/.ci/b.lua", ""), "fixture setup failed")
    assert(fs.write(root .. "/.claude/c.lua", ""), "fixture setup failed")
    assert(fs.write(root .. "/src/d.lua", ""), "fixture setup failed")
    assert(dev_os.run({ "git", "-C", root, "init", "-q" }) == 0, "git init failed")

    -- List the Lua with hidden folders skipped
    local lint = lint_for(root)
    lint.skip_hidden = true
    local files = lint:dev_lua()
    table.sort(files)

    -- Expect only the .dev and .ci files, and skip_hidden restored
    testing.eq(files, { ".ci/b.lua", ".dev/a.lua" })
    testing.eq(lint.skip_hidden, true)
    fs.remove(root, { recursive = true })
end)

testing.test("files lists hidden paths with the hidden option when skip_hidden is set", function()
    -- Make a git work tree with one hidden and one visible file
    local root = support.tempdir()
    for _, dir in ipairs({ ".dev", "src" }) do
        assert(fs.mkdir(root .. "/" .. dir, { parents = true }), "mkdir failed")
    end
    assert(fs.write(root .. "/.dev/a.lua", ""), "fixture setup failed")
    assert(fs.write(root .. "/src/d.lua", ""), "fixture setup failed")
    assert(dev_os.run({ "git", "-C", root, "init", "-q" }) == 0, "git init failed")

    -- Expect skip_hidden to list the visible file only
    local lint = lint_for(root)
    lint.skip_hidden = true
    testing.eq(lint:files({ "*.lua" }), { "src/d.lua" })

    -- Expect the hidden option to list both files
    local files = lint:files({ "*.lua" }, { hidden = true })
    table.sort(files)
    testing.eq(files, { ".dev/a.lua", "src/d.lua" })
    fs.remove(root, { recursive = true })
end)

testing.test("files rg fallback honours gitignore without a git repository", function()
    -- Skip when rg is not installed
    if not dev_os.which("rg") then
        print("skip - rg is not installed")
        return
    end

    -- Make a source tree with a gitignored file but no repository
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/src", { parents = true }), "mkdir src failed")
    assert(fs.write(root .. "/src/new.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/src/skip.rs", ""), "fixture setup failed")
    assert(fs.write(root .. "/.gitignore", "src/skip.rs\n"), "fixture setup failed")

    -- Expect the ignored file to be left out
    testing.eq(lint_for(root):files({ "*.rs" }), { "src/new.rs" })
    fs.remove(root, { recursive = true })
end)

testing.test("files rg fallback matches a literal name, a dot and a question mark", function()
    -- Skip when rg is not installed
    if not dev_os.which("rg") then
        print("skip - rg is not installed")
        return
    end

    -- Make files whose names nearly match the patterns
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/sub", { parents = true }), "mkdir sub failed")
    local names = { "Cargo.toml", "sub/Cargo.toml", "CargoXtoml", "a.lua", "ab.lua", "fooxlua" }
    for _, name in ipairs(names) do
        assert(fs.write(root .. "/" .. name, ""), "fixture setup failed")
    end

    -- Expect a literal name to match itself and its copy in a subfolder only
    local lint = lint_for(root)
    local files = lint:files({ "Cargo.toml" })
    table.sort(files)
    testing.eq(files, { "Cargo.toml", "sub/Cargo.toml" })

    -- Expect a question mark to match one character and a star to match a run
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
    -- Expect a lint with no failures to finish with 0
    local lint = lint_for("/")
    testing.eq(lint:finish(), 0)

    -- Fail two checks while recording the closing note
    lint.failed = { "a", "b" }
    local original = dev_command.note
    local notes = {}
    dev_command.note = function(text)
        notes[#notes + 1] = text
    end
    local ok, code = pcall(lint.finish, lint)
    dev_command.note = original
    assert(ok, code)

    -- Expect exit code 1 and a note naming both checks
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
    -- Build a snippet that fails two checks, one of them twice
    local root = support.tempdir()
    local code = "local lint = require('@lib/lintset').new({ root = %q, verbose = 0 }); "
        .. "lint:fail('a', 'one'); lint:fail('b', 'two'); lint:fail('a', 'three'); "
        .. "require('@dev/os').exit(lint:finish())"
    local snippet = code:format(root)
    local stderr_path = root .. "/stderr.txt"

    -- Run it and capture its standard error
    dev_os.capture(
        support.eval_aliased({ lib = here .. "/" .. STYLE }, snippet),
        { stderr = stderr_path }
    )

    -- Expect every reason, then one closing note naming each check once
    testing.eq(
        assert(fs.read(stderr_path)),
        table.concat({ "one", "two", "three", "These checks failed: a, b.", "" }, "\n")
    )
    fs.remove(root, { recursive = true })
end)

local function quiet_finish(lint)
    local original = dev_command.note
    local notes = {}
    dev_command.note = function(text)
        notes[#notes + 1] = text
    end
    local ok, code = pcall(lint.finish, lint)
    dev_command.note = original
    assert(ok, code)
    return code, notes
end

testing.test("standalone fails the lint on a .sh outside .dev/standalone", function()
    -- Put a shell script outside .dev/standalone
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev", { parents = true }), "mkdir failed")
    assert(fs.write(root .. "/.dev/x.sh", "#!/bin/sh\n"), "fixture setup failed")

    -- Expect the standalone check to fail
    local lint = lint_for(root)
    lint:standalone()
    testing.eq(lint.failed, { "standalone shell" })

    -- Expect the lint to finish with 1 and name the check
    local code, notes = quiet_finish(lint)
    testing.eq(code, 1)
    testing.eq(notes, { "These checks failed: standalone shell." })
    fs.remove(root, { recursive = true })
end)

testing.test("standalone fails the lint on a bad standalone header", function()
    -- Put a standalone shell script with a bad header
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev/standalone", { parents = true }), "mkdir failed")
    assert(
        fs.write(
            root .. "/.dev/standalone/x.sh",
            table.concat({ "#!/bin/sh", "# runs somewhere", "" }, "\n")
        ),
        "fixture setup failed"
    )

    -- Expect the standalone check to fail
    local lint = lint_for(root)
    lint:standalone()
    testing.eq(lint.failed, { "standalone shell" })

    -- Expect the lint to finish with 1 and name the check
    local code, notes = quiet_finish(lint)
    testing.eq(code, 1)
    testing.eq(notes, { "These checks failed: standalone shell." })
    fs.remove(root, { recursive = true })
end)

testing.test("standalone writes each problem line to standard error", function()
    -- Put two shell scripts outside .dev/standalone
    local root = support.tempdir()
    assert(fs.mkdir(root .. "/.dev", { parents = true }), "mkdir failed")
    assert(fs.write(root .. "/.dev/x.sh", "#!/bin/sh\n"), "fixture setup failed")
    assert(fs.write(root .. "/.dev/y.sh", "#!/bin/sh\n"), "fixture setup failed")

    -- Run the standalone check and capture both output streams
    local code = "require('@lib/lintset').new({ root = %q, verbose = 0 }):standalone()"
    local snippet = code:format(root)
    local stderr_path = root .. "/stderr.txt"
    local out = dev_os.capture(
        support.eval_aliased({ lib = here .. "/" .. STYLE }, snippet),
        { stderr = stderr_path }
    )

    -- Expect the check name on standard output and each problem on standard error
    testing.eq(out, "> standalone shell\n")
    local reason = "shell outside .dev/standalone, port it to Lua (dev help porting)\n"
    testing.eq(assert(fs.read(stderr_path)), ".dev/x.sh: " .. reason .. ".dev/y.sh: " .. reason)
    fs.remove(root, { recursive = true })
end)

testing.test("with_files joins two file lists in order without changing either", function()
    local lua_files = { "a.lua", "b.lua" }
    local dev_files = { ".dev/c.lua" }
    testing.eq(lintset.with_files(lua_files, dev_files), { "a.lua", "b.lua", ".dev/c.lua" })
    testing.eq(lua_files, { "a.lua", "b.lua" })
    testing.eq(dev_files, { ".dev/c.lua" })
end)

testing.test("split_lua gives selene the .lua files and luau-analyze the .luau files", function()
    local lua, luau = lintset.split_lua({ "a.lua", "b.luau", "c.txt", ".ci/d.lua", "e/f.luau" })
    testing.eq(lua, { "a.lua", ".ci/d.lua" })
    testing.eq(luau, { "b.luau", "e/f.luau" })
end)

testing.test("stanza headers flags the unheaded stanza of a three-stanza function", function()
    local mixed = table.concat({
        "local function f()",
        "    -- Make a",
        "    local a = 1",
        "",
        "    run(a)",
        "",
        "    -- Check a",
        "    check(a)",
        "end",
        "",
    }, "\n")
    testing.eq(lintset.unheaded(mixed), { 5 })
    local root = support.tempdir()
    assert(fs.write(root .. "/mixed.luau", mixed))
    local lint = lint_for(root)
    local original = dev_command.note
    local notes = {}
    dev_command.note = function(text)
        notes[#notes + 1] = text
    end
    local ok, err = pcall(lint.stanza_headers, lint, "mixed.luau")
    dev_command.note = original
    assert(ok, err)
    testing.eq(lint.failed, { "stanza headers" })
    testing.eq(notes, { "mixed.luau:5: stanza with no intent comment above it, add one" })
    fs.remove(root, { recursive = true })
end)

testing.test("stanza headers passes a three-stanza function with every stanza headed", function()
    local headed = table.concat({
        "local function f()",
        "    -- Make a",
        "    local a = 1",
        "",
        "    -- Run a",
        "    run(a)",
        "",
        "    -- Check a",
        "    check(a)",
        "end",
        "",
    }, "\n")
    testing.eq(lintset.unheaded(headed), {})
    local two = "local function f()\n    a()\n\n    b()\nend\n"
    testing.eq(lintset.unheaded(two), {})
end)

testing.test("stanza headers judges a stanza under a multi-line signature by its body", function()
    local spread = table.concat({
        "local function f(",
        "    a: number,",
        "    b: number",
        "): number",
        "    -- Make a",
        "    local c = a + b",
        "",
        "    -- Return c",
        "    return c",
        "",
        "    -- Done",
        "    done()",
        "end",
        "",
    }, "\n")
    testing.eq(lintset.unheaded(spread), {})
    local paren = table.concat({
        "local function f(",
        "    a: number,",
        "    b: number",
        ")",
        "    -- Make a",
        "    local c = a + b",
        "",
        "    -- Check c",
        "    check(c)",
        "",
        "    run(c)",
        "end",
        "",
    }, "\n")
    testing.eq(lintset.unheaded(paren), { 11 })
end)

testing.test("analyze_findings drops a dev require and a dev type and keeps the rest", function()
    local out = table.concat({
        "a.luau(1,15): (W000) Unknown require: unsupported path",
        "a.luau(2,10): (W000) Unknown type 'dev.Card'",
        "a.luau(3,1): (W000) Unknown global 'nope'",
        "    seen near here",
        "",
        "a.luau(4,1): (W000) Unknown type 'Card'",
        "",
    }, "\n")
    testing.eq(lintset.analyze_findings(out), {
        "a.luau(3,1): (W000) Unknown global 'nope'\n    seen near here",
        "a.luau(4,1): (W000) Unknown type 'Card'",
    })
end)

local function analyze_with(output: string): ({ string }, { string })
    local root = support.tempdir()
    local lint = lint_for(root)
    local which, capture, say, note =
        dev_os.which, dev_os.capture, dev_command.say, dev_command.note
    local notes: { string } = {}
    dev_os.which = function()
        return true
    end
    dev_os.capture = function()
        return output, 1
    end
    dev_command.say = function() end
    dev_command.note = function(text)
        notes[#notes + 1] = text
    end
    local ok, err = pcall(lint.luau_analyze, lint, { "a.luau" })
    dev_os.which, dev_os.capture, dev_command.say, dev_command.note = which, capture, say, note
    fs.remove(root, { recursive = true })
    assert(ok, err)
    return lint.failed, notes
end

testing.test(
    "luau_analyze passes a stub analyzer that reports only an unresolved @dev require",
    function()
        local failed, notes =
            analyze_with("a.luau(1,15): (W000) Unknown require: unsupported path\n")
        testing.eq(failed, {})
        testing.eq(notes, {})
    end
)

testing.test("luau_analyze fails a stub analyzer that reports a real finding", function()
    local failed = analyze_with(
        "a.luau(1,15): (W000) Unknown require: unsupported path\n"
            .. "a.luau(2,1): (W000) Unknown global 'nope'\n"
    )
    testing.eq(failed, { "luau-analyze" })
end)
