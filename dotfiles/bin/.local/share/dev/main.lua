local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/lua/?.lua"

local argv = {}
for i = 1, #arg do
    argv[i] = arg[i]
end
local cli = require("dev.cli")
require("dev.os").catch_term()
local code = cli.guard(cli.main, argv)
if code then
    os.exit(code)
end
