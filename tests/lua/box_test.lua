local t = require("dev.testing")
local box = require("dev.cmd.box")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local NOW = 1792000000

local function stamp(offset)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", NOW + offset)
end

local function executable(path, body)
    assert(fs.write(path, body))
    assert(devos.run({ "chmod", "755", path }) == 0, "chmod failed")
end

local function sandbox(listing, shown)
    local root = support.sandbox({}, {})
    assert(fs.write(root .. "/ls.json", listing))
    assert(fs.write(root .. "/show.json", shown or listing))
    executable(
        root .. "/bin/ci",
        '#!/bin/sh\nprintf "ci %s\\n" "$*" >>"'
            .. root
            .. '/calls"\n'
            .. 'if [ "$2" = show ]; then cat "'
            .. root
            .. '/show.json"; else cat "'
            .. root
            .. '/ls.json"; fi\n'
    )
    executable(root .. "/bin/et", '#!/bin/sh\nprintf "et %s\\n" "$*" >>"' .. root .. '/calls"\n')
    return root
end

local function calls(root)
    return fs.read(root .. "/calls") or ""
end

t.test("left counts hours and minutes for a running box", function()
    local running = { state = "running", expires_at = stamp(3 * 3600 + 12 * 60 + 5) }
    t.eq(box.left(running, NOW), "3h12m left")
    t.eq(box.left({ state = "running", expires_at = stamp(90) }, NOW), "1m left")
    t.eq(box.left({ state = "running", expires_at = stamp(-5) }, NOW), "expired")
end)

t.test("left says kept for a running box that does not expire", function()
    t.eq(box.left({ state = "running" }, NOW), "kept")
end)

t.test("left counts days until a stopped box is deleted", function()
    local stopped = { state = "stopped", delete_after = stamp(6 * 86400 + 60) }
    t.eq(box.left(stopped, NOW), "deleted in 6d")
    t.eq(box.left({ state = "stopped", delete_after = stamp(-1) }, NOW), "deleted soon")
    t.eq(box.left({ state = "creating" }, NOW), "")
end)

t.test("left reads an offset and fractional seconds as UTC", function()
    local running = { state = "running", expires_at = "1970-01-01T05:30:00.250+02:00" }
    t.eq(box.left(running, 0), "3h30m left")
    t.eq(box.left({ state = "running", expires_at = "1969-12-31T22:00:00-05:00" }, 0), "3h0m left")
end)

t.test("a box name with a quote and a command substitution is refused before ci runs", function()
    local root = sandbox('{"ok":true,"boxes":[]}')
    local out, code = support.dev(root, { "box", "show", "a'$(touch PWNED)" })
    t.eq(code, 2)
    t.eq(out:find("bad box name", 1, true) ~= nil, true)
    t.eq(calls(root), "")
    t.eq(fs.exists(root .. "/PWNED"), false)
    fs.remove(root, { recursive = true })
end)

t.test("a box name with a leading dash or a newline is refused", function()
    local root = sandbox('{"ok":true,"boxes":[]}')
    local _, code = support.dev(root, { "box", "stop", "a\nb" })
    t.eq(code, 2)
    t.eq(calls(root), "")
    fs.remove(root, { recursive = true })
end)

t.test("a project path with a quote is refused and nothing is run", function()
    local listing = '{"ok":true,"boxes":[{"name":"b1","state":"running","target":"t","projects":'
        .. '[{"name":"p","path":"/srv/projects/a\'b"}],"tailnet_name":"b1"}],'
        .. '"cap":{"running":1,"running_max":3,"memory_limits_gib":1,"memory_max_gib":2}}'
    local root = sandbox(listing)
    local out, code = support.dev(root, { "connect", "b1", "--ssh" })
    t.eq(code, 1)
    t.eq(out:find("refusing the project path", 1, true) ~= nil, true)
    t.eq(calls(root), "ci box ls --json\n")
    fs.remove(root, { recursive = true })
end)

t.test("ls prints plain text with no escape bytes when piped", function()
    local listing = '{"ok":true,"boxes":[{"name":"b1","state":"running","target":"t","machine":"m",'
        .. '"shape":"s","created_by":"agent:x","tmux_sessions":[],"projects":[],"expires_at":null}],'
        .. '"cap":{"running":1,"running_max":3,"memory_limits_gib":1,"memory_max_gib":2},"machines":[]}'
    local root = sandbox(listing)
    local out, code = support.dev(root, { "box", "ls" })
    t.eq(code, 0)
    t.eq(out:find("\27", 1, true), nil)
    t.eq(out:find("Boxes   1 of 3 running · 2 more can start", 1, true) ~= nil, true)
    t.eq(out:find("● b1", 1, true) ~= nil, true)
    fs.remove(root, { recursive = true })
end)

local LEAP_DAY = 1709164800

t.test("left crosses the leap day 2024-02-29 with a fixed now", function()
    t.eq(
        box.left({ state = "running", expires_at = "2024-02-29T12:00:00Z" }, LEAP_DAY),
        "12h0m left"
    )
    t.eq(
        box.left({ state = "stopped", delete_after = "2024-03-01T00:00:00Z" }, LEAP_DAY),
        "deleted in 1d"
    )
    t.eq(
        box.left({ state = "stopped", delete_after = "2024-03-02T00:00:00Z" }, LEAP_DAY),
        "deleted in 2d"
    )
end)

t.test("left reads a +hh:mm offset as the same instant in UTC", function()
    local plus = { state = "running", expires_at = "2024-02-29T14:00:00+02:00" }
    t.eq(box.left(plus, LEAP_DAY), "12h0m left")
    local minus = { state = "running", expires_at = "2024-02-29T07:00:00-05:00" }
    t.eq(box.left(minus, LEAP_DAY), "12h0m left")
end)

t.test("left ignores fractional seconds", function()
    local at = { state = "running", expires_at = "2024-02-29T12:00:00.750Z" }
    t.eq(box.left(at, LEAP_DAY), "12h0m left")
end)

local function listing(user, host)
    local fields = '"name":"b1","state":"running","target":"t","projects":[],'
        .. '"tailnet_name":'
        .. host
        .. ',"ssh_user":'
        .. user
    return '{"ok":true,"box":{'
        .. fields
        .. '},"boxes":[{'
        .. fields
        .. "}],"
        .. '"cap":{"running":1,"running_max":3,"memory_limits_gib":1,"memory_max_gib":2}}'
end

local function refused(user, host, args)
    local root = sandbox(listing(user, host))
    local out, code = support.dev(root, args)
    local ran = calls(root)
    fs.remove(root, { recursive = true })
    return out, code, ran
end

t.test("a plain user and host reach et", function()
    local _, code, ran = refused('"user"', '"b1.example.net"', { "connect", "b1" })
    t.eq(code, 0)
    t.eq(ran:find("et --ssh-option", 1, true) ~= nil, true)
end)

t.test("an ssh_user that starts with a dash is refused before et runs", function()
    local out, code, ran = refused('"-oProxyCommand=x"', '"b1"', { "connect", "b1" })
    t.eq(code, 6)
    t.eq(out:find("invalid ssh_user", 1, true) ~= nil, true)
    t.eq(ran:find("et ", 1, true), nil)
end)

t.test("a tailnet_name with a space or a semicolon is refused before any hand-off", function()
    for _, host in ipairs({ '"b1 x"', '"b1;touch PWNED"', '"-b1"' }) do
        local out, code, ran = refused('"user"', host, { "connect", "b1" })
        t.eq(code, 6)
        t.eq(out:find("invalid tailnet_name", 1, true) ~= nil, true)
        t.eq(ran, "ci box ls --json\n")
    end
    local _, code, ran = refused('"user"', '"a;b"', { "connect", "b1", "--ssh" })
    t.eq(code, 6)
    t.eq(ran, "ci box ls --json\n")
end)

t.test("an ssh_user that is too long is refused", function()
    local _, code = refused('"' .. string.rep("a", 33) .. '"', '"b1"', { "connect", "b1" })
    t.eq(code, 6)
end)
