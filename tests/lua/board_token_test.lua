local bit = require("bit")
local ffi = require("ffi")

local testing = require("dev.testing")
local board = require("dev.board")
local tokenfile = require("dev.board.tokenfile")
local dev_os = require("dev.os")
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
sent=$(cat)
printf '%s\n' "$sent" >>"$ROOT/stdin"
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
    case "$*" in
    *"-X GET"*) [ -f "$ROOT/list.json" ] && body=$(cat "$ROOT/list.json") ;;
    esac
    status=$(cat "$ROOT/children_status" 2>/dev/null || echo 200)
    case "$*" in
    *"-X POST"*) [ -f "$ROOT/post_status" ] && status=$(cat "$ROOT/post_status") ;;
    esac
    ;;
*) body='{}' ;;
esac
if [ -f "$ROOT/expire" ] && printf '%s' "$sent" | grep -q "$(cat "$ROOT/expire")"; then
    body='{"code":"token_expired","message":"expired"}'
    status=401
    if [ -f "$ROOT/swap" ]; then
        cp "$ROOT/swap" "$SWAPTO"
    fi
fi
if [ -f "$ROOT/refuse" ]; then
    body='{"message":"bad"}'
    status=401
fi
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
        DEV_AGENT = opts.agent or "dotfiles/lead/1",
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

testing.test("token mint sends expires_in_hours 8 by default", function()
    local root, home = sandbox()
    local out, code = mint(root, home)
    testing.eq(code, 0, out)
    testing.ok(read(root, "calls"):find('"expires_in_hours":8', 1, true), read(root, "calls"))
end)

testing.test("token mint --hours 3 sends 3 and --hours 9 is a usage error", function()
    -- Send an explicit lifetime through to Pomb
    local root, home = sandbox()
    local out, code = dev(
        root,
        home,
        { "board", "token", "mint", "--role", "implementer", "--as", NAME, "--hours", "3" }
    )
    testing.eq(code, 0, out)
    testing.ok(read(root, "calls"):find('"expires_in_hours":3', 1, true), read(root, "calls"))

    -- Refuse a lifetime outside 1 to 8 before any request
    root, home = sandbox()
    for _, bad in ipairs({ "9", "0", "x" }) do
        out, code = dev(
            root,
            home,
            { "board", "token", "mint", "--role", "implementer", "--as", NAME, "--hours", bad }
        )
        testing.eq(code, 2, out)
        testing.ok(out:find("--hours takes a whole number from 1 to 8", 1, true), out)
    end

    -- Make no call to Pomb for a refused lifetime
    testing.eq(read(root, "calls"), "")
end)

testing.test("token mint names --hours when Pomb refuses the lifetime", function()
    local root, home = sandbox()
    assert(fs.write(root .. "/children_status", "400"))
    assert(
        fs.write(
            root .. "/children.json",
            '{"message":"the owner allows this token\'s children 4 hours at most"}'
        )
    )
    local out, code = mint(root, home)
    testing.eq(code, 1, out)
    testing.ok(out:find("refused the lifetime", 1, true), out)
    testing.ok(out:find("4 hours at most", 1, true), out)
    testing.ok(out:find("--hours", 1, true), out)
end)

testing.test("token-mint-issue finds the role id by name and issues the child as NAME", function()
    local root, home = sandbox()
    local out, code = mint(root, home)
    testing.ok(code == 0, out)
    local calls = read(root, "calls")
    testing.ok(calls:find("/api/v1/agent-roles", 1, true), calls)
    testing.ok(calls:find("-X POST", 1, true), calls)
    testing.ok(calls:find("/api/v1/auth/tokens/children", 1, true), calls)
    testing.ok(calls:find('"role_id":"role-impl"', 1, true), calls)
    testing.ok(calls:find('"name":"' .. NAME .. '"', 1, true), calls)
    testing.ok(read(root, "stdin"):find("Bearer " .. LEAD, 1, true), read(root, "stdin"))
    testing.eq(
        out,
        "minted role implementer as " .. NAME .. ", label agent-3, expires 2100-01-01T00:00:00Z\n"
    )
end)

testing.test(
    "token-mint-lead-role mints a role token for a DEV_AGENT whose role segment is lead",
    function()
        local root, home = sandbox()
        local out, code = mint(root, home, { agent = "dotfiles/lead/82f0e002/1" })
        testing.ok(code == 0, out)
        testing.ok(
            read(root, "calls"):find("/api/v1/auth/tokens/children", 1, true),
            read(root, "calls")
        )
        testing.ok(read(root, "stdin"):find("Bearer " .. LEAD, 1, true), read(root, "stdin"))
    end
)

testing.test("token-mint-silent never prints, logs or passes the token on an argument", function()
    local root, home = sandbox()
    local out, code = mint(root, home)
    testing.ok(code == 0, out)
    testing.eq(out:find(RAW, 1, true), nil, out)
    testing.eq(read(root, "calls"):find(RAW, 1, true), nil)
    testing.eq(read(root, "stdin"):find(RAW, 1, true), nil)
    testing.eq(occurrences(read(root, "calls"), LEAD), 0)
    assert(fs.write(root .. "/children_status", "409"))
    assert(fs.write(root .. "/children.json", '{"message":"' .. RAW .. '"}'))
    out = mint(root, home)
    testing.eq(out:find(RAW, 1, true), nil, out)
end)

testing.test("token-mint-file writes a 0600 file in a 0700 dir named by a hash of NAME", function()
    local root, home = sandbox()
    local runtime = root .. "/run"
    assert(fs.mkdir(runtime, { parents = true }))
    local out, code = mint(root, home, { runtime = runtime })
    testing.ok(code == 0, out)
    local dir = runtime .. "/dev/tokens"
    local files = token_files(dir)
    testing.eq(#files, 1)
    testing.ok(files[1]:find("^%x+$") and #files[1] == 64, files[1])
    testing.eq(files[1]:find("implementer", 1, true), nil)
    testing.eq(mode_of(dir), tonumber("700", 8))
    testing.eq(mode_of(dir .. "/" .. files[1]), tonumber("600", 8))
    testing.eq(fs.read(dir .. "/" .. files[1]), RAW .. "\n" .. EXPIRES .. "\n")
    root, home = sandbox()
    out, code = mint(root, home)
    testing.ok(code == 0, out)
    dir = home .. "/state/dev/tokens"
    files = token_files(dir)
    testing.eq(#files, 1)
    testing.eq(mode_of(dir), tonumber("700", 8))
    testing.eq(mode_of(dir .. "/" .. files[1]), tonumber("600", 8))
end)

testing.test("a token file write that cannot make its directory returns the make reason", function()
    local previous_state = os.getenv("XDG_STATE_HOME") or ""
    local previous_runtime = os.getenv("XDG_RUNTIME_DIR") or ""
    local state = support.tempdir()
    ffi.C.setenv("XDG_RUNTIME_DIR", "", 1)
    ffi.C.setenv("XDG_STATE_HOME", state, 1)
    assert(fs.write(state .. "/dev", "not a directory"))
    local ok, message, reason, detail = tokenfile.write(NAME, RAW, EXPIRES)
    local dir = tokenfile.dir()
    ffi.C.setenv("XDG_STATE_HOME", previous_state, 1)
    ffi.C.setenv("XDG_RUNTIME_DIR", previous_runtime, 1)
    testing.eq({ ok, message, reason, detail }, { nil, nil, board.FileReason.MAKE_DIR, dir })
end)

testing.test("token-mint-write-failure revokes the token it just issued", function()
    local root, home = sandbox()
    assert(fs.mkdir(home .. "/state", { parents = true }))
    assert(fs.write(home .. "/state/dev", "not a directory"))
    assert(fs.write(root .. "/list.json", '[{"id":"tok-child-9","name":"' .. NAME .. '"}]'))
    local out, code = mint(root, home)
    testing.ok(code == 1, out)
    testing.ok(out:find("Cannot make ", 1, true), out)
    testing.ok(out:find("The token was revoked.", 1, true), out)
    testing.eq(out:find("..", 1, true), nil, out)
    local calls = read(root, "calls")
    testing.ok(calls:find("-X DELETE", 1, true), calls)
    testing.ok(calls:find("/api/v1/auth/tokens/children/tok-child-9\n", 1, true), calls)
    testing.eq(read(root, "stdin"):find(RAW, 1, true), nil)
end)

testing.test("token-mint-write-none says Pomb listed no token to revoke", function()
    local root, home = sandbox()
    assert(fs.mkdir(home .. "/state", { parents = true }))
    assert(fs.write(home .. "/state/dev", "not a directory"))
    assert(fs.write(root .. "/list.json", "[]"))
    local out, code = mint(root, home)
    testing.eq(code, 1)
    testing.ok(out:find("Cannot make ", 1, true), out)
    testing.ok(out:find("Pomb listed no token to revoke.", 1, true), out)
    testing.eq(read(root, "calls"):find("-X DELETE", 1, true), nil)
    testing.eq(out:find(RAW, 1, true), nil, out)
end)

testing.test("token-mint-write-stays says the token stays issued when the revoke fails", function()
    local root, home = sandbox()
    assert(fs.mkdir(home .. "/state", { parents = true }))
    assert(fs.write(home .. "/state/dev", "not a directory"))
    assert(fs.write(root .. "/list.json", '[{"id":"tok-child-9","name":"' .. NAME .. '"}]'))
    assert(fs.write(root .. "/revoke_status", "403"))
    assert(fs.write(root .. "/revoke.json", '{"code":"permission_denied","message":"no"}'))
    local out, code = mint(root, home)
    testing.eq(code, 1)
    testing.ok(out:find("Cannot make ", 1, true), out)
    testing.ok(out:find("The token stays issued. ", 1, true), out)
    testing.eq(out:find("The token was revoked.", 1, true), nil, out)
    testing.ok(read(root, "calls"):find("-X DELETE", 1, true), read(root, "calls"))
    testing.eq(out:find(RAW, 1, true), nil, out)
end)

testing.test("token-read-junk returns the not-a-token-file reason and the path", function()
    local previous_state = os.getenv("XDG_STATE_HOME") or ""
    local previous_runtime = os.getenv("XDG_RUNTIME_DIR") or ""
    ffi.C.setenv("XDG_RUNTIME_DIR", "", 1)
    ffi.C.setenv("XDG_STATE_HOME", support.tempdir(), 1)
    assert(fs.mkdir(tokenfile.dir(), { parents = true }))
    local path = assert(tokenfile.path(NAME))
    assert(fs.write(path, "junk\n"))
    local found, message, reason, detail = tokenfile.read(NAME)
    ffi.C.setenv("XDG_STATE_HOME", previous_state, 1)
    ffi.C.setenv("XDG_RUNTIME_DIR", previous_runtime, 1)
    testing.eq(
        { found, message, reason, detail },
        { nil, nil, board.FileReason.NOT_TOKEN_FILE, path }
    )
end)

testing.test("token-mint-sweep deletes expired token files and keeps live ones", function()
    local root, home = sandbox()
    local dir = home .. "/state/dev/tokens"
    assert(fs.mkdir(dir, { parents = true }))
    assert(fs.write(dir .. "/expired", "pomb_OLD0123456789\n1\n"))
    assert(fs.write(dir .. "/live", "pomb_LIVE0123456789\n" .. EXPIRES .. "\n"))
    local out, code = mint(root, home)
    testing.ok(code == 0, out)
    testing.eq(fs.exists(dir .. "/expired"), false)
    testing.eq(fs.exists(dir .. "/live"), true)
    testing.eq(#token_files(dir), 2)
end)

testing.test(
    "token-status-counts counts files near expiry and expired, and names no token",
    function()
        local root, home = sandbox()
        local dir = home .. "/state/dev/tokens"
        assert(fs.mkdir(dir, { parents = true }))
        assert(fs.write(dir .. "/expired", "pomb_OLD0123456789\n1\n"))
        assert(fs.write(dir .. "/soon", "pomb_SOON0123456789\n" .. os.time() + 600 .. "\n"))
        assert(fs.write(dir .. "/live", "pomb_LIVE0123456789\n" .. EXPIRES .. "\n"))
        local out, code = dev(root, home, { "board", "status" })
        testing.ok(code == 0, out)
        testing.ok(out:find("tokens: 1 expire within an hour, 1 expired", 1, true), out)
        testing.eq(out:find("pomb_", 1, true), nil, out)
    end
)

testing.test("token-status-quiet prints no tokens line when every file is live", function()
    local root, home = sandbox()
    local dir = home .. "/state/dev/tokens"
    assert(fs.mkdir(dir, { parents = true }))
    assert(fs.write(dir .. "/live", "pomb_LIVE0123456789\n" .. EXPIRES .. "\n"))
    local out, code = dev(root, home, { "board", "status" })
    testing.ok(code == 0, out)
    testing.eq(out:find("tokens:", 1, true), nil, out)
end)

testing.test(
    "token-mint-refused shows an unknown role, exceeds_grant and a taken name in words",
    function()
        local root, home = sandbox()
        local out, code =
            dev(root, home, { "board", "token", "mint", "--role", "ghost", "--as", NAME })
        testing.ok(code == 1, out)
        testing.ok(out:find("no agent role named ghost", 1, true), out)
        testing.ok(out:find("implementer, reviewer", 1, true), out)
        assert(fs.write(root .. "/children_status", "400"))
        assert(
            fs.write(
                root .. "/children.json",
                '{"code":"unknown_role","message":"no such agent role"}'
            )
        )
        out, code = mint(root, home)
        testing.ok(code == 1, out)
        testing.ok(out:find("no agent role named implementer", 1, true), out)
        assert(fs.write(root .. "/children_status", "403"))
        assert(fs.write(root .. "/children.json", '{"code":"exceeds_grant","message":"tasks.bin"}'))
        out, code = mint(root, home)
        testing.ok(code == 1, out)
        testing.ok(out:find("cannot issue the implementer role", 1, true), out)
        testing.ok(out:find("tasks.bin", 1, true), out)
        assert(fs.write(root .. "/children_status", "409"))
        assert(
            fs.write(
                root .. "/children.json",
                '{"message":"another token of the account has that name"}'
            )
        )
        out, code = mint(root, home)
        testing.ok(code == 1, out)
        testing.ok(out:find("Another token already has the name " .. NAME, 1, true), out)
        testing.eq(fs.exists(home .. "/state/dev/tokens"), false)
        out, code = mint(root, home, { agent = "dotfiles/implementer/other/1" })
        testing.ok(code == 1, out)
        testing.ok(out:find("Only the lead mints a role token", 1, true), out)
        out, code = dev(root, home, { "board", "token", "mint", "--role", "implementer" })
        testing.ok(code == 2, out)
    end
)

local function minted()
    local root, home = sandbox()
    local out, code = mint(root, home)
    testing.ok(code == 0, out)
    assert(fs.write(root .. "/calls", ""))
    assert(fs.write(root .. "/stdin", ""))
    return root, home
end

testing.test(
    "token-lookup-order reads DEV_BOARD_TOKEN, then the file for DEV_AGENT, then pass",
    function()
        local root, home = minted()
        local out, code = dev(root, home, { "board", "boards" }, {
            agent = NAME,
            env = { DEV_BOARD_TOKEN = ENV_TOKEN },
        })
        testing.ok(code == 0, out)
        testing.ok(read(root, "stdin"):find("Bearer " .. ENV_TOKEN, 1, true), read(root, "stdin"))
        testing.eq(read(root, "stdin"):find(RAW, 1, true), nil)
        testing.eq(occurrences(read(root, "calls"), "pass show"), 0)
        assert(fs.write(root .. "/stdin", ""))
        out, code = dev(root, home, { "board", "boards" }, { agent = NAME })
        testing.ok(code == 0, out)
        testing.ok(read(root, "stdin"):find("Bearer " .. RAW, 1, true), read(root, "stdin"))
        testing.eq(occurrences(read(root, "calls"), "pass show"), 0)
        assert(fs.write(root .. "/stdin", ""))
        out, code = dev(
            root,
            home,
            { "board", "boards" },
            { agent = "dotfiles/implementer/other/1" }
        )
        testing.ok(code == 0, out)
        testing.ok(read(root, "stdin"):find("Bearer " .. WORKER, 1, true), read(root, "stdin"))
        assert(fs.write(root .. "/stdin", ""))
        out, code = dev(root, home, { "board", "boards" })
        testing.ok(code == 0, out)
        testing.ok(read(root, "stdin"):find("Bearer " .. WORKER, 1, true), read(root, "stdin"))
    end
)

testing.test("token-lookup-refused never retries a refused file token with pass", function()
    local root, home = minted()
    assert(fs.write(root .. "/refuse", ""))
    local out, code = dev(root, home, { "board", "boards" }, { agent = NAME })
    testing.ok(code == 1, out)
    testing.ok(out:find("role token file for DEV_AGENT was refused", 1, true), out)
    testing.eq(occurrences(read(root, "calls"), "pass show"), 0)
    testing.eq(out:find(RAW, 1, true), nil, out)
    testing.eq(read(root, "calls"):find(RAW, 1, true), nil)
    assert(fs.remove(root .. "/refuse"))
    local dir = home .. "/state/dev/tokens"
    assert(fs.write(dir .. "/" .. token_files(dir)[1], RAW .. "\n1\n"))
    out, code = dev(root, home, { "board", "boards" }, { agent = NAME })
    testing.ok(code == 1, out)
    testing.ok(out:find("expired", 1, true), out)
    testing.eq(occurrences(read(root, "calls"), "pass show"), 0)
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

testing.test(
    "token-revoke-issue finds the child by NAME in the lead's list and revokes it",
    function()
        local root, home = minted()
        listed(root, NAME)
        local out, code = revoke(root, home)
        testing.ok(code == 0, out)
        testing.eq(out, "revoked the role token of " .. NAME .. "\n")
        local calls = read(root, "calls")
        local listing = calls:find("-X GET", 1, true)
        local revoking = calls:find("-X DELETE", 1, true)
        testing.ok(listing and revoking and listing < revoking, calls)
        testing.ok(calls:find("/api/v1/auth/tokens/children/" .. CHILD_ID .. "\n", 1, true), calls)
        testing.eq(calls:find("tok-other", 1, true), nil, calls)
        testing.ok(read(root, "stdin"):find("Bearer " .. LEAD, 1, true), read(root, "stdin"))
        testing.eq(read(root, "stdin"):find(RAW, 1, true), nil)
        out, code = revoke(root, home, { agent = "dotfiles/implementer/other/1" })
        testing.ok(code == 1, out)
        testing.ok(out:find("Only the lead revokes a role token", 1, true), out)
        out, code = dev(root, home, { "board", "token", "revoke" })
        testing.ok(code == 2, out)
    end
)

testing.test(
    "token-revoke-file deletes the file after Pomb accepts and keeps it when Pomb refuses",
    function()
        local root, home = minted()
        listed(root, NAME)
        local dir = home .. "/state/dev/tokens"
        assert(fs.write(root .. "/revoke_status", "403"))
        assert(fs.write(root .. "/revoke.json", '{"code":"permission_denied","message":"no"}'))
        local out, code = revoke(root, home)
        testing.ok(code == 1, out)
        testing.eq(#token_files(dir), 1)
        assert(fs.remove(root .. "/revoke_status"))
        assert(fs.write(root .. "/revoke.json", '{"revoked":"' .. CHILD_ID .. '"}'))
        out, code = revoke(root, home)
        testing.ok(code == 0, out)
        testing.eq(#token_files(dir), 0)
    end
)

testing.test("token-revoke-none exits 0 for an unknown or already revoked name", function()
    local root, home = minted()
    local dir = home .. "/state/dev/tokens"
    listed(root, "dotfiles/reviewer/another/1")
    local out, code = revoke(root, home)
    testing.ok(code == 0, out)
    testing.eq(out, "Nothing was left to revoke for " .. NAME .. ".\n")
    testing.eq(read(root, "calls"):find("-X DELETE", 1, true), nil)
    testing.eq(#token_files(dir), 0)
    root, home = minted()
    listed(root, NAME)
    assert(fs.write(root .. "/revoke_status", "404"))
    assert(fs.write(root .. "/revoke.json", '{"message":"no such child token"}'))
    out, code = revoke(root, home)
    testing.ok(code == 0, out)
    testing.eq(out, "Nothing was left to revoke for " .. NAME .. ".\n")
    testing.eq(#token_files(home .. "/state/dev/tokens"), 0)
end)

local NEW = "pomb_NEWROLEtoken0123456789"

local function filed_path(home)
    local dir = home .. "/state/dev/tokens"
    return dir .. "/" .. token_files(dir)[1]
end

local function curl_calls(root)
    return occurrences(read(root, "calls"), "curl ")
end

testing.test("token-remint-retry retries once with the new token the file holds", function()
    local root, home = minted()
    local path = filed_path(home)
    assert(fs.write(root .. "/expire", RAW))
    assert(fs.write(root .. "/swap", NEW .. "\n" .. EXPIRES .. "\n"))
    local out, code = dev(root, home, { "board", "boards" }, {
        agent = NAME,
        env = { SWAPTO = path },
    })
    testing.ok(code == 0, out)
    testing.eq(occurrences(read(root, "stdin"), "Bearer " .. RAW), 1)
    local sent = read(root, "stdin")
    local old = sent:find("Bearer " .. RAW, 1, true)
    local new = sent:find("Bearer " .. NEW, 1, true)
    testing.ok(old and new and old < new, sent)
end)

testing.test("token-remint-stale fails with the expired message and no second retry", function()
    local root, home = minted()
    assert(fs.write(root .. "/expire", RAW))
    assert(fs.write(root .. "/swap", RAW .. "\n" .. EXPIRES .. "\n"))
    local out, code = dev(root, home, { "board", "boards" }, {
        agent = NAME,
        env = { SWAPTO = filed_path(home) },
    })
    testing.ok(code == 1, out)
    testing.ok(out:find("expired", 1, true), out)
    testing.eq(curl_calls(root), 2)
    testing.eq(out:find(RAW, 1, true), nil, out)
end)

testing.test("token-remint-env never retries an expired env or pass token from the file", function()
    local root, home = minted()
    assert(fs.write(root .. "/expire", ENV_TOKEN))
    assert(fs.write(root .. "/swap", NEW .. "\n" .. EXPIRES .. "\n"))
    local out, code = dev(root, home, { "board", "boards" }, {
        agent = NAME,
        env = { DEV_BOARD_TOKEN = ENV_TOKEN, SWAPTO = filed_path(home) },
    })
    testing.ok(code == 1, out)
    testing.ok(out:find("expired", 1, true), out)
    testing.eq(curl_calls(root), 2)
    testing.eq(read(root, "stdin"):find(NEW, 1, true), nil)
    root, home = minted()
    assert(fs.write(root .. "/expire", WORKER))
    assert(fs.write(root .. "/swap", NEW .. "\n" .. EXPIRES .. "\n"))
    out, code = dev(root, home, { "board", "boards" }, {
        env = { SWAPTO = filed_path(home) },
    })
    testing.ok(code == 1, out)
    testing.ok(out:find("expired", 1, true), out)
    testing.eq(curl_calls(root), 2)
    testing.eq(read(root, "stdin"):find(NEW, 1, true), nil)
end)

testing.test(
    "token-remint-name replaces the file under the same name and refuses a live clash",
    function()
        local root, home = minted()
        local path = filed_path(home)
        assert(fs.write(root .. "/children.json", (CREATED:gsub(RAW, NEW))))
        assert(fs.write(root .. "/calls", ""))
        local out, code = mint(root, home)
        testing.ok(code == 0, out)
        testing.eq(occurrences(read(root, "calls"), '"name":"' .. NAME .. '"'), 1)
        testing.eq(#token_files(home .. "/state/dev/tokens"), 1)
        testing.eq(filed_path(home), path)
        testing.eq(fs.read(path), NEW .. "\n" .. EXPIRES .. "\n")
        assert(fs.write(root .. "/children_status", "409"))
        assert(
            fs.write(
                root .. "/children.json",
                '{"code":"name_taken","message":"a live token has that name"}'
            )
        )
        out, code = mint(root, home)
        testing.ok(code == 1, out)
        testing.ok(out:find("Another token already has the name " .. NAME, 1, true), out)
        testing.eq(fs.read(path), NEW .. "\n" .. EXPIRES .. "\n")
    end
)

local function renewing(root)
    assert(
        fs.write(
            root .. "/list.json",
            '[{"id":"tok-other","name":"dotfiles/reviewer/other/1"},{"id":"'
                .. CHILD_ID
                .. '","name":"'
                .. NAME
                .. '"}]'
        )
    )
    assert(fs.write(root .. "/calls", ""))
end

local function renew(root, home)
    return dev(
        root,
        home,
        { "board", "token", "mint", "--role", "implementer", "--as", NAME, "--renew" }
    )
end

testing.test("token mint renew replaces a live token and never deletes its file", function()
    local root, home = minted()
    local path = filed_path(home)
    assert(fs.write(root .. "/children.json", (CREATED:gsub(RAW, NEW))))
    renewing(root)

    -- Renew once and expect the delete before the issue
    local out, code = renew(root, home)
    testing.ok(code == 0, out)
    local calls = read(root, "calls")
    local deleting = calls:find("/api/v1/auth/tokens/children/" .. CHILD_ID .. "\n", 1, true)
    local posting = calls:find("-X POST", 1, true)
    testing.ok(deleting and posting and deleting < posting, calls)
    testing.eq(calls:find("tok-other", 1, true), nil, calls)
    testing.eq(filed_path(home), path)
    testing.eq(fs.read(path), NEW .. "\n" .. EXPIRES .. "\n")

    -- Refuse the issue after the delete and keep the file
    assert(fs.write(root .. "/post_status", "409"))
    assert(fs.write(root .. "/children.json", '{"code":"name_taken","message":"taken"}'))
    out, code = renew(root, home)
    testing.ok(code == 1, out)
    testing.ok(out:find("The old token was already deleted", 1, true), out)
    testing.eq(fs.read(path), NEW .. "\n" .. EXPIRES .. "\n")
end)

testing.test("token mint renew with no live token still mints", function()
    local root, home = minted()
    assert(
        fs.write(root .. "/list.json", '[{"id":"tok-other","name":"dotfiles/reviewer/other/1"}]')
    )
    assert(fs.write(root .. "/calls", ""))
    local out, code = renew(root, home)
    testing.ok(code == 0, out)
    testing.eq(read(root, "calls"):find("-X DELETE", 1, true), nil, read(root, "calls"))
    testing.ok(read(root, "calls"):find("-X POST", 1, true), read(root, "calls"))
end)

testing.test("token mint renew issues nothing when the delete fails", function()
    local root, home = minted()
    local path = filed_path(home)
    renewing(root)
    assert(fs.write(root .. "/revoke_status", "403"))
    assert(fs.write(root .. "/revoke.json", '{"code":"permission_denied","message":"no"}'))
    local out, code = renew(root, home)
    testing.ok(code == 1, out)
    testing.eq(read(root, "calls"):find("-X POST", 1, true), nil, read(root, "calls"))
    testing.eq(fs.read(path), RAW .. "\n" .. EXPIRES .. "\n")
end)

testing.test("token mint without renew still refuses a live name and deletes nothing", function()
    local root, home = minted()
    local path = filed_path(home)
    renewing(root)
    assert(fs.write(root .. "/children_status", "409"))
    assert(fs.write(root .. "/children.json", '{"code":"name_taken","message":"taken"}'))
    local out, code = mint(root, home)
    testing.ok(code == 1, out)
    testing.ok(out:find("Another token already has the name " .. NAME, 1, true), out)
    testing.eq(read(root, "calls"):find("-X DELETE", 1, true), nil, read(root, "calls"))
    testing.eq(fs.read(path), RAW .. "\n" .. EXPIRES .. "\n")
end)
