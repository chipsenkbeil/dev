local testing = require("@dev/testing")
local fs = require("@dev/fs")
local standalone = require("@dev/standalone")
local support = require("./support")

local function project(files)
    local root = support.tempdir()
    for rel, text in pairs(files) do
        assert(fs.mkdir(fs.dirname(root .. "/" .. rel), { parents = true }), "mkdir failed")
        assert(fs.write(root .. "/" .. rel, text), "fixture setup failed")
    end
    return root
end

testing.test("standalone reports a .sh outside .dev/standalone", function()
    local root = project({ [".dev/x.sh"] = "#!/bin/sh\n", [".dev/n/y.sh"] = "#!/bin/sh\n" })
    testing.eq(standalone.problems(root), {
        ".dev/n/y.sh: shell outside .dev/standalone, port it to Lua (dev help porting)",
        ".dev/x.sh: shell outside .dev/standalone, port it to Lua (dev help porting)",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("standalone passes a shell command and a helper", function()
    local root = project({
        [".dev/commands/x.sh"] = "#!/bin/sh\n",
        [".dev/commands/n/y.sh"] = "#!/bin/sh\n",
        [".dev/helpers/z.sh"] = "#!/bin/sh\n",
    })
    testing.eq(standalone.problems(root), {})
    fs.remove(root, { recursive = true })
end)

testing.test("standalone reports a .sh in a .dev folder that holds no commands", function()
    local root = project({ [".dev/lib/x.sh"] = "#!/bin/sh\n" })
    testing.eq(standalone.problems(root), {
        ".dev/lib/x.sh: shell outside .dev/standalone, port it to Lua (dev help porting)",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("standalone reports a bad line 2", function()
    local root = project({
        [".dev/standalone/x.sh"] = table.concat({ "#!/bin/sh", "# runs somewhere", "" }, "\n"),
    })
    testing.eq(standalone.problems(root), {
        ".dev/standalone/x.sh: line 2 must read: # standalone: runs on <where>, where dev is absent",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("standalone reports an unknown where", function()
    local root = project({
        [".dev/standalone/x.sh"] = table.concat({
            "#!/bin/sh",
            "# standalone: runs on my laptop, where dev is absent",
            "",
        }, "\n"),
    })
    testing.eq(standalone.problems(root), {
        ".dev/standalone/x.sh: where must be one of: production server, test sandbox, GitHub Actions",
    })
    fs.remove(root, { recursive = true })
end)

testing.test("standalone passes a valid header", function()
    local files = {}
    for _, where in ipairs(standalone.WHERE) do
        files[".dev/standalone/" .. where:gsub(" ", "_") .. ".sh"] = table.concat({
            "#!/bin/sh",
            "# standalone: runs on " .. where .. ", where dev is absent",
            "",
        }, "\n")
    end
    local root = project(files)
    testing.eq(standalone.problems(root), {})
    fs.remove(root, { recursive = true })
end)

testing.test("land_problem refuses an added standalone file without the label", function()
    testing.eq(
        standalone.land_problem({ "a.txt", ".dev/standalone/x.sh" }, { "docs" }),
        "adds .dev/standalone/x.sh, which needs the standalone-ok label that only the owner adds"
    )
end)

testing.test("land_problem passes with the label and for unrelated paths", function()
    testing.eq(standalone.LABEL, "standalone-ok")
    testing.eq(
        standalone.land_problem({ ".dev/standalone/x.sh" }, { "docs", "standalone-ok" }),
        nil
    )
    testing.eq(standalone.land_problem({ ".dev/x.sh", "docs/standalone/y.sh", "a.txt" }, {}), nil)
    testing.eq(standalone.land_problem({}, {}), nil)
end)
