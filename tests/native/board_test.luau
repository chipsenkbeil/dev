local dev_os = require("dev.os")
local runtime = require("dev.runtime")

local failures = 0

local function check(name, body)
    local ok, err = pcall(body)
    if ok then
        print("ok   " .. name)
    else
        failures += 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local function same(actual, expected)
    if actual ~= expected then
        error(string.format("expected %s, got %s", tostring(expected), tostring(actual)), 2)
    end
end

check("every board module and helper command compiles as Luau", function()
    local files = { "luau/dev/board.luau" }
    for _, dir in ipairs({ "luau/dev/board", "luau/dev/commands/__board" }) do
        for _, name in ipairs(runtime.assets(dir)) do
            if name:match("%.luau$") then
                files[#files + 1] = dir .. "/" .. name
            end
        end
    end
    same(#files > 30, true)
    for _, file in ipairs(files) do
        local source = runtime.asset(file)
        same(type(source), "string")
        local chunk, err = runtime.load(source, "@" .. file)
        if not chunk then
            error(file .. ": " .. tostring(err))
        end
    end
end)

check("%z splits NUL-separated output the way the board's git readers expect", function()
    local words = {}
    for word in ("a b\0c\0"):gmatch("([^%z]+)%z") do
        words[#words + 1] = word
    end
    same(#words, 2)
    same(words[1], "a b")
    same(words[2], "c")
    same((("x\0y"):gsub("%z", "\n")), "x\ny")
end)

check("the checks fingerprint keeps the LuaJIT values under bit32", function()
    local board_check = require("dev.board.check")
    same(board_check.fingerprint({}), "811c9dc5")
    same(board_check.fingerprint({ "a" }), "2524c6d2")
    same(board_check.fingerprint({ "dev lint", "dev test" }), "29343d7a")
end)

check("a dev.http failure kind names the curl exit the messages keep", function()
    local board = require("dev.board")
    same(board.curl_exit("resolve"), 6)
    same(board.curl_exit("connect"), 7)
    same(board.curl_exit("timeout"), 28)
    same(board.curl_exit("tls"), 35)
    same(board.curl_exit("other"), 1)
    same(board.curl_exit(nil), 1)
end)

if failures > 0 then
    print(failures .. " failed")
    dev_os.exit(1)
end
