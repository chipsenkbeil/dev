local here = debug.getinfo(1, "S").source:match("^@(.*)/tests/lua/[^/]*$") or "."
package.path = here .. "/dotfiles/bin/.local/share/dev/lua/?.lua;" .. package.path
local devos = require("dev.os")

local uid = os.getenv("FAKE_UID")
if uid then
    devos.getuid = function()
        return tonumber(uid)
    end
end

local name = os.getenv("FAKE_OS")
if name then
    devos.name = function()
        return name
    end
end
