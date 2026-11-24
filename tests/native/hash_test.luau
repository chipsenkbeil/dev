local fs = require("dev.fs")
local hash = require("dev.hash")
local dev_os = require("dev.os")

local failed = false
local function check(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        failed = true
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
local ABC = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

check("sha256 of empty text", function()
    assert(hash.sha256("") == EMPTY)
end)

check("sha256 of abc is lowercase hex", function()
    assert(hash.sha256("abc") == ABC)
end)

check("sha256 reads binary text", function()
    assert(#hash.sha256("a\0b") == 64)
end)

check("sha256_file matches sha256 of the same bytes", function()
    local path = assert(fs.mktemp({ prefix = "hash-test" }))
    assert(fs.write(path, "abc"))
    assert(hash.sha256_file(path) == ABC)
    fs.remove(path)
end)

check("sha256_file streams a file larger than one chunk", function()
    local path = assert(fs.mktemp({ prefix = "hash-test" }))
    local text = string.rep("x", 200000)
    assert(fs.write(path, text))
    assert(hash.sha256_file(path) == hash.sha256(text))
    fs.remove(path)
end)

check("sha256_file names a missing file", function()
    local digest, reason = hash.sha256_file("/nonexistent/dev-hash-test")
    assert(digest == nil)
    assert(string.find(reason, "/nonexistent/dev-hash-test", 1, true))
    assert(string.find(reason, "No such file or directory", 1, true))
end)

if failed then
    dev_os.exit(1)
end
