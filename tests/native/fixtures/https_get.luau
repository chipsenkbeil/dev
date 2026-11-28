--!strict
local dev_os = require("@dev/os")
local http = require("@dev/http")

local url = "https://github.com"
local reply, reason, kind = http.request({ url = url, connect_timeout = 20, timeout = 40 })
if not reply then
    print(string.format("FAIL GET %s: %s (%s)", url, tostring(reason), tostring(kind)))
    dev_os.exit(1)
end
print(string.format("GET %s -> %d", url, reply.status))
if reply.status < 200 or reply.status >= 300 then
    dev_os.exit(1)
end
