local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local REPO = assert(fs.realpath((dev_os.capture({ "pwd" }):gsub("\n$", ""))))

local function install(home)
    return dev_os.capture({ "luajit", REPO .. "/main.lua", "install" }, {
        cwd = REPO,
        stderr = "stdout",
        env = {
            HOME = home,
            XDG_STATE_HOME = home .. "/state",
            DEV_SELF = REPO .. "/bin/dev",
            DEV_REMOTE = "0",
            CI = "",
        },
        unset = { "DEV_AGENT" },
    })
end

local function home_with(links)
    local home = assert(fs.realpath(support.tempdir()))
    for path, target in pairs(links) do
        assert(fs.mkdir(fs.dirname(home .. "/" .. path), { parents = true }))
        assert(fs.symlink(home .. "/" .. target, home .. "/" .. path))
    end
    return home
end

testing.test("install replaces dangling dev links with links into the checkout", function()
    local home = home_with({ [".local/bin/dev"] = "gone/dev", [".local/share/dev"] = "gone/share" })
    local out, code = install(home)
    testing.eq(code, 0, out)
    testing.eq(fs.readlink(home .. "/.local/bin/dev"), REPO .. "/bin/dev")
    testing.eq(fs.readlink(home .. "/.local/share/dev"), REPO)
    testing.eq(fs.read(home .. "/state/dev/snapshot/current/ORIGIN"), REPO .. "\n")
    fs.remove(home, { recursive = true })
end)

testing.test("install makes the dev links in a home that has none", function()
    local home = home_with({})
    local out, code = install(home)
    testing.eq(code, 0, out)
    testing.eq(fs.readlink(home .. "/.local/bin/dev"), REPO .. "/bin/dev")
    testing.eq(fs.readlink(home .. "/.local/share/dev"), REPO)
    fs.remove(home, { recursive = true })
end)

testing.test("install leaves a launcher that is not a link and fails", function()
    local home = home_with({})
    assert(fs.mkdir(home .. "/.local/bin", { parents = true }))
    assert(fs.write(home .. "/.local/bin/dev", "kept\n"))
    local out, code = install(home)
    testing.eq(code, 1, out)
    testing.eq(fs.read(home .. "/.local/bin/dev"), "kept\n")
    testing.ok(out:find("is not a link, so it stays", 1, true), out)
    testing.eq(fs.readlink(home .. "/.local/share/dev"), REPO)
    fs.remove(home, { recursive = true })
end)
