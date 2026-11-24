local dev_command = require("@dev/command")
local dev_os = require("@dev/os")
local runtime = require("@dev/runtime")

local failures = 0

local function check(name, body)
    local ok, err = pcall(body)
    if ok then
        print("ok   " .. name)
    else
        failures += 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local DIR = "luau/dev/commands/board/"

local function specs(dir, found)
    for _, name in ipairs(runtime.assets(dir)) do
        if name:find("%.luau$") then
            found[#found + 1] = dir .. name
        elseif name ~= "DESCRIPTION" then
            specs(dir .. name .. "/", found)
        end
    end
    return found
end

check("every board command file loads and returns a valid spec", function()
    local found = specs(DIR, {})
    if #found ~= 59 then
        error("expected 59 board command files, found " .. #found)
    end
    for _, path in ipairs(found) do
        local chunk, why = runtime.load(
            runtime.asset(path),
            "@" .. path,
            setmetatable({ dev_command = dev_command }, { __index = _G })
        )
        if not chunk then
            error(path .. ": " .. tostring(why))
        end
        local spec = chunk()
        if type(spec) ~= "table" or type(spec.run) ~= "function" then
            error(path .. " does not return a command spec")
        end
    end
end)

check("every board parent has a description", function()
    for _, dir in ipairs({ DIR, DIR .. "token/", DIR .. "seat/" }) do
        if not runtime.asset(dir .. "DESCRIPTION") then
            error(dir .. " has no DESCRIPTION")
        end
    end
end)

dev_os.exit(failures == 0)
