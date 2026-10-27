local ffi = require("ffi")

ffi.cdef([[
int isatty(int fd);
unsigned int getuid(void);
int execvp(const char *file, char *const argv[]);
char *strerror(int errnum);
int open(const char *path, int flags, ...);
int close(int fd);
long read(int fd, void *buf, size_t count);
]])

local STAT_LAYOUTS = {
    ["Linux/x64"] = [[
struct dev_stat {
    uint64_t st_dev, st_ino, st_nlink;
    uint32_t st_mode, st_uid, st_gid;
    int32_t pad0;
    uint64_t st_rdev;
    int64_t st_size, st_blksize, st_blocks;
    int64_t times[6];
    int64_t unused[3];
};]],
    ["Linux/arm64"] = [[
struct dev_stat {
    uint64_t st_dev, st_ino;
    uint32_t st_mode, st_nlink, st_uid, st_gid;
    uint64_t st_rdev, pad1;
    int64_t st_size;
    int32_t st_blksize, pad2;
    int64_t st_blocks;
    int64_t times[6];
    uint32_t unused[2];
};]],
    ["OSX/arm64"] = [[
struct dev_stat {
    int32_t st_dev;
    uint16_t st_mode, st_nlink;
    uint64_t st_ino;
    uint32_t st_uid, st_gid;
    int32_t st_rdev, pad0;
    int64_t times[8];
    int64_t st_size, st_blocks;
    int32_t st_blksize;
    uint32_t st_flags, st_gen;
    int32_t st_lspare;
    int64_t st_qspare[2];
};]],
}

local OPEN_FLAGS = {
    ["Linux/x64"] = { nofollow = 0x20000, cloexec = 0x80000, nonblock = 0x800 },
    ["Linux/arm64"] = { nofollow = 0x8000, cloexec = 0x80000, nonblock = 0x800 },
    ["OSX/arm64"] = { nofollow = 0x100, cloexec = 0x1000000, nonblock = 0x4 },
}

local PLATFORM = ffi.os .. "/" .. ffi.arch
local STAT_LAYOUT = STAT_LAYOUTS[PLATFORM]
if STAT_LAYOUT then
    ffi.cdef(STAT_LAYOUT)
    ffi.cdef("int fstat(int fd, struct dev_stat *buf);")
end
local HAS_FSTAT = STAT_LAYOUT ~= nil and pcall(function()
    return ffi.C.fstat
end)

local S_IFMT = 0xF000
local KIND_BITS = { [0x8000] = "file", [0x4000] = "dir", [0xA000] = "link" }
local EINTR = 4
local READ_CHUNK_BYTES = 65536

local WAIT_SIGNAL_MASK = 0x7f
local WAIT_EXIT_SHIFT = 256

---@alias dev.os.Kind "file"|"dir"|"link"|"other"

---@class dev.os
---@field Kind table<string, dev.os.Kind> the kinds of file `kind_of` names, by constant
---@field SIGNAL_EXIT_BASE integer exit status of a process killed by signal n, which is this plus n
---@field EXEC_FAILED integer exit status when a command cannot be started
local M = {
    SIGNAL_EXIT_BASE = 128,
    EXEC_FAILED = 126,
    Kind = { FILE = "file", DIR = "dir", LINK = "link", OTHER = "other" },
}

---Name the kind of file a raw `st_mode` describes.
---@param mode integer raw st_mode, file type bits included
---@return dev.os.Kind kind what the mode says it is
function M.kind_of(mode)
    return KIND_BITS[bit.band(mode, S_IFMT)] or M.Kind.OTHER
end

---Quote `arg` as one shell word.
---@param arg string word to quote, with no NUL byte
---@return string word the word in single quotes
function M.quote(arg)
    if type(arg) ~= "string" then
        error("quote expects a string, got " .. type(arg), 2)
    end
    if arg:find("\0", 1, true) then
        error("quote cannot take an argument with a NUL byte", 2)
    end
    return "'" .. arg:gsub("'", [['\'']]) .. "'"
end

---Join `argv` into one shell command with every word quoted.
---@param argv string[] command and its arguments, with at least one word
---@return string command the quoted command line
function M.command(argv)
    if type(argv) ~= "table" or #argv == 0 then
        error("command expects a non-empty argv list", 2)
    end
    local words = {}
    for i, arg in ipairs(argv) do
        words[i] = M.quote(arg)
    end
    return table.concat(words, " ")
end

---@class dev.os.Opts
---@field env table<string,string>? variables set for the command, over `os.defaults.env`
---@field unset string[]? variables removed from the command's environment, besides `os.defaults.unset`
---@field cwd string? directory to run in
---@field stdin "null"? read from /dev/null
---@field stdout string? "null", or a file path to append to, resolved against the caller's directory, not `cwd`
---@field stderr string? "null", a file path to append to (resolved like `stdout`), or "stdout" to merge into standard output

---@class dev.os.Defaults
---@field env table<string,string> variables set for every command
---@field unset string[] variables removed from every command's environment
---@field show boolean write each command to standard error before it runs
M.defaults = { env = {}, unset = {}, show = false }

---Name the operating system.
---@return "Darwin"|"Linux"|"Windows" name the system name
function M.name()
    local names = { OSX = "Darwin", Linux = "Linux", Windows = "Windows" }
    return names[ffi.os] or ffi.os
end

local ENV_NAME = "^[A-Za-z_][A-Za-z0-9_]*$"
local CHECK_LEVEL = 3

local function check(opts)
    local merged = {}
    for name, value in pairs(M.defaults.env) do
        merged[name] = value
    end
    for _, name in ipairs(M.defaults.unset) do
        merged[name] = nil
    end
    for name, value in pairs(opts.env or {}) do
        merged[name] = value
    end
    for _, name in ipairs(opts.unset or {}) do
        merged[name] = nil
    end
    local names = {}
    for name in pairs(merged) do
        if type(name) ~= "string" or not name:match(ENV_NAME) then
            error("env name " .. tostring(name) .. " is not a valid variable name", CHECK_LEVEL)
        end
        names[#names + 1] = name
    end
    table.sort(names)
    local words = {}
    local unset = {}
    for _, list in ipairs({ M.defaults.unset, opts.unset or {} }) do
        for _, name in ipairs(list) do
            if not name:match(ENV_NAME) then
                error("env name " .. tostring(name) .. " is not a valid variable name", CHECK_LEVEL)
            end
            unset[#unset + 1] = name
        end
    end
    table.sort(unset)
    for _, name in ipairs(unset) do
        words[#words + 1] = "-u"
        words[#words + 1] = name
    end
    if #names > 0 or #words > 0 then
        words[#words + 1] = "--"
    end
    for _, name in ipairs(names) do
        words[#words + 1] = name .. "=" .. merged[name]
    end
    if opts.stdin ~= nil and opts.stdin ~= "null" then
        error('stdin must be "null" or unset', CHECK_LEVEL)
    end
    if opts.stdout == "stdout" or opts.stdout == "stderr" or opts.stderr == "stderr" then
        error("only stderr can merge, and only into stdout", CHECK_LEVEL)
    end
    return words
end

local function redirect(fd, target)
    if target == nil then
        return ""
    end
    if target == "null" then
        return " " .. fd .. ">/dev/null"
    end
    if target == "stdout" then
        return " 2>&1"
    end
    return " " .. fd .. ">>" .. M.quote(target)
end

local function redirects(opts)
    return (opts.stdin and " </dev/null" or "")
        .. redirect(1, opts.stdout)
        .. redirect(2, opts.stderr)
end

local function directory(cwd)
    if cwd:sub(1, 1) == "/" then
        return cwd
    end
    return "./" .. cwd
end

local function announce(argv)
    if M.defaults.show then
        local stderr = io.stderr
        stderr:write("+ ", M.command(argv), "\n")
    end
end

local function past_env(argv, words)
    if #words == 0 or not argv[1]:find("=", 1, true) then
        return argv
    end
    return { "sh", "-c", 'exec "$@"', "sh", unpack(argv) }
end

local function shell_line(argv, opts, words)
    local command = M.command(past_env(argv, words))
    if #words > 0 then
        local quoted = {}
        for i, word in ipairs(words) do
            quoted[i] = M.quote(word)
        end
        command = "env " .. table.concat(quoted, " ") .. " " .. command
    end
    if opts.cwd then
        command = "( cd -- " .. M.quote(directory(opts.cwd)) .. " && " .. command .. " )"
    end
    return command .. redirects(opts)
end

---Describe the current errno.
---@return string message the system's text for the last failed call
function M.strerror()
    return ffi.string(ffi.C.strerror(ffi.errno()))
end

local function flush_output()
    local stdout, stderr = io.stdout, io.stderr
    stdout:flush()
    stderr:flush()
end

local function decode(status)
    if status == true then
        return 0
    end
    if type(status) ~= "number" then
        return nil
    end
    local signal = bit.band(status, WAIT_SIGNAL_MASK)
    if status % WAIT_EXIT_SHIFT == 0 then
        return status / WAIT_EXIT_SHIFT
    end
    return M.SIGNAL_EXIT_BASE + signal
end

---Run `argv` with the terminal's streams and wait for it.
---@param argv string[] command and its arguments, with at least one word
---@param opts dev.os.Opts? environment, directory and stream options
---@return integer? code exit status, or the signal exit base plus the signal when killed
function M.run(argv, opts)
    opts = opts or {}
    local command = shell_line(argv, opts, check(opts))
    announce(argv)
    flush_output()
    local ok, kind, code = os.execute(command)
    if type(ok) == "number" then
        return decode(ok)
    end
    if kind == "signal" then
        return M.SIGNAL_EXIT_BASE + code
    end
    return code
end

---Run `argv` and collect its standard output.
---@param argv string[] command and its arguments, with at least one word
---@param opts dev.os.Opts? environment, directory and stream options
---@return string output everything the command wrote to standard output
---@return integer? code exit status of the command
function M.capture(argv, opts)
    opts = opts or {}
    local command = shell_line(argv, opts, check(opts))
    announce(argv)
    flush_output()
    local pipe = assert(io.popen(command .. [[; printf '\n%d' "$?"]], "r"))
    local text = pipe:read("*a")
    pipe:close()
    local split = text:match("^.*()\n")
    if not split then
        error("capture lost the exit status of " .. command)
    end
    return text:sub(1, split - 1), tonumber(text:sub(split + 1))
end

---Find `name` on PATH.
---@param name string command name to look up
---@return string? path absolute path, or nil when `name` is not on PATH
function M.which(name)
    local out, code = M.capture({ "sh", "-c", [[command -v -- "$1"]], "sh", name })
    if code ~= 0 then
        return nil
    end
    local path = out:match("^[^\n]+")
    if path and path:sub(1, 1) == "/" then
        return path
    end
    return nil
end

---Read the real user id.
---@return integer uid user id of the process
function M.getuid()
    return tonumber(ffi.C.getuid())
end

---Check whether `fd` is a terminal.
---@param fd integer file descriptor to check
---@return boolean tty true when `fd` is a terminal
function M.isatty(fd)
    return ffi.C.isatty(fd) == 1
end

---Replace this process with `argv`.
---
---Only returns when the exec fails.
---@param argv string[] command and its arguments, with at least one word
---@param opts dev.os.Opts? environment, directory and stream options
---@return nil
---@return string message why the exec failed
function M.exec(argv, opts)
    if type(argv) ~= "table" or #argv == 0 then
        error("exec expects a non-empty argv list", 2)
    end
    opts = opts or {}
    local words = check(opts)
    announce(argv)
    local streams = redirects(opts)
    if opts.cwd or streams ~= "" then
        local wrapped = {
            "sh",
            "-c",
            (streams ~= "" and "exec" .. streams .. "; " or "")
                .. (opts.cwd and 'cd -- "$1" && shift && ' or "")
                .. 'exec "$@"',
            "sh",
        }
        if opts.cwd then
            wrapped[#wrapped + 1] = directory(opts.cwd)
        end
        for _, arg in ipairs(argv) do
            wrapped[#wrapped + 1] = arg
        end
        argv = wrapped
    end
    argv = past_env(argv, words)
    if #words > 0 then
        local prefixed = { "env" }
        for _, word in ipairs(words) do
            prefixed[#prefixed + 1] = word
        end
        for _, arg in ipairs(argv) do
            prefixed[#prefixed + 1] = arg
        end
        argv = prefixed
    end
    local count = #argv
    local cargs = ffi.new("char *[?]", count + 1)
    local keep = {}
    for i, arg in ipairs(argv) do
        if arg:find("\0", 1, true) then
            error("exec cannot take an argument with a NUL byte", 2)
        end
        local buf = ffi.new("char[?]", #arg + 1)
        ffi.copy(buf, arg, #arg)
        keep[i] = buf
        cargs[i - 1] = buf
    end
    flush_output()
    ffi.C.execvp(argv[1], cargs)
    return nil, M.strerror()
end

---@class dev.os.FdStat
---@field uid integer owner user id
---@field mode integer raw st_mode, file type bits included
---@field size integer size in bytes
---@field kind dev.os.Kind what the descriptor is

---Open `path` for reading, refusing a symbolic link in its last part.
---
---The open sets close-on-exec and does not block, so a FIFO never hangs it.
---@param path string file to open
---@return integer? fd the descriptor, or nil on failure
---@return string? message why it failed
function M.open_nofollow(path)
    local flags = OPEN_FLAGS[PLATFORM]
    if not flags then
        return nil, "no safe open on " .. PLATFORM
    end
    if path:find("\0", 1, true) then
        return nil, "path has a NUL byte"
    end
    local fd = ffi.C.open(path, bit.bor(flags.nofollow, flags.cloexec, flags.nonblock))
    if fd < 0 then
        return nil, M.strerror()
    end
    return fd
end

---Read the owner, mode and size of an open descriptor.
---@param fd integer descriptor to inspect
---@return dev.os.FdStat? stat the descriptor's facts, or nil on failure
---@return string? message why it failed
function M.fstat(fd)
    if not HAS_FSTAT then
        return nil, "no fstat on " .. PLATFORM
    end
    local buf = ffi.new("struct dev_stat[1]")
    if ffi.C.fstat(fd, buf) ~= 0 then
        return nil, M.strerror()
    end
    local mode = tonumber(buf[0].st_mode)
    return {
        uid = tonumber(buf[0].st_uid),
        mode = mode,
        size = tonumber(buf[0].st_size),
        kind = M.kind_of(mode),
    }
end

---Read up to `limit` bytes from an open descriptor.
---@param fd integer descriptor to read
---@param limit integer most bytes to read
---@return string? bytes what was read, which is shorter than `limit` only at end of file
---@return string? message why it failed
function M.read_fd(fd, limit)
    local buf = ffi.new("char[?]", READ_CHUNK_BYTES)
    local parts, total = {}, 0
    while total < limit do
        local count = tonumber(ffi.C.read(fd, buf, math.min(READ_CHUNK_BYTES, limit - total)))
        if count < 0 and ffi.errno() ~= EINTR then
            return nil, M.strerror()
        end
        if count == 0 then
            break
        end
        if count > 0 then
            parts[#parts + 1] = ffi.string(buf, count)
            total = total + count
        end
    end
    return table.concat(parts)
end

---Close a descriptor.
---@param fd integer descriptor to close
function M.close(fd)
    ffi.C.close(fd)
end

return M
