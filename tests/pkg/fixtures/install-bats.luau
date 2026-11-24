local dev_os = require("@dev/os")
local source = require("@dev/pkg/source")

dev_os.exit(source.main({
    tool = "bats",
    binary = "bats",
    needs = { "bash" },
    build = function(prefix)
        return { { "bash", "./install.sh", prefix } }
    end,
}, arg))
