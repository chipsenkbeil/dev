local testing = require("dev.testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local function scratch()
    local dir = assert(fs.mktemp({ prefix = "fs-test", dir = true }))
    return dir
end

testing.test("mktemp makes a directory in directory mode and a file otherwise", function()
    local dir = assert(fs.mktemp({ prefix = "fs-test", dir = true }))
    local file = assert(fs.mktemp({ prefix = "fs-test" }))
    testing.ok(fs.is_dir(dir), "directory mode should make a directory")
    testing.ok(fs.is_file(file), "default mode should make a file")
    testing.ok(fs.basename(dir):find("^fs%-test%."), "prefix should lead the name")
    fs.remove(dir, { recursive = true })
    fs.remove(file)
end)

testing.test("list returns names with newlines and quotes, sorted", function()
    local dir = scratch()
    for _, name in ipairs({ "a\nb", "it's", "z" }) do
        assert(fs.write(dir .. "/" .. name, ""))
    end
    testing.eq(fs.list(dir), { "a\nb", "it's", "z" })
    fs.remove(dir, { recursive = true })
end)

testing.test("list fails for a missing directory", function()
    testing.eq((fs.list("/no/such/dir-xyz")), nil)
end)

testing.test("stat reports uid, size and kind", function()
    local dir = scratch()
    testing.eq(fs.stat(dir).uid, tonumber((devos.capture({ "id", "-u" }))))
    testing.eq(fs.stat(dir).kind, "dir")
    assert(fs.write(dir .. "/f", "hello"))
    local st = fs.stat(dir .. "/f")
    testing.eq(st.size, 5)
    testing.eq(st.kind, "file")
    testing.eq(bit.band(st.mode, 511) > 0, true)
    assert(fs.symlink("f", dir .. "/l"))
    testing.eq(fs.stat(dir .. "/l").kind, "link")
    testing.eq(fs.stat(dir .. "/missing"), nil)
    fs.remove(dir, { recursive = true })
end)

testing.test("read and write round-trip binary text", function()
    local dir = scratch()
    assert(fs.write(dir .. "/f", "a\0b\n"))
    testing.eq(fs.read(dir .. "/f"), "a\0b\n")
    local text, err = fs.read(dir .. "/missing")
    testing.eq(text, nil)
    testing.ok(type(err) == "string", "a failed read should say why")
    fs.remove(dir, { recursive = true })
end)

testing.test("predicates tell files, directories, links and executables apart", function()
    local dir = scratch()
    assert(fs.write(dir .. "/f", ""))
    assert(fs.symlink("nowhere", dir .. "/broken"))
    testing.ok(fs.exists(dir .. "/f") and not fs.exists(dir .. "/broken"), "exists follows links")
    testing.ok(fs.is_link(dir .. "/broken"), "a broken link is still a link")
    testing.ok(not fs.is_exec(dir .. "/f"), "a new file is not executable")
    devos.run({ "chmod", "+x", dir .. "/f" })
    testing.ok(fs.is_exec(dir .. "/f"), "chmod +x makes it executable")
    testing.ok(fs.is_dir(dir) and not fs.is_file(dir), "a directory is not a file")
    fs.remove(dir, { recursive = true })
end)

testing.test("mkdir, remove, readlink and realpath", function()
    local dir = scratch()
    testing.eq((fs.mkdir(dir .. "/a/b")), nil)
    testing.eq(fs.mkdir(dir .. "/a/b", { parents = true }), true)
    testing.eq(fs.mkdir(dir .. "/a/b", { parents = true }), true)
    testing.eq((fs.remove(dir .. "/a")), nil)
    assert(fs.symlink("a/b", dir .. "/l"))
    testing.eq(fs.readlink(dir .. "/l"), "a/b")
    testing.eq(fs.readlink(dir .. "/a"), nil)
    testing.eq(fs.realpath(dir .. "/l"), fs.realpath(dir .. "/a/b"))
    testing.eq(fs.remove(dir, { recursive = true }), true)
    testing.ok(not fs.exists(dir), "recursive remove deletes the tree")
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
    local dir = scratch()
    assert(fs.mkdir(dir .. "/real"))
    assert(fs.write(dir .. "/real/a", ""))
    assert(fs.symlink("real", dir .. "/link"))
    testing.eq(fs.list(dir .. "/link"), { "a" })
    fs.remove(dir, { recursive = true })
end)

testing.test("a relative path that starts with a dash works everywhere", function()
    local dir = scratch()
    local path = support.absolute_path()
    local snippet = ("package.path = %q; local fs = require('dev.fs'); "):format(path)
        .. "assert(fs.write('-x', 'abc')); assert(fs.mkdir('-d')); assert(fs.write('-d/in', ''))"
        .. "; io.write(tostring(fs.exists('-x')), tostring(fs.is_file('-x')), tostring(fs.is_dir('-d')), "
        .. "fs.stat('-x').size, table.concat(fs.list('-d'), ','))"
    local out = devos.capture({ "luajit", "-e", snippet }, { cwd = dir })
    testing.eq(out, "truetruetrue3in")
    fs.remove(dir, { recursive = true })
end)

testing.test("read of a directory fails with a message", function()
    local dir = scratch()
    local text, err = fs.read(dir)
    testing.eq(text, nil)
    testing.ok(type(err) == "string" and err ~= "", "expected a message")
    fs.remove(dir, { recursive = true })
end)

testing.test("stat takes the GNU branch when stat --version succeeds", function()
    local dir = scratch()
    assert(
        fs.write(
            dir .. "/stat",
            '#!/bin/sh\n[ "$1" = --version ] && exit 0\nprintf "7 81a4 5\\n"\n'
        )
    )
    devos.run({ "chmod", "+x", dir .. "/stat" })
    local path = support.absolute_path()
    local snippet = ("package.path = %q; local st = require('dev.fs').stat('/anything'); "):format(
        path
    ) .. "io.write(st.uid, ' ', st.mode, ' ', st.size, ' ', st.kind)"
    local out = devos.capture(
        { "luajit", "-e", snippet },
        { env = { PATH = dir .. ":" .. os.getenv("PATH") } }
    )
    testing.eq(out, "7 33188 5 file")
    fs.remove(dir, { recursive = true })
end)

testing.test("an empty path is never the current directory", function()
    testing.eq(fs.exists(""), false)
    testing.eq(fs.is_dir(""), false)
    testing.eq(fs.list(""), nil)
    testing.eq(fs.stat(""), nil)
end)
