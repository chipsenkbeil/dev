dofile((arg[0]:match("^(.*)/[^/]*$") or ".") .. "/boot.lua")

local testrun = require("dev.testrun")

local file = arg[1]
local only = arg[2]
if not file then
    local stderr = io.stderr
    stderr:write("usage: luajit tests/lua/run.lua <file> [name]\n")
    os.exit(2)
end

dofile(file)

os.exit(testrun.execute(0, only) == 0 and 0 or 1)
