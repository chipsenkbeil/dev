local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/lua/?.lua"

local argv = {}
for i = 1, #arg do
    argv[i] = arg[i]
end
require("dev.cli").main(argv)
