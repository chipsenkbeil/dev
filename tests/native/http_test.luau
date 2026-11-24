local fs = require("@dev/fs")
local http = require("@dev/http")
local dev_os = require("@dev/os")

local failed = false
local function check(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        failed = true
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local REFUSED = "http://127.0.0.1:1/"

check("request to a closed port fails with kind connect and names the host", function()
    local reply, reason, kind = http.request({ url = REFUSED, connect_timeout = 5, timeout = 10 })
    assert(reply == nil)
    assert(string.find(reason, "127.0.0.1", 1, true), reason)
    assert(kind == "connect", tostring(kind))
end)

check("request with a malformed url fails with a kind", function()
    local reply, reason, kind = http.request({ url = "not a url" })
    assert(reply == nil)
    assert(type(reason) == "string")
    assert(kind == "other", tostring(kind))
end)

check("request with both body and file raises", function()
    local ok = pcall(http.request, { url = REFUSED, body = "x", file = "/tmp/x" })
    assert(not ok)
end)

check("request without a url raises", function()
    local ok = pcall(http.request, {})
    assert(not ok)
end)

check("download to a closed port fails and writes no file", function()
    local dir = assert(fs.mktemp({ prefix = "http-test", dir = true }))
    local path = dir .. "/out.bin"
    local reply, reason, kind = http.download({ url = REFUSED, path = path, timeout = 10 })
    assert(reply == nil)
    assert(string.find(reason, "127.0.0.1", 1, true), reason)
    assert(kind == "connect", tostring(kind))
    assert(not fs.exists(path))
    fs.remove(dir, { recursive = true })
end)

check("module exposes request and download", function()
    assert(type(http.request) == "function")
    assert(type(http.download) == "function")
end)

if failed then
    dev_os.exit(1)
end
