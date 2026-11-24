local globals = require("dev.globals")
local runtime = require("dev.runtime")
runtime.assets("docs")
print(globals.level, #globals.args, globals.remote, runtime.version)
