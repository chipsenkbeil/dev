dofile((arg[0]:match("^(.*)/[^/]*$") or ".") .. "/boot.lua")

local t = require("testing")

local file = arg[1]
local only = arg[2]
if not file then
    local stderr = io.stderr
    stderr:write("usage: luajit tests/lua/run.lua <file> [name]\n")
    os.exit(2)
end

dofile(file)

local failed = 0
for _, case in ipairs(t.tests()) do
    if not only or case.name:find(only, 1, true) then
        local ok, err = pcall(case.fn)
        if ok then
            print("ok - " .. case.name)
        else
            failed = failed + 1
            print("not ok - " .. case.name)
            print("    " .. tostring(err))
        end
    end
end

os.exit(failed == 0 and 0 or 1)
