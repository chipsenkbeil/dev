local dev_os = require("@dev/os")

dev_os.on_exit(function()
    dev_os.stdout:write("cleanup\n")
end)
dev_os.stdout:write("ready\n")
dev_os.stdout:flush()
dev_os.nap(30)
dev_os.stdout:write("not interrupted\n")
