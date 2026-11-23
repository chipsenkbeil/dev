local testing = require("dev.testing")
local board = require("dev.board")
local cmd_board = require("dev.cmd.board")
local localboard = require("dev.board.localboard")
local pomb = require("dev.board.pomb")
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
local state = assert(workspace:state())
assert(workspace:merge_into_trunk())
assert(card[ctx.args[2]](card, state))
print("landed " .. found:release_column() .. " " .. found:done_column())
]=]

local PROVE_SCRIPT = [=[
local ctx = ...
local board = require("dev.board")
local check = require("dev.board.check")
local review = require("dev.board.review")
local scm = require("dev.scm")

local workspace = scm.workspace(ctx.root)
local found = assert(board.find(workspace))
local card = assert(found:find_card(ctx.args[1]))
local state = workspace:state()
if ctx.args[2] == "fake" then
    state = { commit = "abcdef1234", change = "klmnopqrst" }
end
local rows = { { run = "dev test", result = check.Result.PASS, run_id = "ab12" } }
assert(found.backend:note(card.card.id, check.record(state, rows, false)))
for _, kind in ipairs({ "code", "style" }) do
    assert(found.backend:note(card.card.id, review.record(kind, "r/" .. kind, state, "clean")))
end
]=]

local MOVE_SCRIPT = [=[
local ctx = ...
local board = require("dev.board")
local scm = require("dev.scm")

local found = assert(board.find(scm.workspace(ctx.root)))
local card = assert(found:find_card(ctx.args[1]))
local state
if ctx.args[2] == "fake" then
    state = { commit = "abcdef1234", change = "klmnopqrst" }
end
local ok, message = card:move_to_release(state)
print((ok and "moved" or "refused") .. ": " .. tostring(message))
]=]

local PROOF_SCRIPT = [=[
local ctx = ...
local board = require("dev.board")
local scm = require("dev.scm")

local found = assert(board.find(scm.workspace(ctx.root)))
local card = assert(found:find_card(ctx.args[1]))
print("problem: " .. tostring(card:land_problem()))
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
        [".dev/apiproof.lua"] = PROOF_SCRIPT,
        [".dev/apiprove.lua"] = PROVE_SCRIPT,
        [".dev/apimove.lua"] = MOVE_SCRIPT,
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
            DEV_SELF = dev_os.capture({ "pwd" }):gsub("\n$", "") .. "/bin/dev",
        },
    })
end

local function card(root, home, start, with_checks)
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
    if with_checks then
        must(dev(root, home, { "board", "checks", id, "dev test" }))
    end
    return id
end

local function column_of(home, id)
    local doc = assert(
        json.decode(assert(fs.read(support.board_file(home, BOARD)), "read failed")),
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
    local id = card(root, home, start, true)
    assert(fs.write(root .. "/work.txt", "work\n"), "write failed")
    git(root, "add", "work.txt")
    git(root, "commit", "-q", "-m", "feat: work")
    must(dev(root, home, { "apiprove", id }))
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

testing.test("move_to refuses an unproven card and leaves it where it is", function()
    local root, home = project()
    must(dev(root, home, { "board", "init" }))
    local id = card(root, home, support.Column.VERIFY, true)
    local out, code = dev(root, home, { "apimove", id })
    testing.eq(code, 0, out)
    testing.ok(out:find("refused: Card", 1, true), out)
    testing.ok(out:find("cannot move to " .. support.COLUMN_NAME.RELEASE, 1, true), out)
    testing.eq(column_of(home, id), support.COLUMN_NAME.VERIFY)
end)

testing.test(
    "move_to moves a proven card after a jj merge from the state read before it",
    function()
        local root, home = project()
        must(dev(root, home, { "board", "init" }))
        local id = card(root, home, support.Column.VERIFY, true)
        must(dev(root, home, { "apiprove", id, "fake" }))
        local out, code = dev(root, home, { "apimove", id, "fake" })
        testing.eq(code, 0, out)
        testing.ok(out:find("moved: nil", 1, true), out)
        testing.eq(column_of(home, id), support.COLUMN_NAME.RELEASE)
    end
)

testing.test("a card found by the board api names why it cannot land and lands nothing", function()
    local root, home, bare = project()
    must(dev(root, home, { "board", "init" }))
    local id = card(root, home, support.Column.REVIEW)
    local trunk = dev_os.capture({ "git", "-C", bare, "rev-parse", "master" })
    local out, code = dev(root, home, { "apiproof", id })
    testing.eq(code, 0, out)
    testing.ok(out:find("problem: No code review of change", 1, true), out)
    testing.ok(out:find("The card has no checks rows.", 1, true), out)
    testing.eq(dev_os.capture({ "git", "-C", bare, "rev-parse", "master" }), trunk)
    testing.eq(column_of(home, id), support.COLUMN_NAME.VERIFY)
end)

testing.test("board.find names a project with no board", function()
    local root = support.sandbox({ [".dev/config.toml"] = "" }, {})
    local found, message = board.find(scm.workspace(root))
    testing.eq(found, nil)
    testing.ok(message:find("no `[board]` section", 1, true), tostring(message))
end)

local function column_backend(answer)
    local backend = {
        patches = {},
        column_map = {},
    }
    function backend:done_columns()
        return {}
    end
    function backend:failure(message)
        return support.failure_of(message)
    end
    function backend:columns()
        return { { name = support.COLUMN_NAME.RELEASE }, { name = support.COLUMN_NAME.BLOCKED } }
    end
    function backend:set_column(name, fields)
        self.patches[#self.patches + 1] = { name, fields }
        if answer then
            return nil, answer
        end
        return true
    end
    return backend
end

testing.test("column sets the clears-blockers flag of the named column", function()
    local backend = column_backend()
    local result = cmd_board.run("column", { "release", "--clears-blockers", "on" }, backend)
    testing.eq(result.code, nil, result.output)
    testing.eq(backend.patches, { { support.COLUMN_NAME.RELEASE, { clears_blockers = true } } })
    result = cmd_board.run(
        "column",
        { support.COLUMN_NAME.RELEASE, "--clears-blockers", "off" },
        backend
    )
    testing.eq(backend.patches[2], { support.COLUMN_NAME.RELEASE, { clears_blockers = false } })
end)

testing.test("column sets the blocked flag of the named column", function()
    local backend = column_backend()
    local result =
        cmd_board.run("column", { support.COLUMN_NAME.BLOCKED, "--blocked", "on" }, backend)
    testing.eq(result.code, nil, result.output)
    testing.eq(backend.patches, { { support.COLUMN_NAME.BLOCKED, { is_blocked = true } } })
end)

testing.test("column sends the flags to Pomb as a PATCH of the column id", function()
    local backend = assert(pomb.new({ url = "https://pomb.example", name = "mine", token = "t" }))
    local sent = {}
    function backend:__load()
        self.__detail = { columns = { { id = "col-9", name = support.COLUMN_NAME.RELEASE } } }
        return true
    end
    function backend:__request(method, path, body)
        sent = { method, path, body }
        return {}
    end
    testing.eq(backend:set_column("release", { clears_blockers = true }), true)
    testing.eq(sent, { "PATCH", "/api/columns/col-9", { clears_blockers = true } })
    local done, message = backend:set_column("Nope", { is_blocked = true })
    testing.eq(done, nil)
    testing.eq(message, "The board has no column Nope.")
end)

testing.test("column prints the permission message for a Pomb 403", function()
    local backend = column_backend("Board refused: Pomb answered 403: nope.")
    local result =
        cmd_board.run("column", { support.COLUMN_NAME.RELEASE, "--blocked", "on" }, backend)
    testing.eq(result.code, 1)
    testing.ok(result.message:find("Pomb refused the change", 1, true), result.message)
    testing.ok(result.message:find("columns.edit", 1, true), result.message)
end)

testing.test("column names the lead token by the recorded status, not the wording", function()
    local backend = column_backend("the token is too small")
    function backend:failure()
        return { reason = board.TransportReason.REFUSED, detail = { status = 403 } }
    end
    local result =
        cmd_board.run("column", { support.COLUMN_NAME.RELEASE, "--blocked", "on" }, backend)
    testing.ok(result.message:find("columns.edit", 1, true), result.message)
    local worded = column_backend("Board refused: Pomb answered 403: nope.")
    function worded:failure()
        return { reason = board.TransportReason.REFUSED, detail = { status = 409 } }
    end
    result = cmd_board.run("column", { support.COLUMN_NAME.RELEASE, "--blocked", "on" }, worded)
    testing.eq(result.message:find("columns.edit", 1, true), nil, result.message)
end)

testing.test("a 4xx answer is a board refusal and a 5xx stays board unavailable", function()
    local Reason = board.TransportReason
    for _, status in ipairs({ 400, 404, 409, 429, 499 }) do
        local message =
            board.transport_refusal(Reason.REFUSED, { status = status, message = "nope." })
        testing.eq(message, "Board refused: Pomb answered " .. status .. ": nope.")
        testing.eq(
            pomb.unreachable(
                { reason = Reason.REFUSED, detail = { status = status, message = "nope." } },
                true
            ),
            false,
            message
        )
    end
    for _, status in ipairs({ 500, 502, 503 }) do
        local message =
            board.transport_refusal(Reason.REFUSED, { status = status, message = "down." })
        testing.eq(message, "Board unavailable: Pomb answered " .. status .. ": down.")
    end
    testing.eq(
        board.transport_refusal(Reason.UNREACHABLE, { url = "https://p.test", code = 7 }),
        "Board unavailable: Cannot reach https://p.test (curl exit 7)."
    )
    testing.eq(
        pomb.unreachable(
            { reason = Reason.REFUSED, detail = { status = 502, message = "down." } },
            true
        ),
        true
    )
end)

testing.test("column refuses an unknown name, a bad value and a missing flag", function()
    local backend = column_backend()
    local result = cmd_board.run("column", { "Nope", "--blocked", "on" }, backend)
    testing.eq(result.code, 1)
    testing.eq(result.message, "The board has no column Nope.")
    result = cmd_board.run("column", { support.COLUMN_NAME.RELEASE, "--blocked", "yes" }, backend)
    testing.eq(result.code, 2)
    result = cmd_board.run("column", { support.COLUMN_NAME.RELEASE }, backend)
    testing.eq(result.code, 2)
    result = cmd_board.run("column", {}, backend)
    testing.eq(result.code, 2)
    testing.eq(backend.patches, {})
end)

testing.test("column on a local board is refused with a sentence", function()
    local backend = column_backend()
    local own = localboard.new({ name = "mine", path = "unused.json" })
    function backend:set_column(...)
        return own:set_column(...)
    end
    local result =
        cmd_board.run("column", { support.COLUMN_NAME.RELEASE, "--blocked", "on" }, backend)
    testing.eq(result.code, 1)
    testing.eq(result.message, "A local board has no column flags to set.")
end)
