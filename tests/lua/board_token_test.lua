local bit = require("bit")

local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local LEAD = "pomb_LEADtoken0123456789"
local WORKER = "pomb_WORKERtoken0123456789"
local RAW = "pomb_ROLEtoken0123456789"
local ENV_TOKEN = "pomb_ENVtoken0123456789"
local NAME = "dotfiles/implementer/72f0e012/1"
local EXPIRES = 4102444800
local ROLES = '[{"id":"role-impl","name":"implementer"},{"id":"role-rev","name":"reviewer"}]'
local CREATED = '{"name":"'
    .. NAME
    .. '","role_name":"implementer","label":"agent-3","expires_at":'
    .. EXPIRES
    .. ',"raw_token":"'
    .. RAW
    .. '"}'
local USER = '[board.pomb]\nurl = "https://pomb.example"\ntoken = "pass:secrets/worker/token/pomb"\n'
    .. 'lead_token = "pass:secrets/lead/token/pomb"\n'

local CURL = [[#!/bin/sh
printf 'curl %s\n' "$*" >>"$ROOT/calls"
cat >>"$ROOT/stdin"
printf '\n' >>"$ROOT/stdin"
for last; do :; done
status=200
case "$last" in
*/api/boards) body='[{"id":"board-1","name":"dotfiles","archived":false}]' ;;
*/api/boards/board-1) body='{"id":"board-1","name":"dotfiles","swimlanes":[],"columns":[{"id":"c1","name":"Ready"},{"id":"c2","name":"Done","is_done":true}]}' ;;
*/auth/whoami) body='{"role_name":null}' ;;
*/agent-roles) body=$(cat "$ROOT/roles.json") ;;
*/auth/tokens/children/*)
    body=$(cat "$ROOT/revoke.json" 2>/dev/null || echo '{}')
    status=$(cat "$ROOT/revoke_status" 2>/dev/null || echo 200)
    ;;
*/auth/tokens/children)
    body=$(cat "$ROOT/children.json")
    status=$(cat "$ROOT/children_status" 2>/dev/null || echo 200)
    ;;
*) body='{}' ;;
esac
if [ -f "$ROOT/refuse" ]; then
    body='{"message":"bad"}'
    status=401
fi
printf '%s\n%s' "$body" "$status"
]]

local function executable(path, body)
    assert(fs.write(path, body))
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function sandbox()
    local root = support.sandbox({
        [".dev/config.toml"] = '[board]\nbackend = "pomb"\nname = "dotfiles"\n',
    }, {})
    local home = support.tempdir()
    assert(fs.mkdir(home .. "/.config/dev", { parents = true }))
    assert(fs.write(home .. "/.config/dev/config.toml", USER))
    assert(fs.write(root .. "/roles.json", ROLES))
    assert(fs.write(root .. "/children.json", CREATED))
    executable(root .. "/bin/curl", CURL)
    executable(root .. "/bin/security", "#!/bin/sh\nexit 1\n")
    executable(
        root .. "/bin/pass",
        '#!/bin/sh\nprintf "pass %s\\n" "$*" >>"$ROOT/calls"\n'
            .. 'case "$*" in *Lead*) echo "'
            .. LEAD
            .. '" ;; *) echo "'
            .. WORKER
            .. '" ;; esac\n'
    )
    return root, home
end

local function dev(root, home, args, opts)
    opts = opts or {}
    local env = {
        HOME = home,
        ROOT = root,
        XDG_STATE_HOME = home .. "/state",
        XDG_RUNTIME_DIR = opts.runtime or "",
        CI = "",
        DEV_AGENT = opts.agent or "",
        DEV_PASS_LOCK = root .. "/pass.lock",
    }
    for name, value in pairs(opts.env or {}) do
        env[name] = value
    end
    return support.dev(root, args, { env = env })
end

local function read(root, name)
    return fs.read(root .. "/" .. name) or ""
end

local function occurrences(text, word)
    local count, at = 0, 1
    while true do
        local from, to = text:find(word, at, true)
        if not from then
            return count
        end
        count, at = count + 1, to + 1
    end
end

local function mint(root, home, opts)
    return dev(
        root,
        home,
        { "board", "token", "mint", "--role", "implementer", "--as", NAME },
        opts
    )
end

local function token_files(dir)
    return fs.list(dir) or {}
end

local function mode_of(path)
    return bit.band(fs.stat(path).mode, tonumber("777", 8))
end

t.test("token-mint-issue finds the role id by name and issues the child as NAME", function()
    local root, home = sandbox()
    local out, code = mint(root, home)
    t.ok(code == 0, out)
    local calls = read(root, "calls")
    t.ok(calls:find("/api/v1/agent-roles", 1, true), calls)
    t.ok(calls:find("-X POST", 1, true), calls)
    t.ok(calls:find("/api/v1/auth/tokens/children", 1, true), calls)
    t.ok(calls:find('"role_id":"role-impl"', 1, true), calls)
    t.ok(calls:find('"name":"' .. NAME .. '"', 1, true), calls)
    t.ok(read(root, "stdin"):find("Bearer " .. LEAD, 1, true), read(root, "stdin"))
    t.eq(
        out,
        "minted role implementer as " .. NAME .. ", label agent-3, expires 2100-01-01T00:00:00Z\n"
    )
end)

t.test(
    "token-mint-lead-role mints a role token for a DEV_AGENT whose role segment is lead",
    function()
        local root, home = sandbox()
        local out, code = mint(root, home, { agent = "dotfiles/lead/82f0e002/1" })
        t.ok(code == 0, out)
        t.ok(read(root, "calls"):find("/api/v1/auth/tokens/children", 1, true), read(root, "calls"))
        t.ok(read(root, "stdin"):find("Bearer " .. LEAD, 1, true), read(root, "stdin"))
    end
)

t.test("token-mint-silent never prints, logs or passes the token on an argument", function()
    local root, home = sandbox()
    local out, code = mint(root, home)
    t.ok(code == 0, out)
    t.eq(out:find(RAW, 1, true), nil, out)
    t.eq(read(root, "calls"):find(RAW, 1, true), nil)
    t.eq(read(root, "stdin"):find(RAW, 1, true), nil)
    t.eq(occurrences(read(root, "calls"), LEAD), 0)
    assert(fs.write(root .. "/children_status", "409"))
    assert(fs.write(root .. "/children.json", '{"message":"' .. RAW .. '"}'))
    out = mint(root, home)
    t.eq(out:find(RAW, 1, true), nil, out)
end)

t.test("token-mint-file writes a 0600 file in a 0700 dir named by a hash of NAME", function()
    local root, home = sandbox()
    local runtime = root .. "/run"
    assert(fs.mkdir(runtime, { parents = true }))
    local out, code = mint(root, home, { runtime = runtime })
    t.ok(code == 0, out)
    local dir = runtime .. "/dev/tokens"
    local files = token_files(dir)
    t.eq(#files, 1)
    t.ok(files[1]:find("^%x+$") and #files[1] == 64, files[1])
    t.eq(files[1]:find("implementer", 1, true), nil)
    t.eq(mode_of(dir), tonumber("700", 8))
    t.eq(mode_of(dir .. "/" .. files[1]), tonumber("600", 8))
    t.eq(fs.read(dir .. "/" .. files[1]), RAW .. "\n" .. EXPIRES .. "\n")
    root, home = sandbox()
    out, code = mint(root, home)
    t.ok(code == 0, out)
    dir = home .. "/state/dev/tokens"
    files = token_files(dir)
    t.eq(#files, 1)
    t.eq(mode_of(dir), tonumber("700", 8))
    t.eq(mode_of(dir .. "/" .. files[1]), tonumber("600", 8))
end)

t.test("token-mint-sweep deletes expired token files and keeps live ones", function()
    local root, home = sandbox()
    local dir = home .. "/state/dev/tokens"
    assert(fs.mkdir(dir, { parents = true }))
    assert(fs.write(dir .. "/expired", "pomb_OLD0123456789\n1\n"))
    assert(fs.write(dir .. "/live", "pomb_LIVE0123456789\n" .. EXPIRES .. "\n"))
    local out, code = mint(root, home)
    t.ok(code == 0, out)
    t.eq(fs.exists(dir .. "/expired"), false)
    t.eq(fs.exists(dir .. "/live"), true)
    t.eq(#token_files(dir), 2)
end)

t.test(
    "token-mint-refused shows an unknown role, exceeds_grant and a taken name in words",
    function()
        local root, home = sandbox()
        local out, code =
            dev(root, home, { "board", "token", "mint", "--role", "ghost", "--as", NAME })
        t.ok(code == 1, out)
        t.ok(out:find("no agent role named ghost", 1, true), out)
        t.ok(out:find("implementer, reviewer", 1, true), out)
        assert(fs.write(root .. "/children_status", "400"))
        assert(
            fs.write(
                root .. "/children.json",
                '{"code":"unknown_role","message":"no such agent role"}'
            )
        )
        out, code = mint(root, home)
        t.ok(code == 1, out)
        t.ok(out:find("no agent role named implementer", 1, true), out)
        assert(fs.write(root .. "/children_status", "403"))
        assert(fs.write(root .. "/children.json", '{"code":"exceeds_grant","message":"tasks.bin"}'))
        out, code = mint(root, home)
        t.ok(code == 1, out)
        t.ok(out:find("cannot issue the implementer role", 1, true), out)
        t.ok(out:find("tasks.bin", 1, true), out)
        assert(fs.write(root .. "/children_status", "409"))
        assert(
            fs.write(
                root .. "/children.json",
                '{"message":"another token of the account has that name"}'
            )
        )
        out, code = mint(root, home)
        t.ok(code == 1, out)
        t.ok(out:find("another token already has the name " .. NAME, 1, true), out)
        t.eq(fs.exists(home .. "/state/dev/tokens"), false)
        out, code = mint(root, home, { agent = "dotfiles/implementer/other/1" })
        t.ok(code == 1, out)
        t.ok(out:find("only the lead mints a role token", 1, true), out)
        out, code = dev(root, home, { "board", "token", "mint", "--role", "implementer" })
        t.ok(code == 2, out)
    end
)

local function minted()
    local root, home = sandbox()
    local out, code = mint(root, home)
    t.ok(code == 0, out)
    assert(fs.write(root .. "/calls", ""))
    assert(fs.write(root .. "/stdin", ""))
    return root, home
end

t.test(
    "token-lookup-order reads DEV_BOARD_TOKEN, then the file for DEV_AGENT, then pass",
    function()
        local root, home = minted()
        local out, code = dev(root, home, { "board", "boards" }, {
            agent = NAME,
            env = { DEV_BOARD_TOKEN = ENV_TOKEN },
        })
        t.ok(code == 0, out)
        t.ok(read(root, "stdin"):find("Bearer " .. ENV_TOKEN, 1, true), read(root, "stdin"))
        t.eq(read(root, "stdin"):find(RAW, 1, true), nil)
        t.eq(occurrences(read(root, "calls"), "pass show"), 0)
        assert(fs.write(root .. "/stdin", ""))
        out, code = dev(root, home, { "board", "boards" }, { agent = NAME })
        t.ok(code == 0, out)
        t.ok(read(root, "stdin"):find("Bearer " .. RAW, 1, true), read(root, "stdin"))
        t.eq(occurrences(read(root, "calls"), "pass show"), 0)
        assert(fs.write(root .. "/stdin", ""))
        out, code = dev(
            root,
            home,
            { "board", "boards" },
            { agent = "dotfiles/implementer/other/1" }
        )
        t.ok(code == 0, out)
        t.ok(read(root, "stdin"):find("Bearer " .. WORKER, 1, true), read(root, "stdin"))
        assert(fs.write(root .. "/stdin", ""))
        out, code = dev(root, home, { "board", "boards" })
        t.ok(code == 0, out)
        t.ok(read(root, "stdin"):find("Bearer " .. WORKER, 1, true), read(root, "stdin"))
    end
)

t.test("token-lookup-refused never retries a refused file token with pass", function()
    local root, home = minted()
    assert(fs.write(root .. "/refuse", ""))
    local out, code = dev(root, home, { "board", "boards" }, { agent = NAME })
    t.ok(code == 1, out)
    t.ok(out:find("role token file for DEV_AGENT was refused", 1, true), out)
    t.eq(occurrences(read(root, "calls"), "pass show"), 0)
    t.eq(out:find(RAW, 1, true), nil, out)
    t.eq(read(root, "calls"):find(RAW, 1, true), nil)
    assert(fs.remove(root .. "/refuse"))
    local dir = home .. "/state/dev/tokens"
    assert(fs.write(dir .. "/" .. token_files(dir)[1], RAW .. "\n1\n"))
    out, code = dev(root, home, { "board", "boards" }, { agent = NAME })
    t.ok(code == 1, out)
    t.ok(out:find("expired", 1, true), out)
    t.eq(occurrences(read(root, "calls"), "pass show"), 0)
end)

local CHILD_ID = "tok-child-7"

local function revoke(root, home, opts)
    return dev(root, home, { "board", "token", "revoke", "--as", NAME }, opts)
end

local function listed(root, name)
    assert(
        fs.write(
            root .. "/children.json",
            '[{"id":"tok-other","name":"dotfiles/reviewer/other/1"},{"id":"'
                .. CHILD_ID
                .. '","name":"'
                .. name
                .. '"}]'
        )
    )
end

t.test("token-revoke-issue finds the child by NAME in the lead's list and revokes it", function()
    local root, home = minted()
    listed(root, NAME)
    local out, code = revoke(root, home)
    t.ok(code == 0, out)
    t.eq(out, "revoked the role token of " .. NAME .. "\n")
    local calls = read(root, "calls")
    local listing = calls:find("-X GET", 1, true)
    local revoking = calls:find("-X DELETE", 1, true)
    t.ok(listing and revoking and listing < revoking, calls)
    t.ok(calls:find("/api/v1/auth/tokens/children/" .. CHILD_ID .. "\n", 1, true), calls)
    t.eq(calls:find("tok-other", 1, true), nil, calls)
    t.ok(read(root, "stdin"):find("Bearer " .. LEAD, 1, true), read(root, "stdin"))
    t.eq(read(root, "stdin"):find(RAW, 1, true), nil)
    out, code = revoke(root, home, { agent = "dotfiles/implementer/other/1" })
    t.ok(code == 1, out)
    t.ok(out:find("only the lead revokes a role token", 1, true), out)
    out, code = dev(root, home, { "board", "token", "revoke" })
    t.ok(code == 2, out)
end)

t.test(
    "token-revoke-file deletes the file after Pomb accepts and keeps it when Pomb refuses",
    function()
        local root, home = minted()
        listed(root, NAME)
        local dir = home .. "/state/dev/tokens"
        assert(fs.write(root .. "/revoke_status", "403"))
        assert(fs.write(root .. "/revoke.json", '{"code":"permission_denied","message":"no"}'))
        local out, code = revoke(root, home)
        t.ok(code == 1, out)
        t.eq(#token_files(dir), 1)
        assert(fs.remove(root .. "/revoke_status"))
        assert(fs.write(root .. "/revoke.json", '{"revoked":"' .. CHILD_ID .. '"}'))
        out, code = revoke(root, home)
        t.ok(code == 0, out)
        t.eq(#token_files(dir), 0)
    end
)

t.test("token-revoke-none exits 0 for an unknown or already revoked name", function()
    local root, home = minted()
    local dir = home .. "/state/dev/tokens"
    listed(root, "dotfiles/reviewer/another/1")
    local out, code = revoke(root, home)
    t.ok(code == 0, out)
    t.eq(out, "nothing was left to revoke for " .. NAME .. "\n")
    t.eq(read(root, "calls"):find("-X DELETE", 1, true), nil)
    t.eq(#token_files(dir), 0)
    root, home = minted()
    listed(root, NAME)
    assert(fs.write(root .. "/revoke_status", "404"))
    assert(fs.write(root .. "/revoke.json", '{"message":"no such child token"}'))
    out, code = revoke(root, home)
    t.ok(code == 0, out)
    t.eq(out, "nothing was left to revoke for " .. NAME .. "\n")
    t.eq(#token_files(home .. "/state/dev/tokens"), 0)
end)
