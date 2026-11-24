local dev_os = require("dev.os")
local source = require("dev.pkg.source")

dev_os.exit(source.main({
    tool = "stow",
    binary = "stow",
    needs = { "make", "perl" },
    build = function(prefix)
        return {
            { "./configure", "--prefix=" .. prefix },
            { "make" },
            { "make", "install" },
        }
    end,
}, arg))
