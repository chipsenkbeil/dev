local t = require("dev.testing")
local devos = require("dev.os")
local fs = require("dev.fs")
local support = require("support")

local function scratch()
    local dir = assert(fs.mktemp({ prefix = "fs-test", dir = true }))
    return dir
end

t.test("mktemp makes a directory in directory mode and a file otherwise", function()
    local dir = assert(fs.mktemp({ prefix = "fs-test", dir = true }))
    local file = assert(fs.mktemp({ prefix = "fs-test" }))
    t.ok(fs.is_dir(dir), "directory mode should make a directory")
    t.ok(fs.is_file(file), "default mode should make a file")
    t.ok(fs.basename(dir):find("^fs%-test%."), "prefix should lead the name")
    fs.remove(dir, { recursive = true })
    fs.remove(file)
end)

t.test("list returns names with newlines and quotes, sorted", function()
    local dir = scratch()
    for _, name in ipairs({ "a\nb", "it's", "z" }) do
        assert(fs.write(dir .. "/" .. name, ""))
    end
    t.eq(fs.list(dir), { "a\nb", "it's", "z" })
    fs.remove(dir, { recursive = true })
end)

t.test("list fails for a missing directory", function()
    t.eq((fs.list("/no/such/dir-xyz")), nil)
end)

t.test("stat reports uid, size and kind", function()
    local dir = scratch()
    t.eq(fs.stat(dir).uid, tonumber((devos.capture({ "id", "-u" }))))
    t.eq(fs.stat(dir).kind, "dir")
    assert(fs.write(dir .. "/f", "hello"))
    local st = fs.stat(dir .. "/f")
    t.eq(st.size, 5)
    t.eq(st.kind, "file")
    t.eq(bit.band(st.mode, 511) > 0, true)
    assert(fs.symlink("f", dir .. "/l"))
    t.eq(fs.stat(dir .. "/l").kind, "link")
    t.eq(fs.stat(dir .. "/missing"), nil)
    fs.remove(dir, { recursive = true })
end)

t.test("read and write round-trip binary text", function()
    local dir = scratch()
    assert(fs.write(dir .. "/f", "a\0b\n"))
    t.eq(fs.read(dir .. "/f"), "a\0b\n")
    local text, err = fs.read(dir .. "/missing")
    t.eq(text, nil)
    t.ok(type(err) == "string", "a failed read should say why")
    fs.remove(dir, { recursive = true })
end)

t.test("predicates tell files, directories, links and executables apart", function()
    local dir = scratch()
    assert(fs.write(dir .. "/f", ""))
    assert(fs.symlink("nowhere", dir .. "/broken"))
    t.ok(fs.exists(dir .. "/f") and not fs.exists(dir .. "/broken"), "exists follows links")
    t.ok(fs.is_link(dir .. "/broken"), "a broken link is still a link")
    t.ok(not fs.is_exec(dir .. "/f"), "a new file is not executable")
    devos.run({ "chmod", "+x", dir .. "/f" })
    t.ok(fs.is_exec(dir .. "/f"), "chmod +x makes it executable")
    t.ok(fs.is_dir(dir) and not fs.is_file(dir), "a directory is not a file")
    fs.remove(dir, { recursive = true })
end)

t.test("mkdir, remove, readlink and realpath", function()
    local dir = scratch()
    t.eq((fs.mkdir(dir .. "/a/b")), nil)
    t.eq(fs.mkdir(dir .. "/a/b", { parents = true }), true)
    t.eq(fs.mkdir(dir .. "/a/b", { parents = true }), true)
    t.eq((fs.remove(dir .. "/a")), nil)
    assert(fs.symlink("a/b", dir .. "/l"))
    t.eq(fs.readlink(dir .. "/l"), "a/b")
    t.eq(fs.readlink(dir .. "/a"), nil)
    t.eq(fs.realpath(dir .. "/l"), fs.realpath(dir .. "/a/b"))
    t.eq(fs.remove(dir, { recursive = true }), true)
    t.ok(not fs.exists(dir), "recursive remove deletes the tree")
end)

t.test("join, dirname and basename are pure", function()
    t.eq(fs.join("/a/", "b", "c"), "/a/b/c")
    t.eq(fs.dirname("/a/b"), "/a")
    t.eq(fs.dirname("/a"), "/")
    t.eq(fs.dirname("a"), ".")
    t.eq(fs.dirname("a/b/"), "a")
    t.eq(fs.basename("/a/b/"), "b")
    t.eq(fs.basename("/"), "/")
end)

t.test("list follows a symlinked start directory", function()
    local dir = scratch()
    assert(fs.mkdir(dir .. "/real"))
    assert(fs.write(dir .. "/real/a", ""))
    assert(fs.symlink("real", dir .. "/link"))
    t.eq(fs.list(dir .. "/link"), { "a" })
    fs.remove(dir, { recursive = true })
end)

t.test("a relative path that starts with a dash works everywhere", function()
    local dir = scratch()
    local path = support.absolute_path()
    local snippet = ("package.path = %q; local fs = require('dev.fs'); "):format(path)
        .. "assert(fs.write('-x', 'abc')); assert(fs.mkdir('-d')); assert(fs.write('-d/in', ''))"
        .. "; io.write(tostring(fs.exists('-x')), tostring(fs.is_file('-x')), tostring(fs.is_dir('-d')), "
        .. "fs.stat('-x').size, table.concat(fs.list('-d'), ','))"
    local out = devos.capture({ "luajit", "-e", snippet }, { cwd = dir })
    t.eq(out, "truetruetrue3in")
    fs.remove(dir, { recursive = true })
end)

t.test("read of a directory fails with a message", function()
    local dir = scratch()
    local text, err = fs.read(dir)
    t.eq(text, nil)
    t.ok(type(err) == "string" and err ~= "", "expected a message")
    fs.remove(dir, { recursive = true })
end)

t.test("stat takes the GNU branch when stat --version succeeds", function()
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
    t.eq(out, "7 33188 5 file")
    fs.remove(dir, { recursive = true })
end)

t.test("an empty path is never the current directory", function()
    t.eq(fs.exists(""), false)
    t.eq(fs.is_dir(""), false)
    t.eq(fs.list(""), nil)
    t.eq(fs.stat(""), nil)
end)
