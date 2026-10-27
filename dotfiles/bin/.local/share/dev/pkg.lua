local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/lua/?.lua"

local root = here:match("^(.*)/dotfiles/bin/%.local/share/dev$")
if not root then
    io.stderr:write("pkg.lua: cannot find the dotfiles clone from ", here, "\n")
    os.exit(1)
end

local argv = {}
for i = 1, #arg do
    argv[i] = arg[i]
end
local code = require("dev.pkg").main(argv, {
    scripts = root .. "/scripts",
    manifest = root .. "/.dev/tools.tsv",
})
io.stdout:flush()
os.exit(code)
