local fs = require("dev.fs")
local lock = require("dev.lock")
local dev_os = require("dev.os")

local failed = false
local function check(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        failed = true
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local function fresh()
    local dir = assert(fs.mktemp({ prefix = "lock-test", dir = true }))
    return dir, dir .. "/l.lock"
end

check("try_lock takes a free lock and release frees it", function()
    local dir, path = fresh()
    local handle = assert(lock.try_lock(path))
    local second, reason = lock.try_lock(path)
    assert(second == nil)
    assert(string.find(reason, "held", 1, true))
    handle:release()
    local third = assert(lock.try_lock(path))
    third:release()
    fs.remove(dir, { recursive = true })
end)

check("a collected handle releases the lock", function()
    local dir, path = fresh()
    do
        local handle = assert(lock.try_lock(path))
        handle = nil
    end
    local deadline = os.clock() + 5
    local again
    while os.clock() < deadline do
        collectgarbage()
        again = lock.try_lock(path)
        if again then
            break
        end
    end
    assert(again, "lock still held after collection")
    again:release()
    fs.remove(dir, { recursive = true })
end)

check("shared locks coexist and block an exclusive one", function()
    local dir, path = fresh()
    local a = assert(lock.try_lock(path, { shared = true }))
    local b = assert(lock.try_lock(path, { shared = true }))
    assert(lock.try_lock(path) == nil)
    a:release()
    b:release()
    fs.remove(dir, { recursive = true })
end)

check("lock gives up at its timeout", function()
    local dir, path = fresh()
    local held = assert(lock.try_lock(path))
    local started = os.clock()
    local second, reason = lock.lock(path, { timeout = 0.2 })
    assert(second == nil)
    assert(string.find(reason, "timed out", 1, true))
    assert(os.clock() - started < 5)
    held:release()
    fs.remove(dir, { recursive = true })
end)

check("lock acquires a free lock without waiting", function()
    local dir, path = fresh()
    local handle = assert(lock.lock(path, { timeout = 1 }))
    handle:release()
    fs.remove(dir, { recursive = true })
end)

check("the lock file is created with the given mode", function()
    local dir, path = fresh()
    local handle = assert(lock.try_lock(path, { mode = 384 }))
    local info = assert(fs.stat(path))
    assert(info.mode % 512 == 384, "mode " .. tostring(info.mode))
    handle:release()
    fs.remove(dir, { recursive = true })
end)

check("a lock in a missing folder returns a reason", function()
    local handle, reason = lock.try_lock("/nonexistent/dev-lock-test/l.lock")
    assert(handle == nil)
    assert(string.find(reason, "No such file or directory", 1, true))
end)

check("a negative timeout raises", function()
    local dir, path = fresh()
    local ok = pcall(lock.lock, path, { timeout = -1 })
    assert(not ok)
    fs.remove(dir, { recursive = true })
end)

if failed then
    dev_os.exit(1)
end
