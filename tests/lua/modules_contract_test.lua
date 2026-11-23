local testing = require("dev.testing")
local fs = require("dev.fs")
local support = require("support")

local DOC = "dotfiles/bin/.local/share/dev/docs/modules.md"
local HEADING = "### Modules a command may require"

local PROBE = [=[--[[
Check the modules a command may require.
]]
local entries = %s
local missing = {}
for _, entry in ipairs(entries) do
    local ok, module = pcall(require, entry.module)
    if not ok then
        missing[#missing + 1] = entry.module .. " does not load"
    else
        for _, name in ipairs(entry.functions) do
            if type(module[name]) ~= "function" then
                missing[#missing + 1] = entry.module .. "." .. name .. " is not a function"
            end
        end
    end
end
for _, line in ipairs(missing) do
    print(line)
end
print("checked " .. #entries .. " modules")
]=]

local function section()
    local text = assert(fs.read(DOC))
    local start = assert(text:find(HEADING, 1, true), "the section is missing")
    local rest = text:sub(start + #HEADING)
    local finish = rest:find("\n#", 1, true)
    return finish and rest:sub(1, finish) or rest
end

local function entries()
    local items = {}
    local current

    -- Join each bullet with its continuation lines and refuse a malformed bullet
    for line in section():gmatch("[^\n]+") do
        local module, tail = line:match("^%- `([%w_.]+)`:(.*)$")
        if module then
            current = { module = module, text = tail }
            items[#items + 1] = current
        elseif current and line:match("^  ") then
            current.text = current.text .. " " .. line
        else
            assert(not line:match("^%- "), "malformed bullet: " .. line)
            current = nil
        end
    end

    -- Pull the backticked function names out of each bullet
    for _, item in ipairs(items) do
        item.functions = {}
        for name in item.text:gmatch("`([%w_]+)`") do
            item.functions[#item.functions + 1] = name
        end
        item.text = nil
    end
    return items
end

local function literal(items)
    local parts = {}
    for _, item in ipairs(items) do
        local names = {}
        for _, name in ipairs(item.functions) do
            names[#names + 1] = string.format("%q", name)
        end
        parts[#parts + 1] = string.format(
            "{ module = %q, functions = { %s } }",
            item.module,
            table.concat(names, ", ")
        )
    end
    return "{\n" .. table.concat(parts, ",\n") .. ",\n}"
end

testing.test("the modules topic lists at least one function for every module", function()
    local items = entries()
    testing.ok(#items > 0, "no module is listed")
    for _, item in ipairs(items) do
        testing.ok(#item.functions > 0, item.module .. " lists no function")
    end
end)

testing.test("every module the modules topic lists loads from a project command", function()
    local items = entries()

    -- Put the probe command in a project
    local root = support.sandbox({
        [".dev/contract.lua"] = string.format(PROBE, literal(items)),
    }, {})

    -- Run it through dev
    local out, code = support.dev(root, { "contract" })
    fs.remove(root, { recursive = true })
    testing.eq(code, 0)
    testing.eq(out, "checked " .. #items .. " modules\n")
end)

testing.test("the modules topic names every other module as internal", function()
    local text = section()
    testing.ok(
        text:find(
            "Every other module under `dev` is internal and may change without notice.",
            1,
            true
        ),
        "the closing sentence is missing"
    )
end)
