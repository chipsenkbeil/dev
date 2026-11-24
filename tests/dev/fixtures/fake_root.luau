local cli = require("@dev/cli")
local dev_os = require("@dev/os")
local runtime = require("@dev/runtime")

local repo = arg[0]:match("^(.*)/tests/dev/fixtures/[^/]*$") or "."
runtime.dofile(repo .. "/tests/lua/fake_env.luau")

local parsed, message = runtime.parse_globals({ table.unpack(arg) })
if not parsed then
    dev_os.stderr:write(message, "\n")
    dev_os.exit(2)
end
dev_os.exit(cli.main(parsed))
