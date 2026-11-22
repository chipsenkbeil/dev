local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/lua/?.lua"

local argv = {}
for i = 1, #arg do
    argv[i] = arg[i]
end
local code = require("dev.pkg").main(argv, {
    interpreter = arg[-1] or "luajit",
    modules = here .. "/lua",
})
io.stdout:flush()
os.exit(code)
