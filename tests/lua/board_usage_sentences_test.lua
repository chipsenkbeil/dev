local testing = require("dev.testing")
local dev_os = require("dev.os")
local fs = require("dev.fs")

local REPO = dev_os.capture({ "pwd" }):gsub("\n$", "")
local LUA_ROOT = REPO .. "/dotfiles/bin/.local/share/dev/lua/dev/"
local BOARD_SOURCE = LUA_ROOT .. "cmd/board.lua"
local MOVED_SOURCES = {
    LUA_ROOT .. "board/guards.lua",
    LUA_ROOT .. "board/ship.lua",
    LUA_ROOT .. "board/runcard.lua",
    LUA_ROOT .. "board/setup.lua",
    LUA_ROOT .. "board/stale.lua",
    LUA_ROOT .. "board/wait.lua",
}

local function source_lines()
    local lines = {}
    for _, path in ipairs({ BOARD_SOURCE, unpack(MOVED_SOURCES) }) do
        local text = assert(fs.read(path))
        for line in (text .. "\n"):gmatch("([^\n]*)\n") do
            lines[#lines + 1] = line
        end
    end
    return lines
end

local function literals(text)
    local found = {}
    for piece in text:gmatch('"([^"]*)"') do
        found[#found + 1] = piece
    end
    return found
end

testing.test("every literal board usage message is a capitalised sentence with a period", function()
    local checked = 0
    for number, line in ipairs(source_lines()) do
        local rest = line:match('[^%w_]usage%((".*)$')
        if rest then
            local pieces = literals(rest)
            local first = pieces[1]
            if first then
                local where = BOARD_SOURCE .. ":" .. number .. ": " .. line
                testing.ok(first:find("^%u"), where)
                testing.ok(pieces[#pieces]:find("%.$"), where)
                checked = checked + 1
            end
        end
    end
    testing.ok(checked >= 40, "only " .. checked .. " usage messages checked")
end)

testing.test("no board usage refusal opens with a flag, a variable or a lowercase word", function()
    local sources = {
        BOARD_SOURCE,
        LUA_ROOT .. "board/wiring.lua",
        LUA_ROOT .. "board/runner.lua",
        unpack(MOVED_SOURCES),
    }
    local checked = 0
    for _, path in ipairs(sources) do
        local text = assert(fs.read(path))
        local from = 1
        while true do
            local _, stop = text:find("[^%w_]usage%(", from)
            if not stop then
                break
            end
            from = stop + 1
            local rest = text:sub(stop + 1):match("^%s*(.*)$"):gsub("^string%.format%(%s*", "")
            local line = select(2, text:sub(1, stop):gsub("\n", "")) + 1
            local where = path .. ":" .. line .. ": " .. rest:sub(1, 60)
            testing.ok(rest:find('^"%u') or rest:find("^[%w_%.]+%)"), where)
            checked = checked + 1
        end
    end
    testing.ok(checked >= 60, "only " .. checked .. " usage calls checked")
end)

testing.test("no board message joins a lead to a list with a comma and the word are", function()
    for number, line in ipairs(source_lines()) do
        for _, piece in ipairs(literals(line)) do
            testing.ok(
                not piece:find(", the %a+ are "),
                BOARD_SOURCE .. ":" .. number .. ": " .. piece
            )
        end
    end
end)
