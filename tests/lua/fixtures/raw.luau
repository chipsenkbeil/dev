local dev_os = require("@dev/os")

local term = require("@dev/term")

local restore = term.raw(0)
local keys = {}
for i = 1, tonumber(arg[1]) or 1 do
    keys[i] = term.read_key(0)
end
restore()
restore()
for _, key in ipairs(keys) do
    dev_os.stdout:write(key, "\n")
end
