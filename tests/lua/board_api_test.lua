local testing = require("dev.testing")
local board = require("dev.board")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local scm = require("dev.scm")
local support = require("support")

local BOARD = "mine"

local LAND_SCRIPT = [=[
local ctx = ...
local board = require("dev.board")
local scm = require("dev.scm")

local workspace = scm.workspace(ctx.root)
local found = assert(board.find(workspace))
local card = assert(found:find_card(ctx.args[1]))
assert(workspace:rebase() ~= nil)
assert(workspace:merge_into_trunk())
assert(card[ctx.args[2]](card))
print("landed " .. found:release_column() .. " " .. found:done_column())
]=]

local function must(first, second)
    local code = type(first) == "number" and first or second
    assert(code == 0, tostring(first))
end

local function git(root, ...)
    local argv = {
        "git",
        "-C",
        root,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.com",
        "-c",
        "commit.gpgsign=false",
        ...,
    }
    must(dev_os.run(argv, { stdout = "null", stderr = "null" }))
end

local function project()
    local root = support.sandbox({
        [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "' .. BOARD .. '"\n',
        [".dev/apiland.lua"] = LAND_SCRIPT,
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    assert(fs.write(home .. "/.config/dev/config.toml", ""), "write failed")
    local bare = assert(fs.realpath(support.tempdir()))
    must(dev_os.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, { stdout = "null" }))
    must(dev_os.run({ "git", "init", "-q", "-b", "master", root }, { stdout = "null" }))
    git(root, "remote", "add", "origin", bare)
    assert(fs.write(root .. "/seed.txt", "seed\n"), "write failed")
    git(root, "add", "seed.txt", ".dev")
    git(root, "commit", "-q", "-m", "base")
    git(root, "push", "-q", "origin", "master")
    return root, home, bare
end

local function dev(root, home, args)
    return support.dev(root, args, {
        env = {
            HOME = home,
            XDG_STATE_HOME = home .. "/state",
            DEV_AGENT = "dotfiles/lander",
            DEV_SELF = dev_os.capture({ "pwd" }):gsub("\n$", "") .. "/dotfiles/bin/.local/bin/dev",
        },
    })
end

local function card(root, home, start)
    local out = dev(root, home, {
        "board",
        "add",
        "First",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
        "--column",
        start,
        "--done-when",
        "It works",
    })
    local id = assert(out:match("added (%x+)"), out)
    must(dev(root, home, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
    return id
end

local function column_of(home, id)
    local doc = assert(
        json.decode(
            assert(fs.read(home .. "/state/dev/boards/" .. BOARD .. ".json"), "read failed")
        ),
        "decode failed"
    )
    for _, listed in ipairs(doc.cards) do
        if listed.id:sub(1, #id) == id then
            for _, column in ipairs(doc.columns) do
                if column.id == listed.column_id then
                    return column.name
                end
            end
        end
    end
end

local function land_by_script(method, start)
    local root, home, bare = project()
    must(dev(root, home, { "board", "init" }))
    local id = card(root, home, start)
    assert(fs.write(root .. "/work.txt", "work\n"), "write failed")
    git(root, "add", "work.txt")
    git(root, "commit", "-q", "-m", "feat: work")
    local out, code = dev(root, home, { "apiland", id, method })
    testing.eq(code, 0, out)
    local remote = dev_os.capture({ "git", "-C", bare, "rev-parse", "master" })
    local head = dev_os.capture({ "git", "-C", root, "rev-parse", "HEAD" })
    testing.eq(remote, head)
    return column_of(home, id), out
end

testing.test("a script lands a card by calling only dev.scm and dev.board", function()
    local column, out = land_by_script("move_to_done", support.Column.RELEASE)
    testing.eq(column, support.COLUMN_NAME.DONE)
    local names = support.COLUMN_NAME.RELEASE .. " " .. support.COLUMN_NAME.DONE
    testing.ok(out:find("landed " .. names, 1, true), out)
end)

testing.test("a card found by the board api moves to the release column", function()
    local column = land_by_script("move_to_release", support.Column.VERIFY)
    testing.eq(column, support.COLUMN_NAME.RELEASE)
end)

testing.test("board.find names a project with no board", function()
    local root = support.sandbox({ [".dev/config.toml"] = "" }, {})
    local found, message = board.find(scm.workspace(root))
    testing.eq(found, nil)
    testing.ok(message:find("no `[board]` section", 1, true), tostring(message))
end)
