local ffi = require("ffi")

ffi.cdef([[
int isatty(int fd);
unsigned int getuid(void);
int getpid(void);
int usleep(unsigned int usec);
int setenv(const char *name, const char *value, int overwrite);
int execvp(const char *file, char *const argv[]);
void (*signal(int sig, void (*handler)(int)))(int);
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

local SIGPIPE = 13
local WAIT_SIGNAL_MASK = 0x7f
local WAIT_EXIT_SHIFT = 256
local TIMEOUT_EXIT = 124
local KILLED_EXITS = { [137] = true, [143] = true }
local KILL_GRACE_SECS = 1
local POLL_SECS = 0.1
local MICROS_PER_SEC = 1000000
local TIMED_WRAPPER = table.concat({
    'set -m; { eval "$1"; echo $? >"$2.tmp"; mv "$2.tmp" "$2"; } & pid=$!;',
    '( while [ -d "$4" ]; do',
    'kill -0 "$3" 2>/dev/null || break;',
    "sleep 0.2; done;",
    '[ -e "$2" ] || kill -KILL -- "-$pid" 2>/dev/null;',
    'rm -rf -- "$4" ) </dev/null >/dev/null 2>&1 & echo $pid $!',
}, " ")

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

---Call `fn` while a write to a closed pipe fails with an error instead of killing the process.
---@generic T
---@param fn fun(): T function that writes to a pipe
---@return T result what `fn` returned
function M.without_sigpipe(fn)
    local previous = ffi.C.signal(SIGPIPE, ffi.cast("void (*)(int)", 1))
    local ok, result = pcall(fn)
    ffi.C.signal(SIGPIPE, previous)
    if not ok then
        error(result, 0)
    end
    return result
end

---Run `argv` with `input` on its standard input and collect its standard output.
---
---The input never reaches an argument list, an environment or a file, so a
---secret handed over this way stays out of `ps`. `opts.stdin` and `opts.stdout`
---are not allowed.
---@param argv string[] command and its arguments, with at least one word
---@param input string what the command reads from standard input
---@param opts dev.os.Opts? environment, directory and standard error options
---@return string output everything the command wrote to standard output
---@return integer? code exit status of the command
function M.capture_input(argv, input, opts)
    opts = opts or {}
    if opts.stdin ~= nil or opts.stdout ~= nil then
        error("capture_input takes the input as an argument and keeps standard output", 2)
    end
    local sink, sink_code = M.capture({
        "mktemp",
        ((os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")) .. "/dev-input.XXXXXX",
    })
    if sink_code ~= 0 then
        error("capture_input cannot make a temporary file")
    end
    sink = sink:gsub("\n$", "")
    local command = "{ "
        .. shell_line(argv, opts, check(opts))
        .. "; } >"
        .. M.quote(sink)
        .. [[; printf '\n%d' "$?" >>]]
        .. M.quote(sink)
    announce(argv)
    flush_output()
    local ok, text = pcall(function()
        local pipe = assert(io.popen(command, "w"))
        M.without_sigpipe(function()
            pipe:write(input)
        end)
        pipe:close()
        local file = assert(io.open(sink, "rb"))
        local content = file:read("*a")
        file:close()
        return content
    end)
    os.remove(sink)
    if not ok then
        error(text, 0)
    end
    local split = text:match("^.*()\n")
    if not split then
        error("capture_input lost the exit status of " .. argv[1])
    end
    return text:sub(1, split - 1), tonumber(text:sub(split + 1))
end

---@class dev.os.TimedOpts
---@field env table<string,string>? variables set for the command, over `os.defaults.env`
---@field unset string[]? variables removed from the command's environment, besides `os.defaults.unset`
---@field cwd string? directory to run in
---@field input string? what the command reads from standard input, /dev/null when nil
---@field merge boolean? send standard error to the collected output instead of the terminal

local function nap(secs)
    ffi.C.usleep(secs * MICROS_PER_SEC)
end

---Sleep without starting a process.
---@param secs number seconds to wait
function M.nap(secs)
    nap(secs)
end

local function signal_group(signal, pid)
    M.run({ "sh", "-c", "kill -" .. signal .. ' -- "-$1"', "sh", pid }, { stderr = "null" })
end

---Run `argv` in its own process group and collect its output, stopping it after `secs` seconds.
---
---A command that outlives the limit is sent TERM and then KILL together with everything it started.
---A `secs` of 0 or less sets no limit, as GNU timeout does: the command runs to completion.
---When this process dies first (INT, TERM or KILL), the command's process group is killed and the
---temporary directory removed.
---@param argv string[] command and its arguments, with at least one word
---@param secs number seconds the command may run, 0 or less for no limit
---@param opts dev.os.TimedOpts? environment, directory, input and stream options
---@return string output what the command wrote to standard output, and standard error with `merge`
---@return integer code exit status, 124 when the limit hit or the command was killed
function M.capture_timed(argv, secs, opts)
    opts = opts or {}
    local words = check({ env = opts.env, unset = opts.unset })
    local made, made_code = M.capture({
        "mktemp",
        "-d",
        ((os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "")) .. "/dev-timed.XXXXXX",
    })
    if made_code ~= 0 then
        error("capture_timed cannot make a temporary directory")
    end
    local dir = made:gsub("\n$", "")
    local out, status = dir .. "/out", dir .. "/status"
    local stdin = "/dev/null"
    if opts.input then
        stdin = dir .. "/in"
        local file = assert(io.open(stdin, "wb"))
        file:write(opts.input)
        file:close()
    end
    local base = shell_line(argv, { env = opts.env, unset = opts.unset, cwd = opts.cwd }, words)
    local inner = "( "
        .. base
        .. " ) <"
        .. M.quote(stdin)
        .. " >"
        .. M.quote(out)
        .. (opts.merge and " 2>&1" or "")
    announce(argv)
    flush_output()
    local pipe = assert(io.popen(
        M.command({
            "sh",
            "-c",
            TIMED_WRAPPER,
            "sh",
            inner,
            status,
            tostring(ffi.C.getpid()),
            dir,
        }),
        "r"
    ))
    local pid, watcher = (pipe:read("*l") or ""):match("^(%d+) (%d+)$")
    pipe:close()
    if not pid then
        error("capture_timed could not start " .. argv[1])
    end
    local started = os.time()
    local code
    local polled, failure = pcall(function()
        while not code do
            local file = io.open(status, "rb")
            if file then
                code = tonumber(file:read("*a"))
                file:close()
            elseif secs > 0 and os.time() - started > secs then
                signal_group("TERM", pid)
                nap(KILL_GRACE_SECS)
                signal_group("KILL", pid)
                code = TIMEOUT_EXIT
            else
                nap(POLL_SECS)
            end
        end
    end)
    if not polled then
        signal_group("KILL", pid)
        M.run({ "kill", watcher }, { stderr = "null" })
        M.run({ "rm", "-rf", "--", dir })
        error(failure, 0)
    end
    if KILLED_EXITS[code] then
        code = TIMEOUT_EXIT
    end
    local file = io.open(out, "rb")
    local text = file and file:read("*a") or ""
    if file then
        file:close()
    end
    M.run({ "kill", watcher }, { stderr = "null" })
    M.run({ "rm", "-rf", "--", dir })
    return text, code
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

---Read the id of this process.
---@return integer pid process id
function M.getpid()
    return tonumber(ffi.C.getpid())
end

---Add directories to the end of this process's PATH.
---
---A tool already on PATH still wins.
---@param dirs string[] the directories, in order
function M.append_path(dirs)
    if #dirs == 0 then
        return
    end
    local path = table.concat(dirs, ":")
    local old = os.getenv("PATH")
    if old and old ~= "" then
        path = old .. ":" .. path
    end
    ffi.C.setenv("PATH", path, 1)
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
