local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")
local pipelines = require("dev.pipelines")
local support = require("support")
local templates = require("dev.templates")
local Kind = require("dev.project").Kind

local function project()
    local root = support.sandbox({ ["a.lua"] = "print(1)\n" }, {})
    assert(fs.write(root .. "/bin/pass", "#!/bin/sh\nexit 1\n"))
    assert(dev_os.run({ "chmod", "755", root .. "/bin/pass" }) == 0, "chmod failed")
    return root
end

local function names(dir)
    local out = fs.list(dir) or {}
    table.sort(out)
    return out
end

local function created_in(out)
    local items = {}
    for item in out:gmatch("\ncreated: ([^\n]+)") do
        items[#items + 1] = item
    end
    return items
end

testing.test("init --dry-run writes nothing and plans the files", function()
    local root = project()
    local before = names(root)
    local out, code = support.dev(root, { "init", "--type", "lua", "--dry-run", "--no-gerrit" })
    testing.eq(code, 0)
    testing.ok(out:find("would create: .ci/jobs.lua", 1, true), out)
    testing.ok(out:find("would create: .dev/lint.lua", 1, true), out)
    testing.ok(out:find("would create: .dev/lua/lintset.lua", 1, true), out)
    testing.ok(out:find("would create: docs/STYLE.md", 1, true), out)
    testing.ok(out:find("(dry run, nothing written)", 1, true), out)
    testing.ok(not out:find("\ncreated:"), out)
    testing.eq(names(root), before)
    fs.remove(root, { recursive = true })
end)

testing.test("a second init skips every file the first one created", function()
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = project()
    local first, first_code = support.dev(root, { "init", "--type", "lua", "--no-gerrit" })
    testing.eq(first_code, 0)
    local items = created_in("\n" .. first)
    testing.ok(#items > 0, first)
    testing.ok(fs.is_file(root .. "/.ci/jobs.lua"), first)
    testing.ok(fs.is_file(root .. "/.dev/lint.lua"), first)
    testing.ok(fs.is_file(root .. "/.dev/fmt.lua"), first)
    testing.ok(fs.is_file(root .. "/.dev/lua/lintset.lua"), first)
    for _, name in ipairs(names(root .. "/.dev")) do
        testing.ok(not name:find("%.sh$"), name)
    end
    local second, second_code = support.dev(root, { "init", "--type", "lua", "--no-gerrit" })
    testing.eq(second_code, 0)
    testing.ok(not second:find("\ncreated:"), second)
    for _, item in ipairs(items) do
        local file = item:match("^%S+$")
        if file then
            testing.ok(
                second:find("skipped: " .. file .. " exists", 1, true),
                file .. "\n" .. second
            )
        end
    end
    fs.remove(root, { recursive = true })
end)

testing.test("init names the Gerrit project after the project in a dry run", function()
    local root = project()
    local out = support.dev(root, { "init", "--type", "lua", "--dry-run", "--name", "zz" })
    local want =
        "would create: gerrit project zz (create-project when absent) and remote gerrit gr:zz"
    testing.ok(out:find(want, 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("init skips the lint set for a type that has none", function()
    local root = project()
    local out = support.dev(root, { "init", "--type", "godot", "--dry-run", "--no-gerrit" })
    testing.ok(out:find("skipped: lint set: none yet for godot projects", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("init plans a lint set exactly for the types templates.set_for knows", function()
    for _, kind in ipairs({ Kind.RUST, Kind.LOVE2D, Kind.LUA, Kind.GODOT, Kind.NODE }) do
        local root = project()
        local out = support.dev(root, { "init", "--type", kind, "--dry-run", "--no-gerrit" })
        local none = out:find("skipped: lint set: none yet for " .. kind, 1, true) ~= nil
        testing.eq(none, templates.set_for(kind) == nil, kind .. "\n" .. out)
        fs.remove(root, { recursive = true })
    end
end)

testing.test("init refuses a type it has no name for", function()
    local root = project()
    local out, code = support.dev(root, { "init", "--type", "cobol" })
    testing.eq(code, 2)
    testing.eq(out, "dev init: --type takes rust, love2d, lua, godot or node\n")
    out, code = support.dev(root, { "init", "--name" })
    testing.eq(code, 2)
    testing.eq(out, "dev init: --name needs a value\n")
    fs.remove(root, { recursive = true })
end)

testing.test("init plans no GitHub workflow for any type", function()
    for _, kind in ipairs({ Kind.RUST, Kind.LOVE2D, Kind.LUA, Kind.GODOT, Kind.NODE }) do
        local root = project()
        local out = support.dev(root, { "init", "--type", kind, "--dry-run", "--no-gerrit" })
        testing.ok(not out:find(".github", 1, true), kind .. "\n" .. out)
        fs.remove(root, { recursive = true })
    end
end)

testing.test("the base pipeline runs on the image that ships dev", function()
    local text = pipelines.jobs(false)
    testing.ok(text:find('target = "linux-x86-dev"', 1, true), text)
    testing.ok(not text:find("linux-x86-base", 1, true), text)
end)

local function stub(root, name, text)
    assert(fs.write(root .. "/bin/" .. name, text))
    assert(dev_os.run({ "chmod", "755", root .. "/bin/" .. name }) == 0, "chmod failed")
end

testing.test("init creates the Gerrit project and its remote when the server lacks it", function()
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = project()
    local log = root .. "/ssh.log"
    stub(
        root,
        "ssh",
        '#!/bin/sh\necho "$*" >>' .. log .. '\n[ "$5" = ls-projects ] && echo other\nexit 0\n'
    )
    local out, code = support.dev(root, { "init", "--type", "lua", "--name", "zz" })
    testing.eq(code, 0)
    testing.ok(out:find("created: gerrit project zz\n", 1, true), out)
    testing.ok(out:find("created: remote gerrit gr:zz\n", 1, true), out)
    testing.ok((fs.read(log) or ""):find("create-project zz", 1, true), out)
    local again = support.dev(root, { "init", "--type", "lua", "--name", "zz" })
    testing.ok(again:find("skipped: remote gerrit exists", 1, true), again)
    fs.remove(root, { recursive = true })
end)

testing.test("init leaves the Gerrit step to the owner when ls-projects fails", function()
    local root = project()
    stub(root, "ssh", "#!/bin/sh\necho denied\nexit 255\n")
    local out, code = support.dev(root, { "init", "--type", "lua", "--dry-run", "--name", "zz" })
    testing.eq(code, 0)
    testing.ok(not out:find("Left for you:.*create%-project"), out)
    out, code = support.dev(root, { "init", "--type", "lua", "--name", "zz" })
    testing.eq(code, 0)
    testing.ok(out:find("Gerrit ls-projects failed.\ndenied\n", 1, true), out)
    testing.ok(out:find("create the Gerrit project and remote: ssh -p 29418", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test(
    "init hints at a missing Pomb board and keeps the token off the command line",
    function()
        local root = project()
        local log = root .. "/curl.log"
        stub(root, "pass", "#!/bin/sh\necho secret-token\n")
        stub(
            root,
            "curl",
            '#!/bin/sh\necho "curl $*" >>'
                .. log
                .. '\ncat >/dev/null\nprintf \'[{"name":"General"}]\\n200\'\n'
        )
        local out = support.dev(
            root,
            { "init", "--type", "lua", "--dry-run", "--no-gerrit", "--name", "zz" }
        )
        testing.ok(out:find("No Pomb board for zz", 1, true), out)
        testing.ok(not out:find("General", 1, true), out)
        local logged = fs.read(log) or ""
        testing.ok(logged:find("-K - ", 1, true), logged)
        testing.ok(not logged:find("secret-token", 1, true), logged)
        stub(root, "curl", "#!/bin/sh\ncat >/dev/null\nprintf 'not json\\n200'\n")
        out = support.dev(
            root,
            { "init", "--type", "lua", "--dry-run", "--no-gerrit", "--name", "zz" }
        )
        testing.ok(not out:find("No Pomb board", 1, true), out)
        stub(root, "curl", "#!/bin/sh\ncat >/dev/null\nprintf '\\n401'\nexit 22\n")
        out = support.dev(
            root,
            { "init", "--type", "lua", "--dry-run", "--no-gerrit", "--name", "zz" }
        )
        testing.ok(out:find("Pomb refused the worker token", 1, true), out)
        testing.ok(not out:find("No Pomb board", 1, true), out)
        stub(root, "curl", "#!/bin/sh\ncat >/dev/null\nprintf '\\n000'\nexit 7\n")
        out = support.dev(
            root,
            { "init", "--type", "lua", "--dry-run", "--no-gerrit", "--name", "zz" }
        )
        testing.ok(not out:find("Pomb refused", 1, true), out)
        testing.ok(not out:find("No Pomb board", 1, true), out)
        fs.remove(root, { recursive = true })
    end
)

testing.test("init treats an empty --type and --name as unset", function()
    local root = project()
    local out, code =
        support.dev(root, { "init", "--type", "", "--name", "", "--dry-run", "--no-gerrit" })
    testing.eq(code, 0)
    testing.ok(out:find("init " .. fs.basename(root) .. ": type lua", 1, true), out)
    fs.remove(root, { recursive = true })
end)

testing.test("init leaves a project on bash verbs without Lua verbs", function()
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = project()
    assert(fs.write(root .. "/.dev/lint.sh", "#!/bin/sh\n"), "fixture setup failed")
    local out, code = support.dev(root, { "init", "--type", "lua", "--no-gerrit" })
    testing.eq(code, 0)
    testing.ok(out:find("skipped: .dev/lint.sh exists, left on bash", 1, true), out)
    testing.ok(not fs.exists(root .. "/.dev/lint.lua"), out)
    testing.ok(not fs.exists(root .. "/.dev/fmt.lua"), out)
    testing.ok(not fs.exists(root .. "/.dev/lua/lintset.lua"), out)
    fs.remove(root, { recursive = true })
end)

testing.test("init seeds .dev/README.md from the template", function()
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end
    for _, kind in ipairs({ Kind.LUA, Kind.GODOT }) do
        local root = project()
        local out, code = support.dev(root, { "init", "--type", kind, "--no-gerrit" })
        testing.eq(code, 0)
        testing.ok(out:find("created: .dev/README.md", 1, true), out)
        testing.eq(fs.read(root .. "/.dev/README.md"), fs.read(templates.readme_template()))
        fs.remove(root, { recursive = true })
    end
end)

testing.test("a second init keeps an edited .dev/README.md", function()
    if not dev_os.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = project()
    local _, first = support.dev(root, { "init", "--type", "lua", "--no-gerrit" })
    testing.eq(first, 0)
    local edited = "# my own readme\n"
    assert(fs.write(root .. "/.dev/README.md", edited))
    local out, code = support.dev(root, { "init", "--type", "lua", "--no-gerrit" })
    testing.eq(code, 0)
    testing.ok(out:find("skipped: .dev/README.md exists", 1, true), out)
    testing.eq(fs.read(root .. "/.dev/README.md"), edited)
    fs.remove(root, { recursive = true })
end)
