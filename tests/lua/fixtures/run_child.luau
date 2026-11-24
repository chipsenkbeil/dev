local dev_os = require("dev.os")

dev_os.exit(dev_os.run({ table.unpack(arg) }))
