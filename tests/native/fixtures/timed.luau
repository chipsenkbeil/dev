local dev_os = require("@dev/os")

local unique = tonumber(dev_os.getenv("DEV_TEST_UNIQUE"))
dev_os.stdout:write("ready\n")
dev_os.stdout:flush()
dev_os.capture_timed({
    "sh",
    "-c",
    ("sleep %d & sleep %d; wait"):format(unique, unique + 1),
}, 60)
dev_os.stdout:write("not interrupted\n")
