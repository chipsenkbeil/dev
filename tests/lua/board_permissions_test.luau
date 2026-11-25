local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local support = require("./support")

local WORKER = "pomb_WORKERtoken0123456789"
local function user_config(url)
    return table.concat({
        "[board.pomb]",
        'url = "' .. url .. '"',
        'token = "pass:secrets/worker/token/pomb"',
        "",
    }, "\n")
end

local SERVERS = {}

local function serve(root, status, body)
    SERVERS[root]:set({
        { path = "/api/v1/auth/permissions", status = status, body = body },
        { path = "*", body = "{}" },
    })
end
local CATALOG = '[{"name":"cards.read","group":"cards","description":"Read cards",'
    .. '"presets":["read","work","lead","admin"]},'
    .. '{"name":"boards.create","group":"boards","description":"Create boards",'
    .. '"presets":["lead","admin"]},'
    .. '{"name":"tokens.mint","group":"tokens","description":"Mint tokens","presets":[]}]'

local function executable(path, body)
    assert(fs.write(path, body))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function sandbox()
    -- Make a project on a Pomb board and serve the catalog
    local root = support.sandbox({
        [".dev/config.toml"] = table.concat({
            "[board]",
            'backend = "pomb"',
            'name = "dotfiles"',
            "",
        }, "\n"),
    }, {})
    local home = support.tempdir()
    SERVERS[root] = support.fake_http({})
    serve(root, 200, CATALOG)

    -- Point the home config at the server
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(fs.write(home .. "/.config/dev/config.toml", user_config(SERVERS[root].url)))

    -- Stub the keychain and the pass helper
    executable(root .. "/bin/security", table.concat({ "#!/bin/sh", "exit 1", "" }, "\n"))
    executable(
        root .. "/bin/pass",
        table.concat({ "#!/bin/sh", 'echo "' .. WORKER .. '"', "" }, "\n")
    )
    return root, home
end

local function permissions(root, home, args)
    local words = { "board", "permissions" }
    for _, word in ipairs(args or {}) do
        words[#words + 1] = word
    end
    return support.dev(root, words, {
        env = {
            HOME = home,
            ROOT = root,
            XDG_STATE_HOME = home .. "/state",
            XDG_RUNTIME_DIR = "",
            CI = "",
            DEV_AGENT = "",
            DEV_PASS_LOCK = root .. "/pass.lock",
        },
    })
end

testing.test("permissions prints every catalog entry with its group and presets", function()
    -- Make a sandbox with a server
    local root, home = sandbox()

    -- Print the catalog
    local out, code = permissions(root, home)
    testing.eq(code, 0, out)

    -- Read it from the permissions route
    testing.ok(
        SERVERS[root]:requests():find("GET /api/v1/auth/permissions", 1, true),
        SERVERS[root]:requests()
    )

    -- Print each entry with its group and presets
    testing.ok(out:find("cards.read (cards): read, work, lead, admin\n", 1, true), out)
    testing.ok(out:find("boards.create (boards): lead, admin\n", 1, true), out)
    testing.ok(out:find("tokens.mint (tokens): none", 1, true), out)
end)

testing.test("permissions never prints the token and an extra word is a usage error", function()
    -- Make a sandbox with a server
    local root, home = sandbox()

    -- Keep the token out of the output
    local out, code = permissions(root, home)
    testing.eq(code, 0, out)
    testing.eq(out:find(WORKER, 1, true), nil, out)

    -- Keep it out of the request bodies
    testing.eq(SERVERS[root]:requests():match("body=[^\n]*" .. WORKER), nil)

    -- Refuse an extra word without printing the token
    out, code = permissions(root, home, { "extra" })
    testing.eq(code, 2, out)
    testing.eq(out:find(WORKER, 1, true), nil, out)
end)

testing.test("permissions prints a refused catalog read and exits 1", function()
    -- Serve an expired-token refusal that echoes the token
    local root, home = sandbox()
    serve(root, 401, '{"code":"token_expired","message":"' .. WORKER .. '"}')

    -- Print the catalog
    local out, code = permissions(root, home)

    -- Report the refusal without the token
    testing.eq(code, 1, out)
    testing.ok(out:find("expired", 1, true), out)
    testing.eq(out:find(WORKER, 1, true), nil, out)
end)

testing.test("permissions refuses an answer that is not a list of entries", function()
    -- Serve an answer that is no list
    local root, home = sandbox()
    serve(root, 200, '{"unexpected":true}')

    -- Print the catalog
    local out, code = permissions(root, home)

    -- Refuse the answer
    testing.eq(code, 1, out)
    testing.ok(out:find("cannot read", 1, true), out)
end)
