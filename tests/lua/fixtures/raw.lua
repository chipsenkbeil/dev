dofile(arg[0]:match("^(.*)/fixtures/[^/]*$") .. "/boot.lua")

local term = require("dev.term")

local restore = term.raw(0)
local key = term.read_key(0)
restore()
restore()
io.write(key, "\n")
