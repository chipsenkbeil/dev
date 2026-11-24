local dev_os = require("dev.os")
local fs = require("dev.fs")

local uid = dev_os.getenv("FAKE_UID")
if uid and dev_os.getuid() ~= 0 then
    dev_os.getuid = function()
        return tonumber(uid)
    end
end

local name = dev_os.getenv("FAKE_OS")
if name then
    dev_os.name = function()
        return name
    end
end

local hidden = dev_os.getenv("FAKE_HIDE")
if hidden then
    local which = dev_os.which
    dev_os.which = function(tool)
        if (" " .. hidden .. " "):find(" " .. tool .. " ", 1, true) then
            return nil
        end
        return which(tool)
    end
end

local pick = dev_os.getenv("FAKE_PICK")
if pick then
    local picker = require("dev.ui.picker")
    local queue = {}
    for word in pick:gmatch("%S+") do
        queue[#queue + 1] = word
    end
    local used = 0
    picker.run = function(_, items, opts)
        local log = dev_os.getenv("PICK_LOG")
        if log then
            local lines = { "picker title=" .. opts.title .. " auto=" .. tostring(opts.auto) }
            if opts.note then
                lines[1] ..= " note=" .. opts.note
            end
            if opts.initial then
                lines[1] ..= " initial=" .. opts.initial
            end
            lines[1] ..= "\n"
            for _, item in ipairs(items) do
                local line = item.value .. "\t" .. table.concat(item.cells, "\t")
                if item.disabled then
                    line ..= "\t!" .. item.disabled
                end
                lines[#lines + 1] = line .. "\n"
            end
            assert(fs.append(log, table.concat(lines)))
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
            for word in (dev_os.getenv("FAKE_PICK_TOGGLES") or ""):gmatch("%S+") do
                toggles[#toggles + 1] = word
            end
            return { values = values, toggles = toggles }
        end
        return pick
    end
end

local tty = dev_os.getenv("FAKE_TTY")
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

if dev_os.getenv("FAKE_SAFE_EXE") then
    require("dev.cmd.tools").unsafe_binary = function()
        return nil
    end
end
