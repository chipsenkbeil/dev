local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local IDENT = support.GIT_IDENT
local git = support.git
local rev = support.rev

local function project()
    local root = support.sandbox({ [".dev/config.toml"] = "" }, {})
    local bare = support.tempdir()
    local bare_code = dev_os.run(
        { "git", "init", "--bare", "-q", "-b", "master", bare },
        { stdout = "null" }
    )
    assert(bare_code == 0, "git init --bare failed")
    local root_code = dev_os.run({ "git", "init", "-q", "-b", "master", root }, { stdout = "null" })
    assert(root_code == 0, "git init failed")
    git(root, "remote", "add", "origin", bare)
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "base")
    git(root, "push", "-q", "origin", "master")
    git(root, "checkout", "-q", "-b", "work")
    assert(fs.write(root .. "/work.txt", "one\n"), "write failed")
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "feat: work")
    return root, bare
end

testing.test("land.plain.lands a change in a project with no board", function()
    local root, bare = project()
    local out, code = support.dev(root, { "land" }, { env = IDENT })
    testing.eq(code, 0, out)
    testing.eq(rev(bare, "refs/heads/master"), rev(root, "HEAD"))
end)

testing.test("land.plain.refuses a card flag when there is no board", function()
    local root, bare = project()
    local trunk = rev(bare, "refs/heads/master")
    local out, code = support.dev(root, { "land", "--card", "abcdef12" }, { env = IDENT })
    testing.eq(code, 2, out)
    testing.eq(rev(bare, "refs/heads/master"), trunk)
end)
