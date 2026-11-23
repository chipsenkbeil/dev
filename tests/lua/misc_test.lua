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

testing.test("deploy is an unknown command without a script", function()
    local root = support.sandbox({}, {})
    local out, code = support.dev(root, { "deploy" })
    testing.eq(code, 2)
    testing.ok(out:find("dev: unknown command deploy\n", 1, true), out)
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
