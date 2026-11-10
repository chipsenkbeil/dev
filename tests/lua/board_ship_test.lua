local testing = require("dev.testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local IDENT = { JJ_USER = "t", JJ_EMAIL = "t@example.com" }
local BOARD = "mine"

local function must(first, second)
    local code = type(first) == "number" and first or second
    assert(code == 0, tostring(first))
end

local function jj(root, ...)
    local argv = { "jj", "--no-pager", "--color", "never", "-R", root, ... }
    local out, code = devos.capture(argv, { stderr = "null", env = IDENT })
    assert(code == 0, out)
    return out
end

local function project(extra)
    local root = support.sandbox({
        [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "'
            .. BOARD
            .. '"\n'
            .. (extra or ""),
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    assert(fs.write(home .. "/.config/dev/config.toml", ""), "write failed")
    local bare = support.tempdir()
    must(devos.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, { stdout = "null" }))
    must(
        devos.run({ "jj", "git", "init", root }, { stdout = "null", stderr = "null", env = IDENT })
    )
    jj(root, "git", "remote", "add", "origin", bare)
    assert(fs.write(root .. "/seed.txt", "seed\n"), "write failed")
    jj(root, "commit", "-m", "base")
    jj(root, "bookmark", "create", "master", "-r", "@-")
    jj(root, "git", "push", "--remote", "origin", "--bookmark", "master")
    return root, home
end

local function dev(root, home, args)
    return support.dev(root, args, {
        env = {
            HOME = home,
            XDG_STATE_HOME = home .. "/state",
            JJ_USER = "t",
            JJ_EMAIL = "t@example.com",
            DEV_AGENT = "dotfiles/shipper",
        },
    })
end

local function release_card(root, home, name, outcomes)
    local argv = { "board", "add", name, "--problem", "x", "--size", "1" }
    for _, outcome in ipairs(outcomes) do
        argv[#argv + 1] = "--done-when"
        argv[#argv + 1] = outcome
    end
    local out = dev(root, home, argv)
    local id = assert(out:match("added (%x+)"), out)
    must(dev(root, home, { "board", "move", id, support.COLUMN.RELEASE }))
    return id
end

local function tick(root, home, id)
    must(dev(root, home, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
end

local function state(home, id)
    local doc = assert(
        json.decode(
            assert(fs.read(home .. "/state/dev/boards/" .. BOARD .. ".json"), "read failed")
        ),
        "decode failed"
    )
    for _, card in ipairs(doc.cards) do
        if card.id:sub(1, #id) == id then
            for _, column in ipairs(doc.columns) do
                if column.id == card.column_id then
                    return column.name, card.comments or {}
                end
            end
        end
    end
end

local function done_notes(comments)
    local found = {}
    for _, comment in ipairs(comments) do
        if comment.kind == "done" then
            found[#found + 1] = comment.body
        end
    end
    return found
end

if devos.which("jj") then
    testing.test("ship moves every release card with ticked outcomes to Done", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local first = release_card(root, home, "First", { "It works" })
        local second = release_card(root, home, "Second", { "It works" })
        local open = release_card(root, home, "Open", { "It works", "It ships" })
        tick(root, home, first)
        tick(root, home, second)
        tick(root, home, open)
        local trunk = jj(root, "log", "-r", "master@origin", "--no-graph", "-T", "commit_id")
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        for _, id in ipairs({ first, second }) do
            local column, comments = state(home, id)
            testing.eq(column, support.COLUMN_NAME.DONE)
            local notes = done_notes(comments)
            testing.eq(#notes, 1)
            testing.ok(notes[1]:find(trunk:sub(1, 12), 1, true), notes[1])
        end
        testing.eq((state(home, open)), support.COLUMN_NAME.RELEASE)
        testing.ok(out:find("shipped 2 cards", 1, true), out)
        testing.ok(out:find("left in Release", 1, true), out)
        testing.ok(out:find(open:sub(1, 4), 1, true), out)
    end)

    testing.test("ship with a failing row moves no card and names the row", function()
        local root, home = project('\n[board.release]\nchecks = ["true", "false"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 1, out)
        testing.ok(out:find("no card moved", 1, true), out)
        testing.ok(out:find("false", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
        testing.eq(#done_notes(select(2, state(home, id))), 0)
    end)

    testing.test("ship with a command runs it once in place of the rows", function()
        local root, home = project('\n[board.release]\nchecks = ["false"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        local log = support.tempdir() .. "/ran"
        local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", "echo x >>" .. log })
        testing.eq(code, 0, out)
        testing.eq(fs.read(log), "x\n")
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
    end)

    testing.test("ship with neither a command nor rows refuses", function()
        local root, home = project()
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 2, out)
        testing.ok(out:find("[board.release]", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship with a bare -- refuses and does not run the rows", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        local out, code = dev(root, home, { "board", "ship", "--" })
        testing.eq(code, 2, out)
        testing.ok(out:find("needs a command after --", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)
end
