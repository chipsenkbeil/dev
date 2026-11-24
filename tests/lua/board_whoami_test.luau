local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local support = require("./support")

local WORKER = "pomb_WORKERtoken0123456789"
local EXPIRES = 4102444800
local function user_config(url)
    return '[board.pomb]\nurl = "' .. url .. '"\ntoken = "pass:secrets/worker/token/pomb"\n'
end
local ROLE_WHO = '{"kind":"token","name":"dotfiles/implementer/72f0e012/1","scope":"write",'
    .. '"expires_at":'
    .. EXPIRES
    .. ',"handle":"me","role_name":"implementer","label":"agent-3",'
    .. '"parent_token":{"id":"tok-lead","name":"dotfiles/lead/82f0e002/1"},'
    .. '"permissions":["cards.read","cards.write"],'
    .. '"drift":{"beyond":["cards.write","cards.bin"],"lacks":["cards.move"]},'
    .. '"boards":[{"id":"board-1","name":"dotfiles"},{"id":"board-2","name":"pomb"}]}'
local PLAIN_WHO = '{"kind":"token","name":"plain","scope":"read","expires_at":null,"handle":"me",'
    .. '"role_name":null,"label":null,"parent_token":null,"drift":null,'
    .. '"permissions":["cards.read"],"boards":"all"}'

local SERVERS = {}

local function sync(root)
    SERVERS[root]:set({
        {
            path = "/api/v1/auth/whoami",
            status = tonumber((fs.read(root .. "/who_status"))) or 200,
            body = fs.read(root .. "/who.json"),
        },
        { path = "*", body = "{}" },
    })
end

local function executable(path, body)
    assert(fs.write(path, body))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function sandbox(who)
    local root = support.sandbox({
        [".dev/config.toml"] = '[board]\nbackend = "pomb"\nname = "dotfiles"\n',
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    SERVERS[root] = support.fake_http({})
    assert(fs.write(home .. "/.config/dev/config.toml", user_config(SERVERS[root].url)))
    assert(fs.write(root .. "/who.json", who))
    executable(root .. "/bin/security", "#!/bin/sh\nexit 1\n")
    executable(root .. "/bin/pass", '#!/bin/sh\necho "' .. WORKER .. '"\n')
    return root, home
end

local function whoami(root, home)
    sync(root)
    return support.dev(root, { "board", "whoami" }, {
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

testing.test(
    "whoami-fields prints the name, kind, scope, role, label, issuer and expiry",
    function()
        local root, home = sandbox(ROLE_WHO)
        local out, code = whoami(root, home)
        testing.ok(code == 0, out)
        testing.ok(
            SERVERS[root]:requests():find("/api/v1/auth/whoami", 1, true),
            SERVERS[root]:requests()
        )
        testing.ok(out:find("name: dotfiles/implementer/72f0e012/1\n", 1, true), out)
        testing.ok(out:find("kind: token\n", 1, true), out)
        testing.ok(out:find("scope: write\n", 1, true), out)
        testing.ok(out:find("role: implementer\n", 1, true), out)
        testing.ok(out:find("label: agent-3\n", 1, true), out)
        testing.ok(out:find("issuer: dotfiles/lead/82f0e002/1\n", 1, true), out)
        testing.ok(out:find("expires: 2100-01-01T00:00:00Z\n", 1, true), out)
    end
)

testing.test(
    "whoami-norole prints none for the role, label and issuer of a token with no role",
    function()
        local root, home = sandbox(PLAIN_WHO)
        local out, code = whoami(root, home)
        testing.ok(code == 0, out)
        testing.ok(out:find("role: none\n", 1, true), out)
        testing.ok(out:find("label: none\n", 1, true), out)
        testing.ok(out:find("issuer: none\n", 1, true), out)
        testing.ok(out:find("expires: never\n", 1, true), out)
    end
)

testing.test("whoami-silent prints the boards and permissions and never the token", function()
    local root, home = sandbox(ROLE_WHO)
    local out, code = whoami(root, home)
    testing.ok(code == 0, out)
    testing.ok(out:find("boards: dotfiles, pomb\n", 1, true), out)
    testing.ok(out:find("permissions: cards.read, cards.write", 1, true), out)
    testing.eq(out:find(WORKER, 1, true), nil, out)
    testing.eq(out:find(WORKER, 1, true), nil, out)
    root, home = sandbox(PLAIN_WHO)
    out, code = whoami(root, home)
    testing.ok(out:find("boards: all\n", 1, true), out)
    assert(fs.write(root .. "/who.json", '{"code":"token_expired","message":"' .. WORKER .. '"}'))
    assert(fs.write(root .. "/who_status", "401"))
    out, code = whoami(root, home)
    testing.ok(code == 1, out)
    testing.ok(out:find("expired", 1, true), out)
    testing.eq(out:find(WORKER, 1, true), nil, out)
end)

testing.test("whoami-drift prints the permissions beyond and lacking as the last line", function()
    local root, home = sandbox(ROLE_WHO)
    local out, code = whoami(root, home)
    testing.ok(code == 0, out)
    testing.ok(out:find("\ndrift: beyond cards.write, cards.bin; lacks cards.move\n?$"), out)
end)

testing.test("whoami-drift-none prints drift none with no role, no drift or empty lists", function()
    local empty = ROLE_WHO:gsub('"drift":{[^}]*},', '"drift":{"beyond":[],"lacks":[]},')
    local only = ROLE_WHO:gsub('"lacks":%["cards.move"%]', '"lacks":[]')
    for _, case in ipairs({
        { who = PLAIN_WHO, line = "\ndrift: none\n?$" },
        { who = empty, line = "\ndrift: none\n?$" },
        { who = only, line = "\ndrift: beyond cards.write, cards.bin\n?$" },
    }) do
        local root, home = sandbox(case.who)
        local out, code = whoami(root, home)
        testing.ok(code == 0, out)
        testing.ok(out:find(case.line), out)
    end
end)
