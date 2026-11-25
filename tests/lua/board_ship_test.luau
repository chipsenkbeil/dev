local testing = require("@dev/testing")
local board = require("@dev/board")
local revert = require("@dev/board/revert")
local cmd_board = require("@dev/cmd/board")
local dev_os = require("@dev/os")
local localboard = require("@dev/board/localboard")
local fs = require("@dev/fs")
local json = require("@dev/json")
local support = require("./support")

local IDENT = { JJ_USER = "t", JJ_EMAIL = "t@example.com" }
local BOARD = "mine"

local PASSING_RELEASE = table.concat({
    "",
    "[board.release]",
    'checks = ["true"]',
    "",
}, "\n")
local FAILING_RELEASE = table.concat({
    "",
    "[board.release]",
    'checks = ["false"]',
    "",
}, "\n")

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
    -- Sandbox the project with a local board config
    local config = table.concat({
        "[board]",
        'backend = "local"',
        'name = "' .. BOARD .. '"',
        "",
    }, "\n")
    local root = support.sandbox({
        [".dev/config.toml"] = config .. (extra or ""),
    }, {})

    -- Give the project an empty user config
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    assert(fs.write(home .. "/.config/dev/config.toml", ""), "write failed")

    -- Make the bare remote and a jj repo that points at it
    local bare = support.tempdir()
    must(dev_os.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, { stdout = "null" }))
    must(
        dev_os.run({ "jj", "git", "init", root }, { stdout = "null", stderr = "null", env = IDENT })
    )
    jj(root, "git", "remote", "add", "origin", bare)

    -- Push a seed commit as trunk
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
    -- Build the add command with one flag per outcome
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

    -- Add the card and read its id
    local out = dev(root, home, argv)
    local id = assert(out:match("added (%x+)"), out)

    -- Move the card into Release
    support.place(support.board_file(home, BOARD), id, support.COLUMN_NAME.RELEASE)

    -- Note the landing unless the card is meant to have none
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

local function red_notes(home, id)
    local count = 0
    for _, comment in ipairs(select(2, state(home, id))) do
        if comment.body:find("^Ship went red") then
            count = count + 1
        end
    end
    return count
end

local function label_owner_hold(home, id)
    local file = support.board_file(home, BOARD)
    local doc = assert(json.decode(assert(fs.read(file), "read failed")), "decode failed")
    for _, card in ipairs(doc.cards) do
        if card.id:sub(1, #id) == id then
            card.labels = card.labels or {}
            card.labels[#card.labels + 1] = "needs:human"
            return assert(fs.write(file, (assert(json.encode(doc), "encode failed"))))
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
        -- Start a project with a passing release row
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))

        -- Land three cards in Release and tick one outcome on each
        local first = release_card(root, home, "First", { "It works" })
        local second = release_card(root, home, "Second", { "It works" })
        local open = release_card(root, home, "Open", { "It works", "It ships" })
        tick(root, home, first)
        tick(root, home, second)
        tick(root, home, open)

        -- Ship the board
        local trunk = trunk_commit(root)
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)

        -- Check the finished cards moved to Done with one note naming trunk
        for _, id in ipairs({ first, second }) do
            local column, comments = state(home, id)
            testing.eq(column, support.COLUMN_NAME.DONE)
            local notes = done_notes(comments)
            testing.eq(#notes, 1)
            testing.ok(notes[1]:find(trunk:sub(1, 12), 1, true), notes[1])
        end

        -- Check the unfinished card stayed and the report names it
        testing.eq((state(home, open)), support.COLUMN_NAME.RELEASE)
        testing.ok(out:find("shipped 2 cards", 1, true), out)
        testing.ok(out:find("These cards stay in Release:", 1, true), out)
        testing.ok(out:find(open:sub(1, 4), 1, true), out)
    end)

    testing.test("ship lists a card moved with no done note and exits 1", function()
        -- Start a project with a ticked card in Release
        local root, home = project()
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)

        -- Wrap the board so that every note is refused
        local backend = localboard.new({
            name = BOARD,
            path = support.board_file(home, BOARD),
            private = true,
        })
        backend.root = root
        backend.stages = board.stages(nil, {})
        backend.note = function()
            return nil, "The board refused the note."
        end

        -- Ship through the wrapped board and read the report
        local result = cmd_board.run("ship", { "--", "true" }, backend)
        testing.eq(result.code, 1, result.message)
        testing.ok(
            result.message:find(
                "These cards moved to Done with no done note. Write each note by hand:",
                1,
                true
            ),
            result.message
        )
        testing.ok(
            result.message:find(
                id:sub(1, board.MIN_PREFIX) .. " First: The board refused the note.",
                1,
                true
            ),
            result.message
        )

        -- Check the card still moved to Done without a note
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

    local SYNC_TEMPLATES = table.concat({
        "",
        "[sync]",
        'templates = [ "dotfiles/claude/.claude/skills/style/lint",'
            .. ' "dotfiles/claude/.claude/skills/style/lintset.lua", "init/README.md"]',
        "",
    }, "\n")

    local function ship_template_run(path, sync)
        -- Start a project whose config may list sync templates
        local root, home = project(PASSING_RELEASE .. (sync == nil and SYNC_TEMPLATES or sync))
        must(dev(root, home, { "board", "init" }))

        -- Land a ticked card that touched the path
        local id = release_card(root, home, "First", { "It works" }, push_file(root, path))
        tick(root, home, id)

        -- Ship the board
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
        local path = "init/README.md"
        local out = ship_template_run(path)
        testing.ok(out:find("The dev sync templates changed.", 1, true), out)
        testing.ok(out:find(path, 1, true), out)
    end)

    testing.test("ship lists the templates sync.templates names", function()
        local sync = table.concat({
            "",
            "[sync]",
            'templates = ["docs/other.md"]',
            "",
        }, "\n")
        local out = ship_template_run("docs/other.md", sync)
        testing.ok(out:find("The dev sync templates changed.", 1, true), out)
        testing.ok(out:find("  docs/other.md", 1, true), out)
    end)

    testing.test("ship says nothing about templates without sync.templates", function()
        local out = ship_template_run("docs/other.md", "")
        testing.ok(not out:find("The dev sync templates changed.", 1, true), out)
        local lint = "dotfiles/claude/.claude/skills/style/lint/lua/stylua.toml"
        testing.ok(not ship_template_run(lint, ""):find("sync templates changed", 1, true))
    end)

    testing.test("ship.prints.no.template.line.when.none.changed", function()
        local out = ship_template_run("docs/other.md")
        testing.ok(not out:find("The dev sync templates changed.", 1, true), out)
    end)

    testing.test("ship runs the release command with DEV_CI_PRIORITY set to 1", function()
        -- Write a release check that records the priority variable
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

        -- Start a project whose release row runs that check
        local config = table.concat({
            "",
            "[board.release]",
            'checks = ["' .. script .. '"]',
            "",
        }, "\n")
        local root, home = project(config)
        must(dev(root, home, { "board", "init" }))

        -- Land a ticked card in Release
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)

        -- Ship the board and read what the check saw
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.eq(fs.read(mark), "1")
    end)

    local function follow_script(root)
        local script = root .. "/.dev/commands/follow.sh"
        assert(fs.mkdir(fs.dirname(script), { parents = true }))
        local body = table.concat({
            "#!/bin/sh",
            'echo "followed $PWD"',
            "",
        }, "\n")
        assert(fs.write(script, body), "write failed")
        must(dev_os.run({ "chmod", "755", script }))
    end

    local function trunk_workspace(root)
        local dir = assert(fs.realpath(support.tempdir())) .. "/ship"
        jj(root, "workspace", "add", "-r", "master@origin", dir)
        return dir
    end

    testing.test("ship.runs.the.project.follow.script.after.a.passing.ship", function()
        -- Start a project with a passing release row
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))

        -- Land a ticked card in Release and give the project a follow command
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        follow_script(root)

        -- Ship from a workspace on trunk
        local out, code = dev(trunk_workspace(root), home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.ok(out:find("followed " .. root, 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
    end)

    testing.test("ship.moves.a.clean.main.checkout.onto.trunk", function()
        -- Start a project with a ticked card in Release
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)

        -- Push a newer trunk commit from another clone
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

        -- Fetch it and ship from a workspace on the new trunk
        jj(root, "git", "fetch")
        local out, code = dev(trunk_workspace(root), home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.ok(out:find(root .. " is on trunk " .. trunk:sub(1, 12), 1, true), out)
        testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), trunk)
    end)

    testing.test("ship.with.no.rev.stays.on.the.tested.commit.when.trunk.moves", function()
        -- Start a project with a ticked card in Release
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        local tested = trunk_commit(root)

        -- Stage a newer commit in another clone
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

        -- Ship with a command that pushes the commit while the rows run
        local push = "git -C " .. dev_os.quote(other) .. " push -q origin master"
        local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", push })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)

        -- Check the checkout stayed on the tested commit
        testing.ok(out:find(root .. " is on " .. tested:sub(1, 12), 1, true), out)
        testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), tested)
        testing.eq(fs.exists(root .. "/later.txt"), false)
    end)

    testing.test("ship.skips.follow.when.a.release.row.fails", function()
        -- Start a project whose release row fails
        local root, home = project(FAILING_RELEASE)
        must(dev(root, home, { "board", "init" }))

        -- Land a ticked card in Release and give the project a follow command
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        follow_script(root)

        -- Ship the board
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 1, out)
        testing.eq(out:find("followed", 1, true), nil, out)
    end)

    testing.test("ship with a failing row moves no card and names the row", function()
        -- Start a project whose second release row fails
        local config = table.concat({
            "",
            "[board.release]",
            'checks = ["true", "false"]',
            "",
        }, "\n")
        local root, home = project(config)
        must(dev(root, home, { "board", "init" }))

        -- Land a ticked card in Release
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)

        -- Ship the board
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 1, out)
        testing.ok(out:find("No card moved", 1, true), out)
        testing.ok(out:find("false", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
        testing.eq(#done_notes(select(2, state(home, id))), 0)
    end)

    local SHIP_ROOTS = table.concat({
        "",
        "[board.ship]",
        'source_roots = ["lua/"]',
        "",
    }, "\n")

    local function red_ship(failing, landed, extra)
        -- Start a project that names its source roots
        local root, home = project(extra or SHIP_ROOTS)
        must(dev(root, home, { "board", "init" }))

        -- Land each change, as a ticked card when it has a name
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

        -- Ship with a command that fails and check no card moved
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
        local module = "lua/dev/zmod.lua"
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
            local lua = "lua/dev/"
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

    testing.test("ship.names.the.card.that.touched.a.file.the.failing.test.names", function()
        local out = red_ship("tests/lua/q_test.lua", {
            {
                path = "tests/lua/q_test.lua",
                text = table.concat(
                    { 'local a = "agents/q.md"', 'local b = "agents/missing.md"', "" },
                    "\n"
                ),
            },
            { name = "Quoted", path = "agents/q.md" },
            { name = "Bystander", path = "docs/other.md" },
        })
        testing.ok(out:find("tests/lua/q_test.lua:\n", 1, true), out)
        testing.ok(out:find("Quoted", 1, true), out)
        testing.eq(out:find("Bystander", 1, true), nil)
        testing.eq(out:find("missing", 1, true), nil)
    end)

    testing.test("ship.still.follows.requires.of.a.lua.file.the.failing.test.quotes", function()
        local lua = "lua/dev/"
        local out = red_ship("tests/lua/r_test.lua", {
            {
                path = "tests/lua/r_test.lua",
                text = table.concat(
                    { 'local a = "' .. lua .. 'mid.lua"', 'require("dev.mid")', "" },
                    "\n"
                ),
            },
            { path = lua .. "mid.lua", text = 'require("dev.leaf")\n' },
            { name = "Leafy", path = lua .. "leaf.lua" },
            { name = "Bystander", path = "docs/other.md" },
        })
        testing.ok(out:find("Leafy", 1, true), out)
        testing.eq(out:find("Bystander", 1, true), nil)
    end)

    testing.test("ship.suspects.follow.no.require.without.source_roots", function()
        local lua = "lua/dev/"
        local out = red_ship("tests/lua/n_test.lua", {
            { path = "tests/lua/n_test.lua", text = 'require("dev.zmod")\n' },
            { name = "Loaded", path = lua .. "zmod.lua" },
            { name = "Bystander", path = "docs/other.md" },
        }, "")
        testing.ok(out:find("tests/lua/n_test.lua: no landed card in this batch", 1, true), out)
        testing.eq(out:find("Loaded", 1, true), nil)
    end)

    testing.test("ship.says.a.row.with.no.fail.line.names.no.suspect", function()
        local out = red_ship(nil, { { name = "Bystander", path = "docs/other.md" } })
        testing.ok(out:find("printed no FAIL line, so no suspect is named", 1, true), out)
    end)

    local RED_FILE = "tests/lua/x_test.lua"
    local REVERT_NOW = table.concat({
        "",
        "[board.release]",
        "revert_after = 0",
        "",
    }, "\n")

    local function red_card(extra)
        -- Start a project with the given release config
        local root, home = project(extra)
        must(dev(root, home, { "board", "init" }))

        -- Land a change to the red file as a Release card
        local landed = push_file(root, RED_FILE)
        local id = release_card(root, home, "Touched", READY_OUTCOMES, landed)

        -- Give the card its checks and tick every outcome
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
        testing.ok(out:find("until it lands", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
        testing.ok(jj(root, "log", "-r", "@-", "--no-graph", "-T", "description"):find("Revert"))
    end)

    testing.test("ship.keeps.a.reverted.card.in.release.until.its.revert.lands", function()
        -- Revert a suspect that is red twice
        local root, home, id = red_card(REVERT_NOW)
        red_ship_again(root, home)
        red_ship_again(root, home)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
        testing.ok(dev(root, home, { "board", "show", id }):find("[x]", 1, true), "outcomes ticked")

        -- Ship again before the revert lands on trunk
        jj(root, "new", "master@origin")
        local out, code = dev(root, home, { "board", "ship", "--", "true" })
        testing.eq(code, 0, out)

        -- Check the card kept its place and its ticks
        testing.ok(out:find("has not landed", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
        testing.ok(dev(root, home, { "board", "show", id }):find("[x]", 1, true), "outcomes ticked")
    end)

    testing.test("ship.names.no.suspect.for.a.card.with.a.pending.revert", function()
        -- Revert a suspect that is red twice
        local root, home, id = red_card(REVERT_NOW)
        red_ship_again(root, home)
        red_ship_again(root, home)

        -- Ship red again before the revert lands on trunk
        jj(root, "new", "master@origin")
        local out, code = red_ship_again(root, home)
        testing.eq(code, 1, out)
        testing.eq(out:find("until it lands", 1, true), nil)

        -- Check the card got one revert note and kept its place
        local reverts = 0
        for _, comment in ipairs(select(2, state(home, id))) do
            if comment.body:find("^Reverted landed commit") then
                reverts = reverts + 1
            end
        end
        testing.eq(reverts, 1)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship.requeues.a.card.whose.revert.landed", function()
        -- Revert a suspect that is red twice
        local root, home, id = red_card(REVERT_NOW)
        red_ship_again(root, home)
        red_ship_again(root, home)

        -- Land the revert on trunk
        jj(root, "bookmark", "set", "master", "-r", "@-")
        jj(root, "git", "push", "--remote", "origin", "--bookmark", "master")

        -- Ship and check the card returned to Ready with its ticks cleared
        local out, code = dev(root, home, { "board", "ship", "--", "true" })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.READY)
        testing.eq(dev(root, home, { "board", "show", id }):find("[x]", 1, true), nil)
        testing.eq(#done_notes(select(2, state(home, id))), 0)
    end)

    testing.test("ship.leaves.a.suspect.red.on.a.different.case", function()
        -- Ship red on one case, then on another
        local root, home, id = red_card(REVERT_NOW)
        red_ship_again(root, home, "first case")
        local out, code = red_ship_again(root, home, "other case")

        -- Check the card is noted again and not reverted
        testing.eq(code, 1, out)
        testing.ok(out:find("First red, so the card is noted.", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)

        -- Check each note names its own case
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
        testing.ok(out:find("until it lands", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship.reverts.a.suspect.red.twice.on.a.case.name.with.a.semicolon", function()
        local root, home, id = red_card(REVERT_NOW)
        red_ship_again(root, home, "odd; case")
        local out, code = red_ship_again(root, home, "odd; case")
        testing.eq(code, 1, out)
        testing.ok(out:find("until it lands", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("red.text.round.trips.a.case.name.with.a.semicolon.and.a.space", function()
        local cases = { "a; b", "plain", "", "back\\slash", "end\\", " x", "x ", "", ";; \\; x" }
        local text = revert.red_text("abc1234", 100, cases)
        testing.eq(revert.red_cases(text), cases)
    end)

    testing.test("red.cases.reads.a.note.written.with.plain.case.names", function()
        local text = "Ship went red at commit abc1234 on first case; other case with this card "
            .. "a suspect (epoch 100)."
        testing.eq(revert.red_cases(text), { "first case", "other case" })
    end)

    testing.test("ship.keys.a.red.by.its.file.when.no.case.is.printed", function()
        local root, home, id = red_card(REVERT_NOW)
        red_ship_again(root, home)
        local bodies = red_bodies(home, id)
        testing.ok(bodies[1]:find(" on " .. RED_FILE .. " with this card", 1, true), bodies[1])
        local out = red_ship_again(root, home)
        testing.ok(out:find("until it lands", 1, true), out)
    end)

    testing.test("ship.starts.a.suspect.over.when.it.lands.again", function()
        -- Ship red once for a landed card
        local root, home, id = red_card(REVERT_NOW)
        red_ship_again(root, home)

        -- Land the card again with a newer commit
        land_note(root, home, id, push_file(root, RED_FILE, "again\n"))

        -- Ship red and check the card is noted as a first red
        local out, code = red_ship_again(root, home)
        testing.eq(code, 1, out)
        testing.ok(out:find("First red, so the card is noted.", 1, true), out)
        testing.eq(red_notes(home, id), 2)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship.leaves.a.suspect.whose.revert.conflicts", function()
        -- Change the red file again after the card landed
        local root, home, id = red_card(REVERT_NOW)
        push_file(root, RED_FILE, "later\n")

        -- Ship red twice
        red_ship_again(root, home)
        local out, code = red_ship_again(root, home)

        -- Check the conflict is reported and nothing was reverted
        testing.eq(code, 1, out)
        testing.ok(out:find("conflicts with later changes", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
        testing.eq(
            jj(root, "log", "-r", "@-", "--no-graph", "-T", "description"):find("Revert"),
            nil
        )
    end)

    testing.test("ship with a command runs it once in place of the rows", function()
        -- Start a project whose release row would fail
        local root, home = project(FAILING_RELEASE)
        must(dev(root, home, { "board", "init" }))

        -- Land a ticked card in Release
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)

        -- Ship with a command that logs each run
        local log = support.tempdir() .. "/ran"
        local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", "echo x >>" .. log })
        testing.eq(code, 0, out)
        testing.eq(fs.read(log), "x\n")
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
    end)

    testing.test("ship with neither a command nor rows refuses", function()
        -- Start a project with no release rows
        local root, home = project()
        must(dev(root, home, { "board", "init" }))

        -- Land a ticked card in Release
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)

        -- Ship the board
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 2, out)
        testing.ok(out:find("[board.release]", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship with a bare -- refuses and does not run the rows", function()
        -- Start a project with a passing release row
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))

        -- Land a ticked card in Release
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)

        -- Ship with a dash and no command
        local out, code = dev(root, home, { "board", "ship", "--" })
        testing.eq(code, 2, out)
        testing.ok(out:find("Needs a command after --.", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship writes no note for a refused move", function()
        -- Start a project with a passing release row
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))

        -- Land a ticked card in Release that waits on the owner
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        label_owner_hold(home, id)

        -- Ship twice and check each run refuses without a note
        for _ = 1, 2 do
            local out, code = dev(root, home, { "board", "ship" })
            testing.eq(code, 1, out)
            testing.ok(out:find("waits on the owner", 1, true), out)
            testing.ok(out:find("These cards stay in Release:", 1, true), out)
            testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
            testing.eq(#done_notes(select(2, state(home, id))), 0)
        end
    end)

    testing.test("a ship rerun after a refused move writes one note", function()
        -- Start a project with a passing release row
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))

        -- Land a ticked card in Release that waits on the owner
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)
        label_owner_hold(home, id)

        -- Ship once and see the move refused
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 1, out)

        -- Release the hold, ship again and check the card moved with one note
        must(dev(root, home, { "board", "label", id, "--remove", "needs:human" }))
        out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
        testing.eq(#done_notes(select(2, state(home, id))), 1)
    end)

    testing.test("ship leaves a card landed after the rev in release", function()
        -- Start a project with a passing release row
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))

        -- Land one card at the pinned commit and one after it
        local early = release_card(root, home, "Early", { "It works" })
        local pinned = trunk_commit(root)
        local late = release_card(root, home, "Late", { "It works" }, push_commit(root, "later"))
        tick(root, home, early)
        tick(root, home, late)

        -- Ship at the pinned commit
        jj(root, "new", pinned)
        local out, code = dev(root, home, { "board", "ship", "--rev", pinned })
        testing.eq(code, 0, out)

        -- Check the early card moved with a note naming the pinned commit
        testing.eq((state(home, early)), support.COLUMN_NAME.DONE)
        local notes = done_notes(select(2, state(home, early)))
        testing.eq(#notes, 1)
        testing.ok(notes[1]:find(pinned:sub(1, 12), 1, true), notes[1])

        -- Check the late card stayed and the checkout sits on the pinned commit
        testing.eq((state(home, late)), support.COLUMN_NAME.RELEASE)
        testing.ok(out:find("These cards stay in Release:", 1, true), out)
        testing.ok(out:find(late:sub(1, 4), 1, true), out)
        testing.ok(out:find("is not in", 1, true), out)
        testing.eq(#done_notes(select(2, state(home, late))), 0)
        testing.ok(out:find(root .. " is on " .. pinned:sub(1, 12), 1, true), out)
        testing.eq(jj(root, "log", "-r", "@-", "--no-graph", "-T", "commit_id"), pinned)
    end)

    testing.test("ship reads a pomb land note and moves the card", function()
        -- Start a project with a passing release row
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))

        -- Land a card whose only note is a pomb land note
        local id = release_card(root, home, "Pomb", { "It works" }, false)
        must(
            dev(
                root,
                home,
                { "board", "note", id, "landed " .. trunk_commit(root) .. " on origin/main" }
            )
        )
        tick(root, home, id)

        -- Ship the board
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
    end)

    testing.test("ship reads the newest land note", function()
        -- Start a project with a passing release row
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))

        -- Land a card at a newer commit and note an older landing last
        local pinned = trunk_commit(root)
        local id = release_card(root, home, "Twice", { "It works" }, push_commit(root, "later"))
        land_note(root, home, id, pinned)
        tick(root, home, id)

        -- Ship at the older commit
        jj(root, "new", pinned)
        local out, code = dev(root, home, { "board", "ship", "--rev", pinned })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
    end)

    testing.test("ship refuses a working copy that differs from the rev", function()
        -- Start a project with a ticked card in Release
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)

        -- Dirty the working copy
        assert(fs.write(root .. "/extra.txt", "extra\n"), "write failed")

        -- Ship with a command and check it never ran
        local log = support.tempdir() .. "/ran"
        local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", "echo x >>" .. log })
        testing.eq(code, 1, out)
        testing.ok(out:find("working copy is not at", 1, true), out)
        testing.ok(not fs.exists(log), "the command ran")
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship refuses a working copy on an older trunk", function()
        -- Start a project with a passing release row
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))

        -- Land a ticked card on a newer trunk and move the working copy back
        local pinned = trunk_commit(root)
        local id = release_card(root, home, "Late", { "It works" }, push_commit(root, "later"))
        tick(root, home, id)
        jj(root, "new", pinned)

        -- Ship the board
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 1, out)
        testing.ok(out:find("working copy is not at", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship leaves a card with no landed commit in release and says why", function()
        -- Start a project with a passing release row
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))

        -- Put a ticked card in Release with no landing note
        local id = release_card(root, home, "Bare", { "It works" }, false)
        tick(root, home, id)

        -- Ship the board
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
        testing.ok(out:find("no landed commit", 1, true), out)
    end)

    testing.test("ship names an unticked outcome as the reason", function()
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))
        local id = release_card(root, home, "Open", { "It works" })
        local out, code = dev(root, home, { "board", "ship" })
        testing.eq(code, 0, out)
        testing.ok(out:find("outcome is not ticked", 1, true), out)
        testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    end)

    testing.test("ship takes --rev with a command", function()
        -- Start a project with no release rows
        local root, home = project()
        must(dev(root, home, { "board", "init" }))

        -- Land a ticked card at the pinned commit
        local pinned = trunk_commit(root)
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)

        -- Ship at that commit with a command
        local out, code = dev(root, home, { "board", "ship", "--rev", pinned, "--", "true" })
        testing.eq(code, 0, out)
        testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
    end)

    testing.test("ship with --rev and a bare -- refuses", function()
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))
        local out, code = dev(root, home, { "board", "ship", "--rev", "master@origin", "--" })
        testing.eq(code, 2, out)
        testing.ok(out:find("Needs a command after --.", 1, true), out)
    end)

    testing.test("ship with an unreadable rev moves no card", function()
        -- Start a project with a passing release row
        local root, home = project(PASSING_RELEASE)
        must(dev(root, home, { "board", "init" }))

        -- Land a ticked card in Release
        local id = release_card(root, home, "First", { "It works" })
        tick(root, home, id)

        -- Ship at a rev that does not exist
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
    -- Sandbox the project with a local board config
    local lines = {
        "[board]",
        'backend = "local"',
        'name = "' .. BOARD .. '"',
        "[board.release]",
        'checks = ["true"]',
    }
    if revert_after then
        lines[#lines + 1] = "revert_after = " .. revert_after
    end
    lines[#lines + 1] = ""
    local root = support.sandbox({
        [".dev/config.toml"] = table.concat(lines, "\n"),
    }, {})

    -- Give the project an empty user config
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    assert(fs.write(home .. "/.config/dev/config.toml", ""), "write failed")

    -- Make the bare remote and a git repo that points at it
    local bare = assert(fs.realpath(support.tempdir()))
    must(dev_os.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, { stdout = "null" }))
    must(dev_os.run({ "git", "init", "-q", "-b", "master", root }, { stdout = "null" }))
    git(root, "remote", "add", "origin", bare)

    -- Push a seed commit as trunk
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

    -- Build the add command with one flag per outcome
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

    -- Add the card and move it into Release
    local out = dev(root, home, argv)
    local id = assert(out:match("added (%x+)"), out)
    support.place(support.board_file(home, BOARD), id, support.COLUMN_NAME.RELEASE)

    -- Note the landing and tick every outcome
    land_note(root, home, id, landed)
    for n = 1, #outcomes do
        must(dev(root, home, { "board", "outcome", id, "--tick", tostring(n), "--as", "verifier" }))
    end
    return id
end

testing.test("ship.in.a.git.project.moves.a.card.landed.in.trunk", function()
    -- Start a git project with a card landed on trunk
    local root, home = git_project()
    must(dev(root, home, { "board", "init" }))
    local id = git_release_card(root, home, "First", git_head(root))
    local trunk = git_head(root)

    -- Ship the board
    local out, code = dev(root, home, { "board", "ship" })
    testing.eq(code, 0, out)

    -- Check the card moved to Done with one note naming trunk
    testing.eq((state(home, id)), support.COLUMN_NAME.DONE)
    local notes = done_notes(select(2, state(home, id)))
    testing.eq(#notes, 1)
    testing.ok(notes[1]:find(trunk:sub(1, 12), 1, true), notes[1])
    testing.ok(out:find("shipped 1 card", 1, true), out)
end)

testing.test("ship.in.a.git.project.leaves.a.card.landed.after.the.rev", function()
    -- Start a git project with one card at the pinned commit and one after it
    local root, home = git_project()
    must(dev(root, home, { "board", "init" }))
    local pinned = git_head(root)
    local early = git_release_card(root, home, "Early", pinned)
    local late = git_release_card(root, home, "Late", git_push_commit(root, "later"))

    -- Ship at the pinned commit
    git(root, "checkout", "-q", "--detach", pinned)
    local out, code = dev(root, home, { "board", "ship", "--rev", pinned })
    testing.eq(code, 0, out)

    -- Check only the early card moved
    testing.eq((state(home, early)), support.COLUMN_NAME.DONE)
    testing.eq((state(home, late)), support.COLUMN_NAME.RELEASE)
    testing.ok(out:find("is not in", 1, true), out)
    testing.eq(#done_notes(select(2, state(home, late))), 0)
end)

testing.test("ship.reverts.a.suspect.in.a.git.project", function()
    -- Start a git project with a landed card whose checks are set
    local root, home = git_project(0)
    must(dev(root, home, { "board", "init" }))
    local landed = git_push_commit(root, "g_test")
    local id = git_release_card(root, home, "Touched", landed, READY_OUTCOMES)
    must(dev(root, home, { "board", "checks", id, READY_CHECKS }))

    -- Ship red once and see the card noted
    local echo = "echo FAIL g_test.txt; exit 1"
    local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
    testing.eq(code, 1, out)
    testing.ok(out:find("First red, so the card is noted.", 1, true), out)

    -- Ship red again and see the card reverted
    out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
    testing.eq(code, 1, out)
    testing.ok(out:find("until it lands", 1, true), out)
    testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    local subject = dev_os.capture({ "git", "-C", root, "log", "-1", "--format=%s" })
    testing.ok(subject:find("Revert", 1, true), subject)

    -- Land the revert and check the card returned to Ready
    git(root, "push", "-q", "origin", "master")
    out, code = dev(root, home, { "board", "ship" })
    testing.eq(code, 0, out)
    testing.eq((state(home, id)), support.COLUMN_NAME.READY)
    testing.eq(dev(root, home, { "board", "show", id }):find("[x]", 1, true), nil)
end)

testing.test("ship.leaves.a.suspect.whose.git.revert.conflicts", function()
    -- Start a git project with a landed card
    local root, home = git_project(0)
    must(dev(root, home, { "board", "init" }))
    local id = git_release_card(root, home, "Touched", git_push_commit(root, "g_test"))

    -- Change the same file again after the card landed
    assert(fs.write(root .. "/g_test.txt", "later\n"), "write failed")
    git(root, "commit", "-q", "-am", "later edit")
    git(root, "push", "-q", "origin", "master")

    -- Ship red twice
    local echo = "echo FAIL g_test.txt; exit 1"
    dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
    local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", echo })

    -- Check the conflict is reported and the tree is untouched
    testing.eq(code, 1, out)
    testing.ok(out:find("conflicts with later changes", 1, true), out)
    testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
    testing.eq(dev_os.capture({ "git", "-C", root, "status", "--porcelain" }), "")
    local subject = dev_os.capture({ "git", "-C", root, "log", "-1", "--format=%s" })
    testing.eq(subject:find("Revert", 1, true), nil)
end)

testing.test("ship.reverts.suspects.newest.landed.first.by.short.commit.id", function()
    -- Start a git project with two commits that both touch the red file
    local root, home = git_project(0)
    must(dev(root, home, { "board", "init" }))
    local older = git_push_commit(root, "g_test")
    local more = table.concat({ "g_test", "more", "" }, "\n")
    assert(fs.write(root .. "/g_test.txt", more), "write failed")
    git(root, "commit", "-q", "-am", "newer edit")
    git(root, "push", "-q", "origin", "master")
    local newer = git_head(root)

    -- Land a card for each of them and one for an unrelated commit
    local old_id = git_release_card(root, home, "Older", older:sub(1, 12), READY_OUTCOMES)
    local new_id = git_release_card(root, home, "Newer", newer:sub(1, 12), READY_OUTCOMES)
    local other = git_push_commit(root, "bystander")
    local other_id = git_release_card(root, home, "Bystander", other:sub(1, 12), READY_OUTCOMES)
    must(dev(root, home, { "board", "checks", old_id, READY_CHECKS }))
    must(dev(root, home, { "board", "checks", new_id, READY_CHECKS }))

    -- Ship red twice
    local echo = "echo FAIL g_test.txt; exit 1"
    dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
    local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", echo })

    -- Check the newest card was reverted first and the bystander was spared
    testing.eq(code, 1, out)
    testing.ok(state(home, new_id) == support.COLUMN_NAME.RELEASE, out)
    testing.ok(state(home, old_id) == support.COLUMN_NAME.RELEASE, out)
    testing.ok(out:find("until it lands", 1, true), out)
    testing.eq((state(home, other_id)), support.COLUMN_NAME.RELEASE)
    testing.eq(out:find("conflicts with later changes", 1, true), nil)
end)

testing.test("ship.names.no.suspect.when.every.card.matches", function()
    -- Start a git project with two commits that both touch the red file
    local root, home = git_project(0)
    must(dev(root, home, { "board", "init" }))
    local first = git_push_commit(root, "g_test")
    local more = table.concat({ "g_test", "more", "" }, "\n")
    assert(fs.write(root .. "/g_test.txt", more), "write failed")
    git(root, "commit", "-q", "-am", "second edit")
    git(root, "push", "-q", "origin", "master")
    local second = git_head(root)

    -- Land a card for each of them
    local a_id = git_release_card(root, home, "First", first:sub(1, 12), READY_OUTCOMES)
    local b_id = git_release_card(root, home, "Second", second:sub(1, 12), READY_OUTCOMES)

    -- Ship red and check no card is named a suspect
    local echo = "echo FAIL g_test.txt; exit 1"
    local out, code = dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
    testing.eq(code, 1, out)
    testing.ok(out:find("Every landed card matches the failing files", 1, true), out)
    testing.eq(out:find("First red", 1, true), nil)

    -- Ship red again and check neither card was noted
    dev(root, home, { "board", "ship", "--", "sh", "-c", echo })
    testing.eq((state(home, a_id)), support.COLUMN_NAME.RELEASE)
    testing.eq((state(home, b_id)), support.COLUMN_NAME.RELEASE)
    testing.eq(red_notes(home, a_id), 0)
    testing.eq(red_notes(home, b_id), 0)
end)

testing.test("ship.in.a.git.project.refuses.a.head.off.the.rev", function()
    -- Start a git project with a card landed after the pinned commit
    local root, home = git_project()
    must(dev(root, home, { "board", "init" }))
    local pinned = git_head(root)
    local id = git_release_card(root, home, "Late", git_push_commit(root, "later"))

    -- Move HEAD back to the pinned commit and ship
    git(root, "checkout", "-q", "--detach", pinned)
    local out, code = dev(root, home, { "board", "ship" })
    testing.eq(code, 1, out)
    testing.ok(out:find("working copy is not at", 1, true), out)
    testing.eq((state(home, id)), support.COLUMN_NAME.RELEASE)
end)
