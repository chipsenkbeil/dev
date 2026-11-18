local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local WORKER = "pomb_WORKERtoken0123456789"
local USER =
    '[board.pomb]\nurl = "https://pomb.example"\ntoken = "pass:secrets/worker/token/pomb"\n'
local CATALOG = '[{"name":"cards.read","group":"cards","description":"Read cards",'
    .. '"presets":["read","work","lead","admin"]},'
    .. '{"name":"boards.create","group":"boards","description":"Create boards",'
    .. '"presets":["lead","admin"]},'
    .. '{"name":"tokens.mint","group":"tokens","description":"Mint tokens","presets":[]}]'

local CURL = [[#!/bin/sh
printf 'curl %s\n' "$*" >>"$ROOT/calls"
cat >>"$ROOT/stdin"
printf '\n' >>"$ROOT/stdin"
for last; do :; done
status=200
case "$last" in
*/auth/permissions)
    body=$(cat "$ROOT/catalog.json")
    status=$(cat "$ROOT/catalog_status" 2>/dev/null || echo 200)
    ;;
*) body='{}' ;;
esac
printf '%s\n%s' "$body" "$status"
]]

local function executable(path, body)
    assert(fs.write(path, body))
    assert(dev_os.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function sandbox()
    local root = support.sandbox({
        [".dev/config.toml"] = '[board]\nbackend = "pomb"\nname = "dotfiles"\n',
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(fs.write(home .. "/.config/dev/config.toml", USER))
    assert(fs.write(root .. "/catalog.json", CATALOG))
    executable(root .. "/bin/curl", CURL)
    executable(root .. "/bin/security", "#!/bin/sh\nexit 1\n")
    executable(root .. "/bin/pass", '#!/bin/sh\necho "' .. WORKER .. '"\n')
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
    local root, home = sandbox()
    local out, code = permissions(root, home)
    testing.eq(code, 0, out)
    testing.ok(
        fs.read(root .. "/calls"):find("/api/v1/auth/permissions", 1, true),
        fs.read(root .. "/calls")
    )
    testing.ok(out:find("cards.read (cards): read, work, lead, admin\n", 1, true), out)
    testing.ok(out:find("boards.create (boards): lead, admin\n", 1, true), out)
    testing.ok(out:find("tokens.mint (tokens): none", 1, true), out)
end)

testing.test("permissions never prints the token and an extra word is a usage error", function()
    local root, home = sandbox()
    local out, code = permissions(root, home)
    testing.eq(code, 0, out)
    testing.eq(out:find(WORKER, 1, true), nil, out)
    testing.eq(fs.read(root .. "/calls"):find(WORKER, 1, true), nil)
    out, code = permissions(root, home, { "extra" })
    testing.eq(code, 2, out)
    testing.eq(out:find(WORKER, 1, true), nil, out)
end)

testing.test("permissions prints a refused catalog read and exits 1", function()
    local root, home = sandbox()
    assert(
        fs.write(root .. "/catalog.json", '{"code":"token_expired","message":"' .. WORKER .. '"}')
    )
    assert(fs.write(root .. "/catalog_status", "401"))
    local out, code = permissions(root, home)
    testing.eq(code, 1, out)
    testing.ok(out:find("expired", 1, true), out)
    testing.eq(out:find(WORKER, 1, true), nil, out)
end)

testing.test("permissions refuses an answer that is not a list of entries", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/catalog.json", '{"unexpected":true}'))
    local out, code = permissions(root, home)
    testing.eq(code, 1, out)
    testing.ok(out:find("cannot read", 1, true), out)
end)
