local testing = require("dev.testing")
local registry = require("dev.registry")
local support = require("support")

local SCRIPT = '--[[\nLand the project\'s own way.\n]]\nprint("project land ran")\n'

testing.test("land.override.replaces the builtin row and keeps its group", function()
    local root = support.sandbox({ [".dev/land.lua"] = SCRIPT }, {})
    local row = registry.load(root):find({ "land" })
    testing.eq(row.kind, "override")
    testing.eq(row.desc, "Land the project's own way.")
    testing.eq(row.group, "Share it")
end)

testing.test("land.override.runs the project script and not the builtin", function()
    local root = support.sandbox({ [".dev/land.lua"] = SCRIPT }, {})
    local out, code = support.dev(root, { "land" })
    testing.eq(code, 0, out)
    testing.ok(out:find("project land ran", 1, true), out)
end)

testing.test("land.override.builtin is a builtin row when no script exists", function()
    local root = support.sandbox({}, {})
    testing.eq(registry.load(root):find({ "land" }).kind, "builtin")
end)
