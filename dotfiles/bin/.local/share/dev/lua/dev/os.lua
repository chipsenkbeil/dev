local ffi = require("ffi")

ffi.cdef([[
int isatty(int fd);
unsigned int getuid(void);
int execvp(const char *file, char *const argv[]);
char *strerror(int errnum);
]])

local WAIT_SIGNAL_MASK = 0x7f
local WAIT_EXIT_SHIFT = 256

---@class dev.os
---@field SIGNAL_EXIT_BASE integer exit status of a process killed by signal n, which is this plus n
local M = {
    SIGNAL_EXIT_BASE = 128,
}

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
---@return integer? code exit status, or the signal exit base plus the signal when killed
function M.run(argv)
    local command = M.command(argv)
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
---@return string output everything the command wrote to standard output
---@return integer? code exit status of the command
function M.capture(argv)
    local command = M.command(argv)
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
---@return nil
---@return string message why the exec failed
function M.exec(argv)
    if type(argv) ~= "table" or #argv == 0 then
        error("exec expects a non-empty argv list", 2)
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

return M
