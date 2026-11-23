local source = require("dev.pkg.source")

os.exit(source.main({
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
