local t = require("testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local pipelines = require("dev.pipelines")
local support = require("support")

local function project()
    local root = support.sandbox({ ["a.lua"] = "print(1)\n" }, {})
    assert(fs.write(root .. "/bin/pass", "#!/bin/sh\nexit 1\n"))
    assert(devos.run({ "chmod", "755", root .. "/bin/pass" }) == 0, "chmod failed")
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

t.test("init --dry-run writes nothing and plans the files", function()
    local root = project()
    local before = names(root)
    local out, code = support.dev(root, { "init", "--type", "lua", "--dry-run", "--no-gerrit" })
    t.eq(code, 0)
    t.ok(out:find("would create: .ci/jobs.lua", 1, true), out)
    t.ok(out:find("would create: .dev/lint.sh", 1, true), out)
    t.ok(out:find("would create: docs/STYLE.md", 1, true), out)
    t.ok(out:find("(dry run, nothing written)", 1, true), out)
    t.ok(not out:find("\ncreated:"), out)
    t.eq(names(root), before)
    fs.remove(root, { recursive = true })
end)

t.test("a second init skips every file the first one created", function()
    if not devos.which("git") then
        print("skip - git is not installed")
        return
    end
    local root = project()
    local first, first_code = support.dev(root, { "init", "--type", "lua", "--no-gerrit" })
    t.eq(first_code, 0)
    local items = created_in("\n" .. first)
    t.ok(#items > 0, first)
    t.ok(fs.is_file(root .. "/.ci/jobs.lua"), first)
    t.ok(fs.is_exec(root .. "/.dev/lint.sh"), first)
    local second, second_code = support.dev(root, { "init", "--type", "lua", "--no-gerrit" })
    t.eq(second_code, 0)
    t.ok(not second:find("\ncreated:"), second)
    for _, item in ipairs(items) do
        local file = item:match("^%S+$")
        if file then
            t.ok(second:find("skipped: " .. file .. " exists", 1, true), file .. "\n" .. second)
        end
    end
    fs.remove(root, { recursive = true })
end)

t.test("init names the Gerrit project after the project in a dry run", function()
    local root = project()
    local out = support.dev(root, { "init", "--type", "lua", "--dry-run", "--name", "zz" })
    local want =
        "would create: gerrit project zz (create-project when absent) and remote gerrit gr:zz"
    t.ok(out:find(want, 1, true), out)
    fs.remove(root, { recursive = true })
end)

t.test("init skips the lint set and the workflow for a type that has none", function()
    local root = project()
    local out =
        support.dev(root, { "init", "--type", "godot", "--dry-run", "--no-gerrit", "--public" })
    t.ok(
        out:find("skipped: .github/workflows/ci.yml: no workflow for godot projects", 1, true),
        out
    )
    t.ok(out:find("skipped: lint set: none yet for godot projects", 1, true), out)
    fs.remove(root, { recursive = true })
end)

t.test("init refuses a type it has no name for", function()
    local root = project()
    local out, code = support.dev(root, { "init", "--type", "cobol" })
    t.eq(code, 2)
    t.eq(out, "dev init: --type takes rust, love2d, lua, godot or node\n")
    out, code = support.dev(root, { "init", "--name" })
    t.eq(code, 2)
    t.eq(out, "dev init: --name needs a value\n")
    fs.remove(root, { recursive = true })
end)

t.test("the workflow names the trunk once", function()
    local text = pipelines.workflow("main")
    t.ok(text:find("branches: [main]", 1, true), text)
    t.ok(not text:find("@TRUNK@", 1, true), text)
end)

local function stub(root, name, text)
    assert(fs.write(root .. "/bin/" .. name, text))
    assert(devos.run({ "chmod", "755", root .. "/bin/" .. name }) == 0, "chmod failed")
end

t.test("init creates the Gerrit project and its remote when the server lacks it", function()
    if not devos.which("git") then
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
    t.eq(code, 0)
    t.ok(out:find("created: gerrit project zz\n", 1, true), out)
    t.ok(out:find("created: remote gerrit gr:zz\n", 1, true), out)
    t.ok((fs.read(log) or ""):find("create-project zz", 1, true), out)
    local again = support.dev(root, { "init", "--type", "lua", "--name", "zz" })
    t.ok(again:find("skipped: remote gerrit exists", 1, true), again)
    fs.remove(root, { recursive = true })
end)

t.test("init leaves the Gerrit step to the owner when ls-projects fails", function()
    local root = project()
    stub(root, "ssh", "#!/bin/sh\necho denied\nexit 255\n")
    local out, code = support.dev(root, { "init", "--type", "lua", "--dry-run", "--name", "zz" })
    t.eq(code, 0)
    t.ok(not out:find("Left for you:.*create%-project"), out)
    out, code = support.dev(root, { "init", "--type", "lua", "--name", "zz" })
    t.eq(code, 0)
    t.ok(out:find("warning: gerrit ls-projects failed: denied", 1, true), out)
    t.ok(out:find("create the Gerrit project and remote: ssh -p 29418", 1, true), out)
    fs.remove(root, { recursive = true })
end)

t.test("init hints at a missing Pomb board and keeps the token off the command line", function()
    local root = project()
    local log = root .. "/curl.log"
    stub(root, "pass", "#!/bin/sh\necho secret-token\n")
    stub(
        root,
        "curl",
        '#!/bin/sh\necho "curl $*" >>'
            .. log
            .. '\ncat >/dev/null\nprintf \'[{"name":"General"}]\'\n'
    )
    local out =
        support.dev(root, { "init", "--type", "lua", "--dry-run", "--no-gerrit", "--name", "zz" })
    t.ok(out:find("No Pomb board for zz", 1, true), out)
    local logged = fs.read(log) or ""
    t.ok(logged:find("-K - ", 1, true), logged)
    t.ok(not logged:find("secret-token", 1, true), logged)
    stub(root, "curl", "#!/bin/sh\ncat >/dev/null\nprintf 'not json'\n")
    out = support.dev(root, { "init", "--type", "lua", "--dry-run", "--no-gerrit", "--name", "zz" })
    t.ok(not out:find("No Pomb board", 1, true), out)
    fs.remove(root, { recursive = true })
end)

t.test("init treats an empty --type and --name as unset", function()
    local root = project()
    local out, code =
        support.dev(root, { "init", "--type", "", "--name", "", "--dry-run", "--no-gerrit" })
    t.eq(code, 0)
    t.ok(out:find("init " .. fs.basename(root) .. ": type lua", 1, true), out)
    fs.remove(root, { recursive = true })
end)
