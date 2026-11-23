local here = debug.getinfo(1, "S").source:match("^@(.*)/tests/lua/[^/]*$") or "."
package.path = here .. "/lua/?.lua;" .. package.path
local dev_os = require("dev.os")

local uid = os.getenv("FAKE_UID")
if uid then
    dev_os.getuid = function()
        return tonumber(uid)
    end
end

local name = os.getenv("FAKE_OS")
if name then
    dev_os.name = function()
        return name
    end
end

local hidden = os.getenv("FAKE_HIDE")
if hidden then
    local which = dev_os.which
    dev_os.which = function(tool)
        if (" " .. hidden .. " "):find(" " .. tool .. " ", 1, true) then
            return nil
        end
        return which(tool)
    end
end

local pick = os.getenv("FAKE_PICK")
if pick then
    local picker = require("dev.ui.picker")
    local queue = {}
    for word in pick:gmatch("%S+") do
        queue[#queue + 1] = word
    end
    local used = 0
    picker.run = function(_, items, opts)
        local log = os.getenv("PICK_LOG")
        if log then
            local file = assert(io.open(log, "a"))
            file:write("picker title=", opts.title, " auto=", tostring(opts.auto))
            if opts.note then
                file:write(" note=", opts.note)
            end
            if opts.initial then
                file:write(" initial=", opts.initial)
            end
            file:write("\n")
            for _, item in ipairs(items) do
                file:write(item.value, "\t", table.concat(item.cells, "\t"))
                if item.disabled then
                    file:write("\t!", item.disabled)
                end
                file:write("\n")
            end
            file:close()
        end
        if pick == "CANCEL" then
            return nil
        end
        if not opts.multi and #queue > 1 then
            used = used + 1
            return queue[used]
        end
        if opts.multi then
            local values, toggles = {}, {}
            for word in pick:gmatch("%S+") do
                values[#values + 1] = word
            end
            for word in (os.getenv("FAKE_PICK_TOGGLES") or ""):gmatch("%S+") do
                toggles[#toggles + 1] = word
            end
            return { values = values, toggles = toggles }
        end
        return pick
    end
end

local tty = os.getenv("FAKE_TTY")
if tty then
    require("dev.cmd.box").interactive = function()
        return tty == "1"
    end
    local real_isatty = dev_os.isatty
    dev_os.isatty = function(fd)
        if fd == 0 then
            return tty == "1"
        end
        return real_isatty(fd)
    end
end
