local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or "."
package.path = here .. "/lua/?.lua"

local devos = require("dev.os")
local stderr = io.stderr

local argv = { "bash", here .. "/legacy.bash" }
for i = 1, #arg do
    argv[#argv + 1] = arg[i]
end

local _, message = devos.exec(argv, {
    env = {
        DEV_UID = tostring(devos.getuid()),
        DEV_OS = devos.name(),
    },
})
stderr:write("dev: cannot run bash: ", message, "\n")
os.exit(1)
