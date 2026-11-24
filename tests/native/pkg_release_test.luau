local dev_os = require("dev.os")
local fs = require("dev.fs")

if dev_os.stderr == nil or fs.mktemp == nil then
    print("SKIP the native os and fs modules are not built into this binary yet")
    return
end

local failures = 0

local function check(name, body)
    local ok, err = pcall(body)
    if ok then
        print("ok   " .. name)
    else
        failures += 1
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local release = require("dev.pkg.release")
local SHA = string.rep("a", 64)
local dir = assert(fs.mktemp({ prefix = "pins", dir = true }))

local function read_pin(url)
    local path = dir .. "/releases.tsv"
    assert(fs.write(path, "name version sha256 url path\ntool 1.0 " .. SHA .. " " .. url .. " -\n"))
    return release.read(path)
end

local function refused(url)
    local pins, err = read_pin(url)
    assert(pins == nil, url .. " was accepted")
    assert(tostring(err):find("must be https and a plain word", 1, true), tostring(err))
end

check("an https url is allowed", function()
    assert(read_pin("https://example.com/tool"))
end)

check("an http url to a loopback host is allowed on any port", function()
    assert(read_pin("http://127.0.0.1:8080/tool"))
    assert(read_pin("http://localhost/tool"))
    assert(read_pin("http://localhost:9/tool"))
    assert(read_pin("http://[::1]:8000/tool"))
end)

check("an http url to any other host is refused", function()
    refused("http://example.com/tool")
    refused("http://localhost.evil.com/tool")
    refused("http://127.0.0.1@evil.com/tool")
    refused("http://127.0.0.2/tool")
    refused("ftp://localhost/tool")
    refused("http://[::ffff:127.0.0.1]/tool")
    refused("http://LOCALHOST/tool")
end)

check("root refuses a binary that its group or others can write", function()
    local tools = require("dev.cmd.tools")
    local path = dir .. "/dev"
    assert(fs.write(path, "x"))
    assert(fs.chmod(path, 438))
    assert(tools.unsafe_binary(path) == path)
end)

check("root accepts a binary and a folder it owns that nobody else can write", function()
    local tools = require("dev.cmd.tools")
    assert(tools.unsafe_binary("/usr/bin/env") == nil)
end)

fs.remove(dir, { recursive = true })
if failures > 0 then
    dev_os.exit(1)
end
