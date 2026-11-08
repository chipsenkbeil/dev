local t = require("dev.testing")
local fs = require("dev.fs")
local standalone = require("dev.standalone")
local support = require("support")

local function project(files)
    local root = support.tempdir()
    for rel, text in pairs(files) do
        assert(fs.mkdir(fs.dirname(root .. "/" .. rel), { parents = true }), "mkdir failed")
        assert(fs.write(root .. "/" .. rel, text), "fixture setup failed")
    end
    return root
end

t.test("standalone warns on a .sh outside .dev/standalone", function()
    local root = project({ [".dev/x.sh"] = "#!/bin/sh\n", [".dev/n/y.sh"] = "#!/bin/sh\n" })
    t.eq(standalone.problems(root), {
        "WARNING: .dev/n/y.sh: shell outside .dev/standalone, port it to Lua (dev help porting)",
        "WARNING: .dev/x.sh: shell outside .dev/standalone, port it to Lua (dev help porting)",
    })
    fs.remove(root, { recursive = true })
end)

t.test("standalone warns on a bad line 2", function()
    local root = project({ [".dev/standalone/x.sh"] = "#!/bin/sh\n# runs somewhere\n" })
    t.eq(standalone.problems(root), {
        "WARNING: .dev/standalone/x.sh: line 2 must read: # standalone: runs on <where>, where dev is absent",
    })
    fs.remove(root, { recursive = true })
end)

t.test("standalone warns on an unknown where", function()
    local root = project({
        [".dev/standalone/x.sh"] = "#!/bin/sh\n# standalone: runs on my laptop, where dev is absent\n",
    })
    t.eq(standalone.problems(root), {
        "WARNING: .dev/standalone/x.sh: where must be one of: production server, test sandbox, GitHub Actions",
    })
    fs.remove(root, { recursive = true })
end)

t.test("standalone passes a valid header", function()
    local files = {}
    for _, where in ipairs(standalone.WHERE) do
        files[".dev/standalone/" .. where:gsub(" ", "_") .. ".sh"] = "#!/bin/sh\n# standalone: runs on "
            .. where
            .. ", where dev is absent\n"
    end
    local root = project(files)
    t.eq(standalone.problems(root), {})
    fs.remove(root, { recursive = true })
end)
