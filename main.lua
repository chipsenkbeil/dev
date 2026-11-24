local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/lua/?.lua"

local argv = {}
for i = 1, #arg do
    argv[i] = arg[i]
end

local INTERRUPTED = 130
local ok, cli = pcall(function()
    local loaded = require("@dev/cli")
    require("@dev/os").catch_term()
    return loaded
end)
if not ok then
    if tostring(cli):find("interrupted!", 1, true) then
        os.exit(INTERRUPTED)
    end
    error(cli, 0)
end
local code = cli.guard(cli.main, argv)
if code then
    os.exit(code)
end
