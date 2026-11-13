local testing = require("dev.testing")
local dev_os = require("dev.os")
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
    local out, code = dev_os.capture(argv, { stderr = "null", env = IDENT })
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
    must(dev_os.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, { stdout = "null" }))
    must(
        dev_os.run({ "jj", "git", "init", root }, { stdout = "null", stderr = "null", env = IDENT })
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

local function trunk_commit(root)
    return jj(root, "log", "-r", "master@origin", "--no-graph", "-T", "commit_id")
end

local function land_note(root, home, id, commit)
    must(dev(root, home, {
        "board",
        "note",
        id,
        "Landed commit " .. commit .. " (change abc) on trunk, run by x.",
    }))
end

local function push_commit(root, name)
    assert(fs.write(root .. "/" .. name .. ".txt", name .. "\n"), "write failed")
    jj(root, "commit", "-m", name)
    jj(root, "bookmark", "set", "master", "-r", "@-")
    jj(root, "git", "push", "--remote", "origin", "--bookmark", "master")
    return trunk_commit(root)
end

local function release_card(root, home, name, outcomes, landed)
    local argv = { "board", "add", name, "--problem", "x", "--size", "1" }
    for _, outcome in ipairs(outcomes) do
        argv[#argv + 1] = "--done-when"
        argv[#argv + 1] = outcome
    end
    local out = dev(root, home, argv)
    local id = assert(out:match("added (%x+)"), out)
    must(dev(root, home, { "board", "move", id, support.COLUMN.RELEASE }))
    if landed ~= false then
        land_note(root, home, id, landed or trunk_commit(root))
    end
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

local function label_owner_hold(home, id)
    local file = home .. "/state/dev/boards/" .. BOARD .. ".json"
    local doc = assert(json.decode(assert(fs.read(file), "read failed")), "decode failed")
    for _, card in ipairs(doc.cards) do
        if card.id:sub(1, #id) == id then
            card.labels = card.labels or {}
            card.labels[#card.labels + 1] = "needs:human"
            return assert(fs.write(file, assert(json.encode(doc), "encode failed")))
        end
    end
    error("no card " .. id)
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

if dev_os.which("jj") then
    testing.test("ship moves every release card with ticked outcomes to Done", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local first = release_card(root, home, "First", { "It works" })
        local second = release_card(root, home, "Second", { "It works" })
        local open = release_card(root, home, "Open", { "It works", "It ships" })
        tick(root, home, first)
        tick(root, home, second)
        tick(root, home, open)
        local trunk = trunk_commit(root)
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

    local function follow_script(root)
        local script = root .. "/.dev/follow.sh"
        assert(fs.write(script, '#!/bin/sh\necho "followed $PWD"\n'), "write failed")
        must(dev_os.run({ "chmod", "755", script }))
    end

    testing.test("ship.runs.the.project.follow.script.after.a.passing.ship", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        follow_script(root)
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.ok(out:find("followed " .. root, 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
    end)

    testing.test("ship.moves.a.clean.main.checkout.onto.trunk", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        local remote = jj(root, "git", "remote", "list"):match("^origin (%S+)")
        local parent = assert(fs.realpath(support.tempdir()))
        local other = parent .. "/other"
        must(dev_os.run({ "git", "clone", "-q", remote, other }, { stdout = "null" }))
        assert(fs.write(other .. "/later.txt", "later\n"), "write failed")
        local function git(...)
            local argv = { "git", "-C", other, "-c", "user.name=t", "-c", "user.email=t@t", ... }
            must(dev_os.run(argv, { stdout = "null", stderr = "null" }))
        end
        git("add", "later.txt")
        git("commit", "-q", "-m", "later")
        git("push", "-q", "origin", "master")
        local trunk = dev_os.capture({ "git", "-C", other, "rev-parse", "HEAD" }):gsub("\n$", "")
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.ok(out:find(root .. " is on trunk " .. trunk:sub(1, 12), 1, true), out)
        testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), trunk)
    end)

    testing.test("ship.skips.follow.when.a.release.row.fails", function()
        local root, home = project('\n[board.release]\nchecks = ["false"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        follow_script(root)
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 1, out)
        testing.eq(out:find("followed", 1, true), nil, out)
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

    testing.test("ship writes no note for a refused move", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        label_owner_hold(home, id)
        for _ = 1, 2 do
            local out, code = dev(root, home, { "board", "ship" })
            testing.eq(code, 1, out)
            testing.ok(out:find("waits on the owner", 1, true), out)
            testing.ok(out:find("left in Release", 1, true), out)
            testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
            testing.eq(#done_notes(select(2, state(home, id))), 0)
        end
    end)

    testing.test("a ship rerun after a refused move writes one note", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        label_owner_hold(home, id)
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 1, out)
        must(dev(root, home, { "board", "label", id, "--remove", "needs:human" }))
        out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
        testing.eq(#done_notes(select(2, state(home, id))), 1)
    end)

    testing.test("ship leaves a card landed after the rev in release", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local early = release_card(root, home, "Early", { "It works" })
        local pinned = trunk_commit(root)
        local late = release_card(root, home, "Late", { "It works" }, push_commit(root, "later"))
        tick(root, home, early)
        tick(root, home, late)
        local out, code = dev(root, home, { "board", "ship", "--rev", pinned })
        testing.eq(code, 0, out)
        testing.eq((state(home, early)), support.COLUMN_NAME.DONE)
        local notes = done_notes(select(2, state(home, early)))
        testing.eq(#notes, 1)
        testing.ok(notes[1]:find(pinned:sub(1, 12), 1, true), notes[1])
        testing.eq((state(home, late)), support.COLUMN_NAME.RELEASE)
        testing.ok(out:find("left in Release", 1, true), out)
        testing.ok(out:find(late:sub(1, 4), 1, true), out)
        testing.ok(out:find("is not in", 1, true), out)
        testing.eq(#done_notes(select(2, state(home, late))), 0)
    end)

    testing.test("ship reads a pomb land note and moves the card", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "Pomb", { "It works" }, false)
        must(
            dev(
                root,
                home,
                { "board", "note", id, "landed " .. trunk_commit(root) .. " on origin/main" }
            )
        )
        tick(root, home, id)
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
    end)

    testing.test("ship reads the newest land note", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local pinned = trunk_commit(root)
        local id = release_card(root, home, "Twice", { "It works" }, push_commit(root, "later"))
        land_note(root, home, id, pinned)
        tick(root, home, id)
        local out, code = dev(root, home, { "board", "ship", "--rev", pinned })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
    end)

    testing.test("ship leaves a card with no landed commit in release and says why", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "Bare", { "It works" }, false)
        tick(root, home, id)
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
        testing.ok(out:find("no landed commit", 1, true), out)
    end)

    testing.test("ship names an unticked outcome as the reason", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "Open", { "It works" })
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.ok(out:find("outcome is not ticked", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship takes --rev with a command", function()
        local root, home = project()
        must(dev(root, home, { "board", "init" }))
        local pinned = trunk_commit(root)
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        local out, code = dev(root, home, { "board", "ship", "--rev", pinned, "--", "true" })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
    end)

    testing.test("ship with --rev and a bare -- refuses", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local out, code = dev(root, home, { "board", "ship", "--rev", "master@origin", "--" })
        testing.eq(code, 2, out)
        testing.ok(out:find("needs a command after --", 1, true), out)
    end)

    testing.test("ship with an unreadable rev moves no card", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        local out, code = dev(root, home, { "board", "ship", "--rev", "nosuchrev" })
        testing.eq(code, 1, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)
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

local function git_head(root)
    return (dev_os.capture({ "git", "-C", root, "rev-parse", "HEAD" }):gsub("\n$", ""))
end

local function git_project()
    local root = support.sandbox({
        [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "'
            .. BOARD
            .. '"\n[board.release]\nchecks = ["true"]\n',
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    assert(fs.write(home .. "/.config/dev/config.toml", ""), "write failed")
    local bare = assert(fs.realpath(support.tempdir()))
    must(dev_os.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, { stdout = "null" }))
    must(dev_os.run({ "git", "init", "-q", "-b", "master", root }, { stdout = "null" }))
    git(root, "remote", "add", "origin", bare)
    assert(fs.write(root .. "/seed.txt", "seed\n"), "write failed")
    git(root, "add", "seed.txt")
    git(root, "commit", "-q", "-m", "base")
    git(root, "push", "-q", "origin", "master")
    return root, home
end

local function git_push_commit(root, name)
    assert(fs.write(root .. "/" .. name .. ".txt", name .. "\n"), "write failed")
    git(root, "add", name .. ".txt")
    git(root, "commit", "-q", "-m", name)
    git(root, "push", "-q", "origin", "master")
    return git_head(root)
end

local function git_release_card(root, home, name, landed)
    local out = dev(
        root,
        home,
        { "board", "add", name, "--problem", "x", "--size", "1", "--done-when", "It works" }
    )
    local id = assert(out:match("added (%x+)"), out)
    must(dev(root, home, { "board", "move", id, support.COLUMN.RELEASE }))
    land_note(root, home, id, landed)
    tick(root, home, id)
    return id
end

testing.test("ship.in.a.git.project.moves.a.card.landed.in.trunk", function()
    local root, home = git_project()
    must(dev(root, home, { "board", "init" }))
    local id = git_release_card(root, home, "First", git_head(root))
    local trunk = git_head(root)
    local out, code = dev(root, home, { "board", "ship" })
    testing.eq(code, 0, out)
    testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
    local notes = done_notes(select(2, state(home, id)))
    testing.eq(#notes, 1)
    testing.ok(notes[1]:find(trunk:sub(1, 12), 1, true), notes[1])
    testing.ok(out:find("shipped 1 card", 1, true), out)
end)

testing.test("ship.in.a.git.project.leaves.a.card.landed.after.the.rev", function()
    local root, home = git_project()
    must(dev(root, home, { "board", "init" }))
    local pinned = git_head(root)
    local early = git_release_card(root, home, "Early", pinned)
    local late = git_release_card(root, home, "Late", git_push_commit(root, "later"))
    local out, code = dev(root, home, { "board", "ship", "--rev", pinned })
    testing.eq(code, 0, out)
    testing.eq((state(home, early)), support.COLUMN_NAME.DONE)
    testing.eq((state(home, late)), support.COLUMN_NAME.RELEASE)
    testing.ok(out:find("is not in", 1, true), out)
    testing.eq(#done_notes(select(2, state(home, late))), 0)
end)
