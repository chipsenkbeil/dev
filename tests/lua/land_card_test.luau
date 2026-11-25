local testing = require("@dev/testing")
local board = require("@dev/board")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local json = require("@dev/json")
local support = require("./support")

local GIT_IDENT = support.GIT_IDENT
local git = support.git
local rev = support.rev

local function must(first, second)
    local code = type(first) == "number" and first or second
    assert(code == 0, tostring(first))
end

local function dev(tree, args, extra)
    -- Start from the tree's home and agent
    local env = {
        HOME = tree.home,
        XDG_STATE_HOME = tree.home .. "/state",
        DEV_AGENT = "dotfiles/lander",
        DEV_WS_ROOT = tree.base,
    }

    -- Add the git identity and the caller's overrides
    for name, value in pairs(GIT_IDENT) do
        env[name] = value
    end
    for name, value in pairs(extra or {}) do
        env[name] = value
    end

    -- Run dev in the tree
    return support.dev(tree.root, args, { env = env })
end

local function column_of(home, id)
    local text = assert(fs.read(support.board_file(home, "mine")), "read failed")
    local doc = assert(json.decode(text), "decode failed")
    for _, card in ipairs(doc.cards) do
        if card.id:sub(1, #id) == id then
            for _, column in ipairs(doc.columns) do
                if column.id == card.column_id then
                    return column.name, card
                end
            end
        end
    end
end

local function project()
    -- Make a project on a local board with an empty user config
    local root = support.sandbox({
        [".dev/config.toml"] = table.concat({
            "[board]",
            'backend = "local"',
            'name = "mine"',
            "",
        }, "\n"),
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    assert(fs.write(home .. "/.config/dev/config.toml", ""), "write failed")

    -- Give it a bare remote and start the board
    local bare = support.tempdir()
    must(dev_os.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, { stdout = "null" }))
    must(dev_os.run({ "git", "init", "-q", "-b", "master", root }, { stdout = "null" }))
    git(root, "remote", "add", "origin", bare)
    local main = { root = root, home = home, base = assert(fs.realpath(support.tempdir())) }
    must(dev(main, { "board", "init" }))

    -- Add a ready card and give it a check
    local args = {
        "board",
        "add",
        "Card",
        "--problem",
        "x",
        "--change",
        "x",
        "--out-of-scope",
        "y",
        "--size",
        "1",
    }
    for _, outcome in ipairs(support.READY_OUTCOMES) do
        args[#args + 1] = "--done-when"
        args[#args + 1] = (outcome.name:gsub("%(check: .*%)$", board.JUDGEMENT))
    end
    local out = dev(main, args)
    main.id = assert(out:match("added (%x+)"), out)
    must(dev(main, { "board", "checks", main.id, "true" }))

    -- Publish the board as the base commit
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "base")
    git(root, "push", "-q", "origin", "master")
    main.bare = bare
    return main
end

local function worktree(main, name)
    -- Add a worktree on a branch of its own
    local folder = main.base .. "/" .. fs.basename(main.root)
    assert(fs.mkdir(folder, { parents = true }), "mkdir failed")
    local path = folder .. "/" .. name
    git(main.root, "worktree", "add", "-q", "-b", name, path, "master")

    -- Commit a change in it
    assert(fs.write(path .. "/work.txt", "one\n"), "write failed")
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "feat: work")

    -- Describe the tree for the caller
    return { root = path, home = main.home, base = main.base, id = main.id, bare = main.bare }
end

local function approve(tree)
    -- Move the card to Review as its builder
    local id = tree.id
    must(support.to_review(function(args)
        return dev(tree, args, { DEV_AGENT = "dotfiles/builder" })
    end, id))

    -- Record a clean review of each kind
    for _, kind in ipairs({ "code", "style" }) do
        must(dev(tree, {
            "board",
            "review",
            id,
            "--kind",
            kind,
            "--by",
            "rev",
            "--rev",
            "HEAD",
            "--verdict",
            "clean",
        }, { DEV_AGENT = "rev" }))
    end

    -- Run the card's check and tick every outcome
    must(dev(tree, { "board", "check", id }))
    for number = 1, #support.READY_OUTCOMES do
        local args = { "board", "outcome", id, "--tick", tostring(number), "--as", "verifier" }
        must(dev(tree, args))
    end
end

testing.test("land.card.lands the card its workspace names", function()
    -- Approve the card's workspace
    local main = project()
    local tree = worktree(main, main.id)
    approve(tree)
    local commit = rev(tree.root, "HEAD")

    -- Land it
    local out, code = dev(tree, { "land" })
    testing.eq(code, 0, out)
    testing.eq(rev(main.bare, "refs/heads/master"), commit)

    -- Check the card is Done with a note of the commit
    local column, card = column_of(main.home, main.id)
    testing.eq(column, board.DEFAULT_NAMES.done)
    local note = card.comments[#card.comments]
    testing.eq(note.kind, board.NoteKind.DONE)
    testing.ok(note.body:find("Landed commit " .. commit:sub(1, 12), 1, true), note.body)
end)

testing.test("land.card.refuses a workspace that is not a card and lands nothing", function()
    -- Record the trunk and the card before landing a plain workspace
    local main = project()
    local tree = worktree(main, "scratchws")
    local before = column_of(main.home, main.id)
    local trunk = rev(main.bare, "refs/heads/master")

    -- Land it and see the refusal
    local out, code = dev(tree, { "land" })
    testing.eq(code, 1, out)
    testing.ok(out:find("Cannot land the workspace scratchws as a card", 1, true), out)

    -- Check nothing moved
    testing.eq(rev(main.bare, "refs/heads/master"), trunk)
    testing.eq(column_of(main.home, main.id), before)
end)

testing.test("land.card.refuses.an.unproven.card.through.its.proof.refusal", function()
    -- Record the trunk and the card before landing an unproven one
    local main = project()
    local tree = worktree(main, main.id)
    local trunk = rev(main.bare, "refs/heads/master")
    local before = column_of(main.home, main.id)

    -- Land it and see the single proof refusal
    local out, code = dev(tree, { "land" })
    testing.eq(code, 1, out)
    testing.ok(out:find("cannot land. It is in", 1, true), out)
    testing.eq(out:find("cannot land for these reasons", 1, true), nil, out)

    -- Check nothing moved
    testing.eq(rev(main.bare, "refs/heads/master"), trunk)
    testing.eq(column_of(main.home, main.id), before)
end)

testing.test("land.card.names.the.missing.agent.before.any.proof.refusal", function()
    -- Record the trunk before landing a card's workspace
    local main = project()
    local tree = worktree(main, main.id)
    local trunk = rev(main.bare, "refs/heads/master")

    -- Land with no agent set
    local out, code = dev(tree, { "land" }, { DEV_AGENT = "" })
    testing.eq(code, 1, out)
    testing.ok(out:find("Needs DEV_AGENT", 1, true), out)

    -- Check nothing landed
    testing.eq(rev(main.bare, "refs/heads/master"), trunk)
end)

testing.test("land.card.names.the.claimant.when.another.agent.lands", function()
    -- Let another agent claim the card
    local main = project()
    local tree = worktree(main, main.id)
    must(dev(tree, { "board", "take", main.id }, { DEV_AGENT = "dotfiles/owner" }))

    -- Land it as the lander
    local out, code = dev(tree, { "land" })
    testing.eq(code, 1, out)

    -- Check the refusal names both agents
    testing.ok(out:find("claimed by dotfiles/owner", 1, true), out)
    testing.ok(out:find("not dotfiles/lander", 1, true), out)
end)

testing.test("land.card.passes.card.and.wait.to.the.landing", function()
    -- Approve the card's workspace
    local main = project()
    local tree = worktree(main, main.id)
    approve(tree)
    local commit = rev(tree.root, "HEAD")

    -- Land it with the card and wait flags
    local out, code = dev(tree, { "land", "--card", main.id, "--wait", "5" })
    testing.eq(code, 0, out)

    -- Check the commit landed and the card is Done
    testing.eq(rev(main.bare, "refs/heads/master"), commit)
    testing.eq(column_of(main.home, main.id), board.DEFAULT_NAMES.done)
end)

testing.test("land.card.names.the.card.flag.when.it.matches.nothing", function()
    -- Record the trunk before landing with a bad card flag
    local main = project()
    local tree = worktree(main, main.id)
    local trunk = rev(main.bare, "refs/heads/master")

    -- Land with a card flag that matches nothing
    local out, code = dev(tree, { "land", "--card", "deadbeef" })
    testing.eq(code, 1, out)
    testing.eq(out:find("Cannot land the workspace", 1, true), nil, out)
    testing.ok(out:find("No card starts with deadbeef.", 1, true), out)

    -- Check nothing landed
    testing.eq(rev(main.bare, "refs/heads/master"), trunk)
end)

testing.test("land.card.refuses.a.wait.that.is.not.a.number", function()
    -- Approve the card's workspace and record the trunk
    local main = project()
    local tree = worktree(main, main.id)
    approve(tree)
    local trunk = rev(main.bare, "refs/heads/master")

    -- Land with a wait that is not a number
    local out, code = dev(tree, { "land", "--wait", "abc" })
    testing.eq(code, 2, out)
    testing.ok(out:find("The flag `--wait` needs a number, not abc.", 1, true), out)

    -- Check nothing landed
    testing.eq(rev(main.bare, "refs/heads/master"), trunk)
end)
