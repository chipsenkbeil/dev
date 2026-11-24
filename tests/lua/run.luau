local dev_os = require("dev.os")
local runtime = require("dev.runtime")

runtime.dofile((arg[0]:match("^(.*)/[^/]*$") or ".") .. "/boot.luau")

local testrun = require("dev.testrun")

local file = arg[1]
local only = arg[2]
if not file then
    dev_os.stderr:write("usage: dev -l tests/lua/run.luau <file> [name]\n")
    dev_os.exit(2)
end

runtime.dofile(file)

dev_os.exit(testrun.execute(0, only) == 0 and 0 or 1)
