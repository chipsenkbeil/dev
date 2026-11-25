local testing = require("@dev/testing")
local dev_os = require("@dev/os")
local fs = require("@dev/fs")
local support = require("./support")

local function scratch()
    local dir = assert(fs.mktemp({ prefix = "fs-test", dir = true }))
    return dir
end

testing.test("mktemp makes a directory in directory mode and a file otherwise", function()
    -- Make one temporary directory and one temporary file
    local dir = assert(fs.mktemp({ prefix = "fs-test", dir = true }))
    local file = assert(fs.mktemp({ prefix = "fs-test" }))

    -- Check the kind and the prefix of each
    testing.ok(fs.is_dir(dir), "directory mode should make a directory")
    testing.ok(fs.is_file(file), "default mode should make a file")
    testing.ok(fs.basename(dir):find("^fs%-test%."), "prefix should lead the name")

    -- Remove both
    fs.remove(dir, { recursive = true })
    fs.remove(file)
end)

testing.test("list returns names with newlines and quotes, sorted", function()
    -- Make files named with a newline and a quote
    local dir = scratch()
    for _, name in ipairs({ "a\nb", "it's", "z" }) do
        assert(fs.write(dir .. "/" .. name, ""))
    end

    -- List them sorted
    testing.eq(fs.list(dir), { "a\nb", "it's", "z" })

    -- Remove the directory
    fs.remove(dir, { recursive = true })
end)

testing.test("list fails for a missing directory", function()
    testing.eq((fs.list("/no/such/dir-xyz")), nil)
end)

testing.test("stat reports uid, size and kind", function()
    -- Stat a directory
    local dir = scratch()
    testing.eq(fs.stat(dir).uid, tonumber((dev_os.capture({ "id", "-u" }))))
    testing.eq(fs.stat(dir).kind, "dir")

    -- Stat a file
    assert(fs.write(dir .. "/f", "hello"))
    local st = fs.stat(dir .. "/f")
    testing.eq(st.size, 5)
    testing.eq(st.kind, "file")
    testing.eq(bit32.band(st.mode, 511) > 0, true)

    -- Stat a link and a missing path
    assert(fs.symlink("f", dir .. "/l"))
    testing.eq(fs.stat(dir .. "/l").kind, "link")
    testing.eq(fs.stat(dir .. "/missing"), nil)

    -- Remove the directory
    fs.remove(dir, { recursive = true })
end)

testing.test("read and write round-trip binary text", function()
    -- Write and read back text with a NUL
    local dir = scratch()
    assert(fs.write(dir .. "/f", "a\0b\n"))
    testing.eq(fs.read(dir .. "/f"), "a\0b\n")

    -- Fail to read a missing file with a reason
    local text, err = fs.read(dir .. "/missing")
    testing.eq(text, nil)
    testing.ok(type(err) == "string", "a failed read should say why")

    -- Remove the directory
    fs.remove(dir, { recursive = true })
end)

testing.test("predicates tell files, directories, links and executables apart", function()
    -- Make a file and a broken link
    local dir = scratch()
    assert(fs.write(dir .. "/f", ""))
    assert(fs.symlink("nowhere", dir .. "/broken"))

    -- Tell the file from the broken link
    testing.ok(fs.exists(dir .. "/f") and not fs.exists(dir .. "/broken"), "exists follows links")
    testing.ok(fs.is_link(dir .. "/broken"), "a broken link is still a link")

    -- Tell the file before and after it is made executable
    testing.ok(not fs.is_exec(dir .. "/f"), "a new file is not executable")
    dev_os.run({ "chmod", "+x", dir .. "/f" })
    testing.ok(fs.is_exec(dir .. "/f"), "chmod +x makes it executable")

    -- Tell the directory from a file
    testing.ok(fs.is_dir(dir) and not fs.is_file(dir), "a directory is not a file")

    -- Remove the directory
    fs.remove(dir, { recursive = true })
end)

testing.test("mkdir, remove, readlink and realpath", function()
    -- Make nested directories only with parents and remove only a leaf
    local dir = scratch()
    testing.eq((fs.mkdir(dir .. "/a/b")), nil)
    testing.eq(fs.mkdir(dir .. "/a/b", { parents = true }), true)
    testing.eq(fs.mkdir(dir .. "/a/b", { parents = true }), true)
    testing.eq((fs.remove(dir .. "/a")), nil)

    -- Read a link and resolve it
    assert(fs.symlink("a/b", dir .. "/l"))
    testing.eq(fs.readlink(dir .. "/l"), "a/b")
    testing.eq(fs.readlink(dir .. "/a"), nil)
    testing.eq(fs.realpath(dir .. "/l"), fs.realpath(dir .. "/a/b"))

    -- Remove the tree
    testing.eq(fs.remove(dir, { recursive = true }), true)
    testing.ok(not fs.exists(dir), "recursive remove deletes the tree")
end)

testing.test("move renames to a free path and refuses a taken one", function()
    -- Make a directory to move and a path that is taken
    local dir = scratch()
    assert(fs.mkdir(dir .. "/a"))
    assert(fs.write(dir .. "/a/f", "x"))
    assert(fs.mkdir(dir .. "/taken"))

    -- Refuse the taken path
    testing.eq((fs.move(dir .. "/a", dir .. "/taken")), nil)

    -- Move to a free path
    testing.eq(fs.move(dir .. "/a", dir .. "/b"), true)
    testing.eq(fs.read(dir .. "/b/f"), "x")
    testing.ok(not fs.exists(dir .. "/a"), "the old path is gone")

    -- Remove the directory
    fs.remove(dir, { recursive = true })
end)

testing.test("join, dirname and basename are pure", function()
    testing.eq(fs.join("/a/", "b", "c"), "/a/b/c")
    testing.eq(fs.dirname("/a/b"), "/a")
    testing.eq(fs.dirname("/a"), "/")
    testing.eq(fs.dirname("a"), ".")
    testing.eq(fs.dirname("a/b/"), "a")
    testing.eq(fs.basename("/a/b/"), "b")
    testing.eq(fs.basename("/"), "/")
end)

testing.test("list follows a symlinked start directory", function()
    -- Link to a directory that holds a file
    local dir = scratch()
    assert(fs.mkdir(dir .. "/real"))
    assert(fs.write(dir .. "/real/a", ""))
    assert(fs.symlink("real", dir .. "/link"))

    -- List through the link
    testing.eq(fs.list(dir .. "/link"), { "a" })

    -- Remove the directory
    fs.remove(dir, { recursive = true })
end)

testing.test("a relative path that starts with a dash works everywhere", function()
    -- Build a script that uses dash-led relative paths
    local dir = scratch()
    local snippet = "local fs = require('@dev/fs'); "
        .. "assert(fs.write('-x', 'abc')); assert(fs.mkdir('-d')); assert(fs.write('-d/in', ''))"
        .. "; require('@dev/os').stdout:write(tostring(fs.exists('-x')), tostring(fs.is_file('-x')), tostring(fs.is_dir('-d')), "
        .. "fs.stat('-x').size, table.concat(fs.list('-d'), ','))"

    -- Run it inside the directory and read its answers
    local out = dev_os.capture(support.eval(snippet), { cwd = dir })
    testing.eq(out, "truetruetrue3in")

    -- Remove the directory
    fs.remove(dir, { recursive = true })
end)

testing.test("read of a directory fails with a message", function()
    -- Read a directory
    local dir = scratch()
    local text, err = fs.read(dir)

    -- Get a message and no text
    testing.eq(text, nil)
    testing.ok(type(err) == "string" and err ~= "", "expected a message")

    -- Remove the directory
    fs.remove(dir, { recursive = true })
end)

testing.test("an empty path is never the current directory", function()
    testing.eq(fs.exists(""), false)
    testing.eq(fs.is_dir(""), false)
    testing.eq(fs.list(""), nil)
    testing.eq(fs.stat(""), nil)
end)
