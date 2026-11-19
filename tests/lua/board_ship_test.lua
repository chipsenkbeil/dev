local testing = require("dev.testing")
local board = require("dev.board")
local cmd_board = require("dev.cmd.board")
local dev_os = require("dev.os")
local localboard = require("dev.board.localboard")
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
            GIT_AUTHOR_NAME = "t",
            GIT_AUTHOR_EMAIL = "t@example.com",
            GIT_COMMITTER_NAME = "t",
            GIT_COMMITTER_EMAIL = "t@example.com",
        },
    })
end

local READY_OUTCOMES = {
    "It works (reviewer judgement)",
    "It reads well (reviewer judgement)",
    "It is documented (reviewer judgement)",
}
local READY_CHECKS = "dev --remote lint"

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
    local argv = {
        "board",
        "add",
        name,
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
    }
    for _, outcome in ipairs(outcomes) do
        argv[#argv + 1] = "--done-when"
        argv[#argv + 1] = outcome
    end
    local out = dev(root, home, argv)
    local id = assert(out:match("added (%x+)"), out)
    support.place(support.board_file(home, BOARD), id, support.COLUMN_NAME.RELEASE)
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
        json.decode(assert(fs.read(support.board_file(home, BOARD)), "read failed")),
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
    local file = support.board_file(home, BOARD)
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

    testing.test("ship lists a card moved with no done note and exits 1", function()
        local root, home = project()
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        local backend = localboard.new({
            name = BOARD,
            path = support.board_file(home, BOARD),
            private = true,
        })
        backend.root = root
        backend.stages = board.stages(nil, {})
        backend.note = function()
            return nil, "the board refused the note"
        end
        local result = cmd_board.run("ship", { "--", "true" }, backend)
        testing.eq(result.code, 1, result.message)
        testing.ok(
            result.message:find("moved to Done with no done note, write it by hand:", 1, true),
            result.message
        )
        testing.ok(
            result.message:find(
                id:sub(1, board.MIN_PREFIX) .. " First (the board refused the note)",
                1,
                true
            ),
            result.message
        )
        local column, comments = state(home, id)
        testing.eq(column, support.COLUMN_NAME.DONE)
        testing.eq(#done_notes(comments), 0)
    end)

    local function push_file(root, path, text)
        local dir = fs.dirname(root .. "/" .. path)
        assert(fs.mkdir(dir, { parents = true }), "mkdir failed")
        assert(fs.write(root .. "/" .. path, text or "changed\n"), "write failed")
        jj(root, "commit", "-m", "touch " .. path)
        jj(root, "bookmark", "set", "master", "-r", "@-")
        jj(root, "git", "push", "--remote", "origin", "--bookmark", "master")
        return trunk_commit(root)
    end

    local function ship_template_run(path)
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" }, push_file(root, path))
        tick(root, home, id)
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        return out
    end

    testing.test("ship.names.a.changed.lint.template", function()
        local path = "dotfiles/claude/.claude/skills/style/lint/lua/stylua.toml"
        local out = ship_template_run(path)
        testing.ok(out:find("The dev sync templates changed.", 1, true), out)
        testing.ok(out:find(path, 1, true), out)
        testing.ok(out:find("Synced repos run dev sync", 1, true), out)
        local lib = "dotfiles/claude/.claude/skills/style/lintset.lua"
        testing.ok(ship_template_run(lib):find(lib, 1, true))
    end)

    testing.test("ship.names.a.changed.readme.guide.template", function()
        local path = "dotfiles/bin/.local/share/dev/init/README.md"
        local out = ship_template_run(path)
        testing.ok(out:find("The dev sync templates changed.", 1, true), out)
        testing.ok(out:find(path, 1, true), out)
    end)

    testing.test("ship.prints.no.template.line.when.none.changed", function()
        local out = ship_template_run("docs/other.md")
        testing.ok(not out:find("The dev sync templates changed.", 1, true), out)
    end)

    testing.test("ship runs the release command with DEV_CI_PRIORITY set to 1", function()
        local dir = support.tempdir()
        local mark = dir .. "/priority"
        local script = dir .. "/prio.sh"
        local body = table.concat({
            "#!/bin/sh",
            'printf %s "$DEV_CI_PRIORITY" >"' .. mark .. '"',
            "",
        }, "\n")
        assert(fs.write(script, body))
        must(dev_os.run({ "chmod", "755", script }))
        local root, home = project('\n[board.release]\nchecks = ["' .. script .. '"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.eq(fs.read(mark), "1")
    end)

    local function follow_script(root)
        local script = root .. "/.dev/follow.sh"
        assert(fs.write(script, '#!/bin/sh\necho "followed $PWD"\n'), "write failed")
        must(dev_os.run({ "chmod", "755", script }))
    end

    local function trunk_workspace(root)
        local dir = assert(fs.realpath(support.tempdir())) .. "/ship"
        jj(root, "workspace", "add", "-r", "master@origin", dir)
        return dir
    end

    testing.test("ship.runs.the.project.follow.script.after.a.passing.ship", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        follow_script(root)
        local out, code = dev(trunk_workspace(root), home, { "board", "ship" })
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
        jj(root, "git", "fetch")
        local out, code = dev(trunk_workspace(root), home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.ok(out:find(root .. " is on trunk " .. trunk:sub(1, 12), 1, true), out)
        testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), trunk)
    end)

    testing.test("ship.with.no.rev.stays.on.the.tested.commit.when.trunk.moves", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        local tested = trunk_commit(root)
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
        local push = "git -C " .. dev_os.quote(other) .. " push -q origin master"
        local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", push })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
        testing.ok(out:find(root .. " is on " .. tested:sub(1, 12), 1, true), out)
        testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), tested)
        testing.eq(fs.exists(root .. "/later.txt"), false)
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
        testing.ok(out:find("No card moved", 1, true), out)
        testing.ok(out:find("false", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
        testing.eq(#done_notes(select(2, state(home, id))), 0)
    end)

    local function red_ship(failing, landed)
        local root, home = project()
        must(dev(root, home, { "board", "init" }))
        local pushed = {}
        for _, card in ipairs(landed) do
            if card.name then
                local id = release_card(
                    root,
                    home,
                    card.name,
                    { "It works" },
                    push_file(root, card.path, card.text)
                )
                tick(root, home, id)
                pushed[#pushed + 1] = id
            else
                push_file(root, card.path, card.text)
            end
        end
        local echo = "echo " .. (failing and "FAIL " .. failing or "no failure line") .. "; exit 1"
        local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
        testing.eq(code, 1, out)
        testing.ok(out:find("No card moved", 1, true), out)
        for _, id in ipairs(pushed) do
            testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
        end
        return out
    end

    testing.test("ship.names.the.landed.card.that.touched.a.failing.test", function()
        local out = red_ship("tests/lua/x_test.lua", {
            { name = "Touched", path = "tests/lua/x_test.lua" },
            { name = "Bystander", path = "docs/other.md" },
        })
        testing.ok(out:find("Suspects among the landed cards:", 1, true), out)
        testing.ok(out:find("tests/lua/x_test.lua:\n", 1, true), out)
        testing.ok(out:find("Touched", 1, true), out)
        testing.eq(out:find("Bystander", 1, true), nil)
    end)

    testing.test("ship.says.no.landed.card.touched.a.failing.test", function()
        local out = red_ship("tests/lua/y_test.lua", {
            { name = "Bystander", path = "docs/other.md" },
        })
        testing.ok(
            out:find("tests/lua/y_test.lua: no landed card in this batch touched it", 1, true),
            out
        )
        testing.eq(out:find("Bystander", 1, true), nil)
    end)

    testing.test("ship.names.the.card.that.touched.code.a.failing.test.loads", function()
        local module = "dotfiles/bin/.local/share/dev/lua/dev/zmod.lua"
        local out = red_ship("tests/lua/z_test.lua", {
            { path = "tests/lua/z_test.lua", text = 'require("dev.zmod")\n' },
            { name = "Loaded", path = module },
            { name = "Bystander", path = "docs/other.md" },
        })
        testing.ok(out:find("tests/lua/z_test.lua:\n", 1, true), out)
        testing.ok(out:find("Loaded", 1, true), out)
        testing.eq(out:find("Bystander", 1, true), nil)
    end)

    testing.test(
        "ship.names.the.card.that.touched.code.a.failing.test.loads.through.a.chain",
        function()
            local lua = "dotfiles/bin/.local/share/dev/lua/dev/"
            local out = red_ship("tests/lua/c_test.lua", {
                { path = "tests/lua/c_test.lua", text = 'require("dev.mid")\n' },
                { path = lua .. "mid.lua", text = 'require("dev.leaf")\n' },
                { name = "Leafy", path = lua .. "leaf/init.lua" },
                { name = "Bystander", path = "docs/other.md" },
            })
            testing.ok(out:find("tests/lua/c_test.lua:\n", 1, true), out)
            testing.ok(out:find("Leafy", 1, true), out)
            testing.eq(out:find("Bystander", 1, true), nil)
        end
    )

    testing.test("ship.says.a.row.with.no.fail.line.names.no.suspect", function()
        local out = red_ship(nil, { { name = "Bystander", path = "docs/other.md" } })
        testing.ok(out:find("printed no FAIL line, so no suspect is named", 1, true), out)
    end)

    local RED_FILE = "tests/lua/x_test.lua"
    local REVERT_NOW = "\n[board.release]\nrevert_after = 0\n"

    local function red_card(extra)
        local root, home = project(extra)
        must(dev(root, home, { "board", "init" }))
        local landed = push_file(root, RED_FILE)
        local id = release_card(root, home, "Touched", READY_OUTCOMES, landed)
        must(dev(root, home, { "board", "checks", id, READY_CHECKS }))
        for n = 1, #READY_OUTCOMES do
            must(
                dev(
                    root,
                    home,
                    { "board", "outcome", id, "--tick", tostring(n), "--as", "verifier" }
                )
            )
        end
        return root, home, id
    end

    local function red_ship_again(root, home, case)
        local echo = "echo FAIL " .. RED_FILE .. "; exit 1"
        if case then
            echo = string.format(
                "echo '> %s'; echo 'not ok - %s'; echo 'FAIL %s'; exit 1",
                RED_FILE,
                case,
                RED_FILE
            )
        end
        return dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
    end

    local function red_bodies(home, id)
        local bodies = {}
        for _, comment in ipairs(select(2, state(home, id))) do
            if comment.body:find("^Ship went red") then
                bodies[#bodies + 1] = comment.body
            end
        end
        return bodies
    end

    local function red_notes(home, id)
        local count = 0
        for _, comment in ipairs(select(2, state(home, id))) do
            if comment.body:find("^Ship went red") then
                count = count + 1
            end
        end
        return count
    end

    testing.test("ship.notes.each.suspect.once.when.red", function()
        local root, home, id = red_card()
        local out, code = red_ship_again(root, home)
        testing.eq(code, 1, out)
        testing.ok(out:find("First red, so the card is noted.", 1, true), out)
        testing.eq(red_notes(home, id), 1)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship.keeps.a.suspect.red.within.revert.after", function()
        local root, home, id = red_card()
        red_ship_again(root, home)
        local out, code = red_ship_again(root, home)
        testing.eq(code, 1, out)
        testing.ok(out:find("Reverted after 3600", 1, true), out)
        testing.eq(red_notes(home, id), 1)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship.reverts.a.suspect.red.past.revert.after", function()
        local root, home, id = red_card(REVERT_NOW)
        red_ship_again(root, home)
        local out, code = red_ship_again(root, home)
        testing.eq(code, 1, out)
        testing.ok(out:find("The card is back in Ready.", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.READY)
        testing.ok(jj(root, "log", "-r", "@-", "--no-graph", "-T", "description"):find("Revert"))
        testing.eq(dev(root, home, { "board", "show", id }):find("[x]", 1, true), nil)
    end)

    testing.test("ship.leaves.a.suspect.red.on.a.different.case", function()
        local root, home, id = red_card(REVERT_NOW)
        red_ship_again(root, home, "first case")
        local out, code = red_ship_again(root, home, "other case")
        testing.eq(code, 1, out)
        testing.ok(out:find("First red, so the card is noted.", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
        local bodies = red_bodies(home, id)
        testing.eq(#bodies, 2)
        testing.ok(bodies[1]:find(" on first case with this card", 1, true), bodies[1])
        testing.ok(bodies[2]:find(" on other case with this card", 1, true), bodies[2])
    end)

    testing.test("ship.reverts.a.suspect.red.twice.on.the.same.case", function()
        local root, home, id = red_card(REVERT_NOW)
        red_ship_again(root, home, "same case")
        local out, code = red_ship_again(root, home, "same case")
        testing.eq(code, 1, out)
        testing.ok(out:find("The card is back in Ready.", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.READY)
    end)

    testing.test("ship.keys.a.red.by.its.file.when.no.case.is.printed", function()
        local root, home, id = red_card(REVERT_NOW)
        red_ship_again(root, home)
        local bodies = red_bodies(home, id)
        testing.ok(bodies[1]:find(" on " .. RED_FILE .. " with this card", 1, true), bodies[1])
        local out = red_ship_again(root, home)
        testing.ok(out:find("The card is back in Ready.", 1, true), out)
    end)

    testing.test("ship.starts.a.suspect.over.when.it.lands.again", function()
        local root, home, id = red_card(REVERT_NOW)
        red_ship_again(root, home)
        land_note(root, home, id, push_file(root, RED_FILE, "again\n"))
        local out, code = red_ship_again(root, home)
        testing.eq(code, 1, out)
        testing.ok(out:find("First red, so the card is noted.", 1, true), out)
        testing.eq(red_notes(home, id), 2)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship.leaves.a.suspect.whose.revert.conflicts", function()
        local root, home, id = red_card(REVERT_NOW)
        push_file(root, RED_FILE, "later\n")
        red_ship_again(root, home)
        local out, code = red_ship_again(root, home)
        testing.eq(code, 1, out)
        testing.ok(out:find("conflicts with later changes", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
        testing.eq(
            jj(root, "log", "-r", "@-", "--no-graph", "-T", "description"):find("Revert"),
            nil
        )
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
        testing.ok(out:find("Needs a command after --.", 1, true), out)
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
        jj(root, "new", pinned)
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
        testing.ok(out:find(root .. " is on " .. pinned:sub(1, 12), 1, true), out)
        testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), pinned)
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
        jj(root, "new", pinned)
        local out, code = dev(root, home, { "board", "ship", "--rev", pinned })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
    end)

    testing.test("ship refuses a working copy that differs from the rev", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        assert(fs.write(root .. "/extra.txt", "extra\n"), "write failed")
        local log = support.tempdir() .. "/ran"
        local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", "echo x >>" .. log })
        testing.eq(code, 1, out)
        testing.ok(out:find("working copy is not at", 1, true), out)
        testing.ok(not fs.exists(log), "the command ran")
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship refuses a working copy on an older trunk", function()
        local root, home = project('\n[board.release]\nchecks = ["true"]\n')
        must(dev(root, home, { "board", "init" }))
        local pinned = trunk_commit(root)
        local id = release_card(root, home, "Late", { "It works" }, push_commit(root, "later"))
        tick(root, home, id)
        jj(root, "new", pinned)
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 1, out)
        testing.ok(out:find("working copy is not at", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
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
        testing.ok(out:find("Needs a command after --.", 1, true), out)
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

local function git_project(revert_after)
    local root = support.sandbox({
        [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "'
            .. BOARD
            .. '"\n[board.release]\nchecks = ["true"]\n'
            .. (revert_after and "revert_after = " .. revert_after .. "\n" or ""),
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
    return root, home
end

local function git_push_commit(root, name)
    assert(fs.write(root .. "/" .. name .. ".txt", name .. "\n"), "write failed")
    git(root, "add", name .. ".txt")
    git(root, "commit", "-q", "-m", name)
    git(root, "push", "-q", "origin", "master")
    return git_head(root)
end

local function git_release_card(root, home, name, landed, outcomes)
    outcomes = outcomes or { "It works" }
    local argv = {
        "board",
        "add",
        name,
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
    }
    for _, outcome in ipairs(outcomes) do
        argv[#argv + 1] = "--done-when"
        argv[#argv + 1] = outcome
    end
    local out = dev(root, home, argv)
    local id = assert(out:match("added (%x+)"), out)
    support.place(support.board_file(home, BOARD), id, support.COLUMN_NAME.RELEASE)
    land_note(root, home, id, landed)
    for n = 1, #outcomes do
        must(dev(root, home, { "board", "outcome", id, "--tick", tostring(n), "--as", "verifier" }))
    end
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
    git(root, "checkout", "-q", "--detach", pinned)
    local out, code = dev(root, home, { "board", "ship", "--rev", pinned })
    testing.eq(code, 0, out)
    testing.eq((state(home, early)), support.COLUMN_NAME.DONE)
    testing.eq((state(home, late)), support.COLUMN_NAME.RELEASE)
    testing.ok(out:find("is not in", 1, true), out)
    testing.eq(#done_notes(select(2, state(home, late))), 0)
end)

testing.test("ship.reverts.a.suspect.in.a.git.project", function()
    local root, home = git_project(0)
    must(dev(root, home, { "board", "init" }))
    local landed = git_push_commit(root, "g_test")
    local id = git_release_card(root, home, "Touched", landed, READY_OUTCOMES)
    must(dev(root, home, { "board", "checks", id, READY_CHECKS }))
    local echo = "echo FAIL g_test.txt; exit 1"
    local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
    testing.eq(code, 1, out)
    testing.ok(out:find("First red, so the card is noted.", 1, true), out)
    out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
    testing.eq(code, 1, out)
    testing.ok(out:find("The card is back in Ready.", 1, true), out)
    testing.eq((state(home, id)), support.COLUMN_NAME.READY)
    local subject = dev_os.capture({ "git", "-C", root, "log", "-1", "--format=%s" })
    testing.ok(subject:find("Revert", 1, true), subject)
end)

testing.test("ship.leaves.a.suspect.whose.git.revert.conflicts", function()
    local root, home = git_project(0)
    must(dev(root, home, { "board", "init" }))
    local id = git_release_card(root, home, "Touched", git_push_commit(root, "g_test"))
    assert(fs.write(root .. "/g_test.txt", "later\n"), "write failed")
    git(root, "commit", "-q", "-am", "later edit")
    git(root, "push", "-q", "origin", "master")
    local echo = "echo FAIL g_test.txt; exit 1"
    dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
    local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
    testing.eq(code, 1, out)
    testing.ok(out:find("conflicts with later changes", 1, true), out)
    testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    testing.eq(dev_os.capture({ "git", "-C", root, "status", "--porcelain" }), "")
    local subject = dev_os.capture({ "git", "-C", root, "log", "-1", "--format=%s" })
    testing.eq(subject:find("Revert", 1, true), nil)
end)

testing.test("ship.reverts.suspects.newest.landed.first.by.short.commit.id", function()
    local root, home = git_project(0)
    must(dev(root, home, { "board", "init" }))
    local older = git_push_commit(root, "g_test")
    assert(fs.write(root .. "/g_test.txt", "g_test\nmore\n"), "write failed")
    git(root, "commit", "-q", "-am", "newer edit")
    git(root, "push", "-q", "origin", "master")
    local newer = git_head(root)
    local old_id = git_release_card(root, home, "Older", older:sub(1, 12), READY_OUTCOMES)
    local new_id = git_release_card(root, home, "Newer", newer:sub(1, 12), READY_OUTCOMES)
    must(dev(root, home, { "board", "checks", old_id, READY_CHECKS }))
    must(dev(root, home, { "board", "checks", new_id, READY_CHECKS }))
    local echo = "echo FAIL g_test.txt; exit 1"
    dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
    local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
    testing.eq(code, 1, out)
    testing.ok(state(home, new_id) == support.COLUMN_NAME.READY, out)
    testing.ok(state(home, old_id) == support.COLUMN_NAME.READY, out)
    testing.eq(out:find("conflicts with later changes", 1, true), nil)
end)

testing.test("ship.in.a.git.project.refuses.a.head.off.the.rev", function()
    local root, home = git_project()
    must(dev(root, home, { "board", "init" }))
    local pinned = git_head(root)
    local id = git_release_card(root, home, "Late", git_push_commit(root, "later"))
    git(root, "checkout", "-q", "--detach", pinned)
    local out, code = dev(root, home, { "board", "ship" })
    testing.eq(code, 1, out)
    testing.ok(out:find("working copy is not at", 1, true), out)
    testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
end)
