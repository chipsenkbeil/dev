local runtime = require("dev.runtime")

local root = arg[0]:match("^(.*)/tests/lua/") or "."
runtime.add_path(root .. "/tests/lua")
runtime.add_path(root .. "/.dev/lib")
