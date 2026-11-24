local dev_os = require("@dev/os")
local runtime = require("@dev/runtime")

local here = arg[0]:match("^(.*)/fixtures/[^/]*$") or "."
runtime.dofile(here .. "/fake_env.luau")

local parsed, message = runtime.parse_globals({ table.unpack(arg) })
if not parsed then
    dev_os.stderr:write(message, "\n")
    dev_os.exit(2)
end
dev_os.exit(require("@dev/cli").main(parsed))
