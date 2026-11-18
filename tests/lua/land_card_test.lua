local testing = require("dev.testing")
local board = require("dev.board")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local json = require("dev.json")
local support = require("support")

local GIT_IDENT = support.GIT_IDENT
local git = support.git
local rev = support.rev

local function must(first, second)
    local code = type(first) == "number" and first or second
    assert(code == 0, tostring(first))
end

local function dev(tree, args, extra)
    local env = {
        HOME = tree.home,
        XDG_STATE_HOME = tree.home .. "/state",
        DEV_AGENT = "dotfiles/lander",
        DEV_WS_ROOT = tree.base,
    }
    for name, value in pairs(GIT_IDENT) do
        env[name] = value
    end
    for name, value in pairs(extra or {}) do
        env[name] = value
    end
    return support.dev(tree.root, args, { env = env })
end

local function column_of(home, id)
    local text = assert(fs.read(home .. "/state/dev/boards/mine.json"), "read failed")
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
    local root = support.sandbox({
        [".dev/config.toml"] = '[board]\nbackend = "local"\nname = "mine"\n',
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }), "mkdir failed")
    assert(fs.write(home .. "/.config/dev/config.toml", ""), "write failed")
    local bare = support.tempdir()
    must(dev_os.run({ "git", "init", "--bare", "-q", "-b", "master", bare }, { stdout = "null" }))
    must(dev_os.run({ "git", "init", "-q", "-b", "master", root }, { stdout = "null" }))
    git(root, "remote", "add", "origin", bare)
    local main = { root = root, home = home, base = assert(fs.realpath(support.tempdir())) }
    must(dev(main, { "board", "init" }))
    local out = dev(main, {
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
        "--done-when",
        "It works",
    })
    main.id = assert(out:match("added (%x+)"), out)
    must(dev(main, { "board", "checks", main.id, "true" }))
    git(root, "add", "-A")
    git(root, "commit", "-q", "-m", "base")
    git(root, "push", "-q", "origin", "master")
    main.bare = bare
    return main
end

local function worktree(main, name)
    local folder = main.base .. "/" .. fs.basename(main.root)
    assert(fs.mkdir(folder, { parents = true }), "mkdir failed")
    local path = folder .. "/" .. name
    git(main.root, "worktree", "add", "-q", "-b", name, path, "master")
    assert(fs.write(path .. "/work.txt", "one\n"), "write failed")
    git(path, "add", "-A")
    git(path, "commit", "-q", "-m", "feat: work")
    return { root = path, home = main.home, base = main.base, id = main.id, bare = main.bare }
end

local function approve(tree)
    local id = tree.id
    must(support.to_review(function(args)
        return dev(tree, args, { DEV_AGENT = "dotfiles/builder" })
    end, id))
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
    must(dev(tree, { "board", "check", id }))
    must(dev(tree, { "board", "outcome", id, "--tick", "1", "--as", "verifier" }))
end

testing.test("land.card.lands the card its workspace names", function()
    local main = project()
    local tree = worktree(main, main.id)
    approve(tree)
    local commit = rev(tree.root, "HEAD")
    local out, code = dev(tree, { "land" })
    testing.eq(code, 0, out)
    testing.eq(rev(main.bare, "refs/heads/master"), commit)
    local column, card = column_of(main.home, main.id)
    testing.eq(column, board.DEFAULT_NAMES.done)
    local note = card.comments[#card.comments]
    testing.eq(note.kind, board.NoteKind.DONE)
    testing.ok(note.body:find("Landed commit " .. commit:sub(1, 12), 1, true), note.body)
end)

testing.test("land.card.refuses a workspace that is not a card and lands nothing", function()
    local main = project()
    local tree = worktree(main, "scratchws")
    local before = column_of(main.home, main.id)
    local trunk = rev(main.bare, "refs/heads/master")
    local out, code = dev(tree, { "land" })
    testing.eq(code, 1, out)
    testing.ok(out:find("Cannot land the workspace scratchws as a card", 1, true), out)
    testing.eq(rev(main.bare, "refs/heads/master"), trunk)
    testing.eq(column_of(main.home, main.id), before)
end)

testing.test("land.card.passes.card.and.wait.to.the.landing", function()
    local main = project()
    local tree = worktree(main, main.id)
    approve(tree)
    local commit = rev(tree.root, "HEAD")
    local out, code = dev(tree, { "land", "--card", main.id, "--wait", "5" })
    testing.eq(code, 0, out)
    testing.eq(rev(main.bare, "refs/heads/master"), commit)
    testing.eq(column_of(main.home, main.id), board.DEFAULT_NAMES.done)
end)

testing.test("land.card.names.the.card.flag.when.it.matches.nothing", function()
    local main = project()
    local tree = worktree(main, main.id)
    local trunk = rev(main.bare, "refs/heads/master")
    local out, code = dev(tree, { "land", "--card", "deadbeef" })
    testing.eq(code, 1, out)
    testing.eq(out:find("Cannot land the workspace", 1, true), nil, out)
    testing.ok(out:find("No card starts with deadbeef.", 1, true), out)
    testing.eq(rev(main.bare, "refs/heads/master"), trunk)
end)

testing.test("land.card.refuses.a.wait.that.is.not.a.number", function()
    local main = project()
    local tree = worktree(main, main.id)
    local trunk = rev(main.bare, "refs/heads/master")
    local out, code = dev(tree, { "land", "--wait", "abc" })
    testing.eq(code, 2, out)
    testing.ok(out:find("--wait needs a whole number of seconds", 1, true), out)
    testing.eq(rev(main.bare, "refs/heads/master"), trunk)
end)
