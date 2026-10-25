dofile((arg[0]:match("^(.*)/[^/]*$") or ".") .. "/boot.lua")

local t = require("testing")

local file = arg[1]
if not file then
    local stderr = io.stderr
    stderr:write("usage: luajit tests/lua/run.lua <file>\n")
    os.exit(2)
end

dofile(file)

local failed = 0
for _, case in ipairs(t.tests()) do
    local ok, err = pcall(case.fn)
    if ok then
        print("ok - " .. case.name)
    else
        failed = failed + 1
        print("not ok - " .. case.name)
        print("    " .. tostring(err))
    end
end

os.exit(failed == 0 and 0 or 1)
