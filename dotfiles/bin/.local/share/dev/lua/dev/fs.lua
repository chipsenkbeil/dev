local devos = require("dev.os")

local S_IFMT = 0xF000
local KINDS = { [0x8000] = "file", [0x4000] = "dir", [0xA000] = "link" }

---@class dev.fs.Stat
---@field uid integer owner user id
---@field mode integer raw st_mode, file type bits included
---@field size integer size in bytes
---@field kind "file"|"dir"|"link"|"other" what the path is, without following a link

---@class dev.fs
local M = {}

local gnu_stat

local function try(argv)
    local out, code = devos.capture(argv, { stderr = "stdout" })
    if code == 0 then
        return true
    end
    return nil, (out:gsub("%s+$", ""))
end

local function anchor(path)
    if path == "" or path:sub(1, 1) == "/" then
        return path
    end
    return "./" .. path
end

local function test(flag, path)
    return devos.run({ "test", flag, anchor(path) }) == 0
end

---Check that `path` exists, following links.
---@param path string path to test
---@return boolean exists true when it exists
function M.exists(path)
    return test("-e", path)
end

---Check that `path` is a directory.
---@param path string path to test
---@return boolean dir true when it is a directory or a link to one
function M.is_dir(path)
    return test("-d", path)
end

---Check that `path` is a regular file.
---@param path string path to test
---@return boolean file true when it is a regular file or a link to one
function M.is_file(path)
    return test("-f", path)
end

---Check that `path` is a symbolic link.
---@param path string path to test
---@return boolean link true when it is a link, even a broken one
function M.is_link(path)
    return test("-L", path)
end

---Check that `path` can be executed.
---@param path string path to test
---@return boolean exec true when the process may execute it
function M.is_exec(path)
    return test("-x", path)
end

---Read a whole file.
---@param path string file to read
---@return string? text the file's bytes, or nil on failure
---@return string? message why it failed
function M.read(path)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err
    end
    local text, rerr = file:read("*a")
    file:close()
    return text, rerr
end

---Write a whole file, replacing it.
---@param path string file to write
---@param text string bytes to write
---@return true? ok true on success
---@return string? message why it failed
function M.write(path, text)
    local file, err = io.open(path, "wb")
    if not file then
        return nil, err
    end
    local ok, werr = file:write(text)
    file:close()
    if not ok then
        return nil, werr
    end
    return true
end

---Make a directory.
---@param path string directory to make
---@param opts {parents: boolean?}? `parents` also makes missing parents and accepts an existing directory
---@return true? ok true on success
---@return string? message why it failed
function M.mkdir(path, opts)
    return try(opts and opts.parents and { "mkdir", "-p", "--", path } or { "mkdir", "--", path })
end

---Remove a file, link or directory.
---@param path string path to remove
---@param opts {recursive: boolean?}? `recursive` removes a directory with its contents and accepts a missing path
---@return true? ok true on success
---@return string? message why it failed
function M.remove(path, opts)
    return try(opts and opts.recursive and { "rm", "-rf", "--", path } or { "rm", "--", path })
end

---List the names in a directory.
---@param dir string directory to list
---@return string[]? names sorted names without the directory, or nil on failure
---@return string? message why it failed
function M.list(dir)
    local out, code = devos.capture(
        { "find", "-H", anchor(dir), "-mindepth", "1", "-maxdepth", "1", "-print0" },
        { stderr = "null" }
    )
    if code ~= 0 then
        return nil, "cannot list " .. dir
    end
    local names = {}
    for path in out:gmatch("([^%z]+)%z") do
        names[#names + 1] = path:match("[^/]*$")
    end
    table.sort(names)
    return names
end

local function is_gnu_stat()
    if gnu_stat == nil then
        gnu_stat = devos.run({ "stat", "--version" }, { stdout = "null", stderr = "null" }) == 0
    end
    return gnu_stat
end

---Read a path's owner, mode and size without following a link.
---@param path string path to inspect
---@return dev.fs.Stat? stat the path's facts, or nil when it is missing
function M.stat(path)
    local argv
    if is_gnu_stat() then
        argv = { "stat", "-c", "%u %f %s", "--", anchor(path) }
    else
        argv = { "stat", "-f", "%u %p %z", anchor(path) }
    end
    local out, code = devos.capture(argv, { stderr = "null" })
    if code ~= 0 then
        return nil
    end
    local uid, mode, size = out:match("^(%d+) (%x+) (%d+)")
    if not uid then
        return nil
    end
    local raw = tonumber(mode, is_gnu_stat() and 16 or 8)
    return {
        uid = tonumber(uid),
        mode = raw,
        size = tonumber(size),
        kind = KINDS[bit.band(raw, S_IFMT)] or "other",
    }
end

---Resolve `path` to an absolute path with no links.
---@param path string path to resolve, which must exist
---@return string? real the resolved path, or nil on failure
---@return string? message why it failed
function M.realpath(path)
    local out, code = devos.capture({ "realpath", "--", path }, { stderr = "null" })
    if code ~= 0 then
        return nil, "cannot resolve " .. path
    end
    return (out:gsub("\n$", ""))
end

---Read where a symbolic link points.
---@param path string link to read
---@return string? target the link's text, or nil when `path` is not a link
---@return string? message why it failed
function M.readlink(path)
    local out, code = devos.capture({ "readlink", "--", path }, { stderr = "null" })
    if code ~= 0 then
        return nil, path .. " is not a link"
    end
    return (out:gsub("\n$", ""))
end

---Make a temporary file or directory.
---@param opts {prefix: string?, dir: boolean?}? name prefix (`dev` by default) and whether to make a directory
---@return string? path the new path, or nil on failure
---@return string? message why it failed
function M.mktemp(opts)
    opts = opts or {}
    local base = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")
    local template = base .. "/" .. (opts.prefix or "dev") .. ".XXXXXX"
    local out, code =
        devos.capture(opts.dir and { "mktemp", "-d", template } or { "mktemp", template })
    if code ~= 0 then
        return nil, "cannot make a temporary path under " .. base
    end
    return (out:gsub("\n$", ""))
end

---Make a symbolic link.
---@param target string text the link holds
---@param link string path of the new link
---@return true? ok true on success
---@return string? message why it failed
function M.symlink(target, link)
    return try({ "ln", "-s", "--", target, link })
end

---Join path parts with single slashes.
---@param ... string parts, the first of which may be absolute
---@return string path the joined path
function M.join(...)
    local joined = table.concat({ ... }, "/")
    return (joined:gsub("//+", "/"))
end

---Take the directory part of a path.
---@param path string path to split
---@return string dir the path without its last part, `.` when it has none
function M.dirname(path)
    local trimmed = path:gsub("/+$", "")
    if trimmed == "" then
        return path:sub(1, 1) == "/" and "/" or "."
    end
    local dir = trimmed:match("^(.*)/[^/]*$")
    if dir == nil then
        return "."
    end
    dir = dir:gsub("/+$", "")
    return dir == "" and "/" or dir
end

---Take the last part of a path.
---@param path string path to split
---@return string name the last part, `/` for the root
function M.basename(path)
    local trimmed = path:gsub("/+$", "")
    if trimmed == "" then
        return path:sub(1, 1) == "/" and "/" or ""
    end
    return trimmed:match("[^/]*$")
end

return M
