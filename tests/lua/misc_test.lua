local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local function executable(path, text)
    assert(fs.write(path, text))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function lines(text)
    local out = {}
    for line in text:gmatch("([^\n]*)\n") do
        out[#out + 1] = line
    end
    return out
end

testing.test(
    "guide passes the topics and the question as one argument from the project root",
    function()
        local root = support.sandbox({}, {})
        assert(fs.mkdir(root .. "/.dev/topics", { parents = true }))
        executable(root .. "/bin/guide", '#!/bin/sh\nprintf "%s\\n" "$@"\npwd -P\n')
        local out, code = support.dev(
            root,
            { "guide", "-x", "how do  I" },
            { cwd = root .. "/.dev" }
        )
        testing.eq(code, 0)
        testing.eq(
            lines(out),
            { "dev", "--context-dir", root .. "/.dev/topics", "--", "-x how do  I", root }
        )
        fs.remove(root .. "/.dev/topics", { recursive = true })
        out = support.dev(root, { "guide", "a question" })
        testing.eq(lines(out), { "dev", "--", "a question", root })
        fs.remove(root, { recursive = true })
    end
)

testing.test("guide says how to install guide when it is missing", function()
    local root = support.sandbox({}, {})
    local luajit = assert(dev_os.which("luajit"), "luajit is needed")
    assert(fs.symlink(luajit, root .. "/bin/luajit"))
    local out, code = support.dev(
        root,
        { "guide", "q" },
        { env = { PATH = root .. "/bin:/usr/bin:/bin" } }
    )
    testing.eq(code, 1)
    testing.eq(out, "WARNING: guide not found. Install with: dev install guide\n")
    fs.remove(root, { recursive = true })
end)

testing.test("deploy says there is no built-in and exits 1", function()
    local root = support.sandbox({}, {})
    local out, code = support.dev(root, { "deploy" })
    testing.eq(code, 1)
    testing.eq(out, "dev: deploy has no built-in, add .dev/deploy.sh\n")
    fs.remove(root, { recursive = true })
end)

testing.test(
    "bootstrap runs bootstrap.sh from the dotfiles clone with VERBOSE and without dev's flags",
    function()
        local root = support.sandbox({}, {})
        local clone = assert(fs.realpath(support.tempdir()))
        executable(
            clone .. "/bootstrap.sh",
            '#!/bin/sh\necho "args: $*"\necho "verbose: ${VERBOSE:-unset}"\npwd -P\n'
        )
        local env = { DOTFILES = clone }
        local out, code = support.dev(root, { "-v", "bootstrap", "--no-login" }, { env = env })
        testing.eq(code, 0)
        testing.eq(lines(out), { "args: --no-login", "verbose: 1", clone })
        out = support.dev(root, { "bootstrap", "-v", "--", "--no-login" }, { env = env })
        testing.eq(lines(out), { "args: --no-login", "verbose: 1", clone })
        out = support.dev(root, { "bootstrap", "--dry-run" }, { env = env })
        testing.eq(lines(out), { "args: --dry-run", "verbose: unset", clone })
        fs.remove(root, { recursive = true })
        fs.remove(clone, { recursive = true })
    end
)
