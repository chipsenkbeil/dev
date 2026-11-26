local fs = require("@dev/fs")
local dev_os = require("@dev/os")

local failed = false
local function check(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        failed = true
        print("FAIL " .. name .. ": " .. tostring(err))
    end
end

local root = assert(fs.mktemp({ prefix = "fs-test", dir = true }))

local function is_root()
    local probe = root .. "/probe"
    assert(fs.write(probe, "x", { mode = 0 }))
    local fd = fs.open_nofollow(probe)
    if fd then
        fs.close(fd)
    end
    fs.chmod(probe, 384)
    fs.remove(probe)
    return fd ~= nil
end

check("Kind has the four constants", function()
    assert(fs.Kind.FILE == "file" and fs.Kind.DIR == "dir")
    assert(fs.Kind.LINK == "link" and fs.Kind.OTHER == "other")
end)

check("write then read round trips bytes", function()
    local path = root .. "/a.txt"
    assert(fs.write(path, "a\0b\n") == true)
    assert(fs.read(path) == "a\0b\n")
end)

check("read of a missing file keeps the io.open reason", function()
    local text, reason = fs.read(root .. "/missing")
    assert(text == nil)
    assert(reason == root .. "/missing: No such file or directory", reason)
end)

check("write replaces and append adds", function()
    local path = root .. "/b.txt"
    assert(fs.write(path, "one"))
    assert(fs.write(path, "two"))
    assert(fs.append(path, "+three"))
    assert(fs.read(path) == "two+three")
end)

check("write applies mode to a new file only", function()
    local path = root .. "/secret"
    assert(fs.write(path, "x", { mode = 384 }))
    assert(fs.stat(path).mode % 512 == 384)
    assert(fs.chmod(path, 420))
    assert(fs.write(path, "y", { mode = 384 }))
    assert(fs.stat(path).mode % 512 == 420)
end)

check("atomic write replaces the file and leaves no temp", function()
    local dir = root .. "/atomic"
    assert(fs.mkdir(dir))
    assert(fs.write(dir .. "/f", "old"))
    assert(fs.write(dir .. "/f", "new", { atomic = true, mode = 384 }))
    assert(fs.read(dir .. "/f") == "new")
    local names = assert(fs.list(dir))
    assert(#names == 1 and names[1] == "f")
end)

check("failed atomic write keeps the old file whole", function()
    -- Write an old file
    local path = root .. "/keep"
    assert(fs.write(path, "old"))

    -- Make the folder unwritable and try an atomic write
    assert(fs.chmod(root .. "/atomic", 320))
    local ok, reason = fs.write(root .. "/atomic/f", "new", { atomic = true })
    fs.chmod(root .. "/atomic", 448)

    -- Check the old file is whole
    if not is_root() then
        assert(ok == nil and reason)
        assert(fs.read(root .. "/atomic/f") == "new")
    end
    assert(fs.read(path) == "old")
end)

check("mkdir parents accepts an existing folder, plain mkdir does not", function()
    local dir = root .. "/p/q/r"
    assert(fs.mkdir(dir, { parents = true }))
    assert(fs.mkdir(dir, { parents = true }))
    assert(fs.is_dir(dir))
    local ok, reason = fs.mkdir(dir)
    assert(ok == nil and reason)
end)

check("remove, recursive and missing", function()
    -- Refuse a plain remove of a folder with content
    local dir = root .. "/rm"
    assert(fs.mkdir(dir .. "/sub", { parents = true }))
    assert(fs.write(dir .. "/sub/f", "x"))
    local ok, reason = fs.remove(dir)
    assert(ok == nil and reason)

    -- Remove it recursively, then again while missing
    assert(fs.remove(dir, { recursive = true }))
    assert(not fs.exists(dir))
    assert(fs.remove(dir, { recursive = true }))
    assert(fs.remove(dir) == nil)

    -- Remove a plain file
    assert(fs.write(root .. "/gone", "x"))
    assert(fs.remove(root .. "/gone"))
end)

check("move refuses an existing target and moves otherwise", function()
    assert(fs.write(root .. "/m1", "1"))
    assert(fs.write(root .. "/m2", "2"))
    local ok, text = fs.move(root .. "/m1", root .. "/m2")
    assert(ok == nil and text == root .. "/m2 already exists", text)
    assert(fs.move(root .. "/m1", root .. "/m3"))
    assert(fs.read(root .. "/m3") == "1" and not fs.exists(root .. "/m1"))
end)

check("move returns the exists reason", function()
    assert(fs.write(root .. "/m5", "5"))
    assert(fs.write(root .. "/m6", "6"))
    local ok, _, reason = fs.move(root .. "/m5", root .. "/m6")
    assert(ok == nil and reason == fs.Reason.EXISTS, reason)
    assert(fs.Reason.EXISTS == "exists")
end)

check("move refuses a broken link as target", function()
    assert(fs.symlink("nowhere", root .. "/broken"))
    assert(fs.write(root .. "/m4", "4"))
    local ok, reason = fs.move(root .. "/m4", root .. "/broken")
    assert(ok == nil and reason == root .. "/broken already exists")
end)

check("list is sorted, hidden names included, no dots", function()
    -- Make a folder with three names
    local dir = root .. "/ls"
    assert(fs.mkdir(dir))
    assert(fs.write(dir .. "/b", ""))
    assert(fs.write(dir .. "/a", ""))
    assert(fs.write(dir .. "/.h", ""))

    -- List it sorted
    local names = assert(fs.list(dir))
    assert(table.concat(names, ",") == ".h,a,b", table.concat(names, ","))

    -- List an empty folder
    local empty = assert(fs.list(root .. "/p/q/r"))
    assert(#empty == 0)
end)

check("list follows a link and fails with cannot list", function()
    assert(fs.symlink(root .. "/ls", root .. "/lslink"))
    assert(#assert(fs.list(root .. "/lslink")) == 3)
    local names, text = fs.list(root .. "/nope")
    assert(names == nil and text == "cannot list " .. root .. "/nope")
end)

check("list returns the list reason", function()
    local names, _, reason = fs.list(root .. "/nope")
    assert(names == nil and reason == fs.Reason.LIST and reason == "list", reason)
end)

check("stat does not follow a link and reports raw mode", function()
    local file = assert(fs.stat(root .. "/a.txt"))
    assert(file.kind == "file" and file.size == 4)
    assert(file.mode // 4096 == 8, "mode " .. file.mode)
    assert(file.uid == fs.stat(root).uid)
    assert(fs.stat(root .. "/lslink").kind == "link")
    assert(fs.stat(root .. "/ls").kind == "dir")
    assert(fs.stat(root .. "/broken").kind == "link")
    assert(fs.stat(root .. "/missing") == nil)
end)

check("exists, is_dir, is_file follow links and is_link sees broken ones", function()
    assert(fs.exists(root .. "/lslink") and fs.is_dir(root .. "/lslink"))
    assert(fs.is_file(root .. "/a.txt") and not fs.is_dir(root .. "/a.txt"))
    assert(not fs.exists(root .. "/broken"))
    assert(fs.is_link(root .. "/broken") and fs.is_link(root .. "/lslink"))
    assert(not fs.is_link(root .. "/a.txt"))
end)

check("is_exec follows the permission bits", function()
    local path = root .. "/run.sh"
    assert(fs.write(path, "#!/bin/sh\n", { mode = 493 }))
    assert(fs.is_exec(path))
    assert(fs.chmod(path, 420))
    if not is_root() then
        assert(not fs.is_exec(path))
    end
    assert(not fs.is_exec(root .. "/missing"))
end)

check("realpath and readlink keep their messages", function()
    -- Resolve a link and a missing path
    local real = assert(fs.realpath(root .. "/lslink"))
    assert(real == assert(fs.realpath(root .. "/ls")))
    local ok, text = fs.realpath(root .. "/nope")
    assert(ok == nil and text == "cannot resolve " .. root .. "/nope")

    -- Read a link and a plain file
    assert(fs.readlink(root .. "/lslink") == root .. "/ls")
    local text, why = fs.readlink(root .. "/a.txt")
    assert(text == nil and why == root .. "/a.txt is not a link")
end)

check("realpath returns the resolve reason", function()
    local ok, _, reason = fs.realpath(root .. "/nope")
    assert(ok == nil and reason == fs.Reason.RESOLVE and reason == "resolve", reason)
end)

check("readlink returns the not_link reason", function()
    local text, _, reason = fs.readlink(root .. "/a.txt")
    assert(text == nil and reason == fs.Reason.NOT_LINK and reason == "not_link", reason)
end)

check("mktemp returns the temp reason", function()
    local saved = dev_os.getenv("TMPDIR")
    dev_os.setenv("TMPDIR", root .. "/missing")
    local path, text, reason = fs.mktemp()
    dev_os.setenv("TMPDIR", saved)
    assert(path == nil and reason == fs.Reason.TEMP and reason == "temp", reason)
    assert(text == "cannot make a temporary path under " .. root .. "/missing", text)
end)

check("mktemp names PREFIX.XXXXXX under TMPDIR", function()
    -- Make a named file
    local path = assert(fs.mktemp({ prefix = "named" }))
    assert(string.match(path, "/named%.%w%w%w%w%w%w$"), path)
    assert(fs.is_file(path))

    -- Make a default-named folder
    local dir = assert(fs.mktemp({ dir = true }))
    assert(string.match(dir, "/dev%.%w%w%w%w%w%w$"), dir)
    assert(fs.is_dir(dir))

    -- Clean up
    fs.remove(path)
    fs.remove(dir, { recursive = true })
end)

check("join, dirname and basename keep the edge cases", function()
    assert(fs.join("a", "b") == "a/b")
    assert(fs.join("/a/", "/b", "c") == "/a/b/c")
    assert(fs.dirname("a") == ".")
    assert(fs.dirname("/") == "/")
    assert(fs.dirname("/a") == "/")
    assert(fs.dirname("a/b/") == "a")
    assert(fs.basename("/") == "/")
    assert(fs.basename("") == "")
    assert(fs.basename("a/b/") == "b")
end)

check("open_nofollow, fstat, read_fd and close", function()
    -- Open the file and stat it
    local fd = assert(fs.open_nofollow(root .. "/a.txt"))
    assert(type(fd) == "number")
    local info = assert(fs.fstat(fd))
    assert(info.kind == "file" and info.size == 4)

    -- Read it in two parts
    assert(assert(fs.read_fd(fd, 2)) == "a\0")
    assert(assert(fs.read_fd(fd, 100)) == "b\n")

    -- Close it and see fstat fail
    fs.close(fd)
    local bad, reason = fs.fstat(fd)
    assert(bad == nil and reason)
end)

check("open_nofollow refuses a link", function()
    local fd, reason = fs.open_nofollow(root .. "/lslink")
    assert(fd == nil and reason)
end)

fs.remove(root, { recursive = true })

if failed then
    dev_os.exit(1)
end
