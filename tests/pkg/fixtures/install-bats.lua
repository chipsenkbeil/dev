local source = require("dev.pkg.source")

os.exit(source.main({
    tool = "bats",
    binary = "bats",
    needs = { "bash" },
    build = function(prefix)
        return { { "bash", "./install.sh", prefix } }
    end,
}, arg))
