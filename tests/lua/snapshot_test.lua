local testing = require("dev.testing")
local fs = require("dev.fs")
local snapshot = require("devrepo.snapshot")
local support = require("support")

local DIRS = { lua = true, docs = true, init = true, board = true }

local function tree(label)
    local dir = support.tempdir()
    local share = dir .. "/share"
    assert(fs.mkdir(share, { parents = true }))
    for _, name in ipairs(snapshot.SHARE) do
        local path = share .. "/" .. name
        if DIRS[name] then
            assert(fs.mkdir(path))
        else
            assert(fs.write(path, name .. "\n"))
        end
    end
    assert(fs.write(share .. "/main.lua", "-- " .. label .. "\n"))
    assert(fs.write(share .. "/lua/mod.lua", 'return "' .. label .. '"\n'))
    return share, dir .. "/snapshot"
end

local function resolved(dir)
    return assert(fs.realpath(dir .. "/current"))
end

testing.test("snapshot-dir lives in the dev state directory", function()
    testing.ok(snapshot.dir():find("/dev/snapshot$"), snapshot.dir())
end)

testing.test("snapshot-publish copies the tree and points current at the copy", function()
    local share, dir = tree("one")
    local version = assert(snapshot.publish(share, dir))
    testing.eq(fs.read(version .. "/main.lua"), "-- one\n")
    testing.eq(fs.read(dir .. "/current/lua/mod.lua"), 'return "one"\n')
    testing.eq(fs.read(dir .. "/current/ORIGIN"), share .. "\n")
    testing.eq(resolved(dir), assert(fs.realpath(version)))
    assert(fs.write(share .. "/main.lua", "-- edited\n"))
    testing.eq(fs.read(dir .. "/current/main.lua"), "-- one\n")
end)

testing.test("snapshot-publish copies only the share set", function()
    local share, dir = tree("one")
    assert(fs.mkdir(share .. "/tests"))
    assert(fs.write(share .. "/README.md", "readme\n"))
    local version = assert(snapshot.publish(share, dir))
    local want = { "ORIGIN" }
    for _, name in ipairs(snapshot.SHARE) do
        want[#want + 1] = name
    end
    table.sort(want)
    testing.eq(fs.list(version), want)
end)

testing.test(
    "snapshot-swap renames a link over current and leaves the old version whole",
    function()
        local share, dir = tree("one")
        local first = assert(snapshot.publish(share, dir))
        assert(fs.write(share .. "/lua/mod.lua", 'return "two"\n'))
        local second = assert(snapshot.publish(share, dir))
        testing.ok(first ~= second, "each publish makes its own version directory")
        testing.eq(resolved(dir), assert(fs.realpath(second)))
        testing.eq(fs.read(first .. "/lua/mod.lua"), 'return "one"\n')
        testing.eq(fs.read(dir .. "/current/lua/mod.lua"), 'return "two"\n')
        testing.ok(fs.is_link(dir .. "/current"), "current stays a symlink")
        testing.eq(fs.list(dir), { "current", "versions" })
    end
)

testing.test("snapshot-prune keeps the newest three versions", function()
    local share, dir = tree("one")
    local made = {}
    for index = 1, 5 do
        made[index] = fs.basename(assert(snapshot.publish(share, dir)))
    end
    testing.eq(fs.list(dir .. "/versions"), { made[3], made[4], made[5] })
    testing.eq(resolved(dir), assert(fs.realpath(dir .. "/versions/" .. made[5])))
end)

testing.test("snapshot-fail leaves current alone when the source is missing", function()
    local share, dir = tree("one")
    local first = assert(snapshot.publish(share, dir))
    local version, message = snapshot.publish(dir .. "/nowhere", dir)
    testing.eq(version, nil)
    testing.ok(message ~= nil, "a failure says why")
    testing.eq(resolved(dir), assert(fs.realpath(first)))
    testing.eq(#assert(fs.list(dir .. "/versions")), 1)
    testing.eq(fs.list(dir), { "current", "versions" })
end)
