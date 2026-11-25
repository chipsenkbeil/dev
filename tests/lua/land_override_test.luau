local testing = require("@dev/testing")
local registry = require("@dev/registry")
local support = require("./support")

local SCRIPT = table.concat({
    'local dev_command = require("@dev/command")',
    "return dev_command({",
    '    summary = "Land the project\'s own way.",',
    '    run = function() print("project land ran") end,',
    "})",
    "",
}, "\n")

local FILES = { [".dev/commands/land.luau"] = SCRIPT }

testing.test("land.override.replaces the builtin row and keeps its group", function()
    local root = support.sandbox(FILES, {})
    local row = registry.load(root):find({ "land" })
    testing.eq(row.kind, "override")
    testing.eq(row.replaces, "builtin")
    testing.eq(row.desc, "Land the project's own way.")
end)

testing.test("land.override.runs the project command and not the builtin", function()
    local root = support.sandbox(FILES, {})
    local out, code = support.dev(root, { "land" })
    testing.eq(code, 0, out)
    testing.ok(out:find("project land ran", 1, true), out)
end)

testing.test("land.override.builtin is a builtin row when no command file exists", function()
    local root = support.sandbox({}, {})
    testing.eq(registry.load(root):find({ "land" }).kind, "builtin")
end)
