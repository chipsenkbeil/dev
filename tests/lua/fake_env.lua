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

local pick = os.getenv("FAKE_PICK")
if pick then
    local picker = require("dev.ui.picker")
    picker.run = function(_, items, opts)
        local log = os.getenv("PICK_LOG")
        if log then
            local file = assert(io.open(log, "a"))
            file:write("picker title=", opts.title, " auto=", tostring(opts.auto), "\n")
            for _, item in ipairs(items) do
                file:write(item.value, "\t", table.concat(item.cells, "\t"), "\n")
            end
            file:close()
        end
        if pick == "CANCEL" then
            return nil
        end
        return pick
    end
end
